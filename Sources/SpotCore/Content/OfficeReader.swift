import Foundation

/// docx / xlsx / pptx / odt / ods / odp / epub text through `ZipReader` + `XMLParser` (no process spawning).
enum OfficeReader {
    static let extensions: Set<String> = ["docx", "docm", "dotx", "xlsx", "xlsm", "pptx", "pptm", "odt", "ods", "odp",
                                          "epub"]

    /// Text chunks with locations (slide/sheet/chapter as `page`), or nil when the container is unreadable.
    static func chunks(url: URL, ext: String) -> [ExtractedChunk]? {
        guard let zip = ZipReader(url: url) else { return nil }
        switch ext {
        case "docx", "docm", "dotx":
            guard let xml = zip.read("word/document.xml"),
                  let text = XMLTextCollector.text(xml, breaks: ["p", "tr"], skip: ["instrText", "delText"])
            else { return nil }
            return TextChunker.chunks(text)
        case "pptx", "pptm":
            let slides = numbered(zip, prefix: "ppt/slides/slide", suffix: ".xml")
            guard !slides.isEmpty else { return nil }
            var out: [ExtractedChunk] = []
            for (n, name) in slides {
                guard let xml = zip.read(name), let text = XMLTextCollector.text(xml, breaks: ["p"]) else { continue }
                out += TextChunker.chunks(text, base: ContentLocation(page: n), lines: false)
            }
            return out
        case "xlsx", "xlsm":
            return spreadsheet(zip)
        case "odt", "ods", "odp":
            guard let xml = zip.read("content.xml"),
                  let text = XMLTextCollector.text(xml, breaks: ["p", "h", "table-row", "list-item"])
            else { return nil }
            return TextChunker.chunks(text)
        case "epub":
            let docs = zip.names { n in
                let l = n.lowercased()
                return l.hasSuffix(".xhtml") || l.hasSuffix(".html") || l.hasSuffix(".htm")
            }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            guard !docs.isEmpty else { return nil }
            var out: [ExtractedChunk] = []
            for (i, name) in docs.enumerated() {
                guard let data = zip.read(name), let html = TextDecoder.decode(data) else { continue }
                out += TextChunker.chunks(MarkupStripper.strip(html), base: ContentLocation(page: i + 1), lines: false)
            }
            return out
        default:
            return nil
        }
    }

    /// Entries `prefix{N}suffix`, sorted by N.
    static func numbered(_ zip: ZipReader, prefix: String, suffix: String) -> [(Int, String)] {
        zip.entries.compactMap { e -> (Int, String)? in
            guard e.name.hasPrefix(prefix), e.name.hasSuffix(suffix) else { return nil }
            let mid = e.name.dropFirst(prefix.count).dropLast(suffix.count)
            return Int(mid).map { ($0, e.name) }
        }.sorted { $0.0 < $1.0 }
    }

    /// Sheets as tab-separated rows (`page` = sheet number, `line` = spreadsheet row).
    static func spreadsheet(_ zip: ZipReader) -> [ExtractedChunk]? {
        var shared: [String] = []
        if let xml = zip.read("xl/sharedStrings.xml") {
            let c = XMLTextCollector(breaks: [])
            c.capturing = false
            c.onEnd = { name, c in
                if name == "si" {
                    shared.append(c.current)
                    c.current = ""
                }
            }
            _ = c.parse(xml)
        }
        let sheets = numbered(zip, prefix: "xl/worksheets/sheet", suffix: ".xml")
        guard !sheets.isEmpty else { return nil }
        var out: [ExtractedChunk] = []
        for (n, name) in sheets {
            guard let xml = zip.read(name) else { continue }
            var rows: [(row: Int, text: String)] = []
            var rowNumber = 0
            var cells: [String] = []
            var cellType = ""
            let c = XMLTextCollector(breaks: [])
            c.capturing = false
            c.onStart = { name, attrs, c in
                switch name {
                case "row":
                    rowNumber = Int(attrs["r"] ?? "") ?? rowNumber + 1
                    cells = []
                case "c":
                    cellType = attrs["t"] ?? ""
                    c.current = ""
                default: break
                }
            }
            c.onEnd = { name, c in
                switch name {
                case "c":
                    let raw = c.current
                    let value = cellType == "s" ? Int(raw.trimmingCharacters(in: .whitespaces)).flatMap {
                        $0 >= 0 && $0 < shared.count ? shared[$0] : nil
                    } ?? "" : raw
                    if !value.isEmpty { cells.append(value) }
                    c.current = ""
                case "f":
                    c.current = ""   // formulas aren't content; keep only the cached value
                case "row":
                    if !cells.isEmpty { rows.append((rowNumber, cells.joined(separator: "\t"))) }
                default: break
                }
            }
            guard c.parse(xml) else { continue }
            // Chunk rows ourselves so each chunk's line is its first spreadsheet row.
            var buf = ""
            var first = 0
            var previous = Int.min
            for r in rows {
                // A gap in row numbers starts a new chunk so line arithmetic inside a chunk stays exact.
                if !buf.isEmpty, r.row != previous + 1 {
                    out.append(ExtractedChunk(kind: .text, text: buf, location: ContentLocation(page: n, line: first)))
                    buf = ""
                }
                previous = r.row
                if buf.isEmpty { first = r.row }
                buf += r.text + "\n"
                if buf.utf16.count >= TextChunker.size {
                    out += TextChunker.chunks(buf, base: ContentLocation(page: n), lines: false).map {
                        var ch = $0
                        ch.location.line = first
                        return ch
                    }
                    buf = ""
                }
            }
            if !buf.isEmpty {
                out.append(ExtractedChunk(kind: .text, text: buf, location: ContentLocation(page: n, line: first)))
            }
        }
        return out
    }
}
