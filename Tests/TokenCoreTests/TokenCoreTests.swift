import XCTest
@testable import TokenCore

final class ParserTests: XCTestCase {
    func line(_ s: String) -> Data { Data(s.utf8) }

    func testClaudeDedupKeyAndGenTime() {
        var p = ClaudeParser()
        XCTAssertNil(p.consume(line: line(#"{"type":"user","timestamp":"2026-11-22T01:00:00.000Z","message":{"role":"user"}}"#), path: "/x/a.jsonl"))
        let a = #"{"type":"assistant","timestamp":"2026-11-22T01:00:04.000Z","requestId":"req1","sessionId":"s1","cwd":"/p/demo","isSidechain":false,"message":{"id":"msg1","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":400}}}"#
        let e = p.consume(line: line(a), path: "/x/a.jsonl")
        XCTAssertEqual(e?.key, "claude:msg1:req1")
        XCTAssertEqual(e?.total, 1502)
        XCTAssertEqual(e?.genMs, 4000)
        XCTAssertEqual(e?.cwd, "/p/demo")
        // 同一响应的第二行：同键
        XCTAssertEqual(p.consume(line: line(a), path: "/x/a.jsonl")?.key, "claude:msg1:req1")
    }

    func testClaudeSkipsSyntheticAndEmpty() {
        var p = ClaudeParser()
        let syn = #"{"type":"assistant","timestamp":"2026-11-22T01:00:04Z","message":{"id":"m","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#
        XCTAssertNil(p.consume(line: line(syn), path: "/x"))
    }

    func testCodexCumulativeDiff() {
        var p = CodexParser()
        _ = p.consume(line: line(#"{"type":"session_meta","timestamp":"2026-11-22T01:00:00Z","payload":{"id":"sess","cwd":"/p/codexproj"}}"#), path: "/r.jsonl")
        _ = p.consume(line: line(#"{"type":"turn_context","timestamp":"2026-11-22T01:00:00Z","payload":{"model":"gpt-6.2-sol","cwd":"/p/codexproj"}}"#), path: "/r.jsonl")
        _ = p.consume(line: line(#"{"type":"event_msg","timestamp":"2026-11-22T01:00:01Z","payload":{"type":"user_message"}}"#), path: "/r.jsonl")
        let t1 = #"{"type":"event_msg","timestamp":"2026-11-22T01:00:03Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50}}}}"#
        let e1 = p.consume(line: line(t1), path: "/r.jsonl")
        XCTAssertEqual(e1?.input, 200)
        XCTAssertEqual(e1?.cacheRead, 800)
        XCTAssertEqual(e1?.output, 50)
        XCTAssertEqual(e1?.genMs, 2000)
        XCTAssertEqual(e1?.model, "gpt-6.2-sol")
        // 重复的累计值不产出事件
        XCTAssertNil(p.consume(line: line(t1), path: "/r.jsonl"))
        let t2 = #"{"type":"event_msg","timestamp":"2026-11-22T01:00:05Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2500,"cached_input_tokens":2000,"output_tokens":80}}}}"#
        let e2 = p.consume(line: line(t2), path: "/r.jsonl")
        XCTAssertEqual(e2?.input, 300)
        XCTAssertEqual(e2?.cacheRead, 1200)
        XCTAssertEqual(e2?.output, 30)
        // info 为空的 token_count 忽略
        XCTAssertNil(p.consume(line: line(#"{"type":"event_msg","timestamp":"2026-11-22T01:00:06Z","payload":{"type":"token_count","info":null}}"#), path: "/r.jsonl"))
    }
}

final class IngestTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("claude/p"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("codex"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func assistant(_ id: String, out: Int, ts: String = "2026-11-22T01:00:04Z") -> String {
        #"{"type":"assistant","timestamp":"\#(ts)","requestId":"r\#(id)","cwd":"/p/demo","message":{"id":"\#(id)","model":"claude-sonnet-5-5","usage":{"input_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":0,"output_tokens":\#(out)}}}"#
    }

    func testIncrementalAppendHalfLineAndRewrite() throws {
        let store = try Store(path: dir.appendingPathComponent("t.db").path)
        let ing = Ingestor(store: store, sources: [LogSource(agent: .claude, roots: [dir.appendingPathComponent("claude")])])
        let file = dir.appendingPathComponent("claude/p/s.jsonl")

        try (assistant("a", out: 5) + "\n" + assistant("a", out: 5) + "\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ing.scanAll().events, 2)
        XCTAssertEqual(try store.eventCount(), 1)               // 同键去重

        // 追加一行半：只读完整的那一行
        let fh = try FileHandle(forWritingTo: file)
        try fh.seekToEnd()
        let next = assistant("b", out: 7)
        try fh.write(contentsOf: Data((next + "\n" + next.prefix(20)).utf8))
        XCTAssertEqual(try ing.ingest(paths: [file.path]).events, 1)
        XCTAssertEqual(try store.eventCount(), 2)
        // 补完半行
        try fh.write(contentsOf: Data((next.dropFirst(20) + "\n").utf8))
        try fh.close()
        _ = try ing.ingest(paths: [file.path])
        XCTAssertEqual(try store.eventCount(), 2)               // b 重复，仍是 2 条

        // 文件被改写成更短的内容：从头重读，不重复计数
        try (assistant("c", out: 9) + "\n").write(to: file, atomically: true, encoding: .utf8)
        _ = try ing.scanAll()
        XCTAssertEqual(try store.eventCount(), 3)

        let snap = try StatsEngine(store: store).snapshot(now: Time.isoFrac.date(from: "2026-11-22T12:00:00.000Z")!)
        let all = snap.stats(.all)
        XCTAssertEqual(all.totals.output, 5 + 7 + 9)
        XCTAssertEqual(all.projects.first?.name, "demo")
        XCTAssertGreaterThan(all.totals.cost, 0)
    }
}

final class PricingFormatTests: XCTestCase {
    func testLookup() {
        let p = Pricing()
        XCTAssertEqual(p.price(for: "claude-opus-5-5")?.output, 20)
        XCTAssertEqual(p.price(for: "claude-opus-4-5-20251101")?.input, 5)     // 去日期后缀
        XCTAssertEqual(p.price(for: "claude-opus-4-1-20250805")?.input, 15)
        XCTAssertNil(p.price(for: "mystery-model"))
    }

    func testFormat() {
        XCTAssertEqual(TokenFormat.compact(90_700_000), "90.7M")
        XCTAssertEqual(TokenFormat.compact(1_880_000_000), "1.88B")
        XCTAssertEqual(TokenFormat.compact(939_000_000), "939M")
        XCTAssertEqual(TokenFormat.modelName("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(TokenFormat.modelName("gpt-6.2-sol"), "GPT-6.2 Sol")
        XCTAssertEqual(TokenFormat.modelName("claude-sonnet-4-5-20250929"), "Sonnet 4.5")
    }

    func testFastTimestampMatchesFormatter() {
        for s in ["2026-11-22T01:00:04.082Z", "2026-02-28T23:59:59Z", "2024-02-29T12:00:00.5Z", "1999-12-31T00:00:00.123456Z"] {
            let slow = Time.isoFrac.date(from: s) ?? Time.iso.date(from: s)
            XCTAssertEqual(Time.fastUTC(s), slow.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }, s)
        }
        XCTAssertNil(Time.fastUTC("2026-11-22T01:00:04+08:00"))
    }

    func testDisplayNamesDisambiguate() {
        let n = StatsEngine.displayNames(for: ["/a/zh", "/b/zh", "/c/demo"])
        XCTAssertEqual(n["/a/zh"], "a/zh")
        XCTAssertEqual(n["/c/demo"], "demo")
    }
}
