import CoreServices
import Foundation
import Synchronization
import Testing

@testable import HunchCore

/// Fake embedder: 4-d vectors derived from the text; records every document it saw.
final class IndexFakeEmbedder: Embedder {
    let dimension = 4
    let docs = Mutex<[(title: String, text: String)]>([])
    let calls = Mutex(0)

    func embedQueries(_ q: [String]) async throws -> [[Float]] { q.map(Self.vector) }

    func embedDocuments(_ d: [(title: String, text: String)]) async throws -> [[Float]] {
        calls.withLock { $0 += 1 }
        docs.withLock { $0 += d }
        return d.map { Self.vector($0.text) }
    }

    static func vector(_ s: String) -> [Float] {
        let h = Float(abs(s.hashValue % 1000)) / 1000
        return [1, h, 0, 0]
    }
}

actor IndexFakeVectors: VectorIndex {
    var store: [ChunkID: [Float]] = [:]
    func upsert(_ id: ChunkID, _ v: [Float]) { store[id] = v }
    func remove(_ id: ChunkID) { store[id] = nil }
    func removeItem(_ item: UInt32) { store = store.filter { Chunk.item($0.key) != item } }
    func search(_ q: [Float], k: Int) -> [(id: ChunkID, score: Float)] { [] }
    func storedVector(_ id: ChunkID) async -> [Float]? { store[id] }
    var count: Int { store.count }
    /// Any vector of `item`.
    func has(_ item: UInt32) -> Bool { store.keys.contains { Chunk.item($0) == item } }
}

@Suite(.serialized) struct IndexCoordinatorTests {
    /// Polls until `cond` holds. Deadlines are generous on purpose: FSEvents delivery under a loaded machine (a
    /// parallel build) took over 2 s and failed this suite once; the ≤ 1 s name-visible target lives in hunch-bench.
    static func waitUntil(_ timeout: Duration = .seconds(3), _ cond: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await cond() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await cond()
    }

    static func id(_ catalog: MemoryCatalog, _ path: String) async -> UInt32? { await catalog.item(path: path)?.id }

    @Test func crawlsEmbedsAndAppliesLiveChanges() async throws {
        let t = IndexTempDir()
        t.write("Docs/budget_2024.txt", "rent and groceries")
        t.write("Docs/old.txt")
        t.write("Pictures/dog.jpg")
        t.write("node_modules/x.js")
        let catalog = MemoryCatalog()
        let embedder = IndexFakeEmbedder()
        let vectors = IndexFakeVectors()
        let c = IndexCoordinator(
            roots: [t.url], catalog: catalog, embedder: embedder, vectors: vectors,
            extractor: ContentExtractor(home: t.path), batchSize: 2, watchLatency: 0.1)
        await c.start()

        #expect(await c.lastCrawl?.count == 5)  // Docs, 2 files, Pictures, dog.jpg
        #expect(c.nameIndex.count == 5)
        #expect(!c.nameIndex.search("budget", limit: 5).isEmpty)
        #expect(await Self.waitUntil { await vectors.count == 5 })
        #expect(await catalog.pendingCount == 0)
        #expect(embedder.calls.withLock { $0 } >= 3)  // batches of 2
        let texts = embedder.docs.withLock { $0.map(\.text) }
        #expect(texts.contains("budget 2024 (text document) in Docs. rent and groceries"))
        #expect(texts.contains("dog (image) in Pictures"))

        // Create.
        let t0 = ContinuousClock.now
        t.write("Docs/new_note.md", "hello")
        #expect(await Self.waitUntil(.seconds(10)) { !c.nameIndex.search("new_note", limit: 5).isEmpty })
        print("Coordinator: new file findable by name after \(ContinuousClock.now - t0)")
        let newID = try #require(await Self.id(catalog, t.path + "/Docs/new_note.md"))
        #expect(await Self.waitUntil { await vectors.has(newID) })

        // Rename.
        #expect(await Self.waitUntil { await catalog.pendingCount == 0 })
        let vectorsBeforeRename = await vectors.count
        try FileManager.default.moveItem(atPath: t.path + "/Docs/new_note.md", toPath: t.path + "/Docs/renamed_note.md")
        #expect(
            await Self.waitUntil(.seconds(10)) {
                !c.nameIndex.search("renamed_note", limit: 5).isEmpty
                    && c.nameIndex.search("new_note", limit: 5).isEmpty
            })
        // Contract changed in v3 I4 (v2 asserted `!vectors.has(newID)`, i.e. drop-and-re-add): a rename keeps the
        // item's identity, so its id and content vectors survive. Equally strict for the new contract: the old path
        // is gone, the id is unchanged, no duplicate vector appears, and the name vector (chunk 0) is exactly the
        // embedding of the NEW name document, so no stale vector of the old name stays.
        #expect(await Self.id(catalog, t.path + "/Docs/new_note.md") == nil)
        #expect(await Self.id(catalog, t.path + "/Docs/renamed_note.md") == newID)
        let renamedDoc = await Self.waitUntil {
            embedder.docs.withLock { $0.contains { $0.text.hasPrefix("renamed note") } }
        }
        #expect(renamedDoc)
        let renamedText = try #require(embedder.docs.withLock { $0.last { $0.text.hasPrefix("renamed note") }?.text })
        #expect(
            await Self.waitUntil {
                let v = await vectors.storedVector(Chunk.id(item: newID))
                let pending = await catalog.pendingCount
                return v == IndexFakeEmbedder.vector(renamedText) && pending == 0
            })
        #expect(await vectors.count == vectorsBeforeRename)

        // Delete.
        let oldID = try #require(await Self.id(catalog, t.path + "/Docs/old.txt"))
        try FileManager.default.removeItem(atPath: t.path + "/Docs/old.txt")
        #expect(await Self.waitUntil(.seconds(10)) { c.nameIndex.search("old.txt", limit: 5).isEmpty })
        #expect(await !vectors.has(oldID))

        // Directory moved in from outside the roots: its contents get indexed.
        let outside = IndexTempDir()
        outside.write("Trip/beach.jpg")
        try FileManager.default.moveItem(atPath: outside.path + "/Trip", toPath: t.path + "/Trip")
        #expect(await Self.waitUntil(.seconds(10)) { !c.nameIndex.search("beach", limit: 5).isEmpty })

        // Changes inside skipped folders are ignored.
        t.write("node_modules/y.js")
        try await Task.sleep(for: .milliseconds(400))
        #expect(c.nameIndex.search("y.js", limit: 5).isEmpty)
        #expect(await catalog.meta(IndexCoordinator.MetaKey.lastEventID) != nil)
        await c.stop()
    }

    @Test func pauseStopsEmbeddingUntilResume() async throws {
        let t = IndexTempDir()
        t.write("a.txt")
        let catalog = MemoryCatalog()
        let vectors = IndexFakeVectors()
        let c = IndexCoordinator(
            roots: [t.url], catalog: catalog, embedder: IndexFakeEmbedder(), vectors: vectors,
            extractor: ContentExtractor(home: t.path), watchLatency: 0.1)
        await c.start()
        #expect(await Self.waitUntil { await vectors.count == 1 })
        await c.pause()
        t.write("b.txt")
        #expect(await Self.waitUntil(.seconds(10)) { !c.nameIndex.search("b.txt", limit: 5).isEmpty })
        try await Task.sleep(for: .milliseconds(300))
        #expect(await vectors.count == 1)  // name index updated, embedding held
        await c.resume()
        #expect(await Self.waitUntil { await vectors.count == 2 })
        await c.stop()
    }

    @Test func relaunchResumesWithoutRecrawl() async throws {
        let t = IndexTempDir()
        t.write("first.txt")
        let catalog = MemoryCatalog()
        let vectors = IndexFakeVectors()
        let c1 = IndexCoordinator(roots: [t.url], catalog: catalog, watchLatency: 0.1)
        await c1.start()
        #expect(await c1.lastCrawl != nil)
        let firstID = await Self.id(catalog, t.path + "/first.txt")
        await c1.stop()

        // While "not running": create one file, delete another.
        t.write("while_away.txt")
        try FileManager.default.removeItem(atPath: t.path + "/first.txt")
        try await Task.sleep(for: .milliseconds(300))

        let c2 = IndexCoordinator(
            roots: [t.url], catalog: catalog, embedder: IndexFakeEmbedder(), vectors: vectors,
            extractor: ContentExtractor(home: t.path), watchLatency: 0.1)
        await c2.start()
        #expect(await c2.lastCrawl == nil)  // no re-crawl
        #expect(await Self.waitUntil { !c2.nameIndex.search("while_away", limit: 5).isEmpty })
        #expect(await Self.waitUntil { c2.nameIndex.search("first", limit: 5).isEmpty })
        // Pending embeddings left from the first run are completed.
        #expect(await Self.waitUntil { await catalog.pendingCount == 0 })
        if let firstID { #expect(await !vectors.has(firstID)) }
        await c2.stop()
    }

    @Test func mustScanSubDirsRescansSubtree() async throws {
        let t = IndexTempDir()
        t.write("A/one.txt")
        let catalog = MemoryCatalog()
        let c = IndexCoordinator(roots: [t.url], catalog: catalog)
        await c.fullCrawl()
        t.write("A/B/two.txt")
        try FileManager.default.removeItem(atPath: t.path + "/A/one.txt")
        let flags = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
        await c.apply(ChangeBatch(events: [FileEvent(path: t.path + "/A", flags: flags, id: 42)], lastEventID: 42))
        #expect(!c.nameIndex.search("two.txt", limit: 5).isEmpty)
        #expect(c.nameIndex.search("one.txt", limit: 5).isEmpty)
        #expect(await catalog.item(path: t.path + "/A/B") != nil)
        #expect(await catalog.meta(IndexCoordinator.MetaKey.lastEventID) == "42")

        // Root-level rescan with the root gone from the event's perspective still reconciles.
        t.write("top.txt")
        await c.apply(ChangeBatch(events: [FileEvent(path: t.path, flags: flags, id: 43)], lastEventID: 43))
        #expect(!c.nameIndex.search("top.txt", limit: 5).isEmpty)
        #expect(await catalog.count == 4)  // A, A/B, A/B/two.txt, top.txt
    }

    @Test func embedFailureDoesNotWedgeQueue() async throws {
        final class Flaky: Embedder {
            let dimension = 2
            func embedQueries(_ q: [String]) async throws -> [[Float]] { [] }
            func embedDocuments(_ d: [(title: String, text: String)]) async throws -> [[Float]] {
                if d.contains(where: { $0.text.contains("poison") }) { throw CancellationError() }
                return d.map { _ in [1, 0] }
            }
        }
        let t = IndexTempDir()
        t.write("poison.txt")
        t.write("fine.txt")
        let catalog = MemoryCatalog()
        let vectors = IndexFakeVectors()
        let c = IndexCoordinator(
            roots: [t.url], catalog: catalog, embedder: Flaky(), vectors: vectors,
            extractor: ContentExtractor(home: t.path))
        await c.start()
        #expect(await Self.waitUntil { await catalog.pendingCount == 0 })
        #expect(await vectors.count == 1)
        await c.stop()
    }
}
