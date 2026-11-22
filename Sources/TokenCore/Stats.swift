import Foundation

public enum TimeRange: String, CaseIterable, Sendable, Identifiable {
    case today, week, month, all

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .today: return "今日"
        case .week: return "7 天"
        case .month: return "30 天"
        case .all: return "全部"
        }
    }

    /// 包含今天在内的天数；`all` 为 nil（从最早一条记录算起）。
    public var days: Int? {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        case .all: return nil
        }
    }
}

public struct ModelStat: Sendable, Identifiable {
    public var id: String { agent.rawValue + "/" + model }
    public var agent: Agent
    public var model: String
    public var totals: TokenTotals
    /// 平均生成速度：有耗时记录的响应的输出 token ÷ 耗时。
    public var tokPerSec: Double?
}

public struct AgentStat: Sendable, Identifiable {
    public var id: String { agent.rawValue }
    public var agent: Agent
    public var totals: TokenTotals
    /// 子代理（Claude sidechain）产生的 token。
    public var subagentTokens: Int64
    /// 代码编辑行数（每处改动 max(新增, 删除) 之和）。
    public var editLines: Int64 = 0

    public var subagentShare: Double? {
        totals.total > 0 ? Double(subagentTokens) / Double(totals.total) : nil
    }
}

public struct DayStat: Sendable, Identifiable {
    public var id: String { day }
    public var day: String              // yyyy-MM-dd
    public var perAgent: [Agent: Int64]
    public var total: Int64 { perAgent.values.reduce(0, +) }
}

public struct ProjectStat: Sendable, Identifiable {
    public var id: String { cwd }
    public var cwd: String
    public var name: String
    public var perAgent: [Agent: Int64]
    public var cost: Double
    public var editLines: Int64 = 0
    public var total: Int64 { perAgent.values.reduce(0, +) }
}

public struct RangeStats: Sendable {
    public var range: TimeRange
    public var startDay: String
    public var endDay: String
    public var totals: TokenTotals
    public var agents: [AgentStat]          // 按总量降序
    public var models: [ModelStat]          // 按总量降序
    public var daily: [DayStat]             // startDay…endDay 连续，缺的天补 0
    public var projects: [ProjectStat]      // 按总量降序

    /// 全部 agent 的编辑行数合计。
    public var editLines: Int64 { agents.reduce(0) { $0 + $1.editLines } }

    public var dayCount: Int { max(1, daily.count) }

    public func agent(_ a: Agent) -> AgentStat? { agents.first { $0.agent == a } }
    public func models(for a: Agent) -> [ModelStat] { models.filter { $0.agent == a } }

    public static func empty(_ range: TimeRange, today: String) -> RangeStats {
        RangeStats(range: range, startDay: today, endDay: today, totals: TokenTotals(),
                   agents: [], models: [], daily: [], projects: [])
    }
}

public struct LiveStat: Sendable {
    public var agent: Agent
    public var today: Int64
    /// 最近一次活动：新事件写入或日志文件变动，取较晚者。
    public var lastActivity: Date?
    /// 最近 90 秒内完成的响应的生成速度。
    public var tokPerSec: Double?

    public init(agent: Agent, today: Int64, lastActivity: Date?, tokPerSec: Double?) {
        self.agent = agent
        self.today = today
        self.lastActivity = lastActivity
        self.tokPerSec = tokPerSec
    }

    public func isActive(now: Date = Date(), window: TimeInterval = 20) -> Bool {
        guard let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) <= window
    }
}

public struct Snapshot: Sendable {
    public var generatedAt: Date
    public var firstDay: String?
    public var ranges: [TimeRange: RangeStats]
    public var live: [Agent: LiveStat]

    public func stats(_ r: TimeRange) -> RangeStats {
        ranges[r] ?? .empty(r, today: Time.day(generatedAt))
    }

    /// 当前活跃的 agent，按今日用量降序。
    public func activeAgents(now: Date = Date(), window: TimeInterval = 20) -> [LiveStat] {
        live.values.filter { $0.isActive(now: now, window: window) }.sorted { $0.today > $1.today }
    }

    /// 有数据的 agent（任意时间），用于展开面板的标签。
    public var knownAgents: [Agent] {
        Agent.allCases.filter { a in stats(.all).agents.contains { $0.agent == a && $0.totals.total > 0 } }
    }

    public var liveTokPerSec: Double? {
        let v = live.values.compactMap(\.tokPerSec)
        return v.isEmpty ? nil : v.reduce(0, +)
    }

    public static let empty = Snapshot(generatedAt: Date(), firstDay: nil, ranges: [:], live: [:])
}

/// 从 Store 聚合出界面需要的全部数字。
public struct StatsEngine: Sendable {
    let store: Store
    public var pricing: Pricing
    public var calendar: Calendar = .current

    public init(store: Store, pricing: Pricing = .load()) {
        self.store = store
        self.pricing = pricing
    }

    public func snapshot(now: Date = Date(), activity: [Agent: Date] = [:]) throws -> Snapshot {
        let today = Time.day(now, calendar: calendar)
        let first = try store.db.query("SELECT MIN(day) FROM events").first?.first.flatMap { $0.isNull ? nil : $0.text }
        var ranges: [TimeRange: RangeStats] = [:]
        for r in TimeRange.allCases {
            ranges[r] = try rangeStats(r, today: today, firstDay: first, now: now)
        }
        return Snapshot(generatedAt: now, firstDay: first, ranges: ranges,
                        live: try live(now: now, today: today, activity: activity))
    }

    func startDay(_ r: TimeRange, now: Date, firstDay: String?) -> String {
        guard let n = r.days else { return firstDay ?? Time.day(now, calendar: calendar) }
        let start = calendar.date(byAdding: .day, value: -(n - 1), to: calendar.startOfDay(for: now)) ?? now
        return Time.day(start, calendar: calendar)
    }

    func rangeStats(_ r: TimeRange, today: String, firstDay: String?, now: Date) throws -> RangeStats {
        let start = startDay(r, now: now, firstDay: firstDay)
        let bounds: [SQLValue] = [.text(start), .text(today)]

        // 按 agent × 模型
        var models: [ModelStat] = []
        var agentTotals: [Agent: TokenTotals] = [:]
        var agentSub: [Agent: Int64] = [:]
        let modelRows = try store.db.query("""
            SELECT agent, model, SUM(input), SUM(cache_read), SUM(cache_write), SUM(output),
                   SUM(CASE WHEN sub = 1 THEN input + cache_read + cache_write + output ELSE 0 END),
                   SUM(CASE WHEN gen_ms IS NOT NULL THEN output ELSE 0 END),
                   SUM(COALESCE(gen_ms, 0))
            FROM events WHERE day >= ? AND day <= ? GROUP BY agent, model
            """, bounds)
        for row in modelRows {
            guard let agent = Agent(rawValue: row[0].text) else { continue }
            let t = totals(model: row[1].text, input: row[2].int, cacheRead: row[3].int,
                           cacheWrite: row[4].int, output: row[5].int)
            let genMs = row[8].int
            models.append(ModelStat(agent: agent, model: row[1].text, totals: t,
                                    tokPerSec: genMs > 0 ? Double(row[7].int) / Double(genMs) * 1000 : nil))
            agentTotals[agent, default: TokenTotals()] += t
            agentSub[agent, default: 0] += row[6].int
        }
        models.sort { $0.totals.total > $1.totals.total }
        // 编辑行数（只挂到有用量的 agent 上）
        var agentEdits: [Agent: Int64] = [:]
        var projectEdits: [String: Int64] = [:]
        for row in try store.db.query("""
            SELECT agent, cwd, SUM(lines) FROM edits WHERE day >= ? AND day <= ? GROUP BY agent, cwd
            """, bounds) {
            guard let a = Agent(rawValue: row[0].text) else { continue }
            agentEdits[a, default: 0] += row[2].int
            projectEdits[row[1].text, default: 0] += row[2].int
        }
        let agents = agentTotals.map { AgentStat(agent: $0.key, totals: $0.value, subagentTokens: agentSub[$0.key] ?? 0,
                                                 editLines: agentEdits[$0.key] ?? 0) }
            .sorted { $0.totals.total > $1.totals.total }
        let all = agents.reduce(TokenTotals()) { $0 + $1.totals }

        // 每日 × agent，补齐空白天
        var byDay: [String: [Agent: Int64]] = [:]
        for row in try store.db.query("""
            SELECT day, agent, SUM(input + cache_read + cache_write + output)
            FROM events WHERE day >= ? AND day <= ? GROUP BY day, agent
            """, bounds) {
            guard let a = Agent(rawValue: row[1].text) else { continue }
            byDay[row[0].text, default: [:]][a] = row[2].int
        }
        let daily = days(from: start, to: today).map { DayStat(day: $0, perAgent: byDay[$0] ?? [:]) }

        // 项目 × agent（按模型计价后汇总）
        var proj: [String: (perAgent: [Agent: Int64], cost: Double)] = [:]
        for row in try store.db.query("""
            SELECT cwd, agent, model, SUM(input), SUM(cache_read), SUM(cache_write), SUM(output)
            FROM events WHERE day >= ? AND day <= ? GROUP BY cwd, agent, model
            """, bounds) {
            guard let a = Agent(rawValue: row[1].text) else { continue }
            let t = totals(model: row[2].text, input: row[3].int, cacheRead: row[4].int,
                           cacheWrite: row[5].int, output: row[6].int)
            var p = proj[row[0].text] ?? ([:], 0)
            p.perAgent[a, default: 0] += t.total
            p.cost += t.cost
            proj[row[0].text] = p
        }
        let names = Self.displayNames(for: Array(proj.keys))
        let projects = proj.map { ProjectStat(cwd: $0.key, name: names[$0.key] ?? $0.key,
                                              perAgent: $0.value.perAgent, cost: $0.value.cost,
                                              editLines: projectEdits[$0.key] ?? 0) }
            .sorted { $0.total > $1.total }

        return RangeStats(range: r, startDay: start, endDay: today, totals: all,
                          agents: agents, models: models, daily: daily, projects: projects)
    }

    func live(now: Date, today: String, activity: [Agent: Date]) throws -> [Agent: LiveStat] {
        var out: [Agent: LiveStat] = [:]
        for a in Agent.allCases { out[a] = LiveStat(agent: a, today: 0, lastActivity: activity[a], tokPerSec: nil) }
        for row in try store.db.query("""
            SELECT agent, SUM(input + cache_read + cache_write + output) FROM events WHERE day = ? GROUP BY agent
            """, [.text(today)]) {
            if let a = Agent(rawValue: row[0].text) { out[a]?.today = row[1].int }
        }
        for row in try store.db.query("SELECT agent, MAX(ts) FROM events GROUP BY agent") {
            guard let a = Agent(rawValue: row[0].text) else { continue }
            let d = Date(timeIntervalSince1970: Double(row[1].int) / 1000)
            if out[a]?.lastActivity.map({ $0 < d }) ?? true { out[a]?.lastActivity = d }
        }
        let since = Int64((now.timeIntervalSince1970 - 90) * 1000)
        for row in try store.db.query("""
            SELECT agent, SUM(output), SUM(gen_ms) FROM events
            WHERE ts >= ? AND gen_ms IS NOT NULL GROUP BY agent
            """, [.int(since)]) {
            guard let a = Agent(rawValue: row[0].text), row[2].int > 0 else { continue }
            out[a]?.tokPerSec = Double(row[1].int) / Double(row[2].int) * 1000
        }
        return out
    }

    func totals(model: String, input: Int64, cacheRead: Int64, cacheWrite: Int64, output: Int64) -> TokenTotals {
        var t = TokenTotals()
        t.input = input
        t.cacheRead = cacheRead
        t.cacheWrite = cacheWrite
        t.output = output
        if let p = pricing.price(for: model) {
            t.cost = p.cost(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
        } else {
            t.unpricedTokens = t.total
        }
        return t
    }

    func days(from start: String, to end: String) -> [String] {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        guard var d = f.date(from: start), let last = f.date(from: end), d <= last else { return [end] }
        var out: [String] = []
        while d <= last, out.count < 5000 {
            out.append(f.string(from: d))
            guard let n = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = n
        }
        return out
    }

    /// 目录名作项目名；同名时带上父目录区分。
    static func displayNames(for paths: [String]) -> [String: String] {
        func base(_ p: String) -> String {
            let n = (p as NSString).lastPathComponent
            return n.isEmpty ? "（未知目录）" : n
        }
        var count: [String: Int] = [:]
        for p in paths { count[base(p), default: 0] += 1 }
        var out: [String: String] = [:]
        for p in paths {
            let b = base(p)
            if count[b, default: 0] > 1 {
                let parent = ((p as NSString).deletingLastPathComponent as NSString).lastPathComponent
                out[p] = parent.isEmpty ? b : "\(parent)/\(b)"
            } else {
                out[p] = b
            }
        }
        return out
    }
}
