import SwiftUI
import TokenCore

/// 界面语言。默认中文，存在 UserDefaults 的 `language` 里，右键菜单切换。
enum Lang: String, CaseIterable {
    case zh, en

    static let defaultsKey = "language"

    static var saved: Lang {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Lang.init(rawValue:)) ?? .zh
    }
}

/// 全部界面文案。每条写成 `s(中文, 英文)`，集中在这一个表里；带参数的文案是方法。
struct L10n {
    var lang: Lang

    private func s(_ zh: String, _ en: String) -> String { lang == .en ? en : zh }

    // MARK: 标签与时间范围

    var overview: String { s("概览", "Overview") }
    var detail: String { s("明细", "Details") }

    func range(_ r: TimeRange) -> String {
        switch r {
        case .today: return s("今日", "Today")
        case .week: return s("7 天", "7D")
        case .month: return s("30 天", "30D")
        case .all: return s("全部", "All")
        }
    }

    /// 区块标题里的时间范围：今日 / 近 7 天 / 全部（自 10-10 起 44 天）。
    func rangeTitle(_ st: RangeStats) -> String {
        switch st.range {
        case .today: return s("今日", "Today")
        case .week: return s("近 7 天", "Last 7 days")
        case .month: return s("近 30 天", "Last 30 days")
        case .all: return lang == .en
            ? "All time (since \(shortDate(st.startDay)), \(st.dayCount) days)"
            : "全部（自 \(shortDate(st.startDay)) 起 \(st.dayCount) 天）"
        }
    }

    /// 指标标签里的时间范围：近 7 天 / 全部。
    func rangeMetric(_ r: TimeRange) -> String {
        switch r {
        case .all: return s("全部", "All time")
        case .today: return s("今日", "Today")
        default: return lang == .en ? "Last \(r.days ?? 0)D" : "近 \(range(r))"
        }
    }

    // MARK: 指标

    var today: String { s("今日", "Today") }
    var todayTokens: String { s("今日 token", "Tokens today") }
    var totalTokens: String { s("合计 token", "Total tokens") }
    var cacheHit: String { s("缓存命中", "Cache hit") }
    var output: String { s("输出", "Output") }
    var editLines: String { s("编辑行数", "Lines edited") }
    var liveTotal: String { s("实时合计", "Live total") }
    var live: String { s("实时", "Live") }
    var dailyAvg: String { s("日均", "Daily avg") }
    var subagentShare: String { s("子代理占比", "Subagents") }
    var imageCalls: String { s("生图调用", "Image calls") }
    func imageCallsValue(_ calls: Int64, _ images: Int64) -> String {
        lang == .en ? "\(calls)" + (images != calls ? " · \(images) img" : "") : "\(calls) 次" + (images != calls ? " · \(images) 张" : "")
    }
    func imageTitle(_ calls: Int64, _ images: Int64) -> String {
        lang == .en ? "Image generation · \(calls) call\(calls == 1 ? "" : "s") · \(images) image\(images == 1 ? "" : "s")" : "生图 · \(calls) 次调用 · \(images) 张"
    }
    func imageModelRow(_ calls: Int64) -> String { lang == .en ? "\(calls) call\(calls == 1 ? "" : "s")" : "\(calls) 次" }
    var cacheRead: String { s("缓存读", "Cache read") }
    var cacheWrite: String { s("缓存写", "Cache write") }
    var freshInput: String { s("新输入", "Fresh input") }
    var cacheHitFormula: String { s("缓存读 ÷ 全部输入", "cache read ÷ all input") }
    func hitRate(_ v: String) -> String { s("命中 ", "hit ") + v }

    // MARK: 图表与表格

    var dailyStacked: String { s("每日 · 按 agent 叠加", "Daily · stacked by agent") }
    func peak(_ day: String, _ v: String) -> String { s("峰值", "Peak") + " \(shortDate(day)) · \(v)" }
    func byModel(_ title: String) -> String { s("按模型 · ", "By model · ") + title }
    var noRecords: String { s("这段时间没有记录", "No records in this period") }
    var colModel: String { s("模型", "Model") }
    var colAgent: String { "Agent" }
    var colSpeed: String { s("平均 tok/s", "Avg tok/s") }
    var colTokens: String { "Token" }
    var colShare: String { s("占比", "Share") }
    var total: String { s("合计", "Total") }
    func otherModels(_ n: Int) -> String { lang == .en ? "\(n) other model\(n == 1 ? "" : "s")" : "其他 \(n) 个模型" }
    func agentCount(_ n: Int) -> String { lang == .en ? "\(n) agent\(n == 1 ? "" : "s")" : "\(n) 个 agent" }
    func projectsTitle(_ n: Int) -> String { lang == .en ? "Cost by project · \(n)" : "项目耗费 · \(n) 个项目" }
    func otherProjects(_ n: Int) -> String { lang == .en ? "\(n) other project\(n == 1 ? "" : "s")" : "其他 \(n) 个项目" }
    func projectName(_ name: String) -> String { name == "（未知目录）" ? s(name, "(unknown)") : name }
    /// 柱图悬停提示：11-22 周日 · 131M（Claude 120M，Codex 11M）
    func dayTooltip(_ day: String, _ value: String, parts: [String]) -> String {
        let head = "\(shortDate(day)) \(weekday(day)) · \(value)"
        guard parts.count > 1 else { return head }
        return lang == .en ? head + " (" + parts.joined(separator: ", ") + ")"
                           : head + "（" + parts.joined(separator: "，") + "）"
    }

    // MARK: 日期

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let enShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d"
        return f
    }()

    /// 11-22 / Nov 22
    func shortDate(_ day: String) -> String {
        guard lang == .en, let d = Self.parser.date(from: day) else { return String(day.suffix(5)) }
        return Self.enShort.string(from: d)
    }

    private func weekdayIndex(_ day: String) -> Int? {
        Self.parser.date(from: day).map { Calendar.current.component(.weekday, from: $0) - 1 }
    }

    /// 周日 / Sun
    func weekday(_ day: String) -> String {
        guard let i = weekdayIndex(day) else { return "" }
        return lang == .en ? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][i]
                           : ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][i]
    }

    /// 柱图下方的短标签：一 / Mon
    func weekdayShort(_ day: String) -> String {
        lang == .en ? weekday(day) : String(weekday(day).suffix(1))
    }

    var todayShort: String { s("今", "Today") }
    var todayLabel: String { s("今天", "Today") }

    // MARK: 右键菜单

    var menuRebuild: String { s("重新统计（清空 ~/.tokens 后回填）", "Rebuild stats (clear ~/.tokens and re-import)") }
    var menuOpenFolder: String { s("在 Finder 中打开 ~/.tokens", "Open ~/.tokens in Finder") }
    var menuSwitchLanguage: String { s("Switch to English", "切换到中文") }
    var menuQuit: String { s("退出 Token Notch", "Quit Token Notch") }
}

private struct L10nKey: EnvironmentKey {
    static let defaultValue = L10n(lang: .zh)
}

extension EnvironmentValues {
    var l10n: L10n {
        get { self[L10nKey.self] }
        set { self[L10nKey.self] = newValue }
    }
}
