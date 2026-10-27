import AppKit
import Observation
import SwiftUI

/// The guide's step machine (v4 §4), pure and unit-tested: next/back/set up later/resume/complete, persisted in
/// `onboarding.step` and `onboarding.completed`.
struct OnboardingFlow: Equatable {
    static let stepCount = 5
    static let stepKey = "onboarding.step"
    static let completedKey = "onboarding.completed"
    static let seenKey = "onboarding.seen"

    private(set) var step: Int
    /// +1 forward, −1 back: the slide direction of the step transition.
    private(set) var direction: Int = 1
    private(set) var completed: Bool
    /// The guide has been dismissed with Set Up Later before: show "Don't Show Again".
    let showsDontShowAgain: Bool

    /// Resume at the saved step (first launch and Set Up Later), or step 1 when re-opened from a menu.
    init(defaults: UserDefaults, reopened: Bool = false, forcedStep: Int? = nil) {
        completed = defaults.bool(forKey: Self.completedKey)
        let saved = defaults.integer(forKey: Self.stepKey)
        let start = forcedStep ?? (reopened ? 1 : saved)
        step = min(max(start, 1), Self.stepCount)
        showsDontShowAgain = !reopened && !completed && defaults.bool(forKey: Self.seenKey)
    }

    var isFirst: Bool { step == 1 }
    var isLast: Bool { step == Self.stepCount }

    mutating func next(_ defaults: UserDefaults) {
        guard step < Self.stepCount else { return }
        direction = 1
        step += 1
        defaults.set(step, forKey: Self.stepKey)
    }

    mutating func back(_ defaults: UserDefaults) {
        guard step > 1 else { return }
        direction = -1
        step -= 1
        defaults.set(step, forKey: Self.stepKey)
    }

    /// Set Up Later (Esc, ⌘.): closes without completing; the guide comes back at this step next launch.
    func setUpLater(_ defaults: UserDefaults) {
        defaults.set(step, forKey: Self.stepKey)
        defaults.set(true, forKey: Self.seenKey)
    }

    /// Done, the real hotkey on step 5, or Don't Show Again.
    mutating func complete(_ defaults: UserDefaults) {
        completed = true
        defaults.set(true, forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.stepKey)
    }

    /// First launch shows the guide only when it is not complete, not a login-item launch and not scripted.
    static func showsAtLaunch(defaults: UserDefaults, isLoginItem: Bool, scripted: Bool) -> Bool {
        !defaults.bool(forKey: completedKey) && !isLoginItem && !scripted
    }
}

/// One row of step 3's checklist.
struct FolderChoice: Identifiable, Equatable {
    enum Count: Equatable { case counting, files(Int), many, protected }
    enum Access: Equatable { case unknown, granted, denied }

    let url: URL
    let name: String
    var checked: Bool
    let isHome: Bool
    /// macOS asks before the first read (Desktop, Documents, Downloads and, through them, Home).
    let isProtected: Bool
    var count: Count
    var access: Access = .unknown
    var id: URL { url }

    /// Desktop ☑, Documents ☑, Downloads ☑, Pictures ☐, Movies ☐, Music ☐, Home folder (everything) ☐.
    static func defaults(home: URL) -> [FolderChoice] {
        func row(_ sub: String, _ name: String, _ on: Bool, protected: Bool) -> FolderChoice {
            FolderChoice(
                url: home.appendingPathComponent(sub, isDirectory: true), name: name, checked: on, isHome: false,
                isProtected: protected, count: protected ? .protected : .counting)
        }
        return [
            row("Desktop", "Desktop", true, protected: true),
            row("Documents", "Documents", true, protected: true),
            row("Downloads", "Downloads", true, protected: true),
            row("Pictures", "Pictures", false, protected: false),
            row("Movies", "Movies", false, protected: false),
            row("Music", "Music", false, protected: false),
            FolderChoice(
                url: home, name: "Home folder (everything)", checked: false, isHome: true, isProtected: true,
                count: .protected),
        ]
    }

    /// The roots to index: the app folders plus Home, or plus each checked folder.
    static func roots(_ rows: [FolderChoice], appRoots: [URL]) -> [URL] {
        if let home = rows.first(where: { $0.isHome && $0.checked }) { return appRoots + [home.url] }
        return appRoots + rows.filter { $0.checked && !$0.isHome }.map(\.url)
    }

    var countText: String {
        switch count {
        case .counting: "…"
        case .files(let n): "≈ \(Self.rounded(n).formatted()) files"
        case .many: "many files"
        case .protected: "–"
        }
    }

    /// Two significant digits for big counts ("≈ 42,000"), exact below 1,000.
    static func rounded(_ n: Int) -> Int {
        guard n >= 1_000 else { return n }
        let magnitude = Int(pow(10, Double(Int(log10(Double(n))) - 1)))
        return (n / magnitude) * magnitude
    }
}

/// The guide's state: the flow, the folder checklist, the hotkey test line and the model state.
@MainActor
@Observable
final class OnboardingModel {
    private(set) var flow: OnboardingFlow
    private(set) var folders: [FolderChoice]
    private(set) var hotKeyWorks = false
    private(set) var isTouchingFolders = false
    private(set) var modelState: ModelState
    /// Steps whose entrance has played (M3.12 plays once per step): a step not in here renders at opacity 0 /
    /// scale 0.98 for its first frame, then animates in when `enter` inserts it.
    private(set) var appeared = Set<Int>()
    /// True for 100 ms on a real hotkey press during step 5 (keycap press motion, M3.14).
    private(set) var keycapPressed = false
    var showsFDA = false

    let recorder: ShortcutRecorderModel
    @ObservationIgnored let models: any ModelProviding
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let admin: IndexAdmin?
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored private var modelTask: Task<Void, Never>?
    @ObservationIgnored var onClose: (() -> Void)?

    init(
        recorder: ShortcutRecorderModel, models: any ModelProviding, admin: IndexAdmin?,
        defaults: UserDefaults = AppDefaults.store, reopened: Bool, forcedStep: Int? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.recorder = recorder
        self.models = models
        self.admin = admin
        self.defaults = defaults
        flow = OnboardingFlow(defaults: defaults, reopened: reopened, forcedStep: forcedStep)
        var rows = FolderChoice.defaults(home: home)
        // Re-opened: the current roots fill the checklist.
        if reopened, let current = admin?.userRoots, !current.isEmpty {
            let paths = Set(current.map(\.standardizedFileURL.path))
            for i in rows.indices { rows[i].checked = paths.contains(rows[i].url.standardizedFileURL.path) }
            for url in current where !rows.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                rows.insert(
                    FolderChoice(
                        url: url, name: FileManager.default.displayName(atPath: url.path), checked: true,
                        isHome: false, isProtected: false, count: .counting), at: rows.count - 1)
            }
        }
        folders = rows
        modelState = models.state
        #if DEBUG
        if DebugOverrides.hotKeyState == "works" { hotKeyWorks = true }
        // HUNCH_TCC_RESULT shows the post-Continue row state (as after Back from step 4): Continue itself advances at once.
        if let fake = DebugOverrides.tccResult {
            for i in folders.indices where folders[i].checked && (folders[i].isProtected || folders[i].isHome) {
                folders[i].access = fake == "granted" ? .granted : .denied
            }
        }
        #endif
    }

    var step: Int { flow.step }

    func enter(_ step: Int) {
        if !appeared.contains(step) { appeared.insert(step) }
    }

    // MARK: Lifecycle (live work only while the guide is open)

    func start() {
        let stream = models.states()
        modelTask = Task { [weak self] in
            for await state in stream {
                guard let self else { return }
                if state != self.modelState { self.modelState = state }
            }
        }
        countFolders()
    }

    func stop() {
        modelTask?.cancel()
        countTask?.cancel()
        recorder.stop()
    }

    // MARK: Navigation

    var primaryTitle: String {
        switch flow.step {
        case 1: "Get Started"
        case 4:
            switch modelState {
            case .missing: ModelCopy.downloadButton
            case .ready(let m) where m.textSource == .digUp || m.textSource == .huggingFaceCache: "Use It"
            case .failed: "Try Again"
            default: "Continue"
            }
        case 5: "Done"
        default: "Continue"
        }
    }

    var primaryDisabled: Bool { recorder.isRecording || isTouchingFolders }

    func primary() {
        switch flow.step {
        case 3: Task { await applyFolders() }
        case 4:
            switch modelState {
            case .missing, .failed: models.download()  // stays on step 4; the card shows the progress
            default: flow.next(defaults)
            }
        case 5: complete()
        default: flow.next(defaults)
        }
    }

    func back() { flow.back(defaults) }

    func setUpLater() {
        flow.setUpLater(defaults)
        onClose?()
    }

    /// "Don't Show Again": completes with the defaults applied (app roots only, model left as is).
    func dontShowAgain() {
        if let admin { Task { await admin.setRoots(AppRoots.all + admin.userRoots) } }
        complete()
    }

    func complete() {
        flow.complete(defaults)
        onClose?()
    }

    /// Step 4's secondary: Text Only continues with names and contents.
    func textOnly() { flow.next(defaults) }

    // MARK: Hotkey (step 2 test line, step 5 real press)

    /// Called by the Carbon handler while the guide is open. Returns true when the press is consumed.
    func hotKeyPressed(isKey: Bool) -> Bool {
        switch flow.step {
        case 2 where isKey:
            hotKeyWorks = true
            return true
        case 5:
            keycapPressed = true
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                self?.keycapPressed = false
                try? await Task.sleep(for: .milliseconds(100))  // the keycaps' release
                self?.complete()
                NotificationCenter.default.post(name: .onboardingWantsPanel, object: nil)
            }
            return true
        default:
            return false
        }
    }

    // MARK: Folders (step 3)

    func toggle(_ id: URL) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].checked.toggle()
    }

    func isDisabled(_ row: FolderChoice) -> Bool {
        !row.isHome && folders.contains { $0.isHome && $0.checked }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !folders.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL })
        {
            folders.insert(
                FolderChoice(
                    url: url, name: FileManager.default.displayName(atPath: url.path), checked: true,
                    isHome: false, isProtected: false, count: .counting), at: folders.count - 1)
        }
        countFolders()
    }

    /// Stat-only counts on a utility task, ≤ 300 ms per folder. Never touches a protected folder before Continue.
    private func countFolders() {
        let targets = folders.filter { $0.count == .counting }.map(\.url)
        guard !targets.isEmpty else { return }
        #if DEBUG
        if DebugOverrides.fixtureFolderCounts {
            let fixed: [String: FolderChoice.Count] = [
                "Desktop": .files(312), "Documents": .files(18_940),
                "Downloads": .files(4_211), "Pictures": .many,
                "Movies": .files(86), "Music": .files(1_204),
            ]
            for i in folders.indices { folders[i].count = fixed[folders[i].url.lastPathComponent] ?? folders[i].count }
            return
        }
        #endif
        countTask?.cancel()
        countTask = Task { [weak self] in
            for url in targets {
                let count = await Task.detached(priority: .utility) { FolderCounter.count(url, budget: 0.3) }.value
                guard let self, !Task.isCancelled else { return }
                if let i = self.folders.firstIndex(where: { $0.url == url }) { self.folders[i].count = count }
            }
        }
    }

    /// Continue on step 3: touch each checked protected folder one at a time (the macOS alerts appear one after another),
    /// mark each row, set the roots, then advance even when access was denied.
    func applyFolders() async {
        isTouchingFolders = true
        let checked = folders.indices.filter { folders[$0].checked && (folders[$0].isProtected || folders[$0].isHome) }
        for i in checked {
            let url = folders[i].url
            #if DEBUG
            if let fake = DebugOverrides.tccResult {
                folders[i].access = fake == "granted" ? .granted : .denied
                continue
            }
            Measure.emit("tcc_touch path=\(url.path)")
            #endif
            let ok = await Task.detached(priority: .userInitiated) {
                (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
            }.value
            folders[i].access = ok ? .granted : .denied
        }
        isTouchingFolders = false
        let roots = FolderChoice.roots(folders, appRoots: AppRoots.all)
        if let admin { await admin.setRoots(roots) }
        flow.next(defaults)
    }

    var hasDeniedFolder: Bool { folders.contains { $0.access == .denied } }
}

extension Notification.Name {
    /// The real hotkey completed the guide on step 5: open the panel.
    static let onboardingWantsPanel = Notification.Name("bs.onboardingWantsPanel")
}

/// Stat-only file count for step 3, with a time budget ("many files" past it).
enum FolderCounter {
    static func count(_ url: URL, budget: TimeInterval) -> FolderChoice.Count {
        let deadline = Date().addingTimeInterval(budget)
        guard
            let e = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [],
                options: [.skipsPackageDescendants, .skipsHiddenFiles])
        else {
            return .files(0)
        }
        var n = 0
        while e.nextObject() != nil {
            n += 1
            if n & 255 == 0, Date() > deadline { return .many }
        }
        return .files(n)
    }
}
