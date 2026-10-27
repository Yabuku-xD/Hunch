import Foundation
import Synchronization
import Testing

@testable import HunchCore

private struct FixedNames: NameIndexing {
    let hits: [(id: UInt32, score: Float)]
    func search(_ q: String, limit: Int) -> [(id: UInt32, score: Float)] { Array(hits.prefix(limit)) }
}

private final class CountingEmbedder: Embedder {
    let dimension = 2
    let calls = Mutex(0)
    func embedQueries(_ q: [String]) async throws -> [[Float]] {
        calls.withLock { $0 += 1 }
        return q.map { _ in [1, 0] }
    }
    func embedDocuments(_ d: [(title: String, text: String)]) async throws -> [[Float]] { d.map { _ in [1, 0] } }
}

/// Hits are given as (item id, score) on name chunks; `chunks` adds content chunks.
private struct FixedVectors: VectorIndex {
    let hits: [(id: ChunkID, score: Float)]
    var infos: [ChunkID: ChunkInfo] = [:]
    init(hits: [(id: UInt32, score: Float)]) { self.hits = hits.map { (Chunk.id(item: $0.id), $0.score) } }
    init(chunks: [(info: ChunkInfo, score: Float)]) {
        hits = chunks.map { ($0.info.id, $0.score) }
        infos = Dictionary(uniqueKeysWithValues: chunks.map { ($0.info.id, $0.info) })
    }
    func upsert(_ id: ChunkID, _ v: [Float]) async {}
    func remove(_ id: ChunkID) async {}
    func search(_ q: [Float], k: Int) async -> [(id: ChunkID, score: Float)] { Array(hits.prefix(k)) }
    func chunkInfo(_ ids: [ChunkID]) async -> [ChunkID: ChunkInfo] { infos.filter { ids.contains($0.key) } }
}

private func item(_ id: UInt32) -> Item {
    Item(id: id, path: "/tmp/\(id).txt", name: "\(id).txt", kind: .file, modified: .now)
}

private func fastConfig() -> HybridSearchEngine.Config {
    var c = HybridSearchEngine.Config()
    c.debounce = .milliseconds(1)
    return c
}

@Suite struct SearchEngineTests {
    @Test func namesFirstThenFusedWithGate() async {
        let embedder = CountingEmbedder()
        let engine = HybridSearchEngine(
            names: FixedNames(hits: [(1, 0.9), (2, 0.5)]),
            lookup: { item($0) },
            embedder: embedder,
            // 2 is also a name hit; 3 passes the gate; 4 is under 0.70; 5 is > 0.03 below the best.
            vectors: FixedVectors(hits: [(3, 0.80), (2, 0.79), (4, 0.65), (5, 0.76)]),
            config: fastConfig())
        var emissions: [[SearchResult]] = []
        for await batch in engine.results(for: "dog") { emissions.append(batch) }
        #expect(emissions.count == 2)
        #expect(emissions[0].map(\.id) == [1, 2])
        #expect(emissions[0].allSatisfy { $0.source == .name })
        let fused = emissions[1]
        #expect(Set(fused.map(\.id)) == [1, 2, 3])
        #expect(fused.first { $0.id == 2 }?.source == .both)
        #expect(fused.first { $0.id == 3 }?.source == .semantic)
        // 2: 1/62 + 0.8/62 beats 1: 1/61.
        #expect(fused.map(\.id) == [2, 1, 3])

        // Second run of the same query hits the embedding cache.
        for await _ in engine.results(for: "dog") {}
        #expect(embedder.calls.withLock { $0 } == 1)
        #expect(engine.cachedQueryCount == 1)
    }

    @Test func newQueryCancelsPreviousSemanticLeg() async {
        var c = HybridSearchEngine.Config()
        c.debounce = .milliseconds(200)
        let engine = HybridSearchEngine(
            names: FixedNames(hits: [(1, 1)]), lookup: { item($0) },
            embedder: CountingEmbedder(),
            vectors: FixedVectors(hits: [(9, 0.9)]), config: c)
        let first = engine.results(for: "do")
        _ = engine.results(for: "dog")
        var count = 0
        for await _ in first { count += 1 }
        #expect(count == 1)  // name hits only; the semantic leg was cancelled
    }

    @Test func nameOnlyWithoutEmbedder() async {
        let engine = HybridSearchEngine(names: FixedNames(hits: [(7, 1)]), lookup: { item($0) })
        var emissions = 0
        for await batch in engine.results(for: "x") {
            emissions += 1
            #expect(batch.map(\.id) == [7])
        }
        #expect(emissions == 1)
    }

    @Test func persistentCatalogResumes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bs-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            CrawlEntry(path: "/r/a", name: "a", kind: .folder, modified: date),
            CrawlEntry(path: "/r/a/x.txt", name: "x.txt", kind: .file, modified: date),
            CrawlEntry(path: "/r/b.txt", name: "b.txt", kind: .file, modified: date),
        ]
        var ids: [String: UInt32] = [:]
        do {
            let cat = PersistentCatalog(try Catalog(url: url))
            let stored = await cat.upsert(entries)
            for s in stored { ids[s.path] = s.id }
            await cat.markEmbedded([ids["/r/b.txt"]!])
            await cat.setMeta(IndexCoordinator.MetaKey.lastEventID, "42")
        }
        let cat = PersistentCatalog(try Catalog(url: url))
        #expect(await cat.meta(IndexCoordinator.MetaKey.lastEventID) == "42")
        #expect(Set(await cat.pendingEmbedding(limit: 10).map(\.path)) == ["/r/a", "/r/a/x.txt"])
        let again = await cat.upsert([entries[2]])
        #expect(again.first?.id == ids["/r/b.txt"])  // stable id
        #expect(await cat.pendingEmbedding(limit: 10).count == 2)  // unchanged item stays embedded

        let removed = await cat.remove(paths: ["/r/a"])  // folder takes its subtree
        #expect(Set(removed) == [ids["/r/a"]!, ids["/r/a/x.txt"]!])
        let (_, gone) = await cat.replace(under: ["/r"], with: [])
        #expect(gone == [ids["/r/b.txt"]!])
        #expect(await cat.allItems().isEmpty)
    }
}
