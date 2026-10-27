import CoreServices
import CryptoKit
import Foundation

/// Orchestrates crawl → catalog → name index → embedding → vector index, plus watcher updates (owner: indexer).
///
/// - First launch (no persisted event id or crawl never completed): captures the current FSEvents
///   id, crawls, reconciles the catalog, builds the name index, then persists the id.
/// - Later launches: loads the name index from the catalog and replays FSEvents since the persisted id.
/// - Embedding runs in batches at `.utility` priority, paused while the panel is visible.
/// - Killed at any point: the next launch re-crawls (crawl incomplete) or replays events (crawl done);
///   embedding continues from the catalog's pending set.
public actor IndexCoordinator {
    public enum MetaKey {
        public static let lastEventID = "index.lastEventID"
        public static let crawlComplete = "index.crawlComplete"
        /// "uuid@device" per root volume at the last verify (I3).
        public static let volumes = "index.volumes"
        public static let rulesVersion = "index.rulesVersion"
    }

    /// What the coordinator is doing; reported through `onActivity` on every change and after each embedded batch.
    public enum Activity: Sendable, Equatable {
        case crawling
        case embedding
        case idle
        case paused
        /// The embedder can't load its model; embedding stopped.
        case modelMissing
        /// Replaying the FSEvents journal since the last run.
        case catchingUp
        /// Stat-only verify scan.
        case verifying(VerifyReason)
    }

    /// Called after the catalog changed: upserted items and removed ids (for the content pipeline).
    public typealias ChangeSink = @Sendable (_ upserted: [Item], _ removed: [UInt32]) async -> Void

    public nonisolated let nameIndex: NameIndex
    public nonisolated let catalog: any IndexCatalog
    public nonisolated let crawler: Crawler
    private let embedder: (any Embedder)?
    private let vectors: (any VectorIndex)?
    private let extractor: ContentExtractor
    private let watcher: Watcher
    public let batchSize: Int

    public private(set) var lastCrawl: CrawlStats?
    public private(set) var embeddedCount = 0
    public private(set) var appliedBatches = 0
    public private(set) var isPaused = false
    public private(set) var activity: Activity = .idle
    private let onActivity: (@Sendable (Activity) -> Void)?
    private let onChange: ChangeSink?
    /// K18: Low Power / thermal pause for name embedding (same policy object as the content lanes).
    private let policy: IndexPolicy
    /// Last hand-off to `onChange`; each one waits for the previous, so the sink sees changes in order without the
    /// watcher's apply ever waiting on a busy content pipeline (that wait made names visible 2 s late, §C s5).
    private var forwardTail: Task<Void, Never>?
    /// The caller already filled `nameIndex` from this catalog; skip the reload on a replay start.
    private let namesLoaded: Bool

    private var watchTask: Task<Void, Never>?
    private var embedTask: Task<Void, Never>?
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    private var workWaiters: [CheckedContinuation<Void, Never>] = []
    /// Ids touched by `apply` while a batch was being embedded.
    private var removedInFlight: Set<UInt32> = []
    private var changedInFlight: Set<UInt32> = []
    private var catchingUp = false
    private var pendingEventID: UInt64?
    private var lastMetaWrite: ContinuousClock.Instant?
    /// lastEventID meta writes so far (K9 test: bursts of batches cost ≤ 1 write per 5 s).
    public private(set) var metaWrites = 0
    public private(set) var lastVerify: VerifyReport?
    /// Folders that could not be listed in the last full scan (K21).
    public private(set) var unreadable: [String] = []
    /// Name vectors skipped because their exact model input was unchanged.
    public private(set) var nameEmbedsSkipped = 0
    private var exclusions: [String]
    private let onIndexChanges: (@Sendable ([IndexChange]) -> Void)?

    public init(roots: [URL] = Crawler.defaultRoots,
                catalog: any IndexCatalog = MemoryCatalog(),
                nameIndex: NameIndex = NameIndex(),
                embedder: (any Embedder)? = nil,
                vectors: (any VectorIndex)? = nil,
                extractor: ContentExtractor = ContentExtractor(),
                batchSize: Int = 64,
                watchLatency: Double = 0.3,
                onActivity: (@Sendable (Activity) -> Void)? = nil,
                onChange: ChangeSink? = nil,
                onIndexChanges: (@Sendable ([IndexChange]) -> Void)? = nil,
                exclusions: [String] = [],
                namesLoaded: Bool = false,
                policy: IndexPolicy = .system) {
        self.policy = policy
        self.namesLoaded = namesLoaded
        self.onIndexChanges = onIndexChanges
        self.exclusions = exclusions.map(PathKey.canonical)
        self.onActivity = onActivity
        self.onChange = onChange
        self.crawler = Crawler(roots: roots)
        self.catalog = catalog
        self.nameIndex = nameIndex
        self.embedder = embedder
        self.vectors = vectors
        self.extractor = extractor
        self.batchSize = max(1, batchSize)
        self.watcher = Watcher(roots: roots, latency: watchLatency)
    }

    // MARK: Lifecycle

    public func start() async {
        guard watchTask == nil else { return }
        let crawled = await catalog.meta(MetaKey.crawlComplete) == "1"
        var since = await catalog.meta(MetaKey.lastEventID).flatMap(UInt64.init)
        if since == nil || !crawled {
            guard let id = await fullCrawl() else { return }
            since = id
        } else {
            if !namesLoaded { nameIndex.replaceAll(await catalog.allItems()) }
            // I3: the journal is only trusted on the same volume instance; otherwise a stat-only verify.
            let stored = await catalog.meta(MetaKey.volumes)
            let current = Self.volumeFingerprint(crawler.rootPaths)
            let rulesOK = await catalog.meta(MetaKey.rulesVersion) == IndexSettings.rulesVersion
            if stored != current || !rulesOK {
                let id = Watcher.currentEventID
                lastVerify = await verify(stored != current ? .volumeChanged : .rulesChanged)
                since = id
            } else {
                report(.catchingUp)
                catchingUp = true
            }
        }
        guard !Task.isCancelled else { return }

        let stream = watcher.start(since: since)
        watchTask = Task { [weak self] in
            for await batch in stream {
                guard let self else { return }
                await self.apply(batch)
            }
        }
        if embedder != nil && vectors != nil {
            embedTask = Task(priority: .utility) { [weak self] in await self?.embedLoop() }
        } else if !catchingUp {
            report(isPaused ? .paused : .idle)
        }
    }

    /// "uuid@device" of every root's volume (`FSEventsCopyUUIDForDevice`), sorted; stored after each verify.
    nonisolated static func volumeFingerprint(_ roots: [String]) -> String {
        var parts = Set<String>()
        for r in roots {
            var st = stat()
            guard stat(r, &st) == 0 else { continue }
            let uuid = FSEventsCopyUUIDForDevice(st.st_dev).map { CFUUIDCreateString(nil, $0) as String } ?? "none"
            parts.insert("\(uuid)@\(st.st_dev)")
        }
        return parts.sorted().joined(separator: ",")
    }

    private func report(_ a: Activity, always: Bool = false) {
        guard always || a != activity else { return }
        if activity == .modelMissing && a != .crawling { return }  // sticky once the model is gone
        activity = a
        onActivity?(a)
    }

    public func stop() async {
        watcher.stop()
        watchTask?.cancel()
        embedTask?.cancel()
        watchTask = nil
        embedTask = nil
        await flushEventID()
        wake(&resumeWaiters)
        wake(&workWaiters)
    }

    /// Pause embedding (call when the panel becomes visible). An in-flight batch finishes first.
    public func pause() {
        isPaused = true
        if activity == .idle || activity == .embedding { report(.paused) }
    }

    public func resume() {
        isPaused = false
        if activity == .paused { report(.idle) }
        wake(&resumeWaiters)
    }

    /// K9: 0.25 s FSEvents latency while the panel is visible, 0.5 s hidden (restarts the stream from the last
    /// delivered id; nothing is lost).
    public func setPanelVisible(_ visible: Bool) {
        let latency = visible ? 0.25 : 0.5
        guard watchTask != nil, latency != watcher.latency else { return }
        watcher.setLatency(latency)
    }

    /// First crawl (or re-crawl after `crawlComplete` was reset). Returns the event id to resume watching from.
    @discardableResult
    public func fullCrawl() async -> UInt64? {
        let startID = Watcher.currentEventID
        let report = await verify(.userRequested, crawling: true)
        guard !Task.isCancelled else { return nil }
        lastVerify = report
        await catalog.setMeta(MetaKey.lastEventID, String(startID))
        await catalog.setMeta(MetaKey.crawlComplete, "1")
        return startID
    }

    /// Stat-only verify scan (I3): walks `subtree` (or every root), compares each entry's identity + stamp with the
    /// catalog and writes only what differs. Unchanged trees write 0 rows and read no file contents.
    @discardableResult
    public func verify(_ reason: VerifyReason, subtree: String? = nil, crawling: Bool = false) async -> VerifyReport {
        let t0 = ContinuousClock.now
        let before = activity
        let rowsBefore = await catalog.rowsWritten()
        report(crawling ? .crawling : .verifying(reason))
        let roots = crawler.rootPaths
        var entries: [CrawlEntry]
        var scope: [String]
        var excluding: [String] = []
        if let subtree, !roots.contains(subtree) {
            entries = crawler.walk(subtree, includeRoot: true)
            for nested in crawler.nestedRoots(in: subtree) { entries += crawler.walk(nested, includeRoot: true) }
            scope = [subtree]
        } else if let subtree {
            entries = crawler.walk(subtree)
            for nested in crawler.nestedRoots(in: subtree) { entries += crawler.walk(nested, includeRoot: true) }
            scope = [subtree]
        } else {
            let (crawled, stats) = await crawler.crawlEntries()
            entries = crawled
            lastCrawl = crawling ? stats : lastCrawl
            unreadable = stats.unreadable
            scope = roots
        }
        excluding = exclusions
        entries.removeAll { e in exclusions.contains { Crawler.isInside(e.path, $0) } }
        guard !Task.isCancelled else { return VerifyReport() }
        let (ups, removed) = await catalog.reconcile(under: scope, with: entries, excluding: excluding)
        let changed = ups.filter { $0.change != nil }
        if subtree == nil && crawling {
            nameIndex.replaceAll(await catalog.allItems())
        } else {
            nameIndex.remove(removed)
            nameIndex.upsert(changed.map(\.item))
        }
        await removeVectors(removed)
        await publish(changed, removed)
        var r = VerifyReport(scanned: entries.count, wall: ContinuousClock.now - t0)
        for u in changed {
            switch u.change {
            case .added: r.added += 1
            case .renamed: r.moved += 1
            default: r.changed += 1
            }
        }
        r.removed = removed.count
        r.rowsWritten = await catalog.rowsWritten() - rowsBefore
        if subtree == nil {
            await catalog.setMeta(MetaKey.volumes, Self.volumeFingerprint(roots))
            await catalog.setMeta(MetaKey.rulesVersion, IndexSettings.rulesVersion)
        }
        lastVerify = r
        activity = before == .modelMissing ? .modelMissing : .crawling
        self.report(before == .modelMissing ? .modelMissing : (isPaused ? .paused : .idle), always: true)
        wake(&workWaiters)
        return r
    }

    /// Removes `path` and everything below it from the index (range delete) and keeps it out of later crawls (P17).
    public func exclude(_ path: String) async {
        let p = PathKey.canonical(path)
        if !exclusions.contains(p) { exclusions.append(p) }
        let removed = await catalog.remove(paths: [p])
        nameIndex.remove(removed)
        await removeVectors(removed)
        await publish([], removed)
    }

    /// Forwards a change set to the content pipeline and the app-facing change stream.
    private func publish(_ changed: [CatalogUpsert], _ removed: [UInt32]) async {
        guard !changed.isEmpty || !removed.isEmpty else { return }
        // Name-visible first (the name index is already updated), then the content hand-off, queued.
        if let onIndexChanges {
            var out: [IndexChange] = []
            out.reserveCapacity(changed.count + removed.count)
            for u in changed {
                if let k = u.change { out.append(IndexChange(itemID: Int64(u.item.id), path: u.item.path, kind: k)) }
            }
            for id in removed { out.append(IndexChange(itemID: Int64(id), path: "", kind: .removed)) }
            onIndexChanges(out)
        }
        if let onChange {
            let items = changed.map(\.item), prev = forwardTail
            forwardTail = Task(priority: .utility) {
                await prev?.value
                await onChange(items, removed)
            }
        }
    }

    /// Returns once every change so far has reached the `onChange` sink (tests, benchmarks, `contentIdle`).
    public func changesDelivered() async {
        await forwardTail?.value
    }

    // MARK: Watcher batches

    /// Applies one FSEvents batch to catalog, name index and vector index, then persists its id (throttled).
    public func apply(_ batch: ChangeBatch) async {
        var rescans: [String] = []
        var touched: [String: Bool] = [:]  // indexable path → directory created/moved here
        let roots = crawler.rootPaths
        var verifyAll = false
        for e in batch.events {
            if e.isHistoryDone {
                if catchingUp {
                    catchingUp = false
                    report(isPaused ? .paused : .idle)
                }
                continue
            }
            if e.idsWrapped { verifyAll = true; continue }
            if exclusions.contains(where: { Crawler.isInside(e.path, $0) }) { continue }
            if e.mustScanSubDirs {
                if roots.contains(e.path) {
                    rescans.append(e.path)
                } else if let p = crawler.indexablePath(for: e.path, roots: roots) {
                    rescans.append(p)
                }
                continue
            }
            guard let p = crawler.indexablePath(for: e.path, roots: roots) else { continue }
            let movedIn = p == PathKey.canonical(e.path) && e.isDirectory && (e.isCreated || e.isRenamed)
            touched[p] = (touched[p] ?? false) || movedIn
        }
        if verifyAll {
            await verify(.idsWrapped)
            await noteEventID(batch.lastEventID)
            appliedBatches += 1
            return
        }

        var upserts: [CrawlEntry] = []
        var removals: [String] = []
        var changed: [CatalogUpsert] = []
        var removed: [UInt32] = []

        for root in Set(rescans) {
            var entries = crawler.walk(root, includeRoot: !roots.contains(root))
            for nested in crawler.nestedRoots(in: root) { entries += crawler.walk(nested, includeRoot: true) }
            let r = await catalog.reconcile(under: [root], with: entries, excluding: [])
            changed += r.upserts.filter { $0.change != nil }
            removed += r.removed
        }
        // Directories first so a moved folder's children are matched by identity after the folder itself.
        let ordered = touched.sorted { $0.key.count < $1.key.count }
        for (path, movedIn) in ordered where !rescans.contains(where: { Crawler.isInside(path, $0) }) {
            if let entry = Crawler.entry(at: path) {
                if movedIn && entry.kind == .folder {
                    let r = await catalog.reconcile(under: [path], with: crawler.walk(path, includeRoot: true),
                                                    excluding: crawler.nestedRoots(in: path))
                    changed += r.upserts.filter { $0.change != nil }
                    removed += r.removed
                } else {
                    upserts.append(entry)
                }
            } else {
                removals.append(path)
            }
        }
        if !upserts.isEmpty { changed += await catalog.upsertEntries(upserts).filter { $0.change != nil } }
        if !removals.isEmpty { removed += await catalog.remove(paths: removals) }

        nameIndex.remove(removed)
        nameIndex.upsert(changed.map(\.item))
        await removeVectors(removed)
        await publish(changed, removed)
        removedInFlight.formUnion(removed)
        changedInFlight.formUnion(changed.map(\.item.id))
        await noteEventID(batch.lastEventID)
        appliedBatches += 1
        if !changed.isEmpty { wake(&workWaiters) }
    }

    /// lastEventID is persisted at most every 5 s (and on stop); replaying a few seconds twice is idempotent.
    private func noteEventID(_ id: UInt64) async {
        guard id > 0 else { return }
        pendingEventID = id
        let now = ContinuousClock.now
        if let last = lastMetaWrite, now - last < .seconds(5) { return }
        await flushEventID()
    }

    private func flushEventID() async {
        guard let id = pendingEventID else { return }
        pendingEventID = nil
        lastMetaWrite = ContinuousClock.now
        metaWrites += 1
        await catalog.setMeta(MetaKey.lastEventID, String(id))
    }

    private func removeVectors(_ ids: [UInt32]) async {
        guard let vectors else { return }
        for id in ids { await vectors.removeItem(id) }
    }

    // MARK: Embedding

    private func embedLoop() async {
        guard let embedder, let vectors else { return }
        while !Task.isCancelled {
            if isPaused {
                report(.paused)
                await withCheckedContinuation { resumeWaiters.append($0) }
                continue
            }
            if policy.pausesAll {
                report(.paused)
                try? await Task.sleep(for: .seconds(5))  // power/thermal changes have no wake-up; re-check slowly
                continue
            }
            let batch = await catalog.pendingEmbedding(limit: batchSize)
            if batch.isEmpty {
                report(.idle)
                await withCheckedContinuation { workWaiters.append($0) }
                continue
            }
            report(.embedding)
            removedInFlight = []
            changedInFlight = []
            let allDocs = await Self.documents(for: batch, extractor: extractor)
            // Exact-input rule: a document whose model input hashes to the stored name-vector hash keeps its vector.
            let hashes = allDocs.map { Self.inputHash($0) }
            var todo: [Int] = []
            var skipped: [(id: UInt32, hash: Data)] = []
            for (i, item) in batch.enumerated() {
                if await catalog.nameVectorHash(item.id) == hashes[i] {
                    skipped.append((item.id, hashes[i]))
                } else {
                    todo.append(i)
                }
            }
            nameEmbedsSkipped += skipped.count
            let docs = todo.map { allDocs[$0] }
            var vecs: [[Float]] = []
            if !docs.isEmpty {
                do {
                    vecs = try await embedder.embedDocuments(docs)
                    if vecs.count != docs.count { throw EmbedMismatch() }
                } catch {
                    if Task.isCancelled { return }
                    if let e = error as? EmbedderError, e.isUnavailable {
                        report(.modelMissing)
                        return  // leave the batch pending; a later coordinator (model installed) picks it up
                    }
                    // Retry one by one so a single bad document cannot wedge the queue; failures are skipped.
                    vecs = []
                    for d in docs {
                        vecs.append((try? await embedder.embedDocuments([d]).first) ?? [])
                    }
                }
            }
            guard !Task.isCancelled else { return }
            var done: [(id: UInt32, hash: Data)] = skipped.filter { !removedInFlight.contains($0.id) && !changedInFlight.contains($0.id) }
            for (k, i) in todo.enumerated() where !removedInFlight.contains(batch[i].id) {
                let item = batch[i]
                let v = vecs[k]
                if !v.isEmpty { await vectors.upsert(Chunk.id(item: item.id), v) }
                if !changedInFlight.contains(item.id) { done.append((item.id, v.isEmpty ? Data() : hashes[i])) }
            }
            // Removed meanwhile: make sure no vector survives.
            for item in batch where removedInFlight.contains(item.id) { await vectors.removeItem(item.id) }
            await catalog.markEmbedded(done)
            embeddedCount += done.count
            report(.embedding, always: true)
        }
    }

    /// SHA-256 of the exact model input (title + text) for the name vector.
    nonisolated static func inputHash(_ doc: (title: String, text: String)) -> Data {
        Data(SHA256.hash(data: Data((doc.title + "\u{1F}" + doc.text).utf8)))
    }

    private struct EmbedMismatch: Error {}

    /// Extraction does file I/O; keep it off the actor.
    @concurrent
    private nonisolated static func documents(for items: [Item], extractor: ContentExtractor) async -> [(title: String, text: String)] {
        items.map { extractor.document(for: $0) ?? (title: "none", text: extractor.describe($0)) }
    }

    private func wake(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let w = waiters
        waiters = []
        for c in w { c.resume() }
    }
}
