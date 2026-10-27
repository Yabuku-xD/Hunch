import Accelerate
import Foundation

#if canImport(llama)
internal import llama
#else
internal import CLlama
#endif

/// Why image embedding is unavailable or failed. Never a crash.
public enum MediaEmbedderError: Error, CustomStringConvertible {
    case libraryMissing(String)
    case projectorMissing
    case modelLoadFailed(String)
    case projectorLoadFailed(String)
    case visionUnsupported
    case tokenizeFailed(Int32)
    case encodeFailed(Int32)
    case processFailed(Int32)
    case closed

    public var description: String {
        switch self {
        case .libraryMissing(let why): "libmtmd not loadable: \(why)"
        case .projectorMissing: "no mmproj next to the model"
        case .modelLoadFailed(let p): "llama.cpp couldn't load \(p)"
        case .projectorLoadFailed(let p): "libmtmd couldn't load \(p)"
        case .visionUnsupported: "the projector has no vision encoder"
        case .tokenizeFailed(let rc): "mtmd_tokenize failed (\(rc))"
        case .encodeFailed(let rc): "mtmd_encode_chunk failed (\(rc))"
        case .processFailed(let rc): "llama_process failed (\(rc))"
        case .closed: "embedder was closed"
        }
    }
}

/// Images (and video frames) → vectors in the text query space, through EmbeddingGemma 2's mmproj on libmtmd
/// (owner: media).
///
/// Each image becomes `<bos> <|image> soft-tokens <image|> <eos>` (70-token budget: the measured cross-modal margin
/// at half the cost of 140), one ENCODE pass with MEAN pooling, L2-normalized, Matryoshka-truncated to `dimension`
/// and renormalized — exactly like `LlamaEmbedder`'s text vectors. All work runs on this actor's executor.
///
/// Call `close()` before process exit (ggml-metal asserts if contexts are alive at exit).
public actor MediaEmbedder {
    public nonisolated let dimension: Int
    public nonisolated let maxImageTokens: Int
    private var rt: MTMDRuntime?

    public init(
        modelURL: URL = Paths.modelURL, projectorURL: URL? = nil, dimension: Int = 256,
        maxImageTokens: Int = 70
    ) throws {
        guard let projector = projectorURL ?? Paths.resolveProjector(for: modelURL),
            FileManager.default.fileExists(atPath: projector.path)
        else { throw MediaEmbedderError.projectorMissing }
        self.rt = try MTMDRuntime(model: modelURL, projector: projector, maxImageTokens: maxImageTokens)
        self.dimension = min(dimension, rt?.outputSize ?? dimension)
        self.maxImageTokens = maxImageTokens
    }

    /// Loads off the caller's executor.
    @concurrent
    public static func load(
        modelURL: URL = Paths.modelURL, projectorURL: URL? = nil, dimension: Int = 256,
        maxImageTokens: Int = 70
    ) async throws -> MediaEmbedder {
        try MediaEmbedder(
            modelURL: modelURL, projectorURL: projectorURL, dimension: dimension,
            maxImageTokens: maxImageTokens)
    }

    /// The vector of one RGB image.
    public func embedImage(_ image: RGBImage) throws -> [Float] {
        guard let rt else { throw MediaEmbedderError.closed }
        return try rt.embedImage(image, dimension: dimension)
    }

    /// A query vector from the same model (`task: search result | query: …`), for comparisons in one space.
    public func embedQuery(_ q: String) throws -> [Float] {
        guard let rt else { throw MediaEmbedderError.closed }
        return try rt.embedText(LlamaEmbedder.queryPrompt(q), dimension: dimension)
    }

    /// Frees the mtmd and llama contexts now.
    public func close() { rt = nil }
}

/// Owns a llama model + ENCODE context + extended batch, and the mtmd context. Only used from `MediaEmbedder`.
private final class MTMDRuntime {
    private static let backend: Void = {
        let quiet: ggml_log_callback = { level, text, _ in
            guard level.rawValue >= GGML_LOG_LEVEL_ERROR.rawValue, let text else { return }
            fputs(String(cString: text), stderr)
        }
        llama_log_set(quiet, nil)
        mtmd_helper_log_set(quiet, nil)
        llama_backend_init()
    }()

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let batch: OpaquePointer
    private let mtmd: OpaquePointer
    private let inputWidth: Int
    let outputSize: Int
    private var position: Int32 = 0

    init(model modelURL: URL, projector: URL, maxImageTokens: Int) throws {
        _ = Self.backend
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(modelURL.path, mp) else {
            throw MediaEmbedderError.modelLoadFailed(modelURL.path)
        }
        var cp = llama_context_default_params()
        cp.n_ctx = 2048
        cp.n_batch = 2048
        cp.n_ubatch = 2048
        cp.n_seq_max = 1
        cp.kv_unified = true
        cp.embeddings = true
        cp.pooling_type = LLAMA_POOLING_TYPE_MEAN
        guard let context = llama_init_from_model(model, cp) else {
            llama_model_free(model)
            throw MediaEmbedderError.modelLoadFailed(modelURL.path)
        }
        guard let vocab = llama_model_get_vocab(model), let batch = llama_batch_ext_init(context) else {
            llama_free(context)
            llama_model_free(model)
            throw MediaEmbedderError.modelLoadFailed(modelURL.path)
        }
        var params = mtmd_context_params_default()
        params.use_gpu = true
        params.print_timings = false
        params.warmup = true
        params.image_min_tokens = 1
        params.image_max_tokens = Int32(maxImageTokens)
        guard let mtmd = mtmd_init_from_file(projector.path, model, params) else {
            llama_batch_ext_free(batch)
            llama_free(context)
            llama_model_free(model)
            throw MediaEmbedderError.projectorLoadFailed(projector.path)
        }
        guard mtmd_support_vision(mtmd) else {
            mtmd_free(mtmd)
            llama_batch_ext_free(batch)
            llama_free(context)
            llama_model_free(model)
            throw MediaEmbedderError.visionUnsupported
        }
        self.model = model
        self.context = context
        self.vocab = vocab
        self.batch = batch
        self.mtmd = mtmd
        self.inputWidth = Int(llama_model_n_embd_inp(model))
        self.outputSize = Int(llama_model_n_embd_out(model))
    }

    deinit {
        mtmd_free(mtmd)
        llama_batch_ext_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    private func reset() {
        llama_batch_ext_clear(batch)
        position = 0
    }

    private func place(_ idx: Int32) throws {
        guard idx >= 0 else { throw MediaEmbedderError.processFailed(idx) }
        var pos: [llama_pos] = [position, 0, 0, 0]
        _ = llama_batch_ext_set_pos(batch, idx, &pos)
        _ = llama_batch_ext_set_output_embd(batch, idx, true)
        position += 1
    }

    private func run(dimension: Int) throws -> [Float] {
        if let memory = llama_get_memory(context) { llama_memory_clear(memory, true) }
        let rc = llama_process(context, LLAMA_PROCESS_TYPE_ENCODE, batch)
        guard rc == 0 else { throw MediaEmbedderError.processFailed(rc) }
        guard let e = llama_get_embeddings_seq(context, 0) else { throw MediaEmbedderError.processFailed(-10) }
        let prefix = Array(UnsafeBufferPointer(start: e, count: min(dimension, outputSize)))
        let norm = sqrt(vDSP.sumOfSquares(prefix))
        guard norm > 0, norm.isFinite else { return prefix }
        return vDSP.divide(prefix, norm)
    }

    func embedText(_ prompt: String, dimension: Int) throws -> [Float] {
        reset()
        defer { reset() }
        let utf8 = Array(prompt.utf8)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        let n = utf8.withUnsafeBufferPointer { p in
            p.withMemoryRebound(to: CChar.self) {
                llama_tokenize(vocab, $0.baseAddress, Int32(utf8.count), &tokens, Int32(tokens.count), true, false)
            }
        }
        guard n > 0 else { throw MediaEmbedderError.tokenizeFailed(n) }
        for t in tokens.prefix(min(Int(n), 512)) { try place(llama_batch_ext_add_token(batch, 0, t)) }
        return try run(dimension: dimension)
    }

    func embedImage(_ image: RGBImage, dimension: Int) throws -> [Float] {
        guard image.width > 0, image.height > 0, image.bytes.count == image.width * image.height * 3 else {
            throw MediaEmbedderError.tokenizeFailed(-1)
        }
        reset()
        defer { reset() }
        let bitmap = image.bytes.withUnsafeBufferPointer {
            mtmd_bitmap_init(UInt32(image.width), UInt32(image.height), $0.baseAddress)
        }
        guard let bitmap else { throw MediaEmbedderError.tokenizeFailed(-2) }
        defer { mtmd_bitmap_free(bitmap) }
        guard let chunks = mtmd_input_chunks_init() else { throw MediaEmbedderError.tokenizeFailed(-3) }
        defer { mtmd_input_chunks_free(chunks) }
        let marker = mtmd_default_marker()
        var input = mtmd_input_text(
            text: marker, text_len: marker.map { strlen($0) } ?? 0,
            add_special: true, parse_special: true)
        var bitmaps: [OpaquePointer?] = [bitmap]
        let rc = bitmaps.withUnsafeMutableBufferPointer { mtmd_tokenize(mtmd, chunks, &input, $0.baseAddress, 1) }
        guard rc == 0 else { throw MediaEmbedderError.tokenizeFailed(rc) }
        for i in 0..<mtmd_input_chunks_size(chunks) {
            let chunk = mtmd_input_chunks_get(chunks, i)
            if mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT {
                var n = 0
                guard let toks = mtmd_input_chunk_get_tokens_text(chunk, &n) else { continue }
                for k in 0..<n { try place(llama_batch_ext_add_token(batch, 0, toks[k])) }
            } else {
                let enc = mtmd_encode_chunk(mtmd, chunk)
                guard enc == 0, let rows = mtmd_get_output_embd(mtmd) else {
                    throw MediaEmbedderError.encodeFailed(enc)
                }
                for k in 0..<mtmd_input_chunk_get_n_tokens(chunk) {
                    let e = llama_embd(data: rows + k * inputWidth, n_rows: 1, n_embd: inputWidth)
                    try place(llama_batch_ext_add_embd(batch, 0, e))
                }
            }
        }
        return try run(dimension: dimension)
    }
}
