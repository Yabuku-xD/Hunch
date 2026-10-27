import AppKit
import HunchCore
import Observation
import ServiceManagement
import SwiftUI

/// Content tiers the Search pane switches (Settings › Search › Contents). Stored per tier in `content.<raw>`.
enum ContentToggle: String, CaseIterable, Sendable {
    case documents, images, speech, video, meaning

    var title: String {
        switch self {
        case .documents: "Text in documents"
        case .images: "Text in images"
        case .speech: "Speech in recordings"
        case .video: "Video frames"
        case .meaning: "Meaning"
        }
    }

    var key: String { "content." + rawValue }
}

/// State behind the four Settings panes. Live values (status, model state) are only observed while a pane that shows
/// them is visible (`onAppear`/`onDisappear`, M4).
@MainActor
@Observable
final class SettingsModel {
    let recorder: ShortcutRecorderModel
    private(set) var roots: [URL] = []
    /// Roots that no longer exist, computed on reload (never `fileExists` in a body).
    private(set) var missingRoots: Set<URL> = []
    var selectedRoot: URL?
    private(set) var launchAtLogin = false
    private(set) var loginNote: String?
    private(set) var isRebuilding = false
    private(set) var verifyNote: String?
    private(set) var modelState: ModelState
    private(set) var contents: [ContentToggle: Bool] = [:]

    @ObservationIgnored let admin: IndexAdmin?
    @ObservationIgnored let status: StatusModel
    @ObservationIgnored let models: any ModelProviding
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var modelTask: Task<Void, Never>?
    /// Opens the guide (Settings › General › Help).
    @ObservationIgnored var onWelcome: (() -> Void)?

    init(
        admin: IndexAdmin?, status: StatusModel, models: any ModelProviding, recorder: ShortcutRecorderModel,
        defaults: UserDefaults = AppDefaults.store
    ) {
        self.admin = admin
        self.status = status
        self.models = models
        self.recorder = recorder
        self.defaults = defaults
        modelState = models.state
    }

    var userRoots: [URL] { roots }

    func reload() {
        let next = admin?.userRoots ?? []
        if next != roots { roots = next }
        missingRoots = Set(next.filter { !FileManager.default.fileExists(atPath: $0.path) })
        modelState = models.state
        let master = admin?.contentIndexing ?? true
        for t in ContentToggle.allCases {
            contents[t] = master && (defaults.object(forKey: t.key) as? Bool ?? true)
        }
        readLoginStatus()
    }

    // MARK: Live model state (only while Search/Index is visible)

    func startModelUpdates() {
        guard modelTask == nil else { return }
        let stream = models.states()
        modelTask = Task { [weak self] in
            for await state in stream {
                guard let self else { return }
                if state != self.modelState { self.modelState = state }
            }
        }
    }

    func stopModelUpdates() {
        modelTask?.cancel()
        modelTask = nil
    }

    var modelIsMissing: Bool {
        switch modelState {
        case .ready: false
        default: true
        }
    }

    // MARK: Contents

    func isOn(_ t: ContentToggle) -> Bool { contents[t] ?? true }

    func set(_ t: ContentToggle, _ on: Bool) {
        contents[t] = on
        defaults.set(on, forKey: t.key)
        // HunchCore has one content switch today; it stays on while any tier is on.
        let any = ContentToggle.allCases.contains { contents[$0] ?? true }
        if let admin, admin.contentIndexing != any { Task { await admin.setContentIndexing(any) } }
    }

    /// "Done", "Reading 40%", "Off".
    func caption(_ t: ContentToggle) -> String {
        if !isOn(t) { return "Off" }
        if t == .meaning, modelIsMissing { return "Needs the model. Set it up in Index." }
        let tier: ContentTierStatus.Tier? =
            switch t {
            case .documents: .documents
            case .images: .images
            case .speech: .speech
            case .meaning: .meaning
            case .video: nil
            }
        guard let tier, let s = status.tiers.first(where: { $0.tier == tier }), s.done < s.total, s.total > 0 else {
            return "Done"
        }
        return "Reading \(Int(Double(s.done) / Double(s.total) * 100))%"
    }

    // MARK: Launch at login

    private func readLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: launchAtLogin = true; loginNote = nil
        case .requiresApproval: launchAtLogin = false; loginNote = "Allow in System Settings › Login Items."
        case .notFound: launchAtLogin = false; loginNote = "Available when run from the app bundle."
        case .notRegistered: launchAtLogin = false; loginNote = nil
        @unknown default: launchAtLogin = false; loginNote = nil
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginNote = error.localizedDescription
        }
        let note = loginNote
        readLoginStatus()
        if loginNote == nil, SMAppService.mainApp.status != (on ? .enabled : .notRegistered) { loginNote = note }
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: Folders

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to search"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// Folders dropped from Finder or picked in the open panel; directories only, no duplicates.
    @discardableResult
    func add(_ urls: [URL]) -> Bool {
        let dirs = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let added = dirs.filter { url in !roots.contains { $0.standardizedFileURL == url.standardizedFileURL } }
        guard !added.isEmpty else { return false }
        save(roots + added)
        return true
    }

    func removeSelected() {
        guard let selectedRoot else { return }
        save(roots.filter { $0 != selectedRoot })
        self.selectedRoot = nil
    }

    private func save(_ next: [URL]) {
        roots = next
        missingRoots = Set(next.filter { !FileManager.default.fileExists(atPath: $0.path) })
        guard let admin else { return }
        Task { await admin.setRoots(Crawler.appRoots + next) }
    }

    // MARK: Index

    func verify() {
        guard let admin, !isRebuilding else { return }
        isRebuilding = true
        verifyNote = nil
        Task {
            let r = await admin.verifyIndex()
            isRebuilding = false
            let fixed = r.added + r.changed + r.moved + r.removed
            verifyNote = fixed == 0 ? "Index is up to date." : "Updated \(fixed.formatted()) items."
        }
    }

    /// F12: a visible, destructive Reset with the confirmation alert (the ⌥-click path is gone).
    func reset() {
        guard let admin, !isRebuilding else { return }
        let alert = NSAlert()
        alert.messageText = "Reset the index?"
        alert.informativeText =
            "\(AppInfo.name) forgets everything it indexed and reads your folders again. "
            + "Search works by name meanwhile; contents take a while to come back."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset Index")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isRebuilding = true
        verifyNote = nil
        Task {
            await admin.resetIndex()
            isRebuilding = false
            verifyNote = "Index reset. Reading folders again."
        }
    }

    // MARK: Model

    func chooseModelFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose \(ModelFile.text.fileName) and, for images, \(ModelFile.projector.fileName)"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            do { _ = try await models.importFiles(urls) } catch {
                verifyNote = "Those files aren't the EmbeddingGemma 2 model."
            }
        }
    }

    func confirmRemoveModel() {
        let alert = NSAlert()
        alert.messageText = "Remove the model?"
        alert.informativeText = "Meaning search turns off until you download it again."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { try? await models.remove() }
    }

    func showModelInFinder() {
        if case .ready(let m) = modelState {
            NSWorkspace.shared.activateFileViewerSelecting([m.text])
        } else {
            NSWorkspace.shared.open(models.modelsDirectory)
        }
    }
}
