import Foundation
import HunchCore

// The embedding helper the app launches (`ProcessEmbedder`): `hunch-embedder <model.gguf> <dimension>`.
// Loads the model, answers `EmbedderWire` requests on stdin/stdout one at a time, exits at end of input.

// As in the app: no Metal residency sets (a keep-alive loop that never stops once a model has loaded).
setenv("GGML_METAL_NO_RESIDENCY", "1", 0)

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
let args = CommandLine.arguments
guard args.count == 3, let dimension = Int(args[2]) else {
    FileHandle.standardError.write(Data("usage: hunch-embedder <model.gguf> <dimension>\n".utf8))
    exit(64)
}

func serve() async -> Int32 {
    let embedder: LlamaEmbedder
    do {
        embedder = try await LlamaEmbedder.load(modelURL: URL(fileURLWithPath: args[1]), dimension: dimension)
        try EmbedderWire.writeHandshake(output, width: embedder.modelDimension)
    } catch {
        try? EmbedderWire.writeError(output, error as? EmbedderError ?? .modelLoadFailed(args[1]))
        return 1
    }
    while true {
        let request: (queries: [String]?, documents: [(String, String)]?)?
        do { request = try EmbedderWire.readRequest(input) } catch { return 1 }
        guard let request else { return 0 }
        do {
            let vectors =
                if let q = request.queries {
                    try await embedder.embedQueries(q)
                } else {
                    try await embedder.embedDocuments((request.documents ?? []).map { (title: $0.0, text: $0.1) })
                }
            try EmbedderWire.writeVectors(output, vectors)
        } catch let e as EmbedderError {
            do { try EmbedderWire.writeError(output, e) } catch { return 1 }
        } catch {
            return 1
        }
    }
}

// The model is released before `exit`: ggml's Metal device asserts when a model is still loaded at teardown.
exit(await serve())
