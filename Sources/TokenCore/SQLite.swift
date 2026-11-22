import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "SQLite: \(message)" }
}

public enum SQLValue: Sendable, Equatable {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null

    public var int: Int64 {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        case .text(let s): return Int64(s) ?? 0
        default: return 0
        }
    }

    public var double: Double {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .text(let s): return Double(s) ?? 0
        default: return 0
        }
    }

    public var text: String {
        switch self {
        case .text(let s): return s
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        default: return ""
        }
    }

    public var data: Data? {
        switch self {
        case .blob(let d): return d
        case .text(let s): return Data(s.utf8)
        default: return nil
        }
    }

    public var isNull: Bool { self == .null }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 极薄的 SQLite 封装。调用方负责串行访问（TokenService 用一个串行队列）。
public final class SQLiteDB: @unchecked Sendable {
    let handle: OpaquePointer

    public init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开 \(path)"
            if let h { sqlite3_close_v2(h) }
            throw SQLiteError(message: msg)
        }
        handle = h
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=3000;")
    }

    deinit { sqlite3_close_v2(handle) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw SQLiteError(message: msg)
        }
    }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    public func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(message: "\(lastError) — \(sql)")
        }
        return Statement(stmt: stmt, db: self)
    }

    public func query(_ sql: String, _ args: [SQLValue] = []) throws -> [[SQLValue]] {
        let st = try prepare(sql)
        try st.bind(args)
        var rows: [[SQLValue]] = []
        while try st.step() {
            rows.append(st.row())
        }
        return rows
    }

    public func run(_ sql: String, _ args: [SQLValue] = []) throws {
        let st = try prepare(sql)
        try st.bind(args)
        _ = try st.step()
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public var userVersion: Int {
        get { Int((try? query("PRAGMA user_version").first?.first?.int) ?? 0) }
    }
}

public final class Statement {
    let stmt: OpaquePointer
    let db: SQLiteDB

    init(stmt: OpaquePointer, db: SQLiteDB) {
        self.stmt = stmt
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    public func bind(_ args: [SQLValue]) throws {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, v) in args.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch v {
            case .int(let x): rc = sqlite3_bind_int64(stmt, idx, x)
            case .double(let x): rc = sqlite3_bind_double(stmt, idx, x)
            case .text(let s): rc = sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .blob(let d):
                rc = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
            case .null: rc = sqlite3_bind_null(stmt, idx)
            }
            if rc != SQLITE_OK { throw SQLiteError(message: db.lastError) }
        }
    }

    /// 有一行返回 true；执行完毕返回 false。
    public func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw SQLiteError(message: db.lastError)
    }

    public func row() -> [SQLValue] {
        (0..<sqlite3_column_count(stmt)).map { column($0) }
    }

    func column(_ i: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return .int(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, i))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(stmt, i)))
        case SQLITE_BLOB:
            let n = Int(sqlite3_column_bytes(stmt, i))
            guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return .blob(Data()) }
            return .blob(Data(bytes: p, count: n))
        default: return .null
        }
    }
}
