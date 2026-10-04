import Foundation
import SQLite3

enum SQLValue {
    case null, int(Int), double(Double), text(String)
}

/// Small read-write SQLite wrapper for derived data (the search index). Source of truth stays in the event log.
final class SQLiteDatabase {
    enum DBError: Error { case open(String), sql(String) }

    private var db: OpaquePointer?

    convenience init(path: URL) throws { try self.init(location: path.path) }

    /// `":memory:"` gives a private in-memory database.
    init(location: String) throws {
        guard sqlite3_open_v2(location, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw DBError.open(message)
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
    }

    deinit { sqlite3_close(db) }

    func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let code = sqlite3_step(stmt)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw DBError.sql(String(cString: sqlite3_errmsg(db))) }
    }

    func query(_ sql: String, _ params: [SQLValue] = [], _ body: (SQLiteReader.Row) throws -> Void) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_ROW { try body(SQLiteReader.Row(stmt: stmt)); continue }
            guard code == SQLITE_DONE else { throw DBError.sql(String(cString: sqlite3_errmsg(db))) }
            return
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.sql(String(cString: sqlite3_errmsg(db)))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in params.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .null: sqlite3_bind_null(stmt, index)
            case .int(let v): sqlite3_bind_int64(stmt, index, Int64(v))
            case .double(let v): sqlite3_bind_double(stmt, index, v)
            case .text(let v): sqlite3_bind_text(stmt, index, v, -1, transient)
            }
        }
        return stmt
    }
}
