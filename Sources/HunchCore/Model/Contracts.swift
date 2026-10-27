/// Shared contracts between HunchCore and the app (see CONTRIBUTING.md, "Code map").

/// Turns text into L2-normalized vectors of length `dimension`.
/// Queries use `task: search result | query: {q}`; documents use `title: {title} | text: {text}`.
public protocol Embedder: Sendable {
    var dimension: Int { get }
    func embedQueries(_ q: [String]) async throws -> [[Float]]
    func embedDocuments(_ d: [(title: String, text: String)]) async throws -> [[Float]]
}

/// Dense vector store keyed by `ChunkID` (many vectors per file); scores are cosine similarity (dot product of
/// normalized vectors). Chunk index 0 of an item is its name document and needs no `ChunkInfo`; content chunks
/// (index ≥ 1) carry a `ChunkInfo` row saying what they are and where they sit in the file.
public protocol VectorIndex: Sendable {
    func upsert(_ id: ChunkID, _ v: [Float]) async
    func remove(_ id: ChunkID) async
    func search(_ q: [Float], k: Int) async -> [(id: ChunkID, score: Float)]
    /// Removes every chunk (name + content) of `item`, with their `ChunkInfo` rows.
    func removeItem(_ item: UInt32) async
    /// Stores content chunks: their vectors plus `ChunkInfo` rows, in one batch.
    func upsertChunks(_ chunks: [(info: ChunkInfo, vector: [Float])]) async
    /// `ChunkInfo` for the content chunks among `ids` (name chunks and unknown ids are absent).
    func chunkInfo(_ ids: [ChunkID]) async -> [ChunkID: ChunkInfo]
    /// The stored vector for `id` (as persisted, e.g. Float16-rounded), or nil when absent. Used to reuse vectors
    /// across identical inputs and to clone rows to a renamed/copied file without re-embedding.
    func storedVector(_ id: ChunkID) async -> [Float]?
}

public extension VectorIndex {
    func removeItem(_ item: UInt32) async { await remove(Chunk.id(item: item)) }
    func upsertChunks(_ chunks: [(info: ChunkInfo, vector: [Float])]) async {
        for c in chunks { await upsert(c.info.id, c.vector) }
    }
    func chunkInfo(_ ids: [ChunkID]) async -> [ChunkID: ChunkInfo] { [:] }
    func storedVector(_ id: ChunkID) async -> [Float]? { nil }
}

/// Synchronous name/fuzzy matcher. Must be lock-free-read or Mutex-guarded; called on every keystroke.
public protocol NameIndexing: Sendable {
    func search(_ q: String, limit: Int) -> [(id: UInt32, score: Float)]
}

/// Query front door. The stream emits name hits first (synchronously, never waiting on the model), then fused
/// lists as the full-text and semantic legs arrive, then finishes. Rows are one per file and `SearchResult.id`
/// (the item id) never changes between emissions, so a selected row keeps its identity.
public protocol SearchEngine: Sendable {
    func results(for q: String) -> AsyncStream<[SearchResult]>
    /// The same contract with the synchronous name batch handed back directly, so a UI can draw it in the keystroke's
    /// own frame (reading an `AsyncStream` element always costs a run-loop hop, i.e. one frame). `rest` carries only
    /// the later batches. `first == nil` means the engine has no synchronous batch; read everything from `rest`.
    func start(_ q: String) -> (first: [SearchResult]?, rest: AsyncStream<[SearchResult]>)
    /// What to show for the empty query: Favorites (pinned, in user order) then Recents. Empty sections are omitted.
    func suggestions() -> [SearchSection]
}

public extension SearchEngine {
    func suggestions() -> [SearchSection] { [] }
    func start(_ q: String) -> (first: [SearchResult]?, rest: AsyncStream<[SearchResult]>) { (nil, results(for: q)) }
}

/// Full-text index over extracted document text, OCR text and transcripts (owner: media). Must answer
/// synchronously within 15 ms; hits are returned best first.
public protocol FullTextIndexing: Sendable {
    func search(_ q: String, limit: Int) -> [FullTextHit]
}

/// Background content extraction (text, OCR, transcripts, frames) and chunk embedding (owner: media).
/// The backend enqueues changed files and removes deleted ones; it pauses the pipeline while the panel is visible.
public protocol ContentPipeline: Sendable {
    func enqueue(_ items: [Item]) async
    func remove(_ ids: [UInt32]) async
    func pause() async
    func resume() async
    var status: ContentPipelineStatus { get async }
    /// Reads `item` ahead of the background order (`SearchBackend.indexNow`).
    func prioritize(_ item: Item) async
}

public extension ContentPipeline {
    func prioritize(_ item: Item) async { await enqueue([item]) }
}

/// Live indexing state for the UI (status line, model-missing notice).
public protocol IndexStatusProviding: Sendable {
    /// The latest status.
    var indexStatus: IndexStatus { get }
    /// Emits the current status at once, then every change. Each call returns an independent stream.
    func indexStatusUpdates() -> AsyncStream<IndexStatus>
}
