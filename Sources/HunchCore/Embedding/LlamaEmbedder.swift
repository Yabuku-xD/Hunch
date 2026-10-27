import Accelerate
import Foundation

#if canImport(llama)
internal import llama
#else
internal import CLlama
#endif

/// Why the embedder couldn't load or run. Never a crash.
public enum EmbedderError: Error, Equatable, CustomStringConvertible {
    case modelMissing(String)
    case modelLoadFailed(String)
    case contextFailed
    case invalidDimension(requested: Int, model: Int)
    case tokenizeFailed(String)
    case decodeFailed(Int32)
    case noEmbedding(sequence: Int)

    /// The model can't be used at all (as opposed to one bad input): switch to name-only mode.
    public var isUnavailable: Bool {
        switch self {
        case .modelMissing, .modelLoadFailed, .contextFailed, .invalidDimension: true
        case .tokenizeFailed, .decodeFailed, .noEmbedding: false
        }
    }

    public var description: String {
        switch self {
        case .modelMissing(let p): "embedding model not found at \(p)"
        case .modelLoadFailed(let p): "llama.cpp couldn't load \(p)"
        case .contextFailed: "llama.cpp couldn't create an embedding context"
        case .invalidDimension(let r, let m): "dimension \(r) isn't in 1...\(m)"
        case .tokenizeFailed(let t): "couldn't tokenize \(t.prefix(40))"
        case .decodeFailed(let rc): "llama_decode failed (\(rc))"
        case .noEmbedding(let s): "no pooled embedding for input \(s)"
        }
    }
}

/// EmbeddingGemma 2 on llama.cpp, in process, on Metal (owner: engine).
///
/// The model loads once and stays warm. Inputs are packed into batches of ≤ 64 sequences and ≤ 2,048 tokens
/// (the 0.7.0 runtime crashes on bigger ones), pooled as the gguf says (MEAN for this model), L2-normalized,
/// Matryoshka-truncated to `dimension` (default 256) and renormalized. All llama.cpp work runs on this actor's
/// executor, never the main actor.
public actor LlamaEmbedder: Embedder {
    public nonisolated let modelURL: URL
    public nonisolated let dimension: Int
    /// Width of the model's pooled output (768 for EmbeddingGemma 2).
    public nonisolated let modelDimension: Int

    private let runtime: LlamaRuntime

    public static let queryPrefix = "task: search result | query: "

    public static func queryPrompt(_ q: String) -> String { queryPrefix + q }

    /// `title: {title} | text: {text}`; an empty title becomes `none`.
    public static func documentPrompt(title: String, text: String) -> String {
        "title: \(title.isEmpty ? "none" : title) | text: \(text)"
    }

    /// Loads the model synchronously (≈0.4 s). Prefer `load(...)` from async code.
    public init(modelURL: URL = Paths.modelURL, dimension: Int = 256) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw EmbedderError.modelMissing(modelURL.path)
        }
        let runtime = try autoreleasepool { try LlamaRuntime(modelURL: modelURL) }
        guard dimension > 0, dimension <= runtime.outputSize else {
            throw EmbedderError.invalidDimension(requested: dimension, model: runtime.outputSize)
        }
        // Build the Metal pipelines now so the first real query is warm.
        _ = try runtime.embed([Self.queryPrompt("warm up")], dimension: dimension, role: .query)
        self.modelURL = modelURL
        self.dimension = dimension
        self.modelDimension = runtime.outputSize
        self.runtime = runtime
    }

    /// Loads off the caller's executor.
    @concurrent
    public static func load(modelURL: URL = Paths.modelURL, dimension: Int = 256) async throws -> LlamaEmbedder {
        try LlamaEmbedder(modelURL: modelURL, dimension: dimension)
    }

    public func embedQueries(_ q: [String]) async throws -> [[Float]] {
        try runtime.embed(q.map(Self.queryPrompt), dimension: dimension, role: .query)
    }

    public func embedDocuments(_ d: [(title: String, text: String)]) async throws -> [[Float]] {
        try runtime.embed(
            d.map { Self.documentPrompt(title: $0.title, text: $0.text) }, dimension: dimension, role: .document)
    }

    /// Embeds already-templated prompts.
    public func embedRaw(_ prompts: [String]) async throws -> [[Float]] {
        try runtime.embed(prompts, dimension: dimension, role: .document)
    }
}

/// Owns the llama.cpp model and its contexts. Not thread-safe; only used from `LlamaEmbedder`'s executor.
///
/// Two contexts share one set of weights, each created on first use: a small one for search queries (one input of at
/// most `maxInputTokens`) and a wide one for indexing batches. A search-only load never allocates the wide context's
/// compute buffers, which are about 4x the small one's.
final class LlamaRuntime {
    static let maxSequences = 64
    static let maxBatchTokens = 2048
    static let maxInputTokens = 512
    static let maxQuerySequences = 4
    /// Search queries are a few words; longer ones are cut here like documents are cut at `maxInputTokens`.
    static let maxQueryTokens = 128

    enum Role {
        case query, document

        var tokens: Int { self == .query ? LlamaRuntime.maxQueryTokens : LlamaRuntime.maxBatchTokens }
        var inputTokens: Int { self == .query ? LlamaRuntime.maxQueryTokens : LlamaRuntime.maxInputTokens }
        var sequences: Int { self == .query ? LlamaRuntime.maxQuerySequences : LlamaRuntime.maxSequences }
    }

    /// One llama.cpp context and its token batch.
    private final class Slot {
        let context: OpaquePointer
        var batch: llama_batch

        init(context: OpaquePointer, tokens: Int) {
            self.context = context
            batch = llama_batch_init(Int32(tokens), 0, 1)
        }

        deinit {
            llama_batch_free(batch)
            llama_free(context)
        }
    }

    private static let backend: Void = {
        llama_log_set(
            { level, text, _ in
                guard level.rawValue >= GGML_LOG_LEVEL_ERROR.rawValue, let text else { return }
                fputs(String(cString: text), stderr)
            }, nil)
        llama_backend_init()
    }()

    private let model: OpaquePointer
    private let vocab: OpaquePointer
    private var querySlot: Slot?
    private var documentSlot: Slot?
    let outputSize: Int
    private var pooling: llama_pooling_type

    init(modelURL: URL) throws {
        _ = Self.backend
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 99
        guard let model = llama_model_load_from_file(modelURL.path, mp) else {
            throw EmbedderError.modelLoadFailed(modelURL.path)
        }
        guard let vocab = llama_model_get_vocab(model) else {
            llama_model_free(model)
            throw EmbedderError.modelLoadFailed(modelURL.path)
        }
        self.model = model
        self.vocab = vocab
        outputSize = Int(llama_model_n_embd_out(model))
        pooling = LLAMA_POOLING_TYPE_UNSPECIFIED
        querySlot = try makeSlot(.query)
    }

    deinit {
        autoreleasepool {
            querySlot = nil
            documentSlot = nil
            llama_model_free(model)
        }
    }

    private func makeSlot(_ role: Role) throws -> Slot {
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(role.tokens)
        cp.n_batch = UInt32(role.tokens)
        cp.n_ubatch = UInt32(role.tokens)
        cp.n_seq_max = UInt32(role.sequences)
        cp.kv_unified = true
        cp.embeddings = true
        cp.pooling_type = LLAMA_POOLING_TYPE_UNSPECIFIED  // as the gguf says (MEAN here)
        guard let context = llama_init_from_model(model, cp) else { throw EmbedderError.contextFailed }
        pooling = llama_pooling_type(context)
        return Slot(context: context, tokens: role.tokens)
    }

    private func slot(_ role: Role) throws -> Slot {
        switch role {
        case .query:
            if let querySlot { return querySlot }
            let s = try makeSlot(.query)
            querySlot = s
            return s
        case .document:
            if let documentSlot { return documentSlot }
            let s = try makeSlot(.document)
            documentSlot = s
            return s
        }
    }

    /// Metal objects ggml autoreleases on this (non-main) thread would otherwise outlive the call.
    func embed(_ prompts: [String], dimension: Int, role: Role) throws -> [[Float]] {
        try autoreleasepool { try embedInPool(prompts, dimension: dimension, role: role) }
    }

    private func embedInPool(_ prompts: [String], dimension: Int, role: Role) throws -> [[Float]] {
        let slot = try slot(role)
        var out: [[Float]] = []
        out.reserveCapacity(prompts.count)
        var pending: [[llama_token]] = []
        var pendingTokens = 0
        for prompt in prompts {
            let tokens = try tokenize(prompt, limit: role.inputTokens)
            if pending.count == role.sequences || pendingTokens + tokens.count > role.tokens {
                out += try run(pending, dimension: dimension, slot: slot)
                pending.removeAll(keepingCapacity: true)
                pendingTokens = 0
            }
            pending.append(tokens)
            pendingTokens += tokens.count
        }
        if !pending.isEmpty { out += try run(pending, dimension: dimension, slot: slot) }
        return out
    }

    private func tokenize(_ text: String, limit: Int) throws -> [llama_token] {
        let utf8 = Array(text.utf8)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        var n = utf8.withUnsafeBufferPointer { p in
            p.withMemoryRebound(to: CChar.self) {
                llama_tokenize(vocab, $0.baseAddress, Int32(utf8.count), &tokens, Int32(tokens.count), true, false)
            }
        }
        if n < 0, n != Int32.min {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = utf8.withUnsafeBufferPointer { p in
                p.withMemoryRebound(to: CChar.self) {
                    llama_tokenize(vocab, $0.baseAddress, Int32(utf8.count), &tokens, Int32(tokens.count), true, false)
                }
            }
        }
        guard n > 0 else { throw EmbedderError.tokenizeFailed(text) }
        tokens.removeLast(tokens.count - Int(n))
        if tokens.count > limit {
            tokens = Array(tokens[0..<(limit - 1)]) + [llama_vocab_eos(vocab)]
        }
        return tokens
    }

    /// One llama_decode over ≤ maxSequences inputs whose tokens fit one ubatch.
    private func run(_ seqs: [[llama_token]], dimension: Int, slot: Slot) throws -> [[Float]] {
        let context = slot.context
        var n: Int32 = 0
        for (s, tokens) in seqs.enumerated() {
            for (pos, token) in tokens.enumerated() {
                let i = Int(n)
                slot.batch.token[i] = token
                slot.batch.pos[i] = llama_pos(pos)
                slot.batch.n_seq_id[i] = 1
                slot.batch.seq_id[i]![0] = llama_seq_id(s)
                slot.batch.logits[i] = 1
                n += 1
            }
        }
        slot.batch.n_tokens = n
        if let memory = llama_get_memory(context) { llama_memory_clear(memory, true) }
        let rc = llama_decode(context, slot.batch)
        guard rc == 0 else { throw EmbedderError.decodeFailed(rc) }

        var vectors: [[Float]] = []
        vectors.reserveCapacity(seqs.count)
        var offset = 0
        for (s, tokens) in seqs.enumerated() {
            var full = [Float](repeating: 0, count: outputSize)
            if pooling == LLAMA_POOLING_TYPE_NONE {
                // Pool ourselves: mean over the sequence's token embeddings.
                for t in 0..<tokens.count {
                    guard let e = llama_get_embeddings_ith(context, Int32(offset + t)) else {
                        throw EmbedderError.noEmbedding(sequence: s)
                    }
                    vDSP_vadd(full, 1, e, 1, &full, 1, vDSP_Length(outputSize))
                }
            } else {
                guard let pooled = llama_get_embeddings_seq(context, llama_seq_id(s)) else {
                    throw EmbedderError.noEmbedding(sequence: s)
                }
                full.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: pooled, count: outputSize) }
            }
            offset += tokens.count
            // Normalizing the full vector and then the prefix equals normalizing the prefix directly.
            vectors.append(Self.normalized(Array(full[0..<dimension])))
        }
        return vectors
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(vDSP.sumOfSquares(v))
        guard norm > 0, norm.isFinite else { return v }
        return vDSP.divide(v, norm)
    }
}
