import AppKit
import SwiftUI
import TokenCore

enum NotchState: Equatable {
    case idle        // 和刘海融为一体
    case active      // 有 agent 在跑：两翼浮出
    case expanded    // 鼠标悬停：展开面板
}

enum PanelTab: Hashable {
    case overview
    case agent(Agent)
    case detail
}

/// 刘海的物理尺寸（没有刘海的屏幕用菜单栏高度和一个默认宽度）。
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool

    static func current(for screen: NSScreen) -> NotchGeometry {
        let f = screen.frame
        if screen.safeAreaInsets.top > 0,
           let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return NotchGeometry(screenFrame: f, notchWidth: f.width - l.width - r.width,
                                 notchHeight: screen.safeAreaInsets.top, hasNotch: true)
        }
        let menuBar = max(24, f.maxY - screen.visibleFrame.maxY)
        return NotchGeometry(screenFrame: f, notchWidth: 200, notchHeight: menuBar, hasNotch: false)
    }

    /// 优先内置刘海屏，否则主屏。
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var snapshot: Snapshot = .empty
    @Published var geometry: NotchGeometry
    @Published var hovering = false
    @Published var tab: PanelTab = .overview
    @Published var range: TimeRange = .week
    @Published var rotation = 0
    /// 界面语言，右键菜单切换，存在 UserDefaults。调试可用 `TOKEN_NOTCH_LANG=en` 覆盖。
    @Published var lang: Lang = ProcessInfo.processInfo.environment["TOKEN_NOTCH_LANG"].flatMap(Lang.init(rawValue:)) ?? .saved {
        didSet {
            if DebugRender.directory == nil, DemoVideo.directory == nil {
                UserDefaults.standard.set(lang.rawValue, forKey: Lang.defaultsKey)
            }
        }
    }
    var t: L10n { L10n(lang: lang) }
    /// 展开面板内容的实际高度（由视图回报），用于热区判定。
    @Published var panelHeight: CGFloat = 420

    static let wingWidth: CGFloat = 146
    static let panelWidth: CGFloat = 680
    static let rotateEvery: TimeInterval = 4

    /// 展开：弹簧略慢、轻微回弹；收回：更快、不回弹；两翼出现 / 消失介于两者之间。
    static let openAnimation = Animation.spring(response: 0.46, dampingFraction: 0.84)
    static let closeAnimation = Animation.spring(response: 0.3, dampingFraction: 0.96)
    static let wingsAnimation = Animation.spring(response: 0.4, dampingFraction: 0.88)

    private var rotateTimer: Timer?
    private var clock: Timer?
    @Published private(set) var now = Date()

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        applyForcedTabAndRange()
        rotateTimer = Timer.scheduledTimer(withTimeInterval: Self.rotateEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.activeAgents.count > 1 {
                    withAnimation(.easeInOut(duration: 0.45)) { self.rotation += 1 }
                }
            }
        }
        // 活跃窗口按时间过期，即使没有新快照也要重新判定。
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let next = Date()
                // 活跃窗口到期时两翼要收起，带上动画；其余时候静默更新。
                if self.overrideActive == nil,
                   self.snapshot.activeAgents(now: self.now).isEmpty != self.snapshot.activeAgents(now: next).isEmpty {
                    withAnimation(Self.wingsAnimation) { self.now = next }
                } else {
                    self.now = next
                }
            }
        }
    }

    /// 离屏渲染时伪造的活跃 agent。
    var overrideActive: [LiveStat]?

    var activeAgents: [LiveStat] { overrideActive ?? snapshot.activeAgents(now: now) }

    /// 轮播中当前显示的 agent。
    var currentLive: LiveStat? {
        let a = activeAgents
        guard !a.isEmpty else { return nil }
        return a[rotation % a.count]
    }

    /// 调试用：`TOKEN_NOTCH_FORCE=active|expanded[:overview|claude|codex|detail][:today|week|month|all]`
    /// 固定在某个状态，便于截图检查；正常使用不设置。
    var forced: NotchState? = {
        guard let v = ProcessInfo.processInfo.environment["TOKEN_NOTCH_FORCE"] else { return nil }
        switch v.split(separator: ":").first {
        case "active": return .active
        case "expanded": return .expanded
        case "idle": return .idle
        default: return nil
        }
    }()

    func applyForcedTabAndRange() {
        guard let v = ProcessInfo.processInfo.environment["TOKEN_NOTCH_FORCE"] else { return }
        let parts = v.split(separator: ":").map(String.init)
        if parts.count > 1 {
            switch parts[1] {
            case "detail": tab = .detail
            case "overview": tab = .overview
            default: if let a = Agent(rawValue: parts[1]) { tab = .agent(a) }
            }
        }
        if parts.count > 2, let r = TimeRange(rawValue: parts[2]) { range = r }
    }

    var state: NotchState {
        if let forced { return forced == .active && activeAgents.isEmpty ? .idle : forced }
        if hovering { return .expanded }
        return activeAgents.isEmpty ? .idle : .active
    }

    /// 当前状态下黑色形状主体（不含两侧外圆角）的尺寸。
    var bodySize: CGSize {
        switch state {
        case .idle: return CGSize(width: geometry.notchWidth, height: geometry.notchHeight)
        case .active: return CGSize(width: geometry.notchWidth + Self.wingWidth * 2, height: geometry.notchHeight)
        case .expanded: return CGSize(width: max(Self.panelWidth, geometry.notchWidth + 120), height: panelHeight)
        }
    }

    var tabs: [PanelTab] {
        [.overview] + snapshot.knownAgents.map { .agent($0) } + [.detail]
    }

    func isLive(_ a: Agent) -> Bool {
        snapshot.live[a]?.isActive(now: now) ?? false
    }
}

enum Palette {
    static let accent = Color(red: 1.0, green: 159 / 255, blue: 10 / 255)        // #FF9F0A
    static let text = Color(white: 0.96)                                          // #F5F5F7
    static let text2 = Color(red: 161 / 255, green: 161 / 255, blue: 166 / 255)   // #A1A1A6
    static let text3 = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)   // #8E8E93
    static let card = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)       // #1C1C1E
    static let track = Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255)      // #2C2C2E
    static let muted = Color(red: 58 / 255, green: 58 / 255, blue: 60 / 255)      // #3A3A3C
    static let grayBar = Color(red: 99 / 255, green: 99 / 255, blue: 102 / 255)   // #636366
    static let divider = Color(red: 72 / 255, green: 72 / 255, blue: 74 / 255)    // #48484A

    /// 各 agent 的颜色取自各家 logo，在黑底上略提亮：
    /// Claude 用 Anthropic 的珊瑚橙；Codex（OpenAI）和 Grok（xAI）的 logo 都是黑白，分别取近白和中灰；
    /// Gemini 星芒渐变取偏紫的一端，和 DeepSeek 鲸鱼蓝拉开。
    static func agent(_ a: Agent) -> Color {
        switch a {
        case .claude: return Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)       // #D97757
        case .codex: return Color(red: 229 / 255, green: 229 / 255, blue: 234 / 255)       // #E5E5EA
        case .antigravity: return Color(red: 167 / 255, green: 139 / 255, blue: 250 / 255) // #A78BFA
        case .grok: return Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)        // #8E8E93
        case .deepseek: return Color(red: 91 / 255, green: 121 / 255, blue: 1.0)           // #5B79FF
        }
    }
}
