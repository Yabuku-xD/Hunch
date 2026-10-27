import Compression
import Foundation
import SQLite3
import Synchronization

/// Full-text index over document text, OCR text and transcripts (owner: media).
///
/// Measured design (spec M.vi): words go into a contentless FTS5 `unicode61 remove_diacritics 2` table with 2/3-char
/// prefix indexes (p95 0.26 ms prefix, 2.2 ms common ranked at 200k chunks, 0.37 MB index per MB of text). The trigram
/// tokenizer is 3–4× bigger and 98 ms p95 on common 3-char queries, so it only indexes chunks in scripts unicode61
/// can't segment (CJK, Thai, …) and answers queries in those scripts as substrings. Chunk text lives LZFSE-compressed in
/// `ft_chunk` for snippets and exact-phrase checks. Search is synchronous on a dedicated read connection (WAL), so
/// writes never block a keystroke for long.
public final class FullTextIndex: FullTextIndexing, Sendable {
    public let url: URL
    private let reader: Mutex<Connection>
    private let writer: Mutex<Connection>

    /// Characters of context around the first match in a snippet.
    static let snippetRadius = 70
    /// Matches scored with bm25 per FTS query; beyond this, matches are taken in index order.
    static let rankWindow = 200

    public init(url: URL) throws {
        self.url = url
        let w = try Connection(url: url, write: true)
        try w.db.exec(
            """
            PRAGMA cache_size=-16000;
            PRAGMA auto_vacuum=INCREMENTAL;
            CREATE TABLE IF NOT EXISTS ft_chunk(
                id INTEGER PRIMARY KEY, item INTEGER NOT NULL, kind INTEGER NOT NULL,
                page INTEGER, line INTEGER, time REAL, rx REAL, ry REAL, rw REAL, rh REAL,
                cjk INTEGER NOT NULL DEFAULT 0, body BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS ft_chunk_item ON ft_chunk(item);
            CREATE VIRTUAL TABLE IF NOT EXISTS ft_words USING fts5(body, content='', contentless_delete=1,
                tokenize='unicode61 remove_diacritics 2', prefix='2 3');
            CREATE VIRTUAL TABLE IF NOT EXISTS ft_tri USING fts5(body, content='', contentless_delete=1,
                tokenize='trigram remove_diacritics 1');
            """)
        writer = Mutex(w)
        reader = Mutex(try Connection(url: url, write: false))
    }

    /// In-memory-like scratch index in a temporary file (tests, benchmarks).
    public static func temporary() throws -> FullTextIndex {
        try FullTextIndex(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("fts-\(UUID().uuidString).sqlite"))
    }

    // MARK: Writing

    /// Replaces each item's chunks of `kinds` (nil = all kinds; an empty list just deletes). One transaction for the
    /// whole batch.
    public func replace(_ batch: [(item: UInt32, kinds: Set<ContentMatch.Kind>?, chunks: [ExtractedChunk])]) throws {
        try writer.withLock { c in
            try c.db.transaction {
                for entry in batch {
                    try c.deleteItem(entry.item, kinds: entry.kinds)
                    for ch in entry.chunks { try c.insert(item: entry.item, ch) }
                }
            }
            c.reclaimFreePages()
        }
    }

    public func replace(item: UInt32, chunks: [ExtractedChunk]) throws {
        try replace([(item: item, kinds: nil, chunks: chunks)])
    }

    /// Adds chunks to an item without deleting its existing ones (e.g. OCR of scanned pages after the text layer).
    public func append(item: UInt32, chunks: [ExtractedChunk]) throws {
        try writer.withLock { c in
            try c.db.transaction { for ch in chunks { try c.insert(item: item, ch) } }
            c.reclaimFreePages()
        }
    }

    /// Deletes every chunk of `items`.
    public func remove(items: [UInt32]) throws {
        try writer.withLock { c in
            try c.db.transaction { for i in items { try c.deleteItem(i, kinds: nil) } }
            c.reclaimFreePages()
        }
    }

    /// The stored chunks of `item`, in insertion order (for embedding).
    public func chunks(item: UInt32) -> [ExtractedChunk] {
        reader.withLock { c in
            defer { c.resetAll() }
            guard
                let s = try? c.stmt(
                    "SELECT kind, page, line, time, rx, ry, rw, rh, body FROM ft_chunk WHERE item=? ORDER BY id")
            else { return [] }
            s.bind(1, Int64(item))
            var out: [ExtractedChunk] = []
            while s.step() {
                let kind = ContentMatch.Kind(rawValue: UInt8(s.int(0))) ?? .text
                out.append(ExtractedChunk(kind: kind, text: Self.decompress(s.blob(8)), location: s.location(from: 1)))
            }
            return out
        }
    }

    public var chunkCount: Int {
        reader.withLock { c in
            defer { c.resetAll() }
            guard let s = try? c.stmt("SELECT count(*) FROM ft_chunk"), s.step() else { return 0 }
            return Int(s.int(0))
        }
    }

    /// Bytes on disk (database + WAL).
    public var sizeOnDisk: Int64 {
        let fm = FileManager.default
        return [url.path, url.path + "-wal"].reduce(Int64(0)) {
            $0 + (((try? fm.attributesOfItem(atPath: $1))?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Merges FTS segments and checkpoints the WAL (after bulk loads).
    public func optimize() {
        writer.withLock { c in
            try? c.db.exec(
                "INSERT INTO ft_words(ft_words) VALUES('optimize'); INSERT INTO ft_tri(ft_tri) VALUES('optimize');")
            try? c.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    // MARK: Search

    public func search(_ q: String, limit: Int) -> [FullTextHit] {
        let query = q.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !query.isEmpty, limit > 0 else { return [] }
        let tokens = Self.tokens(query)
        let segmentless = query.unicodeScalars.contains(where: Self.needsTrigram)
        var rows: [Int64: Double] = [:]
        var order: [Int64] = []
        func add(_ found: [(Int64, Double)]) {
            for (id, score) in found where rows[id] == nil {
                rows[id] = score
                order.append(id)
            }
        }
        reader.withLock { c in
            defer { c.resetAll() }
            if segmentless {
                // Substring search: every whitespace-separated piece ≥ 3 characters as a trigram phrase.
                let pieces = query.split(separator: " ").filter { $0.count >= 3 }.map { Self.quote(String($0)) }
                if !pieces.isEmpty { add(c.match("ft_tri", pieces.joined(separator: " "), limit: limit)) }
            }
            guard !tokens.isEmpty else { return }
            let last = tokens.count - 1
            let prefixLast = tokens[last].count >= 2  // a 1-char prefix would scan the whole vocabulary
            let star = prefixLast ? "*" : ""
            if tokens.count > 1 {
                add(c.match("ft_words", Self.quote(tokens.joined(separator: " ")) + star, limit: limit))
            }
            let and = tokens.enumerated().map { i, t in Self.quote(t) + (i == last ? star : "") }.joined(separator: " ")
            add(c.match("ft_words", and, limit: limit))
        }
        guard !order.isEmpty else { return [] }
        let rowsByID = reader.withLock { c in
            defer { c.resetAll() }
            return c.rows(order)
        }
        var hits: [FullTextHit] = []
        hits.reserveCapacity(order.count)
        // Compiled once per query, not once per row (it was most of a multi-word query's time).
        let phrase = tokens.count > 1 ? Self.phrasePattern(tokens) : nil
        for id in order {
            guard let row = rowsByID[id] else { continue }
            hits.append(Self.hit(row, query: query, tokens: tokens, phrase: phrase, score: rows[id] ?? 0))
        }
        // Exact phrases first, then BM25 (stable).
        let ranked = hits.enumerated().sorted { a, b in
            if a.element.isExactPhrase != b.element.isExactPhrase { return a.element.isExactPhrase }
            if a.element.bm25 != b.element.bm25 { return a.element.bm25 > b.element.bm25 }
            return a.offset < b.offset
        }.map(\.element)
        return Array(ranked.prefix(limit))
    }

    // MARK: Helpers

    struct Row {
        var item: UInt32
        var kind: ContentMatch.Kind
        var location: ContentLocation
        var text: String
    }

    /// Word tokens as unicode61 sees them (letters, digits, marks; everything else separates).
    static func tokens(_ q: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for s in q.unicodeScalars {
            let p = s.properties
            if p.isAlphabetic || p.numericType != nil || p.generalCategory == .nonspacingMark || s == "_" {
                if s == "_" {
                    if !cur.isEmpty { out.append(String(cur)) }
                    cur = String.UnicodeScalarView()
                } else {
                    cur.append(s)
                }
            } else if !cur.isEmpty {
                out.append(String(cur))
                cur = String.UnicodeScalarView()
            }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out
    }

    static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    /// Scripts written without spaces between words (unicode61 would index whole runs as one token).
    static func needsTrigram(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0E00...0x0EFF,  // Thai, Lao
            0x1000...0x109F,  // Myanmar
            0x1780...0x17FF,  // Khmer
            0x2E80...0x9FFF,  // CJK radicals … unified ideographs, kana
            0xA960...0xA97F, 0xAC00...0xD7AF,  // Hangul
            0xF900...0xFAFF, 0xFF66...0xFF9F,
            0x20000...0x3FFFF:
            return true
        default: return false
        }
    }

    /// `pattern`: `phrasePattern(tokens)` for multi-word queries.
    static func hit(
        _ row: Row, query: String, tokens: [String], phrase pattern: NSRegularExpression?,
        score: Double
    ) -> FullTextHit {
        let text = row.text as NSString
        let opts: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var phrase = text.range(of: query, options: opts)
        if phrase.location == NSNotFound, let pattern {
            // Same words separated by punctuation/newlines ("INV-4471" for "inv 4471") still read as the phrase.
            phrase =
                pattern.firstMatch(in: row.text, range: NSRange(location: 0, length: text.length))?.range
                ?? NSRange(location: NSNotFound, length: 0)
        }
        let isExact = phrase.location != NSNotFound
        var ranges: [NSRange] = []
        if isExact {
            ranges.append(phrase)
        } else {
            for t in tokens {
                let r = wordStart(text, t, opts)
                if r.location != NSNotFound { ranges.append(r) }
            }
            if ranges.isEmpty {
                let r = text.range(of: query, options: opts)
                if r.location != NSNotFound { ranges.append(r) }
            }
        }
        ranges.sort { $0.location < $1.location }
        let anchor = ranges.first ?? NSRange(location: 0, length: 0)
        var start = max(0, anchor.location - snippetRadius)
        var end = min(text.length, anchor.location + anchor.length + snippetRadius * 2)
        // Snap to whitespace and keep surrogate pairs whole.
        if start > 0 {
            let ws = text.rangeOfCharacter(
                from: .whitespacesAndNewlines, options: [],
                range: NSRange(location: start, length: anchor.location - start))
            if ws.location != NSNotFound { start = ws.location + 1 }
        }
        if end < text.length {
            let ws = text.rangeOfCharacter(
                from: .whitespacesAndNewlines, options: .backwards,
                range: NSRange(
                    location: anchor.location + anchor.length,
                    length: end - anchor.location - anchor.length))
            if ws.location != NSNotFound { end = ws.location }
        }
        start = text.rangeOfComposedCharacterSequence(at: min(start, max(0, text.length - 1))).location
        if end < text.length { end = text.rangeOfComposedCharacterSequence(at: end).location }
        end = max(end, start)
        let lead = start > 0 ? "…" : ""
        let trail = end < text.length ? "…" : ""
        let body = text.substring(with: NSRange(location: start, length: end - start))
        // Collapse whitespace while mapping highlight offsets.
        // Whitespace runs collapse to one space; `map` takes body UTF-16 offsets to snippet offsets.
        var map: [Int] = []
        map.reserveCapacity(body.utf16.count + 1)
        var lastSpace = false
        var outLen = (lead as NSString).length
        for unit in body.utf16 {
            let isWS = unit == 10 || unit == 13 || unit == 9 || unit == 32
            map.append(outLen)
            if !isWS || !lastSpace { outLen += 1 }
            lastSpace = isWS
        }
        map.append(outLen)
        let snippet = lead + collapse(body) + trail
        var highlights: [Range<Int>] = []
        for r in ranges {
            let a = r.location - start, b = r.location + r.length - start
            guard a >= 0, b <= map.count - 1, a < b else { continue }
            let lo = map[a], hi = max(map[a] + 1, map[b - 1] + 1)
            if let prev = highlights.last, lo < prev.upperBound { continue }
            highlights.append(lo..<hi)
        }
        var location = row.location
        if location.line != nil {
            let before = text.substring(to: anchor.location)
            location.line! += before.utf16.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        }
        return FullTextHit(
            item: row.item, kind: row.kind, location: location, snippet: snippet,
            highlights: highlights, bm25: score, isExactPhrase: isExact)
    }

    /// Whitespace runs → one space (same lengths as the offset map in `hit`).
    static func collapse(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var lastSpace = false
        for u in s.unicodeScalars {
            if u == "\n" || u == "\r" || u == "\t" || u == " " {
                if !lastSpace { out.append(" ") }
                lastSpace = true
            } else {
                out.append(u)
                lastSpace = false
            }
        }
        return String(out)
    }

    /// First occurrence of `token` at a word start (falls back to anywhere).
    static func wordStart(_ text: NSString, _ token: String, _ opts: NSString.CompareOptions) -> NSRange {
        var search = NSRange(location: 0, length: text.length)
        var first = NSRange(location: NSNotFound, length: 0)
        while search.length > 0 {
            let r = text.range(of: token, options: opts, range: search)
            guard r.location != NSNotFound else { break }
            if first.location == NSNotFound { first = r }
            if r.location == 0 { return r }
            let prev = text.character(at: r.location - 1)
            if let s = Unicode.Scalar(prev), !(s.properties.isAlphabetic || s.properties.numericType != nil) {
                return r
            }
            let next = r.location + 1
            search = NSRange(location: next, length: text.length - next)
        }
        return first
    }

    /// The tokens in order, separated only by non-word characters.
    static func phrasePattern(_ tokens: [String]) -> NSRegularExpression? {
        let pattern = tokens.map { NSRegularExpression.escapedPattern(for: $0) }.joined(
            separator: "[^\\p{L}\\p{N}]{1,3}")
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // MARK: Compression

    /// 1 byte tag (0 raw, 1 LZFSE) + 4-byte length + payload.
    static func compress(_ s: String) -> [UInt8] {
        let src = Array(s.utf8)
        guard src.count >= 256 else { return [0] + src }
        var dst = [UInt8](repeating: 0, count: src.count + 64)
        let n = compression_encode_buffer(&dst, dst.count, src, src.count, nil, COMPRESSION_LZFSE)
        guard n > 0, n + 5 < src.count else { return [0] + src }
        let len = UInt32(src.count)
        return [1, UInt8(len & 0xFF), UInt8(len >> 8 & 0xFF), UInt8(len >> 16 & 0xFF), UInt8(len >> 24)] + dst[0..<n]
    }

    static func decompress(_ b: UnsafeRawBufferPointer) -> String {
        guard let tag = b.first else { return "" }
        if tag == 0 { return String(decoding: b.dropFirst(), as: UTF8.self) }
        guard b.count > 5 else { return "" }
        let len = Int(b[1]) | Int(b[2]) << 8 | Int(b[3]) << 16 | Int(b[4]) << 24
        var dst = [UInt8](repeating: 0, count: len)
        let payload = UnsafeRawBufferPointer(rebasing: b[5...])
        let n = compression_decode_buffer(
            &dst, len, payload.bindMemory(to: UInt8.self).baseAddress!, payload.count,
            nil, COMPRESSION_LZFSE)
        return String(decoding: dst[0..<n], as: UTF8.self)
    }

    // MARK: Connection

    /// One sqlite connection with cached raw statements (blob binding, which `Statement` doesn't offer).
    final class Connection {
        let db: SQLiteDB
        private var cache: [String: Raw] = [:]

        init(url: URL, write: Bool) throws {
            db = try SQLiteDB(url: url)
            if !write { try db.exec("PRAGMA query_only=1") }
        }

        /// Resets every cached statement so none keeps a read snapshot open (WAL readers would miss new commits).
        func resetAll() {
            for s in cache.values { sqlite3_reset(s.p) }
        }

        func stmt(_ sql: String) throws -> Raw {
            if let s = cache[sql] {
                s.reset()
                return s
            }
            var p: OpaquePointer?
            let rc = sqlite3_prepare_v3(db.handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &p, nil)
            guard rc == SQLITE_OK, let p else { throw db.error(rc) }
            let s = Raw(p)
            cache[sql] = s
            return s
        }

        func insert(item: UInt32, _ ch: ExtractedChunk) throws {
            let text = ch.text
            guard !text.isEmpty else { return }
            let cjk = text.unicodeScalars.contains(where: FullTextIndex.needsTrigram)
            let s = try stmt(
                """
                INSERT INTO ft_chunk(item, kind, page, line, time, rx, ry, rw, rh, cjk, body)
                VALUES(?,?,?,?,?,?,?,?,?,?,?)
                """)
            s.bind(1, Int64(item))
            s.bind(2, Int64(ch.kind.rawValue))
            s.bind(3, ch.location.page.map(Int64.init))
            s.bind(4, ch.location.line.map(Int64.init))
            s.bind(5, ch.location.time)
            s.bind(6, ch.location.region?.x)
            s.bind(7, ch.location.region?.y)
            s.bind(8, ch.location.region?.width)
            s.bind(9, ch.location.region?.height)
            s.bind(10, Int64(cjk ? 1 : 0))
            s.bind(11, blob: FullTextIndex.compress(text))
            try s.run(db)
            let rowid = sqlite3_last_insert_rowid(db.handle)
            let w = try stmt("INSERT INTO ft_words(rowid, body) VALUES(?, ?)")
            w.bind(1, rowid)
            w.bind(2, text)
            try w.run(db)
            if cjk {
                let t = try stmt("INSERT INTO ft_tri(rowid, body) VALUES(?, ?)")
                t.bind(1, rowid)
                t.bind(2, text)
                try t.run(db)
            }
        }

        func pragma(_ name: String) -> Int64 {
            defer { resetAll() }
            guard let s = try? stmt("PRAGMA \(name)"), s.step() else { return 0 }
            return s.int(0)
        }

        /// Returns the pages freed by deletes and FTS segment merges to the file system after a write, so the store
        /// never keeps the high-water mark of its churn (v4 s15: content.sqlite ≤ the text it indexes). Stores are
        /// incremental auto-vacuum (set before the first table); a store made before that is converted once by one
        /// VACUUM when a sixteenth of it is free (~4 s per GB, readers keep reading the WAL snapshot).
        func reclaimFreePages() {
            let free = pragma("freelist_count")
            guard free > 256 else { return }
            if pragma("auto_vacuum") == 2 {
                try? db.exec("PRAGMA incremental_vacuum")
            } else if free * 16 > pragma("page_count") {
                try? db.exec("PRAGMA auto_vacuum=INCREMENTAL; VACUUM; PRAGMA wal_checkpoint(TRUNCATE)")
            }
        }

        func deleteItem(_ item: UInt32, kinds: Set<ContentMatch.Kind>?) throws {
            let sel = try stmt("SELECT id, cjk, kind FROM ft_chunk WHERE item=?")
            sel.bind(1, Int64(item))
            var ids: [(Int64, Bool)] = []
            var all = true
            while sel.step() {
                if let kinds, let k = ContentMatch.Kind(rawValue: UInt8(sel.int(2))), !kinds.contains(k) {
                    all = false
                    continue
                }
                ids.append((sel.int(0), sel.int(1) != 0))
            }
            guard !ids.isEmpty else { return }
            let dw = try stmt("DELETE FROM ft_words WHERE rowid=?")
            let dt = try stmt("DELETE FROM ft_tri WHERE rowid=?")
            for (id, cjk) in ids {
                dw.reset()
                dw.bind(1, id)
                try dw.run(db)
                if cjk {
                    dt.reset()
                    dt.bind(1, id)
                    try dt.run(db)
                }
            }
            if all {
                let d = try stmt("DELETE FROM ft_chunk WHERE item=?")
                d.bind(1, Int64(item))
                try d.run(db)
            } else {
                let d = try stmt("DELETE FROM ft_chunk WHERE id=?")
                for (id, _) in ids {
                    d.reset()
                    d.bind(1, id)
                    try d.run(db)
                }
            }
        }

        /// rowid + relevance (−bm25, higher is better), best first, ranked within the first `rankWindow` matches.
        ///
        /// `ORDER BY rank` scores and sorts every match: a common word or a 2-letter prefix matches most of 200k chunks
        /// and took ~190 ms p95. Without it FTS5 streams the doclist and stops at the LIMIT, scoring only the rows it
        /// returns (spec M.vi: rank with bm25 over the top 200 only). Queries with fewer matches are ranked exactly.
        func match(_ table: String, _ expr: String, limit: Int) -> [(Int64, Double)] {
            guard let s = try? stmt("SELECT rowid, -bm25(\(table)) FROM \(table) WHERE \(table) MATCH ? LIMIT ?")
            else { return [] }
            s.bind(1, expr)
            s.bind(2, Int64(max(limit, FullTextIndex.rankWindow)))
            var out: [(Int64, Double)] = []
            while s.step() { out.append((s.int(0), s.double(1))) }
            out.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            return Array(out.prefix(limit))
        }

        func rows(_ ids: [Int64]) -> [Int64: Row] {
            guard
                let s = try? stmt("SELECT item, kind, page, line, time, rx, ry, rw, rh, body FROM ft_chunk WHERE id=?")
            else { return [:] }
            var out: [Int64: Row] = [:]
            for id in ids {
                s.reset()
                s.bind(1, id)
                guard s.step() else { continue }
                let kind = ContentMatch.Kind(rawValue: UInt8(s.int(1))) ?? .text
                out[id] = Row(
                    item: UInt32(truncatingIfNeeded: s.int(0)), kind: kind, location: s.location(from: 2),
                    text: FullTextIndex.decompress(s.blob(9)))
            }
            return out
        }
    }

    /// A raw prepared statement. Not thread-safe; owned by one `Connection`.
    final class Raw {
        let p: OpaquePointer
        init(_ p: OpaquePointer) { self.p = p }
        deinit { sqlite3_finalize(p) }

        func reset() {
            sqlite3_reset(p)
            sqlite3_clear_bindings(p)
        }

        func bind(_ i: Int32, _ v: Int64?) {
            if let v { sqlite3_bind_int64(p, i, v) } else { sqlite3_bind_null(p, i) }
        }

        func bind(_ i: Int32, _ v: Double?) {
            if let v { sqlite3_bind_double(p, i, v) } else { sqlite3_bind_null(p, i) }
        }

        func bind(_ i: Int32, _ v: String) {
            sqlite3_bind_text(p, i, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

        func bind(_ i: Int32, blob: [UInt8]) {
            blob.withUnsafeBytes {
                _ = sqlite3_bind_blob(
                    p, i, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }

        func step() -> Bool { sqlite3_step(p) == SQLITE_ROW }

        func run(_ db: SQLiteDB) throws {
            let rc = sqlite3_step(p)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw db.error(rc) }
        }

        func int(_ c: Int32) -> Int64 { sqlite3_column_int64(p, c) }
        func double(_ c: Int32) -> Double { sqlite3_column_double(p, c) }
        func isNull(_ c: Int32) -> Bool { sqlite3_column_type(p, c) == SQLITE_NULL }

        func blob(_ c: Int32) -> UnsafeRawBufferPointer {
            let n = Int(sqlite3_column_bytes(p, c))
            guard n > 0, let b = sqlite3_column_blob(p, c) else { return UnsafeRawBufferPointer(start: nil, count: 0) }
            return UnsafeRawBufferPointer(start: b, count: n)
        }

        /// page, line, time, rx, ry, rw, rh starting at column `c`.
        func location(from c: Int32) -> ContentLocation {
            var loc = ContentLocation()
            if !isNull(c) { loc.page = Int(int(c)) }
            if !isNull(c + 1) { loc.line = Int(int(c + 1)) }
            if !isNull(c + 2) { loc.time = double(c + 2) }
            if !isNull(c + 3) {
                loc.region = ContentRegion(
                    x: double(c + 3), y: double(c + 4), width: double(c + 5), height: double(c + 6))
            }
            return loc
        }
    }
}
