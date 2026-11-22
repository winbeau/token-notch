import Foundation

/// 每百万 token 的美元价格。
public struct ModelPrice: Sendable, Equatable, Codable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(_ input: Double, _ output: Double, _ cacheRead: Double, _ cacheWrite: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    func cost(input i: Int64, output o: Int64, cacheRead r: Int64, cacheWrite w: Int64) -> Double {
        (Double(i) * input + Double(o) * output + Double(r) * cacheRead + Double(w) * cacheWrite) / 1_000_000
    }
}

/// 默认价格取自 cc-switch（MIT）预置的价格表；`~/.tokens/pricing.json` 可覆盖或补充：
/// `{"model-id": {"input": 2, "output": 10, "cacheRead": 0.1, "cacheWrite": 2.5}}`
public struct Pricing: Sendable {
    public var table: [String: ModelPrice]

    public static let builtin: [String: ModelPrice] = [
        "claude-fable-5-2": .init(8, 40, 0.20, 10),
        "claude-fable-5-1": .init(10, 50, 0.25, 12.5),
        "claude-fable-5": .init(10, 50, 1.00, 12.5),
        "claude-mythos-5-1": .init(10, 50, 0.25, 12.5),
        "claude-mythos-5": .init(10, 50, 1.00, 12.5),
        "claude-opus-5-5": .init(4, 20, 0.20, 5),
        "claude-opus-5": .init(5, 25, 0.50, 6.25),
        "claude-opus-4-8": .init(5, 25, 0.50, 6.25),
        "claude-opus-4-7": .init(5, 25, 0.50, 6.25),
        "claude-opus-4-6": .init(5, 25, 0.50, 6.25),
        "claude-opus-4-5": .init(5, 25, 0.50, 6.25),
        "claude-opus-4-1": .init(15, 75, 1.50, 18.75),
        "claude-opus-4": .init(15, 75, 1.50, 18.75),
        "claude-sonnet-5-5": .init(2, 10, 0.10, 2.5),
        "claude-sonnet-5": .init(2, 10, 0.20, 2.5),
        "claude-sonnet-4-6": .init(3, 15, 0.30, 3.75),
        "claude-sonnet-4-5": .init(3, 15, 0.30, 3.75),
        "claude-sonnet-4": .init(3, 15, 0.30, 3.75),
        "claude-haiku-5-5": .init(0.10, 0.50, 0.01, 0.125),
        "claude-haiku-4-5": .init(1, 5, 0.10, 1.25),
        "claude-3-5-haiku": .init(0.80, 4, 0.08, 1),
        "claude-3-5-sonnet": .init(3, 15, 0.30, 3.75),
        "gpt-6-astra": .init(10, 50, 1, 12.5),
        "gpt-6.2-sol": .init(2, 10, 0.10, 2.5),
        "gpt-6.2-astra": .init(8, 40, 0.40, 10),
        "gpt-6.1-sol": .init(2, 10, 0.10, 2.5),
        "gpt-6.1-terra": .init(1, 5, 0.05, 1.25),
        "gpt-6-sol": .init(2, 10, 0.20, 2.5),
        "gpt-6-luna": .init(0.10, 0.50, 0.01, 0.125),
        "gpt-5.6-sol": .init(4, 20, 0.40, 5),
        "gpt-5.6-terra": .init(2, 12, 0.20, 2.5),
        // Gemini（Antigravity 记的是带档位的 ID，如 gemini-3.8-flash-high，按最长前缀匹配）
        "gemini-4-neon": .init(3, 15, 0.15, 0),
        "gemini-4-argon": .init(2, 10, 0.10, 0),
        "gemini-4-carbon": .init(2, 10, 0.10, 0),
        "gemini-4-hydrogen": .init(1.5, 7.5, 0.075, 0),
        "gemini-3.8-flash": .init(0.75, 3.75, 0.075, 0),
        "gemini-3.7-flash": .init(0.75, 3.75, 0.075, 0),
        "gemini-3.6-flash": .init(0.75, 3.75, 0.075, 0),
        "gemini-3.5-flash": .init(1.5, 9, 0.15, 0),
        "gemini-3.5-flash-lite": .init(0.30, 2.5, 0.03, 0),
        "gemini-3.1-pro-preview": .init(2, 12, 0.20, 0),
        "gemini-3.1-flash-lite": .init(0.25, 1.5, 0.025, 0),
        "gemini-3-pro-preview": .init(2, 12, 0.20, 0),
        "gemini-3-flash-preview": .init(0.5, 3, 0.05, 0),
        "gemini-2.5-pro": .init(1.25, 10, 0.125, 0),
        "gemini-2.5-flash": .init(0.3, 2.5, 0.03, 0),
        "gemini-2.5-flash-lite": .init(0.10, 0.40, 0.01, 0),
        // Grok
        "grok-4.7": .init(2, 6, 0.50, 0),
        "grok-4.6": .init(2, 6, 0.50, 0),
        "grok-4.5": .init(2, 6, 0.30, 0),
        "grok-4.7-build": .init(2, 6, 0.50, 0),
        "grok-4.7-build-fast": .init(4, 12, 1, 0),
        "grok-4.6-build": .init(2, 6, 0.50, 0),
        "grok-4.5-build": .init(2, 6, 0.30, 0),
        "grok-4.3": .init(1.25, 2.5, 0.20, 0),
        "grok-4": .init(3, 15, 0.75, 0),
        // DeepSeek
        "deepseek-flash": .init(0.3, 1.2, 0.006, 0),
        "deepseek-v4.1-flash": .init(0.3, 1.2, 0.006, 0),
        "deepseek-v4-flash": .init(0.3, 1.2, 0.006, 0),
        "deepseek-v4-pro": .init(1.32, 3.96, 0.044, 0),
        "deepseek-chat": .init(0.44, 1.32, 0.014, 0),
        "deepseek-reasoner": .init(0.44, 1.32, 0.014, 0),
        "deepseek-v3.2": .init(0.28, 0.42, 0.028, 0),
        "deepseek-v3.1": .init(0.55, 1.67, 0.055, 0),
        "deepseek-v3": .init(0.28, 1.11, 0.028, 0),
    ]

    public init(table: [String: ModelPrice] = Pricing.builtin) {
        self.table = table
    }

    /// 内置表 + 用户覆盖文件。
    public static func load(overrides url: URL = Store.defaultDirectory.appendingPathComponent("pricing.json")) -> Pricing {
        var p = Pricing()
        if let d = try? Data(contentsOf: url),
           let extra = try? JSONDecoder().decode([String: ModelPrice].self, from: d) {
            for (k, v) in extra { p.table[k.lowercased()] = v }
        }
        return p
    }

    /// 先精确匹配；再去掉 `-20250514` 这类日期后缀；最后按最长前缀匹配
    /// （`claude-opus-4-5-20251101` → `claude-opus-4-5`，而不是 `claude-opus-4`）。
    public func price(for model: String) -> ModelPrice? {
        let m = model.lowercased()
        if let p = table[m] { return p }
        let stripped = m.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        if let p = table[stripped] { return p }
        let best = table.keys.filter { stripped.hasPrefix($0 + "-") || stripped.hasPrefix($0 + "[") }
            .max(by: { $0.count < $1.count })
        return best.flatMap { table[$0] }
    }
}
