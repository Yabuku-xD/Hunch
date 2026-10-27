import Foundation

/// Splits extracted text into overlapping chunks (1,000 characters, 150 overlap), preferring to break at
/// whitespace, and records the 1-based line each chunk starts on.
public enum TextChunker {
    public static let size = 1000
    public static let overlap = 150

    /// Chunks of `text`. `base` supplies page/time/region; `line` is set when `lines` is true.
    public static func chunks(_ text: String, kind: ContentMatch.Kind = .text, base: ContentLocation = .whole,
                              lines: Bool = true, size: Int = size, overlap: Int = overlap) -> [ExtractedChunk] {
        let utf16 = Array(text.utf16)
        let n = utf16.count
        guard n > 0 else { return [] }
        var out: [ExtractedChunk] = []
        var start = 0
        var line = 1
        var lineAt = 0   // utf16 offset up to which `line` is counted
        let newline: UInt16 = 10
        while start < n {
            var end = min(n, start + size)
            if end < n {
                // Content-defined cut: among the line and sentence ends in the last 35% of the window, the one whose
                // preceding 16 characters hash highest; without any, the highest-hashing whitespace in the last 15%.
                // A max-hash pick does not depend on where the window starts, so after an edit both chunk chains cut
                // at the same place within a chunk or two and every later chunk keeps its exact text (and its cached
                // vector, I6) instead of shifting. Never splits a surrogate pair.
                var best = -1
                var bestHash: UInt32 = 0
                var cut = end
                let sentenceFloor = start + size * 65 / 100
                while cut > sentenceFloor {
                    let c = utf16[cut - 1]
                    if c == 10 || (c == 32 && cut >= 2 && (utf16[cut - 2] == 46 || utf16[cut - 2] == 0x3002)) {
                        let h = anchorHash(utf16, before: cut - 1)
                        if best < 0 || h > bestHash { best = cut; bestHash = h }
                    }
                    cut -= 1
                }
                let floor = best > 0 ? sentenceFloor : start + size * 85 / 100
                cut = best > 0 ? floor : end
                while cut > floor {
                    if isSpace(utf16[cut - 1]) {
                        let h = anchorHash(utf16, before: cut - 1)
                        if best < 0 || h > bestHash { best = cut; bestHash = h }
                    }
                    cut -= 1
                }
                if best > floor { end = best }
                if end < n, UTF16.isTrailSurrogate(utf16[end]) { end -= 1 }
            }
            while lineAt < start {
                if utf16[lineAt] == newline { line += 1 }
                lineAt += 1
            }
            let piece = String(decoding: utf16[start..<end], as: UTF16.self)
            if piece.contains(where: { !$0.isWhitespace }) {
                var loc = base
                if lines { loc.line = line }
                out.append(ExtractedChunk(kind: kind, text: piece, location: loc))
            }
            if end >= n { break }
            var next = max(start + 1, end - overlap)
            // Start the overlap at a word boundary when one is close.
            var probe = next
            while probe < end, probe < next + 40, !isSpace(utf16[probe - 1]) { probe += 1 }
            if probe < end, isSpace(utf16[probe - 1]) { next = probe }
            if UTF16.isTrailSurrogate(utf16[next]) { next += 1 }
            start = next
        }
        return out
    }

    /// FNV-1a of the 16 UTF-16 units before `end`.
    @inline(__always) static func anchorHash(_ u: [UInt16], before end: Int) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for i in max(0, end - 16)..<end { h = (h ^ UInt32(u[i])) &* 16_777_619 }
        return h
    }

    @inline(__always) static func isSpace(_ c: UInt16) -> Bool {
        c == 32 || c == 10 || c == 9 || c == 13 || c == 0x3000 || c == 0xA0
    }
}

/// Reads bytes as text: UTF-8 (BOM ok), UTF-16 with BOM, else Windows-1252. nil for binary data (NUL bytes).
enum TextDecoder {
    static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        if bytes.count >= 2, (bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF) {
            return String(data: data, encoding: .utf16)
        }
        let probe = bytes.prefix(8192)
        if probe.contains(0) { return nil }
        var body = bytes[...]
        if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = body.dropFirst(3) }
        if let s = String(validating: body, as: UTF8.self) { return s }
        // A multi-byte sequence cut at the end (size cap) is fine.
        for trim in 1...3 where body.count > trim {
            if let s = String(validating: body.dropLast(trim), as: UTF8.self) { return s }
        }
        // Mostly-binary data that slipped through: too many control characters.
        let controls = probe.reduce(0) { $0 + (($1 < 9 || ($1 > 13 && $1 < 32)) ? 1 : 0) }
        if controls * 20 > probe.count { return nil }
        return String(data: Data(body), encoding: .windowsCP1252)
    }
}

/// Strips HTML/XML-ish markup in one pass: drops script/style bodies, turns block tags into newlines and decodes
/// the common entities. (No WebKit: NSAttributedString's HTML importer isn't safe off the main thread.)
enum MarkupStripper {
    static func strip(_ html: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(html.unicodeScalars.count / 2)
        let s = Array(html.unicodeScalars)
        var i = 0
        let n = s.count
        func lowerName(at j: Int) -> String {
            var k = j
            var name = ""
            while k < n, name.count < 12, s[k].properties.isAlphabetic || ("0"..."9").contains(s[k]) {
                name.unicodeScalars.append(s[k])
                k += 1
            }
            return name.lowercased()
        }
        let blocks: Set<String> = ["p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "section",
                                   "article", "header", "footer", "table", "ul", "ol", "pre", "blockquote", "title"]
        while i < n {
            let c = s[i]
            if c == "<" {
                let closing = i + 1 < n && s[i + 1] == "/"
                let name = lowerName(at: i + (closing ? 2 : 1))
                if !closing, name == "script" || name == "style" {
                    // Skip to the matching close tag.
                    let close = Array("</\(name)".unicodeScalars)
                    var j = i + 1
                    while j < n {
                        if s[j] == "<", j + close.count <= n,
                           String(String.UnicodeScalarView(s[j..<(j + close.count)])).lowercased() == "</\(name)" { break }
                        j += 1
                    }
                    i = j
                }
                if i + 3 < n, s[i + 1] == "!", s[i + 2] == "-", s[i + 3] == "-" {
                    var j = i + 4
                    while j + 2 < n, !(s[j] == "-" && s[j + 1] == "-" && s[j + 2] == ">") { j += 1 }
                    i = j + 3
                    continue
                }
                while i < n, s[i] != ">" { i += 1 }
                i += 1
                if blocks.contains(name) { out.append("\n") } else if !name.isEmpty { out.append(" ") }
                continue
            }
            if c == "&" {
                var j = i + 1
                var ent = ""
                while j < n, j - i < 10, s[j] != ";", s[j] != " ", s[j] != "&" {
                    ent.unicodeScalars.append(s[j])
                    j += 1
                }
                if j < n, s[j] == ";", let decoded = entity(ent) {
                    out.append(decoded)
                    i = j + 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    static func entity(_ e: String) -> Unicode.Scalar? {
        switch e {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:
            if e.hasPrefix("#x") || e.hasPrefix("#X") { return UInt32(e.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init) }
            if e.hasPrefix("#") { return UInt32(e.dropFirst()).flatMap(Unicode.Scalar.init) }
            return nil
        }
    }
}
