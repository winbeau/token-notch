import XCTest
@testable import TokenCore

final class EditCountTests: XCTestCase {
    func testMaxOfAddedRemoved() {
        // +1−1 记 1 行
        XCTAssertEqual(EditCount.replace(old: "let a = 1", new: "let a = 2").lines, 1)
        // +7−5 与 +5−7 都记 7 行
        let five = (1...5).map { "old \($0)" }.joined(separator: "\n")
        let seven = (1...7).map { "new \($0)" }.joined(separator: "\n")
        XCTAssertEqual(EditCount.replace(old: five, new: seven), EditChange(added: 7, removed: 5, lines: 7))
        XCTAssertEqual(EditCount.replace(old: seven, new: five), EditChange(added: 5, removed: 7, lines: 7))
    }

    func testCommonContextLinesAreNotCounted() {
        let old = "a\nb\nc\nd\n"
        let new = "a\nB\nc\nd\nE\n"
        // 两处独立改动：b→B（+1−1 记 1）和末尾追加 E（+1 记 1），共 2 行
        XCTAssertEqual(EditCount.replace(old: old, new: new), EditChange(added: 2, removed: 1, lines: 2))
        // 中间夹着未改动的行：两段各记 max
        XCTAssertEqual(EditCount.replace(old: "1\n2\n3\nkeep\n5", new: "one\nkeep\nfive\nsix\nseven").lines, 3 + 3)
        XCTAssertEqual(EditCount.replace(old: "x", new: "x\ny").lines, 1)
        XCTAssertTrue(EditCount.replace(old: "same", new: "same").isEmpty)
    }

    func testWriteCountsAllLinesAdded() {
        XCTAssertEqual(EditCount.write("1\n2\n3\n"), EditChange(added: 3, removed: 0, lines: 3))
        XCTAssertEqual(EditCount.write("").lines, 0)
    }

    func testPatchSumsEachChangeBlock() {
        let patch = """
        *** Begin Patch
        *** Update File: a.swift
        @@ func a()
        -one
        -two
        +ONE
         keep
        +added
        *** Add File: b.swift
        +1
        +2
        +3
        *** End Patch
        """
        // 块 1：+1−2 → 2；块 2：+1 → 1；新文件：+3 → 3
        XCTAssertEqual(EditCount.patch(EditCount.patches(in: patch)[0]), EditChange(added: 5, removed: 2, lines: 6))
    }

    func testPatchesInsideEscapedJS() {
        let js = #"const r = await tools.apply_patch("*** Begin Patch\n*** Update File: x\n@@\n-a\n+b\n+c\n*** End Patch"); text(r)"#
        let found = EditCount.patches(in: js)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(EditCount.patch(found[0]).lines, 2)
    }
}

final class EditParserTests: XCTestCase {
    func line(_ s: String) -> Data { Data(s.utf8) }

    func testClaudeEditCountsOnlyAfterSuccessfulResult() {
        var p = ClaudeParser()
        var out = ParseOutput()
        let use = #"{"type":"assistant","timestamp":"2026-11-22T01:00:04.000Z","sessionId":"s","cwd":"/p/demo","requestId":"r","message":{"id":"m","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tu_ok","name":"Edit","input":{"file_path":"/p/demo/a","old_string":"a\nb","new_string":"a\nc\nd"}},{"type":"tool_use","id":"tu_bad","name":"Write","input":{"file_path":"/p/demo/b","content":"x\ny\n"}}],"usage":{"input_tokens":1,"output_tokens":2}}}"#
        p.consume(line: line(use), path: "/x.jsonl", into: &out)
        XCTAssertEqual(out.edits.count, 0)
        XCTAssertEqual(p.pending.count, 2)
        let result = #"{"type":"user","timestamp":"2026-11-22T01:00:05.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_ok","content":"ok"},{"type":"tool_result","tool_use_id":"tu_bad","is_error":true,"content":"denied"}]}}"#
        p.consume(line: line(result), path: "/x.jsonl", into: &out)
        XCTAssertEqual(out.edits.map(\.key), ["claude:tu_ok"])
        XCTAssertEqual(out.edits.first?.change, EditChange(added: 2, removed: 1, lines: 2))
        XCTAssertEqual(out.edits.first?.cwd, "/p/demo")
        XCTAssertTrue(p.pending.isEmpty)
    }

    func testCodexExecPatch() {
        var p = CodexParser()
        var out = ParseOutput()
        p.consume(line: line(#"{"type":"session_meta","timestamp":"2026-11-22T01:00:00Z","payload":{"id":"sess","cwd":"/p/cx"}}"#), path: "/r.jsonl", into: &out)
        let call = #"{"type":"response_item","timestamp":"2026-11-22T01:00:02Z","payload":{"type":"custom_tool_call","status":"completed","call_id":"c1","name":"exec","input":"text(await tools.apply_patch(`*** Begin Patch\n*** Update File: /p/cx/a\n@@\n-x\n+y\n*** Add File: /p/cx/b\n+1\n+2\n*** End Patch`))"}}"#
        p.consume(line: line(call), path: "/r.jsonl", into: &out)
        XCTAssertEqual(out.edits.count, 1)
        XCTAssertEqual(out.edits.first?.change.lines, 3)
        XCTAssertEqual(out.edits.first?.cwd, "/p/cx")
        XCTAssertEqual(out.edits.first?.key, "codex:sess:c1:0")
    }
}

final class MigrationTests: XCTestCase {
    func testV1DatabaseGetsEditsTableAndRereadsLogs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tn-mig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.db").path
        do {
            let db = try SQLiteDB(path: path)
            try db.exec("""
            CREATE TABLE events (key TEXT PRIMARY KEY, agent TEXT NOT NULL, ts INTEGER NOT NULL, day TEXT NOT NULL,
                model TEXT NOT NULL, cwd TEXT NOT NULL, session TEXT NOT NULL, sub INTEGER NOT NULL DEFAULT 0,
                input INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0,
                cache_write INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0, gen_ms INTEGER);
            CREATE TABLE cursors (path TEXT PRIMARY KEY, agent TEXT NOT NULL, offset INTEGER NOT NULL,
                fp INTEGER NOT NULL, mtime REAL NOT NULL, state BLOB);
            INSERT INTO cursors VALUES ('/some/file.jsonl', 'claude', 100, 0, 0, NULL);
            PRAGMA user_version = 1;
            """)
        }
        let store = try Store(path: path)
        XCTAssertEqual(store.db.userVersion, Store.schemaVersion)
        XCTAssertEqual(try store.allCursors().count, 0)
        XCTAssertEqual(try store.editCount(), 0)
    }
}

/// 新口径：覆盖写入按 diff 算，临时目录、agent 自己的目录、锁文件和生成物不计入。
final class EditRulesTests: XCTestCase {
    func line(_ s: String) -> Data { Data(s.utf8) }

    func testWhichFilesCount() {
        let home = "/Users/me"
        func counted(_ p: String, cwd: String = "") -> Bool { EditCount.isCounted(path: p, cwd: cwd, home: home) }
        XCTAssertTrue(counted("/Users/me/code/app/main.swift"))
        XCTAssertTrue(counted("README.md", cwd: "/Users/me/code/app"))
        XCTAssertTrue(counted("/Users/me/code/app/.claude/skills/x/SKILL.md"))   // 项目里的 .claude 照算
        XCTAssertFalse(counted("/tmp/probe.py"))
        XCTAssertFalse(counted("/private/tmp/claude-501/x/scratchpad/a.py"))
        XCTAssertFalse(counted("/var/folders/ab/T/x.txt"))
        XCTAssertFalse(counted("/Users/me/.claude/plans/plan.md"))
        XCTAssertFalse(counted("/Users/me/.gemini/antigravity/brain/s/scratch/a.h"))
        XCTAssertFalse(counted("~/.dsh/notes.md"))
        XCTAssertFalse(counted("a.py", cwd: "/tmp/work"))
        XCTAssertFalse(counted("/Users/me/code/app/package-lock.json"))
        XCTAssertFalse(counted("/Users/me/code/app/Cargo.lock"))
        XCTAssertFalse(counted("/Users/me/code/app/web/app.min.js"))
        XCTAssertFalse(counted("/Users/me/code/app/node_modules/x/index.js"))
        XCTAssertFalse(counted(".build/debug/x.swift", cwd: "/Users/me/code/app"))
    }

    func testDiffSplitsChangesAtUnchangedLines() {
        // 30 行里改第 3 行、在第 20 行后插 2 行：两处改动，1 + 2
        let old = (1...30).map { "line \($0)" }
        var new = old
        new[2] = "changed"
        new.insert(contentsOf: ["a", "b"], at: 20)
        XCTAssertEqual(EditCount.replace(old: old.joined(separator: "\n"), new: new.joined(separator: "\n")),
                       EditChange(added: 3, removed: 1, lines: 3))
        // 整个删掉一半：一处改动，记删除的行数
        XCTAssertEqual(EditCount.replace(old: old.joined(separator: "\n"), new: old.prefix(15).joined(separator: "\n")).lines, 15)
    }

    func testHunkAndPatchFilter() {
        XCTAssertEqual(EditCount.hunk([" ctx", "-a", "+b", "+c", " ctx", "+d"]), EditChange(added: 3, removed: 1, lines: 3))
        let patch = "*** Update File: src/a.swift\n@@\n-x\n+y\n*** Add File: /tmp/scratch.py\n+1\n+2\n+3\n*** Add File: package-lock.json\n+{}\n"
        XCTAssertEqual(EditCount.patch(patch).lines, 5)
        XCTAssertEqual(EditCount.patch(patch) { EditCount.isCounted(path: $0, cwd: "/Users/me/app", home: "/Users/me") }.lines, 1)
    }

    /// Claude：覆盖已有文件只算改动的行；replace_all 以结果里的 diff 为准；临时目录里的不算。
    func testClaudeOverwriteUsesResultDiff() {
        var p = ClaudeParser()
        var out = ParseOutput()
        let content = (1...100).map { "l\($0)" }.joined(separator: "\\n")
        let use = #"{"type":"assistant","timestamp":"2026-11-22T01:00:04.000Z","sessionId":"s","cwd":"/p/demo","requestId":"r","message":{"id":"m","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"w1","name":"Write","input":{"file_path":"/p/demo/big.txt","content":"\#(content)"}},{"type":"tool_use","id":"w2","name":"Write","input":{"file_path":"/p/demo/new.txt","content":"a\nb\nc\n"}},{"type":"tool_use","id":"e1","name":"Edit","input":{"file_path":"/p/demo/c.txt","old_string":"foo","new_string":"bar","replace_all":true}},{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"/tmp/x.py","content":"1\n2\n"}}],"usage":{"input_tokens":1,"output_tokens":2}}}"#
        p.consume(line: line(use), path: "/x.jsonl", into: &out)
        XCTAssertEqual(Set(p.pending.keys), ["w1", "w2", "e1"])   // /tmp 下的不记

        // 覆盖：100 行的文件只改了 2 行
        p.consume(line: line(#"{"type":"user","timestamp":"2026-11-22T01:00:05.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"w1","content":"ok"}]},"toolUseResult":{"type":"update","filePath":"/p/demo/big.txt","content":"…","originalFile":"…","structuredPatch":[{"oldStart":1,"lines":[" l1","-old2","+l2"," l3"]},{"oldStart":50,"lines":["-old50","+l50"]}]}}"#), path: "/x.jsonl", into: &out)
        // 新建：结果里没有 diff，按全部行数
        p.consume(line: line(#"{"type":"user","timestamp":"2026-11-22T01:00:06.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"w2","content":"ok"}]},"toolUseResult":{"type":"create","filePath":"/p/demo/new.txt","content":"a\nb\nc\n","structuredPatch":[],"originalFile":null}}"#), path: "/x.jsonl", into: &out)
        // replace_all：实际替换了 3 处
        p.consume(line: line(#"{"type":"user","timestamp":"2026-11-22T01:00:07.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"e1","content":"ok"}]},"toolUseResult":{"filePath":"/p/demo/c.txt","oldString":"foo","newString":"bar","replaceAll":true,"structuredPatch":[{"lines":["-foo","+bar"," x","-foo","+bar"]},{"lines":["-foo","+bar"]}]}}"#), path: "/x.jsonl", into: &out)
        XCTAssertEqual(out.edits.map(\.key), ["claude:w1", "claude:w2", "claude:e1"])
        XCTAssertEqual(out.edits.map(\.change.lines), [2, 3, 3])
    }

    /// Claude：结果里没有 structuredPatch 但有原文件时，自己对原文件做 diff。
    func testClaudeOverwriteFallsBackToOriginalFile() {
        var p = ClaudeParser()
        var out = ParseOutput()
        p.consume(line: line(#"{"type":"assistant","timestamp":"2026-11-22T01:00:04.000Z","sessionId":"s","cwd":"/p/demo","requestId":"r","message":{"id":"m","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"w1","name":"Write","input":{"file_path":"/p/demo/a.txt","content":"1\n2\nX\n4\n"}}],"usage":{"input_tokens":1,"output_tokens":2}}}"#), path: "/x.jsonl", into: &out)
        p.consume(line: line(#"{"type":"user","timestamp":"2026-11-22T01:00:05.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"w1","content":"ok"}]},"toolUseResult":{"type":"update","filePath":"/p/demo/a.txt","content":"1\n2\nX\n4\n","originalFile":"1\n2\n3\n4\n"}}"#), path: "/x.jsonl", into: &out)
        XCTAssertEqual(out.edits.first?.change, EditChange(added: 1, removed: 1, lines: 1))
    }

    /// DeepSeek：write 覆盖已有文件时按结果 meta 里的新旧文本算。
    func testDeepSeekOverwriteUsesMetaDiffs() {
        var p = DeepSeekParser()
        var out = ParseOutput()
        let lines = [
            #"{"type":"session","id":"session-1","cwd":"/p/dsh"}"#,
            #"{"type":"tool/call","seq":1,"time":1791612182139,"data":{"turn":1,"step":1,"callId":"c1","name":"write","arguments":"{\"file_path\":\"/p/dsh/big.md\",\"content\":\"1\\n2\\n3\\n4\\n5\\n6\\n7\\n8\\n\"}"}}"#,
            #"{"type":"tool/call","seq":2,"time":1791612182140,"data":{"turn":1,"step":1,"callId":"c2","name":"write","arguments":"{\"file_path\":\"/tmp/s.sh\",\"content\":\"1\\n2\\n\"}"}}"#,
            #"{"type":"tool/result","seq":3,"time":1791612182141,"data":{"turn":1,"step":1,"message":{"role":"tool","toolCallId":"c1","isError":false},"meta":{"operation":"update","diffs":[{"path":"/p/dsh/big.md","oldText":"1\nold\n3","newText":"1\n2\n3"},{"path":"/p/dsh/big.md","oldText":"7","newText":"7\n8"}]}}}"#,
            #"{"type":"tool/result","seq":4,"time":1791612182142,"data":{"turn":1,"step":1,"message":{"role":"tool","toolCallId":"c2","isError":false},"meta":{"operation":"create","diffs":[]}}}"#,
        ]
        for l in lines { p.consume(line: line(l), path: "/s/session-1/session.v4.jsonl.zstd", into: &out) }
        XCTAssertEqual(out.edits.map(\.key), ["deepseek:session-1:c1"])   // /tmp 下的 c2 不算
        XCTAssertEqual(out.edits.first?.change.lines, 2)
    }

    /// Antigravity：读过或写过的文件再覆盖时只算改动的行；没见过的按新建；草稿目录不算。
    func testAntigravityOverwriteDiffsAgainstKnownContent() {
        var p = AntigravityParser()
        var out = ParseOutput()
        let path = "/r/brain/sess/.system_generated/logs/transcript_full.jsonl"
        func step(_ i: Int, _ calls: String) {
            p.consume(line: line(#"{"step_index":\#(i),"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-18T04:36:42Z","input_tokens":10,"output_tokens":5,"tool_calls":[\#(calls)]}"#), path: path, into: &out)
        }
        func result(_ i: Int, _ content: String) {
            p.consume(line: line(#"{"step_index":\#(i),"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-11-18T04:36:43Z","content":"\#(content)"}"#), path: path, into: &out)
        }
        // 读 /p/a.h（5 行），然后整文件重写，只改第 3 行并在末尾加一行
        step(1, #"{"name":"read_file","args":{"Path":"/p/a.h"}}"#)
        result(2, #"Created At: x\nCompleted At: y\nShowing lines 1-5 of 5\n1: a\n2: b\n3: c\n4: \n5: e"#)
        step(3, #"{"name":"write_file","args":{"Path":"/p/a.h","Overwrite":true,"Content":"a\nb\nC\n\ne\nf\n"}}"#)
        // 再改写一遍：和刚写的只差一行
        step(5, #"{"name":"write_file","args":{"Path":"/p/a.h","Overwrite":true,"Content":"a\nb\nC\n\nE\nf\n"}}"#)
        // 没见过的文件按新建；草稿目录里的不算
        step(7, #"{"name":"write_file","args":{"Path":"/p/new.h","Overwrite":true,"Content":"1\n2\n3\n"}},{"name":"write_file","args":{"Path":"\#(NSHomeDirectory())/.gemini/antigravity/brain/sess/scratch/x.h","Overwrite":true,"Content":"1\n2\n"}}"#)
        // 整行的 edit 会更新记着的内容：之后重写成同样的内容就没有改动
        step(10, #"{"name":"edit_file","args":{"Path":"/p/new.h","Target":"2","Replacement":"two\n2.5"}}"#)
        step(12, #"{"name":"write_file","args":{"Path":"/p/new.h","Overwrite":true,"Content":"1\ntwo\n2.5\n3\n"}}"#)
        // 分段读的结果不能当成全文
        step(14, #"{"name":"read_file","args":{"Path":"/p/part.h"}}"#)
        result(15, #"Partial read (lines 1-380 of 380). Showing bytes 0-10 of 100 in this line range.\n1: a"#)
        step(16, #"{"name":"write_file","args":{"Path":"/p/part.h","Overwrite":true,"Content":"a\nb\n"}}"#)

        XCTAssertEqual(out.edits.map(\.key), ["antigravity:sess:3:0", "antigravity:sess:5:0", "antigravity:sess:7:0",
                                              "antigravity:sess:10:0", "antigravity:sess:16:0"])
        XCTAssertEqual(out.edits.map(\.change.lines), [1 + 1, 1, 3, 2, 2])
    }

    /// 解析器状态要存进游标：存取一遍之后记着的文件内容还在。
    func testAntigravityStateSurvivesEncoding() throws {
        var p = AntigravityParser()
        var out = ParseOutput()
        let path = "/r/brain/sess/.system_generated/logs/transcript_full.jsonl"
        p.consume(line: line(#"{"step_index":1,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-18T04:36:42Z","tool_calls":[{"name":"write_file","args":{"Path":"/p/a","Content":"1\n2\n3\n"}}]}"#), path: path, into: &out)
        var q = try JSONDecoder().decode(AntigravityParser.self, from: JSONEncoder().encode(p))
        q.consume(line: line(#"{"step_index":3,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-18T04:37:42Z","tool_calls":[{"name":"write_file","args":{"Path":"/p/a","Content":"1\n2\n3\n4\n"}}]}"#), path: path, into: &out)
        XCTAssertEqual(out.edits.map(\.change.lines), [3, 1])
    }

    func testV3DatabaseDropsEditsAndRereadsLogs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tn-mig4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.db").path
        do {
            let store = try Store(path: path)
            try store.db.exec("""
            INSERT INTO events (key, agent, ts, day, model, cwd, session) VALUES ('e1', 'claude', 1, '2026-11-22', 'm', '/p', 's');
            INSERT INTO edits (key, agent, ts, day, cwd, session, added, removed, lines) VALUES ('x', 'claude', 1, '2026-11-22', '/p', 's', 900, 0, 900);
            INSERT INTO cursors VALUES ('/some/file.jsonl', 'claude', 100, 0, 0, NULL);
            PRAGMA user_version = 3;
            """)
        }
        let store = try Store(path: path)
        XCTAssertEqual(store.db.userVersion, Store.schemaVersion)
        XCTAssertEqual(try store.editCount(), 0)
        XCTAssertEqual(try store.allCursors().count, 0)
        XCTAssertEqual(try store.db.query("SELECT COUNT(*) FROM events").first?.first?.int, 1)   // 用量记录保留
    }
}
