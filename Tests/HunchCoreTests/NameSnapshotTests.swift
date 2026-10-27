import Foundation
import Testing

@testable import HunchCore

@Suite struct NameSnapshotTests {
    static func items(_ n: Int) -> [Item] {
        var r = SystemRandomNumberGenerator()
        let words = ["invoice", "Résumé", "会議メモ", "budget", "a：b", "Kernel", "终端", "orbit"]
        return (0..<n).map { i in
            let name = "\(words[i % words.count])_\(i)" + (i % 3 == 0 ? ".txt" : "")
            return Item(
                id: UInt32(i + 1), path: "/x/\(name)", name: name, kind: i % 50 == 0 ? .app : .file,
                modified: Date(timeIntervalSinceReferenceDate: Double(UInt32.random(in: 0...800_000_000, using: &r))))
        }
    }

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("names-\(UUID().uuidString).bin")
    }

    @Test func roundTripAnswersEveryQueryTheSame() throws {
        let all = Self.items(3_000)
        let index = NameIndex(aliases: { AppNames.pinyinKeys($0.name) })
        index.replaceAll(all)
        index.remove([5, 6, 7])
        index.upsert([Item(id: 6, path: "/x/renamed", name: "renamed orbit", kind: .file, modified: .now)])
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let gen = NameIndex.snapshotGeneration(of: all)
        try index.writeSnapshot(url, generation: gen)
        let loaded = NameIndex(aliases: { _ in [] })
        #expect(loaded.loadSnapshot(url, generation: gen))
        #expect(loaded.count == index.count)
        for q in ["inv", "résumé", "会議", "a:b", "kern", "zhongduan", "zd", "orbit_7", "renamed", "o", "b_1"] {
            #expect(loaded.search(q, limit: 20).map(\.id) == index.search(q, limit: 20).map(\.id), "\(q)")
        }
        // Later mutations work on a loaded index.
        loaded.remove([6])
        #expect(loaded.search("renamed", limit: 5).isEmpty)
    }

    @Test func corruptTruncatedOrStaleSnapshotsFallBack() throws {
        let all = Self.items(500)
        let index = NameIndex(items: all)
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let gen = NameIndex.snapshotGeneration(of: all)
        try index.writeSnapshot(url, generation: gen)
        let good = try Data(contentsOf: url)
        let fresh = NameIndex()
        #expect(!fresh.loadSnapshot(url, generation: gen &+ 1), "generation mismatch")
        #expect(!fresh.loadSnapshot(Self.tempURL(), generation: gen), "missing file")
        var flipped = good
        flipped[good.count / 2] ^= 0x5A
        try flipped.write(to: url)
        #expect(!fresh.loadSnapshot(url, generation: gen), "flipped byte")
        try good.prefix(good.count - 9).write(to: url)
        #expect(!fresh.loadSnapshot(url, generation: gen), "truncated")
        try Data(repeating: 0xFF, count: 64).write(to: url)
        #expect(!fresh.loadSnapshot(url, generation: gen), "garbage")
        #expect(fresh.count == 0)
        // Any change to a name changes the generation.
        var renamed = all
        renamed[3].name += "x"
        #expect(NameIndex.snapshotGeneration(of: renamed) != gen)
    }
}
