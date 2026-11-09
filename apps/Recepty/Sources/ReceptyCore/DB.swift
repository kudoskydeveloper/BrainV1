import Foundation
import SQLite3

public struct ReceptyError: LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

public enum SQLValue: Equatable {
    case int(Int64), real(Double), text(String), blob(Data), null
    public var int: Int? { if case .int(let v) = self { return Int(v) }; if case .real(let v) = self { return Int(v) }; return nil }
    public var int64: Int64? { if case .int(let v) = self { return v }; return nil }
    public var double: Double? { if case .real(let v) = self { return v }; if case .int(let v) = self { return Double(v) }; return nil }
    public var string: String? { if case .text(let v) = self { return v }; if case .int(let v) = self { return String(v) }; return nil }
}

public typealias Row = [String: SQLValue]

/// A thin SQLite connection (serialized mode, WAL, 5 s busy timeout) shared by the app and the MCP server (same as in Financie and Faktúry).
public final class DB {
    private var db: OpaquePointer?

    /// readOnly opens another app's database without ever writing to it.
    public init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil
            throw ReceptyError("Databázu sa nepodarilo otvoriť: \(path)")
        }
        sqlite3_busy_timeout(db, 5000)
        if !readOnly { try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;") }
    }

    deinit { sqlite3_close(db) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw ReceptyError(m)
        }
    }

    @discardableResult
    public func run(_ sql: String, _ args: [Any?] = []) throws -> [Row] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw ReceptyError("SQLite: \(String(cString: sqlite3_errmsg(db)))") }
        defer { sqlite3_finalize(st) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(st, idx)
            case let v as Int: sqlite3_bind_int64(st, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, idx, v)
            case let v as Bool: sqlite3_bind_int64(st, idx, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(st, idx, v)
            case let v as String: sqlite3_bind_text(st, idx, v, -1, transient)
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(st, idx, $0.baseAddress, Int32(v.count), transient) }
            default: sqlite3_bind_text(st, idx, "\(a!)", -1, transient)
            }
        }
        var rows: [Row] = []
        while true {
            let r = sqlite3_step(st)
            if r == SQLITE_DONE { break }
            guard r == SQLITE_ROW else {
                var msg = String(cString: sqlite3_errmsg(db))
                if msg.hasPrefix("RECEPTY: ") { msg.removeFirst(9) }
                throw ReceptyError(msg)
            }
            var row: Row = [:]
            for c in 0..<sqlite3_column_count(st) {
                let name = String(cString: sqlite3_column_name(st, c))
                switch sqlite3_column_type(st, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(st, c))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(st, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(st, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(st, c))
                    row[name] = .blob(n > 0 ? Data(bytes: sqlite3_column_blob(st, c), count: n) : Data())
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public var lastID: Int64 { sqlite3_last_insert_rowid(db) }

    private var depth = 0
    /// BEGIN IMMEDIATE … COMMIT (nested calls join the outer transaction).
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        if depth > 0 { depth += 1; defer { depth -= 1 }; return try body() }
        try exec("BEGIN IMMEDIATE")
        depth = 1
        do {
            let v = try body()
            depth = 0
            try exec("COMMIT")
            return v
        } catch {
            depth = 0
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Copies the whole database to a file (a consistent snapshot even while others write).
    public func backup(to path: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        try run("VACUUM INTO ?", [path])
    }
}
