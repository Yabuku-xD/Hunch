import Foundation

/// Persisted, resumable work queue: one row per (item, tier) with the file fingerprint it was read at, so a quit,
/// crash or pause resumes where it stopped and unchanged files are never read twice. Only used from
/// `ContentIndexPipeline`'s executor.
final class ContentQueue {
    enum State: Int {
        case pending = 0
        /// Text is searchable; chunk vectors still to compute.
        case extracted = 1
        case done = 2
        /// Dataless (cloud-only) placeholder: names only until a modify event shows it materialized.
        case waitingDownload = 3
        /// Huge/cold file waiting for idle + AC power or `indexNow`.
        case deferred = 4
    }

    /// Bumped when an extractor's output for the same bytes changes (part of the blob-cache key, I5).
    static let extractorRev = 3

    struct Job: Sendable, Hashable {
        var item: UInt32
        var tier: ContentTier
        var path: String
        var name: String
        var pages: [Int]?
    }

    struct Row {
        var tier: ContentTier
        var state: State
        var fingerprint: FileFingerprint
        var path: String
        var textVectors: Int
        var imageVectors: Int
        var contentHash: Data?
    }

    private let db: SQLiteDB

    init(url: URL) throws {
        db = try SQLiteDB(url: url)
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS cq(
                item INTEGER NOT NULL, tier INTEGER NOT NULL,
                path TEXT NOT NULL, name TEXT NOT NULL,
                inode INTEGER NOT NULL, size INTEGER NOT NULL, mtime INTEGER NOT NULL,
                grp INTEGER NOT NULL, modified REAL NOT NULL,
                state INTEGER NOT NULL, status INTEGER, pages TEXT,
                nvec INTEGER NOT NULL DEFAULT 0, nimg INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(item, tier)) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS cq_next ON cq(tier, state, grp, modified DESC);
            CREATE INDEX IF NOT EXISTS cq_state ON cq(state, tier, grp, modified DESC);
            """)
        // v3 columns (in place, idempotent): dataless flags, blob-cache key, resumable cursor.
        let info = try db.prepare("SELECT name FROM pragma_table_info('cq')")
        var have = Set<String>()
        try info.bind([])
        while try info.step() { if let n = info.string(0) { have.insert(n) } }
        try db.transaction {
            for (col, type) in [
                ("flags", "INTEGER NOT NULL DEFAULT 0"), ("content_hash", "BLOB"),
                ("extractor_rev", "INTEGER"), ("cursor", "INTEGER"), ("ctime_ns", "INTEGER"),
            ]
            where !have.contains(col) {
                try db.exec("ALTER TABLE cq ADD COLUMN \(col) \(type)")
            }
            try db.exec(
                """
                CREATE INDEX IF NOT EXISTS cq_hash ON cq(content_hash, tier) WHERE content_hash IS NOT NULL;
                CREATE TABLE IF NOT EXISTS chunkvec(item INTEGER NOT NULL, tier INTEGER NOT NULL, idx INTEGER NOT NULL,
                    input_hash BLOB NOT NULL, PRIMARY KEY(item, tier, idx)) WITHOUT ROWID;
                CREATE INDEX IF NOT EXISTS chunkvec_hash ON chunkvec(input_hash);
                """)
        }
    }

    /// Statements prepared once per SQL text.
    private var prepared: [String: Statement] = [:]
    private func prep(_ sql: String) throws -> Statement {
        if let s = prepared[sql] { return s }
        let s = try db.prepare(sql)
        prepared[sql] = s
        return s
    }

    func transaction<T>(_ body: () throws -> T) throws -> T { try db.transaction(body) }

    /// Every queued (item, path), for re-applying the secret rules after they change.
    func allPaths() -> [(item: UInt32, path: String)] {
        guard let s = try? prep("SELECT DISTINCT item, path FROM cq"), (try? s.bind([])) != nil else { return [] }
        var out: [(item: UInt32, path: String)] = []
        while (try? s.step()) == true { out.append((UInt32(truncatingIfNeeded: s.int64(0)), s.string(1) ?? "")) }
        return out
    }

    func rows(item: UInt32) -> [Row] {
        guard
            let s = try? prep(
                "SELECT tier, state, inode, size, mtime, path, nvec, nimg, flags, content_hash FROM cq WHERE item=?"),
            (try? s.bind([item])) != nil
        else { return [] }
        var out: [Row] = []
        while (try? s.step()) == true {
            guard let tier = ContentTier(rawValue: Int(s.int64(0))) else { continue }
            out.append(
                Row(
                    tier: tier, state: State(rawValue: Int(s.int64(1))) ?? .pending,
                    fingerprint: FileFingerprint(
                        inode: UInt64(bitPattern: s.int64(2)), size: s.int64(3),
                        mtime: s.int64(4), flags: UInt32(truncatingIfNeeded: s.int64(8))),
                    path: s.string(5) ?? "", textVectors: Int(s.int64(6)), imageVectors: Int(s.int64(7)),
                    contentHash: s.blob(9)))
        }
        return out
    }

    /// Inserts or resets a row to pending with a new fingerprint.
    func upsert(
        item: UInt32, tier: ContentTier, path: String, name: String, fp: FileFingerprint, group: Int,
        modified: Double, pages: [Int]? = nil, state: State = .pending
    ) throws {
        let pagesText = pages.map { $0.map(String.init).joined(separator: ",") }
        try prep(
            """
            INSERT INTO cq(item, tier, path, name, inode, size, mtime, grp, modified, state, pages, flags)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(item, tier) DO UPDATE SET path=excluded.path, name=excluded.name, inode=excluded.inode,
                size=excluded.size, mtime=excluded.mtime, grp=excluded.grp, modified=excluded.modified,
                state=excluded.state, status=NULL, pages=excluded.pages, flags=excluded.flags
            """
        ).bind([
            item, tier.rawValue, path, name, Int64(bitPattern: fp.inode), fp.size, fp.mtime, group, modified,
            state.rawValue, pagesText, Int64(fp.stamp.flags),
        ]).run()
    }

    /// Fingerprint changed but the bytes hash the same (touch, safe-save of identical content): metadata only.
    func refresh(item: UInt32, tier: ContentTier, fp: FileFingerprint) throws {
        try prep("UPDATE cq SET inode=?, size=?, mtime=?, flags=? WHERE item=? AND tier=?")
            .bind([Int64(bitPattern: fp.inode), fp.size, fp.mtime, Int64(fp.stamp.flags), item, tier.rawValue]).run()
    }

    func setHash(item: UInt32, tier: ContentTier, hash: Data?) throws {
        try prep("UPDATE cq SET content_hash=?, extractor_rev=? WHERE item=? AND tier=?")
            .bind([hash, Self.extractorRev, item, tier.rawValue]).run()
    }

    /// Another finished row with the same bytes and extractor (blob cache, I5).
    func donor(
        hash: Data, tier: ContentTier, excluding item: UInt32
    ) -> (
        item: UInt32, status: ExtractionStatus,
        textVectors: Int, imageVectors: Int
    )? {
        // INDEXED BY: without stats the planner prefers cq_state (state=2 AND tier), which is nearly every row,
        // so each lookup scanned the whole queue (~100k rows) and the incremental bench crawled for hours.
        guard
            let s = try? prep(
                """
                SELECT item, status, nvec, nimg FROM cq INDEXED BY cq_hash
                    WHERE content_hash=? AND content_hash IS NOT NULL AND tier=? AND state=2 AND extractor_rev=?
                    AND item<>? LIMIT 1
                """), (try? s.bind([hash, tier.rawValue, Self.extractorRev, item])) != nil,
            (try? s.step()) == true
        else { return nil }
        defer { _ = try? s.run() }
        return (
            UInt32(truncatingIfNeeded: s.int64(0)), ExtractionStatus(rawValue: Int(s.int64(1))) ?? .ok,
            Int(s.int64(2)), Int(s.int64(3))
        )
    }

    // MARK: Chunk vector cache: exact model input hash → where that vector already lives.

    func chunkVector(hash: Data) -> (item: UInt32, tier: ContentTier, idx: UInt32)? {
        guard let s = try? prep("SELECT item, tier, idx FROM chunkvec WHERE input_hash=? LIMIT 1"),
            (try? s.bind([hash])) != nil, (try? s.step()) == true,
            let t = ContentTier(rawValue: Int(s.int64(1)))
        else { return nil }
        defer { _ = try? s.run() }
        return (UInt32(truncatingIfNeeded: s.int64(0)), t, UInt32(truncatingIfNeeded: s.int64(2)))
    }

    func setChunkVectors(item: UInt32, tier: ContentTier, _ rows: [(idx: UInt32, hash: Data)]) throws {
        try db.transaction {
            try prep("DELETE FROM chunkvec WHERE item=? AND tier=?").bind([item, tier.rawValue]).run()
            let ins = try prep("INSERT OR REPLACE INTO chunkvec(item, tier, idx, input_hash) VALUES(?,?,?,?)")
            for r in rows { try ins.bind([item, tier.rawValue, r.idx, r.hash]).run() }
        }
    }

    /// Dataless rows (names only), for the status line.
    func cloudOnlyCount() -> Int {
        guard let s = try? prep("SELECT count(DISTINCT item) FROM cq WHERE state=3"), (try? s.bind([])) != nil,
            (try? s.step()) == true
        else { return 0 }
        defer { _ = try? s.run() }
        return Int(s.int64(0))
    }

    /// Renamed/moved but unchanged: new path, no re-read.
    func move(item: UInt32, path: String, name: String) throws {
        try prep("UPDATE cq SET path=?, name=? WHERE item=?").bind([path, name, item]).run()
    }

    func delete(item: UInt32, tier: ContentTier? = nil) throws {
        if let tier {
            try prep("DELETE FROM cq WHERE item=? AND tier=?").bind([item, tier.rawValue]).run()
            try prep("DELETE FROM chunkvec WHERE item=? AND tier=?").bind([item, tier.rawValue]).run()
        } else {
            try prep("DELETE FROM cq WHERE item=?").bind([item]).run()
            try prep("DELETE FROM chunkvec WHERE item=?").bind([item]).run()
        }
    }

    /// Up to `limit` jobs of `tier` in `state`, best first, skipping `busy` items.
    func next(tier: ContentTier?, state: State, limit: Int, busy: Set<UInt32>) -> [Job] {
        let sql =
            tier == nil
            ? "SELECT item, tier, path, name, pages FROM cq WHERE state=? ORDER BY tier, grp, modified DESC LIMIT ?"
            : "SELECT item, tier, path, name, pages FROM cq WHERE state=? AND tier=? ORDER BY grp, modified DESC LIMIT ?"
        let args: [Any?] =
            tier == nil
            ? [state.rawValue, limit + busy.count]
            : [state.rawValue, tier!.rawValue, limit + busy.count]
        guard let s = try? prep(sql), (try? s.bind(args)) != nil else { return [] }
        var out: [Job] = []
        while out.count < limit, (try? s.step()) == true {
            let item = UInt32(truncatingIfNeeded: s.int64(0))
            guard !busy.contains(item), let t = ContentTier(rawValue: Int(s.int64(1))) else { continue }
            let pages = s.string(4).map { $0.split(separator: ",").compactMap { Int($0) } }
            out.append(Job(item: item, tier: t, path: s.string(2) ?? "", name: s.string(3) ?? "", pages: pages))
        }
        return out
    }

    func finish(
        item: UInt32, tier: ContentTier, state: State, status: ExtractionStatus, fp: FileFingerprint?,
        imageVectors: Int? = nil
    ) throws {
        var sql = "UPDATE cq SET state=?, status=?"
        var args: [Any?] = [state.rawValue, status.rawValue]
        if let fp {
            sql += ", inode=?, size=?, mtime=?, flags=?"
            args += [Int64(bitPattern: fp.inode), fp.size, fp.mtime, Int64(fp.stamp.flags)]
        }
        if let imageVectors {
            sql += ", nimg=?"
            args.append(imageVectors)
        }
        sql += " WHERE item=? AND tier=?"
        args += [item, tier.rawValue]
        try prep(sql).bind(args).run()
    }

    func setTextVectors(item: UInt32, tier: ContentTier, count: Int) throws {
        try prep("UPDATE cq SET nvec=?, state=2 WHERE item=? AND tier=?").bind([count, item, tier.rawValue]).run()
    }

    /// (tier, state) → rows.
    func counts() -> [ContentTier: [State: Int]] {
        guard let s = try? db.prepare("SELECT tier, state, count(*) FROM cq GROUP BY tier, state"),
            (try? s.bind([])) != nil
        else { return [:] }
        var out: [ContentTier: [State: Int]] = [:]
        while (try? s.step()) == true {
            guard let t = ContentTier(rawValue: Int(s.int64(0))), let st = State(rawValue: Int(s.int64(1))) else {
                continue
            }
            out[t, default: [:]][st] = Int(s.int64(2))
        }
        return out
    }

    func status(item: UInt32, tier: ContentTier) -> ExtractionStatus? {
        guard let s = try? db.prepare("SELECT status FROM cq WHERE item=? AND tier=?"),
            (try? s.bind([item, tier.rawValue])) != nil, (try? s.step()) == true, !s.isNull(0)
        else { return nil }
        return ExtractionStatus(rawValue: Int(s.int64(0)))
    }

    /// Rows left `extracted` when there is no embedder become done (and back when one appears). Only done rows
    /// without text vectors go back: rows already embedded stay done, so a relaunch embeds nothing.
    func settleExtracted(to state: State) throws {
        if state == .done {
            try db.prepare("UPDATE cq SET state=? WHERE state=?").bind([State.done.rawValue, State.extracted.rawValue])
                .run()
        } else {
            try db.prepare("UPDATE cq SET state=? WHERE state=? AND nvec=0")
                .bind([State.extracted.rawValue, State.done.rawValue]).run()
        }
    }
}
