import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import HunchCore

private func item(_ id: UInt32, _ url: URL) -> Item {
    Item(id: id, path: url.path, name: url.lastPathComponent, kind: .file, modified: Date())
}

private func newPipeline(
    _ dir: URL, media: MediaEmbedder? = nil, embedder: (any Embedder)? = nil,
    vectors: (any VectorIndex)? = nil
) throws -> ContentIndexPipeline {
    try ContentIndexPipeline(
        fullText: FullTextIndex(url: dir.appendingPathComponent("content.sqlite")),
        queueURL: dir.appendingPathComponent("queue.sqlite"), media: media, embedder: embedder,
        vectors: vectors, policy: .always, locale: Locale(identifier: "en-US"))
}

/// The best hit for `q` in `item`, if any.
private func find(_ fts: FullTextIndex, _ q: String, item: UInt32) -> FullTextHit? {
    fts.search(q, limit: 50).first { $0.item == item }
}

// MARK: Full-text index

@Suite struct ContentFullTextTests {
    @Test func phraseSnippetHighlightAndLine() throws {
        let fts = try FullTextIndex.temporary()
        let text =
            (1...40).map { "line \($0) filler words here" }.joined(separator: "\n")
            + "\nthe quarterly zebra-quantum report is due\nmore text"
        try fts.replace(item: 7, chunks: TextChunker.chunks(text))
        let hit = try #require(find(fts, "zebra quantum", item: 7))
        #expect(hit.isExactPhrase)
        #expect(hit.location.line == 41)
        let ns = hit.snippet as NSString
        let h = try #require(hit.highlights.first)
        #expect(ns.substring(with: NSRange(location: h.lowerBound, length: h.count)).lowercased() == "zebra-quantum")
        // Prefix of the last word while typing.
        #expect(find(fts, "zebra quan", item: 7) != nil)
        // Diacritics and case don't matter.
        try fts.replace(item: 8, chunks: [ExtractedChunk(kind: .text, text: "Crème Brûlée recipe")])
        #expect(find(fts, "creme brulee", item: 8)?.isExactPhrase == true)
    }

    @Test func updateAndDeleteByItem() throws {
        let fts = try FullTextIndex.temporary()
        try fts.replace(item: 1, chunks: [ExtractedChunk(kind: .text, text: "alpha marmalade")])
        try fts.replace(item: 2, chunks: [ExtractedChunk(kind: .text, text: "alpha marmalade too")])
        try fts.replace(item: 1, chunks: [ExtractedChunk(kind: .text, text: "beta lighthouse")])
        #expect(find(fts, "marmalade", item: 1) == nil)
        #expect(find(fts, "lighthouse", item: 1) != nil)
        try fts.remove(items: [2])
        #expect(fts.search("marmalade", limit: 10).isEmpty)
        // Kind-scoped replace keeps other kinds.
        try fts.replace([(item: 1, kinds: [.ocr], chunks: [ExtractedChunk(kind: .ocr, text: "scanned walrus")])])
        #expect(find(fts, "walrus", item: 1)?.kind == .ocr)
        #expect(find(fts, "lighthouse", item: 1) != nil)
    }

    @Test func cjkSubstring() throws {
        let fts = try FullTextIndex.temporary()
        try fts.replace(item: 3, chunks: [ExtractedChunk(kind: .text, text: "東京都庁の会議資料を確認してください")])
        #expect(find(fts, "会議資料", item: 3) != nil)
    }

    @Test func chunkerOverlapAndLines() {
        let text = String(repeating: "word ", count: 600) + "\nend"
        let chunks = TextChunker.chunks(text)
        #expect(chunks.count >= 3)
        #expect(chunks.allSatisfy { $0.text.utf16.count <= TextChunker.size })
        #expect(chunks.first?.location.line == 1)
        #expect(chunks.last?.text.hasSuffix("end") == true)
    }
}

let isCI = ProcessInfo.processInfo.environment["CI"] != nil

// MARK: Extraction through the pipeline

@Suite(.serialized) struct ContentPipelineTests {
    @Test(.disabled(if: isCI, "Vision OCR fails on GitHub-hosted macOS runners; tracked in issue #1"))
    func everyFormatFindsItsPhraseAtTheRightLocation() async throws {
        let dir = Fixture.scratch("formats")
        func u(_ n: String) -> URL { dir.appendingPathComponent(n) }
        // Text: phrase on line 3.
        try "first line\nsecond line\nthe saffron hovercraft departs\n".write(
            to: u("notes.md"), atomically: true, encoding: .utf8)
        try "<html><body><script>var hidden='nope'</script><p>marzipan telescope</p></body></html>"
            .write(to: u("page.html"), atomically: true, encoding: .utf8)
        try "{\\rtf1\\ansi{\\fonttbl\\f0 Helvetica;}\\f0 the cobalt pelican sings\\par}"
            .write(to: u("memo.rtf"), atomically: true, encoding: .utf8)
        try Fixture.docx(["intro paragraph", "the vermilion abacus"]).write(to: u("doc.docx"))
        try Fixture.xlsx([(2, "header"), (5, "turquoise gondola")]).write(to: u("sheet.xlsx"))
        try Fixture.pptx(["title slide", "the obsidian trombone"]).write(to: u("deck.pptx"))
        Fixture.write(Fixture.textImage(["Invoice INV-4471", "periwinkle walrus"]), to: u("shot.png"), type: .png)
        Fixture.write(Fixture.textImage(["tangerine glacier"]), to: u("photo.heic"), type: .heic)
        Fixture.pdf(
            textPage: ["Quarterly summary", "the indigo marathon"], scannedPage: ["crimson harmonica"],
            to: u("scan.pdf"))
        try await Fixture.video(text: ["emerald submarine"], textFrom: 8, textTo: 11, seconds: 14, to: u("clip.mp4"))
        try Fixture.say("The magnificent lighthouse keeper plays the violin every evening.", to: u("speech.aiff"))

        let files: [(UInt32, String)] = [
            (1, "notes.md"), (2, "page.html"), (3, "memo.rtf"), (4, "doc.docx"),
            (5, "sheet.xlsx"), (6, "deck.pptx"), (7, "shot.png"), (8, "photo.heic"),
            (9, "scan.pdf"), (10, "clip.mp4"), (11, "speech.aiff"),
        ]
        let p = try newPipeline(dir)
        await p.enqueue(files.map { item($0.0, u($0.1)) })
        #expect(await p.waitUntilIdle(timeout: .seconds(240)))
        let fts = p.fullText

        #expect(find(fts, "saffron hovercraft", item: 1)?.location.line == 3)
        #expect(find(fts, "marzipan telescope", item: 2) != nil)
        #expect(find(fts, "hidden nope", item: 2) == nil)
        #expect(find(fts, "cobalt pelican", item: 3) != nil)
        #expect(find(fts, "vermilion abacus", item: 4) != nil)
        let cell = find(fts, "turquoise gondola", item: 5)
        #expect(cell?.location.page == 1)
        #expect(cell?.location.line == 5)
        #expect(find(fts, "obsidian trombone", item: 6)?.location.page == 2)
        let ocr = try #require(find(fts, "periwinkle walrus", item: 7))
        #expect(ocr.kind == .ocr)
        #expect(ocr.location.region != nil)
        #expect(find(fts, "INV-4471", item: 7) != nil)
        #expect(find(fts, "tangerine glacier", item: 8)?.kind == .ocr)
        let textPage = find(fts, "indigo marathon", item: 9)
        #expect(textPage?.location.page == 1)
        #expect(textPage?.kind == .text)
        let scanned = find(fts, "crimson harmonica", item: 9)
        #expect(scanned?.location.page == 2)
        #expect(scanned?.kind == .ocr)
        let frame = try #require(find(fts, "emerald submarine", item: 10))
        #expect(frame.kind == .ocr)
        #expect(abs((frame.location.time ?? -10) - 8) <= 1)

        let speechStatus = await p.status(item: 11, tier: .media)
        if speechStatus == .speechUnavailable {
            let reason = await MediaReader.speechUnavailableReason(locale: Locale(identifier: "en-US")) ?? "?"
            print("transcript test: speech unavailable — \(reason)")
            #expect(!reason.isEmpty)
        } else {
            let spoken = try #require(find(fts, "lighthouse keeper", item: 11))
            #expect(spoken.kind == .transcript)
            #expect(spoken.location.time != nil)
        }
        let progress = await p.tierProgress
        #expect(progress.allSatisfy { $0.done == $0.total })
        await p.stop()
    }

    @Test func corruptFilesAreSkippedWithoutCrashing() async throws {
        let dir = Fixture.scratch("corrupt")
        func u(_ n: String) -> URL { dir.appendingPathComponent(n) }
        let good = Fixture.scratch("good")
        Fixture.write(Fixture.textImage(["sample text"]), to: good.appendingPathComponent("a.png"), type: .png)
        Fixture.pdf(textPage: ["hello pdf"], scannedPage: ["scan"], to: good.appendingPathComponent("a.pdf"))
        try Fixture.docx(["hello docx"]).write(to: good.appendingPathComponent("a.docx"))
        try Fixture.xlsx([(1, "hello xlsx")]).write(to: good.appendingPathComponent("a.xlsx"))
        try await Fixture.video(
            text: ["x"], textFrom: 1, textTo: 2, seconds: 3, to: good.appendingPathComponent("a.mp4"))
        var items: [Item] = []
        var id: UInt32 = 1
        for name in ["a.png", "a.pdf", "a.docx", "a.xlsx", "a.mp4"] {
            for f in [0.0, 0.1, 0.5, 0.9] {
                let target = u("\(Int(f * 100))-\(name)")
                Fixture.truncated(good.appendingPathComponent(name), fraction: f, to: target)
                items.append(item(id, target))
                id += 1
            }
        }
        var rng = SystemRandomNumberGenerator()
        let junk = Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &rng) })
        for ext in ["jpg", "heic", "mov", "m4a", "pptx", "epub", "txt", "rtf", "pages"] {
            let target = u("junk.\(ext)")
            try junk.write(to: target)
            items.append(item(id, target))
            id += 1
        }
        let p = try newPipeline(dir)
        await p.enqueue(items)
        #expect(await p.waitUntilIdle(timeout: .seconds(180)))
        let status = await p.status
        #expect(status.pending == 0)
        #expect(status.processed >= items.count)
        await p.stop()
    }

    @Test func unchangedFilesAreNotReprocessed() async throws {
        let dir = Fixture.scratch("unchanged")
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        try "the pistachio comet".write(to: a, atomically: true, encoding: .utf8)
        try "another file".write(to: b, atomically: true, encoding: .utf8)
        let p = try newPipeline(dir)
        await p.enqueue([item(1, a), item(2, b)])
        #expect(await p.waitUntilIdle())
        #expect(await p.reads == 2)
        await p.enqueue([item(1, a), item(2, b)])
        #expect(await p.waitUntilIdle())
        #expect(await p.reads == 2)
        // A rename is a path update, not a re-read.
        let moved = dir.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: b, to: moved)
        await p.enqueue([item(2, moved)])
        #expect(await p.waitUntilIdle())
        #expect(await p.reads == 2)
        // A real change is re-read.
        try "the pistachio comet returns, longer now".write(to: a, atomically: true, encoding: .utf8)
        await p.enqueue([item(1, a)])
        #expect(await p.waitUntilIdle())
        #expect(await p.reads == 3)
        #expect(find(p.fullText, "comet returns", item: 1) != nil)
        // A fresh pipeline on the same queue resumes without re-reading.
        await p.stop()
        let p2 = try newPipeline(dir)
        await p2.enqueue([item(1, a), item(2, moved)])
        #expect(await p2.waitUntilIdle())
        #expect(await p2.reads == 0)
        await p2.remove([1])
        #expect(find(p2.fullText, "pistachio", item: 1) == nil)
        await p2.stop()
    }

    @Test func pauseHoldsWork() async throws {
        let dir = Fixture.scratch("pause")
        let a = dir.appendingPathComponent("a.txt")
        try "paused text".write(to: a, atomically: true, encoding: .utf8)
        let p = try newPipeline(dir)
        await p.pause()
        await p.enqueue([item(1, a)])
        try await Task.sleep(for: .milliseconds(300))
        #expect(await p.reads == 0)
        #expect(await p.status.isPaused)
        await p.resume()
        #expect(await p.waitUntilIdle())
        #expect(await p.reads == 1)
        await p.stop()
    }

    /// Needs the EmbeddingGemma 2 model + mmproj; fails (never skips) without them, except in CI where the model is not downloaded.
    @Test(.disabled(if: isCI, "CI does not download the 865 MB model"))
    func imageSemanticsAndImageVectors() async throws {
        let model = try #require(Paths.resolveModel(), "EmbeddingGemma 2 model not found")
        let media = try await MediaEmbedder.load(modelURL: model)
        let dir = Fixture.scratch("semantic")
        let circle = dir.appendingPathComponent("red_circle.png")
        Fixture.write(Fixture.redCircle(), to: circle, type: .png)

        guard let rgb = ImageLoader.rgb(Fixture.redCircle()) else { Issue.record("rgb"); await media.close(); return }
        let v = try await media.embedImage(rgb)
        let red = try await media.embedQuery("red circle")
        let tax = try await media.embedQuery("tax invoice")
        func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        #expect(v.count == 256)
        #expect(abs(dot(v, v) - 1) < 1e-3)
        print("red circle: cos(red circle)=\(dot(v, red)) cos(tax invoice)=\(dot(v, tax))")
        #expect(dot(v, red) > dot(v, tax) + 0.05)

        // Through the pipeline: the image gets an `.image` chunk vector.
        let vectors = MemoryVectors()
        let p = try newPipeline(dir, media: media, vectors: vectors)
        await p.enqueue([item(1, circle)])
        #expect(await p.waitUntilIdle(timeout: .seconds(120)))
        let infos = await vectors.all()
        #expect(infos.contains { $0.kind == .image && $0.item == 1 })
        let best = await vectors.search(red, k: 1).first
        #expect(best.map { Chunk.item($0.id) } == 1)
        await p.stop()
        await media.close()
    }
}
