import Foundation

/// 一批日志行解析出来的东西：用量事件和代码编辑。
struct ParseOutput {
    var events: [UsageEvent] = []
    var edits: [EditEvent] = []
}

/// 增量解析器：逐行喂日志，往 `out` 里追加用量事件和编辑。
/// 解析器本身就是要持久化的状态（Codable），这样下次从字节游标处接着读时，
/// 上下文（会话 ID、模型、上一轮累计值、待确认的编辑等）不会丢。
protocol LogParser: Codable {
    init()
    mutating func consume(line: Data, path: String, into out: inout ParseOutput)
    /// 一批行解析完后的补充（例如去旁边的数据库查模型、项目目录）。默认什么也不做。
    static func enrich(_ out: inout ParseOutput, path: String)
}

extension LogParser {
    static func enrich(_ out: inout ParseOutput, path: String) {}

    /// 测试用：喂一行，返回这一行产出的最后一条用量事件。
    mutating func consume(line: Data, path: String) -> UsageEvent? {
        var out = ParseOutput()
        consume(line: line, path: path, into: &out)
        return out.events.last
    }
}

// MARK: - 工具

func bytes(_ s: String) -> Data { Data(s.utf8) }

/// memmem 比 Data.range(of:) 快一个量级；工具结果行可能有几 MB。
func lineContains(_ line: Data, _ needle: Data) -> Bool {
    line.withUnsafeBytes { h in
        needle.withUnsafeBytes { n in
            memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil
        }
    }
}

func parseJSON(_ line: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
}

func toInt64(_ v: Any?) -> Int64 {
    (v as? NSNumber)?.int64Value ?? 0
}

/// 不做完整 JSON 解析，直接取 `"timestamp":"..."` 的值（用户行可能很大，比如工具结果）。
func quickTimestamp(_ line: Data) -> Int64? {
    let key = bytes("\"timestamp\":\"")
    guard let r = line.range(of: key) else { return nil }
    let start = r.upperBound
    guard let end = line[start...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
    return Time.parseMs(String(decoding: line[start..<end], as: UTF8.self))
}

/// 两次时间戳之差落在 (0, 10 分钟] 才当作响应耗时，否则视为未知。
func plausibleGap(_ ts: Int64, since: Int64?) -> Int64? {
    guard let since else { return nil }
    let d = ts - since
    return (d > 0 && d <= 600_000) ? d : nil
}

/// 工具调用发出后先记着，等工具结果回来、确认没出错再算进编辑行数（被拒绝、匹配失败的编辑不算）。
struct PendingEdit: Codable, Equatable {
    var ts: Int64
    var cwd: String
    var session: String
    var change: EditChange
}

extension Dictionary where Key == String, Value == PendingEdit {
    /// 会话中断时结果永远不会回来；留个上限，避免状态无限增长。
    mutating func cap(_ n: Int = 256) {
        guard count > n else { return }
        for k in sorted(by: { $0.value.ts < $1.value.ts }).prefix(count - n).map(\.key) {
            removeValue(forKey: k)
        }
    }
}

// MARK: - Claude Code：~/.claude/projects/**/*.jsonl

/// 每条 assistant 行带 `message.usage`；同一响应按内容块拆成多行，usage 相同，
/// 用 `message.id + requestId` 去重。`input_tokens` 本身就是新输入（不含缓存）。
/// 编辑来自 assistant 行里的 `tool_use`（Edit / MultiEdit / Write），等对应的 `tool_result` 没报错才算。
struct ClaudeParser: LogParser {
    var lastUserTs: Int64?
    var pending: [String: PendingEdit] = [:]

    private static let usageKey = bytes("\"usage\"")
    private static let userType = bytes("\"type\":\"user\"")
    private static let toolResult = bytes("tool_result")
    private static let toolUse = bytes("\"tool_use\"")

    init() {}

    mutating func consume(line: Data, path: String, into out: inout ParseOutput) {
        guard lineContains(line, Self.usageKey) || lineContains(line, Self.toolUse) else {
            guard lineContains(line, Self.userType) else { return }
            if let ts = quickTimestamp(line) { lastUserTs = ts }
            resolvePending(line: line, obj: nil, into: &out)
            return
        }
        guard let obj = parseJSON(line), let type = obj["type"] as? String else { return }
        let ts = (obj["timestamp"] as? String).flatMap(Time.parseMs)
        if type == "user" {
            if let ts { lastUserTs = ts }
            resolvePending(line: line, obj: obj, into: &out)
            return
        }
        guard type == "assistant", let ts,
              let msg = obj["message"] as? [String: Any] else { return }
        let cwd = (obj["cwd"] as? String) ?? ""
        let session = (obj["sessionId"] as? String) ?? ""
        collectEdits(msg["content"], ts: ts, cwd: cwd, session: session)

        guard let usage = msg["usage"] as? [String: Any] else { return }
        let model = (msg["model"] as? String) ?? "unknown"
        if model == "<synthetic>" { return }

        let input = toInt64(usage["input_tokens"])
        let cacheRead = toInt64(usage["cache_read_input_tokens"])
        let cacheWrite = toInt64(usage["cache_creation_input_tokens"])
        let output = toInt64(usage["output_tokens"])
        guard input + cacheRead + cacheWrite + output > 0 else { return }

        let id = (msg["id"] as? String) ?? (obj["uuid"] as? String) ?? "\(ts)"
        let req = (obj["requestId"] as? String) ?? ""
        let sub = (obj["isSidechain"] as? Bool) ?? path.contains("/subagents/")
        out.events.append(UsageEvent(
            key: "claude:\(id):\(req)",
            agent: .claude,
            ts: ts,
            model: model,
            cwd: cwd,
            session: session,
            isSubagent: sub,
            input: input,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            output: output,
            genMs: plausibleGap(ts, since: lastUserTs)
        ))
    }

    private mutating func collectEdits(_ content: Any?, ts: Int64, cwd: String, session: String) {
        guard let blocks = content as? [[String: Any]] else { return }
        for b in blocks where b["type"] as? String == "tool_use" {
            guard let id = b["id"] as? String, let input = b["input"] as? [String: Any] else { continue }
            var change = EditChange()
            switch b["name"] as? String {
            case "Edit":
                change = EditCount.replace(old: input["old_string"] as? String ?? "", new: input["new_string"] as? String ?? "")
            case "MultiEdit":
                for e in input["edits"] as? [[String: Any]] ?? [] {
                    change += EditCount.replace(old: e["old_string"] as? String ?? "", new: e["new_string"] as? String ?? "")
                }
            case "Write":
                change = EditCount.write(input["content"] as? String ?? "")
            default:
                continue
            }
            if !change.isEmpty {
                pending[id] = PendingEdit(ts: ts, cwd: cwd, session: session, change: change)
            }
        }
        pending.cap()
    }

    /// user 行里的 tool_result：对上待确认的编辑就结算。只有行里确实出现了待确认的 id 才做完整解析。
    private mutating func resolvePending(line: Data, obj: [String: Any]?, into out: inout ParseOutput) {
        guard !pending.isEmpty, lineContains(line, Self.toolResult),
              pending.keys.contains(where: { lineContains(line, bytes($0)) }),
              let obj = obj ?? parseJSON(line),
              let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
        for b in blocks where b["type"] as? String == "tool_result" {
            guard let id = b["tool_use_id"] as? String, let p = pending.removeValue(forKey: id) else { continue }
            if (b["is_error"] as? Bool) == true { continue }
            out.edits.append(EditEvent(key: "claude:\(id)", agent: .claude, ts: p.ts, cwd: p.cwd,
                                       session: p.session, change: p.change))
        }
    }
}

// MARK: - Codex：~/.codex/sessions/**/rollout-*.jsonl

/// `token_count` 事件给的是会话**累计**用量，这里取与上一次的差值。
/// Codex 的 `input_tokens` 含缓存命中部分，新输入 = input − cached；没有缓存写。
/// 编辑来自 apply_patch 补丁：旧版是独立的 apply_patch 工具，新版包在 exec 的 JS 代码里，
/// 这里不区分，直接在工具调用的参数里找 `*** Begin Patch` 块。
struct CodexParser: LogParser {
    struct Cumulative: Codable, Equatable {
        var input: Int64 = 0
        var cached: Int64 = 0
        var output: Int64 = 0
    }

    var session = ""
    var model = "unknown"
    var cwd = ""
    var prev = Cumulative()
    var lastMarkTs: Int64?

    private static let markers = ["session_meta", "turn_context", "token_count", "user_message", "Begin Patch"].map(bytes)

    init() {}

    mutating func consume(line: Data, path: String, into out: inout ParseOutput) {
        guard Self.markers.contains(where: { lineContains(line, $0) }),
              let obj = parseJSON(line) else { return }
        let type = obj["type"] as? String
        let payload = obj["payload"] as? [String: Any] ?? [:]
        let ts = (obj["timestamp"] as? String).flatMap(Time.parseMs)

        if type == "session_meta" {
            session = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? session
            cwd = (payload["cwd"] as? String) ?? cwd
            return
        }
        if type == "turn_context" {
            model = (payload["model"] as? String) ?? model
            cwd = (payload["cwd"] as? String) ?? cwd
            return
        }
        switch payload["type"] as? String {
        case "user_message":
            if let ts { lastMarkTs = ts }
            return
        case "token_count":
            break
        case "function_call", "custom_tool_call":
            collectPatches(payload, ts: ts, path: path, into: &out)
            return
        default:
            return
        }
        guard let ts,
              let info = payload["info"] as? [String: Any],
              let tot = info["total_token_usage"] as? [String: Any] else { return }

        let cur = Cumulative(input: toInt64(tot["input_tokens"]),
                             cached: toInt64(tot["cached_input_tokens"]),
                             output: toInt64(tot["output_tokens"]))
        var d = Cumulative(input: cur.input - prev.input,
                           cached: cur.cached - prev.cached,
                           output: cur.output - prev.output)
        if d.input < 0 || d.cached < 0 || d.output < 0 { d = cur }   // 累计值被重置
        prev = cur
        guard d.input + d.output > 0 else { return }

        let gen = plausibleGap(ts, since: lastMarkTs)
        lastMarkTs = ts
        let sid = session.isEmpty ? path : session
        out.events.append(UsageEvent(
            key: "codex:\(sid):\(cur.input):\(cur.output)",
            agent: .codex,
            ts: ts,
            model: model,
            cwd: cwd,
            session: sid,
            input: max(0, d.input - d.cached),
            cacheRead: d.cached,
            cacheWrite: 0,
            output: d.output,
            genMs: gen
        ))
    }

    private func collectPatches(_ payload: [String: Any], ts: Int64?, path: String, into out: inout ParseOutput) {
        guard let ts else { return }
        if let status = payload["status"] as? String, status != "completed" { return }
        let text = [payload["input"], payload["arguments"]].compactMap { $0 as? String }.joined(separator: "\n")
        let callId = (payload["call_id"] as? String) ?? (payload["id"] as? String) ?? "\(ts)"
        let sid = session.isEmpty ? path : session
        for (i, patch) in EditCount.patches(in: text).enumerated() {
            let change = EditCount.patch(patch)
            guard !change.isEmpty else { continue }
            out.edits.append(EditEvent(key: "codex:\(sid):\(callId):\(i)", agent: .codex, ts: ts,
                                       cwd: cwd, session: sid, change: change))
        }
    }
}
