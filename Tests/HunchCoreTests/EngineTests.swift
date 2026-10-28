import Foundation
import Testing

@testable import HunchCore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("EngineTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct SplitMix {
    var state: UInt64
    mutating func next() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(Double(z >> 11) / Double(1 << 53)) * 2 - 1
    }
    mutating func unitVector(_ d: Int) -> [Float] {
        LlamaRuntime.normalized((0..<d).map { _ in next() })
    }
}

private func dot(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
}

@Suite("Engine: VectorStore")
struct EngineVectorStoreTests {
    @Test func topKEqualsBruteForceOn5kRandomVectors() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try VectorStore(directory: dir, dimension: 256)
        var rng = SplitMix(state: 42)
        var vectors: [(id: ChunkID, vector: [Float])] = []
        for i in 0..<5000 { vectors.append((ChunkID(i * 3 + 7), rng.unitVector(256))) }
        try await store.upsert(vectors)
        #expect(await store.count == 5000)

        // Brute force over the same Float16-rounded data the store holds.
        let rounded = vectors.map { ($0.id, $0.vector.map { Float(Float16($0)) }) }
        for _ in 0..<20 {
            let q = rng.unitVector(256)
            let expected = rounded.map { (id: $0.0, score: dot($0.1, q)) }
                .sorted { $0.score > $1.score }.prefix(10)
            let got = await store.search(q, k: 10)
            #expect(got.map(\.id) == expected.map(\.id))
            for (g, e) in zip(got, expected) { #expect(abs(g.score - e.score) < 1e-4) }
        }
        // k larger than n returns everything, sorted.
        let all = await store.search(rng.unitVector(256), k: 10_000)
        #expect(all.count == 5000)
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.score >= $1.score })
    }

    @Test func persistenceRoundtripAfterReopen() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var rng = SplitMix(state: 7)
        let vectors = (0..<3000).map { (id: ChunkID($0 + 1), vector: rng.unitVector(256)) }
        let q = rng.unitVector(256)
        var before: [(id: ChunkID, score: Float)] = []
        do {
            let store = try VectorStore(directory: dir, dimension: 256)
            try await store.upsert(vectors)
            try await store.remove([5, 10, 2999])
            before = await store.search(q, k: 25)
            await store.flush()
        }
        let reopened = try VectorStore(directory: dir, dimension: 256)
        #expect(await reopened.count == 2997)
        let after = await reopened.search(q, k: 25)
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after.map(\.score) == before.map(\.score))
        let v = try #require(await reopened.vector(42))
        #expect(zip(v, vectors[41].vector).allSatisfy { abs($0 - $1) < 1e-3 })

        // A different dimension must not reuse the old rows.
        let other = try VectorStore(directory: dir, dimension: 128)
        #expect(await other.count == 0)
    }

    @Test func deleteCorrectness() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try VectorStore(directory: dir, dimension: 64)
        var rng = SplitMix(state: 99)
        let vectors = (0..<500).map { (id: ChunkID($0), vector: rng.unitVector(64)) }
        try await store.upsert(vectors)
        let removed = Set(stride(from: 0, to: 500, by: 3).map(ChunkID.init))
        try await store.remove(Array(removed) + [9999])  // unknown id ignored
        await store.remove(1)  // protocol path
        #expect(await store.count == 500 - removed.count - 1)
        for (id, vector) in vectors {
            let gone = removed.contains(id) || id == 1
            #expect(await store.contains(id) == !gone)
            if !gone {
                // Each survivor still finds itself first with score ≈ 1 (rows moved correctly).
                let hit = await store.search(vector, k: 1)
                #expect(hit.first?.id == id)
                #expect(abs((hit.first?.score ?? 0) - 1) < 2e-3)
            }
        }
        let all = await store.search(vectors[2].vector, k: 1000)
        #expect(Set(all.map(\.id)).isDisjoint(with: removed.union([1])))

        // Re-insert after delete, and overwrite in place.
        await store.upsert(0, vectors[0].vector)
        await store.upsert(2, vectors[0].vector)
        #expect(await store.search(vectors[0].vector, k: 2).map(\.id).sorted() == [0, 2])
    }

    @Test func loads100kVectorsQuickly() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let store = try VectorStore(directory: dir, dimension: 256)
            var rng = SplitMix(state: 1)
            let base = rng.unitVector(256)
            try await store.upsert((0..<100_000).map { (ChunkID($0), base) })
            await store.flush()
        }
        let clock = ContinuousClock()
        var store: VectorStore?
        let elapsed = try clock.measure { store = try VectorStore(directory: dir, dimension: 256) }
        #expect(await store?.count == 100_000)
        print("VectorStore open 100k×256: \(elapsed)")
        #expect(elapsed < .milliseconds(50))
        let q = SplitMix(state: 2).unitVectorCopy(256)
        let searchTime = await clock.measure { _ = await store?.search(q, k: 50) }
        print("VectorStore search 100k×256: \(searchTime)")
    }
}

private extension SplitMix {
    func unitVectorCopy(_ d: Int) -> [Float] {
        var copy = self
        return copy.unitVector(d)
    }
}

@Suite("Engine: Catalog")
struct EngineCatalogTests {
    @Test func upsertRemovePendingMetaOpens() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            let catalog = try Catalog(url: url)
            let stored = try catalog.upsert([
                Item(id: 0, path: "/a/one.txt", name: "one.txt", kind: .file, modified: t),
                Item(id: 0, path: "/a/two", name: "two", kind: .folder, modified: t),
                Item(id: 0, path: "/Applications/Safari.app", name: "Safari", kind: .app, modified: t),
            ])
            #expect(Set(stored.map(\.id)).count == 3)
            #expect(catalog.count == 3)
            #expect(catalog.item(stored[2].id)?.kind == .app)
            #expect(try catalog.pendingEmbedding(limit: 10).count == 3)
            try catalog.markEmbedded([stored[0].id, stored[1].id])
            #expect(try catalog.pendingEmbedding(limit: 10).map(\.id) == [stored[2].id])

            // Same path keeps its id; unchanged keeps embedded, changed mtime clears it.
            let again = try catalog.upsert([
                Item(id: 0, path: "/a/one.txt", name: "one.txt", kind: .file, modified: t),
                Item(id: 0, path: "/a/two", name: "two", kind: .folder, modified: t.addingTimeInterval(5)),
            ])
            #expect(again.map(\.id) == [stored[0].id, stored[1].id])
            #expect(Set(try catalog.pendingEmbedding(limit: 10).map(\.id)) == [stored[1].id, stored[2].id])

            #expect(try catalog.remove(paths: ["/a/one.txt", "/nope"]) == [stored[0].id])
            #expect(catalog.item(stored[0].id) == nil)
            try catalog.setMeta(IndexCoordinator.MetaKey.lastEventID, "123456789")
            try catalog.recordOpen(path: "/Applications/Safari.app", at: t)
            try catalog.recordOpen(path: "/Applications/Safari.app", at: t.addingTimeInterval(60))
        }
        let reopened = try Catalog(url: url)
        #expect(reopened.count == 2)
        #expect(try reopened.all().count == 2)
        #expect(try reopened.meta(IndexCoordinator.MetaKey.lastEventID) == "123456789")
        let opens = try reopened.openStats()["/Applications/Safari.app"]
        #expect(opens?.count == 2)
        #expect(opens?.last == t.addingTimeInterval(60))
    }

    @Test func bulkUpsert100k() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        let items = (0..<100_000).map {
            Item(id: 0, path: "/home/f\($0).txt", name: "f\($0).txt", kind: .file, modified: .now)
        }
        let clock = ContinuousClock()
        let catalog = try Catalog(url: url)
        let write = try clock.measure { try catalog.upsert(items) }
        var loaded: [Item] = []
        let read = try clock.measure { loaded = try catalog.all() }
        print("Catalog upsert 100k: \(write), all(): \(read)")
        #expect(loaded.count == 100_000)
    }
}

@Suite("Engine: LlamaEmbedder")
struct EngineEmbedderTests {
    static let modelExists = FileManager.default.fileExists(atPath: Paths.modelURL.path)

    @Test func missingModelThrowsTypedError() async {
        let bogus = URL(fileURLWithPath: "/nonexistent/model.gguf")
        await #expect(throws: EmbedderError.modelMissing(bogus.path)) {
            _ = try await LlamaEmbedder.load(modelURL: bogus)
        }
    }

    @Test func nameDocumentFormatD() {
        let d = NameDocument.make(name: "golden_retriever_beach", kindLabel: "image", parent: "Pictures/Holidays")
        #expect(d.title == "none")
        #expect(d.text == "golden retriever beach (image) in Pictures/Holidays")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = NameDocument.make(path: home + "/Documents/Finance/tax_return_2023.pdf", kind: .file)
        #expect(p.text == "tax return 2023 (PDF document) in Documents/Finance")
        #expect(LlamaEmbedder.documentPrompt(title: "", text: "x") == "title: none | text: x")
    }

    @Test(.enabled(if: modelExists)) func modelSmokeDogPhotos() async throws {
        let embedder = try await LlamaEmbedder.load()
        #expect(embedder.dimension == 256)
        let q = try await embedder.embedQueries(["dog photos"])[0]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let docs = try await embedder.embedDocuments([
            NameDocument.make(path: home + "/Pictures/Holidays/golden_retriever_beach.jpg", kind: .file),
            NameDocument.make(path: home + "/Documents/Finance/tax_return_2023.pdf", kind: .file),
        ])
        for v in [q] + docs {
            #expect(v.count == 256)
            #expect(abs(dot(v, v) - 1) < 1e-4)
        }
        let dog = dot(q, docs[0]), tax = dot(q, docs[1])
        print("cos(dog photos, golden_retriever_beach.jpg) = \(dog), cos(dog photos, tax_return_2023.pdf) = \(tax)")
        #expect(dog > tax)

        // Spec cross-check: the measured title form gives 0.7427 / 0.5332 at 256-d.
        let raw = try await embedder.embedRaw([
            "title: golden_retriever_beach.jpg | text: Pictures/Holidays",
            "title: tax_return_2023.pdf | text: Documents/Finance",
        ])
        print("title form: \(dot(q, raw[0])) / \(dot(q, raw[1]))")
        #expect(abs(dot(q, raw[0]) - 0.7427) < 0.02)
        #expect(abs(dot(q, raw[1]) - 0.5332) < 0.02)

        // A batch of 64 docs embeds without error; batching doesn't change vectors.
        let batch = (0..<64).map {
            NameDocument.make(
                name: "report_\($0)_invoice", kindLabel: "PDF document",
                parent: "Documents/Budget/\($0 % 7)")
        }
        let clock = ContinuousClock()
        var vectors: [[Float]] = []
        let t = try await clock.measure { vectors = try await embedder.embedDocuments(batch) }
        print("64-doc batch: \(t)")
        #expect(vectors.count == 64)
        #expect(vectors.allSatisfy { $0.count == 256 && abs(dot($0, $0) - 1) < 1e-4 })
        let single = try await embedder.embedDocuments([batch[17]])[0]
        #expect(dot(single, vectors[17]) > 0.999)

        // 300 docs crosses several 64-sequence batches.
        let many = try await embedder.embedDocuments((0..<300).map { ("none", "file \($0) (image) in Pictures") })
        #expect(many.count == 300)

        let qt = try await clock.measure { _ = try await embedder.embedQueries(["holiday pictures"]) }
        print("warm query: \(qt)")
    }

    @Test(.enabled(if: modelExists)) func indexingContextIsFreedWhenIdle() async throws {
        let embedder = try await LlamaEmbedder.load(indexingIdle: .milliseconds(300))
        func footprint() -> Int {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return rc == KERN_SUCCESS ? Int(info.phys_footprint) >> 20 : 0
        }
        let words = ["invoice", "total", "due", "meeting", "notes", "photo", "beach", "contract", "lease", "tax"]
        let batch = (0..<64).map { i in
            (title: "doc\(i).txt", text: (0..<(40 + i * 9)).map { words[($0 * 7 + i) % 10] }.joined(separator: " "))
        }
        let first = try await embedder.embedDocuments(batch)
        #expect(await embedder.holdsIndexingContext)
        let busy = footprint()
        // A query in the gap does not keep the indexing context alive.
        _ = try await embedder.embedQueries(["beach photo"])
        try await Task.sleep(for: .seconds(1))
        #expect(await !embedder.holdsIndexingContext)
        let idle = footprint()
        print("indexing context: busy=\(busy) MB idle=\(idle) MB")
        let clock = ContinuousClock()
        var again: [[Float]] = []
        let t = try await clock.measure { again = try await embedder.embedDocuments(batch) }
        print("first batch after release: \(t)")
        #expect(zip(first, again).allSatisfy { dot($0, $1) > 0.9999 })
    }
}
