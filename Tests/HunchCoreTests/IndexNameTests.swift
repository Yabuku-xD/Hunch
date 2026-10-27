import Foundation
import Testing

@testable import HunchCore

@Suite struct IndexNameTests {
    static let old = Date(timeIntervalSinceNow: -400 * 86_400)
    var nextID: UInt32 = 1

    static func items(_ names: [String], kind: ItemKind = .file, modified: Date = old, from start: UInt32 = 1) -> [Item]
    {
        names.enumerated().map { i, n in
            Item(id: start + UInt32(i), path: "/x/\(n)", name: n, kind: kind, modified: modified)
        }
    }

    static func names(_ index: NameIndex, _ q: String, limit: Int = 10, all: [Item]) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.name) })
        return index.search(q, limit: limit).map { byID[$0.id]! }
    }

    @Test func exactBeatsPrefix() {
        let all = Self.items(["Notes Backup", "Notes", "notes.txt"])
        let idx = NameIndex(items: all)
        let r = Self.names(idx, "notes", all: all)
        #expect(r.first == "Notes")
        #expect(r[1] == "notes.txt")  // exact stem
        #expect(r.count == 3)
    }

    @Test func prefixBeatsWordBoundary() {
        let all = Self.items(["My Calendar", "Calendar Export", "minical"])
        let idx = NameIndex(items: all)
        #expect(Self.names(idx, "cal", all: all) == ["Calendar Export", "My Calendar", "minical"])
    }

    @Test func wordBoundaryPrefixSeparatorsAndCamelCase() {
        let all = Self.items([
            "project_report.pdf", "data-report.csv", "q3.report", "MyReport.doc", "AnnualReport", "unreported.txt",
        ])
        let idx = NameIndex(items: all)
        let r = Self.names(idx, "report", all: all)
        #expect(
            Set(r.prefix(5)) == ["project_report.pdf", "data-report.csv", "q3.report", "MyReport.doc", "AnnualReport"])
        #expect(r.last == "unreported.txt")  // mid-word: fuzzy tier only
        let fold = NameIndex.fold("XMLParser2go")
        let starts = fold.flags.enumerated().filter { $0.element == 1 }.map(\.offset)
        #expect(starts == [0, 3, 9, 10])  // X, P, 2, g
    }

    @Test func acronymVSC() {
        var all = Self.items(["devise_cards.txt", "Very Small Cat Pictures"])
        all += Self.items(["Visual Studio Code"], kind: .app, from: 10)
        let idx = NameIndex(items: all)
        let r = Self.names(idx, "vsc", all: all)
        #expect(r.first == "Visual Studio Code")
        #expect(r.last == "devise_cards.txt")
        let s = idx.search("vsc", limit: 3)
        #expect(s[0].score * NameIndex.scoreScale > 450)
    }

    @Test func acronymBeatsFuzzyWithoutBoosts() {
        let all = Self.items(["Google Chrome Canary", "gocheck"])
        let idx = NameIndex(items: all)
        #expect(Self.names(idx, "gcc", all: all) == ["Google Chrome Canary", "gocheck"])
    }

    @Test func fuzzyGapPenalty() {
        let all = Self.items(["axbxc", "axxxbxxxc", "ab_c_suffix"])
        let idx = NameIndex(items: all)
        let r = Self.names(idx, "abc", all: all)
        #expect(r.firstIndex(of: "axbxc")! < r.firstIndex(of: "axxxbxxxc")!)
        #expect(Self.names(idx, "xyz", all: all).isEmpty)
    }

    @Test func diacriticAndCaseInsensitive() {
        let all = Self.items(["Résumé.pdf", "resume_old.txt", "CAFÉ MENU", "Straße"])
        let idx = NameIndex(items: all)
        #expect(Self.names(idx, "resume", all: all).first == "Résumé.pdf")
        #expect(Set(Self.names(idx, "résumé", all: all)) == ["Résumé.pdf", "resume_old.txt"])
        #expect(Self.names(idx, "RESUME", all: all).count == 2)
        #expect(Self.names(idx, "cafe", all: all) == ["CAFÉ MENU"])
        #expect(Self.names(idx, "menu", all: all) == ["CAFÉ MENU"])
        // Decomposed (NFD) input folds the same way.
        #expect(Self.names(idx, "re\u{301}sume\u{301}", all: all).first == "Résumé.pdf")
        #expect(!Self.names(idx, "stra", all: all).isEmpty)
    }

    @Test func boostsAppOpensRecency() {
        var all = Self.items(["Safari"], kind: .folder)
        all += Self.items(["Safari"], kind: .app, from: 2)
        all += Self.items(["report a.txt", "report b.txt"], from: 3)
        all += Self.items(["report c.txt"], modified: .now, from: 5)
        let idx = NameIndex(items: all)
        #expect(idx.search("safari", limit: 2).first?.id == 2)
        #expect(idx.search("report", limit: 3).first?.id == 5)  // recency
        // Opens long ago have decayed away (half-life 7 days) ...
        for _ in 0..<8 { idx.recordOpen(3, at: Self.old) }
        #expect(idx.search("report", limit: 3).first?.id == 5)
        // ... recent ones boost.
        for _ in 0..<3 { idx.recordOpen(4, at: Date(timeIntervalSinceNow: -86_400)) }
        #expect(idx.search("report", limit: 3).first?.id == 4)  // frecency
    }

    @Test func upsertRemoveAndCompaction() {
        let idx = NameIndex(items: Self.items(["alpha", "beta"]))
        #expect(idx.count == 2)
        idx.upsert([Item(id: 1, path: "/x/gamma", name: "gamma", kind: .file, modified: .now)])
        #expect(idx.search("alpha", limit: 5).isEmpty)
        #expect(idx.search("gamma", limit: 5).map(\.id) == [1])
        idx.remove([2])
        #expect(idx.search("beta", limit: 5).isEmpty)
        #expect(idx.count == 1)
        let many = Self.items((0..<5000).map { "file\($0)" }, from: 100)
        idx.upsert(many)
        idx.remove(many.prefix(4000).map(\.id))
        #expect(idx.count == 1001)
        #expect(idx.search("file4999", limit: 1).first?.id == 5099)
    }

    @Test func concurrentReadsAndWrites() async {
        let idx = NameIndex(items: Self.items((0..<2000).map { "doc \($0)" }))
        await withTaskGroup(of: Void.self) { g in
            for t in 0..<4 {
                g.addTask {
                    for i in 0..<200 { _ = idx.search("doc \(i)", limit: 10) }
                }
                g.addTask {
                    for i in 0..<200 {
                        let id = UInt32(10_000 + t * 1000 + i)
                        idx.upsert([Item(id: id, path: "/y/\(id)", name: "new \(id)", kind: .file, modified: .now)])
                    }
                }
            }
        }
        #expect(idx.count == 2800)
    }

    @Test func performance200k() {
        let words = [
            "report", "invoice", "photo", "beach", "holiday", "budget", "Visual", "Studio", "code", "notes",
            "draft", "final", "résumé", "project", "data", "export", "backup", "scan", "IMG", "meeting",
        ]
        let exts = ["pdf", "txt", "jpg", "md", "swift", "png", "docx", ""]
        var rng = SystemRandomNumberGenerator()
        var items: [Item] = []
        items.reserveCapacity(200_000)
        for i in 0..<200_000 {
            let n = Int.random(in: 1...4, using: &rng)
            var name = (0..<n).map { _ in words.randomElement(using: &rng)! }.joined(
                separator: ["_", " ", "-", ""].randomElement()!)
            name += "\(i % 997)"
            let ext = exts.randomElement()!
            if !ext.isEmpty { name += "." + ext }
            items.append(
                Item(
                    id: UInt32(i + 1), path: "/p/\(name)", name: name, kind: i % 100 == 0 ? .app : .file,
                    modified: Date(timeIntervalSinceNow: -Double(i))))
        }
        let t0 = ContinuousClock.now
        let idx = NameIndex(items: items)
        let build = ContinuousClock.now - t0
        let queries = [
            "r", "re", "rep", "inv", "vsc", "beach", "phbe", "notes2", "résumé", "zz", "img12", "budget",
            "pro", "d", "fin", "q", "meetin", "dataex",
        ]
        var times: [Double] = []
        for _ in 0..<3 {
            for q in queries {
                let s = ContinuousClock.now
                _ = idx.search(q, limit: 20)
                times.append((ContinuousClock.now - s) / .milliseconds(1))
            }
        }
        times.sort()
        let p95 = times[Int(Double(times.count) * 0.95)]
        print(
            "NameIndex 200k: build \(build), p95 \(String(format: "%.2f", p95)) ms, max \(String(format: "%.2f", times.last!)) ms"
        )
        #if DEBUG
        #expect(p95 < 250)  // unoptimized build; the 10 ms target is checked with -c release
        #else
        #expect(p95 <= 10)
        #endif
    }
}
