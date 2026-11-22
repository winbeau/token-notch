import Foundation

public enum TokenFormat {
    /// 90.7M、1.88B、10.1K、512。
    public static func compact(_ n: Int64) -> String {
        let v = Double(n)
        let (x, unit): (Double, String) =
            v >= 1e9 ? (v / 1e9, "B") : v >= 1e6 ? (v / 1e6, "M") : v >= 1e3 ? (v / 1e3, "K") : (v, "")
        if unit.isEmpty { return String(n) }
        if x >= 100 { return String(format: "%.0f%@", x, unit) }
        if x >= 10 { return String(format: "%.1f%@", x, unit) }
        return String(format: "%.2f%@", x, unit)
    }

    /// 行数：不到一万显示完整数字（带千分位），再大用 K/M。
    public static func lines(_ n: Int64) -> String {
        if n < 10_000 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.locale = Locale(identifier: "en_US")
            return f.string(from: NSNumber(value: n)) ?? String(n)
        }
        return compact(n)
    }

    public static func percent(_ r: Double?, digits: Int = 1) -> String {
        guard let r else { return "—" }
        if r > 0, r < 0.001 { return "<0.1%" }
        return String(format: "%.\(digits)f%%", r * 100)
    }

    public static func cost(_ usd: Double) -> String {
        if usd <= 0 { return "$0" }
        if usd < 1 { return String(format: "$%.2f", usd) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return "$" + (f.string(from: NSNumber(value: usd.rounded())) ?? String(Int(usd)))
    }

    public static func speed(_ tps: Double?) -> String {
        guard let tps else { return "—" }
        return String(format: "%.0f tok/s", tps)
    }

    /// Claude 模型名去掉前缀：claude-opus-5-5 → Opus 5.5；gpt-6.2-sol → GPT-6.2 Sol。
    public static func modelName(_ id: String) -> String {
        var s = id.lowercased().replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        if s.hasPrefix("claude-") {
            s.removeFirst("claude-".count)
            var parts = s.split(separator: "-").map(String.init)
            guard let family = parts.first else { return id }
            parts.removeFirst()
            let version = parts.joined(separator: ".")
            return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
        }
        // gemini-3.8-flash-high → Gemini 3.8 Flash High；grok-4.7 → Grok 4.7；deepseek-v4-pro → DeepSeek V4 Pro
        if s.hasPrefix("gemini-") || s.hasPrefix("grok-") || s.hasPrefix("deepseek-") {
            return s.split(separator: "-").map { w -> String in
                if w == "deepseek" { return "DeepSeek" }
                return w.prefix(1).uppercased() + w.dropFirst()
            }.joined(separator: " ")
        }
        if s.hasPrefix("gpt-") {
            let parts = s.split(separator: "-").map(String.init)
            guard parts.count >= 2 else { return id.uppercased() }
            let rest = parts.dropFirst(2).map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return (["GPT-" + parts[1]] + rest).joined(separator: " ")
        }
        return id
    }
}
