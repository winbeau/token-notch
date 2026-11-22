import Foundation

// 新增 agent 的日志解析。格式参考 cc-switch（MIT）的 session_usage_agy.rs /
// session_usage_grokbuild.rs / session_usage_dsh.rs，并在本机日志上核对过。

/// 用 memmem 在一行里取 `"key":"value"` 的字符串值，不做完整 JSON 解析。
func quickString(_ line: Data, _ key: String) -> String? {
    let needle = bytes("\"\(key)\":\"")
    return line.withUnsafeBytes { (h: UnsafeRawBufferPointer) -> String? in
        guard let base = h.baseAddress,
              let hit = needle.withUnsafeBytes({ memmem(base, h.count, $0.baseAddress, $0.count) }) else { return nil }
        let start = base.distance(to: UnsafeRawPointer(hit)) + needle.count
        guard start < h.count, let q = memchr(base + start, 0x22, h.count - start) else { return nil }
        let end = base.distance(to: UnsafeRawPointer(q))
        return String(decoding: UnsafeRawBufferPointer(rebasing: h[start..<end]), as: UTF8.self)
    }
}

// MARK: - Antigravity（Gemini）：~/.gemini/antigravity/brain/<会话>/.system_generated/logs/transcript_full.jsonl

/// 每个步骤一行（同一步骤可能被改写多次，按 step_index 去重）。`PLANNER_RESPONSE` 且 `DONE` 的步骤带
/// 精确的 token 计数；`input_tokens` 是新输入（不含缓存读）。
///
/// 模型：transcript 里一般没有。按优先级取
/// 1. 同目录上两级 `conversations/<会话>.db` 原生库：步骤元数据 → 生成记录 → 模型 ID（protobuf，见 enrich）；
/// 2. 会话正文里的 `changed setting \`Model Selection\` from X to Y`（显示名，换成 ID）；
/// 3. 都没有记 unknown，不猜。
/// 项目目录与是否子代理来自 `conversation_summaries.db`。编辑来自 `edit_file` / `write_file` 工具调用。
///
/// `write_file` 不区分新建和覆盖，日志里也没有原文件。为了让覆盖只算改动的行，这里记着会话里每个文件
/// 最后一次已知的内容（只存每行的哈希）：之前写入的、`read_file` 完整读到的、`edit_file` 改过之后的。
/// 覆盖时拿它做 diff；从没见过的文件按新建算。
struct AntigravityParser: LogParser {
    var selectedModel: String?
    var lastStepTs: Int64?
    /// 路径 → 已知内容的行哈希（UInt32 依次拼成的字节）
    var known: [String: Data] = [:]
    /// `known` 的新旧顺序，超出上限时丢最旧的
    var knownOrder: [String] = []
    /// 还没回来的 `read_file`：结果所在的步骤号 → 路径
    var pendingReads: [Int: String] = [:]

    private static let markers = ["PLANNER_RESPONSE", "Model Selection"].map(bytes)
    private static let generic = bytes("GENERIC")
    static let knownLimit = 256
    static let maxTrackedLines = 20_000

    init() {}

    static func session(of path: String) -> String {
        // …/brain/<会话>/.system_generated/logs/transcript_full.jsonl
        let parts = path.split(separator: "/")
        return parts.count >= 4 ? String(parts[parts.count - 4]) : path
    }

    mutating func consume(line: Data, path: String, into out: inout ParseOutput) {
        let stepTs = quickString(line, "created_at").flatMap(Time.parseMs)
        defer { if let stepTs { lastStepTs = stepTs } }
        if !pendingReads.isEmpty, lineContains(line, Self.generic), let obj = parseJSON(line),
           obj["type"] as? String == "GENERIC", let step = (obj["step_index"] as? NSNumber)?.intValue,
           let path = pendingReads.removeValue(forKey: step) {
            if let lines = (obj["content"] as? String).flatMap(Self.fullRead) { remember(path, lines) }
            return
        }
        guard Self.markers.contains(where: { lineContains(line, $0) }), let obj = parseJSON(line) else { return }
        let type = obj["type"] as? String
        if type == "USER_INPUT" {
            if let m = (obj["content"] as? String).flatMap(Self.modelFromSettingsChange) { selectedModel = m }
            return
        }
        guard type == "PLANNER_RESPONSE", obj["status"] as? String == "DONE",
              let step = (obj["step_index"] as? NSNumber)?.intValue, let ts = stepTs else { return }
        let session = Self.session(of: path)

        let input = toInt64(obj["input_tokens"])
        let cacheRead = toInt64(obj["cache_read_tokens"])
        let cacheWrite = toInt64(obj["cache_write_tokens"])
        let output = toInt64(obj["output_tokens"])
        if input + cacheRead + cacheWrite + output > 0 {
            let explicit = (obj["model"] as? String).flatMap { $0.isEmpty || $0.lowercased() == "unknown" ? nil : $0 }
            out.events.append(UsageEvent(
                key: "antigravity:\(session):\(step)", agent: .antigravity, ts: ts,
                model: (explicit ?? selectedModel).map(Self.modelID) ?? "unknown",
                cwd: "", session: session,
                input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output,
                genMs: plausibleGap(ts, since: lastStepTs)))
        }

        pendingReads = [:]
        for (i, call) in ((obj["tool_calls"] as? [[String: Any]]) ?? []).enumerated() {
            let args = call["args"] as? [String: Any] ?? [:]
            let name = call["name"] as? String
            if name == "run_command" {
                out.images += ImageCalls.events(in: args["CommandLine"] as? String ?? "",
                                                keyPrefix: "antigravity:\(session):\(step):\(i)", agent: .antigravity,
                                                ts: ts, cwd: "", session: session)
                continue
            }
            let path = args["Path"] as? String ?? args["TargetFile"] as? String ?? args["AbsolutePath"] as? String ?? ""
            // 不计入的文件（agent 的草稿目录等）连内容也不用记
            guard EditCount.isCounted(path: path) else { continue }
            var change = EditChange()
            switch name {
            case "read_file":
                // 每个工具调用的结果依次落在后面的步骤里
                if !path.isEmpty { pendingReads[step + 1 + i] = path }
                continue
            case "edit_file", "replace_file_content":
                let old = args["Target"] as? String ?? args["TargetContent"] as? String ?? ""
                let new = args["Replacement"] as? String ?? args["ReplacementContent"] as? String ?? ""
                change = EditCount.replace(old: old, new: new)
                applyEdit(path, old: old, new: new)
            case "multi_replace_file_content":
                for c in args["ReplacementChunks"] as? [[String: Any]] ?? [] {
                    let old = c["TargetContent"] as? String ?? "", new = c["ReplacementContent"] as? String ?? ""
                    change += EditCount.replace(old: old, new: new)
                    applyEdit(path, old: old, new: new)
                }
            case "write_file", "write_to_file":
                let content = args["Content"] as? String ?? args["CodeContent"] as? String ?? ""
                let lines = EditCount.hashes(content)
                let before = known[path].map(Self.unpack)
                if Self.isTrue(args["Append"]) {
                    change = EditCount.write(content)
                    if let before { remember(path, before + lines) }
                } else {
                    change = before.map { EditCount.diff($0, lines) } ?? EditCount.write(content)
                    remember(path, lines)
                }
            default:
                continue
            }
            if !change.isEmpty {
                out.edits.append(EditEvent(key: "antigravity:\(session):\(step):\(i)", agent: .antigravity,
                                           ts: ts, cwd: "", session: session, change: change))
            }
        }
    }

    // MARK: 已知的文件内容

    static func isTrue(_ v: Any?) -> Bool {
        (v as? Bool) ?? ((v as? String)?.lowercased() == "true")
    }

    static func pack(_ lines: [UInt32]) -> Data {
        lines.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func unpack(_ data: Data) -> [UInt32] {
        [UInt32](unsafeUninitializedCapacity: data.count / 4) { buf, n in
            n = data.copyBytes(to: buf) / 4
        }
    }

    private mutating func remember(_ path: String, _ lines: [UInt32]) {
        knownOrder.removeAll { $0 == path }
        guard !path.isEmpty, lines.count <= Self.maxTrackedLines else {
            known[path] = nil
            return
        }
        known[path] = Self.pack(lines)
        knownOrder.append(path)
        while knownOrder.count > Self.knownLimit { known[knownOrder.removeFirst()] = nil }
    }

    /// 把一次字符串替换应用到记着的内容上。只有被替换的部分正好是整行时才对得上；
    /// 对不上就留着旧内容不动——之后覆盖时最多把这次改的几行再算一遍，比当成全新文件准得多。
    private mutating func applyEdit(_ path: String, old: String, new: String) {
        guard let data = known[path] else { return }
        let lines = Self.unpack(data), target = EditCount.hashes(old)
        guard !target.isEmpty, target.count <= lines.count else { return }
        for start in 0...(lines.count - target.count) where lines[start] == target[0] {
            if Array(lines[start..<(start + target.count)]) == target {
                remember(path, Array(lines[..<start]) + EditCount.hashes(new) + Array(lines[(start + target.count)...]))
                return
            }
        }
    }

    /// `read_file` 的结果：`…\nShowing lines 1-59 of 59\n1: 第一行\n2: 第二行…`。只认读完整个文件的；
    /// 分段读、按字节偏移读的返回 nil。
    static func fullRead(_ content: String) -> [UInt32]? {
        guard let r = content.range(of: "\nShowing lines 1-") else { return nil }
        let rest = content[r.upperBound...]
        guard let nl = rest.firstIndex(of: "\n") else { return nil }
        let counts = rest[..<nl].components(separatedBy: " of ")
        guard counts.count == 2, let n = Int(counts[0]), n == Int(counts[1]), n > 0, n <= maxTrackedLines else { return nil }
        var out: [UInt32] = []
        out.reserveCapacity(n)
        for line in rest[rest.index(after: nl)...].split(separator: "\n", omittingEmptySubsequences: false) {
            if out.count == n { break }
            let prefix = "\(out.count + 1):"
            guard line.hasPrefix(prefix) else { return nil }
            var text = line.dropFirst(prefix.count)
            if text.first == " " { text = text.dropFirst() }
            out.append(EditCount.hash(text))
        }
        return out.count == n ? out : nil
    }

    /// `changed setting \`Model Selection\` from X to Gemini 3.8 Flash (High). …` → 显示名。
    static func modelFromSettingsChange(_ content: String) -> String? {
        guard let r = content.range(of: "Model Selection") else { return nil }
        let rest = content[r.upperBound...]
        guard let to = rest.range(of: " to ") else { return nil }
        let tail = rest[to.upperBound...]
        // 模型名里本身有点（Gemini 3.8），只把「句号 + 空格」、换行、反引号当成结束
        let end = [tail.range(of: ". ")?.lowerBound, tail.firstIndex(of: "\n"), tail.firstIndex(of: "`")]
            .compactMap { $0 }.min() ?? tail.endIndex
        let m = tail[..<end].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return m.isEmpty || m.lowercased() == "none" ? nil : m
    }

    /// 显示名 → 定价表用的 ID：`Gemini 3.8 Flash (High)` → `gemini-3.8-flash-high`。已经是 ID 的原样返回。
    static func modelID(_ display: String) -> String {
        guard display.contains(" ") else { return display }
        return display.lowercased()
            .replacingOccurrences(of: " (", with: "-")
            .replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    /// Orchestrator 模式的原生别名只代表模式，换成实际干活的模型（与 cc-switch 一致）。
    static let orchestratorWorkers: [String: String] = [
        "gemini-pro-orchestrator": "gemini-4-carbon",
        "gemini-pro-orchestrator-argon": "gemini-4-argon",
        "gemini-pro-orchestrator-g1-pro": "gemini-4-argon",
        "gemini-pro-orchestrator-neon": "gemini-4-neon",
        "gemini-flash-worker-agy": "gemini-4-hydrogen",
    ]

    static func enrich(_ out: inout ParseOutput, path: String) {
        guard !out.events.isEmpty || !out.edits.isEmpty || !out.images.isEmpty else { return }
        let session = session(of: path)
        // …/<根>/brain/<会话>/.system_generated/logs/transcript_full.jsonl
        let root = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        var cwd = "", isSub = false
        if let db = try? SQLiteDB(readOnly: root.appendingPathComponent("conversation_summaries.db").path),
           let r = try? db.query("SELECT workspace_uris, parent_conversation_id FROM conversation_summaries WHERE conversation_id = ?",
                                 [.text(session)]).first {
            if let d = r[0].text.data(using: .utf8), let uris = try? JSONSerialization.jsonObject(with: d) as? [String],
               let first = uris.first, let u = URL(string: first), u.isFileURL {
                cwd = u.path
            }
            isSub = !r[1].text.isEmpty
        }

        var native: [Int: (model: String?, ms: Int64?)] = [:]
        if let db = try? SQLiteDB(readOnly: root.appendingPathComponent("conversations/\(session).db").path) {
            for e in out.events {
                guard let step = e.key.split(separator: ":").last.flatMap({ Int($0) }),
                      let meta = try? db.query("SELECT metadata FROM steps WHERE idx = ? AND step_type = 15", [.int(Int64(step))]).first?[0].data,
                      let ref = Proto.message([UInt8](meta)[...], 20) else { continue }
                let gen = Int64(Proto.varint(ref, 3) ?? 0)
                guard let data = try? db.query("SELECT data FROM gen_metadata WHERE idx = ?", [.int(gen)]).first?[0].data,
                      let resp = Proto.message([UInt8](data)[...], 1) else { continue }
                let base = Proto.string(resp, 19)
                let worker = base.flatMap { orchestratorWorkers[$0] }
                var tiered = Proto.string(resp, 21)
                if worker != nil, let t = tiered.map(modelID),
                   t.contains("orchestrator") || t == "gemini-flash" || t == "gemini-flash-worker-agy" {
                    tiered = nil
                }
                let model = [tiered, worker, base].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty && $0.lowercased() != "unknown" }
                var ms: Int64?
                if let first = Proto.message(resp, 11), let stream = Proto.message(resp, 12) {
                    let v = Proto.durationMs(first) + Proto.durationMs(stream)
                    if v > 0 { ms = v }
                }
                native[step] = (model.map(modelID), ms)
            }
        }

        for i in out.events.indices {
            out.events[i].cwd = cwd
            out.events[i].isSubagent = isSub
            if let step = out.events[i].key.split(separator: ":").last.flatMap({ Int($0) }), let n = native[step] {
                if let m = n.model { out.events[i].model = m }
                if let ms = n.ms { out.events[i].genMs = ms }
            }
        }
        for i in out.edits.indices { out.edits[i].cwd = cwd }
        for i in out.images.indices { out.images[i].cwd = cwd }
    }
}

// MARK: - Grok：~/.grok/sessions/<编码后的项目目录>/<会话>/updates.jsonl

/// 每轮对话结束时有一条 `turn_completed`，`usage` 是**这一轮**的独立总量（不是累计），
/// `modelUsage` 按模型拆分。xAI 口径的 `inputTokens` 含缓存命中，入库前拆成新输入 + 缓存读。
/// `apiDurationMs` 是真实的 API 耗时，直接当生成耗时。
/// 本机样本里没有编辑类工具调用，Grok 暂不统计编辑行数。
struct GrokParser: LogParser {
    private static let marker = bytes("turn_completed")

    init() {}

    mutating func consume(line: Data, path: String, into out: inout ParseOutput) {
        guard lineContains(line, Self.marker), let obj = parseJSON(line),
              let params = obj["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "turn_completed",
              let usage = update["usage"] as? [String: Any] else { return }
        let meta = (params["_meta"] as? [String: Any]) ?? (update["_meta"] as? [String: Any]) ?? [:]
        let ts: Int64
        if let ms = meta["agentTimestampMs"] as? NSNumber {
            ts = ms.int64Value
        } else if let secs = obj["timestamp"] as? NSNumber {
            ts = Int64(secs.doubleValue * 1000)
        } else if let s = obj["timestamp"] as? String, let v = Time.parseMs(s) {
            ts = v
        } else {
            return
        }
        let session = (params["sessionId"] as? String) ?? URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        let turn = (meta["eventId"] as? String) ?? (update["prompt_id"] as? String) ?? "\(ts)"
        let cwd = Self.cwd(of: path)

        var perModel = (usage["modelUsage"] as? [String: [String: Any]]) ?? [:]
        if perModel.isEmpty { perModel = ["unknown": usage] }
        for (model, u) in perModel.sorted(by: { $0.key < $1.key }) {
            let cacheRead = toInt64(u["cachedReadTokens"])
            let cacheWrite = toInt64(u["cacheCreationTokens"])
            let output = toInt64(u["outputTokens"])
            let input = max(0, toInt64(u["inputTokens"]) - cacheRead - cacheWrite)
            guard input + cacheRead + cacheWrite + output > 0 else { continue }
            let api = toInt64(u["apiDurationMs"])
            out.events.append(UsageEvent(
                key: "grok:\(session):\(turn):\(model)", agent: .grok, ts: ts, model: model,
                cwd: cwd, session: session, input: input, cacheRead: cacheRead, cacheWrite: cacheWrite,
                output: output, genMs: api > 0 ? api : nil))
        }
    }

    /// 目录名是百分号编码的项目路径：`%2FUsers%2Fme%2Fproj` → `/Users/me/proj`。
    static func cwd(of path: String) -> String {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        return dir.removingPercentEncoding ?? dir
    }

    /// 没有按模型拆分时，用会话摘要里的当前模型补上。
    static func enrich(_ out: inout ParseOutput, path: String) {
        guard out.events.contains(where: { $0.model == "unknown" }) else { return }
        let summary = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("summary.json")
        guard let d = try? Data(contentsOf: summary), let obj = parseJSON(d),
              let model = obj["current_model_id"] as? String, !model.isEmpty else { return }
        for i in out.events.indices where out.events[i].model == "unknown" { out.events[i].model = model }
    }
}

// MARK: - DeepSeek Harness：~/.dsh/sessions/<项目>/<会话>/session.v4.jsonl.zstd

/// 用量挂在 `assistant/message` 上；三种 token 互不重叠，`inputTokens` 就是新输入。
/// 生成耗时按同一步 `step/start` 到 `assistant/message` 的间隔估算。
/// 编辑来自 `tool/call` 的 `edit` / `write`，对应的 `tool/result` 没报错才算。
/// `write` 覆盖已有文件时，结果的 `meta`（`operation: update`）带着逐段的新旧文本，按它算改动的行。
struct DeepSeekParser: LogParser {
    var session = ""
    var cwd = ""
    var isSub = false
    var stepStart: [String: Int64] = [:]
    var pending: [String: PendingEdit] = [:]

    private static let markers = ["\"type\":\"session\"", "\"type\":\"step/start\"", "\"type\":\"assistant/message\"",
                                  "\"type\":\"tool/call\"", "\"type\":\"tool/result\""].map(bytes)
    private static let toolResult = bytes("\"type\":\"tool/result\"")
    private static let assistant = bytes("\"type\":\"assistant/message\"")
    private static let streamKey = bytes(",\"stream\":")

    init() {}

    /// assistant/message 行的大头是最后的 `stream`（逐块时间戳），用量在它前面。
    /// 截到 `,"stream":` 补上两个右括号再解析，快一个量级；截出来不是合法 JSON 就退回整行解析。
    static func parseAssistant(_ line: Data) -> [String: Any]? {
        let cut = line.withUnsafeBytes { h in
            streamKey.withUnsafeBytes { n -> Int? in
                guard let base = h.baseAddress, let hit = memmem(base, h.count, n.baseAddress, n.count) else { return nil }
                return base.distance(to: UnsafeRawPointer(hit))
            }
        }
        if let cut {
            var head = Data(line.prefix(cut))
            head.append(contentsOf: Array("}}".utf8))
            if let obj = parseJSON(head) { return obj }
        }
        return parseJSON(line)
    }

    mutating func consume(line: Data, path: String, into out: inout ParseOutput) {
        guard Self.markers.contains(where: { lineContains(line, $0) }) else { return }
        // 工具结果可能很大，只有带着待确认编辑的 id 才解析
        if lineContains(line, Self.toolResult),
           pending.isEmpty || !pending.keys.contains(where: { lineContains(line, bytes($0)) }) { return }
        let parsed = lineContains(line, Self.assistant) ? Self.parseAssistant(line) : parseJSON(line)
        guard let obj = parsed, let type = obj["type"] as? String else { return }
        let data = obj["data"] as? [String: Any] ?? [:]
        let ts = toInt64(obj["time"])
        let stepKey = "\(toInt64(data["turn"])):\(toInt64(data["step"]))"
        if session.isEmpty {
            session = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        }

        switch type {
        case "session":
            session = (obj["id"] as? String) ?? session
            cwd = (obj["cwd"] as? String) ?? cwd
            isSub = toInt64(obj["delegationDepth"]) > 0
        case "step/start":
            stepStart = [stepKey: ts]
        case "assistant/message":
            guard let usage = data["usage"] as? [String: Any], ts > 0 else { return }
            let msg = data["message"] as? [String: Any] ?? [:]
            let source = msg["source"] as? [String: Any] ?? [:]
            let input = toInt64(usage["inputTokens"])
            let cacheRead = toInt64(usage["cacheReadTokens"])
            let cacheWrite = toInt64(usage["cacheWriteTokens"])
            let output = toInt64(usage["outputTokens"])
            guard input + cacheRead + cacheWrite + output > 0 else { return }
            let id = (msg["id"] as? String) ?? "\(stepKey):\(obj["seq"] ?? ts)"
            out.events.append(UsageEvent(
                key: "deepseek:\(session):\(id)", agent: .deepseek, ts: ts,
                model: (source["model"] as? String) ?? "unknown", cwd: cwd, session: session, isSubagent: isSub,
                input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output,
                genMs: plausibleGap(ts, since: stepStart[stepKey])))
        case "tool/call":
            guard let callId = data["callId"] as? String,
                  let argText = data["arguments"] as? String,
                  let args = parseJSON(Data(argText.utf8)) else { return }
            var change = EditChange()
            let name = data["name"] as? String
            switch name {
            case "edit":
                change = EditCount.replace(old: args["old_string"] as? String ?? "", new: args["new_string"] as? String ?? "")
            case "write":
                change = EditCount.write(args["content"] as? String ?? "")
            case "bash":
                out.images += ImageCalls.events(in: args["command"] as? String ?? "", keyPrefix: "deepseek:\(session):\(callId)",
                                                agent: .deepseek, ts: ts, cwd: cwd, session: session)
                return
            default:
                return
            }
            let path = args["path"] as? String ?? args["file_path"] as? String ?? args["filePath"] as? String ?? ""
            if !change.isEmpty, EditCount.isCounted(path: path, cwd: cwd) {
                pending[callId] = PendingEdit(ts: ts, cwd: cwd, session: session, change: change,
                                              path: path, isWrite: name == "write")
                pending.cap()
            }
        case "tool/result":
            let msg = data["message"] as? [String: Any] ?? [:]
            guard let callId = (msg["toolCallId"] as? String) ?? ((msg["source"] as? [String: Any])?["callId"] as? String),
                  var p = pending.removeValue(forKey: callId) else { return }
            if (msg["isError"] as? Bool) == true { return }
            if p.isWrite, let meta = data["meta"] as? [String: Any], meta["operation"] as? String == "update",
               let diffs = meta["diffs"] as? [[String: Any]] {
                p.change = diffs.reduce(EditChange()) {
                    $0 + EditCount.replace(old: $1["oldText"] as? String ?? "", new: $1["newText"] as? String ?? "")
                }
            }
            guard !p.change.isEmpty else { return }
            out.edits.append(EditEvent(key: "deepseek:\(p.session):\(callId)", agent: .deepseek, ts: p.ts,
                                       cwd: p.cwd, session: p.session, change: p.change))
        default:
            return
        }
    }
}
