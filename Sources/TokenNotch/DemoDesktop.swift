import AppKit
import SwiftUI
import TokenCore

/// 演示画面里桌面上的 agent 窗口：交代一下刘海里的数字是哪来的。它们是背景，主角是刘海，
/// 所以只有两个、个头小、半透明、滚得慢。窗口里的内容全是虚构的。
@MainActor
enum DemoDesktop {
    enum Tone { case prompt, dim, edit, ok, plain }

    struct Window {
        var title: String
        var agent: Agent
        /// 在画布上的位置（左上角原点）
        var frame: CGRect
        var lines: [(Tone, String)]
    }

    static let visibleLines = 4
    /// 每隔多久滚一行。窗口只是背景，滚得慢一点，不和刘海抢注意力
    static let stepEvery = 1.3
    /// 窗口四周留给阴影的边
    static let margin: CGFloat = 30

    /// 只放两个小窗口，贴在画面底部两角：正好是两翼轮播的那两个 agent。
    static let windows: [Window] = [
        Window(title: "atlas-web — claude", agent: .claude, frame: CGRect(x: 24, y: 520, width: 290, height: 112), lines: [
            (.prompt, "› add retry to the uploader"),
            (.dim, "  Read   src/upload/client.ts"),
            (.edit, "  Edit   src/upload/client.ts  +18 −4"),
            (.dim, "  Bash   npm test -- upload"),
            (.ok, "  ✓ 42 passed (3.1s)"),
            (.prompt, "› now cover the timeout path"),
            (.edit, "  Edit   src/upload/retry.test.ts  +27"),
            (.ok, "  ✓ 45 passed (3.4s)"),
        ]),
        Window(title: "api-gateway — codex", agent: .codex, frame: CGRect(x: 686, y: 520, width: 290, height: 112), lines: [
            (.prompt, "› rate-limit the /export endpoint"),
            (.dim, "• Ran rg \"export\" src/routes"),
            (.plain, "• Edited src/routes/export.ts (+24 −3)"),
            (.dim, "• Ran pnpm test export"),
            (.ok, "  18 passed"),
            (.prompt, "› document the 429 response"),
            (.plain, "• Edited openapi.yaml (+12)"),
        ]),
    ]

    /// 每个窗口滚到各个位置时的画面：第 k 张以第 k 行结尾（内容循环）。
    static func renderStates() -> [[CGImage]] {
        windows.map { w in
            (0..<w.lines.count).compactMap { k in
                let shown = (0..<visibleLines).map { w.lines[(k - visibleLines + 1 + $0 + w.lines.count * 2) % w.lines.count] }
                let view = DemoWindowView(window: w, lines: shown).padding(margin)
                let r = ImageRenderer(content: view)
                r.scale = DemoVideo.scale
                return r.cgImage
            }
        }
    }

    /// 时刻 t 各窗口该画哪一张、画在哪。几个窗口错开滚动，不同时跳。
    static func layers(_ states: [[CGImage]], at t: Double) -> [(CGImage, CGRect)] {
        zip(windows, states).enumerated().compactMap { i, pair in
            let (w, images) = pair
            guard !images.isEmpty else { return nil }
            let step = Int(t / stepEvery + Double(i) * 0.5) + visibleLines - 1 + i * 2
            return (images[step % images.count], w.frame.insetBy(dx: -margin, dy: -margin))
        }
    }
}

private struct DemoWindowView: View {
    var window: DemoDesktop.Window
    var lines: [(DemoDesktop.Tone, String)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Palette.divider).frame(width: 9, height: 9) }
                Text(window.title).font(.system(size: 12)).foregroundStyle(Palette.text3).padding(.leading, 6)
                Spacer()
                Circle().fill(Palette.agent(window.agent)).frame(width: 6, height: 6)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.1)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(line.0))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(width: window.frame.width, height: window.frame.height)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(red: 0.08, green: 0.08, blue: 0.095).opacity(0.78)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
        .environment(\.colorScheme, .dark)
    }

    func color(_ tone: DemoDesktop.Tone) -> Color {
        switch tone {
        case .prompt: return Palette.text
        case .dim: return Palette.grayBar
        case .edit: return window.agent == .codex ? Palette.text2 : Palette.agent(window.agent)
        case .ok: return Color(red: 0.44, green: 0.81, blue: 0.56)
        case .plain: return Color(white: 0.78)
        }
    }
}
