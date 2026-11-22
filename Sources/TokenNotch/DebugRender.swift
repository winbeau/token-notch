import AppKit
import SwiftUI
import TokenCore

/// `TOKEN_NOTCH_RENDER=<目录>`：拿到第一份真实快照后，把各状态 / 各页面离屏渲染成 PNG 然后退出。
/// 用来在没有屏幕录制权限的环境里检查界面。
@MainActor
enum DebugRender {
    static var directory: String? { ProcessInfo.processInfo.environment["TOKEN_NOTCH_RENDER"] }

    static func run(model: NotchModel, into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let snap = model.snapshot
        let claude = snap.live[.claude] ?? LiveStat(agent: .claude, today: 0, lastActivity: Date(), tokPerSec: 42)
        var codex = snap.live[.codex] ?? LiveStat(agent: .codex, today: 0, lastActivity: Date(), tokPerSec: 12)
        if codex.tokPerSec == nil { codex.tokPerSec = 12 }
        var deepseek = snap.live[.deepseek] ?? LiveStat(agent: .deepseek, today: 0, lastActivity: Date(), tokPerSec: 60)
        if deepseek.tokPerSec == nil { deepseek.tokPerSec = 60 }

        let cases: [(String, NotchState, [LiveStat]?, PanelTab, TimeRange)] = [
            ("1-idle", .idle, [], .overview, .week),
            ("2a-active-one", .active, [claude], .overview, .week),
            ("2b-active-two", .active, [claude, codex], .overview, .week),
            ("2c-active-deepseek", .active, [deepseek, claude], .overview, .week),
            ("3-agent-claude-week", .expanded, nil, .agent(.claude), .week),
            ("4-overview-all", .expanded, nil, .overview, .all),
            ("5-detail-all", .expanded, nil, .detail, .all),
            ("6-agent-codex-month", .expanded, nil, .agent(.codex), .month),
            ("7-overview-today", .expanded, nil, .overview, .today),
            ("8-detail-week", .expanded, nil, .detail, .week),
            ("9-agent-deepseek-all", .expanded, nil, .agent(.deepseek), .all),
            ("10-agent-antigravity-all", .expanded, nil, .agent(.antigravity), .all),
            ("11-agent-grok-all", .expanded, nil, .agent(.grok), .all),
            ("12-agent-codex-all", .expanded, nil, .agent(.codex), .all),
        ]
        for lang in Lang.allCases {
        for (name, state, active, tab, range) in cases {
            model.lang = lang
            model.forced = state
            model.overrideActive = active
            model.tab = tab
            model.range = range
            let size = NotchWindowController.windowSize
            let view = NotchRootView(model: model)
                .frame(width: size.width, height: state == .expanded ? size.height : 80)
                .background(Color(red: 75 / 255, green: 82 / 255, blue: 99 / 255))
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let cg = r.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(lang.rawValue)-\(name).png"))
            }
        }
        }
        NSApp.terminate(nil)
    }
}
