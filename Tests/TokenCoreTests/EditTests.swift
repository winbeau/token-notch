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
