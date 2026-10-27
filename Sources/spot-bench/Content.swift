import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SpotCore
import UniformTypeIdentifiers

// `--content`: the content-indexing budgets on generated fixtures, through the same SpotCore entry points the app
// uses (ContentIndexPipeline, ContentReader, MediaEmbedder, FullTextIndex). Prints, in this order:
//
//   text_files_per_sec=          tier 1 end to end (read + chunk + FTS write + queue) over 3,000 mixed documents
//   ocr_ms_per_image=            Vision OCR per 1440×900 screenshot (mean, after one warm-up)
//   image_embed_ms=              EmbeddingGemma 2 mmproj vector per image (mean, after one warm-up)
//   video_s_per_min=             tier 3 frames (distinct-frame OCR + image vectors) per minute of video
//   transcript_x_realtime=       SpeechAnalyzer speed (audio seconds per wall second), or `unavailable reason=…`
//   fts_p95_ms= chunks=200000    FullTextIndex query p95 over 200k chunks
//   fts_index_mb_per_100mb_text= index size on disk per 100 MB of indexed text

func contentBench() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spot-bench-content-\(getpid())",
                                                                            isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
        note("content: can't create \(dir.path): \(error)")
        exit(1)
    }
    defer { try? FileManager.default.removeItem(at: dir) }
    var rng = RNG(state: 0xC0DE_FACE_1234_5678)
    let corpus = Corpus(&rng)

    // BS_CONTENT_ONLY=text,ocr,image,video,speech,fts runs a subset (for iterating on one stage).
    let only = ProcessInfo.processInfo.environment["BS_CONTENT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    func runs(_ stage: String) -> Bool { only?.contains(stage) ?? true }

    if runs("text") { print("text_files_per_sec=\(await textFilesPerSecond(dir, corpus, &rng))") }

    let shots = (0..<24).map { i in screenshot(title: "Report \(i + 1)", lines: (0..<14).map { _ in Corpus.screenLine(&rng) }) }
    if runs("ocr") { print("ocr_ms_per_image=\(await ocrMsPerImage(dir, shots))") }

    // The image model, loaded once for the image and video metrics (the app shares one the same way).
    var media: MediaEmbedder?
    var mediaWhy = ""
    if !runs("image") && !runs("video") {
        mediaWhy = "skipped"
    } else if let model = Paths.resolveModel() {
        do {
            media = try await MediaEmbedder.load(modelURL: model, dimension: 256)
        } catch {
            mediaWhy = "\(error)"
        }
    } else {
        mediaWhy = "no embedding model found (set BS_MODEL to the gguf path)"
    }
    if media == nil { note("content: image embedding unavailable: \(mediaWhy)") }

    if runs("image") {
        if let media {
            print("image_embed_ms=\(await imageEmbedMs(media, shots))")
        } else {
            print("image_embed_ms=unavailable reason=\"\(mediaWhy)\"")
        }
    }
    if runs("video") { print("video_s_per_min=\(await videoSecondsPerMinute(dir, corpus, media, &rng))") }
    await media?.close()

    if runs("speech") { print("transcript_x_realtime=\(await transcriptRealtime(dir, corpus, &rng))") }

    if runs("fts") {
        let (p95Line, sizeLine) = ftsBench(dir, corpus, &rng)
        print(p95Line)
        print(sizeLine)
    }
}

// MARK: Corpus

/// Zipf-like vocabulary: common English words plus generated ones, so the FTS index has a realistic long tail.
struct Corpus {
    let vocab: [String]

    init(_ rng: inout RNG) {
        let common = ["the", "of", "and", "to", "in", "is", "for", "that", "with", "on", "as", "by", "this", "from",
                      "be", "are", "at", "or", "an", "was", "we", "will", "can", "all", "has", "report", "invoice",
                      "budget", "meeting", "project", "design", "summary", "quarterly", "contract", "insurance",
                      "receipt", "schedule", "customer", "revenue", "analysis", "review", "update", "release",
                      "account", "payment", "delivery", "travel", "itinerary", "lecture", "chapter", "thesis"]
        let onsets = ["b", "c", "d", "f", "g", "h", "k", "l", "m", "n", "p", "r", "s", "t", "v", "st", "tr", "pl",
                      "gr", "br", "ch", "sh", "th"]
        let nuclei = ["a", "e", "i", "o", "u", "ai", "ea", "ou", "io"]
        let codas = ["", "n", "r", "s", "t", "l", "m", "nd", "rt", "ck"]
        var seen = Set(common)
        var words = common
        while words.count < 8000 {
            var w = ""
            for _ in 0..<Int.random(in: 2...4, using: &rng) {
                w += onsets[Int.random(in: 0..<onsets.count, using: &rng)]
                w += nuclei[Int.random(in: 0..<nuclei.count, using: &rng)]
                w += codas[Int.random(in: 0..<codas.count, using: &rng)]
            }
            if seen.insert(w).inserted { words.append(w) }
        }
        vocab = words
    }

    /// Screen text is natural language (the generated words above would defeat Vision's language model and make OCR
    /// slower than on any real screenshot): sentence fragments with numbers, dates and identifiers, ~80 characters.
    static let screenPhrases = [
        "Quarterly revenue grew 12% compared with last year", "Invoice INV-4471 is due on March 3",
        "Please review the attached contract before Friday", "Meeting notes from the design review",
        "Total amount: $1,284.50 including tax", "The build failed because a dependency is missing",
        "Shipping address and billing details", "Your flight to Lisbon departs at 07:45 from gate B12",
        "Click Save to keep your changes", "Error: permission denied while opening the file",
        "Project roadmap for the second half", "Customer support ticket #20931 was resolved",
        "Wi-Fi password for the guest network", "Agenda: budget, hiring plan, office move",
        "Monthly statement for account ending 0042", "Insurance claim submitted on 14 June 2025",
        "Recipe: two cups of flour and one egg", "Lecture 7 covers sorting algorithms and heaps",
        "The server responded with status 503", "Delivery window between 9 am and noon",
        "Thank you for your order", "Settings are saved automatically", "Draft version 3, not for distribution",
        "Open the terminal and run the install script", "Receipt for the conference registration",
    ]

    static func screenLine(_ rng: inout RNG, maxChars: Int = 90) -> String {
        var line = screenPhrases[Int.random(in: 0..<screenPhrases.count, using: &rng)]
        while true {
            let next = screenPhrases[Int.random(in: 0..<screenPhrases.count, using: &rng)]
            guard line.count + 2 + next.count <= maxChars else { break }
            line += ". " + next
        }
        return line
    }

    func word(_ rng: inout RNG) -> String {
        vocab[min(vocab.count - 1, Int(Double(vocab.count) * pow(Double.random(in: 0..<1, using: &rng), 3)))]
    }

    func sentence(_ n: Int, _ rng: inout RNG) -> String {
        var s = (0..<n).map { _ in word(&rng) }.joined(separator: " ")
        s = s.prefix(1).uppercased() + s.dropFirst()
        return s + "."
    }

    func prose(words n: Int, _ rng: inout RNG) -> String {
        var out = ""
        var left = n
        while left > 0 {
            let k = min(left, Int.random(in: 6...16, using: &rng))
            out += sentence(k, &rng)
            left -= k
            out += Int.random(in: 0..<5, using: &rng) == 0 ? "\n\n" : " "
        }
        return out
    }
}

// MARK: Tier 1

/// Writes 3,000 documents (txt, md, csv, html, swift, json and 2-page PDFs) and times the content pipeline from
/// enqueue until every file's text is in the full-text index.
func textFilesPerSecond(_ dir: URL, _ corpus: Corpus, _ rng: inout RNG) async -> String {
    let root = dir.appendingPathComponent("docs", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var items: [Item] = []
    let total = 3000
    var bytes = 0
    for i in 0..<total {
        let text = corpus.prose(words: Int.random(in: 300...1500, using: &rng), &rng)
        let ext: String
        var body = text
        switch i % 20 {
        case 0: ext = "pdf"
        case 1, 2:
            ext = "html"
            body = "<html><head><title>Doc \(i)</title></head><body>"
                + text.components(separatedBy: "\n\n").map { "<p>\($0)</p>" }.joined() + "</body></html>"
        case 3, 4:
            ext = "csv"
            body = text.split(separator: " ").chunked(6).map { $0.joined(separator: ",") }.joined(separator: "\n")
        case 5, 6, 7:
            ext = "md"
            body = "# Notes \(i)\n\n" + text
        case 8, 9:
            ext = "swift"
            body = text.components(separatedBy: ". ").map { "// \($0)" }.joined(separator: "\n")
        case 10:
            ext = "json"
            body = "{\"id\": \(i), \"body\": \"" + text.replacingOccurrences(of: "\n", with: "\\n") + "\"}"
        default: ext = "txt"
        }
        let url = root.appendingPathComponent("doc-\(i).\(ext)")
        if ext == "pdf" {
            writePDF(pages: [String(text.prefix(text.count / 2)), String(text.suffix(text.count - text.count / 2))],
                     to: url)
        } else {
            do { try body.write(to: url, atomically: false, encoding: .utf8) } catch {
                note("content: write failed: \(error)")
                return "nan"
            }
        }
        bytes += text.utf8.count
        items.append(Item(id: UInt32(i + 1), path: url.path, name: url.lastPathComponent, kind: .file, modified: Date()))
    }
    do {
        let fullText = try FullTextIndex(url: dir.appendingPathComponent("t1-fts.sqlite"))
        let pipeline = try ContentIndexPipeline(fullText: fullText, queueURL: dir.appendingPathComponent("t1-queue.sqlite"),
                                                policy: .always, home: dir.path)
        var idle = false
        let ms = await millis {
            await pipeline.enqueue(items)
            idle = await pipeline.waitUntilIdle(timeout: .seconds(600))
        }
        await pipeline.stop()
        let reads = await pipeline.reads
        note("content: tier 1 read \(reads) of \(total) files (\(fmt(Double(bytes) / 1_048_576)) MiB text) into " +
             "\(fullText.chunkCount) chunks in \(fmt(ms)) ms on \(pipeline.cpuWorkers) workers")
        guard idle, reads == total, fullText.chunkCount > 0 else {
            note("content: tier 1 did not finish (idle \(idle), reads \(reads)/\(total))")
            return "nan"
        }
        return fmt(Double(total) / (ms / 1000))
    } catch {
        note("content: pipeline failed: \(error)")
        return "nan"
    }
}

extension Array {
    func chunked(_ n: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: n).map { self[$0..<Swift.min($0 + n, count)] }
    }
}

func writePDF(pages: [String], to url: URL) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
    let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
    for text in pages {
        ctx.beginPDFPage(nil)
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ])
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: box.insetBy(dx: 54, dy: 54), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

// MARK: Tier 2

/// A 1440×900 "screenshot": a grey title bar and dark text lines on white.
func screenshot(title: String, lines: [String], width: Int = 1440, height: Int = 900) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 0.92, green: 0.92, blue: 0.93, alpha: 1))
    ctx.fill(CGRect(x: 0, y: height - 56, width: width, height: 56))
    drawLines([title], in: ctx, top: CGFloat(height) - 16, size: 26)
    drawLines(lines, in: ctx, top: CGFloat(height) - 100, size: 24)
    return ctx.makeImage()!
}

func drawLines(_ lines: [String], in ctx: CGContext, top: CGFloat, size: CGFloat, x: CGFloat = 48) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    for (i, s) in lines.enumerated() {
        let attr = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1),
        ])
        ctx.textPosition = CGPoint(x: x, y: top - size - CGFloat(i) * size * 1.6)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
    }
}

func writePNG(_ img: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(dest, img, nil)
    return CGImageDestinationFinalize(dest)
}

/// Mean ms per image of the tier-2 reader (OCR only: no image model), after one warm-up image.
func ocrMsPerImage(_ dir: URL, _ shots: [CGImage]) async -> String {
    var paths: [String] = []
    for (i, img) in shots.enumerated() {
        let url = dir.appendingPathComponent("shot-\(i).png")
        guard writePNG(img, to: url) else { note("content: PNG write failed"); return "nan" }
        paths.append(url.path)
    }
    let reader = ContentReader(media: nil)
    var empty = 0
    let warm = await millis { _ = await reader.read(path: paths[0], tier: .images) }
    note("content: OCR warm-up \(fmt(warm)) ms")
    var samples: [Double] = []
    for p in paths.dropFirst() {
        var r: ExtractedContent?
        samples.append(await millis { r = await reader.read(path: p, tier: .images) })
        if r?.chunks.isEmpty ?? true { empty += 1 }
    }
    if empty > 0 { note("content: WARNING \(empty) screenshots produced no OCR text") }
    note("content: OCR p95 \(fmt(p95(samples))) ms over \(samples.count) screenshots")
    guard empty < samples.count else { return "nan" }
    return fmt(samples.reduce(0, +) / Double(samples.count))
}

/// Packed RGB at ≤ 896 px, the size the reader hands the projector.
func rgbImage(_ img: CGImage, maxSide: Int = 896) -> RGBImage? {
    let scale = min(1, Double(maxSide) / Double(max(img.width, img.height)))
    let w = max(1, Int((Double(img.width) * scale).rounded()))
    let h = max(1, Int((Double(img.height) * scale).rounded()))
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return nil }
    var rgb = [UInt8](repeating: 0, count: w * h * 3)
    for i in 0..<(w * h) {
        rgb[i * 3] = rgba[i * 4]
        rgb[i * 3 + 1] = rgba[i * 4 + 1]
        rgb[i * 3 + 2] = rgba[i * 4 + 2]
    }
    return RGBImage(width: w, height: h, bytes: rgb)
}

/// Mean ms per image vector (the projector + model pass), after one warm-up image.
func imageEmbedMs(_ media: MediaEmbedder, _ shots: [CGImage]) async -> String {
    let images = shots.compactMap { rgbImage($0) }
    guard images.count > 1 else { return "nan" }
    do {
        let warm = try await millis { _ = try await media.embedImage(images[0]) }
        note("content: image embed warm-up \(fmt(warm)) ms")
        var samples: [Double] = []
        for img in images.dropFirst() {
            samples.append(try await millis { _ = try await media.embedImage(img) })
        }
        note("content: image embed p95 \(fmt(p95(samples))) ms over \(samples.count) images")
        return fmt(samples.reduce(0, +) / Double(samples.count))
    } catch {
        note("content: image embedding failed: \(error)")
        return "nan"
    }
}

// MARK: Tier 3

/// A 2-minute 960×540 H.264 slideshow (a new slide every 8 s) read by the tier-3 reader: distinct frames are OCR'd
/// and, with the model, embedded. Wall seconds per minute of video.
func videoSecondsPerMinute(_ dir: URL, _ corpus: Corpus, _ media: MediaEmbedder?, _ rng: inout RNG) async -> String {
    let url = dir.appendingPathComponent("slides.mp4")
    let seconds = 120
    let slides = (0..<(seconds / 8 + 1)).map { i in
        screenshot(title: "Slide \(i + 1)", lines: (0..<8).map { _ in Corpus.screenLine(&rng, maxChars: 60) },
                   width: 960, height: 540)
    }
    do {
        try await writeVideo(seconds: seconds, frame: { slides[$0 / 8] }, to: url)
    } catch {
        note("content: video write failed: \(error)")
        return "nan"
    }
    let reader = ContentReader(media: media)
    var r: ExtractedContent?
    let ms = await millis { r = await reader.read(path: url.path, tier: .media) }
    let chunks = r?.chunks.count ?? 0, vectors = r?.images.count ?? 0
    note("content: video \(seconds) s → \(chunks) OCR chunks, \(vectors) frame vectors in \(fmt(ms)) ms" +
         (media == nil ? " (no image model: OCR only)" : ""))
    guard chunks > 0 else { return "nan" }
    return fmt((ms / 1000) / (Double(seconds) / 60))
}

func writeVideo(seconds: Int, frame: (Int) -> CGImage, to url: URL) async throws {
    let w = 960, h = 540
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
    ])
    let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
    try writer.start()
    writer.startSession(atSourceTime: .zero)
    let attributes = CVPixelBufferCreationAttributes(pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
                                                     size: CVImageSize(width: w, height: h))
    for s in 0...seconds {
        let image = frame(s)
        let buffer = try CVMutablePixelBuffer(attributes)
        buffer.withUnsafeBuffer { pb in
            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
        }
        try await receiver.append(CVReadOnlyPixelBuffer(buffer), with: CMTime(value: CMTimeValue(s), timescale: 1))
    }
    receiver.finish()
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

/// `say -o` ~1 minute of English speech, transcribed by the tier-3 reader. Audio seconds per wall second, or
/// `unavailable reason="…"` when SpeechAnalyzer can't run here.
func transcriptRealtime(_ dir: URL, _ corpus: Corpus, _ rng: inout RNG) async -> String {
    let url = dir.appendingPathComponent("speech.aiff")
    let script = """
        The quarterly budget review starts with the travel expenses from the spring conference. \
        Our customer revenue grew in every region except the northern office, where two contracts were delayed. \
        Please send the signed insurance forms before Friday, and keep the receipts for the delivery fees. \
        The design team will present the new release schedule after lunch, followed by a short summary of the \
        open questions. We agreed to move the project meeting to Thursday morning at nine thirty. \
        Remember that the lecture notes for chapter seven are in the shared folder, next to the thesis draft. \
        Finally, the payment for the itinerary was confirmed, and the account will be updated next week.
        """
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Samantha", "-o", url.path, script]
    say.standardError = FileHandle.nullDevice
    do {
        try say.run()
        say.waitUntilExit()
        if say.terminationStatus != 0 {  // voice not installed: the default voice
            let retry = Process()
            retry.executableURL = say.executableURL
            retry.arguments = ["-o", url.path, script]
            try retry.run()
            retry.waitUntilExit()
            guard retry.terminationStatus == 0 else { return "unavailable reason=\"say failed\"" }
        }
    } catch {
        return "unavailable reason=\"say failed: \(error)\""
    }
    guard let duration = try? await AVURLAsset(url: url).load(.duration).seconds, duration > 0 else {
        return "unavailable reason=\"couldn't read the generated audio\""
    }
    let reader = ContentReader(media: nil, locale: Locale(identifier: "en_US"))
    var r: ExtractedContent?
    let ms = await millis { r = await reader.read(path: url.path, tier: .media) }
    guard let r else { return "nan" }
    if r.status == .speechUnavailable || (r.chunks.isEmpty && r.note != nil) {
        let why = (r.note ?? "speech recognition unavailable").replacingOccurrences(of: "\"", with: "'")
        return "unavailable reason=\"\(why)\""
    }
    let words = r.chunks.map(\.text).joined(separator: " ")
    note("content: transcribed \(fmt(duration)) s of speech in \(fmt(ms)) ms: \(words.prefix(80))…")
    guard !words.isEmpty else { return "unavailable reason=\"the transcriber returned no text (status \(r.status))\"" }
    return fmt(duration / (ms / 1000))
}

// MARK: Full text

/// 200,000 chunks of ~500 characters (≈ 100 MB of text) in a FullTextIndex, then 500 mixed queries.
func ftsBench(_ dir: URL, _ corpus: Corpus, _ rng: inout RNG) -> (String, String) {
    let chunkCount = 200_000, perItem = 10
    let fail = ("fts_p95_ms=nan chunks=\(chunkCount)", "fts_index_mb_per_100mb_text=nan")
    let index: FullTextIndex
    do { index = try FullTextIndex(url: dir.appendingPathComponent("fts-bench.sqlite")) } catch {
        note("content: FTS open failed: \(error)")
        return fail
    }
    var textBytes = 0
    var phrases: [String] = []
    let t0 = ContinuousClock.now
    do {
        var batch: [(item: UInt32, kinds: Set<ContentMatch.Kind>?, chunks: [ExtractedChunk])] = []
        for item in 0..<(chunkCount / perItem) {
            var chunks: [ExtractedChunk] = []
            for c in 0..<perItem {
                let text = corpus.prose(words: 80, &rng)
                textBytes += text.utf8.count
                if item % 400 == 0, c == 0 {
                    phrases.append(text.split(separator: " ").prefix(3).joined(separator: " ")
                        .trimmingCharacters(in: .punctuationCharacters))
                }
                chunks.append(ExtractedChunk(kind: .text, text: text, location: ContentLocation(page: c + 1)))
            }
            batch.append((item: UInt32(item + 1), kinds: nil, chunks: chunks))
            if batch.count == 500 {
                try index.replace(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { try index.replace(batch) }
    } catch {
        note("content: FTS insert failed: \(error)")
        return fail
    }
    index.optimize()
    let buildMs = (ContinuousClock.now - t0) / .milliseconds(1)
    let stored = index.chunkCount
    note("content: FTS built \(stored) chunks (\(fmt(Double(textBytes) / 1_048_576)) MiB text) in \(fmt(buildMs)) ms")

    // Query mix: frequent and rare words, 2–4 character prefixes (typing), two words, three-word phrases.
    let queries: [String] = (0..<500).map { i in
        switch i % 5 {
        case 0: return corpus.word(&rng)
        case 1: return corpus.vocab[Int.random(in: 500..<corpus.vocab.count, using: &rng)]
        case 2: let w = corpus.word(&rng); return String(w.prefix(Int.random(in: 2...min(4, max(2, w.count)), using: &rng)))
        case 3: return "\(corpus.word(&rng)) \(corpus.word(&rng))"
        default: return phrases[Int.random(in: 0..<phrases.count, using: &rng)]
        }
    }
    for q in queries.prefix(20) { _ = index.search(q, limit: 50) }
    var hits = 0
    let samples = queries.map { q in
        millis { hits += index.search(q, limit: 50).isEmpty ? 0 : 1 }
    }
    let kinds = ["word", "rare word", "prefix", "two words", "phrase"]
    let byKind = kinds.indices.map { k in
        "\(kinds[k]) \(fmt(p95(samples.indices.filter { $0 % 5 == k }.map { samples[$0] })))"
    }
    note("content: FTS \(hits)/\(queries.count) queries had hits; max \(fmt(samples.max() ?? .nan)) ms; " +
         "p95 by kind: \(byKind.joined(separator: ", "))")
    let mb = Double(index.sizeOnDisk) / 1_048_576
    let perHundred = mb / (Double(textBytes) / 1_048_576) * 100
    note("content: FTS index \(fmt(mb)) MiB on disk")
    guard stored == chunkCount, hits > 0 else { return fail }
    return ("fts_p95_ms=\(fmt(p95(samples))) chunks=\(stored)", "fts_index_mb_per_100mb_text=\(fmt(perHundred))")
}
