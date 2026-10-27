import Foundation
import Synchronization
import Testing

@testable import HunchCore

// K17 query operators and K18 shared index policy.

@Suite struct QueryParserTests {
    static let home = "/Users/me"

    @Test(arguments: [
        ("invoice", ParsedQuery(text: "invoice")),
        ("a:b.txt", ParsedQuery(text: "a:b.txt")),
        ("kind:foo bar", ParsedQuery(text: "kind:foo bar")),
        ("name:invoice", ParsedQuery(text: "invoice", nameOnly: true)),
        ("tax in:Downloads", ParsedQuery(text: "tax", folders: ["/Users/me/Downloads"])),
        ("in:~/Work/ x", ParsedQuery(text: "x", folders: ["/Users/me/Work"])),
        ("in:\"My Stuff\" plan", ParsedQuery(text: "plan", folders: ["/Users/me/My Stuff"])),
        ("in:/Volumes/X report", ParsedQuery(text: "report", folders: ["/Volumes/X"])),
        ("ext:PDF ext:.md notes", ParsedQuery(text: "notes", extensions: ["pdf", "md"])),
        ("KIND:app safari", ParsedQuery(text: "safari", kinds: [.app])),
        ("in: x", ParsedQuery(text: "in: x")),
    ])
    func table(_ input: String, _ expected: ParsedQuery) {
        #expect(QueryParser.parse(input, home: Self.home) == expected)
    }

    @Test func filters() {
        let pdf = Item(id: 1, path: "/Users/me/Downloads/a.pdf", name: "a.pdf", kind: .file, modified: .now)
        let sibling = Item(id: 2, path: "/Users/me/Downloads2/a.pdf", name: "a.pdf", kind: .file, modified: .now)
        let png = Item(id: 3, path: "/Users/me/Downloads/b.png", name: "b.png", kind: .file, modified: .now)
        let app = Item(id: 4, path: "/Applications/Safari.app", name: "Safari.app", kind: .app, modified: .now)
        let inDl = QueryParser.parse("in:Downloads", home: Self.home)
        #expect(inDl.matches(pdf) && inDl.matches(png) && !inDl.matches(sibling))
        #expect(QueryParser.parse("kind:image", home: Self.home).matches(png))
        #expect(!QueryParser.parse("kind:image", home: Self.home).matches(pdf))
        #expect(QueryParser.parse("kind:doc", home: Self.home).matches(pdf))
        #expect(QueryParser.parse("kind:app", home: Self.home).matches(app))
        #expect(!QueryParser.parse("ext:pdf", home: Self.home).matches(png))
    }

    @Test func engineHonoursNameOnlyAndScope() async throws {
        let items: [UInt32: Item] = [
            1: Item(id: 1, path: "/r/Downloads/invoice.pdf", name: "invoice.pdf", kind: .file, modified: .now),
            2: Item(id: 2, path: "/r/Other/invoice.txt", name: "invoice.txt", kind: .file, modified: .now),
            3: Item(id: 3, path: "/r/Other/notes.txt", name: "notes.txt", kind: .file, modified: .now),
        ]
        let names = NameIndex()
        names.replaceAll(items.values)
        let fullText = ContentOnlyText()
        let engine = HybridSearchEngine(names: names, lookup: { items[$0] }, fullText: fullText)
        engine.attach(scope: { folder, _ in items.values.filter { $0.path.hasPrefix(folder + "/") } })

        // name: skips full text: notes.txt (content-only hit) never shows.
        var seen: Set<UInt32> = []
        for await batch in engine.results(for: "name:invoice") { seen.formUnion(batch.map(\.id)) }
        #expect(seen == [1, 2])
        #expect(fullText.calls.load(ordering: .relaxed) == 0)

        // Without name: the content-only hit arrives.
        seen = []
        for await batch in engine.results(for: "invoice") { seen.formUnion(batch.map(\.id)) }
        #expect(seen.contains(3))

        // in: excludes other folders, from both legs.
        seen = []
        for await batch in engine.results(for: "invoice in:/r/Downloads") { seen.formUnion(batch.map(\.id)) }
        #expect(seen == [1])

        // in: alone lists the folder through the range scope.
        seen = []
        for await batch in engine.results(for: "in:/r/Other") { seen.formUnion(batch.map(\.id)) }
        #expect(seen == [2, 3])
    }
}

/// Full text that finds notes.txt (id 3) for any query and counts calls.
private final class ContentOnlyText: FullTextIndexing, Sendable {
    let calls = Atomic<Int>(0)
    func search(_ q: String, limit: Int) -> [FullTextHit] {
        calls.add(1, ordering: .relaxed)
        return [FullTextHit(item: 3, snippet: "invoice inside", bm25: 1, isExactPhrase: false)]
    }
}

@Suite struct PolicyTests {
    @Test func lowPowerPausesEverything() {
        let p = IndexPolicy(lowPower: { true }, thermalSerious: { false }, onBattery: { false })
        #expect(p.pausesAll)
        for t in [ContentTier.documents, .images, .media] { #expect(!p.allows(t)) }
    }

    @Test func batteryAndHoursOnlyHoldDeferrableTiers() {
        let battery = IndexPolicy(lowPower: { false }, thermalSerious: { false }, onBattery: { true })
        #expect(battery.allows(.documents) && !battery.allows(.images) && !battery.allows(.media))

        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let nightOnly = IndexPolicy(
            lowPower: { false }, thermalSerious: { false }, onBattery: { false },
            hours: .init(from: 22, to: 6), now: { noon })
        #expect(nightOnly.allows(.documents))
        #expect(!nightOnly.allows(.media))  // outside the window: T3 not started
        let dayOnly = IndexPolicy(
            lowPower: { false }, thermalSerious: { false }, onBattery: { false },
            hours: .init(from: 9, to: 17), now: { noon })
        #expect(dayOnly.allows(.media))
    }

    @Test func lowPowerPausesNameEmbeddingLoop() async throws {
        let tree = FileManager.default.temporaryDirectory.appendingPathComponent("PolicyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tree) }
        FileManager.default.createFile(atPath: tree.appendingPathComponent("a.txt").path, contents: Data("x".utf8))
        let embedder = CountingDocs()
        let vectors = try VectorStore(directory: tree.appendingPathComponent(".v"), dimension: 8)
        let policy = IndexPolicy(lowPower: { true }, thermalSerious: { false }, onBattery: { false })
        let coordinator = IndexCoordinator(roots: [tree], embedder: embedder, vectors: vectors, policy: policy)
        await coordinator.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while await coordinator.activity != .paused, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await coordinator.activity == .paused)
        #expect(embedder.docs.load(ordering: .relaxed) == 0)
        await coordinator.stop()
    }
}

private final class CountingDocs: Embedder, Sendable {
    let docs = Atomic<Int>(0)
    var dimension: Int { 8 }
    func embedQueries(_ q: [String]) async throws -> [[Float]] { q.map { _ in [Float](repeating: 0.35, count: 8) } }
    func embedDocuments(_ d: [(title: String, text: String)]) async throws -> [[Float]] {
        docs.add(d.count, ordering: .relaxed)
        return d.map { _ in [Float](repeating: 0.35, count: 8) }
    }
}
