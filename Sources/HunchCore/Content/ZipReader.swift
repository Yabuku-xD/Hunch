import Compression
import Foundation

/// Minimal ZIP reader for office/e-book containers: EOCD → central directory → local header, stored or DEFLATE
/// entries (inflated with the Compression framework). No ZIP64, no encryption; anything odd returns nil.
struct ZipReader {
    struct Entry {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var size: Int
        var localOffset: Int
        var encrypted: Bool
    }

    /// Largest entry we inflate (zip-bomb guard).
    static let maxEntrySize = 64 << 20

    let data: Data
    private(set) var entries: [Entry] = []

    init?(url: URL) {
        guard let d = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: d)
    }

    init?(data: Data) {
        self.data = data
        guard data.count >= 22 else { return nil }
        // Find the end-of-central-directory record in the last 64 KB.
        let count = data.count
        let lower = max(0, count - 65_557)
        var eocd = -1
        var i = count - 22
        while i >= lower {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let total = Int(u16(eocd + 10))
        let cdSize = Int(u32(eocd + 12))
        let cdOffset = Int(u32(eocd + 16))
        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= count, total < 200_000 else { return nil }
        var p = cdOffset
        for _ in 0..<total {
            guard p + 46 <= count, u32(p) == 0x0201_4B50 else { return nil }
            let flags = u16(p + 8)
            let method = u16(p + 10)
            let csize = Int(u32(p + 20))
            let usize = Int(u32(p + 24))
            let nameLen = Int(u16(p + 28))
            let extraLen = Int(u16(p + 30))
            let commentLen = Int(u16(p + 32))
            let local = Int(u32(p + 42))
            guard p + 46 + nameLen <= count else { return nil }
            let nameBytes = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLen))
            let name = String(decoding: nameBytes, as: UTF8.self)
            entries.append(
                Entry(
                    name: name, method: method, compressedSize: csize, size: usize, localOffset: local,
                    encrypted: flags & 1 != 0))
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }

    func names(matching predicate: (String) -> Bool) -> [String] { entries.map(\.name).filter(predicate) }

    /// The inflated bytes of `name`, or nil if it's missing, encrypted, too big or corrupt.
    func read(_ name: String) -> Data? {
        guard let e = entry(name) else { return nil }
        return read(e)
    }

    func read(_ e: Entry) -> Data? {
        guard !e.encrypted, e.size <= Self.maxEntrySize, e.compressedSize >= 0 else { return nil }
        let count = data.count
        let p = e.localOffset
        guard p >= 0, p + 30 <= count, u32(p) == 0x0403_4B50 else { return nil }
        let start = p + 30 + Int(u16(p + 26)) + Int(u16(p + 28))
        guard start <= count, start + e.compressedSize <= count else { return nil }
        let src = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.compressedSize))
        switch e.method {
        case 0:
            return src
        case 8:
            guard e.size > 0 else { return Data() }
            var out = Data(count: e.size)
            let written = out.withUnsafeMutableBytes { dst in
                src.withUnsafeBytes { s in
                    compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, e.size,
                        s.bindMemory(to: UInt8.self).baseAddress!, e.compressedSize,
                        nil, COMPRESSION_ZLIB)
                }
            }
            guard written == e.size else { return nil }
            return out
        default:
            return nil
        }
    }

    private func u16(_ o: Int) -> UInt16 {
        let b = data.startIndex + o
        return UInt16(data[b]) | UInt16(data[b + 1]) << 8
    }

    private func u32(_ o: Int) -> UInt32 {
        let b = data.startIndex + o
        return UInt32(data[b]) | UInt32(data[b + 1]) << 8 | UInt32(data[b + 2]) << 16 | UInt32(data[b + 3]) << 24
    }
}

/// Collects the character data of an XML document with XMLParser, inserting line breaks after block elements.
/// Optional hooks let callers capture attributes (spreadsheet cells) or split into sections.
final class XMLTextCollector: NSObject, XMLParserDelegate {
    /// Local names (prefix stripped) that end a line.
    let breaks: Set<String>
    /// Local names whose text is ignored.
    let skip: Set<String>
    private(set) var text = ""
    private var skipping = 0
    var onStart: ((_ name: String, _ attributes: [String: String], _ collector: XMLTextCollector) -> Void)?
    var onEnd: ((_ name: String, _ collector: XMLTextCollector) -> Void)?
    /// When false, character data is dropped (callers toggle it from the hooks).
    var capturing = true
    var current = ""

    init(breaks: Set<String>, skip: Set<String> = []) {
        self.breaks = breaks
        self.skip = skip
    }

    /// Parses `data`; nil when the XML is malformed (truncated files).
    static func text(_ data: Data, breaks: Set<String>, skip: Set<String> = [], tabs: Set<String> = []) -> String? {
        let c = XMLTextCollector(breaks: breaks, skip: skip)
        if !tabs.isEmpty {
            c.onStart = { name, _, c in if tabs.contains(name) { c.append("\t") } }
        }
        return c.parse(data) ? c.text : nil
    }

    func parse(_ data: Data) -> Bool {
        let p = XMLParser(data: data)
        p.delegate = self
        p.shouldResolveExternalEntities = false
        let ok = p.parse()
        return ok || !text.isEmpty && p.parserError == nil
    }

    func append(_ s: String) {
        text += s
    }

    static func local(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        let name = Self.local(elementName)
        if skip.contains(name) { skipping += 1 }
        if name == "br" || name == "line-break" { text += "\n" }
        if name == "tab" || name == "s" && elementName.hasPrefix("text:") { text += " " }
        onStart?(name, attributeDict, self)
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = Self.local(elementName)
        if skip.contains(name) { skipping = max(0, skipping - 1) }
        onEnd?(name, self)
        if breaks.contains(name), !text.isEmpty, text.last != "\n" { text += "\n" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipping == 0 else { return }
        if capturing { text += string } else { current += string }
    }
}
