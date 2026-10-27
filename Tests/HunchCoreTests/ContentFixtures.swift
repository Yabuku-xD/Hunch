import AVFoundation
import Compression
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

@testable import HunchCore

/// Generated test fixtures for the content tests (no checked-in binaries).
enum Fixture {
    static func scratch(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ContentTests-\(tag)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Images

    /// Black text on white, `lines` stacked from the top.
    static func textImage(_ lines: [String], width: Int = 1200, height: Int = 600, fontSize: CGFloat = 44) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(lines, in: ctx, height: CGFloat(height), fontSize: fontSize)
        return ctx.makeImage()!
    }

    static func draw(_ lines: [String], in ctx: CGContext, height: CGFloat, fontSize: CGFloat, x: CGFloat = 40) {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        for (i, s) in lines.enumerated() {
            let attr = NSAttributedString(
                string: s,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                        red: 0, green: 0, blue: 0, alpha: 1),
                ])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: x, y: height - 40 - fontSize - CGFloat(i) * fontSize * 1.6)
            CTLineDraw(line, ctx)
        }
    }

    static func redCircle(size: Int = 512) -> CGImage {
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        let inset = CGFloat(size) * 0.15
        ctx.fillEllipse(
            in: CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset))
        return ctx.makeImage()!
    }

    static func write(_ img: CGImage, to url: URL, type: UTType) {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        precondition(CGImageDestinationFinalize(dest), "couldn't write \(url.lastPathComponent)")
    }

    // MARK: PDF

    /// Page 1 has a real text layer; page 2 is an image only (a "scan").
    static func pdf(textPage: [String], scannedPage: [String], to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        draw(textPage, in: ctx, height: 792, fontSize: 18)
        ctx.endPDFPage()
        ctx.beginPDFPage(nil)
        let scan = textImage(scannedPage, width: 1224, height: 1584, fontSize: 40)
        ctx.draw(scan, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    // MARK: Video

    /// 1 fps H.264: flat black frames except `text` shown from `textFrom` to `textTo` seconds.
    static func video(text: [String], textFrom: Int, textTo: Int, seconds: Int, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let w = 960, h = 540
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let textFrame = textImage(text, width: w, height: h, fontSize: 40)
        for s in 0...seconds {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            if s >= textFrom && s < textTo {
                ctx.draw(textFrame, in: CGRect(x: 0, y: 0, width: w, height: h))
            } else {
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(s), timescale: 1))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    // MARK: Audio

    /// `say -o` with a known sentence.
    static func say(_ sentence: String, to url: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-o", url.path, sentence]
        try p.run()
        p.waitUntilExit()
        precondition(p.terminationStatus == 0, "say failed")
    }

    // MARK: Zip / Office

    /// A ZIP archive; entries are DEFLATE-compressed when that is smaller.
    static func zip(_ entries: [(String, String)]) -> Data {
        var out = Data()
        var central = Data()
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]
        }
        for (name, text) in entries {
            let raw = Array(text.utf8)
            var deflated = [UInt8](repeating: 0, count: raw.count + 1024)
            let n = compression_encode_buffer(&deflated, deflated.count, raw, raw.count, nil, COMPRESSION_ZLIB)
            let useDeflate = n > 0 && n < raw.count
            let payload = useDeflate ? Array(deflated[0..<n]) : raw
            let crc = crc32(raw)
            let nameBytes = Array(name.utf8)
            let offset = UInt32(out.count)
            let method = useDeflate ? 8 : 0
            out.append(
                contentsOf: le32(0x0403_4B50) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0) + le32(crc)
                    + le32(UInt32(payload.count)) + le32(UInt32(raw.count)) + le16(nameBytes.count) + le16(0))
            out.append(contentsOf: nameBytes)
            out.append(contentsOf: payload)
            central.append(
                contentsOf: le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(method) + le16(0)
                    + le16(0) + le32(crc) + le32(UInt32(payload.count)) + le32(UInt32(raw.count))
                    + le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset))
            central.append(contentsOf: nameBytes)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.append(
            contentsOf: le32(0x0605_4B50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
                + le32(UInt32(central.count)) + le32(cdOffset) + le16(0))
        return out
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        }
        return ~c
    }

    static func docx(_ paragraphs: [String]) -> Data {
        let body = paragraphs.map { "<w:p><w:r><w:t xml:space=\"preserve\">\(esc($0))</w:t></w:r></w:p>" }.joined()
        return zip([
            ("[Content_Types].xml", "<?xml version=\"1.0\"?><Types/>"),
            (
                "word/document.xml",
                """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)</w:body></w:document>
                """
            ),
        ])
    }

    /// One sheet; `cells` are (row, shared string).
    static func xlsx(_ cells: [(Int, String)]) -> Data {
        let shared = cells.map { "<si><t>\(esc($0.1))</t></si>" }.joined()
        let rows = cells.enumerated().map { i, c in
            "<row r=\"\(c.0)\"><c r=\"A\(c.0)\" t=\"s\"><v>\(i)</v></c><c r=\"B\(c.0)\"><v>\(c.0 * 10)</v></c></row>"
        }.joined()
        return zip([
            (
                "xl/sharedStrings.xml",
                "<?xml version=\"1.0\"?><sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\(shared)</sst>"
            ),
            (
                "xl/worksheets/sheet1.xml",
                "<?xml version=\"1.0\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(rows)</sheetData></worksheet>"
            ),
        ])
    }

    static func pptx(_ slides: [String]) -> Data {
        zip(
            slides.enumerated().map { i, s in
                (
                    "ppt/slides/slide\(i + 1).xml",
                    """
                    <?xml version="1.0"?><p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>\(esc(s))</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>
                    """
                )
            })
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }

    /// The first `fraction` of `url`'s bytes, written to `to`.
    static func truncated(_ url: URL, fraction: Double, to: URL) {
        let d = try! Data(contentsOf: url)
        try! d.prefix(Int(Double(d.count) * fraction)).write(to: to)
    }
}

/// In-memory `VectorIndex` for pipeline tests.
actor MemoryVectors: VectorIndex {
    var vectors: [ChunkID: [Float]] = [:]
    var infos: [ChunkID: ChunkInfo] = [:]

    func upsert(_ id: ChunkID, _ v: [Float]) { vectors[id] = v }
    func remove(_ id: ChunkID) {
        vectors[id] = nil
        infos[id] = nil
    }
    func search(_ q: [Float], k: Int) -> [(id: ChunkID, score: Float)] {
        vectors.map { (id: $0.key, score: zip(q, $0.value).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }
            .sorted { $0.score > $1.score }.prefix(k).map { $0 }
    }
    func upsertChunks(_ chunks: [(info: ChunkInfo, vector: [Float])]) {
        for c in chunks {
            vectors[c.info.id] = c.vector
            infos[c.info.id] = c.info
        }
    }
    func chunkInfo(_ ids: [ChunkID]) -> [ChunkID: ChunkInfo] {
        var out: [ChunkID: ChunkInfo] = [:]
        for id in ids { out[id] = infos[id] }
        return out
    }
    func storedVector(_ id: ChunkID) -> [Float]? { vectors[id] }
    func all() -> [ChunkInfo] { Array(infos.values) }
}
