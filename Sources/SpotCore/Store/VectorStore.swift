import Accelerate
import Foundation

/// Persistent dense vector store (owner: engine).
///
/// Vectors live row-major as Float16 in a memory-mapped file `vectors.f16` (no header; row r starts at r·dim·2).
/// Rows are keyed by `ChunkID` (`item << 24 | chunk`), so a file can own many vectors (its name + content chunks).
/// The chunk id → row map is the `vector_rows` table in `index.sqlite`; content chunks also have a `chunks` row
/// (kind, location, text offset, snippet). Opening = mmap + one SQL scan, no parsing.
/// Delete is swap-remove (the last row moves into the hole). Search converts blocks of rows to Float32 with vImage,
/// scores them with one vDSP matrix-vector product per block and keeps the top k in a min-heap.
/// Scores are dot products; store L2-normalized vectors so they are cosine similarities.
public actor VectorStore: VectorIndex {
    public let dimension: Int
    /// True when the stored vectors were discarded on open (new store, other dimension, old key format or a broken
    /// map). Callers should then mark every catalog item as needing a vector again.
    public nonisolated let didReset: Bool

    private let db: SQLiteDB
    private let file: MappedRows
    private let insertRow: Statement
    private let moveRow: Statement
    private let deleteRow: Statement
    private let itemRows: Statement
    private let insertChunk: Statement
    private let deleteChunks: Statement
    private let getChunk: Statement
    private var ids: [ChunkID] = []           // row → chunk id
    private var rows: [ChunkID: Int] = [:]    // chunk id → row
    /// The last persistence error swallowed by the non-throwing `VectorIndex` methods.
    public private(set) var lastError: Error?

    private static let blockRows = 2048
    /// Bumped when the meaning of `vector_rows.id` changes.
    private static let keyFormat = "chunk64"

    public init(directory: URL = Paths.appSupport, dimension: Int = 256) throws {
        guard dimension > 0 else { throw SQLiteError(code: -1, message: "vector dimension must be positive") }
        self.dimension = dimension
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try SQLiteDB(url: directory.appendingPathComponent("index.sqlite"))
        try db.exec("""
            CREATE TABLE IF NOT EXISTS vector_rows(id INTEGER PRIMARY KEY, row INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS chunks(
                id INTEGER PRIMARY KEY, kind INTEGER NOT NULL,
                page INTEGER, line INTEGER, time REAL, rx REAL, ry REAL, rw REAL, rh REAL,
                text_offset INTEGER, snippet TEXT);
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            """)
        self.db = db
        file = try MappedRows(url: directory.appendingPathComponent("vectors.f16"), rowBytes: dimension * 2)
        insertRow = try db.prepare("INSERT OR REPLACE INTO vector_rows(id, row) VALUES(?, ?)")
        moveRow = try db.prepare("UPDATE vector_rows SET row = ? WHERE id = ?")
        deleteRow = try db.prepare("DELETE FROM vector_rows WHERE id = ?")
        itemRows = try db.prepare("SELECT id FROM vector_rows WHERE id BETWEEN ? AND ?")
        insertChunk = try db.prepare("""
            INSERT OR REPLACE INTO chunks(id, kind, page, line, time, rx, ry, rw, rh, text_offset, snippet)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        deleteChunks = try db.prepare("DELETE FROM chunks WHERE id BETWEEN ? AND ?")
        getChunk = try db.prepare(
            "SELECT kind, page, line, time, rx, ry, rw, rh, text_offset, snippet FROM chunks WHERE id = ?")

        // Format check: a different dimension or key format invalidates everything stored.
        let getMeta = try db.prepare("SELECT value FROM meta WHERE key = ?")
        let storedDim = try getMeta.bind(["vector_dim"]).step() ? getMeta.string(0).flatMap { Int($0) } : nil
        try getMeta.run()
        let storedKeys = try getMeta.bind(["vector_keys"]).step() ? getMeta.string(0) : nil
        try getMeta.run()

        var loaded: [ChunkID] = []
        var map: [ChunkID: Int] = [:]
        var consistent = storedDim == dimension && storedKeys == Self.keyFormat
        if consistent {
            let count = try db.prepare("SELECT count(*) FROM vector_rows")
            let n = try count.bind([]).step() ? Int(count.int64(0)) : 0
            try count.run()
            if n > file.capacity { consistent = false }
            if consistent && n > 0 {
                loaded = [ChunkID](repeating: 0, count: n)
                var seen = [Bool](repeating: false, count: n)
                map.reserveCapacity(n)
                let scan = try db.prepare("SELECT id, row FROM vector_rows")
                try scan.bind([])
                while try scan.step() {
                    let id = ChunkID(bitPattern: scan.int64(0))
                    let row = Int(scan.int64(1))
                    guard row >= 0, row < n, !seen[row] else { consistent = false; break }
                    seen[row] = true
                    loaded[row] = id
                    map[id] = row
                }
                try? scan.run()
            }
        }
        if !consistent {
            // Unknown or broken state: start empty rather than serve wrong vectors.
            try db.transaction {
                try db.exec("DELETE FROM vector_rows; DELETE FROM chunks;")
                let setMeta = try db.prepare("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)")
                try setMeta.bind(["vector_dim", String(dimension)]).run()
                try setMeta.bind(["vector_keys", Self.keyFormat]).run()
            }
            loaded = []
            map = [:]
        }
        didReset = !consistent
        ids = loaded
        rows = map
    }

    /// Number of stored vectors (all chunks).
    public var count: Int { ids.count }

    public func contains(_ id: ChunkID) -> Bool { rows[id] != nil }

    /// True when any chunk of `item` has a vector.
    public func containsItem(_ item: UInt32) -> Bool {
        (try? chunkIDs(of: item).isEmpty == false) ?? false
    }

    /// The stored (Float16-rounded) vector for `id`.
    public func vector(_ id: ChunkID) -> [Float]? {
        guard let row = rows[id] else { return nil }
        let p = file.row(row, dimension: dimension)
        return (0..<dimension).map { Float(p[$0]) }
    }

    // MARK: VectorIndex

    public func upsert(_ id: ChunkID, _ v: [Float]) async {
        do { try upsert([(id, v)]) } catch { lastError = error }
    }

    public func remove(_ id: ChunkID) async {
        do { try remove([id]) } catch { lastError = error }
    }

    public func search(_ q: [Float], k: Int) async -> [(id: ChunkID, score: Float)] {
        topK(q, k: k)
    }

    public func removeItem(_ item: UInt32) async {
        do { try removeItems([item]) } catch { lastError = error }
    }

    public func upsertChunks(_ chunks: [(info: ChunkInfo, vector: [Float])]) async {
        do { try upsert(chunks: chunks) } catch { lastError = error }
    }

    public func storedVector(_ id: ChunkID) async -> [Float]? { vector(id) }

    public func chunkInfo(_ ids: [ChunkID]) async -> [ChunkID: ChunkInfo] {
        var out: [ChunkID: ChunkInfo] = [:]
        for id in ids where Chunk.index(id) != 0 && out[id] == nil {
            do {
                let st = try getChunk.bind([id])
                defer { _ = try? st.run() }
                guard try st.step() else { continue }
                func int(_ c: Int32) -> Int? { st.isNull(c) ? nil : Int(st.int64(c)) }
                func dbl(_ c: Int32) -> Double? { st.isNull(c) ? nil : st.double(c) }
                var region: ContentRegion?
                if let x = dbl(4), let y = dbl(5), let w = dbl(6), let h = dbl(7) {
                    region = ContentRegion(x: x, y: y, width: w, height: h)
                }
                out[id] = ChunkInfo(
                    id: id,
                    kind: ContentMatch.Kind(rawValue: UInt8(truncatingIfNeeded: st.int64(0))) ?? .semantic,
                    location: ContentLocation(page: int(1), line: int(2), time: dbl(3), region: region),
                    textOffset: int(8), snippet: st.string(9))
            } catch {
                lastError = error
            }
        }
        return out
    }

    // MARK: Batch API

    /// Inserts or overwrites vectors in one transaction. Vectors whose length isn't `dimension` are skipped.
    public func upsert(_ batch: [(id: ChunkID, vector: [Float])]) throws {
        try upsert(batch, infos: [])
    }

    /// Content chunks: vectors plus their `chunks` rows, in one transaction.
    public func upsert(chunks: [(info: ChunkInfo, vector: [Float])]) throws {
        let valid = chunks.filter { $0.vector.count == dimension }
        try upsert(valid.map { ($0.info.id, $0.vector) }, infos: valid.map(\.info))
    }

    private func upsert(_ batch: [(id: ChunkID, vector: [Float])], infos: [ChunkInfo]) throws {
        let valid = batch.filter { $0.vector.count == dimension }
        guard !valid.isEmpty else { return }
        let newRows = valid.reduce(into: Set<ChunkID>()) { if rows[$1.id] == nil { $0.insert($1.id) } }.count
        try file.ensureCapacity(ids.count + newRows)
        let snapshot = (ids, rows)
        do {
            try db.transaction {
                for (id, vector) in valid {
                    let row: Int
                    if let existing = rows[id] {
                        row = existing
                    } else {
                        row = ids.count
                        ids.append(id)
                        rows[id] = row
                        try insertRow.bind([id, row]).run()
                    }
                    let dst = file.row(row, dimension: dimension)
                    vector.withUnsafeBufferPointer { src in
                        for i in 0..<dimension { dst[i] = Float16(src[i]) }
                    }
                }
                for info in infos {
                    let l = info.location, r = l.region
                    try insertChunk.bind([info.id, info.kind.rawValue, l.page, l.line, l.time,
                                          r?.x, r?.y, r?.width, r?.height, info.textOffset, info.snippet]).run()
                }
            }
        } catch {
            (ids, rows) = snapshot
            throw error
        }
    }

    /// Swap-removes `ids` (and their chunk rows) in one transaction. Unknown ids are ignored.
    public func remove(_ batch: [ChunkID]) throws {
        let snapshot = (ids, rows)
        var moves: [(from: Int, to: Int)] = []
        do {
            try db.transaction {
                for id in batch {
                    try deleteChunks.bind([id, id]).run()
                    guard let row = rows.removeValue(forKey: id) else { continue }
                    try deleteRow.bind([id]).run()
                    let last = ids.count - 1
                    if row != last {
                        let moved = ids[last]
                        ids[row] = moved
                        rows[moved] = row
                        moves.append((last, row))
                        try moveRow.bind([row, moved]).run()
                    }
                    ids.removeLast()
                }
            }
        } catch {
            (ids, rows) = snapshot
            throw error
        }
        // Copy rows only after the map committed; replaying in order reproduces each swap.
        for move in moves {
            file.row(move.to, dimension: dimension).update(from: file.row(move.from, dimension: dimension),
                                                          count: dimension)
        }
    }

    /// Removes every chunk of each item.
    public func removeItems(_ items: [UInt32]) throws {
        var doomed: [ChunkID] = []
        for item in items {
            doomed += try chunkIDs(of: item)
            let r = Chunk.range(item: item)
            try deleteChunks.bind([r.lowerBound, r.upperBound]).run()
        }
        try remove(doomed)
    }

    private func chunkIDs(of item: UInt32) throws -> [ChunkID] {
        let r = Chunk.range(item: item)
        let st = try itemRows.bind([r.lowerBound, r.upperBound])
        var out: [ChunkID] = []
        while try st.step() { out.append(ChunkID(bitPattern: st.int64(0))) }
        return out
    }

    /// Flushes the mapped vectors to disk (the OS does this lazily otherwise).
    public func flush() {
        file.sync()
    }

    /// Drops this process's resident copy of the vector pages (flush + remap). They stay in the OS file cache, so
    /// the next search faults them back cheaply. Called when the backend goes idle.
    public func releaseResidentPages() {
        do { try file.remap() } catch { lastError = error }
    }

    // MARK: Search

    /// Exact top-k by dot product, highest first.
    public func topK(_ q: [Float], k: Int) -> [(id: ChunkID, score: Float)] {
        let n = ids.count
        guard n > 0, k > 0, q.count == dimension else { return [] }
        let d = dimension
        let kk = min(k, n)
        var heap = TopKHeap(capacity: kk)
        let block = Self.blockRows
        var floats = [Float](repeating: 0, count: block * d)
        var scores = [Float](repeating: 0, count: block)
        q.withUnsafeBufferPointer { qp in
            floats.withUnsafeMutableBufferPointer { fp in
                scores.withUnsafeMutableBufferPointer { sp in
                    var start = 0
                    while start < n {
                        let count = min(block, n - start)
                        var src = vImage_Buffer(data: UnsafeMutableRawPointer(file.row(start, dimension: d)),
                                                height: 1, width: vImagePixelCount(count * d),
                                                rowBytes: count * d * 2)
                        var dst = vImage_Buffer(data: UnsafeMutableRawPointer(fp.baseAddress!),
                                                height: 1, width: vImagePixelCount(count * d),
                                                rowBytes: count * d * 4)
                        vImageConvert_Planar16FtoPlanarF(&src, &dst, vImage_Flags(kvImageNoFlags))
                        // scores[count×1] = floats[count×d] · q[d×1]
                        vDSP_mmul(fp.baseAddress!, 1, qp.baseAddress!, 1, sp.baseAddress!, 1,
                                  vDSP_Length(count), 1, vDSP_Length(d))
                        for i in 0..<count { heap.offer(sp[i], Int32(start + i)) }
                        start += count
                    }
                }
            }
        }
        return heap.sortedDescending().map { (ids[Int($0.row)], $0.score) }
    }
}

/// Fixed-size min-heap keeping the k largest scores.
struct TopKHeap {
    private(set) var items: [(score: Float, row: Int32)] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        items.reserveCapacity(capacity)
    }

    @inline(__always)
    mutating func offer(_ score: Float, _ row: Int32) {
        if items.count < capacity {
            items.append((score, row))
            siftUp(items.count - 1)
        } else if score > items[0].score {
            items[0] = (score, row)
            siftDown(0)
        }
    }

    func sortedDescending() -> [(score: Float, row: Int32)] {
        items.sorted { $0.score > $1.score || ($0.score == $1.score && $0.row < $1.row) }
    }

    private mutating func siftUp(_ i: Int) {
        var c = i
        while c > 0 {
            let p = (c - 1) / 2
            guard items[c].score < items[p].score else { return }
            items.swapAt(c, p)
            c = p
        }
    }

    private mutating func siftDown(_ i: Int) {
        var p = i
        let n = items.count
        while true {
            let l = 2 * p + 1, r = l + 1
            var m = p
            if l < n && items[l].score < items[m].score { m = l }
            if r < n && items[r].score < items[m].score { m = r }
            if m == p { return }
            items.swapAt(p, m)
            p = m
        }
    }
}

/// A growable, memory-mapped file of fixed-size rows.
final class MappedRows {
    private let fd: Int32
    private let rowBytes: Int
    private var base: UnsafeMutableRawPointer?
    private(set) var capacity: Int = 0   // rows
    private static let minRows = 1024

    init(url: URL, rowBytes: Int) throws {
        self.rowBytes = rowBytes
        fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let existing = Int(st.st_size) / rowBytes
        do {
            try map(rows: max(existing, Self.minRows))
        } catch {
            close(fd)
            throw error
        }
    }

    deinit {
        if let base { munmap(base, capacity * rowBytes) }
        close(fd)
    }

    func row(_ r: Int, dimension: Int) -> UnsafeMutablePointer<Float16> {
        (base! + r * rowBytes).assumingMemoryBound(to: Float16.self)
    }

    func ensureCapacity(_ rows: Int) throws {
        guard rows > capacity else { return }
        var target = max(capacity, Self.minRows)
        while target < rows { target *= 2 }
        try map(rows: target)
    }

    func sync() {
        if let base { msync(base, capacity * rowBytes, MS_ASYNC) }
    }

    /// Writes dirty pages back synchronously and maps the file afresh (resident set of the mapping → 0).
    func remap() throws {
        guard let base else { return }
        msync(base, capacity * rowBytes, MS_SYNC)
        let rows = capacity
        munmap(base, rows * rowBytes)
        self.base = nil
        capacity = 0
        try map(rows: rows)
    }

    private func map(rows: Int) throws {
        let bytes = rows * rowBytes
        var st = stat()
        if fstat(fd, &st) == 0, Int(st.st_size) < bytes {
            guard ftruncate(fd, off_t(bytes)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let p = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let p, p != MAP_FAILED else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOMEM) }
        if let base { munmap(base, capacity * rowBytes) }
        base = p
        madvise(p, bytes, MADV_RANDOM)
        capacity = rows
    }
}
