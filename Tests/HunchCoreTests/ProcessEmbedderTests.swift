import Foundation
import Testing

@testable import HunchCore

@Suite struct EmbedderWireTests {
    @Test func requestsRoundTrip() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: EmbedderWire.encodeQueries(["dog photos", "", "合同 租赁"]))
        try pipe.fileHandleForWriting.write(
            contentsOf: EmbedderWire.encodeDocuments([(title: "a.txt", text: "drill"), (title: "", text: "")]))
        try pipe.fileHandleForWriting.write(
            contentsOf: EmbedderWire.encodeImage(RGBImage(width: 2, height: 1, bytes: [1, 2, 3, 4, 5, 6])))
        try pipe.fileHandleForWriting.close()
        let first = try #require(try EmbedderWire.readRequest(pipe.fileHandleForReading))
        #expect(first.queries == ["dog photos", "", "合同 租赁"])
        let second = try #require(try EmbedderWire.readRequest(pipe.fileHandleForReading))
        #expect(second.documents?.map(\.0) == ["a.txt", ""])
        #expect(second.documents?.map(\.1) == ["drill", ""])
        let third = try #require(try EmbedderWire.readRequest(pipe.fileHandleForReading)?.image)
        #expect(third.width == 2 && third.height == 1 && third.bytes == [1, 2, 3, 4, 5, 6])
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

    /// The image helper must give the same vector as the in-process image model. Needs the model, its projector and
    /// a built `hunch-embedder`; skipped otherwise.
    @Test(.disabled(if: isCI, "CI does not download the model"))
    func imageHelperMatchesInProcess() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let helper = root.appendingPathComponent(".build/release/hunch-embedder")
        guard let model = Paths.resolveModel(), let projector = Paths.resolveProjector(for: model),
            FileManager.default.isExecutableFile(atPath: helper.path)
        else { return }
        let bytes = (0..<(64 * 48 * 3)).map { UInt8(truncatingIfNeeded: $0 * 7) }
        let image = RGBImage(width: 64, height: 48, bytes: bytes)
        let remote = try await ProcessImageEmbedder.launch(
            helper: helper, modelURL: model, projectorURL: projector, dimension: 256)
        let local = try await MediaEmbedder.load(modelURL: model, projectorURL: projector, dimension: 256)
        let (r, l) = (try await remote.embedImage(image), try await local.embedImage(image))
        await local.close()
        #expect(r.count == 256)
        #expect(zip(r, l).map(*).reduce(0, +) > 0.999)
    }

    /// Regression: every request leaked its pipe reads in the helper (NSData autoreleased on a thread whose pool never
    /// drained), about 8 KB per 8 KB read, 1.1 GB after an hour of indexing. Large requests must not grow the helper.
    @Test(.disabled(if: isCI, "CI does not download the model"))
    func helperMemoryStaysFlat() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let helper = root.appendingPathComponent(".build/release/hunch-embedder")
        guard let model = Paths.resolveModel(), FileManager.default.isExecutableFile(atPath: helper.path) else {
            return
        }
        let remote = try await ProcessEmbedder.launch(helper: helper, modelURL: model, dimension: 256)
        let pid = try #require(await remote.helperPID)
        let text = String(repeating: "invoice total due ", count: 4000)
        let batch = (0..<8).map { (title: "doc\($0).txt", text: text) }
        func footprint() -> UInt64 {
            var info = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            return rc == 0 ? info.ri_phys_footprint : 0
        }
        _ = try await remote.embedDocuments(batch)
        let before = footprint()
        for _ in 0..<40 { _ = try await remote.embedDocuments(batch) }
        let grown = Int64(footprint()) - Int64(before)
        // 40 requests of about 550 KB each: the leak grew the helper by over 20 MB.
        #expect(grown < 8 << 20, "helper grew \(grown >> 20) MB")
    }
}
