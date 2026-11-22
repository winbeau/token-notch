import Foundation

/// 增量解析器：逐行喂日志，必要时产出一条用量事件。
/// 解析器本身就是要持久化的状态（Codable），这样下次从字节游标处接着读时，
/// 上下文（会话 ID、模型、上一轮累计值等）不会丢。
protocol LogParser: Codable {
    init()
    mutating func consume(line: Data, path: String) -> UsageEvent?
}

// MARK: - 工具

private func bytes(_ s: String) -> Data { Data(s.utf8) }

/// memmem 比 Data.range(of:) 快一个量级；工具结果行可能有几 MB。
private func contains(_ line: Data, _ needle: Data) -> Bool {
    line.withUnsafeBytes { h in
        needle.withUnsafeBytes { n in
            memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil
        }
    }
}

private func json(_ line: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
}

private func int(_ v: Any?) -> Int64 {
    (v as? NSNumber)?.int64Value ?? 0
}

/// 不做完整 JSON 解析，直接取 `"timestamp":"..."` 的值（用户行可能很大，比如工具结果）。
private func quickTimestamp(_ line: Data) -> Int64? {
    let key = bytes("\"timestamp\":\"")
    guard let r = line.range(of: key) else { return nil }
    let start = r.upperBound
    guard let end = line[start...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
    return Time.parseMs(String(decoding: line[start..<end], as: UTF8.self))
}

/// 两次时间戳之差落在 (0, 10 分钟] 才当作响应耗时，否则视为未知。
private func plausibleGap(_ ts: Int64, since: Int64?) -> Int64? {
    guard let since else { return nil }
    let d = ts - since
    return (d > 0 && d <= 600_000) ? d : nil
}

// MARK: - Claude Code：~/.claude/projects/**/*.jsonl

/// 每条 assistant 行带 `message.usage`；同一响应按内容块拆成多行，usage 相同，
/// 用 `message.id + requestId` 去重。`input_tokens` 本身就是新输入（不含缓存）。
struct ClaudeParser: LogParser {
    var lastUserTs: Int64?

    private static let usageKey = bytes("\"usage\"")
    private static let userType = bytes("\"type\":\"user\"")

    init() {}

    mutating func consume(line: Data, path: String) -> UsageEvent? {
        guard contains(line, Self.usageKey) else {
            if contains(line, Self.userType), let ts = quickTimestamp(line) { lastUserTs = ts }
            return nil
        }
        guard let obj = json(line), let type = obj["type"] as? String else { return nil }
        let ts = (obj["timestamp"] as? String).flatMap(Time.parseMs)
        if type == "user" {
            if let ts { lastUserTs = ts }
            return nil
        }
        guard type == "assistant", let ts,
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { return nil }
        let model = (msg["model"] as? String) ?? "unknown"
        if model == "<synthetic>" { return nil }

        let input = int(usage["input_tokens"])
        let cacheRead = int(usage["cache_read_input_tokens"])
        let cacheWrite = int(usage["cache_creation_input_tokens"])
        let output = int(usage["output_tokens"])
        guard input + cacheRead + cacheWrite + output > 0 else { return nil }

        let id = (msg["id"] as? String) ?? (obj["uuid"] as? String) ?? "\(ts)"
        let req = (obj["requestId"] as? String) ?? ""
        let sub = (obj["isSidechain"] as? Bool) ?? path.contains("/subagents/")
        return UsageEvent(
            key: "claude:\(id):\(req)",
            agent: .claude,
            ts: ts,
            model: model,
            cwd: (obj["cwd"] as? String) ?? "",
            session: (obj["sessionId"] as? String) ?? "",
            isSubagent: sub,
            input: input,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            output: output,
            genMs: plausibleGap(ts, since: lastUserTs)
        )
    }
}

// MARK: - Codex：~/.codex/sessions/**/rollout-*.jsonl

/// `token_count` 事件给的是会话**累计**用量，这里取与上一次的差值。
/// Codex 的 `input_tokens` 含缓存命中部分，新输入 = input − cached；没有缓存写。
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

    private static let markers = ["session_meta", "turn_context", "token_count", "user_message"].map(bytes)

    init() {}

    mutating func consume(line: Data, path: String) -> UsageEvent? {
        guard Self.markers.contains(where: { contains(line, $0) }),
              let obj = json(line) else { return nil }
        let type = obj["type"] as? String
        let payload = obj["payload"] as? [String: Any] ?? [:]
        let ts = (obj["timestamp"] as? String).flatMap(Time.parseMs)

        if type == "session_meta" {
            session = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? session
            cwd = (payload["cwd"] as? String) ?? cwd
            return nil
        }
        if type == "turn_context" {
            model = (payload["model"] as? String) ?? model
            cwd = (payload["cwd"] as? String) ?? cwd
            return nil
        }
        switch payload["type"] as? String {
        case "user_message":
            if let ts { lastMarkTs = ts }
            return nil
        case "token_count":
            break
        default:
            return nil
        }
        guard let ts,
              let info = payload["info"] as? [String: Any],
              let tot = info["total_token_usage"] as? [String: Any] else { return nil }

        let cur = Cumulative(input: int(tot["input_tokens"]),
                             cached: int(tot["cached_input_tokens"]),
                             output: int(tot["output_tokens"]))
        var d = Cumulative(input: cur.input - prev.input,
                           cached: cur.cached - prev.cached,
                           output: cur.output - prev.output)
        if d.input < 0 || d.cached < 0 || d.output < 0 { d = cur }   // 累计值被重置
        prev = cur
        guard d.input + d.output > 0 else { return nil }

        let gen = plausibleGap(ts, since: lastMarkTs)
        lastMarkTs = ts
        let sid = session.isEmpty ? path : session
        return UsageEvent(
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
        )
    }
}
