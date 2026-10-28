// Model pin matches DigUp's ModelFiles.swift (MIT, github.com/ARahim3/DigUp)
import CryptoKit
import Darwin
import Foundation
import Network
import Synchronization
import os

private let log = Logger(subsystem: "dev.hunch", category: "model")

// MARK: Public model surface

public enum ModelFile: String, CaseIterable, Sendable, Codable {
    case text, projector

    public static let repository = "ggml-org/embeddinggemma-2-GGUF"
    public static let revision = "bfcd298762cc34d0357ece5ebdd31791a3a374d8"

    public var fileName: String { ModelFileSpec.pinned[self]!.fileName }
    public var byteCount: Int64 { ModelFileSpec.pinned[self]!.byteCount }
    public var sha256: String { ModelFileSpec.pinned[self]!.sha256 }
    public var remoteURL: URL { ModelFileSpec.pinned[self]!.remoteURL }
}

/// One downloadable file. The public `ModelFile` reads the pinned table; tests inject a small one.
struct ModelFileSpec: Sendable, Equatable {
    let fileName: String
    let byteCount: Int64
    let sha256: String
    let remoteURL: URL

    static func huggingFace(_ name: String) -> URL {
        URL(string: "https://huggingface.co/\(ModelFile.repository)/resolve/\(ModelFile.revision)/\(name)")!
    }

    static let pinned: [ModelFile: ModelFileSpec] = [
        .text: ModelFileSpec(
            fileName: "embeddinggemma-2-Q8_0.gguf", byteCount: 309_855_456,
            sha256: "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135",
            remoteURL: huggingFace("embeddinggemma-2-Q8_0.gguf")),
        .projector: ModelFileSpec(
            fileName: "mmproj-embeddinggemma-2-Q8_0.gguf", byteCount: 554_821_024,
            sha256: "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f",
            remoteURL: huggingFace("mmproj-embeddinggemma-2-Q8_0.gguf")),
    ]
}

public enum ModelSource: String, Sendable, Codable, Equatable {
    case override  // HUNCH_MODEL / HUNCH_MMPROJ (dev only, unverified, logged)
    case downloaded  // ~/.hunch/models
}

public struct ResolvedModel: Sendable, Equatable {
    public let text: URL
    public let textSource: ModelSource
    public let projector: URL?  // nil → text meaning only, image vectors off
    public let projectorSource: ModelSource?
    public var hasProjector: Bool { projector != nil }

    public init(text: URL, textSource: ModelSource, projector: URL?, projectorSource: ModelSource?) {
        self.text = text
        self.textSource = textSource
        self.projector = projector
        self.projectorSource = projectorSource
    }
}

public struct DownloadProgress: Sendable, Equatable {
    public let file: ModelFile  // the file currently transferring
    public let receivedBytes: Int64  // across all requested files, includes resumed .partial bytes
    public let totalBytes: Int64  // sum of requested files (864_676_480 for both)
    public let bytesPerSecond: Double?  // nil until 3 s of samples
    public var fraction: Double { totalBytes == 0 ? 0 : Double(receivedBytes) / Double(totalBytes) }
    public var secondsRemaining: Double? { bytesPerSecond.map { Double(totalBytes - receivedBytes) / max($0, 1) } }

    public init(file: ModelFile, receivedBytes: Int64, totalBytes: Int64, bytesPerSecond: Double?) {
        self.file = file
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }
}

public enum ModelStoreError: Error, Sendable, Equatable {
    case offline
    case http(status: Int)
    case checksum(ModelFile)  // after one automatic retry
    case diskFull(needed: Int64, available: Int64)  // needed = remaining bytes + 512 MB headroom
    case io(String)
}

public enum ModelState: Sendable, Equatable {
    case missing  // names + contents search only
    case downloading(DownloadProgress)
    case paused(DownloadProgress)  // .partial kept; resumable after relaunch
    case verifying(ModelFile)
    case ready(ResolvedModel)
    case failed(ModelStoreError, progress: DownloadProgress?)
}

/// UI-facing surface. ModelStore conforms; the app's DEBUG FixtureModelStore conforms too.
public protocol ModelProviding: AnyObject, Sendable {
    var state: ModelState { get }  // non-blocking snapshot (Mutex), safe on main
    func states() -> AsyncStream<ModelState>  // yields `state` first; progress ≤ 4 Hz
    func download()  // user-initiated; text first, then projector; no-op if ready
    func pause()  // keeps resumeData/.partial
    func cancel()  // deletes .partial files, state → .missing
    func remove() async throws  // deletes only `.downloaded` files, never an override
    /// Verifies size + SHA off-main, then copies (APFS clone) into Models/.
    func importFiles(_ urls: [URL]) async throws -> ResolvedModel
    var modelsDirectory: URL { get }  // for "Show in Finder"
}

// MARK: ModelStore

public final class ModelStore: ModelProviding {
    public static let shared = ModelStore()
    public static let downloadBytes: Int64 = 864_676_480
    /// Free space kept on top of the remaining bytes before a download starts.
    static let headroomBytes: Int64 = 512 * 1024 * 1024
    /// UI progress rate: at most one `.downloading` update per 250 ms.
    static let progressInterval: Duration = .milliseconds(250)

    public let modelsDirectory: URL
    let home: URL
    let environment: [String: String]
    let specs: [ModelFile: ModelFileSpec]
    let configuration: URLSessionConfiguration
    /// Free bytes on the volume holding the given directory (injected in tests).
    let capacity: @Sendable (URL) -> Int64?
    let monitorsNetwork: Bool

    private let inner = Mutex(Inner())
    private let verifiedCache: Mutex<VerifiedCache>

    struct Inner {
        var state: ModelState = .missing
        var continuations: [UUID: AsyncStream<ModelState>.Continuation] = [:]
        var lastProgressEmit: ContinuousClock.Instant?
        /// The user asked for the download and has not paused or cancelled it since.
        var wantsDownload = false
        var runner: Task<Void, Never>?
        var activeTask: URLSessionDownloadTask?
        var activeFetch: FetchContext?
        var resumeData: [ModelFile: Data] = [:]
        var pathMonitor: NWPathMonitor?
        var session: URLSession?
        var rate: RateSample?
    }

    struct RateSample { var start: ContinuousClock.Instant; var startBytes: Int64 }

    public convenience init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configuration: URLSessionConfiguration = .default
    ) {
        self.init(
            home: home, environment: environment, configuration: configuration,
            specs: ModelFileSpec.pinned, capacity: ModelStore.volumeCapacity, monitorsNetwork: true)
    }

    init(
        home: URL, environment: [String: String], configuration: URLSessionConfiguration,
        specs: [ModelFile: ModelFileSpec], capacity: @escaping @Sendable (URL) -> Int64?,
        monitorsNetwork: Bool
    ) {
        self.home = home
        self.environment = environment
        self.configuration = configuration
        self.specs = specs
        self.capacity = capacity
        self.monitorsNetwork = monitorsNetwork
        modelsDirectory = Paths.modelsDirectory(home: home)
        verifiedCache = Mutex(VerifiedCache.load(from: modelsDirectory.appendingPathComponent(".verified.json")))
        let initial: ModelState
        if let model = resolve() {
            initial = .ready(model)
        } else if let progress = partialProgress(current: .text), progress.receivedBytes > 0 {
            initial = .paused(progress)
        } else {
            initial = .missing
        }
        inner.withLock { $0.state = initial }
    }

    deinit {
        inner.withLock { s in
            s.pathMonitor?.cancel()
            s.session?.invalidateAndCancel()
            for c in s.continuations.values { c.finish() }
        }
    }

    func spec(_ file: ModelFile) -> ModelFileSpec { specs[file]! }
    var downloadTotal: Int64 { ModelFile.allCases.reduce(0) { $0 + spec($1).byteCount } }

    // MARK: State

    public var state: ModelState { inner.withLock { $0.state } }

    public func states() -> AsyncStream<ModelState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ModelState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let current = inner.withLock { s -> ModelState in
            s.continuations[id] = continuation
            return s.state
        }
        continuation.yield(current)
        continuation.onTermination = { [weak self] _ in
            _ = self?.inner.withLock { $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    /// Sets the state and tells observers. `.downloading` updates are dropped inside the 4 Hz gate.
    func setState(_ new: ModelState, force: Bool = false) {
        let targets: [AsyncStream<ModelState>.Continuation] = inner.withLock { s in
            if case .downloading = new, case .downloading = s.state, !force {
                let now = ContinuousClock.now
                if let last = s.lastProgressEmit, now - last < Self.progressInterval {
                    s.state = new
                    return []
                }
                s.lastProgressEmit = now
            } else if case .downloading = new {
                s.lastProgressEmit = .now
            }
            guard s.state != new || force else { return [] }
            s.state = new
            return Array(s.continuations.values)
        }
        for c in targets { c.yield(new) }
    }

    // MARK: Resolution

    struct Candidate { let url: URL; let source: ModelSource }

    /// Every place a file may live, in `ModelSource` order.
    func candidates(_ file: ModelFile) -> [Candidate] {
        var out: [Candidate] = []
        let name = spec(file).fileName
        let key = file == .text ? "HUNCH_MODEL" : "HUNCH_MMPROJ"
        if let o = environment[key], !o.isEmpty {
            out.append(Candidate(url: URL(fileURLWithPath: (o as NSString).expandingTildeInPath), source: .override))
        }
        out.append(Candidate(url: modelsDirectory.appendingPathComponent(name), source: .downloaded))
        return out
    }

    /// Stat-only resolution in the order of ModelSource (first that exists AND has the exact byte count wins,
    /// per file; text and projector may come from different sources). Uses Models/.verified.json
    /// (keyed by path, size, mtime, inode) and never hashes on the caller's thread. ≤ 5 ms.
    public func resolve() -> ResolvedModel? {
        guard let text = resolveFile(.text) else { return nil }
        let projector = resolveFile(.projector)
        return ResolvedModel(
            text: text.url, textSource: text.source,
            projector: projector?.url, projectorSource: projector?.source)
    }

    func resolveFile(_ file: ModelFile) -> Candidate? {
        let bytes = spec(file).byteCount
        for c in candidates(file) {
            guard let st = FileStat(c.url) else { continue }
            if c.source == .override {
                log.info("unverified override \(file.rawValue, privacy: .public) \(c.url.path, privacy: .public)")
                return c
            }
            guard st.size == bytes else { continue }
            if verifiedCache.withLock({ $0.verdict(c.url, st) }) == false { continue }  // known bad hash
            return c
        }
        return nil
    }

    /// Hashes any unverified candidate off-main (4 MiB chunks, CryptoKit), updates .verified.json and `state`.
    public func verifyCandidates() async -> ResolvedModel? {
        for file in ModelFile.allCases {
            while let c = resolveFile(file), c.source != .override,
                let st = FileStat(c.url), verifiedCache.withLock({ $0.verdict(c.url, st) }) == nil
            {
                let ok = (try? await Self.sha256(of: c.url)) == spec(file).sha256
                verifiedCache.withLock { $0.record(c.url, st, ok: ok) }
                if !ok { log.error("checksum mismatch \(c.url.path, privacy: .public)") }
                if ok { break }
            }
        }
        saveVerified()
        let model = resolve()
        if isIdle {
            if let model { setState(.ready(model)) } else if case .ready = state { setState(.missing) }
        }
        return model
    }

    private var isIdle: Bool {
        switch state {
        case .downloading, .verifying: return false
        default: return true
        }
    }

    private func saveVerified() {
        let url = modelsDirectory.appendingPathComponent(".verified.json")
        verifiedCache.withLock { $0.save(to: url) }
    }

    /// Streamed SHA-256 in 4 MiB chunks, on a background task.
    static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = try autoreleasepool { try handle.read(upToCount: 4 * 1024 * 1024) }
                guard let chunk, !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    // MARK: Download control

    public func download() {
        if case .ready(let m) = state, m.hasProjector { return }
        let start: Bool = inner.withLock { s in
            s.wantsDownload = true
            return s.runner == nil
        }
        startPathMonitorIfNeeded()
        guard start else { return }
        let task = Task.detached(priority: .utility) { [weak self] in
            await self?.runDownloads()
            _ = self?.inner.withLock { $0.runner = nil }
        }
        inner.withLock { $0.runner = task }
    }

    public func pause() {
        let task: URLSessionDownloadTask? = inner.withLock { s in
            s.wantsDownload = false
            return s.activeTask
        }
        task?.cancel(byProducingResumeData: { _ in })  // resume data arrives in didCompleteWithError
    }

    public func cancel() {
        let (task, runner): (URLSessionDownloadTask?, Task<Void, Never>?) = inner.withLock { s in
            s.wantsDownload = false
            s.resumeData = [:]
            return (s.activeTask, s.runner)
        }
        runner?.cancel()
        task?.cancel()
        Task.detached { [weak self] in
            _ = await runner?.value
            guard let self else { return }
            for file in ModelFile.allCases { self.deletePartial(file) }
            if let model = self.resolve() { self.setState(.ready(model)) } else { self.setState(.missing) }
        }
    }

    public func remove() async throws {
        cancelQuietly()
        let fm = FileManager.default
        for file in ModelFile.allCases {
            // Only the copies this app owns; an override is never touched.
            let url = modelsDirectory.appendingPathComponent(spec(file).fileName)
            if fm.fileExists(atPath: url.path) {
                do { try fm.removeItem(at: url) } catch { throw ModelStoreError.io(error.localizedDescription) }
            }
            deletePartial(file)
        }
        if let model = resolve() { setState(.ready(model)) } else { setState(.missing) }
    }

    private func cancelQuietly() {
        let (task, runner): (URLSessionDownloadTask?, Task<Void, Never>?) = inner.withLock { s in
            s.wantsDownload = false
            s.resumeData = [:]
            return (s.activeTask, s.runner)
        }
        runner?.cancel()
        task?.cancel()
    }

    public func importFiles(_ urls: [URL]) async throws -> ResolvedModel {
        let fm = FileManager.default
        try ensureModelsDirectory()
        for url in urls {
            guard let st = FileStat(url) else { throw ModelStoreError.io("Cannot read \(url.lastPathComponent)") }
            guard let file = ModelFile.allCases.first(where: { spec($0).byteCount == st.size }) else {
                throw ModelStoreError.io("\(url.lastPathComponent) is not an EmbeddingGemma 2 Q8_0 file")
            }
            setState(.verifying(file))
            let hash = try await Self.sha256(of: url)
            guard hash == spec(file).sha256 else {
                restoreIdleState()
                throw ModelStoreError.checksum(file)
            }
            let dest = modelsDirectory.appendingPathComponent(spec(file).fileName)
            if dest.standardizedFileURL.resolvingSymlinksInPath() != url.standardizedFileURL.resolvingSymlinksInPath() {
                try? fm.removeItem(at: dest)
                do { try fm.copyItem(at: url, to: dest) }  // clonefile on APFS
                catch {
                    restoreIdleState()
                    throw ModelStoreError.io(error.localizedDescription)
                }
            }
            excludeFromBackup(dest)
            if let dst = FileStat(dest) { verifiedCache.withLock { $0.record(dest, dst, ok: true) } }
        }
        saveVerified()
        guard let model = resolve() else {
            restoreIdleState()
            throw ModelStoreError.io("The text model is still missing")
        }
        setState(.ready(model))
        return model
    }

    private func restoreIdleState() {
        if let model = resolve() { setState(.ready(model)) } else { setState(.missing) }
    }

    // MARK: Download engine

    func partialURL(_ file: ModelFile) -> URL {
        modelsDirectory.appendingPathComponent(spec(file).fileName + ".partial")
    }

    func partialSize(_ file: ModelFile) -> Int64 { FileStat(partialURL(file))?.size ?? 0 }

    private func deletePartial(_ file: ModelFile) {
        try? FileManager.default.removeItem(at: partialURL(file))
    }

    /// Files still to fetch, in download order (text first).
    func pendingFiles() -> [ModelFile] {
        ModelFile.allCases.filter { resolveFile($0) == nil }
    }

    /// Bytes already on disk or resolved for every file, for the progress total.
    func partialProgress(current: ModelFile) -> DownloadProgress? {
        var received: Int64 = 0
        for file in ModelFile.allCases {
            if resolveFile(file) != nil { received += spec(file).byteCount } else { received += partialSize(file) }
        }
        return DownloadProgress(
            file: current, receivedBytes: received, totalBytes: downloadTotal,
            bytesPerSecond: nil)
    }

    private func ensureModelsDirectory() throws {
        do { try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true) } catch {
            throw ModelStoreError.io(error.localizedDescription)
        }
    }

    private func runDownloads() async {
        var checksumRetried: Set<ModelFile> = []
        let startBytes = partialProgress(current: .text)?.receivedBytes ?? 0
        inner.withLock { $0.rate = RateSample(start: .now, startBytes: startBytes) }
        while !Task.isCancelled {
            let pending = pendingFiles()
            guard inner.withLock({ $0.wantsDownload }) else {
                if let file = pending.first { setState(.paused(partialProgress(current: file)!)) }
                return
            }
            guard let file = pending.first else {
                if let model = resolve() { setState(.ready(model), force: true) }
                return
            }
            do {
                try ensureModelsDirectory()
                let remaining = pending.reduce(Int64(0)) { $0 + max(0, spec($1).byteCount - partialSize($1)) }
                let needed = remaining + Self.headroomBytes
                if let available = capacity(modelsDirectory), available < needed {
                    throw ModelStoreError.diskFull(needed: needed, available: available)
                }
                try await fetch(file)
                guard inner.withLock({ $0.wantsDownload }), !Task.isCancelled else {
                    if !Task.isCancelled { setState(.paused(partialProgress(current: file)!)) }
                    return
                }
                setState(.verifying(file))
                let partial = partialURL(file)
                let size = partialSize(file)
                let hash = size == spec(file).byteCount ? try await Self.sha256(of: partial) : ""
                if hash != spec(file).sha256 {
                    deletePartial(file)
                    inner.withLock { _ = $0.resumeData.removeValue(forKey: file) }
                    if checksumRetried.contains(file) { throw ModelStoreError.checksum(file) }
                    checksumRetried.insert(file)
                    log.error("checksum mismatch for \(file.rawValue, privacy: .public), retrying once")
                    continue
                }
                let dest = modelsDirectory.appendingPathComponent(spec(file).fileName)
                try? FileManager.default.removeItem(at: dest)
                if rename(partial.path, dest.path) != 0 { throw ModelStoreError.io(String(cString: strerror(errno))) }
                excludeFromBackup(dest)
                if let st = FileStat(dest) { verifiedCache.withLock { $0.record(dest, st, ok: true) } }
                saveVerified()
            } catch let error as ModelStoreError {
                if error == .io("paused") {
                    setState(.paused(partialProgress(current: file)!))
                    return
                }
                setState(.failed(error, progress: partialProgress(current: file)))
                if error != .offline { inner.withLock { $0.wantsDownload = false } }
                return
            } catch {
                if Task.isCancelled { return }
                setState(.failed(.io(error.localizedDescription), progress: partialProgress(current: file)))
                inner.withLock { $0.wantsDownload = false }
                return
            }
        }
    }

    private func makeSession() -> URLSession {
        inner.withLock { s in
            if let session = s.session { return session }
            let delegate = DownloadDelegate(store: self)
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            s.session = session
            return session
        }
    }

    /// Transfers one file into its `.partial`. Returns when the transfer completes; throws `.io("paused")` on pause.
    private func fetch(_ file: ModelFile) async throws {
        let session = makeSession()
        let offset = partialSize(file)
        guard offset < spec(file).byteCount else { return }
        let base = (partialProgress(current: file)?.receivedBytes ?? 0) - offset
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let task: URLSessionDownloadTask = inner.withLock { s in
                    let task: URLSessionDownloadTask
                    if let data = s.resumeData.removeValue(forKey: file) {
                        task = session.downloadTask(withResumeData: data)
                    } else {
                        var request = URLRequest(url: spec(file).remoteURL)
                        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
                        task = session.downloadTask(with: request)
                    }
                    s.activeTask = task
                    s.activeFetch = FetchContext(file: file, offset: offset, base: base, continuation: cont)
                    return task
                }
                setState(
                    .downloading(
                        DownloadProgress(
                            file: file, receivedBytes: base + offset,
                            totalBytes: downloadTotal, bytesPerSecond: nil)), force: true)
                task.resume()
            }
        } onCancel: {
            inner.withLock { $0.activeTask }?.cancel()
        }
    }

    // MARK: Delegate callbacks

    struct FetchContext {
        let file: ModelFile
        let offset: Int64
        let base: Int64
        let continuation: CheckedContinuation<Void, Error>
        var error: ModelStoreError?
        /// Bytes the in-flight transfer has written to its temp file so far.
        var written: Int64 = 0
    }

    fileprivate func didWrite(totalBytesWritten: Int64) {
        let snapshot: (ModelFile, Int64, Double?)? = inner.withLock { s in
            guard var fetch = s.activeFetch else { return nil }
            fetch.written = totalBytesWritten
            s.activeFetch = fetch
            let received = fetch.base + fetch.offset + totalBytesWritten
            var rate: Double?
            if let r = s.rate {
                let elapsed = ContinuousClock.now - r.start
                let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                if secs >= 3 { rate = Double(received - r.startBytes) / secs }
            }
            return (fetch.file, received, rate)
        }
        guard let (file, received, rate) = snapshot else { return }
        setState(
            .downloading(
                DownloadProgress(
                    file: file, receivedBytes: received, totalBytes: downloadTotal,
                    bytesPerSecond: rate)))
    }

    /// Moves the finished temp file into `.partial` (appending after a ranged response). Runs synchronously,
    /// because URLSession deletes `location` when this returns.
    fileprivate func didFinish(location: URL, response: URLResponse?) {
        guard let fetch = inner.withLock({ $0.activeFetch }) else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        var failure: ModelStoreError?
        let partial = partialURL(fetch.file)
        let fm = FileManager.default
        switch status {
        case 200:
            try? fm.removeItem(at: partial)
            do { try fm.moveItem(at: location, to: partial) } catch { failure = .io(error.localizedDescription) }
        case 206:
            let start = (response as? HTTPURLResponse).flatMap { Self.contentRangeStart($0) } ?? fetch.offset
            do {
                if start != partialSize(fetch.file) {
                    // The server resumed somewhere else; trust only a fresh file.
                    if start == 0 {
                        try? fm.removeItem(at: partial)
                        try fm.moveItem(at: location, to: partial)
                    } else {
                        try? fm.removeItem(at: partial)
                        failure = .io("unexpected range start \(start)")
                    }
                } else {
                    try Self.append(location, to: partial)
                }
            } catch { failure = .io(error.localizedDescription) }
        case 416:
            break  // the .partial already holds every byte; the checksum decides
        default:
            failure = .http(status: status)
        }
        inner.withLock { s in s.activeFetch?.error = failure }
    }

    fileprivate func didComplete(error: Error?) {
        let fetch: FetchContext? = inner.withLock { s in
            let f = s.activeFetch
            s.activeFetch = nil
            s.activeTask = nil
            if let error = error as NSError?,
                let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, let file = f?.file
            {
                s.resumeData[file] = data
            }
            return f
        }
        guard let fetch else { return }
        if let failure = fetch.error {
            fetch.continuation.resume(throwing: failure)
            return
        }
        guard let error else {
            fetch.continuation.resume()
            return
        }
        let urlError = error as? URLError
        if urlError?.code == .cancelled {
            fetch.continuation.resume(throwing: ModelStoreError.io("paused"))
        } else if let urlError, Self.offlineCodes.contains(urlError.code) {
            fetch.continuation.resume(throwing: ModelStoreError.offline)
        } else {
            fetch.continuation.resume(throwing: ModelStoreError.io(error.localizedDescription))
        }
    }

    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
    ]

    static func contentRangeStart(_ response: HTTPURLResponse) -> Int64? {
        // "bytes 100-199/1000"
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
            let bytes = value.split(separator: " ").last,
            let start = bytes.split(separator: "-").first
        else { return nil }
        return Int64(start)
    }

    static func append(_ source: URL, to dest: URL) throws {
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.moveItem(at: source, to: dest)
            return
        }
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        try out.seekToEnd()
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
    }

    // MARK: Network + disk helpers

    private func startPathMonitorIfNeeded() {
        guard monitorsNetwork else { return }
        let monitor: NWPathMonitor? = inner.withLock { s in
            guard s.pathMonitor == nil else { return nil }
            let m = NWPathMonitor()
            s.pathMonitor = m
            return m
        }
        guard let monitor else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied else { return }
            // Auto-retry only a download the user started that stopped for lack of network.
            guard case .failed(.offline, _) = self.state, self.inner.withLock({ $0.wantsDownload }) else { return }
            self.download()
        }
        monitor.start(queue: DispatchQueue(label: "Hunch.model.path", qos: .utility))
    }

    private func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    static func volumeCapacity(_ dir: URL) -> Int64? {
        var probe = dir
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: URLSession delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak let store: ModelStore?
    init(store: ModelStore) { self.store = store }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        store?.didWrite(totalBytesWritten: totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        store?.didFinish(location: location, response: downloadTask.response)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        store?.didComplete(error: error)
    }
}

// MARK: Stat + verification cache

struct FileStat: Equatable, Codable {
    let size: Int64
    let mtime: Double
    let inode: UInt64

    /// `stat` follows symlinks (the HF cache links snapshots to blobs).
    init?(_ url: URL) {
        var st = Darwin.stat()
        guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        size = Int64(st.st_size)
        mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        inode = UInt64(st.st_ino)
    }
}

/// `Models/.verified.json`: path → (stat, verdict). A changed size, mtime or inode drops the verdict.
struct VerifiedCache: Codable {
    struct Entry: Codable { let stat: FileStat; let ok: Bool }
    var entries: [String: Entry] = [:]

    func verdict(_ url: URL, _ st: FileStat) -> Bool? {
        guard let e = entries[url.path], e.stat == st else { return nil }
        return e.ok
    }

    mutating func record(_ url: URL, _ st: FileStat, ok: Bool) {
        entries[url.path] = Entry(stat: st, ok: ok)
    }

    static func load(from url: URL) -> VerifiedCache {
        guard let data = try? Data(contentsOf: url),
            let cache = try? JSONDecoder().decode(VerifiedCache.self, from: data)
        else { return VerifiedCache() }
        return cache
    }

    func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}
