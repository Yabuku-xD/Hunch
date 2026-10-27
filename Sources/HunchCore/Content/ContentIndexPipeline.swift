import CryptoKit
import Foundation
import IOKit.ps
import Synchronization

/// Tiered background content indexing (owner: media): T1 documents (CPU, performance cores − 2 workers, `.utility`),
/// T2 images + scanned PDF pages (one Vision/GPU stream, `.utility`), T3 video + audio (one stream, `.background`),
/// plus one lane that embeds text chunks once their words are already searchable.
///
/// Work is persisted per (file, tier) in `queue.sqlite` with the file's inode + size + mtime, so restarts resume and
/// unchanged files are skipped. Order: user folders (Desktop, Documents, Downloads, Pictures, Movies) and files
/// modified in the last 30 days first, newest first. Everything pauses while the panel is visible (`pause()`), in
/// Low Power Mode and at thermal state serious or worse; T3 also pauses on battery.
public actor ContentIndexPipeline: ContentPipeline {
    /// When lanes may run (K18: the policy shared with the coordinator's embedding loop).
    public typealias Policy = IndexPolicy

    private enum Lane: Hashable {
        case tier(ContentTier)
        case embed
    }

    public nonisolated let fullText: FullTextIndex
    private let queue: ContentQueue
    private let reader: ContentReader
    private let vectors: (any VectorIndex)?
    private let embedder: (any Embedder)?
    private let policy: Policy
    private let home: String
    public nonisolated let cpuWorkers: Int

    private var userPaused = false
    private var busy: Set<UInt32> = []
    private var lanes: [Task<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var started = false
    /// Files read so far in this process (tests: unchanged files must not count).
    public private(set) var reads = 0
    /// Files whose bytes were hashed to decide reuse (I5 hash-check lane).
    public private(set) var hashChecks = 0
    /// Extractions skipped because the bytes were unchanged or another file had the same bytes (blob cache).
    public private(set) var unchangedSkips = 0
    public private(set) var blobClones = 0
    /// Text chunks sent to the model / served from the chunk-vector cache (I6) / too short for a vector (K12a).
    public private(set) var chunksEmbedded = 0
    public private(set) var chunksReused = 0
    public private(set) var chunksTooShort = 0
    public private(set) var lastNote: String?

    /// Chunk-index layout per item: tier t's text vectors at `t << 21 + k`, its image vectors at `+ 1 << 20`.
    static func vectorBase(_ tier: ContentTier) -> UInt32 { UInt32(tier.rawValue) << 21 }
    static let imageOffset: UInt32 = 1 << 20
    /// Text chunks embedded per file (all of them stay in full text).
    static let maxEmbeddedChunks = 1000
    static let userFolders = ["Desktop", "Documents", "Downloads", "Pictures", "Movies"]

    public init(
        fullText: FullTextIndex, queueURL: URL, media: (any ImageEmbedding)? = nil, embedder: (any Embedder)? = nil,
        vectors: (any VectorIndex)? = nil, policy: Policy = .system, locale: Locale = .current,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) throws {
        self.fullText = fullText
        self.queue = try ContentQueue(url: queueURL)
        self.reader = ContentReader(media: vectors == nil ? nil : media, locale: locale)
        self.vectors = vectors
        self.embedder = vectors == nil ? nil : embedder
        self.policy = policy
        self.home = home
        self.secretRulesMarker = queueURL.deletingLastPathComponent()
            .appendingPathComponent(".secret-rules-\(SecretRules.revision)")
        self.cpuWorkers = max(1, Self.performanceCores() - 2)
        Dataless.applyProcessPolicy()
        // Without an embedder nothing waits for vectors.
        try queue.settleExtracted(to: self.embedder == nil ? .done : .extracted)
    }

    /// Default locations under Application Support.
    public static func standard(
        media: (any ImageEmbedding)? = nil, embedder: (any Embedder)? = nil,
        vectors: (any VectorIndex)? = nil
    ) throws -> ContentIndexPipeline {
        let dir = Paths.appSupport
        return try ContentIndexPipeline(
            fullText: FullTextIndex(url: dir.appendingPathComponent("content.sqlite")),
            queueURL: dir.appendingPathComponent("content-queue.sqlite"),
            media: media, embedder: embedder, vectors: vectors)
    }

    /// Starts the lanes (idempotent). `enqueue` starts them too.
    public func start() {
        guard !started else { return }
        started = true
        for _ in 0..<cpuWorkers { spawn(.tier(.documents), priority: .utility) }
        spawn(.tier(.images), priority: .utility)
        spawn(.tier(.media), priority: .background)
        if embedder != nil { spawn(.embed, priority: .utility) }
        // K3: files indexed before a secret rule matched them lose their chunks and vectors (names stay).
        Task(priority: .background) { [weak self] in await self?.purgeSecrets() }
    }

    /// Set once the queue has been re-checked against this `SecretRules.revision`.
    private let secretRulesMarker: URL

    private func purgeSecrets() async {
        guard !FileManager.default.fileExists(atPath: secretRulesMarker.path) else { return }
        defer { FileManager.default.createFile(atPath: secretRulesMarker.path, contents: nil) }
        let secret = Array(Set(queue.allPaths().filter { SecretRules.isSecret(path: $0.path) }.map(\.item)))
        if !secret.isEmpty { await remove(secret) }
    }

    /// Stops all lanes (in-flight reads are abandoned; their rows stay pending and resume next start).
    public func stop() {
        for l in lanes { l.cancel() }
        lanes.removeAll()
        started = false
        wakeAll()
    }

    private func spawn(_ lane: Lane, priority: TaskPriority) {
        lanes.append(Task(priority: priority) { [weak self] in await self?.run(lane) })
    }

    // MARK: ContentPipeline

    public func enqueue(_ items: [Item]) async {
        let now = Date().timeIntervalSince1970
        try? queue.transaction {
            for item in items
            where item.kind == .file
                || ContentReader.iworkExtensions
                    .contains((item.path as NSString).pathExtension.lowercased())
            {
                guard let tier = ContentReader.tier(for: item.path), let fp = FileFingerprint.of(path: item.path) else {
                    continue
                }
                let rows = queue.rows(item: item.id)
                let row = rows.first(where: { $0.tier == tier })
                if let row, row.fingerprint == fp, row.state != .pending {
                    if row.path != item.path { try queue.move(item: item.id, path: item.path, name: item.name) }
                    continue
                }
                let modified = item.modified.timeIntervalSince1970
                // K2: a cloud-only placeholder is never read; a later modify that clears the flag re-queues it.
                try queue.upsert(
                    item: item.id, tier: tier, path: item.path, name: item.name, fp: fp,
                    group: group(path: item.path, modified: modified, now: now), modified: modified,
                    state: fp.isDataless ? .waitingDownload : .pending)
            }
        }
        start()
        wakeAll()
    }

    /// Dataless files known to the queue (names only), for `IndexStatus.cloudOnly`.
    public var cloudOnlyCount: Int { queue.cloudOnlyCount() }

    public func remove(_ ids: [UInt32]) async {
        for id in ids {
            await dropVectors(item: id, rows: queue.rows(item: id))
            try? queue.delete(item: id)
        }
        try? fullText.remove(items: ids)
    }

    /// Moves `item` to the front of its tier (preview, `in:` scope): re-enqueue with the best group.
    public func prioritize(_ item: Item) async {
        await enqueue([item])
    }

    public func pause() async { userPaused = true }

    public func resume() async {
        userPaused = false
        wakeAll()
    }

    public var status: ContentPipelineStatus {
        get async {
            let c = queue.counts()
            var pending = 0, processed = 0
            for (_, s) in c {
                pending += (s[.pending] ?? 0) + (s[.extracted] ?? 0)
                processed += s[.done] ?? 0
            }
            return ContentPipelineStatus(
                pending: pending, processed: processed, isPaused: isPaused(.tier(.documents)),
                cloudOnly: queue.cloudOnlyCount())
        }
    }

    /// Per-tier progress (T1–T3) for the status line.
    public var tierProgress: [ContentTierProgress] {
        let c = queue.counts()
        return [ContentTier.documents, .images, .media].map { t in
            let s = c[t] ?? [:]
            let total = s.values.reduce(0, +)
            return ContentTierProgress(tier: t, done: total - (s[.pending] ?? 0), total: total)
        }
    }

    /// Why the last file was partly skipped (e.g. speech unavailable).
    public func status(item: UInt32, tier: ContentTier) -> ExtractionStatus? { queue.status(item: item, tier: tier) }

    /// Waits until no work is pending or running (tests, benchmarks). False on timeout.
    public func waitUntilIdle(timeout: Duration = .seconds(120)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let c = queue.counts()
            let left = c.values.reduce(0) { $0 + ($1[.pending] ?? 0) + (embedder == nil ? 0 : ($1[.extracted] ?? 0)) }
            if left == 0, busy.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    // MARK: Lanes

    private func isPaused(_ lane: Lane) -> Bool {
        if userPaused { return true }
        switch lane {
        case .tier(let t): return !policy.allows(t)
        case .embed: return policy.pausesAll
        }
    }

    private func wakeAll() {
        let w = waiters
        waiters.removeAll()
        for c in w { c.resume() }
    }

    private func idle(_ pausedBySystem: Bool) async {
        if pausedBySystem {
            try? await Task.sleep(for: .seconds(5))
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func run(_ lane: Lane) async {
        while !Task.isCancelled {
            if isPaused(lane) {
                await idle(!userPaused)
                continue
            }
            switch lane {
            case .embed:
                // K12(b): up to 16 files per pass, their chunks packed into model batches of ≤ 32.
                let jobs = queue.next(tier: nil, state: .extracted, limit: 16, busy: busy)
                guard !jobs.isEmpty else { await idle(false); continue }
                for j in jobs { busy.insert(j.item) }
                await embedText(jobs)
                for j in jobs { busy.remove(j.item) }
            case .tier(let tier):
                let jobs = queue.next(tier: tier, state: .pending, limit: tier == .documents ? 16 : 1, busy: busy)
                guard !jobs.isEmpty else { await idle(false); continue }
                for j in jobs { busy.insert(j.item) }
                let results = await read(jobs, tier: tier)
                await commit(results, tier: tier)
                for j in jobs { busy.remove(j.item) }
                wakeAll()  // the embed lane and tier 2 (scanned pages) may have new work
            }
        }
    }

    private enum Outcome: Sendable {
        case extracted(ExtractedContent)
        /// Same bytes as last time (touch, identical safe-save): metadata only.
        case unchanged
        /// Same bytes as another finished file: copy its rows (blob cache).
        case clone(donor: UInt32, status: ExtractionStatus, textVectors: Int, imageVectors: Int)
    }

    private struct ReadResult: Sendable {
        var job: ContentQueue.Job
        var fingerprint: FileFingerprint?
        var hash: Data?
        var outcome: Outcome
        var content: ExtractedContent {
            if case .extracted(let c) = outcome { return c }
            return ExtractedContent()
        }
    }

    /// Hash-check lane, then extraction of what is really new; both off the actor, each read under the watchdog.
    private func read(_ jobs: [ContentQueue.Job], tier: ContentTier) async -> [ReadResult] {
        let reader = self.reader
        let limit = policy.watchdog(tier)
        let priority: TaskPriority = tier == .media ? .background : .utility
        // 1. Full content hash (streamed, F_NOCACHE). Dataless files are never opened.
        let hashed: [(FileFingerprint?, Data?)] = await Task.detached(priority: priority) {
            jobs.map { job in
                let fp = FileFingerprint.of(path: job.path)
                guard let fp, !fp.isDataless else { return (fp, nil) }
                FileAccessCounter.shared.add(hashChecks: 1)
                return (fp, ContentHash.of(path: job.path)?.bytes)
            }
        }.value
        hashChecks += jobs.count
        // 2. Decide: unchanged / clone / extract.
        var out: [ReadResult] = []
        var toRead: [(Int, ContentQueue.Job)] = []
        for (i, job) in jobs.enumerated() {
            let (fp, hash) = hashed[i]
            let row = queue.rows(item: job.item).first { $0.tier == job.tier }
            if let hash, job.pages == nil, let old = row?.contentHash, old == hash, (row?.textVectors ?? 0) >= 0 {
                unchangedSkips += 1
                out.append(ReadResult(job: job, fingerprint: fp, hash: hash, outcome: .unchanged))
            } else if let hash, job.pages == nil, let d = queue.donor(hash: hash, tier: tier, excluding: job.item) {
                blobClones += 1
                out.append(
                    ReadResult(
                        job: job, fingerprint: fp, hash: hash,
                        outcome: .clone(
                            donor: d.item, status: d.status, textVectors: d.textVectors,
                            imageVectors: d.imageVectors)))
            } else {
                out.append(ReadResult(job: job, fingerprint: fp, hash: hash, outcome: .unchanged))
                toRead.append((out.count - 1, job))
            }
        }
        guard !toRead.isEmpty else { return out }
        reads += toRead.count
        let contents: [ExtractedContent] = await Task.detached(priority: priority) {
            var res: [ExtractedContent] = []
            res.reserveCapacity(toRead.count)
            for (_, job) in toRead {
                let content =
                    await Self.withWatchdog(seconds: limit, priority: priority) {
                        await autoreleasepool { () -> Task<ExtractedContent, Never> in
                            Task { await reader.read(path: job.path, tier: tier, pages: job.pages) }
                        }.value
                    } ?? .failed(.unreadable, "watchdog: no result after \(Int(limit)) s")
                res.append(content)
            }
            return res
        }.value
        for ((slot, _), c) in zip(toRead, contents) {
            var c = c
            c.chunks = SecretRules.filter(c.chunks)  // K3: never store a private key or token
            out[slot].outcome = .extracted(c)
        }
        return out
    }

    /// Kinds of full-text chunk each tier owns (so a PDF's OCR'd scans survive a text-layer refresh and vice versa).
    static func kinds(_ tier: ContentTier) -> Set<ContentMatch.Kind> {
        switch tier {
        case .names: []
        case .documents: [.text]
        case .images: [.ocr]
        case .media: [.ocr, .transcript]
        }
    }

    private func commit(_ results: [ReadResult], tier: ContentTier) async {
        let kinds = Self.kinds(tier)
        var extracted: [ReadResult] = []
        for r in results {
            switch r.outcome {
            case .extracted: extracted.append(r)
            case .unchanged:
                if let fp = r.fingerprint { try? queue.refresh(item: r.job.item, tier: tier, fp: fp) }
                let old = queue.rows(item: r.job.item).first { $0.tier == tier }
                let needsVectors =
                    embedder != nil && (old?.textVectors ?? 0) == 0
                    && !fullText.chunks(item: r.job.item).filter({ kinds.contains($0.kind) }).isEmpty
                try? queue.finish(
                    item: r.job.item, tier: tier, state: needsVectors ? .extracted : .done,
                    status: .ok, fp: r.fingerprint)
            case .clone(let donor, let status, let textVectors, let imageVectors):
                await cloneRows(
                    from: donor, to: r.job.item, tier: tier, textVectors: textVectors,
                    imageVectors: imageVectors)
                try? queue.finish(
                    item: r.job.item, tier: tier, state: .done, status: status, fp: r.fingerprint,
                    imageVectors: imageVectors)
                try? queue.setTextVectors(item: r.job.item, tier: tier, count: textVectors)
                try? queue.setHash(item: r.job.item, tier: tier, hash: r.hash)
            }
        }
        try? fullText.replace(extracted.map { (item: $0.job.item, kinds: kinds, chunks: $0.content.chunks) })
        for r in extracted {
            let item = r.job.item
            let old = queue.rows(item: item).first { $0.tier == tier }
            if let vectors {
                if let old, old.imageVectors > 0 {
                    let base = Self.vectorBase(tier) + Self.imageOffset
                    for k in 1...UInt32(old.imageVectors) {
                        await vectors.remove(Chunk.id(item: item, index: base + k))
                    }
                }
                if !r.content.images.isEmpty {
                    let base = Self.vectorBase(tier) + Self.imageOffset
                    let batch = r.content.images.enumerated().map { k, img in
                        (
                            info: ChunkInfo(
                                id: Chunk.id(item: item, index: base + UInt32(k + 1)), kind: .image,
                                location: img.location, snippet: img.caption),
                            vector: img.vector
                        )
                    }
                    await vectors.upsertChunks(batch)
                }
            }
            let hasText = !r.content.chunks.isEmpty
            let state: ContentQueue.State =
                embedder != nil && (hasText || (old?.textVectors ?? 0) > 0) ? .extracted : .done
            let waiting = r.content.note == ContentReader.datalessNote
            try? queue.finish(
                item: item, tier: tier, state: waiting ? .waitingDownload : state,
                status: r.content.status, fp: r.fingerprint, imageVectors: r.content.images.count)
            if !waiting { try? queue.setHash(item: item, tier: tier, hash: r.hash) }
            if let note = r.content.note { lastNote = note }
            // Scanned PDF pages → tier 2 (or drop a stale tier-2 row).
            if tier == .documents, (r.job.path as NSString).pathExtension.lowercased() == "pdf" {
                if r.content.scannedPages.isEmpty {
                    if queue.rows(item: item).contains(where: { $0.tier == .images }) {
                        await dropVectors(item: item, rows: queue.rows(item: item).filter { $0.tier == .images })
                        try? fullText.replace([(item: item, kinds: Self.kinds(.images), chunks: [])])
                        try? queue.delete(item: item, tier: .images)
                    }
                } else if let fp = r.fingerprint {
                    let modified = Double(fp.mtime) / 1e9
                    try? queue.upsert(
                        item: item, tier: .images, path: r.job.path, name: r.job.name, fp: fp,
                        group: group(
                            path: r.job.path, modified: modified,
                            now: Date().timeIntervalSince1970),
                        modified: modified, pages: r.content.scannedPages)
                }
            }
        }
    }

    /// Blob cache (I5): copies another file's full-text rows and vectors for identical bytes. 0 model work.
    private func cloneRows(
        from donor: UInt32, to item: UInt32, tier: ContentTier, textVectors: Int,
        imageVectors: Int
    ) async {
        let kinds = Self.kinds(tier)
        let chunks = fullText.chunks(item: donor).filter { kinds.contains($0.kind) }
        try? fullText.replace([(item: item, kinds: kinds, chunks: chunks)])
        guard let vectors else { return }
        let base = Self.vectorBase(tier)
        var ids: [(from: ChunkID, to: ChunkID)] = []
        if textVectors > 0 {
            for k in 1...UInt32(textVectors) {
                ids.append((Chunk.id(item: donor, index: base + k), Chunk.id(item: item, index: base + k)))
            }
        }
        if imageVectors > 0 {
            for k in 1...UInt32(imageVectors) {
                ids.append(
                    (
                        Chunk.id(item: donor, index: base + Self.imageOffset + k),
                        Chunk.id(item: item, index: base + Self.imageOffset + k)
                    ))
            }
        }
        let infos = await vectors.chunkInfo(ids.map(\.from))
        var batch: [(info: ChunkInfo, vector: [Float])] = []
        for (from, to) in ids {
            guard let v = await vectors.storedVector(from) else { continue }
            var info = infos[from] ?? ChunkInfo(id: to, kind: .semantic)
            info.id = to
            batch.append((info, v))
        }
        if !batch.isEmpty { await vectors.upsertChunks(batch) }
    }

    /// A chunk gets a vector only with ≥ 4 words (or ≥ 24 non-space characters for unspaced scripts), K12(a).
    static func worthEmbedding(_ text: String) -> Bool {
        var words = 0, chars = 0, inWord = false
        for ch in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(ch) { inWord = false; continue }
            chars += 1
            if !inWord { words += 1; inWord = true }
            if words >= 4 || chars >= 24 { return true }
        }
        return false
    }

    /// SHA-256 of the exact model input (title + text + output dimension), the chunk-vector cache key (I6).
    static func inputHash(title: String, text: String, dimension: Int) -> Data {
        var h = SHA256()
        h.update(data: Data("\(dimension)\u{1F}\(title)\u{1F}".utf8))
        h.update(data: Data(text.utf8))
        return Data(h.finalize())
    }

    /// Embeds the text chunks of several files: cached vectors (same exact input anywhere) are reused, the rest are
    /// packed across files into model batches of ≤ 32, shortest first.
    private func embedText(_ jobs: [ContentQueue.Job]) async {
        guard let embedder, let vectors else { return }
        struct Plan {
            var job: ContentQueue.Job
            var slots: [(info: ChunkInfo, hash: Data, text: String, vector: [Float]?)] = []
            var old: Int
        }
        var plans: [Plan] = []
        var need: [(plan: Int, slot: Int)] = []
        for job in jobs {
            let kinds = Self.kinds(job.tier)
            let base = Self.vectorBase(job.tier)
            let old = queue.rows(item: job.item).first { $0.tier == job.tier }?.textVectors ?? 0
            var plan = Plan(job: job, old: old)
            var offset = 0
            for c in fullText.chunks(item: job.item) where kinds.contains(c.kind) {
                defer { offset += c.text.utf16.count }
                guard plan.slots.count < Self.maxEmbeddedChunks else { break }
                guard Self.worthEmbedding(c.text) else { chunksTooShort += 1; continue }
                let hash = Self.inputHash(title: job.name, text: c.text, dimension: embedder.dimension)
                var cached: [Float]?
                if let src = queue.chunkVector(hash: hash) {
                    cached = await vectors.storedVector(
                        Chunk.id(
                            item: src.item,
                            index: Self.vectorBase(src.tier) + src.idx))
                }
                let info = ChunkInfo(
                    id: Chunk.id(item: job.item, index: base + UInt32(plan.slots.count + 1)),
                    kind: .semantic, location: c.location, textOffset: offset,
                    snippet: String(c.text.prefix(160)))
                plan.slots.append((info, hash, c.text, cached))
                if cached == nil { need.append((plans.count, plan.slots.count - 1)) } else { chunksReused += 1 }
            }
            plans.append(plan)
        }
        // Shortest first so a batch's padding stays small.
        need.sort { plans[$0.plan].slots[$0.slot].text.utf16.count < plans[$1.plan].slots[$1.slot].text.utf16.count }
        var failed = false
        for batch in need.chunked(32) {
            let docs = batch.map { (title: plans[$0.plan].job.name, text: plans[$0.plan].slots[$0.slot].text) }
            guard let vs = try? await embedder.embedDocuments(docs), vs.count == docs.count else {
                failed = true; break
            }
            chunksEmbedded += docs.count
            for (ref, v) in zip(batch, vs) { plans[ref.plan].slots[ref.slot].vector = v }
        }
        for plan in plans {
            let job = plan.job
            let base = Self.vectorBase(job.tier)
            if failed {
                // Model unavailable: leave the text searchable and stop asking.
                try? queue.setTextVectors(item: job.item, tier: job.tier, count: plan.old)
                continue
            }
            let batch = plan.slots.compactMap { s in s.vector.map { (info: s.info, vector: $0) } }
            if plan.old > batch.count {
                for k in (batch.count + 1)...plan.old {
                    await vectors.remove(Chunk.id(item: job.item, index: base + UInt32(k)))
                }
            }
            if !batch.isEmpty { await vectors.upsertChunks(batch) }
            try? queue.setChunkVectors(
                item: job.item, tier: job.tier,
                plan.slots.enumerated().map { (UInt32($0.offset + 1), $0.element.hash) })
            try? queue.setTextVectors(item: job.item, tier: job.tier, count: batch.count)
        }
    }

    private func dropVectors(item: UInt32, rows: [ContentQueue.Row]) async {
        guard let vectors else { return }
        for r in rows {
            let base = Self.vectorBase(r.tier)
            if r.textVectors > 0 {
                for k in 1...UInt32(r.textVectors) { await vectors.remove(Chunk.id(item: item, index: base + k)) }
            }
            if r.imageVectors > 0 {
                for k in 1...UInt32(r.imageVectors) {
                    await vectors.remove(Chunk.id(item: item, index: base + Self.imageOffset + k))
                }
            }
        }
    }

    // MARK: Helpers

    /// 0 recent in a user folder, 1 older in a user folder, 2 recent elsewhere, 3 the rest.
    private func group(path: String, modified: Double, now: Double) -> Int {
        let inUser = Self.userFolders.contains { path.hasPrefix(home + "/" + $0 + "/") }
        let recent = now - modified < 30 * 86_400
        return (inUser ? 0 : 2) + (recent ? 0 : 1)
    }

    static func withWatchdog<T: Sendable>(
        seconds: Double, priority: TaskPriority,
        _ op: @escaping @Sendable () async -> T
    ) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let work = Task.detached(priority: priority) {
                let r = await op()
                if once.claim() { cont.resume(returning: r) }
                once.cancelTimer()
            }
            let timer = Task.detached {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                if once.claim() {
                    work.cancel()
                    cont.resume(returning: nil)
                }
            }
            once.setTimer(timer)
        }
    }

    static func performanceCores() -> Int {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &n, &size, nil, 0) == 0, n > 0 { return Int(n) }
        return ProcessInfo.processInfo.activeProcessorCount
    }

    nonisolated static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}

/// First-wins flag plus the watchdog timer to cancel once the work finished.
private final class Once: Sendable {
    private let state = Mutex<(done: Bool, timer: Task<Void, Never>?, finished: Bool)>((false, nil, false))

    func claim() -> Bool {
        state.withLock { s in
            defer { s.done = true }
            return !s.done
        }
    }

    func setTimer(_ t: Task<Void, Never>) {
        let cancelNow = state.withLock { s -> Bool in
            s.timer = t
            return s.finished
        }
        if cancelNow { t.cancel() }
    }

    func cancelTimer() {
        let t = state.withLock { s -> Task<Void, Never>? in
            s.finished = true
            return s.timer
        }
        t?.cancel()
    }
}

extension Array {
    func chunked(_ n: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: n).map { self[$0..<Swift.min($0 + n, count)] }
    }
}
