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

    static let schemaVersion = 5

    /// 同一模型的不同叫法，入库时统一。DeepSeek Harness 记的 deepseek-flash 就是 V4.1 Flash。
    static let modelAliases: [String: String] = [
        "deepseek-flash": "deepseek-v4.1-flash",
    ]

    static func canonicalModel(_ m: String) -> String { modelAliases[m] ?? m }

    func migrate() throws {
        let v = db.userVersion
        guard v < Self.schemaVersion else { return }
        try db.transaction {
            if v < 1 {
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
                """)
            }
            if v < 2 {
                // 代码编辑：一次工具调用一行，lines = 各处改动 max(新增, 删除) 之和。
                try db.exec("""
                CREATE TABLE IF NOT EXISTS edits (
                    key     TEXT PRIMARY KEY,
                    agent   TEXT NOT NULL,
                    ts      INTEGER NOT NULL,
                    day     TEXT NOT NULL,
                    cwd     TEXT NOT NULL,
                    session TEXT NOT NULL,
                    added   INTEGER NOT NULL DEFAULT 0,
                    removed INTEGER NOT NULL DEFAULT 0,
                    lines   INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS idx_edits_day ON edits(day);
                """)
                // 已有库的游标早已越过历史里的编辑：清空游标让全部日志重读一遍。
                // events 是按键幂等 upsert，重读不会重复计数，编辑则借此回填。
                if v >= 1 { try db.exec("DELETE FROM cursors;") }
            }
            if v < 3 {
                // 生图调用：一次 img / imagegen 命令（或内置生图工具）一行
                try db.exec("""
                CREATE TABLE IF NOT EXISTS images (
                    key     TEXT PRIMARY KEY,
                    agent   TEXT NOT NULL,
                    ts      INTEGER NOT NULL,
                    day     TEXT NOT NULL,
                    cwd     TEXT NOT NULL,
                    session TEXT NOT NULL,
                    kind    TEXT NOT NULL,
                    model   TEXT NOT NULL,
                    count   INTEGER NOT NULL DEFAULT 1
                );
                CREATE INDEX IF NOT EXISTS idx_images_day ON images(day);
                """)
                for (from, to) in Self.modelAliases {
                    try db.run("UPDATE events SET model = ? WHERE model = ?", [.text(to), .text(from)])
                }
                // 同上：重读全部日志以回填历史里的生图调用
                if v >= 1 { try db.exec("DELETE FROM cursors;") }
            }
            if v < 4 {
                // 编辑行数换了算法（覆盖写入按 diff 算、临时目录等不计入）：清掉旧的编辑记录和游标，
                // 让历史日志按新算法重算一遍。events、images 是按键幂等 upsert，重读不会重复计数。
                if v >= 1 { try db.exec("DELETE FROM edits; DELETE FROM cursors;") }
            }
            if v < 5 {
                // 按天汇总：界面上的数字都从这张小表算，不再每次扫全部事件。
                // 一行是「某天 × agent × 模型 × 项目」的合计；events 有改动的那几天记进 daily_dirty，
                // 读统计前把这几天重算一遍（见 refreshDaily）。汇总是从 events 推出来的，随时可以整表重建。
                try db.exec("""
                CREATE TABLE IF NOT EXISTS daily (
                    day         TEXT NOT NULL,
                    agent       TEXT NOT NULL,
                    model       TEXT NOT NULL,
                    cwd         TEXT NOT NULL,
                    input       INTEGER NOT NULL,
                    cache_read  INTEGER NOT NULL,
                    cache_write INTEGER NOT NULL,
                    output      INTEGER NOT NULL,
                    sub_tokens  INTEGER NOT NULL,
                    gen_out     INTEGER NOT NULL,
                    gen_ms      INTEGER NOT NULL,
                    last_ts     INTEGER NOT NULL,
                    PRIMARY KEY (day, agent, model, cwd)
                ) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS daily_dirty (day TEXT PRIMARY KEY) WITHOUT ROWID;
                DELETE FROM daily;
                INSERT OR IGNORE INTO daily_dirty SELECT DISTINCT day FROM events;
                -- 编辑行数按「天 × agent × 项目」汇总时只扫这个索引，不回表、不排序（它也顶替了原来只有 day 的索引）
                DROP INDEX IF EXISTS idx_edits_day;
                CREATE INDEX IF NOT EXISTS idx_edits_roll ON edits(day, agent, cwd, lines);
                """)
            }
            try db.exec("PRAGMA user_version = \(Self.schemaVersion);")
        }
    }

    // MARK: 事件

    private lazy var upsertStmt: Statement? = try? db.prepare("""
        INSERT INTO events (key, agent, ts, day, model, cwd, session, sub, input, cache_read, cache_write, output, gen_ms)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            model       = CASE WHEN events.model = 'unknown' THEN excluded.model ELSE events.model END,
            cwd         = CASE WHEN events.cwd = '' THEN excluded.cwd ELSE events.cwd END,
            sub         = max(sub, excluded.sub),
            input       = max(input, excluded.input),
            cache_read  = max(cache_read, excluded.cache_read),
            cache_write = max(cache_write, excluded.cache_write),
            output      = max(output, excluded.output),
            gen_ms      = CASE WHEN excluded.gen_ms IS NULL THEN gen_ms WHEN gen_ms IS NULL THEN excluded.gen_ms
                               ELSE max(gen_ms, excluded.gen_ms) END
        RETURNING day
        """)

    /// 同一键重复出现时（流式多行、文件被重读）取各字段最大值，所以重放是安全的。
    /// 改到的那几天记进 daily_dirty（和事件在同一个事务里），汇总表下次读之前重算。
    func upsert(_ events: [UsageEvent]) throws {
        guard !events.isEmpty else { return }
        guard let st = upsertStmt else { throw SQLiteError(message: "upsert 语句准备失败") }
        // 行里存的 day 是第一次写入时定的，后来的更新不改它，所以以语句返回的为准
        var days: Set<String> = []
        defer { for d in days { try? db.run("INSERT OR IGNORE INTO daily_dirty (day) VALUES (?)", [.text(d)]) } }
        for e in events {
            try st.bind([
                .text(e.key), .text(e.agent.rawValue), .int(e.ts), .text(Time.day(ms: e.ts)),
                .text(Self.canonicalModel(e.model)), .text(e.cwd), .text(e.session), .int(e.isSubagent ? 1 : 0),
                .int(e.input), .int(e.cacheRead), .int(e.cacheWrite), .int(e.output),
                e.genMs.map { .int($0) } ?? .null,
            ])
            if try st.step() {
                days.insert(st.row()[0].text)
                while try st.step() {}
            }
        }
    }

    private lazy var editStmt: Statement? = try? db.prepare("""
        INSERT INTO edits (key, agent, ts, day, cwd, session, added, removed, lines)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            added = excluded.added, removed = excluded.removed, lines = excluded.lines,
            cwd = CASE WHEN edits.cwd = '' THEN excluded.cwd ELSE edits.cwd END
        """)

    func upsert(edits: [EditEvent]) throws {
        guard !edits.isEmpty else { return }
        guard let st = editStmt else { throw SQLiteError(message: "edits 语句准备失败") }
        for e in edits {
            try st.bind([
                .text(e.key), .text(e.agent.rawValue), .int(e.ts), .text(Time.day(ms: e.ts)),
                .text(e.cwd), .text(e.session),
                .int(e.change.added), .int(e.change.removed), .int(e.change.lines),
            ])
            _ = try st.step()
        }
    }

    private lazy var imageStmt: Statement? = try? db.prepare("""
        INSERT INTO images (key, agent, ts, day, cwd, session, kind, model, count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            kind = excluded.kind, model = excluded.model, count = excluded.count,
            cwd = CASE WHEN images.cwd = '' THEN excluded.cwd ELSE images.cwd END
        """)

    func upsert(images: [ImageEvent]) throws {
        guard !images.isEmpty else { return }
        guard let st = imageStmt else { throw SQLiteError(message: "images 语句准备失败") }
        for e in images {
            try st.bind([
                .text(e.key), .text(e.agent.rawValue), .int(e.ts), .text(Time.day(ms: e.ts)),
                .text(e.cwd), .text(e.session), .text(e.kind), .text(e.model), .int(e.count),
            ])
            _ = try st.step()
        }
    }

    public func imageCount() throws -> Int {
        Int(try db.query("SELECT COUNT(*) FROM images").first?.first?.int ?? 0)
    }

    public func editCount() throws -> Int {
        Int(try db.query("SELECT COUNT(*) FROM edits").first?.first?.int ?? 0)
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

    // MARK: 按天汇总

    private lazy var dirtyStmt: Statement? = try? db.prepare("SELECT day FROM daily_dirty")

    /// 把有改动的那几天的汇总重算一遍。没有改动时只是一次空查询。读统计之前调用。
    public func refreshDaily() throws {
        guard let st = dirtyStmt else { throw SQLiteError(message: "daily_dirty 语句准备失败") }
        try st.bind([])
        var days: [String] = []
        while try st.step() { days.append(st.row()[0].text) }
        guard !days.isEmpty else { return }
        try db.transaction {
            for day in days {
                try db.run("DELETE FROM daily WHERE day = ?", [.text(day)])
                try db.run("""
                    INSERT INTO daily
                    SELECT day, agent, model, cwd, SUM(input), SUM(cache_read), SUM(cache_write), SUM(output),
                           SUM(CASE WHEN sub = 1 THEN input + cache_read + cache_write + output ELSE 0 END),
                           SUM(CASE WHEN gen_ms IS NOT NULL THEN output ELSE 0 END),
                           SUM(COALESCE(gen_ms, 0)), MAX(ts)
                    FROM events WHERE day = ? GROUP BY agent, model, cwd
                    """, [.text(day)])
            }
            try db.exec("DELETE FROM daily_dirty")
        }
    }

    /// 游标的位置和修改时间，不带解析器状态（状态可能有几 MB，全量扫描时用不着）。
    func cursorIndex() throws -> [String: (offset: Int64, mtime: Double)] {
        var out: [String: (offset: Int64, mtime: Double)] = [:]
        for r in try db.query("SELECT path, offset, mtime FROM cursors") {
            out[r[0].text] = (r[1].int, r[2].double)
        }
        return out
    }

    /// 清空全部数据，下次扫描会从头回填。
    public func reset() throws {
        try db.exec("DELETE FROM events; DELETE FROM edits; DELETE FROM images; DELETE FROM cursors; DELETE FROM daily; DELETE FROM daily_dirty;")
    }
}
