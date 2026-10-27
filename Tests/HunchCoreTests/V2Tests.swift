import Foundation
import Synchronization
import Testing

@testable import HunchCore

private func scratch(_ tag: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("V2Tests-\(tag)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func touch(_ dir: URL, _ name: String) -> String {
    let p = dir.appendingPathComponent(name).path
    FileManager.default.createFile(atPath: p, contents: Data("x".utf8))
    return p
}

private func waitUntil(_ timeout: Duration = .seconds(3), _ cond: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await cond()
}

// MARK: Favorites, recents, frecency

@Suite struct FavoritesRecentsTests {
    @Test func pinsKeepUserOrderAndDropDeletedFiles() throws {
        let dir = scratch("pins")
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = try Catalog(url: dir.appendingPathComponent("index.sqlite"))
        let paths = ["a.txt", "b.txt", "c.txt"].map { touch(dir, $0) }
        try catalog.upsert(
            paths.map {
                Item(
                    id: 0, path: $0, name: ($0 as NSString).lastPathComponent,
                    kind: .file, modified: .now)
            })
        for p in paths { try catalog.pin(path: p) }
        try catalog.pin(path: paths[0])  // already pinned: no-op
        #expect(try catalog.favorites().map(\.path) == paths)

        try catalog.reorderPins([paths[2], paths[0]])
        #expect(try catalog.favorites().map(\.path) == [paths[2], paths[0], paths[1]])

        try catalog.unpin(path: paths[0])
        #expect(try catalog.favorites().map(\.path) == [paths[2], paths[1]])

        try FileManager.default.removeItem(atPath: paths[2])
        #expect(try catalog.favorites().map(\.path) == [paths[1]])
        #expect(try catalog.pinnedPaths() == [paths[1]])  // the dead pin was deleted
    }

    @Test func recentsNewestFirstLimitedAndPruned() throws {
        let dir = scratch("recents")
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = try Catalog(url: dir.appendingPathComponent("index.sqlite"))
        let paths = (0..<4).map { touch(dir, "f\($0).txt") }
        try catalog.upsert(paths.map { Item(id: 0, path: $0, name: "x", kind: .file, modified: .now) })
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        for (i, p) in paths.enumerated() { try catalog.recordOpen(path: p, at: t.addingTimeInterval(Double(i))) }
        try catalog.recordOpen(path: paths[0], at: t.addingTimeInterval(10))
        #expect(try catalog.recents(limit: 3).map(\.path) == [paths[0], paths[3], paths[2]])

        try FileManager.default.removeItem(atPath: paths[3])
        #expect(try catalog.recents(limit: 10).map(\.path) == [paths[0], paths[2], paths[1]])
        #expect(try catalog.openStats()[paths[3]] == nil)
        #expect(try catalog.openStats()[paths[0]]?.count == 2)
    }

    @Test func frecencyHalvesEveryWeekAndPersists() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let week = Frecency.halfLife
        let f = Frecency().adding(at: t).adding(at: t)
        #expect(abs(f.value(at: t) - 2) < 1e-9)
        #expect(abs(f.value(at: t.addingTimeInterval(week)) - 1) < 1e-9)
        #expect(abs(f.adding(at: t.addingTimeInterval(week)).score - 2) < 1e-9)

        let dir = scratch("frecency")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        do {
            let catalog = try Catalog(url: url)
            try catalog.recordOpen(path: "/x", at: t)
            try catalog.recordOpen(path: "/x", at: t.addingTimeInterval(week))
        }
        let stats = try Catalog(url: url).frecencyStats()["/x"]
        #expect(stats?.count == 2)
        #expect(abs((stats?.frecency.score ?? 0) - 1.5) < 1e-9)
        #expect(stats?.frecency.at == t.addingTimeInterval(week))
    }

    @Test func v1OpensTableMigrates() throws {
        let dir = scratch("migrate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        do {
            let db = try SQLiteDB(url: url)
            try db.exec(
                """
                CREATE TABLE opens(path TEXT PRIMARY KEY, count INTEGER NOT NULL, last REAL NOT NULL);
                INSERT INTO opens VALUES('/old', 3, 1700000000);
                """)
        }
        let catalog = try Catalog(url: url)
        let s = try catalog.frecencyStats()["/old"]
        #expect(s?.count == 3)
        #expect(s?.frecency.score == 3)
        try catalog.recordOpen(path: "/old", at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try catalog.frecencyStats()["/old"]?.frecency.score == 4)
    }

    @Test func recordedOpensBoostNameMatches() {
        let items = (1...3).map {
            Item(
                id: UInt32($0), path: "/d/report \($0).pdf", name: "report \($0).pdf",
                kind: .file, modified: Date(timeIntervalSinceNow: -400 * 86_400))
        }
        let idx = NameIndex(items: items)
        #expect(idx.search("report", limit: 3).first?.id == 1)
        idx.recordOpen(3)
        #expect(idx.search("report", limit: 3).first?.id == 3)
        #expect(abs(idx.frecency(3) - 1) < 1e-3)
        #expect(abs(idx.frecency(3, at: Date(timeIntervalSinceNow: Frecency.halfLife)) - 0.5) < 1e-3)
    }

    @Test func backendSuggestionsFavoritesThenRecents() async throws {
        let dir = scratch("suggest")
        let tree = scratch("suggest-tree")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: tree)
        }
        let a = touch(tree, "alpha.txt"), b = touch(tree, "beta.txt"), c = touch(tree, "gamma.txt")
        let backend = SearchBackend(directory: dir, roots: [tree], modelURL: nil)
        backend.start()
        await backend.wait(for: .caughtUp)
        let real = { (p: String) in Crawler.realPath(p) }
        backend.pin(real(c))
        for p in [a, b, c] { try backend.catalog!.recordOpen(path: real(p)) }
        let sections = backend.engine.suggestions()
        #expect(sections.map(\.kind) == [.favorites, .recents])
        #expect(sections[0].results.map(\.item.path) == [real(c)])
        #expect(sections[1].results.map(\.item.path) == [real(b), real(a)])  // pinned c not repeated
        await backend.coordinator?.stop()
    }
}

// MARK: Model resolution, name-only mode

@Suite struct ModelMissingTests {
    @Test func resolutionOrder() throws {
        let home = scratch("home")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(Paths.resolveModel(environment: [:], home: home) == nil)

        // Sparse files with the pinned names and exact byte counts (APFS stores no data for them).
        func sparse(_ dir: URL, _ file: ModelFile) throws -> String {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let p = dir.appendingPathComponent(file.fileName).path
            FileManager.default.createFile(atPath: p, contents: nil)
            let h = try #require(FileHandle(forWritingAtPath: p))
            try h.truncate(atOffset: UInt64(file.byteCount))
            try h.close()
            return p
        }
        let models = home.appendingPathComponent("Library/Application Support/Hunch/Models")
        _ = touch(
            try {
                try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true); return models
            }(),
            "stray-model.gguf")  // other ggufs are never picked up
        #expect(Paths.resolveModel(environment: [:], home: home) == nil)
        let mmproj = try sparse(models, .projector)
        let own = try sparse(models, .text)
        // A HUNCH_MODEL that doesn't exist falls through to our own Models folder; the projector pairs by name.
        #expect(Paths.resolveModel(environment: ["HUNCH_MODEL": "/nope.gguf"], home: home)?.path == own)
        let explicit = touch(home, "x.gguf")
        #expect(Paths.resolveModel(environment: ["HUNCH_MODEL": explicit], home: home)?.path == explicit)
        #expect(ModelStore(home: home, environment: [:]).resolve()?.projector?.path == mmproj)

        try FileManager.default.removeItem(atPath: own)
        let digUp = Paths.digUpModel(home: home)
        #expect(try sparse(digUp.deletingLastPathComponent(), .text) == digUp.path)
        #expect(Paths.resolveModel(environment: [:], home: home) == digUp)
    }

    @Test func noModelMeansNameOnlyAndModelMissingStatus() async throws {
        let dir = scratch("nomodel")
        let tree = scratch("nomodel-tree")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: tree)
        }
        _ = touch(tree, "quarterly budget.xlsx")
        let backend = SearchBackend(directory: dir, roots: [tree], modelURL: nil)
        #expect(backend.indexStatus.phase == .modelMissing)
        #expect(backend.embedder == nil)
        backend.start()
        await backend.wait(for: .caughtUp)
        #expect(!backend.engine.isSemanticReady)
        var emissions: [[SearchResult]] = []
        for await batch in backend.engine.results(for: "budget") { emissions.append(batch) }
        #expect(emissions.count == 1)
        #expect(emissions[0].first?.item.name == "quarterly budget.xlsx")
        let status = backend.indexStatus
        #expect(status.phase == .modelMissing)
        #expect(status.items >= 1)
        await backend.coordinator?.stop()
    }

    @Test func unloadableModelStopsEmbeddingAndReportsMissing() async throws {
        let dir = scratch("badmodel")
        let tree = scratch("badmodel-tree")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: tree)
        }
        _ = touch(tree, "a.txt")
        let backend = SearchBackend(directory: dir, roots: [tree], modelURL: URL(fileURLWithPath: "/nonexistent.gguf"))
        let updates = backend.indexStatusUpdates()
        backend.start()
        await backend.wait(for: .caughtUp)
        var sawMissing = false
        for await s in updates where s.phase == .modelMissing {
            sawMissing = true
            break
        }
        #expect(sawMissing)
        #expect(await backend.embedder?.loadError == .modelMissing("/nonexistent.gguf"))
        // Name search still answers instantly.
        var first: [SearchResult] = []
        for await batch in backend.engine.results(for: "a.txt") { first = batch; break }
        #expect(first.first?.item.name == "a.txt")
        await backend.coordinator?.stop()
    }
}

// MARK: Lazy load, idle unload, reload

private final class FakeModel: Embedder {
    let dimension = 2
    func embedQueries(_ q: [String]) async throws -> [[Float]] { q.map { _ in [1, 0] } }
    func embedDocuments(_ d: [(title: String, text: String)]) async throws -> [[Float]] { d.map { _ in [0, 1] } }
}

private final class Counter: Sendable { let n = Mutex(0) }

@Suite struct ModelLifecycleTests {
    private static func managed(
        timeout: Duration, keepAlive: @escaping @Sendable () async -> Bool = { false },
        loads: Counter
    ) -> ManagedEmbedder {
        ManagedEmbedder(
            modelURL: URL(fileURLWithPath: "/fake.gguf"), dimension: 2, idleTimeout: timeout,
            keepAlive: keepAlive,
            loader: { _, _ in
                try await Task.sleep(for: .milliseconds(20))
                loads.n.withLock { $0 += 1 }
                return FakeModel()
            })
    }

    @Test func lazyLoadSharedUnloadAfterIdleThenReload() async throws {
        let loads = Counter()
        // Long enough that a slow CI runner cannot reach the idle unload before the isLoaded check below.
        let e = Self.managed(timeout: .milliseconds(800), loads: loads)
        #expect(await !e.isLoaded)  // nothing at init
        async let a = e.embedQueries(["x"])
        async let b = e.embedDocuments([("none", "y")])
        let (va, vb) = try await (a, b)
        #expect(va == [[1, 0]] && vb == [[0, 1]])
        #expect(loads.n.withLock { $0 } == 1)  // concurrent callers share one load
        #expect(await e.isLoaded)
        #expect(await waitUntil(.seconds(2)) { await !e.isLoaded })
        _ = try await e.embedQueries(["again"])  // transparent reload
        #expect(loads.n.withLock { $0 } == 2)
        #expect(await e.loadCount == 2)
    }

    @Test func useAndPendingWorkKeepTheModel() async throws {
        let loads = Counter()
        let pending = Mutex(true)
        let e = Self.managed(timeout: .milliseconds(100), keepAlive: { pending.withLock { $0 } }, loads: loads)
        try await e.preload()
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(60))
            _ = try await e.embedQueries(["keep"])
        }
        #expect(await e.isLoaded)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await e.isLoaded)  // idle but embeddings pending
        pending.withLock { $0 = false }
        #expect(await waitUntil(.seconds(2)) { await !e.isLoaded })
        #expect(loads.n.withLock { $0 } == 1)
    }

    @Test func missingModelFailsFastAndSticks() async {
        let e = ManagedEmbedder(modelURL: URL(fileURLWithPath: "/nonexistent/m.gguf"), dimension: 256)
        await #expect(throws: EmbedderError.modelMissing("/nonexistent/m.gguf")) {
            _ = try await e.embedQueries(["x"])
        }
        #expect(await e.loadError == .modelMissing("/nonexistent/m.gguf"))
        #expect(await !e.isLoaded)
    }

    @Test func nameResultsDoNotWaitOnModelLoad() async {
        let slow = ManagedEmbedder(
            modelURL: URL(fileURLWithPath: "/fake.gguf"), dimension: 2,
            loader: { _, _ in
                try await Task.sleep(for: .seconds(1))
                return FakeModel()
            })
        let item = Item(id: 1, path: "/a/notes.txt", name: "notes.txt", kind: .file, modified: .now)
        var config = HybridSearchEngine.Config()
        config.debounce = .zero
        let engine = HybridSearchEngine(
            names: NameIndex(items: [item]), lookup: { $0 == 1 ? item : nil },
            embedder: slow, vectors: EmptyVectors(), config: config)
        let t0 = ContinuousClock.now
        var first: [SearchResult]?
        for await batch in engine.results(for: "notes") { first = batch; break }
        #expect(first?.map(\.id) == [1])
        #expect(ContinuousClock.now - t0 < .milliseconds(100))
    }
}

private struct EmptyVectors: VectorIndex {
    func upsert(_ id: ChunkID, _ v: [Float]) async {}
    func remove(_ id: ChunkID) async {}
    func search(_ q: [Float], k: Int) async -> [(id: ChunkID, score: Float)] { [] }
}

// MARK: Settings

@Suite struct SettingsTests {
    @Test func settingsPersistAndRebuildDropsOldRoots() async throws {
        let dir = scratch("settings")
        let a = scratch("rootA"), b = scratch("rootB")
        defer { for u in [dir, a, b] { try? FileManager.default.removeItem(at: u) } }
        _ = touch(a, "from_a.txt")
        _ = touch(b, "from_b.txt")
        do {
            let backend = SearchBackend(directory: dir, roots: [a], modelURL: nil)
            backend.start()
            await backend.wait(for: .caughtUp)
            #expect(!backend.nameIndex.search("from_a", limit: 5).isEmpty)
            await backend.update(settings: IndexSettings(roots: [b]))
            #expect(backend.settings.roots == [b])
            #expect(backend.nameIndex.search("from_a", limit: 5).isEmpty)
            #expect(!backend.nameIndex.search("from_b", limit: 5).isEmpty)
            await backend.coordinator?.stop()
        }
        let relaunched = SearchBackend(directory: dir, modelURL: nil)
        relaunched.start()
        await relaunched.wait(for: .namesLoaded)
        #expect(relaunched.settings.roots.map(\.path) == [b.path])
        #expect(!relaunched.nameIndex.search("from_b", limit: 5).isEmpty)
        await relaunched.wait(for: .caughtUp)
        await relaunched.coordinator?.stop()
    }

    @Test func settingsCodecAndDefault() {
        let s = IndexSettings(roots: [URL(fileURLWithPath: "/tmp/x", isDirectory: true)])
        #expect(IndexSettings.decode(s.encoded()) == s)
        #expect(IndexSettings.decode("garbage") == nil)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let roots = IndexSettings.default.roots.map { $0.standardizedFileURL.path }
        // F1: apps only by default; the home folder is opt-in.
        #expect(!roots.contains(home) && roots.contains("/Applications"))
        #expect(roots == Crawler.appRoots.map { $0.standardizedFileURL.path })
        #expect(roots.allSatisfy { $0 == home + "/Applications" || !$0.hasPrefix(home) })
    }

    /// O3: crawling the default roots of a home that has Desktop/Documents/Downloads never lists them.
    @Test func defaultRootsNeverEnterProtectedFolders() async throws {
        let home = scratch("tcc-home")
        defer { try? FileManager.default.removeItem(at: home) }
        for dir in ["Desktop", "Documents", "Downloads", "Applications/Tool.app"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for dir in ["Desktop", "Documents", "Downloads"] { _ = touch(home.appendingPathComponent(dir), "secret.txt") }
        // Only the temp ~/Applications.
        let roots = Crawler.appRoots(home: home).filter { $0.path.hasPrefix(home.path) }
        let crawler = Crawler(roots: roots, home: home.path)
        let (entries, _) = await crawler.crawlEntries()
        let paths = entries.map(\.path)
        #expect(paths.contains { $0.hasSuffix("/Applications/Tool.app") })
        for dir in ["Desktop", "Documents", "Downloads"] {
            #expect(!paths.contains { $0.contains("/\(dir)/") || $0.hasSuffix("/\(dir)") })
        }
    }
}

// MARK: Chunked vectors + content fusion

@Suite struct ContentFusionTests {
    @Test func chunkTableRoundtripAndRemoveItem() async throws {
        let dir = scratch("chunks")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try VectorStore(directory: dir, dimension: 2)
        #expect(store.didReset)
        let page3 = ContentLocation(page: 3, region: ContentRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        let info = ChunkInfo(
            id: Chunk.id(item: 7, index: 2), kind: .image, location: page3, textOffset: 120,
            snippet: "a dog on a beach")
        await store.upsert(Chunk.id(item: 7), [1, 0])
        await store.upsertChunks([
            (info, [0, 1]), (ChunkInfo(id: Chunk.id(item: 7, index: 1), kind: .semantic), [0.6, 0.8]),
        ])
        await store.upsert(Chunk.id(item: 8), [1, 0])
        #expect(await store.count == 4)
        #expect(await store.chunkInfo([info.id, Chunk.id(item: 7)]) == [info.id: info])
        #expect(Chunk.item(info.id) == 7 && Chunk.index(info.id) == 2)

        await store.removeItem(7)
        #expect(await store.count == 1)
        #expect(await store.chunkInfo([info.id]).isEmpty)
        #expect(await store.containsItem(8))
        await store.flush()
        let reopened = try VectorStore(directory: dir, dimension: 2)
        #expect(!reopened.didReset)
        #expect(await reopened.search([1, 0], k: 5).map(\.id) == [Chunk.id(item: 8)])
    }

    private struct Texts: FullTextIndexing {
        let hits: [FullTextHit]
        func search(_ q: String, limit: Int) -> [FullTextHit] { hits }
    }

    private static func item(_ id: UInt32) -> Item {
        Item(id: id, path: "/d/\(id).pdf", name: "\(id).pdf", kind: .file, modified: .now)
    }

    @Test func exactPhraseBeatsSemanticOnlyOneRowPerFile() {
        var c = HybridSearchEngine.Config()
        c.semanticWeight = 5  // make semantic strong enough that only the phrase rule keeps the order
        let engine = HybridSearchEngine(names: NameIndex(), lookup: { Self.item($0) }, config: c)
        let loc = ContentLocation(page: 4, line: 12)
        let text = [
            FullTextHit(
                item: 1, kind: .text, location: ContentLocation(page: 1), snippet: "lease", bm25: 9,
                isExactPhrase: false),
            FullTextHit(
                item: 1, kind: .text, location: loc, snippet: "the lease agreement", highlights: [4..<19],
                bm25: 5, isExactPhrase: true),
            FullTextHit(
                item: 1, kind: .ocr, location: ContentLocation(page: 6), snippet: "lease agreement",
                bm25: 4, isExactPhrase: true),
        ]
        let chunk = ChunkInfo(
            id: Chunk.id(item: 2, index: 3), kind: .semantic, location: ContentLocation(page: 2),
            snippet: "rental contract terms")
        let fused = engine.fuse(
            names: [], fullText: text, semantic: [(chunk.id, 0.9), (Chunk.id(item: 2), 0.89)],
            chunks: [chunk.id: chunk])
        #expect(fused.map(\.id) == [1, 2])  // one row per file, phrase hit first
        #expect(fused[0].source == .content)
        #expect(
            fused[0].match
                == ContentMatch(
                    kind: .text, snippet: "the lease agreement", highlights: [4..<19],
                    location: loc))
        #expect(fused[0].moreMatches == 2)
        #expect(fused[0].key == ResultKey(item: 1, location: loc))
        #expect(fused[1].source == .semantic)
        #expect(fused[1].match?.snippet == "rental contract terms")
        #expect(fused[1].moreMatches == 0)
    }

    @Test func streamOrderNamesThenFullTextThenSemantic() async {
        let names = NameIndex(items: [Self.item(1)])
        var c = HybridSearchEngine.Config()
        c.debounce = .milliseconds(1)
        let hit = FullTextHit(item: 3, snippet: "1 pdf", bm25: 1, isExactPhrase: true)
        let engine = HybridSearchEngine(
            names: names, lookup: { Self.item($0) }, embedder: FakeModel(),
            vectors: EmptyVectors(), fullText: Texts(hits: [hit]), config: c)
        var emissions: [[UInt32]] = []
        for await batch in engine.results(for: "1.pdf") { emissions.append(batch.map(\.id)) }
        #expect(emissions.count == 3)
        #expect(emissions[0] == [1])
        #expect(Set(emissions[1]) == [1, 3])
        #expect(Set(emissions[2]) == [1, 3])
    }
}
