import Foundation
import Synchronization

/// Fuses four retrieval legs into one row per file (owner: integrate).
///
/// Per query:
/// 1. **Name** hits are yielded synchronously inside `results(for:)` (no task hop, never waits on the model).
/// 2. A detached task asks the **full-text** index (exact / substring over document text, OCR and transcripts;
///    synchronous, ≤ 15 ms) and, if it found anything, yields name + full-text fused.
/// 3. After a 100 ms debounce (skipped when the query embedding is cached) it embeds the query (loading the model on
///    first need), searches the vector index for **semantic text and image** chunks and yields all four legs fused.
///
/// Fusion is reciprocal rank fusion per file: Σ weight / (k + rank), where each leg ranks files by their best hit.
/// Semantic-only files must pass the research gate (cosine ≥ threshold and within the window of the best score;
/// images have their own threshold), and never outrank a file with an exact full-text phrase hit. Each row shows its
/// best content match (exact phrase > best full-text hit > best semantic chunk) and counts the rest in `moreMatches`.
/// Starting a new query cancels the previous query's task.
public final class HybridSearchEngine: SearchEngine {
    public struct Config: Sendable {
        public var nameLimit = 50
        public var fullTextLimit = 100
        /// Chunks fetched from the vector index (several may belong to one file).
        public var semanticK = 200
        public var resultLimit = 50
        public var rrfK: Float = 60
        public var nameWeight: Float = 1.0
        public var fullTextWeight: Float = 1.0
        public var semanticWeight: Float = 0.8
        public var semanticThreshold: Float = 0.70
        public var semanticWindow: Float = 0.03
        /// Gate for semantic-only image / frame chunks (cross-modal cosines run lower; media team calibrates).
        public var imageThreshold: Float = 0.30
        public var debounce: Duration = .milliseconds(100)
        public var cacheSize = 64
        public init() {}
    }

    public typealias Hit = (id: UInt32, score: Float)
    public typealias ChunkHit = (id: ChunkID, score: Float)

    public let config: Config
    private let names: any NameIndexing
    private let lookup: @Sendable (UInt32) -> Item?

    private struct State {
        var embedder: (any Embedder)?
        var vectors: (any VectorIndex)?
        var fullText: (any FullTextIndexing)?
        var suggestions: (@Sendable () -> [SearchSection])?
        var scope: (@Sendable (_ folder: String, _ limit: Int) -> [Item])?
        var semanticTask: Task<Void, Never>?
        var cache: [String: [Float]] = [:]
        var cacheOrder: [String] = []  // least recent first
    }
    private let state: Mutex<State>

    /// `lookup` must be synchronous and cheap (e.g. `Catalog.item(_:)`, an in-memory read); unknown ids are dropped.
    public init(names: any NameIndexing,
                lookup: @escaping @Sendable (UInt32) -> Item?,
                embedder: (any Embedder)? = nil,
                vectors: (any VectorIndex)? = nil,
                fullText: (any FullTextIndexing)? = nil,
                config: Config = Config()) {
        self.names = names
        self.lookup = lookup
        self.config = config
        self.state = Mutex(State(embedder: embedder, vectors: vectors, fullText: fullText))
    }

    /// Enables legs as they become ready (each may arrive later than launch).
    public func attach(embedder: (any Embedder)? = nil, vectors: (any VectorIndex)? = nil,
                       fullText: (any FullTextIndexing)? = nil) {
        state.withLock { s in
            if let embedder { s.embedder = embedder }
            if let vectors { s.vectors = vectors }
            if let fullText { s.fullText = fullText }
        }
    }

    /// Supplies the empty-query sections (the backend wires Favorites + Recents).
    public func attach(suggestions: @escaping @Sendable () -> [SearchSection]) {
        state.withLock { $0.suggestions = suggestions }
    }

    /// K17/K6: lists the items at or below a folder (range query on the catalog) for an `in:` scope with no text.
    public func attach(scope: @escaping @Sendable (_ folder: String, _ limit: Int) -> [Item]) {
        state.withLock { $0.scope = scope }
    }

    /// Drops the semantic leg (model gone) without touching the others.
    public func detachEmbedder() {
        state.withLock { $0.embedder = nil }
    }

    public var isSemanticReady: Bool {
        state.withLock { $0.embedder != nil && $0.vectors != nil }
    }

    // MARK: SearchEngine

    public func suggestions() -> [SearchSection] {
        state.withLock { $0.suggestions }?() ?? []
    }

    public func results(for q: String) -> AsyncStream<[SearchResult]> {
        begin(q, yieldNames: true).rest
    }

    public func start(_ q: String) -> (first: [SearchResult]?, rest: AsyncStream<[SearchResult]>) {
        begin(q, yieldNames: false)
    }

    private func begin(_ q: String, yieldNames: Bool) -> (first: [SearchResult]?, rest: AsyncStream<[SearchResult]>) {
        // K17: `name:` / `in:` / `ext:` / `kind:` operators; a plain query parses to itself with no filters.
        let parsed = QueryParser.parse(q.trimmingCharacters(in: .whitespacesAndNewlines))
        let query = parsed.text
        let filtered = parsed.hasFilters
        let (stream, continuation) = AsyncStream<[SearchResult]>.makeStream(bufferingPolicy: .bufferingNewest(4))

        var nameHits: [Hit] = []
        var first: [SearchResult] = []
        if query.isEmpty {
            // `in:Folder` alone: the folder's items via the catalog range (K6), no full scan.
            if let folder = parsed.folders.first, let scope = state.withLock({ $0.scope }) {
                for item in scope(folder, config.nameLimit * 8) where parsed.matches(item) {
                    nameHits.append((item.id, 0))
                    first.append(SearchResult(item: item, score: 0, source: .name))
                    if first.count == config.nameLimit { break }
                }
            }
        } else {
            for h in names.search(query, limit: filtered ? config.nameLimit * 8 : config.nameLimit) {
                guard let item = lookup(h.id), parsed.matches(item) else { continue }
                nameHits.append(h)
                first.append(SearchResult(item: item, score: h.score, source: .name))
                if first.count == config.nameLimit { break }
            }
        }
        if yieldNames { continuation.yield(first) }
        let keep: @Sendable ([SearchResult]) -> [SearchResult] = { r in filtered ? r.filter { parsed.matches($0.item) } : r }

        let (embedder, vectors, fullText, cached, previous) = state.withLock { s in
            let p = s.semanticTask
            s.semanticTask = nil
            return (s.embedder, s.vectors, s.fullText, s.cache[query], p)
        }
        previous?.cancel()
        let semanticReady = embedder != nil && vectors != nil
        guard !query.isEmpty, !parsed.nameOnly, fullText != nil || semanticReady else {
            continuation.finish()
            return (first, stream)
        }

        let task = Task.detached(priority: .userInitiated) { [self] in
            defer { continuation.finish() }
            var textHits: [FullTextHit] = []
            if let fullText {
                textHits = fullText.search(query, limit: config.fullTextLimit)
                guard !Task.isCancelled else { return }
                if !textHits.isEmpty { continuation.yield(keep(fuse(names: nameHits, fullText: textHits))) }
            }
            guard let embedder, let vectors else { return }
            let vector: [Float]
            if let cached {
                vector = cached
                remember(query, cached)  // refresh recency
            } else {
                do { try await Task.sleep(for: config.debounce) } catch { return }
                guard let v = try? await embedder.embedQueries([query]).first, !v.isEmpty,
                      !Task.isCancelled else { return }
                remember(query, v)
                vector = v
            }
            let semantic = await vectors.search(vector, k: config.semanticK)
            guard !Task.isCancelled else { return }
            let contentIDs = semantic.lazy.map(\.id).filter { Chunk.index($0) != 0 }
            let chunks = contentIDs.isEmpty ? [:] : await vectors.chunkInfo(Array(contentIDs))
            guard !Task.isCancelled else { return }
            continuation.yield(keep(fuse(names: nameHits, fullText: textHits, semantic: semantic, chunks: chunks)))
        }
        state.withLock { $0.semanticTask = task }
        continuation.onTermination = { _ in task.cancel() }
        return (first, stream)
    }

    // MARK: Fusion

    private struct FileHit {
        var score: Float = 0
        var name = false
        var text = false
        var semantic = false
        var exact = false
        var bestText: FullTextHit?
        var bestChunk: ChunkInfo?
        var matches = 0
    }

    /// Name-only convenience (v1 signature): `semantic` ids are item ids of name vectors.
    public func fuse(names: [Hit], semantic: [Hit]) -> [SearchResult] {
        fuse(names: names, semantic: semantic.map { (Chunk.id(item: $0.id), $0.score) })
    }

    /// Reciprocal rank fusion of the four legs, one row per file (see the type doc).
    public func fuse(names: [Hit], fullText: [FullTextHit] = [], semantic: [ChunkHit] = [],
                     chunks: [ChunkID: ChunkInfo] = [:]) -> [SearchResult] {
        let c = config
        var files: [UInt32: FileHit] = [:]
        files.reserveCapacity(names.count + fullText.count + semantic.count)

        for (rank, h) in names.enumerated() where files[h.id]?.name != true {
            files[h.id, default: FileHit()].name = true
            files[h.id]!.score += c.nameWeight / (c.rrfK + Float(rank + 1))
        }

        var textRank = 0
        for hit in fullText {
            var f = files[hit.item] ?? FileHit()
            f.matches += 1
            if !f.text {
                textRank += 1
                f.text = true
                f.score += c.fullTextWeight / (c.rrfK + Float(textRank))
                f.bestText = hit
            } else if hit.isExactPhrase && f.bestText?.isExactPhrase != true {
                f.bestText = hit
            }
            f.exact = f.exact || hit.isExactPhrase
            files[hit.item] = f
        }

        let isImage = { (id: ChunkID) in chunks[id]?.kind == .image }
        let bestText = semantic.lazy.filter { !isImage($0.id) }.map(\.score).max() ?? 0
        let bestImage = semantic.lazy.filter { isImage($0.id) }.map(\.score).max() ?? 0
        let textGate = max(c.semanticThreshold, bestText - c.semanticWindow)
        let imageGate = max(c.imageThreshold, bestImage - c.semanticWindow)
        var semanticRank = 0
        var seen = Set<UInt32>()
        for h in semantic {
            let item = Chunk.item(h.id)
            let firstForFile = seen.insert(item).inserted
            if firstForFile { semanticRank += 1 }
            var f = files[item] ?? FileHit()
            let gate = isImage(h.id) ? imageGate : textGate
            // Files found by name or text keep any semantic evidence; semantic-only files must pass the gate.
            guard f.name || f.text || h.score >= gate else { continue }
            let info = chunks[h.id]
            if info != nil { f.matches += 1 }
            if !f.semantic {
                f.semantic = true
                f.score += c.semanticWeight / (c.rrfK + Float(semanticRank))
            }
            if f.bestChunk == nil, let info { f.bestChunk = info }
            files[item] = f
        }

        // Exact full-text phrase hits outrank every semantic-only file.
        if let floor = files.values.lazy.filter(\.exact).map(\.score).min() {
            for (id, f) in files where f.semantic && !f.name && !f.text && f.score >= floor {
                files[id]!.score = floor.nextDown
            }
        }

        let ranked = files.sorted { a, b in
            a.value.score != b.value.score ? a.value.score > b.value.score : a.key < b.key
        }
        var out: [SearchResult] = []
        out.reserveCapacity(min(ranked.count, c.resultLimit))
        for (id, f) in ranked {
            guard let item = lookup(id) else { continue }
            let source: MatchSource = f.name ? (f.semantic ? .both : .name) : (f.text ? .content : .semantic)
            var match: ContentMatch?
            if let t = f.bestText {
                match = ContentMatch(kind: t.kind, snippet: t.snippet, highlights: t.highlights, location: t.location)
            } else if let ch = f.bestChunk {
                match = ContentMatch(kind: ch.kind == .image ? .image : .semantic, snippet: ch.snippet ?? "",
                                     location: ch.location)
            }
            out.append(SearchResult(item: item, score: f.score, source: source, match: match,
                                    moreMatches: match == nil ? 0 : max(0, f.matches - 1)))
            if out.count == c.resultLimit { break }
        }
        return out
    }

    // MARK: Query-embedding cache (LRU)

    private func remember(_ query: String, _ vector: [Float]) {
        let limit = config.cacheSize
        state.withLock { s in
            if s.cache.updateValue(vector, forKey: query) != nil {
                s.cacheOrder.removeAll { $0 == query }
            }
            s.cacheOrder.append(query)
            while s.cacheOrder.count > limit {
                s.cache[s.cacheOrder.removeFirst()] = nil
            }
        }
    }

    var cachedQueryCount: Int { state.withLock { $0.cache.count } }
}
