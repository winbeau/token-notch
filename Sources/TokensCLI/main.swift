import Foundation
import TokenCore

// 用法：tokens [--db <path>] [--reset] [--json]
// 导入本机 agent 日志到 ~/.tokens/tokens.db，然后打印各时间范围的统计。

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

let dbPath = option("--db")
let reset = flag("--reset")

do {
    let store = try dbPath.map { try Store(path: $0) } ?? Store.openDefault()
    if reset { try store.reset() }
    let ingestor = Ingestor(store: store)
    let t0 = Date()
    let r = try ingestor.scanAll()
    print(String(format: "导入：读 %d 个文件，%d 条事件，用时 %.2fs；库内共 %d 条（%@）",
                 r.filesRead, r.events, Date().timeIntervalSince(t0), try store.eventCount(), store.path))

    let t1 = Date()
    let snap = try StatsEngine(store: store).snapshot()
    print(String(format: "统计用时 %.3fs，最早记录 %@\n", Date().timeIntervalSince(t1), snap.firstDay ?? "—"))

    for range in TimeRange.allCases {
        let s = snap.stats(range)
        let t = s.totals
        print("== \(range.label)（\(s.startDay) ~ \(s.endDay)，\(s.dayCount) 天）")
        print("   合计 \(TokenFormat.compact(t.total))  新输入 \(TokenFormat.compact(t.input))  缓存读 \(TokenFormat.compact(t.cacheRead))  缓存写 \(TokenFormat.compact(t.cacheWrite))  输出 \(TokenFormat.compact(t.output))  命中 \(TokenFormat.percent(t.cacheHitRate))  ≈\(TokenFormat.cost(t.cost))")
        for a in s.agents {
            print("   · \(a.agent.displayName): \(TokenFormat.compact(a.totals.total))  命中 \(TokenFormat.percent(a.totals.cacheHitRate))  子代理 \(TokenFormat.percent(a.subagentShare))  ≈\(TokenFormat.cost(a.totals.cost))")
        }
        guard range == .all || range == .week else { continue }
        print("   模型：")
        for m in s.models.prefix(8) {
            print("     \(TokenFormat.modelName(m.model).padding(toLength: 16, withPad: " ", startingAt: 0)) \(m.agent.shortName.padding(toLength: 7, withPad: " ", startingAt: 0)) \(TokenFormat.compact(m.totals.total).padding(toLength: 8, withPad: " ", startingAt: 0)) \(TokenFormat.speed(m.tokPerSec))  ≈\(TokenFormat.cost(m.totals.cost))\(m.totals.unpricedTokens > 0 ? "（未计价）" : "")")
        }
        print("   项目（共 \(s.projects.count) 个）：")
        for p in s.projects.prefix(6) {
            let split = Agent.allCases.compactMap { a in p.perAgent[a].map { "\(a.shortName) \(TokenFormat.compact($0))" } }
            print("     \(p.name): \(TokenFormat.compact(p.total))  [\(split.joined(separator: ", "))]  ≈\(TokenFormat.cost(p.cost))")
        }
        if range == .week {
            print("   每日：" + s.daily.map { "\($0.day.suffix(5)) \(TokenFormat.compact($0.total))" }.joined(separator: "  "))
        }
    }
    print("\n== 实时")
    for l in snap.live.values.sorted(by: { $0.today > $1.today }) {
        let ago = l.lastActivity.map { String(format: "%.0fs 前", Date().timeIntervalSince($0)) } ?? "—"
        print("   \(l.agent.displayName): 今日 \(TokenFormat.compact(l.today))  最近活动 \(ago)  速度 \(TokenFormat.speed(l.tokPerSec))\(l.isActive() ? "  [活跃]" : "")")
    }
} catch {
    FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
    exit(1)
}
