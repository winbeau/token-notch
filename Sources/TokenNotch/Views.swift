import AppKit
import SwiftUI
import TokenCore

// MARK: - 根视图

struct NotchRootView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let state = model.state
        let body = model.bodySize
        let flare = state.flare
        let shape = NotchShape(flare: flare, bottomRadius: state.bottomRadius)

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                switch state {
                case .idle:
                    Color.clear
                case .active:
                    WingsView(model: model)
                        .padding(.horizontal, flare.width)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.08)),
                            removal: .opacity.animation(.easeIn(duration: 0.1))))
                case .expanded:
                    PanelView(model: model)
                        .padding(.horizontal, flare.width + 28)
                        .padding(.top, model.geometry.notchHeight + 8)
                        .padding(.bottom, 24)
                        .frame(width: body.width + flare.width * 2)
                        .background(HeightReader { h in
                            if abs(model.panelHeight - h) > 0.5 { model.panelHeight = h }
                        })
                        // 形状先张开，内容稍后淡入；收回时内容先淡出，形状再缩回。
                        // 内容宽度固定（不随形状插值），形状变形时不会重新布局抖动。
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                                .animation(.easeOut(duration: 0.24).delay(0.12)),
                            removal: .opacity.animation(.easeIn(duration: 0.09))))
                }
            }
            .frame(width: body.width + flare.width * 2,
                   height: state == .expanded ? nil : body.height, alignment: .top)
            .background(shape.fill(Color.black).opacity(state == .idle && !model.geometry.hasNotch ? 0 : 1))
            .clipShape(shape)
            .contextMenu { ContextMenuItems() }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        // 不挂隐式动画：展开 / 收回 / 两翼各自在触发处用不同的曲线（见 NotchModel.openAnimation 等）。
    }
}

struct HeightReader: View {
    var onChange: (CGFloat) -> Void
    var body: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { onChange(g.size.height) }
                .onChange(of: g.size.height) { _, h in onChange(h) }
        }
    }
}

struct ContextMenuItems: View {
    var body: some View {
        Button("重新统计（清空 ~/.tokens 后回填）") {
            (NSApp.delegate as? AppDelegate)?.rebuild()
        }
        Button("在 Finder 中打开 ~/.tokens") {
            NSWorkspace.shared.open(Store.defaultDirectory)
        }
        Divider()
        Button("退出 Token Notch") { NSApp.terminate(nil) }
    }
}

// MARK: - 两翼（活动状态）

struct WingsView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let active = model.activeAgents
        HStack(spacing: 0) {
            if let live = model.currentLive {
                HStack(spacing: 7) {
                    PulseDot(color: Palette.agent(live.agent))
                    Text(live.agent.shortName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.text2)
                }
                .padding(.leading, 18)
                .frame(width: NotchModel.wingWidth, alignment: .leading)
                .id("L-\(live.agent.rawValue)")
                .transition(.opacity)

                Spacer(minLength: model.geometry.notchWidth)

                HStack(spacing: 8) {
                    if let tps = live.tokPerSec {
                        Text(TokenFormat.speed(tps))
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.agent(live.agent))
                    }
                    Text(TokenFormat.compact(live.today))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    if active.count > 1 {
                        HStack(spacing: 3) {
                            ForEach(0..<active.count, id: \.self) { i in
                                Circle()
                                    .fill(i == model.rotation % active.count ? Palette.text : Palette.divider)
                                    .frame(width: 4, height: 4)
                            }
                        }
                    }
                }
                .monospacedDigit()
                .padding(.trailing, 18)
                .frame(width: NotchModel.wingWidth, alignment: .trailing)
                .id("R-\(live.agent.rawValue)")
                .transition(.opacity)
            }
        }
        .frame(height: model.geometry.notchHeight)
    }
}

struct PulseDot: View {
    var color: Color
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .background(Circle().fill(color.opacity(0.25)).frame(width: 13, height: 13).scaleEffect(on ? 1 : 0.6))
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

// MARK: - 展开面板

struct PanelView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(model.tabs, id: \.self) { tab in
                        TabPill(title: title(tab), dot: dot(tab), selected: model.tab == tab) {
                            withAnimation(.easeInOut(duration: 0.2)) { model.tab = tab }
                        }
                    }
                }
                Spacer(minLength: 12)
                RangePicker(selection: $model.range)
            }
            .frame(height: 20)

            Group {
                switch model.tab {
                case .overview: OverviewPage(model: model)
                case .agent(let a): AgentPage(model: model, agent: a)
                case .detail: DetailPage(model: model)
                }
            }
            .transition(.opacity)
        }
        .foregroundStyle(Palette.text)
        .monospacedDigit()
    }

    func title(_ t: PanelTab) -> String {
        switch t {
        case .overview: return "概览"
        case .agent(let a): return a.displayName
        case .detail: return "明细"
        }
    }

    func dot(_ t: PanelTab) -> Color? {
        if case .agent(let a) = t, model.isLive(a) { return Palette.agent(a) }
        return nil
    }
}

struct TabPill: View {
    var title: String
    var dot: Color?
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 5, height: 5) }
                Text(title)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .foregroundStyle(selected ? Palette.text : Palette.text3)
            .background(Capsule().fill(selected ? Palette.track : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct RangePicker: View {
    @Binding var selection: TimeRange

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TimeRange.allCases) { r in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selection = r }
                } label: {
                    Text(r.label)
                        .font(.system(size: 11))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 1)
                        .foregroundStyle(selection == r ? Palette.text : Palette.text3)
                        .background(Capsule().fill(selection == r ? Palette.muted : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Palette.card))
    }
}

// MARK: - 小组件

struct Metric: View {
    var label: String
    var value: String
    var color: Color = Palette.text

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.text2)
            Text(value).font(.system(size: 20, weight: .semibold)).foregroundStyle(color)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

struct StatCell: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(Palette.text2)
            Text(value).font(.system(size: 17, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
    }
}

/// 水平分段条：各段按占比分宽，小段至少 3pt 可见。
struct SegmentBar: View {
    var segments: [(value: Double, color: Color)]
    var height: CGFloat = 8
    var gap: CGFloat = 2

    var body: some View {
        GeometryReader { g in
            let parts = segments.filter { $0.value > 0 }
            let sum = parts.reduce(0) { $0 + $1.value }
            let avail = g.size.width - gap * CGFloat(max(0, parts.count - 1))
            HStack(spacing: gap) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, s in
                    Rectangle().fill(s.color)
                        .frame(width: max(3, sum > 0 ? avail * s.value / sum : 0))
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
    }
}

struct Track: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(color).frame(width: g.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: height)
    }
}

/// 每日柱图。`agent` 为 nil 时按 agent 叠加着色；悬停显示当天明细。
struct DailyBars: View {
    var days: [DayStat]
    var agent: Agent?
    var height: CGFloat = 100
    var showLabels = true
    @State private var hovered: String?

    var body: some View {
        let values = days.map { d in agent.map { a in d.perAgent[a] ?? 0 } ?? d.total }
        let maxV = max(1, values.max() ?? 1)
        let spacing: CGFloat = days.count > 14 ? 2 : 8
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                    let isToday = i == days.count - 1
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if let agent {
                            bar(values[i], maxV, color: isToday ? Palette.agent(agent) : (hovered == d.day ? Palette.grayBar : Palette.muted))
                        } else {
                            ForEach(Agent.allCases.reversed(), id: \.self) { a in
                                let v = d.perAgent[a] ?? 0
                                if v > 0 {
                                    Rectangle().fill(Palette.agent(a).opacity(hovered == nil || hovered == d.day ? 1 : 0.55))
                                        .frame(height: max(1, height * CGFloat(v) / CGFloat(maxV)))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in hovered = inside ? d.day : (hovered == d.day ? nil : hovered) }
                }
            }
            .frame(height: height)
            .overlay(alignment: .topLeading) { tooltip(values: values) }

            if showLabels {
                labels
            }
        }
    }

    @ViewBuilder
    func bar(_ v: Int64, _ maxV: Int64, color: Color) -> some View {
        let h = v == 0 ? 1 : max(2, height * CGFloat(v) / CGFloat(maxV))
        RoundedRectangle(cornerRadius: days.count > 14 ? 1 : 4, style: .continuous)
            .fill(v == 0 ? Palette.track : color)
            .frame(height: h)
    }

    @ViewBuilder
    func tooltip(values: [Int64]) -> some View {
        if let hovered, let i = days.firstIndex(where: { $0.day == hovered }) {
            let d = days[i]
            let parts = agent == nil
                ? Agent.allCases.compactMap { a in d.perAgent[a].map { v in "\(a.shortName) \(TokenFormat.compact(v))" } }
                : []
            Text("\(DateLabel.short(d.day)) \(DateLabel.weekday(d.day)) · \(TokenFormat.compact(values[i]))"
                 + (parts.count > 1 ? "（" + parts.joined(separator: "，") + "）" : ""))
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.track))
                .offset(y: -22)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    var labels: some View {
        if days.count <= 14 {
            HStack(spacing: days.count > 14 ? 2 : 8) {
                ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                    Text(i == days.count - 1 ? "今" : DateLabel.weekdayShort(d.day))
                        .font(.system(size: 11))
                        .foregroundStyle(i == days.count - 1 ? Palette.text : Palette.text3)
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            HStack {
                Text(DateLabel.short(days.first?.day ?? ""))
                Spacer()
                Text(DateLabel.short(days[days.count / 2].day))
                Spacer()
                Text("今天")
            }
            .font(.system(size: 10))
            .foregroundStyle(Palette.text3)
        }
    }
}

enum DateLabel {
    static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func short(_ day: String) -> String { String(day.suffix(5)) }

    static func weekday(_ day: String) -> String {
        guard let d = parser.date(from: day) else { return "" }
        return ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][Calendar.current.component(.weekday, from: d) - 1]
    }

    static func weekdayShort(_ day: String) -> String {
        String(weekday(day).suffix(1))
    }
}
