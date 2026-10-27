import Foundation
import SQLite3

/// A SQLite failure: the result code and SQLite's message.
public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin owner of a sqlite3 connection. Not thread-safe; callers serialize access (Mutex or actor).
final class SQLiteDB {
    private(set) var handle: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(code: rc, message: message)
        }
        handle = db
        // Writers on one file wait for each other (Catalog and VectorStore both write index.sqlite). The stock
        // busy_timeout backs off to 50–100 ms sleeps, so a ~1 ms vector commit next door held a name-visible
        // FSEvents batch for 0.3–0.9 s (v4 s5). Poll every 1 ms instead, for ≤ 5 s like before.
        sqlite3_busy_handler(
            db,
            { _, attempts in
                guard attempts < 5000 else { return 0 }
                usleep(1000)
                return 1
            }, nil)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY;")
    }

    deinit { sqlite3_close_v2(handle) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc) }
        return Statement(stmt, db: self)
    }

    func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Nesting depth of `transaction` (K13: reentrant; inner levels are savepoints).
    private var depth = 0

    /// Runs `body` inside one transaction; rolls back if it throws. Nested calls use SAVEPOINTs, so an inner
    /// failure rolls back only the inner work and the outer transaction decides the rest.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        let level = depth
        let name = "sp\(level)"
        try exec(level == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(name)")
        depth += 1
        defer { depth -= 1 }
        do {
            let result = try body()
            try exec(level == 0 ? "COMMIT" : "RELEASE \(name)")
            return result
        } catch {
            if level == 0 {
                try? exec("ROLLBACK")
            } else {
                try? exec("ROLLBACK TO \(name)")
                try? exec("RELEASE \(name)")
            }
            throw error
        }
    }

    /// Rows changed by the most recent statement.
    var changes: Int { Int(sqlite3_changes(handle)) }
}

/// A prepared statement, reset before every use.
final class Statement {
    private let stmt: OpaquePointer
    private let db: SQLiteDB
    private var done = false

    init(_ stmt: OpaquePointer, db: SQLiteDB) {
        self.stmt = stmt
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    /// Resets and binds `values` (1-based in order). Supported: Int, Int64, UInt32, Double, String, nil.
    @discardableResult
    func bind(_ values: [Any?]) throws -> Statement {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        done = false
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            let rc: Int32
            switch value {
            case nil: rc = sqlite3_bind_null(stmt, index)
            case let v as Int: rc = sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Int64: rc = sqlite3_bind_int64(stmt, index, v)
            case let v as UInt32: rc = sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as UInt64: rc = sqlite3_bind_int64(stmt, index, Int64(bitPattern: v))
            case let v as UInt8: rc = sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Double: rc = sqlite3_bind_double(stmt, index, v)
            case let v as String: rc = sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
            case let v as Data:
                rc = v.withUnsafeBytes {
                    sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
                }
            case let v as Bool: rc = sqlite3_bind_int64(stmt, index, v ? 1 : 0)
            default: rc = SQLITE_MISMATCH
            }
            if rc != SQLITE_OK { throw db.error(rc) }
        }
        return self
    }

    /// Steps once; true while a row is available. After the last row it keeps returning false until `bind`.
    func step() throws -> Bool {
        guard !done else { return false }
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE:
            done = true
            return false
        default:
            done = true
            throw db.error(rc)
        }
    }

    /// Steps to completion, ignoring rows.
    func run() throws {
        while try step() {}
    }

    func int64(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
    func double(_ col: Int32) -> Double { sqlite3_column_double(stmt, col) }
    func isNull(_ col: Int32) -> Bool { sqlite3_column_type(stmt, col) == SQLITE_NULL }
    func blob(_ col: Int32) -> Data? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, col))
        guard let p = sqlite3_column_blob(stmt, col) else { return Data() }
        return Data(bytes: p, count: n)
    }
    func string(_ col: Int32) -> String? {
        guard let text = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: text)
    }
}
