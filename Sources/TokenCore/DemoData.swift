import Foundation

/// 演示数据：虚构的项目名和用量，用于截图和演示视频（`TOKEN_NOTCH_DEMO=1`），不读任何真实日志。
/// 用固定种子生成，每次结果一样。
public enum DemoData {
    struct RNG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
        mutating func pick<T>(_ xs: [(T, Double)]) -> T {
            var r = next() * xs.reduce(0) { $0 + $1.1 }
            for (x, w) in xs { r -= w; if r <= 0 { return x } }
            return xs.last!.0
        }
    }

    static let projects = ["~/code/atlas-web", "~/code/token-notch", "~/code/ml-pipeline", "~/code/api-gateway",
                           "~/code/ios-client", "~/code/docs-site", "~/code/infra", "~/code/design-tokens",
                           "~/code/billing-svc", "~/code/cli-tools"]

    /// (agent, 每日响应数, 模型及权重, 每次响应的上下文规模)
    static let agents: [(Agent, Int, [(String, Double)], Double)] = [
        (.claude, 60, [("claude-opus-5-5", 5), ("claude-sonnet-5-5", 3), ("claude-haiku-5-5", 1)], 90_000),
        (.codex, 28, [("gpt-6.2-sol", 3), ("gpt-6.2-astra", 2)], 70_000),
        (.deepseek, 30, [("deepseek-v4.1-flash", 4), ("deepseek-v4-pro", 1)], 60_000),
        (.antigravity, 12, [("gemini-4-carbon-high", 3), ("gemini-3.8-flash-high", 2)], 80_000),
        (.grok, 3, [("grok-4.7", 1)], 40_000),
    ]

    public static func populate(_ store: Store, now: Date = Date(), days: Int = 30) throws {
        var rng = RNG(state: 0x5EED_70CE)
        let cal = Calendar.current
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var events: [UsageEvent] = []
        var edits: [EditEvent] = []
        var images: [ImageEvent] = []
        let projectWeights = projects.enumerated().map { ($0.element, 1.0 / Double($0.offset + 1)) }

        for d in 0..<days {
            guard let day = cal.date(byAdding: .day, value: -d, to: cal.startOfDay(for: now)) else { continue }
            let weekday = cal.component(.weekday, from: day)
            let busy = (weekday == 1 || weekday == 7 ? 0.45 : 1.0) * rng.range(0.55, 1.35) * (1 + Double(days - d) / Double(days))
            for (agent, perDay, models, ctx) in agents {
                // 新 agent 只出现在最近一段时间，柱图更有层次
                if agent == .antigravity && d > 18 { continue }
                if agent == .grok && d > 10 { continue }
                let n = max(1, Int(Double(perDay) * busy))
                // 白天 9 点后的工作时间；今天则放在“现在”之前的几个小时里（不能落到未来）
                let midnight = Int64(day.timeIntervalSince1970 * 1000)
                let dayStart = d == 0 ? max(midnight, nowMs - 5 * 3_600_000) : midnight + 9 * 3_600_000
                let dayEnd = d == 0 ? nowMs - 120_000 : midnight + 23 * 3_600_000
                for i in 0..<n {
                    let ts = dayStart + Int64(Double(max(1, dayEnd - dayStart)) * rng.next())
                    let size = ctx * rng.range(0.4, 2.2)
                    let output = Int64(size * rng.range(0.004, 0.012))
                    let model = rng.pick(models)
                    let cwd = rng.pick(projectWeights)
                    events.append(UsageEvent(
                        key: "demo:\(agent.rawValue):\(d):\(i)", agent: agent, ts: ts, model: model, cwd: cwd,
                        session: "demo-\(agent.rawValue)-\(d)", isSubagent: agent == .claude && rng.next() < 0.3,
                        input: Int64(size * rng.range(0.002, 0.02)), cacheRead: Int64(size),
                        cacheWrite: agent == .claude ? Int64(size * rng.range(0.005, 0.03)) : 0, output: output,
                        genMs: Int64(Double(output) / rng.range(60, 160) * 1000)))
                    if agent != .grok && rng.next() < 0.35 {
                        let added = Int(rng.range(1, 40)), removed = Int(rng.range(0, 25))
                        edits.append(EditEvent(key: "demo-edit:\(agent.rawValue):\(d):\(i)", agent: agent, ts: ts, cwd: cwd,
                                               session: "", change: .block(added: added, removed: removed)))
                    }
                    if (agent == .codex || agent == .claude) && rng.next() < 0.03 {
                        images.append(ImageEvent(key: "demo-img:\(agent.rawValue):\(d):\(i)", agent: agent, ts: ts, cwd: cwd,
                                                 session: "", kind: rng.next() < 0.6 ? "generate" : "edit",
                                                 model: rng.next() < 0.7 ? "gpt-image-2.5-sunburst" : "gpt-image-2", count: 1))
                    }
                }
            }
        }
        // 最近几十秒内的响应：让这几个 agent 显示为“正在运行”，并有实时 tok/s
        for (agent, model, tps) in [(Agent.claude, "claude-opus-5-5", 128.0), (.codex, "gpt-6.2-sol", 46.0),
                                    (.deepseek, "deepseek-v4.1-flash", 96.0), (.antigravity, "gemini-4-carbon-high", 58.0)] {
            for k in 0..<4 {
                let output: Int64 = 900 + Int64(k) * 150
                events.append(UsageEvent(
                    key: "demo-live:\(agent.rawValue):\(k)", agent: agent, ts: nowMs - Int64(k) * 12_000 - 1_000,
                    model: model, cwd: projects[1], session: "demo-live", input: 1_200, cacheRead: 160_000,
                    cacheWrite: 2_000, output: output, genMs: Int64(Double(output) / tps * 1000)))
            }
        }
        try store.db.transaction {
            try store.upsert(events)
            try store.upsert(edits: edits)
            try store.upsert(images: images)
        }
    }
}
