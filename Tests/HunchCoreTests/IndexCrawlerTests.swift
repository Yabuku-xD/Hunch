import AppKit
import CoreText
import Foundation
import PDFKit
import Testing

@testable import HunchCore

/// Temp directory helper shared by the Index* tests (paths are symlink-resolved, as FSEvents reports them).
struct IndexTempDir: ~Copyable {
    let path: String

    init() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bs-index-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        path = Crawler.realPath(base.path)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    func write(_ rel: String, _ text: String = "x") {
        let full = path + "/" + rel
        try! FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try! text.write(toFile: full, atomically: false, encoding: .utf8)
    }

    func mkdir(_ rel: String) {
        try! FileManager.default.createDirectory(atPath: path + "/" + rel, withIntermediateDirectories: true)
    }
}

@Suite struct IndexCrawlerTests {
    static func makeTree(_ t: borrowing IndexTempDir) {
        t.write("Docs/report.txt")
        t.write("Docs/Sub/deep.md")
        t.write("Docs/.hidden.txt")
        t.write(".secret/x.txt")
        t.write("node_modules/pkg/index.js")
        t.write("Proj/main.swift")
        t.write("Proj/.git/config")
        t.write("Proj/.build/debug/x")
        t.write("Proj/DerivedData/y")
        t.write("Proj/Caches/z")
        t.write("Tool.app/Contents/MacOS/Tool")
        t.write("Lib.bundle/Contents/Info.plist")
        t.write("Holiday.photoslibrary/database/db")
        t.write("Library/Preferences/p.plist")  // skipped: home is the temp root
        t.mkdir("Empty")
        // UF_HIDDEN without a dot.
        t.write("FlagHidden/inside.txt")
        _ = chflags(t.path + "/FlagHidden", UInt32(UF_HIDDEN))
    }

    static let expected: Set<String> = [
        "Docs", "Docs/report.txt", "Docs/Sub", "Docs/Sub/deep.md", "Proj", "Proj/main.swift",
        "Tool.app", "Lib.bundle", "Holiday.photoslibrary", "Empty",
    ]

    @Test func crawlsTreeWithPackagesHiddenAndSkips() async {
        let t = IndexTempDir()
        Self.makeTree(t)
        let crawler = Crawler(roots: [t.url], home: t.path, maxConcurrency: 3)
        let (entries, stats) = await crawler.crawlEntries()
        let rel = Set(entries.map { String($0.path.dropFirst(t.path.count + 1)) })
        #expect(rel == Self.expected)
        #expect(entries.count == Self.expected.count)  // no duplicates
        #expect(stats.count == entries.count)
        let byRel = Dictionary(uniqueKeysWithValues: entries.map { (String($0.path.dropFirst(t.path.count + 1)), $0) })
        #expect(byRel["Tool.app"]?.kind == .app)
        #expect(byRel["Tool.app"]?.name == "Tool")
        #expect(byRel["Lib.bundle"]?.kind == .file)
        #expect(byRel["Holiday.photoslibrary"]?.kind == .file)
        #expect(byRel["Docs"]?.kind == .folder)
        #expect(byRel["Docs/report.txt"]?.kind == .file)
        #expect(abs(byRel["Docs/report.txt"]!.modified.timeIntervalSinceNow) < 120)

        // Sync variant finds the same set.
        let sync = Set(crawler.crawl().map { String($0.path.dropFirst(t.path.count + 1)) })
        #expect(sync == Self.expected)
    }

    @Test func indexablePathRules() {
        let t = IndexTempDir()
        let c = Crawler(roots: [t.url], home: t.path)
        #expect(c.indexablePath(for: t.path + "/Docs/a.txt") == t.path + "/Docs/a.txt")
        #expect(c.indexablePath(for: t.path + "/Tool.app/Contents/MacOS/Tool") == t.path + "/Tool.app")
        #expect(c.indexablePath(for: t.path + "/Docs/.DS_Store") == nil)
        #expect(c.indexablePath(for: t.path + "/node_modules/a/b.js") == nil)
        #expect(c.indexablePath(for: t.path + "/Library/x") == nil)
        #expect(c.indexablePath(for: t.path) == nil)
        #expect(c.indexablePath(for: "/elsewhere/file") == nil)
    }

    @Test func nestedRootsAreDeduplicated() {
        let t = IndexTempDir()
        t.mkdir("Applications")
        let c = Crawler(roots: [t.url, t.url.appendingPathComponent("Applications"), t.url], home: t.path)
        #expect(c.rootPaths == [t.path])
    }

    @Test func realHomeThroughput() async throws {
        // Measurement only (not a gate): the real default scope.
        guard ProcessInfo.processInfo.environment["HUNCH_CRAWL_BENCH"] != nil else { return }
        let (entries, stats) = await Crawler().crawlEntries()
        print("Crawler: \(entries.count) items in \(stats.seconds) s = \(Int(stats.itemsPerSecond)) items/s")
    }
}

@Suite struct IndexExtractorTests {
    @Test func formatDForNamesOnly() {
        let x = ContentExtractor(home: "/Users/me")
        let jpg = Item(
            id: 1, path: "/Users/me/Pictures/Holidays/golden_retriever_beach.jpg",
            name: "golden_retriever_beach.jpg", kind: .file, modified: .now)
        let doc = x.document(for: jpg)!
        #expect(doc.title == "none")
        #expect(doc.text == "golden retriever beach (image) in Pictures/Holidays")
        let app = Item(
            id: 2, path: "/Applications/Visual Studio Code.app", name: "Visual Studio Code", kind: .app, modified: .now)
        #expect(x.document(for: app)!.text == "Visual Studio Code (application) in Applications")
        let folder = Item(id: 3, path: "/Users/me/Documents/tax-2023", name: "tax-2023", kind: .folder, modified: .now)
        #expect(x.document(for: folder)!.text == "tax 2023 (folder) in Documents")
        let pdf = Item(
            id: 4, path: "/Users/me/missing/report_invoice_12.pdf", name: "report_invoice_12.pdf", kind: .file,
            modified: .now)
        #expect(x.document(for: pdf)!.text == "report invoice 12 (PDF document) in missing")
    }

    @Test func extractsTextMarkdownSourceAndRejectsBinary() throws {
        let t = IndexTempDir()
        t.write("notes.md", "# Trip\n\nBeach   day\twith the dog")
        t.write("main.swift", "print(\"hello\")")
        t.write("LICENSE", "MIT License")
        try Data([0x89, 0x50, 0x00, 0x01, 0x02]).write(to: URL(fileURLWithPath: t.path + "/blob.weird"))
        try Data(repeating: 0x41, count: 10_000).write(to: URL(fileURLWithPath: t.path + "/big.txt"))
        let x = ContentExtractor(home: t.path)
        #expect(x.extractText(at: t.path + "/notes.md") == "# Trip Beach day with the dog")
        #expect(x.extractText(at: t.path + "/main.swift") == "print(\"hello\")")
        #expect(x.extractText(at: t.path + "/LICENSE") == "MIT License")
        #expect(x.extractText(at: t.path + "/blob.weird") == nil)
        #expect(x.extractText(at: t.path + "/big.txt")?.count == 1500)
        let item = Item(id: 1, path: t.path + "/notes.md", name: "notes.md", kind: .file, modified: .now)
        let doc = x.document(for: item)!
        #expect(doc.title == "notes.md")
        #expect(doc.text == "notes (text document) in Home. # Trip Beach day with the dog")
        let bin = Item(id: 2, path: t.path + "/blob.weird", name: "blob.weird", kind: .file, modified: .now)
        #expect(x.document(for: bin)!.title == "none")
    }

    @Test func extractsRTFDocxAndPDF() throws {
        let t = IndexTempDir()
        let s = NSAttributedString(string: "Quarterly budget summary")
        let rtf = try s.data(
            from: NSRange(location: 0, length: s.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try rtf.write(to: URL(fileURLWithPath: t.path + "/a.rtf"))
        let docx = try s.data(
            from: NSRange(location: 0, length: s.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try docx.write(to: URL(fileURLWithPath: t.path + "/a.docx"))
        Self.writePDF(t.path + "/a.pdf", pages: ["Page one dog", "Page two cat", "Page three secret"])
        let x = ContentExtractor()
        #expect(x.extractText(at: t.path + "/a.rtf") == "Quarterly budget summary")
        #expect(x.extractText(at: t.path + "/a.docx") == "Quarterly budget summary")
        let pdf = try #require(x.extractText(at: t.path + "/a.pdf"))
        #expect(pdf.contains("one dog") && pdf.contains("two cat"))
        #expect(!pdf.contains("secret"))  // first 2 pages only
    }

    static func writePDF(_ path: String, pages: [String]) {
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil)!
        for text in pages {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(
                string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
            ctx.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
