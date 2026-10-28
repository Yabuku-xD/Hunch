import Foundation
import Synchronization
import os

/// Everything behind the panel, wired end to end (owner: integrate).
///
/// `init` is instant, so the panel is usable at once (the name index starts empty). `start()` then, in the
/// background: opens the SQLite catalog + mmapped vector store, fills the name index from the catalog (plus saved
/// frecency), enables the semantic leg with a lazily loaded model (`ManagedEmbedder`: loads on first semantic need,
/// unloads after 5 idle minutes) and runs `IndexCoordinator` over `IndexSettings.roots` (FSEvents replay or first
/// crawl, then embedding catch-up). Embedding and the content pipeline are paused while the panel is visible.
/// No model found → name-only mode with `IndexStatus.Phase.modelMissing`; nothing crashes.
public final class SearchBackend: IndexStatusProviding {
    public let nameIndex = NameIndex()
    public let engine: HybridSearchEngine
    public let directory: URL
    /// The embedding model in use, nil = name-only mode. Set at init or later by `attachModel(_:)`.
    public var modelURL: URL? { state.withLock { $0.modelURL } }
    /// The vision projector (mmproj) for image vectors, nil = text meaning only.
    public var projectorURL: URL? { state.withLock { $0.projectorURL } }
    /// The lazily loaded embedder (nil without a model). Shared with the content pipeline.
    public var embedder: ManagedEmbedder? { state.withLock { $0.embedder } }

    private struct State {
        var modelURL: URL?
        var projectorURL: URL?
        var embedder: ManagedEmbedder?
        var catalog: Catalog?
        var vectors: VectorStore?
        var coordinator: IndexCoordinator?
        var settings: IndexSettings
        var pipeline: (any ContentPipeline)?
        var content: ContentRuntime?
        var started = false
        var panelVisible = false
        var activity: IndexCoordinator.Activity = .idle
        var status = IndexStatus()
        var subscribers: [UUID: AsyncStream<IndexStatus>.Continuation] = [:]
        var reached: Set<Phase> = []
        var changeSubscribers: [UUID: AsyncStream<IndexChangeBatch>.Continuation] = [:]
        var generation: UInt64 = 0
        var unreadable: [String] = []
        var cloudOnly = 0
        var lastVerify: VerifyReport?
        var waiters: [(Phase, CheckedContinuation<Void, Never>)] = []
    }

    public enum Phase: Sendable, Hashable {
        /// The name index holds everything the catalog had on disk.
        case namesLoaded
        /// First crawl or FSEvents replay applied (embedding may still be catching up).
        case caughtUp
        /// Caught up and the content queue drained (tests, tools). Returns at once when content indexing is off.
        case contentIdle
    }
    private let state: Mutex<State>
    /// Read on every result row; kept separate from `state` so lookups never wait on startup work.
    private let catalogRef = CatalogRef()
    private let appsCache = Mutex<(catalog: Catalog, written: Int, apps: [Item])?>(nil)
    private final class CatalogRef: Sendable {
        let value = Mutex<Catalog?>(nil)
        func get() -> Catalog? { value.withLock { $0 } }
        func set(_ c: Catalog) { value.withLock { $0 = c } }
    }
    /// Explicit roots from `init` (tests, tools) override the persisted settings for this session.
    private let rootsOverride: [URL]?
    private let dimension: Int
    private static let log = Logger(subsystem: "dev.hunch", category: "backend")

    /// - Parameters:
    ///   - roots: index these instead of the persisted `IndexSettings` (not persisted).
    ///   - modelURL: the gguf to embed with; nil = name-only. Defaults to `ModelStore.shared.resolve()?.text`.
    ///   - projectorURL: the mmproj for image vectors; nil = no image vectors.
    ///   - idleUnload: release the model after this long without a query or pending embedding.
    public init(
        directory: URL = Paths.appSupport,
        roots: [URL]? = nil,
        modelURL: URL? = ModelStore.shared.resolve()?.text,
        projectorURL: URL? = ModelStore.shared.resolve()?.projector,
        dimension: Int = 256,
        idleUnload: Duration = .seconds(300)
    ) {
        self.directory = directory
        self.rootsOverride = roots
        self.dimension = dimension
        self.idleUnload = idleUnload
        let ref = catalogRef
        let embedder = modelURL.map { Self.makeEmbedder($0, dimension: dimension, idleUnload: idleUnload, ref: ref) }
        state = Mutex(
            State(
                modelURL: modelURL, projectorURL: modelURL == nil ? nil : projectorURL,
                embedder: embedder,
                settings: IndexSettings(roots: roots ?? IndexSettings.default.roots),
                status: IndexStatus(phase: modelURL == nil ? .modelMissing : .idle)))
        engine = HybridSearchEngine(names: nameIndex, lookup: { id in ref.get()?.item(id) })
        engine.attach(suggestions: { [weak self] in self?.suggestions() ?? [] })
        engine.attach(scope: { folder, limit in Array(((try? ref.get()?.items(under: folder)) ?? []).prefix(limit)) })
    }

    private let idleUnload: Duration

    private static func makeEmbedder(
        _ url: URL, dimension: Int, idleUnload: Duration,
        ref: CatalogRef
    ) -> ManagedEmbedder {
        ManagedEmbedder(
            modelURL: url, dimension: dimension, idleTimeout: idleUnload,
            keepAlive: { ((try? ref.get()?.pendingCount()) ?? 0) > 0 })
    }

    /// O4: switches a running backend from name-only (or another model) to `model`. Idempotent. Creates the
    /// embedder, gives it to the engine, rebuilds the content runtime with the embedder + projector, restarts the
    /// coordinator so pending names get vectors, leaves `.modelMissing` and republishes. Never blocks the caller
    /// on the crawl: the coordinator restart runs detached.
    public func attachModel(_ model: ResolvedModel) async {
        let ref = catalogRef
        let (changed, embedder, vectors): (Bool, ManagedEmbedder, VectorStore?) = state.withLock { s in
            if let e = s.embedder, s.modelURL == model.text, s.projectorURL == model.projector {
                return (false, e, s.vectors)
            }
            let e =
                (s.modelURL == model.text ? s.embedder : nil)
                ?? Self.makeEmbedder(model.text, dimension: dimension, idleUnload: idleUnload, ref: ref)
            s.modelURL = model.text
            s.projectorURL = model.projector
            s.embedder = e
            if case .modelMissing = s.activity { s.activity = .idle }
            return (true, e, s.vectors)
        }
        guard changed else {
            publishStatus()
            return
        }
        if let vectors {
            engine.attach(embedder: embedder)
            await embedder.observe { loaded in
                if !loaded { Task { await vectors.releaseResidentPages() } }
            }
        }
        // Content runtime: rebuild it so the pipeline embeds chunks and the mmproj embeds images.
        let old: ContentRuntime? = state.withLock { s in
            let c = s.content
            if c != nil {
                s.content = nil
                s.pipeline = nil
            }
            return c
        }
        if let old { await old.stop() }
        if let catalog = catalogRef.get() {
            if old != nil || state.withLock({ $0.settings.contentIndexing }) {
                startContent(catalog: catalog, vectors: vectors)
            }
            let coordinator = state.withLock { s in
                let c = s.coordinator
                s.coordinator = nil
                return c
            }
            if let coordinator {
                Task.detached(priority: .utility) { [self] in
                    await coordinator.stop()
                    await runCoordinator()
                }
            }
        }
        publishStatus()
    }

    public var coordinator: IndexCoordinator? { state.withLock { $0.coordinator } }
    /// The SQLite catalog, once `namesLoaded` is reached.
    public var catalog: Catalog? { catalogRef.get() }
    /// The vector store (name + content chunks), once `namesLoaded` is reached.
    public var vectors: VectorStore? { state.withLock { $0.vectors } }
    /// K1: the content runtime `start()` built (nil while booting, or with `contentIndexing` off).
    public var content: ContentRuntime? { state.withLock { $0.content } }

    /// Kicks off loading + indexing in the background. Idempotent.
    public func start() {
        let first = state.withLock { s in
            defer { s.started = true }
            return !s.started
        }
        guard first else { return }
        Task.detached(priority: .userInitiated) { [self] in await boot() }
    }

    private func boot() async {
        let t0 = ContinuousClock.now
        guard let catalog = openCatalog() else {
            reach(.namesLoaded)
            reach(.caughtUp)
            return
        }
        catalogRef.set(catalog)
        if rootsOverride == nil, let saved = IndexSettings.decode(try? catalog.meta(IndexSettings.metaKey)) {
            state.withLock { $0.settings = saved }
        }

        // I8: names.bin when it matches the catalog exactly, else the fold of every name (then a fresh snapshot).
        let items = catalog.items
        let snapshot = directory.appendingPathComponent("names.bin")
        let generation = NameIndex.snapshotGeneration(of: items)
        if !nameIndex.loadSnapshot(snapshot, generation: generation) {
            nameIndex.replaceAll(items)
            let index = nameIndex
            Task.detached(priority: .utility) { try? index.writeSnapshot(snapshot, generation: generation) }
        }
        applyFrecency(catalog)
        Self.log.info("name index ready: \(self.nameIndex.count) items in \(Self.ms(since: t0)) ms")
        reach(.namesLoaded)

        var vectors: VectorStore?
        do {
            let v = try VectorStore(directory: directory, dimension: dimension)
            if v.didReset { try? catalog.resetEmbedded() }
            vectors = v
        } catch {
            Self.log.error("vector store unavailable: \(String(describing: error), privacy: .public)")
        }
        if let vectors {
            engine.attach(vectors: vectors)
            // Idle (model unloaded after 5 min): also give back the resident vector pages.
            await embedder?.observe { loaded in
                if !loaded { Task { await vectors.releaseResidentPages() } }
            }
        }
        if let embedder, vectors != nil {
            engine.attach(embedder: embedder)  // loads on the first query or pending batch, not now
        } else if modelURL == nil {
            Self.log.error("no embedding model found; name search only")
        }
        state.withLock { s in
            s.catalog = catalog
            s.vectors = vectors
        }
        publishStatus()
        startContent(catalog: catalog, vectors: vectors)

        await runCoordinator()
        Self.log.info("index caught up after \(Self.ms(since: t0)) ms")
        reach(.caughtUp)
    }

    /// Builds a coordinator for the current settings and runs its `start()` (crawl or replay).
    private func runCoordinator() async {
        let (catalog, vectors, roots) = state.withLock { ($0.catalog, $0.vectors, $0.settings.roots) }
        guard let catalog else { return }
        let embedder: (any Embedder)? = vectors == nil ? nil : self.embedder
        let coordinator = IndexCoordinator(
            roots: roots,
            catalog: PersistentCatalog(catalog),
            nameIndex: nameIndex,
            embedder: embedder,
            vectors: vectors,
            onActivity: { [weak self] a in self?.coordinatorDid(a) },
            onChange: { [weak self] upserted, removed in await self?.forwardChanges(upserted, removed) },
            onIndexChanges: { [weak self] changes in self?.broadcast(changes) },
            exclusions: state.withLock { $0.settings.exclusions },
            namesLoaded: true)
        let paused = state.withLock { s in
            s.coordinator = coordinator
            return s.panelVisible
        }
        if paused { await coordinator.pause() }
        await coordinator.start()
        await refreshDetails()
    }

    /// Pulls the slow-changing status details (unreadable folders, last verify, cloud-only count) and republishes.
    private func refreshDetails() async {
        let (coordinator, pipeline) = state.withLock { ($0.coordinator, $0.pipeline) }
        let unreadable = await coordinator?.unreadable
        let verify = await coordinator?.lastVerify
        let cloudOnly = await pipeline?.status.cloudOnly
        state.withLock { s in
            if let unreadable { s.unreadable = unreadable }
            if let verify { s.lastVerify = verify }
            if let cloudOnly { s.cloudOnly = cloudOnly }
        }
        publishStatus()
    }

    /// Suspends until `phase` has been reached (returns at once if it already has).
    public func wait(for phase: Phase) async {
        if phase == .contentIdle {
            await wait(for: .caughtUp)
            await coordinator?.changesDelivered()
            _ = await content?.pipeline.waitUntilIdle()
            return
        }
        await withCheckedContinuation { c in
            let done = state.withLock { s in
                if s.reached.contains(phase) { return true }
                s.waiters.append((phase, c))
                return false
            }
            if done { c.resume() }
        }
    }

    private func reach(_ phase: Phase) {
        let ready = state.withLock { s in
            s.reached.insert(phase)
            let (now, later) = (s.waiters.filter { $0.0 == phase }, s.waiters.filter { $0.0 != phase })
            s.waiters = later
            return now.map(\.1)
        }
        for c in ready { c.resume() }
    }

    private func openCatalog() -> Catalog? {
        let url = directory.appendingPathComponent("index.sqlite")
        do {
            return try Catalog(url: url)
        } catch {
            Self.log.error("catalog open failed (\(String(describing: error), privacy: .public)); starting fresh")
        }
        // Corrupt database: move it (and its vectors) aside and rebuild from a crawl.
        let fm = FileManager.default
        let stamp = Int(Date.now.timeIntervalSince1970)
        for name in ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm", "vectors.f16"] {
            let src = directory.appendingPathComponent(name)
            try? fm.moveItem(at: src, to: directory.appendingPathComponent("\(name).broken-\(stamp)"))
        }
        do {
            return try Catalog(url: url)
        } catch {
            Self.log.fault("catalog unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Replays saved frecency into the name index's ranking boost.
    private func applyFrecency(_ catalog: Catalog) {
        guard let stats = try? catalog.frecencyStats() else { return }
        for (path, s) in stats {
            if let item = try? catalog.item(path: path) { nameIndex.setFrecency(item.id, s.frecency) }
        }
    }

    // MARK: Status

    public var indexStatus: IndexStatus { state.withLock { $0.status } }

    public func indexStatusUpdates() -> AsyncStream<IndexStatus> {
        let (stream, continuation) = AsyncStream<IndexStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let current = state.withLock { s in
            s.subscribers[id] = continuation
            return s.status
        }
        continuation.yield(current)
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    private func coordinatorDid(_ a: IndexCoordinator.Activity) {
        let settled = state.withLock { s in
            defer { s.activity = a }
            return s.activity != a && (a == .idle || a == .paused)
        }
        publishStatus()
        // A crawl/verify/replay just finished: its unreadable list and report are new.
        if settled { Task.detached(priority: .utility) { [weak self] in await self?.refreshDetails() } }
    }

    // MARK: Change stream (P8)

    /// Catalog changes (adds, moves, metadata/content updates, removals) as they are applied, one batch per
    /// coordinator publish, with a strictly increasing `generation`. Each call returns an independent stream.
    public func changes() -> AsyncStream<IndexChangeBatch> {
        let (stream, continuation) = AsyncStream<IndexChangeBatch>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        state.withLock { $0.changeSubscribers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.changeSubscribers.removeValue(forKey: id) }
        }
        return stream
    }

    private func broadcast(_ changes: [IndexChange]) {
        guard !changes.isEmpty else { return }
        let (batch, subscribers) = state.withLock { s in
            s.generation += 1
            return (IndexChangeBatch(generation: s.generation, changes: changes), Array(s.changeSubscribers.values))
        }
        for c in subscribers { c.yield(batch) }
    }

    private func publishStatus() {
        let catalog = catalogRef.get()
        let items = catalog?.count ?? 0
        let pending = (try? catalog?.pendingCount()) ?? 0
        let (status, subscribers): (IndexStatus, [AsyncStream<IndexStatus>.Continuation]) = state.withLock { s in
            let phase: IndexStatus.Phase
            switch s.activity {
            case .crawling: phase = .crawling
            case .catchingUp: phase = .catchingUp
            case .verifying(let r): phase = .verifying(r)
            case .modelMissing: phase = .modelMissing
            case _ where s.modelURL == nil: phase = .modelMissing
            case .embedding: phase = .embedding
            case .paused: phase = pending > 0 ? .paused : .idle
            case .idle: phase = .idle
            }
            let next = IndexStatus(
                phase: phase, items: items, embedded: max(0, items - pending), total: items,
                cloudOnly: s.cloudOnly, unreadable: s.unreadable, lastVerify: s.lastVerify)
            guard next != s.status else { return (next, []) }
            s.status = next
            return (next, Array(s.subscribers.values))
        }
        for c in subscribers { c.yield(status) }
    }

    // MARK: Content pipeline + full text (media team)

    /// K1: builds the content runtime (full text + pipeline sharing this backend's embedder and vectors) and
    /// attaches it before the coordinator runs, so the first crawl already feeds the queue.
    private func startContent(catalog: Catalog, vectors: VectorStore?) {
        guard state.withLock({ $0.settings.contentIndexing && $0.content == nil }) else { return }
        let runtime: ContentRuntime
        do {
            let (embedder, modelURL, projectorURL) = state.withLock { ($0.embedder, $0.modelURL, $0.projectorURL) }
            runtime = try ContentRuntime(
                directory: directory, embedder: vectors == nil ? nil : embedder,
                vectors: vectors, modelURL: vectors == nil ? nil : modelURL,
                projectorURL: projectorURL, dimension: dimension)
        } catch {
            Self.log.error("content index unavailable: \(String(describing: error), privacy: .public)")
            return
        }
        state.withLock { $0.content = runtime }
        attach(contentPipeline: runtime.pipeline, fullText: runtime.fullText)
        Task(priority: .utility) { await runtime.start() }
    }

    /// Plugs in the media team's pipeline and/or full-text index. The pipeline then receives every catalog change
    /// (files only) and follows the panel's pause/resume; the full-text index becomes the engine's second leg.
    public func attach(contentPipeline: (any ContentPipeline)? = nil, fullText: (any FullTextIndexing)? = nil) {
        if let contentPipeline {
            let paused = state.withLock { s in
                s.pipeline = contentPipeline
                return s.panelVisible
            }
            if paused { Task { await contentPipeline.pause() } }
        }
        if let fullText { engine.attach(fullText: fullText) }
    }

    private func forwardChanges(_ upserted: [Item], _ removed: [UInt32]) async {
        guard let pipeline = state.withLock({ $0.pipeline }) else { return }
        if !removed.isEmpty { await pipeline.remove(removed) }
        let files = upserted.filter { $0.kind == .file }
        if !files.isEmpty { await pipeline.enqueue(files) }
    }

    // MARK: Favorites + recents

    /// Pinned items, in user order (pins of deleted files are dropped).
    public func favorites() -> [Item] {
        (try? catalogRef.get()?.favorites()) ?? []
    }

    /// Recently opened items, newest first (entries of deleted files are dropped).
    public func recents(limit: Int = 10) -> [Item] {
        (try? catalogRef.get()?.recents(limit: limit)) ?? []
    }

    public func pin(_ path: String) {
        attempt("pin") { try catalogRef.get()?.pin(path: path) }
    }

    public func unpin(_ path: String) {
        attempt("unpin") { try catalogRef.get()?.unpin(path: path) }
    }

    public func isPinned(_ path: String) -> Bool {
        ((try? catalogRef.get()?.pinnedPaths()) ?? []).contains(path)
    }

    /// New favorites order (paths); pinned paths not listed keep their order after the listed ones.
    public func reorderFavorites(_ paths: [String]) {
        attempt("reorder") { try catalogRef.get()?.reorderPins(paths) }
    }

    /// Favorites, Recents (minus pinned items), then every application A to Z (minus both); empty sections are
    /// omitted.
    public func suggestions(recentLimit: Int = 8) -> [SearchSection] {
        let favorites = favorites()
        let pinned = Set(favorites.map(\.id))
        let recents = recents(limit: recentLimit + pinned.count).filter { !pinned.contains($0.id) }.prefix(recentLimit)
        let shown = pinned.union(recents.map(\.id))
        let apps = applications().filter { !shown.contains($0.id) }
        var out: [SearchSection] = []
        if !favorites.isEmpty {
            out.append(
                SearchSection(
                    kind: .favorites, title: "Favorites",
                    results: favorites.map { SearchResult(item: $0, score: 0, source: .name) }))
        }
        if !recents.isEmpty {
            out.append(
                SearchSection(
                    kind: .recents, title: "Recents",
                    results: recents.map { SearchResult(item: $0, score: 0, source: .name) }))
        }
        if !apps.isEmpty {
            out.append(
                SearchSection(
                    kind: .applications, title: "Applications",
                    results: apps.map { SearchResult(item: $0, score: 0, source: .name) }))
        }
        return out
    }

    /// Apps in the application folders, A to Z. Rebuilt only after the catalog changed, so showing the panel costs
    /// no scan.
    public func applications() -> [Item] {
        guard let catalog = catalogRef.get() else { return [] }
        let written = catalog.itemRowsWritten.load(ordering: .relaxed)
        if let cached = appsCache.withLock({ $0 }), cached.written == written, cached.catalog === catalog {
            return cached.apps
        }
        let roots = Crawler.appRoots.map { PathKey.canonical(Crawler.realPath($0.path)) }
        let apps = Self.launchable(catalog.items(kind: .app), roots: roots)
        appsCache.withLock { $0 = (catalog, written, apps) }
        return apps
    }

    /// The apps under `roots` that are not inside another bundle, sorted by name without ".app" as Finder sorts.
    static func launchable(_ apps: [Item], roots: [String]) -> [Item] {
        apps.filter { app in
            let parent = (app.path as NSString).deletingLastPathComponent
            return roots.contains { Crawler.isInside(app.path, $0) } && !parent.contains(".app/")
                && !parent.hasSuffix(".app")
        }
        .map { (item: $0, key: ($0.name as NSString).deletingPathExtension) }
        .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        .map(\.item)
    }

    // MARK: Settings

    public var settings: IndexSettings { state.withLock { $0.settings } }

    /// Persists `settings` and, if the roots changed, rebuilds the index for them.
    public func update(settings: IndexSettings) async {
        let changed = state.withLock { s in
            defer { s.settings = settings }
            return s.settings != settings
        }
        if let encoded = settings.encoded() {
            attempt("save settings") { try catalogRef.get()?.setMeta(IndexSettings.metaKey, encoded) }
        }
        guard changed else { return }
        // contentIndexing alone is a toggle, not a re-crawl: pause/resume the content lanes.
        let (content, visible) = state.withLock { ($0.content, $0.panelVisible) }
        if !settings.contentIndexing {
            await content?.pipeline.pause()
        } else if let content, !visible {
            await content.pipeline.resume()
        } else if content == nil, let catalog = catalogRef.get() {
            startContent(catalog: catalog, vectors: vectors)
        }
        await rebuild()
    }

    /// Re-crawls the current roots from scratch: items outside them are dropped (with their vectors), the rest is
    /// reconciled; unchanged items keep their vectors. Returns once the crawl is applied (embedding continues).
    public func rebuild() async {
        let (old, catalog, vectors, roots, pipeline) = state.withLock { s in
            let c = s.coordinator
            s.coordinator = nil
            return (c, s.catalog, s.vectors, s.settings.roots, s.pipeline)
        }
        await old?.stop()
        guard let catalog else { return }
        let rootPaths = Set(Crawler(roots: roots).rootPaths)
        let outside = ((try? catalog.all()) ?? []).filter { !PersistentCatalog.isAtOrBelow($0.path, anyOf: rootPaths) }
        if !outside.isEmpty {
            let removed = (try? catalog.remove(paths: outside.map(\.path))) ?? []
            nameIndex.remove(removed)
            if let vectors { try? await vectors.removeItems(removed) }
            await pipeline?.remove(removed)
        }
        attempt("reset crawl") { try catalog.setMeta(IndexCoordinator.MetaKey.crawlComplete, nil) }
        await runCoordinator()
    }

    /// Stat-only verify of every root (replaces the Settings "Rebuild" button): writes only what differs and reads
    /// no file contents. Returns what it found (empty report before the index is open).
    @discardableResult
    public func verifyIndex() async -> VerifyReport {
        guard let coordinator = state.withLock({ $0.coordinator }) else { return VerifyReport() }
        let report = await coordinator.verify(.userRequested)
        await refreshDetails()
        return report
    }

    /// Destructive: forgets every item (names, vectors, extracted content) and crawls the roots again from scratch.
    /// Ids change. Only behind an explicit confirmation in the UI.
    public func resetIndex() async {
        let (old, catalog, vectors, pipeline) = state.withLock { s in
            let c = s.coordinator
            s.coordinator = nil
            return (c, s.catalog, s.vectors, s.pipeline)
        }
        await old?.stop()
        guard let catalog else { return }
        let removed = (try? catalog.remove(paths: ((try? catalog.all()) ?? []).map(\.path))) ?? []
        nameIndex.remove(removed)
        if let vectors { try? await vectors.removeItems(removed) }
        await pipeline?.remove(removed)
        attempt("reset crawl") {
            try catalog.setMeta(IndexCoordinator.MetaKey.crawlComplete, nil)
            try catalog.setMeta(IndexCoordinator.MetaKey.lastEventID, nil)
        }
        broadcast(removed.map { IndexChange(itemID: Int64($0), path: "", kind: .removed) })
        await runCoordinator()
    }

    /// Removes `path` and everything below it from the index (range delete, no rebuild) and keeps it out of later
    /// crawls by adding it to `IndexSettings.exclusions` (P17).
    public func exclude(_ path: String) async {
        let (settings, coordinator) = state.withLock { s in
            if !s.settings.exclusions.contains(path) { s.settings.exclusions.append(path) }
            return (s.settings, s.coordinator)
        }
        if let encoded = settings.encoded() {
            attempt("save settings") { try catalogRef.get()?.setMeta(IndexSettings.metaKey, encoded) }
        }
        await coordinator?.exclude(path)
    }

    /// Reads `path`'s contents now, ahead of the background order (preview, `in:` scope, deferred files).
    public func indexNow(_ path: String, priority: ContentPriority = .userInitiated) {
        let catalog = catalogRef.get()
        guard let pipeline = state.withLock({ $0.pipeline }) else { return }
        let task = TaskPriority(
            rawValue: priority == .userInitiated
                ? TaskPriority.userInitiated.rawValue
                : priority == .normal ? TaskPriority.utility.rawValue : TaskPriority.background.rawValue)
        Task.detached(priority: task) {
            guard let item = (try? catalog?.item(path: path)) ?? nil, item.kind == .file else { return }
            await pipeline.prioritize(item)
        }
    }

    // MARK: UI hooks

    /// Pause embedding + content work while the panel is up so query embeddings never queue behind batches.
    public func setPanelVisible(_ visible: Bool) {
        let (coordinator, pipeline) = state.withLock { s in
            s.panelVisible = visible
            return (s.coordinator, s.pipeline)
        }
        guard coordinator != nil || pipeline != nil else { return }
        Task(priority: .userInitiated) { [self] in
            // Apply the latest state, not the captured one, so out-of-order tasks still converge.
            if state.withLock({ $0.panelVisible }) {
                await coordinator?.pause()
                await pipeline?.pause()
            } else {
                await coordinator?.resume()
                await pipeline?.resume()
            }
        }
    }

    /// Records that the user opened a result (frecency boost now, persisted for the next launch and Recents).
    public func recordOpen(_ item: Item) {
        nameIndex.recordOpen(item.id)
        let catalog = catalogRef.get()
        Task.detached(priority: .utility) {
            do { try catalog?.recordOpen(path: item.path) } catch {
                Self.log.error("recordOpen failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func attempt(_ what: String, _ body: () throws -> Void) {
        do { try body() } catch {
            Self.log.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func ms(since t0: ContinuousClock.Instant) -> Int {
        Int(((ContinuousClock.now - t0) / .milliseconds(1)).rounded())
    }
}
