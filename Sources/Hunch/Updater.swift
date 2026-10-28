import AppKit
import CryptoKit
import Foundation
import HunchCore
import Observation

/// In-app updates from GitHub Releases: check, download the zip, verify it against SHA256SUMS.txt and its code
/// signature, swap the bundle in place and relaunch. One request per check. Settings and the model folder
/// (`~/.hunch/models`) live outside the bundle, so an update keeps both.
///
/// Automatic updates are quiet: a check at launch when the last one is a day old, then one a day from a
/// system-scheduled background activity (macOS picks the moment). A newer release downloads and verifies in the
/// background, and installs and relaunches only once no Hunch window is open and the Mac has had no input for a
/// minute, so it never interrupts a search.
@MainActor
@Observable
final class Updater {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(String)
        case failed(String)
    }

    static let shared = Updater()

    private(set) var phase: Phase = .idle
    var automatic: Bool {
        didSet { defaults.set(automatic, forKey: Self.automaticKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var scheduler: NSBackgroundActivityScheduler?
    /// True while a Hunch window (panel, Settings, the guide) is on screen; a quiet install waits for false.
    @ObservationIgnored var isBusy: () -> Bool = { false }
    private static let automaticKey = "updates.automatic"
    private static let lastCheckKey = "updates.lastCheck"
    private static let interval: TimeInterval = 24 * 3600
    /// Passed to the relaunch after a quiet update.
    static let updatedFlag = "--updated"

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        automatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    var available: Release? {
        if case .available(let r) = phase { return r }
        return nil
    }

    /// At launch: a check when the last one is a day old, then a daily one scheduled by the system.
    func startAutomatic() {
        guard AppInfo.version != "dev", scheduler == nil else { return }
        checkIfDue()
        let s = NSBackgroundActivityScheduler(identifier: "\(Bundle.main.bundleIdentifier ?? "app.hunch.Hunch").update")
        s.repeats = true
        s.interval = Self.interval
        s.tolerance = 3600
        s.qualityOfService = .utility
        s.schedule { [weak self] done in
            Task { @MainActor in self?.checkIfDue() }
            done(.finished)
        }
        scheduler = s
    }

    private func checkIfDue() {
        guard automatic, phase == .idle || phase == .upToDate else { return }
        let last = defaults.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last >= Self.interval else { return }
        check(quiet: true)
    }

    /// `quiet`: an automatic check. A newer release installs without asking; a failed request stays silent.
    func check(quiet: Bool = false) {
        switch phase {
        case .checking, .installing: return
        default: break
        }
        phase = .checking
        task = Task {
            do {
                var request = URLRequest(url: UpdateCheck.latestAPI, timeoutInterval: 20)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                try Self.requireOK(response)
                defaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                if let r = try UpdateCheck.release(from: data), UpdateCheck.isNewer(r.version, than: AppInfo.version) {
                    phase = .available(r)
                    if quiet, automatic { install(quiet: true) }
                } else {
                    phase = .upToDate
                }
            } catch {
                phase = quiet ? .idle : .failed("Could not reach GitHub. Try again later.")
            }
        }
    }

    /// `quiet`: from an automatic check. Waits until Hunch is not in use before it swaps the bundle and relaunches;
    /// on any problem the update stays available for a manual install, which reports the reason.
    func install(quiet: Bool = false) {
        guard let release = available else { return }
        let bundle = Bundle.main.bundleURL
        if let problem = Self.placementProblem(bundle) {
            if !quiet { phase = .failed(problem) }
            return
        }
        phase = .installing("Downloading \(AppInfo.name) \(release.version)…")
        task = Task {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent(
                "hunch-update-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = try await Self.download(release.archive, to: work.appendingPathComponent(release.archiveName))
                let (sums, response) = try await URLSession.shared.data(from: release.checksums)
                try Self.requireOK(response)
                guard
                    let expected = UpdateCheck.checksum(
                        for: release.archiveName, in: String(decoding: sums, as: UTF8.self))
                else { throw UpdateError("The release has no checksum for \(release.archiveName).") }
                phase = .installing("Checking the download…")
                let actual = try await Task.detached { try Self.sha256(zip) }.value
                guard actual == expected else { throw UpdateError("The download does not match its checksum.") }
                let unpacked = work.appendingPathComponent("unpacked")
                try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
                let app = unpacked.appendingPathComponent(bundle.lastPathComponent)
                try Self.validate(app, version: release.version)
                try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
                if quiet {
                    phase = .installing("Version \(release.version) installs when \(AppInfo.name) is not in use.")
                    try await waitUntilIdle()
                }
                phase = .installing("Installing…")
                _ = try FileManager.default.replaceItemAt(bundle, withItemAt: app)
                Self.relaunch(bundle, quiet: quiet)
            } catch {
                if quiet {
                    phase = .available(release)
                } else {
                    phase = .failed(
                        (error as? UpdateError)?.message ?? "The update failed. Your current version still works.")
                }
            }
        }
    }

    // MARK: Steps

    struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Updating needs a writable, non-translocated bundle (Gatekeeper runs quarantined apps from a read-only copy).
    private static func placementProblem(_ bundle: URL) -> String? {
        if bundle.path.contains("/AppTranslocation/") {
            return "Move \(AppInfo.name) to the Applications folder, open it from there, then update."
        }
        if !FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) {
            return "\(AppInfo.name) cannot replace itself in \(bundle.deletingLastPathComponent().path)."
        }
        return nil
    }

    /// One look every 30 s, only while a verified update waits: no Hunch window open and no input for a minute.
    private func waitUntilIdle() async throws {
        while isBusy() || Self.secondsSinceInput() < 60 {
            try await Task.sleep(for: .seconds(30))
        }
    }

    private static func secondsSinceInput() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return .infinity }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    private static func requireOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError("GitHub did not return the release. Try again later.")
        }
    }

    private static func download(_ url: URL, to destination: URL) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: url)
        try requireOK(response)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    nonisolated private static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The archive must hold this app (same bundle id) at the advertised version.
    private static func validate(_ app: URL, version: String) throws {
        guard let info = Bundle(url: app)?.infoDictionary,
            info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
            info["CFBundleShortVersionString"] as? String == version
        else { throw UpdateError("The download is not \(AppInfo.name) \(version).") }
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { p in
                p.terminationStatus == 0
                    ? c.resume() : c.resume(throwing: UpdateError("The downloaded app failed verification."))
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }

    /// A detached shell waits for this process to exit (the single-instance lock), then opens the new bundle.
    ///
    /// `open -n`: for a moment after the process exits, Launch Services still lists it as running, and a plain `open`
    /// sends the reopen to that dead instance (error -600) instead of launching, so the app quit and stayed closed.
    /// `quiet`: the new process gets `--updated` and starts in the menu bar without opening Settings.
    private static func relaunch(_ bundle: URL, quiet: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let open = quiet ? "/usr/bin/open -n \"$2\" --args \(updatedFlag)" : "/usr/bin/open -n \"$2\""
        p.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; \(open)", "sh",
            String(ProcessInfo.processInfo.processIdentifier), bundle.path,
        ]
        try? p.run()
        NSApp.terminate(nil)
    }
}
