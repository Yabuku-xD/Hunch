import Foundation
import Testing

@testable import HunchCore

@Suite struct EmbedderWireTests {
    @Test func requestsRoundTrip() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: EmbedderWire.encodeQueries(["dog photos", "", "合同 租赁"]))
        try pipe.fileHandleForWriting.write(
            contentsOf: EmbedderWire.encodeDocuments([(title: "a.txt", text: "drill"), (title: "", text: "")]))
        try pipe.fileHandleForWriting.close()
        let first = try #require(try EmbedderWire.readRequest(pipe.fileHandleForReading))
        #expect(first.queries == ["dog photos", "", "合同 租赁"])
        let second = try #require(try EmbedderWire.readRequest(pipe.fileHandleForReading))
        #expect(second.documents?.map(\.0) == ["a.txt", ""])
        #expect(second.documents?.map(\.1) == ["drill", ""])
        #expect(try EmbedderWire.readRequest(pipe.fileHandleForReading) == nil)
    }

    @Test func repliesRoundTrip() throws {
        let pipe = Pipe()
        let vectors: [[Float]] = [[0.5, -0.25, 1], [0, 2, -3]]
        try EmbedderWire.writeVectors(pipe.fileHandleForWriting, vectors)
        try EmbedderWire.writeVectors(pipe.fileHandleForWriting, [])
        try EmbedderWire.writeError(pipe.fileHandleForWriting, .invalidDimension(requested: 900, model: 768))
        #expect(try EmbedderWire.readVectors(pipe.fileHandleForReading) == vectors)
        #expect(try EmbedderWire.readVectors(pipe.fileHandleForReading) == [])
        #expect(throws: EmbedderError.invalidDimension(requested: 900, model: 768)) {
            try EmbedderWire.readVectors(pipe.fileHandleForReading)
        }
    }

    /// The helper must give the same vectors as the in-process runtime. Needs the model and a built
    /// `hunch-embedder` (`swift build -c release --product hunch-embedder`); skipped otherwise.
    @Test(.disabled(if: isCI, "CI does not download the 865 MB model"))
    func helperMatchesInProcess() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let helper = root.appendingPathComponent(".build/release/hunch-embedder")
        guard let model = Paths.resolveModel(), FileManager.default.isExecutableFile(atPath: helper.path) else {
            return
        }
        let remote = try await ProcessEmbedder.launch(helper: helper, modelURL: model, dimension: 256)
        let local = try await LlamaEmbedder.load(modelURL: model, dimension: 256)
        let q = ["dog photos", "tax return 2023"]
        let d = [(title: "invoice.pdf", text: "Acme invoice total 226.80")]
        let (rq, lq) = (try await remote.embedQueries(q), try await local.embedQueries(q))
        let (rd, ld) = (try await remote.embedDocuments(d), try await local.embedDocuments(d))
        for (a, b) in zip(rq + rd, lq + ld) {
            #expect(zip(a, b).map(*).reduce(0, +) > 0.9999)
        }
    }
}
