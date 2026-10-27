import Foundation
import Synchronization

/// id → Item catalog backed by SQLite at `Paths.appSupport/index.sqlite` (owner: engine).
///
/// Tables: `items` (the entries, with `embedded` = 1 once a vector exists for the current name/mtime/hash),
/// `meta` (key/value, e.g. the FSEvents last event id and `IndexSettings`), `opens` (per-path open count, last open
/// and decayed frecency for ranking + Recents) and `pins` (Favorites, by path, in user order).
/// Writes run one transaction per batch. `item(_:)` and `count` read an in-memory mirror, so search never waits on SQL.
public final class Catalog: Sendable {
    private struct DB {
        let db: SQLiteDB
        let upsert: Statement
        let remove: Statement
        let markEmbedded: Statement
        let pending: Statement
        let all: Statement
        let getMeta: Statement
        let setMeta: Statement
        let getOpen: Statement
        let putOpen: Statement
        let deleteOpen: Statement
        let opens: Statement
        let recentOpens: Statement
        let itemByPath: Statement
        let pins: Statement
        let addPin: Statement
        let deletePin: Statement
        let setPinPosition: Statement
        let pendingCount: Statement
        // v3
        let byPathFull: Statement
        let byIdentity: Statement
        let insertFull: Statement
        let updateFull: Statement
        let moveRow: Statement
        let underRange: Statement
        let deleteRange: Statement
        let nameVecHash: Statement
        let markEmbeddedHash: Statement
    }

    /// Schema version written by this build (`PRAGMA user_version`).
    public static let schemaVersion = 3
    /// Rows of `items` inserted/updated/deleted by this process (bench + tests: "rows written").
    public let itemRowsWritten = Atomic<Int>(0)

    public static var defaultURL: URL { Paths.appSupport.appendingPathComponent("index.sqlite") }

    private let state: Mutex<DB>
    private let cache: Mutex<CatalogMirror>

    public init(url: URL = Catalog.defaultURL) throws {
        let db = try SQLiteDB(url: url)
        // No mmap: the launch scan into the in-memory mirror would leave the whole file resident (~60 MiB of
        // clean pages per 200k items, counted in RSS); later reads are point lookups served by the page cache.
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS items(
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL,
                kind INTEGER NOT NULL,
                modified REAL NOT NULL,
                content_hash TEXT,
                embedded INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS items_pending ON items(embedded) WHERE embedded = 0;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS opens(path TEXT PRIMARY KEY, count INTEGER NOT NULL, last REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS pins(path TEXT PRIMARY KEY, position INTEGER NOT NULL);
            """)
        // v1 catalogs have no frecency column: add it and seed it with the raw count (decayed from `last`).
        let hasFrecency = try db.prepare("SELECT count(*) FROM pragma_table_info('opens') WHERE name = 'frecency'")
        let migrated = try hasFrecency.bind([]).step() && hasFrecency.int64(0) > 0
        try hasFrecency.run()
        if !migrated {
            try db.exec(
                """
                ALTER TABLE opens ADD COLUMN frecency REAL NOT NULL DEFAULT 0;
                UPDATE opens SET frecency = count;
                """)
        }
        try Self.migrate(db)
        let s = DB(
            db: db,
            upsert: try db.prepare(
                """
                INSERT INTO items(path, name, kind, modified, content_hash, embedded) VALUES(?1, ?2, ?3, ?4, ?5, 0)
                ON CONFLICT(path) DO UPDATE SET
                    name = excluded.name, kind = excluded.kind, modified = excluded.modified,
                    content_hash = excluded.content_hash,
                    embedded = CASE WHEN items.name = excluded.name AND items.modified = excluded.modified
                                     AND items.content_hash IS excluded.content_hash
                                    THEN items.embedded ELSE 0 END
                RETURNING id
                """),
            remove: try db.prepare("DELETE FROM items WHERE path = ? RETURNING id"),
            markEmbedded: try db.prepare("UPDATE items SET embedded = 1 WHERE id = ?"),
            pending: try db.prepare(
                "SELECT id, path, name, kind, modified FROM items WHERE embedded = 0 ORDER BY id LIMIT ?"),
            all: try db.prepare("SELECT id, path, name, kind, modified FROM items"),
            getMeta: try db.prepare("SELECT value FROM meta WHERE key = ?"),
            setMeta: try db.prepare("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)"),
            getOpen: try db.prepare("SELECT count, last, frecency FROM opens WHERE path = ?"),
            putOpen: try db.prepare("INSERT OR REPLACE INTO opens(path, count, last, frecency) VALUES(?, ?, ?, ?)"),
            deleteOpen: try db.prepare("DELETE FROM opens WHERE path = ?"),
            opens: try db.prepare("SELECT path, count, last, frecency FROM opens"),
            recentOpens: try db.prepare("SELECT path FROM opens ORDER BY last DESC"),
            itemByPath: try db.prepare("SELECT id, path, name, kind, modified FROM items WHERE path = ?"),
            pins: try db.prepare("SELECT path FROM pins ORDER BY position, path"),
            addPin: try db.prepare(
                """
                INSERT OR IGNORE INTO pins(path, position) VALUES(?1, (SELECT COALESCE(MAX(position), -1) + 1 FROM pins))
                """),
            deletePin: try db.prepare("DELETE FROM pins WHERE path = ?"),
            setPinPosition: try db.prepare("UPDATE pins SET position = ? WHERE path = ?"),
            pendingCount: try db.prepare("SELECT count(*) FROM items WHERE embedded = 0"),
            byPathFull: try db.prepare(
                """
                SELECT id, name, kind, modified, dev, file_id, size, mtime_ns, ctime_ns, flags FROM items WHERE path = ?
                """),
            byIdentity: try db.prepare(
                """
                SELECT id, path, kind, modified FROM items WHERE dev = ? AND file_id = ?
                """),
            insertFull: try db.prepare(
                """
                INSERT INTO items(path, name, kind, modified, embedded, dev, file_id, doc_id, clone_id, size, ctime_ns,
                                  mtime_ns, flags)
                VALUES(?1, ?2, ?3, ?4, 0, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12) RETURNING id
                """),
            updateFull: try db.prepare(
                """
                UPDATE items SET name = ?2, kind = ?3, modified = ?4, dev = ?5, file_id = ?6, doc_id = ?7, clone_id = ?8,
                    size = ?9, ctime_ns = ?10, mtime_ns = ?11, flags = ?12,
                    embedded = CASE WHEN ?13 THEN embedded ELSE 0 END
                WHERE id = ?1
                """),
            moveRow: try db.prepare(
                """
                UPDATE items SET path = ?2, name = ?3, kind = ?4, modified = ?5, doc_id = ?6, clone_id = ?7, size = ?8,
                    ctime_ns = ?9, mtime_ns = ?10, flags = ?11,
                    embedded = 0
                WHERE id = ?1
                """),
            underRange: try db.prepare(
                """
                SELECT id, path, name, kind, modified FROM items
                WHERE path = ?1 OR (path >= ?1 || '/' AND path < ?1 || '0')
                """),
            deleteRange: try db.prepare(
                """
                DELETE FROM items WHERE path = ?1 OR (path >= ?1 || '/' AND path < ?1 || '0') RETURNING id
                """),
            nameVecHash: try db.prepare("SELECT name_vec_hash FROM items WHERE id = ?"),
            markEmbeddedHash: try db.prepare("UPDATE items SET embedded = 1, name_vec_hash = ?2 WHERE id = ?1")
        )
        var mirror = CatalogMirror()
        let countAll = try db.prepare("SELECT count(*) FROM items")
        if try countAll.bind([]).step() { mirror.reserve(Int(countAll.int64(0))) }
        try countAll.run()
        try Self.forEachItem(s.all.bind([])) { mirror.insert($0) }
        state = Mutex(s)
        cache = Mutex(mirror)
    }

    // MARK: Reads (in-memory mirror)

    public func item(_ id: UInt32) -> Item? {
        cache.withLock { $0.item(id) }
    }

    public var count: Int {
        cache.withLock { $0.count }
    }

    /// Every item, from the in-memory mirror (a snapshot; no SQL, no up-front array).
    public var items: CatalogItems {
        CatalogItems(mirror: cache.withLock { $0 })
    }

    // MARK: Items

    /// Inserts or updates `items` by path in one transaction and returns them with their catalog ids
    /// (the incoming `id` is ignored; an existing path keeps its id). A changed name, mtime or content hash
    /// clears `embedded`. `contentHashes`, when given, is parallel to `items`.
    @discardableResult
    public func upsert(_ items: [Item], contentHashes: [String?]? = nil) throws -> [Item] {
        guard !items.isEmpty else { return [] }
        let stored: [Item] = try state.withLock { s in
            try s.db.transaction {
                var out: [Item] = []
                out.reserveCapacity(items.count)
                for (i, item) in items.enumerated() {
                    let hash = contentHashes.flatMap { i < $0.count ? $0[i] : nil }
                    let st = try s.upsert.bind([
                        item.path, item.name, item.kind.rawValue,
                        item.modified.timeIntervalSince1970, hash,
                    ])
                    guard try st.step() else { throw SQLiteError(code: -1, message: "upsert returned no id") }
                    var copy = item
                    copy.id = UInt32(truncatingIfNeeded: st.int64(0))
                    try st.run()
                    out.append(copy)
                }
                return out
            }
        }
        itemRowsWritten.add(stored.count, ordering: .relaxed)
        cache.withLock { mirror in
            for item in stored { mirror.insert(item) }
        }
        return stored
    }

    /// Deletes `paths` in one transaction; returns the ids that existed (drop their vectors too).
    @discardableResult
    public func remove(paths: [String]) throws -> [UInt32] {
        guard !paths.isEmpty else { return [] }
        let ids: [UInt32] = try state.withLock { s in
            try s.db.transaction {
                var out: [UInt32] = []
                for path in paths {
                    let st = try s.remove.bind([path])
                    while try st.step() { out.append(UInt32(truncatingIfNeeded: st.int64(0))) }
                }
                return out
            }
        }
        itemRowsWritten.add(ids.count, ordering: .relaxed)
        cache.withLock { mirror in
            for id in ids { mirror.remove(id) }
        }
        return ids
    }

    /// Every item, straight from SQLite (one scan, no per-row allocation beyond the Item).
    public func all() throws -> [Item] {
        try state.withLock { s in try Self.readItems(s.all.bind([])) }
    }

    /// Marks `ids` as having a current vector.
    public func markEmbedded(_ ids: [UInt32]) throws {
        guard !ids.isEmpty else { return }
        try state.withLock { s in
            try s.db.transaction {
                for id in ids { try s.markEmbedded.bind([id]).run() }
            }
        }
    }

    /// Up to `limit` items that still need a vector, oldest id first.
    public func pendingEmbedding(limit: Int) throws -> [Item] {
        try state.withLock { s in try Self.readItems(s.pending.bind([max(0, limit)])) }
    }

    // MARK: Meta

    public func meta(_ key: String) throws -> String? {
        try state.withLock { s in
            let st = try s.getMeta.bind([key])
            defer { _ = try? st.run() }
            return try st.step() ? st.string(0) : nil
        }
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        try state.withLock { s in try s.setMeta.bind([key, value]).run() }
    }

    /// Items with no current vector.
    public func pendingCount() throws -> Int {
        try state.withLock { s in
            let st = try s.pendingCount.bind([])
            defer { _ = try? st.run() }
            return try st.step() ? Int(st.int64(0)) : 0
        }
    }

    /// Marks every item as needing a vector (after the vector store was reset).
    public func resetEmbedded() throws {
        try state.withLock { s in try s.db.exec("UPDATE items SET embedded = 0 WHERE embedded <> 0") }
    }

    /// The catalog row for `path`, straight from SQLite.
    public func item(path: String) throws -> Item? {
        try state.withLock { s in try Self.readItems(s.itemByPath.bind([path])).first }
    }

    // MARK: Opens (ranking + Recents)

    /// Counts one open of `path` and returns its updated frecency.
    @discardableResult
    public func recordOpen(path: String, at date: Date = .now) throws -> Frecency {
        try state.withLock { s in
            try s.db.transaction {
                let get = try s.getOpen.bind([path])
                var count = 0
                var f = Frecency()
                if try get.step() {
                    count = Int(get.int64(0))
                    f = Frecency(score: get.double(2), at: Date(timeIntervalSince1970: get.double(1)))
                }
                try get.run()
                let next = f.adding(at: date)
                try s.putOpen.bind([path, count + 1, next.at.timeIntervalSince1970, next.score]).run()
                return next
            }
        }
    }

    /// path → (open count, last open) for frecency ranking.
    public func openStats() throws -> [String: (count: Int, last: Date)] {
        try frecencyStats().mapValues { ($0.count, $0.frecency.at) }
    }

    /// path → (open count, frecency as of the last open).
    public func frecencyStats() throws -> [String: (count: Int, frecency: Frecency)] {
        try state.withLock { s in
            let st = try s.opens.bind([])
            var out: [String: (count: Int, frecency: Frecency)] = [:]
            while try st.step() {
                guard let path = st.string(0) else { continue }
                out[path] = (
                    Int(st.int64(1)),
                    Frecency(score: st.double(3), at: Date(timeIntervalSince1970: st.double(2)))
                )
            }
            return out
        }
    }

    /// Most recently opened catalog items, newest first. Entries whose file no longer exists are deleted.
    public func recents(limit: Int) throws -> [Item] {
        guard limit > 0 else { return [] }
        let paths: [String] = try state.withLock { s in
            let st = try s.recentOpens.bind([])
            var out: [String] = []
            while try st.step() { if let p = st.string(0) { out.append(p) } }
            return out
        }
        var out: [Item] = []
        var missing: [String] = []
        for path in paths where out.count < limit {
            guard FileManager.default.fileExists(atPath: path) else { missing.append(path); continue }
            if let item = try item(path: path) { out.append(item) }
        }
        if !missing.isEmpty {
            try state.withLock { s in
                try s.db.transaction { for p in missing { try s.deleteOpen.bind([p]).run() } }
            }
        }
        return out
    }

    // MARK: Pins (Favorites)

    /// Appends `path` to the favorites (no-op if already pinned).
    public func pin(path: String) throws {
        try state.withLock { s in try s.addPin.bind([path]).run() }
    }

    public func unpin(path: String) throws {
        try state.withLock { s in try s.deletePin.bind([path]).run() }
    }

    /// Reorders the favorites: `paths` first, in that order; pinned paths not listed keep their relative order after.
    public func reorderPins(_ paths: [String]) throws {
        let current = try pinnedPaths()
        var seen = Set<String>()
        let listed = paths.filter { current.contains($0) && seen.insert($0).inserted }
        let order = listed + current.filter { !seen.contains($0) }
        try state.withLock { s in
            try s.db.transaction {
                for (i, p) in order.enumerated() { try s.setPinPosition.bind([i, p]).run() }
            }
        }
    }

    /// Pinned paths in user order (including ones not in the catalog).
    public func pinnedPaths() throws -> [String] {
        try state.withLock { s in
            let st = try s.pins.bind([])
            var out: [String] = []
            while try st.step() { if let p = st.string(0) { out.append(p) } }
            return out
        }
    }

    /// Pinned catalog items in user order. Pins whose file no longer exists are deleted; pins of paths that exist
    /// but aren't (yet) in the catalog are kept and skipped.
    public func favorites() throws -> [Item] {
        var out: [Item] = []
        var missing: [String] = []
        for path in try pinnedPaths() {
            guard FileManager.default.fileExists(atPath: path) else { missing.append(path); continue }
            if let item = try item(path: path) { out.append(item) }
        }
        if !missing.isEmpty {
            try state.withLock { s in
                try s.db.transaction { for p in missing { try s.deletePin.bind([p]).run() } }
            }
        }
        return out
    }

    // MARK: Helpers

    private static func readItems(_ st: Statement) throws -> [Item] {
        var out: [Item] = []
        try forEachItem(st) { out.append($0) }
        return out
    }

    private static func forEachItem(_ st: Statement, _ body: (Item) -> Void) throws {
        while try st.step() {
            body(
                Item(
                    id: UInt32(truncatingIfNeeded: st.int64(0)),
                    path: st.string(1) ?? "",
                    name: st.string(2) ?? "",
                    kind: ItemKind(rawValue: UInt8(truncatingIfNeeded: st.int64(3))) ?? .file,
                    modified: Date(timeIntervalSince1970: st.double(4))))
        }
    }
}

// MARK: - v3: identity, stamps, range queries (v3 plan §B I2/I4, K6)

extension Catalog {
    /// In-place, idempotent migration to schema v3 in one `BEGIN IMMEDIATE`: adds identity/stamp/hash columns,
    /// the identity + hash indexes and the `volumes`/`dirs`/`blob` tables. Existing ids, `embedded` flags and
    /// vectors are untouched, so a migrated catalog re-embeds and re-extracts nothing. A crash before COMMIT
    /// rolls back; the next open redoes it (every step checks before it acts).
    static func migrate(_ db: SQLiteDB) throws {
        let version = try db.prepare("PRAGMA user_version")
        let current = try version.bind([]).step() ? Int(version.int64(0)) : 0
        try version.run()
        guard current < schemaVersion else { return }
        try db.transaction {
            let info = try db.prepare("SELECT name FROM pragma_table_info('items')")
            var have = Set<String>()
            try info.bind([])
            while try info.step() { if let n = info.string(0) { have.insert(n) } }
            for (col, type) in [
                ("dev", "INTEGER"), ("file_id", "INTEGER"), ("doc_id", "INTEGER"),
                ("clone_id", "INTEGER"), ("size", "INTEGER"), ("ctime_ns", "INTEGER"),
                ("mtime_ns", "INTEGER"), ("flags", "INTEGER"), ("name_doc_hash", "BLOB"),
                ("name_vec_hash", "BLOB"),
            ] where !have.contains(col) {
                try db.exec("ALTER TABLE items ADD COLUMN \(col) \(type)")
            }
            // Not UNIQUE: hard links legitimately share (dev, file_id) across paths.
            try db.exec(
                """
                CREATE INDEX IF NOT EXISTS items_fileid ON items(dev, file_id) WHERE file_id IS NOT NULL;
                CREATE INDEX IF NOT EXISTS items_hash ON items(content_hash) WHERE content_hash IS NOT NULL;
                CREATE TABLE IF NOT EXISTS volumes(uuid TEXT PRIMARY KEY, device INTEGER, mount TEXT,
                    last_event_id INTEGER, online INTEGER NOT NULL DEFAULT 1, verified_at REAL);
                CREATE TABLE IF NOT EXISTS dirs(path TEXT PRIMARY KEY, mtime_ns INTEGER, child_count INTEGER)
                    WITHOUT ROWID;
                PRAGMA user_version = \(schemaVersion);
                """)
        }
        try? db.exec("PRAGMA optimize=0x10002")
    }

    /// Identity-aware upsert (I1/I4). Per entry:
    /// - known path, same name/kind/stamp ⇒ nothing written (`change == nil`);
    /// - known path, changed ⇒ one UPDATE (`.metadata`); `embedded` survives a stamp backfill of a migrated row;
    /// - unknown path whose `(dev, file_id)` belongs to a row whose old path is gone ⇒ the row is moved
    ///   (`.renamed(from:)`, id + vectors + full-text kept);
    /// - else INSERT (`.added`).
    public func upsertEntries(_ entries: [CrawlEntry]) throws -> [CatalogUpsert] {
        guard !entries.isEmpty else { return [] }
        let out: [CatalogUpsert] = try state.withLock { s in
            try s.db.transaction {
                var out: [CatalogUpsert] = []
                out.reserveCapacity(entries.count)
                var written = 0
                for e in entries {
                    let r = try upsertOne(s, e)
                    if r.change != nil { written += 1 }
                    out.append(r)
                }
                itemRowsWritten.add(written, ordering: .relaxed)
                return out
            }
        }
        let changed = out.filter { $0.change != nil }
        if !changed.isEmpty {
            cache.withLock { mirror in for r in changed { mirror.insert(r.item) } }
        }
        return out
    }

    private func bindStamp(_ e: CrawlEntry) -> [Any?] {
        let id = e.identity, st = e.stamp
        return [
            id.map { Int64(bitPattern: $0.device) }, id.map { Int64(bitPattern: $0.fileID) },
            id?.documentID.map { Int64($0) }, id?.cloneID.map { Int64(bitPattern: $0) },
            st?.size, st?.ctimeNs, st?.mtimeNs, st.map { Int64($0.flags) },
        ]
    }

    private func upsertOne(_ s: DB, _ e: CrawlEntry) throws -> CatalogUpsert {
        let modified = e.modified.timeIntervalSince1970
        var item = Item(id: 0, path: e.path, name: e.name, kind: e.kind, modified: e.modified)
        let q = try s.byPathFull.bind([e.path])
        if try q.step() {
            let id = UInt32(truncatingIfNeeded: q.int64(0))
            let name = q.string(1) ?? "", kind = q.int64(2), oldModified = q.double(3)
            let hasStamp = !q.isNull(7)
            let same: Bool
            if let st = e.stamp, let ident = e.identity, hasStamp {
                same =
                    name == e.name && kind == Int64(e.kind.rawValue)
                    && q.int64(4) == Int64(bitPattern: ident.device) && q.int64(5) == Int64(bitPattern: ident.fileID)
                    && q.int64(6) == st.size && q.int64(7) == st.mtimeNs && q.int64(8) == st.ctimeNs
                    && q.int64(9) == Int64(st.flags)
            } else {
                same =
                    name == e.name && kind == Int64(e.kind.rawValue) && oldModified == modified
                    && (e.stamp == nil || hasStamp)
            }
            try q.run()
            item.id = id
            if same { return CatalogUpsert(item: item, change: nil) }
            // Keep the name vector when only a missing stamp is being filled in (migrated v2 row).
            let keepEmbedded = name == e.name && kind == Int64(e.kind.rawValue) && oldModified == modified
            try s.updateFull.bind([id, e.name, e.kind.rawValue, modified] + bindStamp(e) + [keepEmbedded ? 1 : 0]).run()
            return CatalogUpsert(item: item, change: .metadata)
        }
        try q.run()
        if let ident = e.identity {
            let m = try s.byIdentity.bind([Int64(bitPattern: ident.device), Int64(bitPattern: ident.fileID)])
            var candidate: (UInt32, String)?
            while try m.step() {
                let oldPath = m.string(1) ?? ""
                if candidate == nil, !Self.stillThere(oldPath, ident) {
                    candidate = (UInt32(truncatingIfNeeded: m.int64(0)), oldPath)
                }
            }
            if let (id, oldPath) = candidate {
                let st = e.stamp
                try s.moveRow.bind([
                    id, e.path, e.name, e.kind.rawValue, modified,
                    ident.documentID.map { Int64($0) }, ident.cloneID.map { Int64(bitPattern: $0) },
                    st?.size, st?.ctimeNs, st?.mtimeNs, st.map { Int64($0.flags) },
                ]).run()
                item.id = id
                return CatalogUpsert(item: item, change: .renamed(from: oldPath))
            }
        }
        let ins = try s.insertFull.bind([e.path, e.name, e.kind.rawValue, modified] + bindStamp(e))
        guard try ins.step() else { throw SQLiteError(code: -1, message: "insert returned no id") }
        item.id = UInt32(truncatingIfNeeded: ins.int64(0))
        try ins.run()
        return CatalogUpsert(item: item, change: .added)
    }

    /// The old path still holds this identity (hard link, or not moved yet) ⇒ not a move.
    static func stillThere(_ path: String, _ ident: FileIdentity) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return UInt64(st.st_ino) == ident.fileID && UInt64(UInt32(bitPattern: st.st_dev)) == ident.device
    }

    /// Items at or below `path` (range scan on the UNIQUE(path) index, K6). `'0'` is the byte after `'/'`, so
    /// "/a/b c" is not below "/a/b".
    public func items(under path: String) throws -> [Item] {
        try state.withLock { s in try Self.readItems(s.underRange.bind([path])) }
    }

    /// Deletes `path` and everything below it via the same range (no full scan). Returns the removed ids.
    @discardableResult
    public func deleteSubtree(_ paths: [String]) throws -> [UInt32] {
        guard !paths.isEmpty else { return [] }
        let ids: [UInt32] = try state.withLock { s in
            try s.db.transaction {
                var out: [UInt32] = []
                for p in paths {
                    let st = try s.deleteRange.bind([p])
                    while try st.step() { out.append(UInt32(truncatingIfNeeded: st.int64(0))) }
                }
                return out
            }
        }
        itemRowsWritten.add(ids.count, ordering: .relaxed)
        if !ids.isEmpty { cache.withLock { m in for id in ids { m.remove(id) } } }
        return ids
    }

    /// The exact-input hash stored with an item's current name vector (nil = unknown / never embedded with v3).
    public func nameVectorHash(_ id: UInt32) throws -> Data? {
        try state.withLock { s in
            let st = try s.nameVecHash.bind([id])
            defer { _ = try? st.run() }
            guard try st.step(), let blob = st.blob(0) else { return nil }
            return blob
        }
    }

    /// Marks items embedded and records the exact-input hash of their name document.
    public func markEmbedded(_ pairs: [(id: UInt32, hash: Data)]) throws {
        guard !pairs.isEmpty else { return }
        try state.withLock { s in
            try s.db.transaction {
                for p in pairs { try s.markEmbeddedHash.bind([p.id, p.hash]).run() }
            }
        }
    }

    /// `PRAGMA user_version` (tests: migration ran).
    public func schemaUserVersion() throws -> Int {
        try state.withLock { s in
            let st = try s.db.prepare("PRAGMA user_version")
            defer { _ = try? st.run() }
            return try st.bind([]).step() ? Int(st.int64(0)) : 0
        }
    }
}
