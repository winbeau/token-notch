import XCTest
@testable import TokenCore

/// 按天汇总表：统计从它读，结果要和直接聚合 events 完全一样。
final class RollupTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tn-roll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func ms(_ iso: String) -> Int64 { Time.parseMs(iso)! }

    func event(_ key: String, _ agent: Agent, _ iso: String, model: String = "claude-sonnet-5-5", cwd: String = "/p/a",
               sub: Bool = false, input: Int64 = 1, cacheRead: Int64 = 10, output: Int64, genMs: Int64? = 1000) -> UsageEvent {
        UsageEvent(key: key, agent: agent, ts: ms(iso), model: model, cwd: cwd, session: "s", isSubagent: sub,
                   input: input, cacheRead: cacheRead, cacheWrite: 0, output: output, genMs: genMs)
    }

    /// 各范围的数字直接从 events 算一遍，和快照对比。
    func assertMatchesEvents(_ store: Store, now: Date, file: StaticString = #filePath, line: UInt = #line) throws {
        let engine = StatsEngine(store: store)
        let snap = try engine.snapshot(now: now)
        for r in TimeRange.allCases {
            let s = snap.stats(r)
            let rows = try store.db.query("""
                SELECT agent, model, cwd, SUM(input), SUM(cache_read), SUM(output),
                       SUM(CASE WHEN sub = 1 THEN input + cache_read + cache_write + output ELSE 0 END)
                FROM events WHERE day >= ? AND day <= ? GROUP BY agent, model, cwd
                """, [.text(s.startDay), .text(s.endDay)])
            XCTAssertEqual(s.totals.input, rows.reduce(0) { $0 + $1[3].int }, "\(r) 新输入", file: file, line: line)
            XCTAssertEqual(s.totals.cacheRead, rows.reduce(0) { $0 + $1[4].int }, "\(r) 缓存读", file: file, line: line)
            XCTAssertEqual(s.totals.output, rows.reduce(0) { $0 + $1[5].int }, "\(r) 输出", file: file, line: line)
            XCTAssertEqual(s.agents.reduce(0) { $0 + $1.subagentTokens }, rows.reduce(0) { $0 + $1[6].int }, "\(r) 子代理", file: file, line: line)
            XCTAssertEqual(Set(s.models.map { "\($0.agent.rawValue)/\($0.model)" }), Set(rows.map { "\($0[0].text)/\($0[1].text)" }),
                           "\(r) 模型", file: file, line: line)
            XCTAssertEqual(Set(s.projects.map(\.cwd)), Set(rows.map { $0[2].text }), "\(r) 项目", file: file, line: line)
            XCTAssertEqual(s.daily.reduce(0) { $0 + $1.total }, s.totals.total, "\(r) 每日合计", file: file, line: line)
        }
    }

    func testSnapshotMatchesEventsAcrossUpdates() throws {
        let store = try Store(path: dir.appendingPathComponent("t.db").path)
        let now = Time.isoFrac.date(from: "2026-11-22T12:00:00.000Z")!
        try store.upsert([
            event("a", .claude, "2026-11-22T01:00:00Z", output: 100),
            event("b", .claude, "2026-11-21T01:00:00Z", model: "claude-opus-5-5", cwd: "/p/b", sub: true, output: 50),
            event("c", .codex, "2026-11-10T01:00:00Z", model: "gpt-6.2-sol", output: 30),
            event("d", .deepseek, "2026-10-01T01:00:00Z", model: "unknown", cwd: "", output: 7),
        ])
        try assertMatchesEvents(store, now: now)
        XCTAssertEqual(try store.db.query("SELECT COUNT(*) FROM daily_dirty")[0][0].int, 0)   // 读过之后就干净了

        // 同键再来一次：输出变大、未知的模型和目录补上了（分组键变了）
        try store.upsert([
            event("a", .claude, "2026-11-22T01:00:30Z", output: 900),
            event("d", .deepseek, "2026-10-01T01:00:05Z", model: "deepseek-v4-pro", cwd: "/p/d", output: 7),
        ])
        try assertMatchesEvents(store, now: now)
        let all = try StatsEngine(store: store).snapshot(now: now).stats(.all)
        XCTAssertEqual(all.totals.output, 900 + 50 + 30 + 7)
        XCTAssertFalse(all.models.contains { $0.model == "unknown" })
    }

    /// 一条响应跨过零点：行里的 day 是第一行定的，后面的更新要记到那一天上。
    func testUpdateAfterMidnightRefreshesTheStoredDay() throws {
        let store = try Store(path: dir.appendingPathComponent("t.db").path)
        let before = Time.isoFrac.date(from: "2026-11-22T12:00:00.000Z")!
        // 找一个本地时间 23:59:50 的时刻，免得测试依赖时区
        let cal = Calendar.current
        let late = cal.date(bySettingHour: 23, minute: 59, second: 50, of: before)!
        let next = late.addingTimeInterval(30)
        let iso = ISO8601DateFormatter()
        try store.upsert([event("m", .claude, iso.string(from: late), output: 10)])
        _ = try StatsEngine(store: store).snapshot(now: next)
        try store.upsert([event("m", .claude, iso.string(from: next), output: 500)])
        try assertMatchesEvents(store, now: next)
        XCTAssertEqual(try store.db.query("SELECT SUM(output) FROM daily")[0][0].int, 500)
    }

    /// 只刷新实时部分时不重算范围统计，但今日合计和最近活动是新的。
    func testRefreshingLiveKeepsRangesAndUpdatesToday() throws {
        let store = try Store(path: dir.appendingPathComponent("t.db").path)
        let engine = StatsEngine(store: store)
        let now = Date()
        try store.upsert([UsageEvent(key: "x", agent: .claude, ts: Int64(now.timeIntervalSince1970 * 1000) - 5_000,
                                     model: "claude-sonnet-5-5", cwd: "/p", session: "s", input: 1, cacheRead: 0,
                                     cacheWrite: 0, output: 300, genMs: 3_000)])
        let full = try engine.snapshot(now: now)
        try store.upsert([UsageEvent(key: "y", agent: .claude, ts: Int64(now.timeIntervalSince1970 * 1000) - 1_000,
                                     model: "claude-sonnet-5-5", cwd: "/p", session: "s", input: 1, cacheRead: 0,
                                     cacheWrite: 0, output: 200, genMs: 2_000)])
        let live = try engine.refreshingLive(full, now: now)
        XCTAssertEqual(live.stats(.all).totals.output, 300)             // 范围统计沿用旧的
        XCTAssertEqual(live.live[.claude]?.today, 301 + 201)            // 今日合计是新的
        XCTAssertEqual(live.live[.claude]?.tokPerSec ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(try engine.snapshot(now: now).stats(.all).totals.output, 500)
    }

    /// 从 v4 升上来：汇总表按已有的 events 建好，不用重读日志（游标保留）。
    func testV4DatabaseBuildsRollupWithoutRereading() throws {
        let path = dir.appendingPathComponent("t.db").path
        do {
            let store = try Store(path: path)
            try store.upsert([event("a", .claude, "2026-11-22T01:00:00Z", output: 100)])
            try store.db.exec("""
                INSERT INTO cursors VALUES ('/some/file.jsonl', 'claude', 100, 0, 0, NULL);
                DROP TABLE daily; DROP TABLE daily_dirty; PRAGMA user_version = 4;
                """)
        }
        let store = try Store(path: path)
        XCTAssertEqual(store.db.userVersion, Store.schemaVersion)
        XCTAssertEqual(try store.allCursors().count, 1)
        let all = try StatsEngine(store: store).snapshot(now: Time.isoFrac.date(from: "2026-11-22T12:00:00.000Z")!).stats(.all)
        XCTAssertEqual(all.totals.output, 100)
    }

    /// 文件没有新内容时再导入一次，不往库里写任何东西。
    func testIngestOfUnchangedFileWritesNothing() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("claude/p"), withIntermediateDirectories: true)
        let store = try Store(path: dir.appendingPathComponent("t.db").path)
        let ing = Ingestor(store: store, sources: [LogSource(agent: .claude, roots: [dir.appendingPathComponent("claude")])])
        let file = dir.appendingPathComponent("claude/p/s.jsonl")
        try (#"{"type":"assistant","timestamp":"2026-11-22T01:00:04Z","requestId":"r","cwd":"/p/demo","message":{"id":"a","model":"claude-sonnet-5-5","usage":{"input_tokens":1,"output_tokens":5}}}"# + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ing.scanAll().events, 1)
        let changes = { try store.db.query("SELECT total_changes()")[0][0].int }
        let before = try changes()
        XCTAssertEqual(try ing.ingest(paths: [file.path]).events, 0)
        XCTAssertEqual(try ing.scanAll().filesRead, 0)
        XCTAssertEqual(try changes(), before)
    }
}
