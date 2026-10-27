import CoreGraphics
import Foundation
import ImageIO
import Vision

/// ImageIO decoding straight to the working size (thumbnails, so a 48 MP HEIC never decodes at full size).
enum ImageLoader {
    /// Images over this many pixels are skipped (names only).
    static let maxPixels = 100_000_000
    /// Long side for OCR and embedding.
    static let maxSide = 1600

    enum Failure: Error { case unreadable, tooLarge }

    /// The first frame of `url` (GIF: first frame; RAW via ImageIO), oriented and downscaled to ≤ `maxSide`.
    static func load(_ url: URL, maxSide: Int = maxSide) -> Result<CGImage, Failure> {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts), CGImageSourceGetCount(src) > 0 else {
            return .failure(.unreadable)
        }
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any] {
            let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
            if w * h > maxPixels { return .failure(.tooLarge) }
        } else {
            return .failure(.unreadable)
        }
        let thumb: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, thumb as CFDictionary), img.width > 0 else {
            return .failure(.unreadable)
        }
        return .success(img)
    }

    /// Decodes in-memory image data the same way.
    static func load(data: Data, maxSide: Int = maxSide) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        let thumb: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, thumb as CFDictionary)
    }

    /// Packed RGB at ≤ `maxSide` (the projector resizes again; this only bounds the copy).
    static func rgb(_ img: CGImage, maxSide: Int = 896) -> RGBImage? {
        let scale = min(1, Double(maxSide) / Double(max(img.width, img.height)))
        let w = max(1, Int((Double(img.width) * scale).rounded()))
        let h = max(1, Int((Double(img.height) * scale).rounded()))
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        rgb.withUnsafeMutableBufferPointer { d in
            rgba.withUnsafeBufferPointer { s in
                for i in 0..<(w * h) {
                    d[i * 3] = s[i * 4]
                    d[i * 3 + 1] = s[i * 4 + 1]
                    d[i * 3 + 2] = s[i * 4 + 2]
                }
            }
        }
        return RGBImage(width: w, height: h, bytes: rgb)
    }

    /// Perceptual signature: a 64-bit difference hash (9×8 grayscale) plus mean luminance, since a dHash alone can't
    /// tell a flat black frame from a mostly white one.
    struct Signature: Equatable {
        var hash: UInt64
        var mean: Int

        func isNear(_ o: Signature, bits: Int) -> Bool {
            (hash ^ o.hash).nonzeroBitCount <= bits && abs(mean - o.mean) < 12
        }
    }

    static func signature(_ img: CGImage) -> Signature {
        var px = [UInt8](repeating: 0, count: 9 * 8)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        }
        var h: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                h <<= 1
                if px[y * 9 + x] < px[y * 9 + x + 1] { h |= 1 }
            }
        }
        return Signature(hash: h, mean: px.reduce(0) { $0 + Int($1) } / px.count)
    }

    /// Mean luminance variance proxy: a nearly flat frame (black, white) has no text or meaning worth a vector.
    static func isFlat(_ img: CGImage) -> Bool {
        var px = [UInt8](repeating: 0, count: 16 * 16)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let lo = px.min() ?? 0, hi = px.max() ?? 0
        return Int(hi) - Int(lo) < 6
    }
}

/// One recognized line.
struct OCRLine: Sendable {
    var text: String
    /// Top-left origin, normalized.
    var region: ContentRegion
}

/// Apple Vision text recognition: accurate, automatic language, no language correction.
///
/// Correction costs 15–20% per dense screenshot here (~145 → ~120 ms on 1440×900 with 14 lines; spec M.iii: 101 →
/// 55 ms) and rewrites the tokens people search screenshots for — invoice numbers, codes, error identifiers — into
/// dictionary words. Search tolerates small OCR slips through prefixes and the semantic leg.
enum TextRecognizer {
    static func recognize(_ img: CGImage) async -> [OCRLine] {
        guard img.width >= 24, img.height >= 12 else { return [] }
        var req = RecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.automaticallyDetectsLanguage = true
        req.usesLanguageCorrection = false
        guard let obs = try? await req.perform(on: img) else { return [] }
        var lines: [OCRLine] = []
        for o in obs {
            guard let s = o.topCandidates(1).first?.string, !s.isEmpty else { continue }
            let r = o.boundingBox.cgRect
            lines.append(OCRLine(text: s, region: ContentRegion(x: r.minX, y: 1 - r.maxY, width: r.width,
                                                                height: r.height)))
        }
        // Reading order: top to bottom, then left to right within a band.
        lines.sort { a, b in
            if abs(a.region.y - b.region.y) > min(a.region.height, b.region.height) * 0.5 { return a.region.y < b.region.y }
            return a.region.x < b.region.x
        }
        return lines
    }

    /// OCR lines grouped into ≤ 1,000-character chunks; each chunk's region is the union of its lines.
    static func chunks(_ lines: [OCRLine], base: ContentLocation = .whole) -> [ExtractedChunk] {
        var out: [ExtractedChunk] = []
        var text = ""
        var box: ContentRegion?
        func flush() {
            guard !text.isEmpty else { return }
            var loc = base
            loc.region = box
            out.append(ExtractedChunk(kind: .ocr, text: text, location: loc))
            text = ""
            box = nil
        }
        for l in lines {
            if !text.isEmpty, text.utf16.count + l.text.utf16.count > TextChunker.size { flush() }
            text += text.isEmpty ? l.text : "\n" + l.text
            box = box.map { union($0, l.region) } ?? l.region
        }
        flush()
        return out
    }

    static func union(_ a: ContentRegion, _ b: ContentRegion) -> ContentRegion {
        let x0 = min(a.x, b.x), y0 = min(a.y, b.y)
        let x1 = max(a.x + a.width, b.x + b.width), y1 = max(a.y + a.height, b.y + b.height)
        return ContentRegion(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
