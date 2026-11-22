import Foundation

/// ~/.tokens/tokens.db：本项目自己的用量库。只由 token-notch 写入。
public final class Store: @unchecked Sendable {
    public let db: SQLiteDB
    public let path: String

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tokens", isDirectory: true)
    }

    public static func openDefault() throws -> Store {
        let dir = defaultDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Store(path: dir.appendingPathComponent("tokens.db").path)
    }

    public init(path: String) throws {
        self.path = path
        db = try SQLiteDB(path: path)
        try migrate()
    }

    static let schemaVersion = 1

    func migrate() throws {
        guard db.userVersion < Self.schemaVersion else { return }
        try db.exec("""
        CREATE TABLE IF NOT EXISTS events (
            key         TEXT PRIMARY KEY,
            agent       TEXT NOT NULL,
            ts          INTEGER NOT NULL,
            day         TEXT NOT NULL,
            model       TEXT NOT NULL,
            cwd         TEXT NOT NULL,
            session     TEXT NOT NULL,
            sub         INTEGER NOT NULL DEFAULT 0,
            input       INTEGER NOT NULL DEFAULT 0,
            cache_read  INTEGER NOT NULL DEFAULT 0,
            cache_write INTEGER NOT NULL DEFAULT 0,
            output      INTEGER NOT NULL DEFAULT 0,
            gen_ms      INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_events_day ON events(day);
        CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
        CREATE TABLE IF NOT EXISTS cursors (
            path   TEXT PRIMARY KEY,
            agent  TEXT NOT NULL,
            offset INTEGER NOT NULL,
            fp     INTEGER NOT NULL,
            mtime  REAL NOT NULL,
            state  BLOB
        );
        PRAGMA user_version = \(Self.schemaVersion);
        """)
    }

    // MARK: 事件

    private lazy var upsertStmt: Statement? = try? db.prepare("""
        INSERT INTO events (key, agent, ts, day, model, cwd, session, sub, input, cache_read, cache_write, output, gen_ms)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            input       = max(input, excluded.input),
            cache_read  = max(cache_read, excluded.cache_read),
            cache_write = max(cache_write, excluded.cache_write),
            output      = max(output, excluded.output),
            gen_ms      = COALESCE(gen_ms, excluded.gen_ms)
        """)

    /// 同一键重复出现时（流式多行、文件被重读）取各字段最大值，所以重放是安全的。
    func upsert(_ events: [UsageEvent]) throws {
        guard let st = upsertStmt else { throw SQLiteError(message: "upsert 语句准备失败") }
        for e in events {
            try st.bind([
                .text(e.key), .text(e.agent.rawValue), .int(e.ts), .text(Time.day(ms: e.ts)),
                .text(e.model), .text(e.cwd), .text(e.session), .int(e.isSubagent ? 1 : 0),
                .int(e.input), .int(e.cacheRead), .int(e.cacheWrite), .int(e.output),
                e.genMs.map { .int($0) } ?? .null,
            ])
            _ = try st.step()
        }
    }

    public func eventCount() throws -> Int {
        Int(try db.query("SELECT COUNT(*) FROM events").first?.first?.int ?? 0)
    }

    // MARK: 游标

    struct Cursor {
        var path: String
        var agent: Agent
        var offset: Int64
        var fingerprint: UInt64
        var mtime: Double
        var state: Data?
    }

    func cursor(for path: String) throws -> Cursor? {
        guard let r = try db.query("SELECT agent, offset, fp, mtime, state FROM cursors WHERE path = ?", [.text(path)]).first,
              let agent = Agent(rawValue: r[0].text) else { return nil }
        return Cursor(path: path, agent: agent, offset: r[1].int,
                      fingerprint: UInt64(bitPattern: r[2].int), mtime: r[3].double, state: r[4].data)
    }

    func allCursors() throws -> [String: Cursor] {
        var out: [String: Cursor] = [:]
        for r in try db.query("SELECT path, agent, offset, fp, mtime, state FROM cursors") {
            guard let agent = Agent(rawValue: r[1].text) else { continue }
            out[r[0].text] = Cursor(path: r[0].text, agent: agent, offset: r[2].int,
                                    fingerprint: UInt64(bitPattern: r[3].int), mtime: r[4].double, state: r[5].data)
        }
        return out
    }

    func save(_ c: Cursor) throws {
        try db.run("""
            INSERT INTO cursors (path, agent, offset, fp, mtime, state) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET agent = excluded.agent, offset = excluded.offset,
                fp = excluded.fp, mtime = excluded.mtime, state = excluded.state
            """, [.text(c.path), .text(c.agent.rawValue), .int(c.offset),
                  .int(Int64(bitPattern: c.fingerprint)), .double(c.mtime), c.state.map { .blob($0) } ?? .null])
    }

    /// 清空全部数据，下次扫描会从头回填。
    public func reset() throws {
        try db.exec("DELETE FROM events; DELETE FROM cursors;")
    }
}
