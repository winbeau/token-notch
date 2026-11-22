import Foundation

public enum Agent: String, CaseIterable, Sendable, Codable, Hashable {
    case claude
    case codex
    case antigravity   // Google Antigravity（Gemini）
    case grok          // Grok Build / Grok App
    case deepseek      // DeepSeek Harness（DSH）

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .grok: return "Grok"
        case .deepseek: return "DeepSeek Harness"
        }
    }

    public var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .grok: return "Grok"
        case .deepseek: return "DeepSeek"
        }
    }
}

/// 一次模型响应的用量。`input` 是**新输入**（不含缓存读写），四项相加即总量。
public struct UsageEvent: Sendable, Equatable {
    public var key: String          // 去重键：同一响应在日志里可能出现多行
    public var agent: Agent
    public var ts: Int64            // unix 毫秒
    public var model: String
    public var cwd: String
    public var session: String
    public var isSubagent: Bool
    public var input: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64
    public var output: Int64
    /// 从上一次用户输入（或上一次响应）到这次响应写入日志的毫秒数，用于估算 tok/s；未知为 nil。
    public var genMs: Int64?

    public var total: Int64 { input + cacheRead + cacheWrite + output }

    public init(key: String, agent: Agent, ts: Int64, model: String, cwd: String, session: String,
                isSubagent: Bool = false, input: Int64, cacheRead: Int64, cacheWrite: Int64,
                output: Int64, genMs: Int64? = nil) {
        self.key = key
        self.agent = agent
        self.ts = ts
        self.model = model
        self.cwd = cwd
        self.session = session
        self.isSubagent = isSubagent
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
        self.genMs = genMs
    }
}

/// 一次代码编辑（一次工具调用）。按键去重，重读日志不会重复计数。
public struct EditEvent: Sendable, Equatable {
    public var key: String
    public var agent: Agent
    public var ts: Int64
    public var cwd: String
    public var session: String
    public var change: EditChange

    public init(key: String, agent: Agent, ts: Int64, cwd: String, session: String, change: EditChange) {
        self.key = key
        self.agent = agent
        self.ts = ts
        self.cwd = cwd
        self.session = session
        self.change = change
    }
}

public struct TokenTotals: Sendable, Equatable {
    public var input: Int64 = 0
    public var cacheRead: Int64 = 0
    public var cacheWrite: Int64 = 0
    public var output: Int64 = 0
    /// 已计价部分的美元费用；`unpricedTokens > 0` 时是下限。
    public var cost: Double = 0
    public var unpricedTokens: Int64 = 0

    public init() {}

    public var total: Int64 { input + cacheRead + cacheWrite + output }

    /// 缓存命中率 = 缓存读 ÷ 全部输入（新输入 + 缓存读 + 缓存写）。
    public var cacheHitRate: Double? {
        let all = input + cacheRead + cacheWrite
        return all > 0 ? Double(cacheRead) / Double(all) : nil
    }

    public static func + (a: TokenTotals, b: TokenTotals) -> TokenTotals {
        var r = TokenTotals()
        r.input = a.input + b.input
        r.cacheRead = a.cacheRead + b.cacheRead
        r.cacheWrite = a.cacheWrite + b.cacheWrite
        r.output = a.output + b.output
        r.cost = a.cost + b.cost
        r.unpricedTokens = a.unpricedTokens + b.unpricedTokens
        return r
    }

    public static func += (a: inout TokenTotals, b: TokenTotals) { a = a + b }
}

enum Time {
    nonisolated(unsafe) static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseMs(_ s: String) -> Int64? {
        if let v = fastUTC(s) { return v }
        guard let d = isoFrac.date(from: s) ?? iso.date(from: s) else { return nil }
        return Int64((d.timeIntervalSince1970 * 1000).rounded())
    }

    /// 快路径：`YYYY-MM-DDTHH:MM:SS[.fff…]Z`（日志里几乎全是这种）。其他格式返回 nil 走 Formatter。
    static func fastUTC(_ s: String) -> Int64? {
        var u = Array(s.utf8)
        guard u.count >= 20, u[4] == 0x2D, u[7] == 0x2D, u[10] == 0x54, u[13] == 0x3A, u[16] == 0x3A,
              u.last == 0x5A else { return nil }
        u.removeLast()
        func num(_ a: Int, _ n: Int) -> Int? {
            var v = 0
            for i in a..<(a + n) {
                let c = Int(u[i]) - 48
                guard c >= 0, c <= 9 else { return nil }
                v = v * 10 + c
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let sec = num(17, 2) else { return nil }
        var ms = 0
        if u.count > 19 {
            guard u[19] == 0x2E, u.count > 20 else { return nil }
            let digits = min(3, u.count - 20)
            guard let f = num(20, digits) else { return nil }
            ms = f * [1, 100, 10, 1][digits]
        }
        // 公历日期 → 自 1970-01-01 的天数（Howard Hinnant 的 days_from_civil）
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return Int64(((days * 24 + h) * 60 + mi) * 60 + sec) * 1000 + Int64(ms)
    }

    /// 本地时区的 yyyy-MM-dd。
    static func day(ms: Int64, calendar: Calendar = .current) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        day(ms: Int64(date.timeIntervalSince1970 * 1000), calendar: calendar)
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
