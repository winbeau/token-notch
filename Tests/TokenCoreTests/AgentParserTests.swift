import XCTest
@testable import TokenCore

/// protobuf 编码小工具（只为测试造数据）。
private enum PB {
    static func varint(_ v: UInt64) -> [UInt8] {
        var v = v, out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }
    static func field(_ n: Int, varint v: UInt64) -> [UInt8] { varint(UInt64(n << 3)) + varint(v) }
    static func field(_ n: Int, bytes b: [UInt8]) -> [UInt8] { varint(UInt64(n << 3 | 2)) + varint(UInt64(b.count)) + b }
    static func field(_ n: Int, string s: String) -> [UInt8] { field(n, bytes: Array(s.utf8)) }
}

final class AgentParserTests: XCTestCase {
    func line(_ s: String) -> Data { Data(s.utf8) }

    // MARK: Antigravity

    func testAntigravityModelSelectionAndEdits() {
        var p = AntigravityParser()
        var out = ParseOutput()
        let path = "/r/brain/sess-1/.system_generated/logs/transcript_full.jsonl"
        p.consume(line: line(#"{"step_index":0,"type":"USER_INPUT","status":"DONE","created_at":"2026-11-18T04:36:30Z","content":"The user changed setting `Model Selection` from None to Gemini 3.8 Flash (High). No need to comment."}"#), path: path, into: &out)
        p.consume(line: line(#"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"RUNNING","created_at":"2026-11-18T04:36:40Z","input_tokens":5,"cache_read_tokens":0,"output_tokens":1}"#), path: path, into: &out)
        XCTAssertTrue(out.events.isEmpty)   // 未完成的步骤不算
        p.consume(line: line(#"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-18T04:36:42Z","input_tokens":18175,"cache_read_tokens":100,"output_tokens":1335,"tool_calls":[{"name":"edit_file","args":{"Path":"/p/a","Target":"x\ny","Replacement":"x\nz\nw"}},{"name":"write_file","args":{"Path":"/p/b","Content":"1\n2\n3"}},{"name":"read_file","args":{}}]}"#), path: path, into: &out)
        XCTAssertEqual(out.events.count, 1)
        let e = out.events[0]
        XCTAssertEqual(e.key, "antigravity:sess-1:1")
        XCTAssertEqual(e.model, "gemini-3.8-flash-high")
        XCTAssertEqual(e.input, 18175)
        XCTAssertEqual(e.cacheRead, 100)
        XCTAssertEqual(e.genMs, 2000)
        XCTAssertEqual(out.edits.map(\.change.lines), [2, 3])
        XCTAssertNotNil(Pricing().price(for: e.model))   // 带档位的 ID 按前缀计价
    }

    func testAntigravityModelID() {
        XCTAssertEqual(AntigravityParser.modelID("Gemini 4 Argon (High)"), "gemini-4-argon-high")
        XCTAssertEqual(AntigravityParser.modelID("gemini-4-carbon"), "gemini-4-carbon")
        XCTAssertEqual(AntigravityParser.modelFromSettingsChange("changed setting `Model Selection` from Gemini 4 Argon (High) to Gemini 4 Carbon (High). No need"), "Gemini 4 Carbon (High)")
        XCTAssertNil(AntigravityParser.modelFromSettingsChange("`Model Selection` from X to None. ok"))
    }

    func testAntigravityNativeModelsCwdAndTiming() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tn-agy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sub-1"
        let logs = dir.appendingPathComponent("brain/\(sid)/.system_generated/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("conversations"), withIntermediateDirectories: true)
        // 子代理会话：没有 Model Selection，模型只在原生库里
        try (#"{"step_index":3,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-18T04:36:42Z","input_tokens":10,"cache_read_tokens":90,"output_tokens":5}"# + "\n")
            .write(to: logs.appendingPathComponent("transcript_full.jsonl"), atomically: true, encoding: .utf8)
        do {
            let db = try SQLiteDB(path: dir.appendingPathComponent("conversations/\(sid).db").path)
            try db.exec("CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, metadata BLOB); CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB);")
            let meta = PB.field(20, bytes: PB.field(3, varint: 7))
            let duration = { (s: UInt64, ns: UInt64) in PB.field(1, varint: s) + PB.field(2, varint: ns) }
            let resp = PB.field(19, string: "gemini-pro-orchestrator") + PB.field(21, string: "orchestrator-carbon")
                + PB.field(11, bytes: duration(1, 500_000_000)) + PB.field(12, bytes: duration(3, 0))
            try db.run("INSERT INTO steps VALUES (3, 15, ?)", [.blob(Data(meta))])
            try db.run("INSERT INTO gen_metadata VALUES (7, ?)", [.blob(Data(PB.field(1, bytes: resp)))])
            let sum = try SQLiteDB(path: dir.appendingPathComponent("conversation_summaries.db").path)
            try sum.exec("CREATE TABLE conversation_summaries (conversation_id TEXT, workspace_uris TEXT, parent_conversation_id TEXT)")
            try sum.run("INSERT INTO conversation_summaries VALUES (?, ?, ?)",
                        [.text(sid), .text(#"["file:///Users/me/My%20Proj"]"#), .text("parent")])
        }
        let store = try Store(path: dir.appendingPathComponent("t.db").path)
        let ing = Ingestor(store: store, sources: [LogSource(agent: .antigravity, roots: [dir.appendingPathComponent("brain")],
                                                             match: .named("transcript_full.jsonl"))])
        XCTAssertEqual(try ing.scanAll().events, 1)
        let r = try store.db.query("SELECT model, cwd, sub, gen_ms FROM events").first!
        XCTAssertEqual(r[0].text, "gemini-4-carbon")      // Orchestrator 别名换成实际模型
        XCTAssertEqual(r[1].text, "/Users/me/My Proj")
        XCTAssertEqual(r[2].int, 1)
        XCTAssertEqual(r[3].int, 4500)
    }

    // MARK: Grok

    func testGrokTurnCompletedPerModel() {
        var p = GrokParser()
        var out = ParseOutput()
        let path = "/h/.grok/sessions/%2FUsers%2Fme%2Fproj/01abc/updates.jsonl"
        let l = #"{"timestamp": 1793786524, "method": "_x.ai/session/update", "params": {"sessionId": "01abc", "update": {"sessionUpdate": "turn_completed", "prompt_id": "p1", "usage": {"inputTokens": 59901, "outputTokens": 1864, "cachedReadTokens": 43392, "cacheCreationTokens": 0, "modelUsage": {"grok-4.7": {"inputTokens": 59901, "outputTokens": 1864, "cachedReadTokens": 43392, "cacheCreationTokens": 0, "apiDurationMs": 24182}}}}, "_meta": {"eventId": "01abc-220", "agentTimestampMs": 1793786524735}}}"#
        p.consume(line: line(l), path: path, into: &out)
        XCTAssertEqual(out.events.count, 1)
        let e = out.events[0]
        XCTAssertEqual(e.key, "grok:01abc:01abc-220:grok-4.7")
        XCTAssertEqual(e.input, 59901 - 43392)
        XCTAssertEqual(e.cacheRead, 43392)
        XCTAssertEqual(e.total, 59901 + 1864)
        XCTAssertEqual(e.ts, 1793786524735)
        XCTAssertEqual(e.genMs, 24182)
        XCTAssertEqual(e.cwd, "/Users/me/proj")
        // 其他 sessionUpdate 不产出
        p.consume(line: line(#"{"params":{"update":{"sessionUpdate":"agent_message_chunk"}}}"#), path: path, into: &out)
        XCTAssertEqual(out.events.count, 1)
    }

    // MARK: DeepSeek Harness

    func testDeepSeekUsageAndEdits() {
        var p = DeepSeekParser()
        var out = ParseOutput()
        let path = "/h/.dsh/sessions/--p--/session-1/session.v4.jsonl.zstd"
        for l in [
            #"{"type":"session","version":4,"id":"session-1","createdAt":1,"cwd":"/p/dsh","delegationDepth":1}"#,
            #"{"type":"step/start","seq":13,"time":1791612178031,"data":{"turn":1,"step":1}}"#,
            #"{"type":"assistant/message","seq":26,"time":1791612182137,"data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"id":"m1","source":{"kind":"model","provider":"deepseek-official","model":"deepseek-flash"}},"usage":{"inputTokens":1895,"outputTokens":561,"cacheReadTokens":8704,"cacheWriteTokens":0,"totalTokens":11160},"stream":[{"type":"chunk","time":1}]}}"#,
            #"{"type":"tool/call","seq":27,"time":1791612182138,"data":{"turn":1,"step":1,"callId":"c1","name":"edit","arguments":"{\"file_path\":\"/p/dsh/a\",\"old_string\":\"a\",\"new_string\":\"b\\nc\"}"}}"#,
            #"{"type":"tool/call","seq":28,"time":1791612182139,"data":{"turn":1,"step":1,"callId":"c2","name":"write","arguments":"{\"file_path\":\"/p/dsh/b\",\"content\":\"1\\n2\\n\"}"}}"#,
            #"{"type":"tool/result","seq":29,"time":1791612182152,"data":{"message":{"role":"tool","toolCallId":"c1","content":[],"isError":false}}}"#,
            #"{"type":"tool/result","seq":30,"time":1791612182153,"data":{"message":{"role":"tool","toolCallId":"c2","content":[],"isError":true}}}"#,
        ] {
            p.consume(line: line(l), path: path, into: &out)
        }
        XCTAssertEqual(out.events.count, 1)
        let e = out.events[0]
        XCTAssertEqual(e.key, "deepseek:session-1:m1")
        XCTAssertEqual(e.model, "deepseek-flash")
        XCTAssertEqual(e.total, 11160)
        XCTAssertEqual(e.genMs, 1791612182137 - 1791612178031)
        XCTAssertTrue(e.isSubagent)
        XCTAssertEqual(e.cwd, "/p/dsh")
        XCTAssertEqual(out.edits.map(\.key), ["deepseek:session-1:c1"])   // c2 报错不算
        XCTAssertEqual(out.edits.first?.change.lines, 2)
    }

    func testDeepSeekAssistantFallsBackToFullParse() {
        // stream 不是最后一个键时，截断解析失败，退回整行解析
        let l = #"{"type":"assistant/message","time":5,"data":{"stream":[],"x":{"a":1},"message":{"id":"m"},"usage":{"inputTokens":1}}}"#
        XCTAssertEqual((DeepSeekParser.parseAssistant(Data(l.utf8))?["data"] as? [String: Any])?["usage"] as? [String: Int], ["inputTokens": 1])
    }

    // MARK: zstd / protobuf

    func testZstdFramesAndIncrementalIngest() throws {
        guard let exe = Zstd.executable else { throw XCTSkip("本机没有 zstd") }
        func compress(_ s: String) throws -> Data {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["-cq"]
            let i = Pipe(), o = Pipe()
            p.standardInput = i
            p.standardOutput = o
            try p.run()
            try i.fileHandleForWriting.write(contentsOf: Data(s.utf8))
            try i.fileHandleForWriting.close()
            let d = o.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return d
        }
        let msg = { (id: String) in
            #"{"type":"assistant/message","time":1791612182137,"data":{"turn":1,"step":1,"message":{"id":"\#(id)","source":{"model":"deepseek-flash"}},"usage":{"inputTokens":1,"outputTokens":2,"cacheReadTokens":3,"cacheWriteTokens":0},"stream":[]}}"# + "\n"
        }
        let f1 = try compress(#"{"type":"session","id":"s","cwd":"/p","delegationDepth":0}"# + "\n" + msg("a"))
        let f2 = try compress(msg("b"))
        XCTAssertEqual(Zstd.completeFramesLength(f1 + f2), f1.count + f2.count)
        XCTAssertEqual(Zstd.completeFramesLength(f1 + f2.prefix(f2.count - 3)), f1.count)   // 半帧不算

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tn-dsh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sess = dir.appendingPathComponent("sessions/--p--/s")
        try FileManager.default.createDirectory(at: sess, withIntermediateDirectories: true)
        let file = sess.appendingPathComponent("session.v4.jsonl.zstd")
        try (f1 + f2.prefix(5)).write(to: file)
        let store = try Store(path: dir.appendingPathComponent("t.db").path)
        let ing = Ingestor(store: store, sources: [LogSource(agent: .deepseek, roots: [dir.appendingPathComponent("sessions")], match: .dshSession)])
        XCTAssertEqual(try ing.scanAll().events, 1)
        try (f1 + f2).write(to: file)   // 第二帧写完
        XCTAssertEqual(try ing.ingest(paths: [file.path]).events, 1)
        XCTAssertEqual(try store.eventCount(), 2)
        let r = try store.db.query("SELECT cwd FROM events WHERE key = 'deepseek:s:b'").first
        XCTAssertEqual(r?[0].text, "/p")    // 会话信息随游标状态保留
    }

    func testProtoReader() {
        let msg = PB.field(1, varint: 300) + PB.field(2, string: "hi") + PB.field(3, bytes: PB.field(4, varint: 9))
        let b = msg[...]
        XCTAssertEqual(Proto.varint(b, 1), 300)
        XCTAssertEqual(Proto.string(b, 2), "hi")
        XCTAssertEqual(Proto.message(b, 3).flatMap { Proto.varint($0, 4) }, 9)
        XCTAssertNil(Proto.string(b, 5))
        XCTAssertTrue(Proto.fields([0xFF][...]).isEmpty)   // 坏数据不崩
    }

    func testModelNames() {
        XCTAssertEqual(TokenFormat.modelName("gemini-4-carbon-high"), "Gemini 4 Carbon High")
        XCTAssertEqual(TokenFormat.modelName("grok-4.7"), "Grok 4.7")
        XCTAssertEqual(TokenFormat.modelName("deepseek-v4-pro"), "DeepSeek V4 Pro")
    }
}
