import AppKit
import HunchCore
import Observation

/// Content indexing progress per tier, for the band status. HunchCore's `IndexStatus` covers names + name vectors;
/// tiers come from the content pipeline once it reports them (the fixture fills them in today).
struct ContentTierStatus: Sendable, Equatable {
    enum Tier: Sendable, Equatable {
        case documents, images, speech, meaning
    }

    var tier: Tier
    var done: Int
    var total: Int
}

/// Everything the panel and Settings need from the index besides search: status, pins, recents, roots, rebuild.
/// `BackendIndexAdmin` wraps the real `SearchBackend`; DEBUG fixtures use an in-memory one.
@MainActor
protocol IndexAdmin: AnyObject {
    func statusUpdates() -> AsyncStream<IndexStatus>
    func contentTiers() -> [ContentTierStatus]
    var roots: [URL] { get }
    func setRoots(_ roots: [URL]) async
    /// Stat-only verify of every root; writes only what differs.
    func verifyIndex() async -> VerifyReport
    /// Destructive: forgets everything and crawls again (⌥-click + confirm only).
    func resetIndex() async
    /// P17: range-delete `item` (and everything below a folder) and keep it out of later crawls.
    func exclude(_ item: Item) async
    /// Read `item`'s contents now (preview).
    func indexNow(_ item: Item)
    /// P8: catalog changes, to refresh stale visible results.
    func changes() -> AsyncStream<IndexChangeBatch>
    func isPinned(_ item: Item) -> Bool
    func pin(_ item: Item)
    func unpin(_ item: Item)
    func recordOpen(_ item: Item)
    func setPanelVisible(_ visible: Bool)
    var modelDescription: String { get }
    /// The meaning model (v4 §2): `ModelStore.shared`, or DEBUG `FixtureModelStore` under `HUNCH_MODEL_STATE`.
    var models: any ModelProviding { get }
    /// Read file contents at all (Settings › Search › Contents).
    var contentIndexing: Bool { get }
    func setContentIndexing(_ on: Bool) async
}

extension IndexAdmin {
    /// Roots the user chose (the app folders are always included and not counted).
    var userRoots: [URL] {
        let apps = Set(Crawler.appRoots.map(\.standardizedFileURL.path))
        return roots.filter { !apps.contains($0.standardizedFileURL.path) }
    }
    var userRootsCount: Int { userRoots.count }
}

/// Picks the model provider once at launch.
enum ModelProviders {
    @MainActor static func make() -> any ModelProviding {
        #if DEBUG
        if let spec = DebugOverrides.modelState, let fixture = FixtureModelStore(spec: spec) { return fixture }
        #endif
        return ModelStore.shared
    }
}

/// DEBUG `HUNCH_INDEX_STATE` (idle, crawling, content:40, meaning:42, unreadable:2, cloud:1204): a fixed status for the
/// band, footer, menu and Index pane.
enum IndexStateFixture {
    static func make(_ spec: String) -> (IndexStatus, [ContentTierStatus])? {
        let parts = spec.split(separator: ":").map(String.init)
        let n = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        switch parts.first {
        case "idle": return (IndexStatus(phase: .idle, items: 80_112, embedded: 80_112, total: 80_112), [])
        case "crawling": return (IndexStatus(phase: .crawling, items: 12_340), [])
        case "content":
            return (
                IndexStatus(phase: .idle, items: 80_112), [ContentTierStatus(tier: .documents, done: n, total: 100)]
            )
        case "meaning":
            return (IndexStatus(phase: .idle, items: 80_112), [ContentTierStatus(tier: .meaning, done: n, total: 100)])
        case "unreadable":
            let paths = (0..<max(n, 1)).map {
                NSHomeDirectory() + ["/Library/Mail", "/Library/Messages", "/Library/Safari"][$0 % 3]
            }
            return (IndexStatus(phase: .idle, items: 80_112, unreadable: paths), [])
        case "cloud": return (IndexStatus(phase: .idle, items: 80_112, cloudOnly: n), [])
        case "missing": return (IndexStatus(phase: .modelMissing, items: 80_112), [])
        default: return nil
        }
    }
}

@MainActor
final class BackendIndexAdmin: IndexAdmin {
    private let backend: SearchBackend
    let models: any ModelProviding
    private var modelTask: Task<Void, Never>?

    init(backend: SearchBackend, models: any ModelProviding) {
        self.backend = backend
        self.models = models
        // F9: a model that becomes ready (download done, import, found later) attaches without a relaunch.
        let stream = models.states()
        modelTask = Task { [backend] in
            for await state in stream {
                if case .ready(let model) = state { await backend.attachModel(model) }
            }
        }
    }

    func statusUpdates() -> AsyncStream<IndexStatus> {
        #if DEBUG
        if let spec = DebugOverrides.indexState, let (status, _) = IndexStateFixture.make(spec) {
            return AsyncStream { $0.yield(status) }
        }
        #endif
        return backend.indexStatusUpdates()
    }
    func contentTiers() -> [ContentTierStatus] {
        #if DEBUG
        if let spec = DebugOverrides.indexState, let (_, tiers) = IndexStateFixture.make(spec) { return tiers }
        #endif
        return []
    }
    var contentIndexing: Bool { backend.settings.contentIndexing }
    func setContentIndexing(_ on: Bool) async {
        var next = backend.settings
        next.contentIndexing = on
        await backend.update(settings: next)
    }
    var roots: [URL] { backend.settings.roots }
    func setRoots(_ roots: [URL]) async {
        // Keep exclusions and the content switch; only the roots change (the backend diffs the rest).
        var next = backend.settings
        next.roots = roots
        await backend.update(settings: next)
    }
    func verifyIndex() async -> VerifyReport { await backend.verifyIndex() }
    func resetIndex() async { await backend.resetIndex() }
    func exclude(_ item: Item) async { await backend.exclude(item.path) }
    func indexNow(_ item: Item) { if item.kind == .file { backend.indexNow(item.path) } }
    func changes() -> AsyncStream<IndexChangeBatch> { backend.changes() }
    func isPinned(_ item: Item) -> Bool { backend.isPinned(item.path) }
    func pin(_ item: Item) { backend.pin(item.path) }
    func unpin(_ item: Item) { backend.unpin(item.path) }
    func recordOpen(_ item: Item) { backend.recordOpen(item) }
    func setPanelVisible(_ visible: Bool) { backend.setPanelVisible(visible) }
    var modelDescription: String {
        guard let url = backend.modelURL else { return "No model: names and contents only" }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Bundle paths of running apps. Republishes only when the set changes (launch/terminate notifications).
@MainActor
@Observable
final class RunningApps {
    static let shared = RunningApps()
    private(set) var paths: Set<String> = []

    private init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RunningApps.shared.refresh() }
            }
        }
    }

    func isRunning(_ path: String) -> Bool { paths.contains(Self.standardize(path)) }

    func application(at path: String) -> NSRunningApplication? {
        let target = Self.standardize(path)
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL.map { Self.standardize($0.path) } == target
        }
    }

    private func refresh() {
        let next = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL.map { Self.standardize($0.path) } })
        if next != paths { paths = next }
    }

    private static func standardize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        if p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

/// "Open in Preview" style verbs: the app macOS opens the file with (the user's default for its type, or the
/// file's own "Open with" choice). Cached per file while the panel is open; cleared on each show, so a default
/// changed in Finder shows up the next time.
@MainActor
enum DefaultApp {
    private static var names: [String: String] = [:]

    static func reset() { names.removeAll(keepingCapacity: true) }

    static func name(for path: String) -> String? {
        if let hit = names[path] { return hit.isEmpty ? nil : hit }
        let app = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path))
        let name =
            app.map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 } ?? ""
        if app != nil { names[path] = name }
        return name.isEmpty ? nil : name
    }

    /// Apps that can open `url`, default first, deduplicated by bundle id, at most `limit`.
    static func candidates(for url: URL, limit: Int = 6) -> [URL] {
        let workspace = NSWorkspace.shared
        var seen = Set<String>()
        var out: [URL] = []
        let all =
            [workspace.urlForApplication(toOpen: url)].compactMap { $0 } + workspace.urlsForApplications(toOpen: url)
        for app in all {
            let id = Bundle(url: app)?.bundleIdentifier ?? app.path
            guard seen.insert(id).inserted else { continue }
            out.append(app)
            if out.count == limit { break }
        }
        return out
    }
}
