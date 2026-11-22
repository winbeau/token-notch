import SwiftUI
import TokenCore

private func rangeTitle(_ s: RangeStats) -> String {
    switch s.range {
    case .all: return "全部（自 \(DateLabel.short(s.startDay)) 起 \(s.dayCount) 天）"
    case .today: return "今日"
    default: return "近 \(s.range.label)"
    }
}

private func costText(_ t: TokenTotals) -> String {
    "≈ " + TokenFormat.cost(t.cost) + (t.unpricedTokens > 0 ? "+" : "")
}

// MARK: - 概览：全部 agent 合计

struct OverviewPage: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let s = model.snapshot.stats(model.range)
        let t = s.totals
        let today = model.snapshot.live.values.reduce(Int64(0)) { $0 + $1.today }

        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("合计 token · \(rangeTitle(s))").font(.system(size: 12)).foregroundStyle(Palette.text2)
                    Text(TokenFormat.compact(t.total))
                        .font(.system(size: 46, weight: .semibold)).tracking(-1)
                }
                Spacer()
                HStack(spacing: 24) {
                    if model.range != .today { Metric(label: "今日", value: TokenFormat.compact(today)) }
                    Metric(label: "缓存命中", value: TokenFormat.percent(t.cacheHitRate))
                    Metric(label: "输出", value: TokenFormat.compact(t.output))
                    Metric(label: "实时合计", value: TokenFormat.speed(model.snapshot.liveTokPerSec), color: Palette.accent)
                }
            }

            if !s.agents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SegmentBar(segments: s.agents.map { (Double($0.totals.total), Palette.agent($0.agent)) })
                    HStack(spacing: 24) {
                        ForEach(s.agents) { a in
                            HStack(spacing: 7) {
                                Circle().fill(Palette.agent(a.agent)).frame(width: 7, height: 7)
                                Text(a.agent.displayName).foregroundStyle(Color(white: 0.9))
                                Text("\(TokenFormat.compact(a.totals.total)) · \(TokenFormat.percent(share(a.totals.total, t.total)))")
                                    .foregroundStyle(Palette.text2)
                            }
                        }
                    }
                    .font(.system(size: 12))
                }
            }

            if s.daily.count > 1 {
                let peak = s.daily.max { $0.total < $1.total }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("每日 · 按 agent 叠加")
                        Spacer()
                        if let peak, peak.total > 0 {
                            Text("峰值 \(DateLabel.short(peak.day)) · \(TokenFormat.compact(peak.total))")
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(Palette.text2)
                    DailyBars(days: s.daily, agent: nil, height: 56)
                }
            }

            ModelTable(stats: s)
        }
    }

    func share(_ v: Int64, _ total: Int64) -> Double? { total > 0 ? Double(v) / Double(total) : nil }
}

struct ModelTable: View {
    var stats: RangeStats
    let columns = [GridItem(.flexible(minimum: 140), alignment: .leading)]

    var body: some View {
        let total = stats.totals.total
        let top = Array(stats.models.prefix(7))
        let rest = stats.models.dropFirst(7)
        let restTotal = rest.reduce(Int64(0)) { $0 + $1.totals.total }

        VStack(spacing: 0) {
            row(cells: ["模型", "Agent", "平均 tok/s", "Token", "占比"], color: Palette.text3, size: 11)
                .padding(.bottom, 6)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.track).frame(height: 1) }
            ForEach(top) { m in
                HStack(spacing: 0) {
                    HStack(spacing: 7) {
                        Circle().fill(Palette.agent(m.agent)).frame(width: 6, height: 6)
                        Text(TokenFormat.modelName(m.model)).foregroundStyle(Color(white: 0.9)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(2)
                    cell(m.agent.shortName, Palette.text2, align: .leading)
                    cell(m.tokPerSec.map { String(format: "%.0f", $0) } ?? "—", Palette.text2)
                    cell(TokenFormat.compact(m.totals.total), Palette.text)
                    cell(TokenFormat.percent(total > 0 ? Double(m.totals.total) / Double(total) : nil), Palette.text2)
                }
                .font(.system(size: 12))
                .padding(.vertical, 5)
            }
            if !rest.isEmpty {
                HStack(spacing: 0) {
                    HStack(spacing: 7) {
                        Circle().fill(Palette.divider).frame(width: 6, height: 6)
                        Text("其他 \(rest.count) 个模型").foregroundStyle(Palette.text2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(2)
                    cell("—", Palette.text3, align: .leading)
                    cell("—", Palette.text3)
                    cell(TokenFormat.compact(restTotal), Palette.text)
                    cell(TokenFormat.percent(total > 0 ? Double(restTotal) / Double(total) : nil), Palette.text2)
                }
                .font(.system(size: 12))
                .padding(.vertical, 5)
            }
            HStack(spacing: 0) {
                Text("合计").frame(maxWidth: .infinity, alignment: .leading).layoutPriority(2)
                cell("\(stats.agents.count) 个 agent", Palette.text2, align: .leading, weight: .regular)
                cell(costText(stats.totals), Palette.text2)
                cell(TokenFormat.compact(total), Palette.text)
                cell("100%", Palette.text)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.top, 7)
            .overlay(alignment: .top) { Rectangle().fill(Palette.divider).frame(height: 1) }
        }
    }

    func row(cells: [String], color: Color, size: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(cells[0]).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(2)
            ForEach(1..<cells.count, id: \.self) { i in
                cell(cells[i], color, align: i == 1 ? .leading : .trailing)
            }
        }
        .font(.system(size: size))
        .foregroundStyle(color)
    }

    func cell(_ s: String, _ color: Color, align: Alignment = .trailing, weight: Font.Weight? = nil) -> some View {
        Text(s)
            .fontWeight(weight)
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(width: 92, alignment: align)
    }
}

// MARK: - 单个 agent

struct AgentPage: View {
    @ObservedObject var model: NotchModel
    var agent: Agent

    var body: some View {
        let s = model.snapshot.stats(model.range)
        let a = s.agent(agent)
        let t = a?.totals ?? TokenTotals()
        let live = model.snapshot.live[agent]
        let models = s.models(for: agent)
        let agentTotal = max(1, t.total)

        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("今日 token").font(.system(size: 12)).foregroundStyle(Palette.text2)
                    Text(TokenFormat.compact(live?.today ?? 0))
                        .font(.system(size: 46, weight: .semibold)).tracking(-1)
                }
                Spacer()
                HStack(spacing: 28) {
                    if model.range != .today {
                        Metric(label: model.range == .all ? "全部" : "近 \(model.range.label)", value: TokenFormat.compact(t.total))
                        Metric(label: "日均", value: TokenFormat.compact(t.total / Int64(s.dayCount)))
                    }
                    Metric(label: "实时", value: TokenFormat.speed(live?.tokPerSec), color: Palette.agent(agent))
                }
            }

            HStack(spacing: 10) {
                StatCell(label: "缓存命中", value: TokenFormat.percent(t.cacheHitRate))
                StatCell(label: "输出", value: TokenFormat.compact(t.output))
                StatCell(label: "缓存写入", value: TokenFormat.compact(t.cacheWrite))
                StatCell(label: "子代理占比", value: TokenFormat.percent(a?.subagentShare))
            }

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(rangeTitle(s)).font(.system(size: 11)).foregroundStyle(Palette.text2)
                    DailyBars(days: s.daily, agent: agent, height: 100)
                        .padding(.top, 24)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    Text("按模型 · \(rangeTitle(s))").font(.system(size: 11)).foregroundStyle(Palette.text2)
                    ForEach(Array(models.prefix(5).enumerated()), id: \.element.id) { i, m in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(TokenFormat.modelName(m.model)).foregroundStyle(Color(white: 0.9))
                                Spacer()
                                Text("\(TokenFormat.compact(m.totals.total)) · \(TokenFormat.percent(Double(m.totals.total) / Double(agentTotal)))")
                                    .foregroundStyle(Palette.text2)
                            }
                            .font(.system(size: 12))
                            Track(fraction: Double(m.totals.total) / Double(agentTotal),
                                  color: i == 0 ? Palette.agent(agent) : Palette.text3)
                        }
                    }
                    if models.isEmpty {
                        Text("这段时间没有记录").font(.system(size: 12)).foregroundStyle(Palette.text3)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - 明细：缓存构成 + 项目耗费

struct DetailPage: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let s = model.snapshot.stats(model.range)
        let t = s.totals
        let total = max(1, t.total)
        let parts: [(String, Int64, Color)] = [
            ("缓存读", t.cacheRead, Palette.accent),
            ("缓存写", t.cacheWrite, Color(white: 0.9)),
            ("新输入", t.input, Palette.text3),
            ("输出", t.output, Palette.grayBar),
        ]

        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Text("缓存命中").font(.system(size: 11)).foregroundStyle(Palette.text2)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(TokenFormat.percent(t.cacheHitRate)).font(.system(size: 40, weight: .semibold)).tracking(-1)
                    Text("缓存读 ÷ 全部输入").font(.system(size: 12)).foregroundStyle(Palette.text3)
                }
                SegmentBar(segments: parts.map { (Double($0.1), $0.2) })
                VStack(spacing: 6) {
                    ForEach(parts, id: \.0) { p in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(p.2).frame(width: 7, height: 7)
                            Text(p.0).foregroundStyle(Color(white: 0.9))
                            Spacer()
                            Text(TokenFormat.compact(p.1))
                            Text(TokenFormat.percent(Double(p.1) / Double(total)))
                                .foregroundStyle(Palette.text2).frame(width: 48, alignment: .trailing)
                        }
                        .font(.system(size: 12))
                    }
                }
                Rectangle().fill(Palette.track).frame(height: 1)
                ForEach(s.agents) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(a.agent.displayName).foregroundStyle(Color(white: 0.9))
                            Spacer()
                            Text("命中 \(TokenFormat.percent(a.totals.cacheHitRate))").foregroundStyle(Palette.text2)
                        }
                        .font(.system(size: 12))
                        Track(fraction: a.totals.cacheHitRate ?? 0, color: Palette.agent(a.agent))
                    }
                }
            }
            .frame(width: 250)

            ProjectList(stats: s)
                .frame(maxWidth: .infinity)
        }
    }
}

struct ProjectList: View {
    var stats: RangeStats

    var body: some View {
        let top = Array(stats.projects.prefix(6))
        let rest = stats.projects.dropFirst(6)
        let restTotal = rest.reduce(Int64(0)) { $0 + $1.total }
        let restCost = rest.reduce(0.0) { $0 + $1.cost }
        let maxP = max(1, top.first?.total ?? 1)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("项目耗费 · \(stats.projects.count) 个项目")
                Spacer()
                ForEach(stats.agents) { a in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Palette.agent(a.agent)).frame(width: 7, height: 7)
                        Text(a.agent.shortName)
                    }
                }
            }
            .font(.system(size: 11)).foregroundStyle(Palette.text2)

            ForEach(top) { p in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(p.name).foregroundStyle(Color(white: 0.9)).lineLimit(1).truncationMode(.middle)
                            .help(p.cwd)
                        Spacer(minLength: 4)
                        Text(TokenFormat.compact(p.total))
                        Text("≈ " + TokenFormat.cost(p.cost)).foregroundStyle(Palette.text2)
                            .frame(width: 64, alignment: .trailing)
                    }
                    .font(.system(size: 12))
                    // 长度按项目之间对比，条内按 agent 分色
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.card)
                            SegmentBar(segments: Agent.allCases.map { (Double(p.perAgent[$0] ?? 0), Palette.agent($0)) },
                                       height: 6, gap: 1)
                                .frame(width: max(4, g.size.width * CGFloat(p.total) / CGFloat(maxP)))
                        }
                    }
                    .frame(height: 6)
                }
            }
            if !rest.isEmpty {
                HStack(spacing: 10) {
                    Text("其他 \(rest.count) 个项目").foregroundStyle(Palette.text2)
                    Spacer()
                    Text(TokenFormat.compact(restTotal))
                    Text("≈ " + TokenFormat.cost(restCost)).foregroundStyle(Palette.text2)
                        .frame(width: 64, alignment: .trailing)
                }
                .font(.system(size: 12))
            }
            HStack(spacing: 10) {
                Text("合计")
                Spacer()
                Text(TokenFormat.compact(stats.totals.total))
                Text(costText(stats.totals)).frame(width: 64, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.top, 8)
            .overlay(alignment: .top) { Rectangle().fill(Palette.divider).frame(height: 1) }
        }
    }
}
