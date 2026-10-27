import Foundation
import HunchCore

/// `--embed-eval <model.gguf> <in.json> <out.json>`: embeds `{"queries": [String], "docs": [{"title", "text"}]}` with
/// the app's own runtime (prompts, pooling, Metal) at the full 768 dimensions and writes `{"queries": [[Double]],
/// "docs": [[Double]]}`. `Scripts/quant-eval.py` compares quantizations against a BF16 reference with it.
func embedEval(model: String, input: String, output: String) async -> Int32 {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: input))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let queries = obj["queries"] as? [String], let docs = obj["docs"] as? [[String: String]]
        else {
            FileHandle.standardError.write(Data("embed-eval: bad input\n".utf8))
            return 1
        }
        let embedder = try await LlamaEmbedder.load(modelURL: URL(fileURLWithPath: model), dimension: 768)
        let q = try await embedder.embedQueries(queries)
        let d = try await embedder.embedDocuments(docs.map { (title: $0["title"] ?? "", text: $0["text"] ?? "") })
        let json = try JSONSerialization.data(withJSONObject: [
            "queries": q.map { $0.map(Double.init) }, "docs": d.map { $0.map(Double.init) },
        ])
        try json.write(to: URL(fileURLWithPath: output))
        print("embed_eval_vectors=\(q.count + d.count)")
        return 0
    } catch {
        FileHandle.standardError.write(Data("embed-eval failed: \(error)\n".utf8))
        return 1
    }
}
