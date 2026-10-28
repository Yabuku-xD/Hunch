import Foundation
import HunchCore

// The embedding helper the app launches (`ProcessEmbedder`): `hunch-embedder <model.gguf> <dimension>` for text, or
// `hunch-embedder --image <model.gguf> <mmproj.gguf> <dimension>` for images (`ProcessImageEmbedder`).
// Loads the model, answers `EmbedderWire` requests on stdin/stdout one at a time, exits at end of input.

// As in the app: no Metal residency sets (a keep-alive loop that never stops once a model has loaded).
setenv("GGML_METAL_NO_RESIDENCY", "1", 0)

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
let args = CommandLine.arguments
let imageMode = args.count == 5 && args[1] == "--image"
guard (args.count == 3 && !imageMode) || imageMode, let dimension = Int(args[args.count - 1]) else {
    FileHandle.standardError.write(
        Data("usage: hunch-embedder <model.gguf> <dimension> | --image <model.gguf> <mmproj.gguf> <dimension>\n".utf8))
    exit(64)
}

/// Answers requests until end of input. `answer` returns nil for a request this mode does not handle.
func loop(
    _ answer: (_ queries: [String]?, _ documents: [(String, String)]?, _ image: RGBImage?) async throws -> [[Float]]?
)
    async -> Int32
{
    while true {
        let request: (queries: [String]?, documents: [(String, String)]?, image: RGBImage?)?
        do { request = try EmbedderWire.readRequest(input) } catch { return 1 }
        guard let request else { return 0 }
        do {
            guard let vectors = try await answer(request.queries, request.documents, request.image) else {
                throw EmbedderError.decodeFailed(-2)
            }
            try EmbedderWire.writeVectors(output, vectors)
        } catch let e as EmbedderError {
            do { try EmbedderWire.writeError(output, e) } catch { return 1 }
        } catch let e as MediaEmbedderError {
            do { try EmbedderWire.writeError(output, .tokenizeFailed(e.description)) } catch { return 1 }
        } catch {
            return 1
        }
    }
}

func serveText() async -> Int32 {
    let embedder: LlamaEmbedder
    do {
        embedder = try await LlamaEmbedder.load(modelURL: URL(fileURLWithPath: args[1]), dimension: dimension)
        try EmbedderWire.writeHandshake(output, width: embedder.modelDimension)
    } catch {
        try? EmbedderWire.writeError(output, error as? EmbedderError ?? .modelLoadFailed(args[1]))
        return 1
    }
    return await loop { queries, documents, _ in
        if let queries { return try await embedder.embedQueries(queries) }
        if let documents { return try await embedder.embedDocuments(documents.map { (title: $0.0, text: $0.1) }) }
        return nil
    }
}

func serveImages() async -> Int32 {
    let embedder: MediaEmbedder
    do {
        embedder = try await MediaEmbedder.load(
            modelURL: URL(fileURLWithPath: args[2]), projectorURL: URL(fileURLWithPath: args[3]), dimension: dimension)
        try EmbedderWire.writeHandshake(output, width: embedder.dimension)
    } catch {
        try? EmbedderWire.writeError(output, .modelLoadFailed("\(error)"))
        return 1
    }
    let status = await loop { _, _, image in
        guard let image else { return nil }
        return [try await embedder.embedImage(image)]
    }
    await embedder.close()
    return status
}

// The model is released before `exit`: ggml's Metal device asserts when a model is still loaded at teardown.
exit(imageMode ? await serveImages() : await serveText())
