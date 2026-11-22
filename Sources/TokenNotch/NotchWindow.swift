import AppKit
import Combine
import SwiftUI

/// 无边框、不抢焦点的面板，贴在刘海处。窗口本身固定大小，形状在 SwiftUI 里变化；
/// 收起时鼠标事件穿透，展开时才接收点击（透明区域由窗口服务器按 alpha 穿透）。
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        // 面板成为 key 之后，鼠标移动事件只发给它；不打开的话本地、全局监听都收不到。
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 悬停诊断日志：`TOKEN_NOTCH_DEBUG=hover` 或 `defaults write dev.token-notch.app debugHover -bool YES`，
/// 写到 ~/.tokens/hover.log。只记判定结果的变化，不记每一次鼠标移动。
@MainActor
final class HoverLog {
    static let enabled: Bool = {
        (ProcessInfo.processInfo.environment["TOKEN_NOTCH_DEBUG"] ?? "").contains("hover")
            || UserDefaults.standard.bool(forKey: "debugHover")
    }()

    private let handle: FileHandle? = {
        guard HoverLog.enabled else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tokens/hover.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()

    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ s: @autoclosure () -> String) {
        guard let handle else { return }
        handle.write(Data("\(clock.string(from: Date())) \(s())\n".utf8))
    }
}

@MainActor
final class NotchWindowController {
    let panel = NotchPanel()
    let model: NotchModel
    private var monitors: [Any] = []
    private var bag: Set<AnyCancellable> = []
    private var pending: DispatchWorkItem?
    private var pendingTarget = false
    private var poll: Timer?
    private var pollFast = false
    private let hoverLog = HoverLog()

    static let windowSize = CGSize(width: NotchModel.panelWidth + 36 * 2 + 40, height: 760)
    static let openDelay: TimeInterval = 0.1
    static let closeDelay: TimeInterval = 0.3
    /// 鼠标在刘海附近时的轮询频率（兜底：鼠标停住不动、事件被别的窗口吃掉时也能判定）。
    static let fastPoll: TimeInterval = 1 / 60
    static let slowPoll: TimeInterval = 1 / 6

    init(model: NotchModel) {
        self.model = model
        let host = NSHostingView(rootView: NotchRootView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        layout()
        panel.orderFrontRegardless()

        model.$hovering.sink { [weak self] h in
            self?.panel.ignoresMouseEvents = !h
        }.store(in: &bag)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &bag)

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse(source: "global") }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.trackMouse(source: "local") }
            return e
        }) { monitors.append(l) }
        schedulePoll(fast: false)
        hoverLog.log("start screen=\(model.geometry.screenFrame) notch=\(model.geometry.notchWidth)x\(model.geometry.notchHeight)")
    }

    func layout() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let g = NotchGeometry.current(for: screen)
        model.geometry = g
        let s = Self.windowSize
        panel.setFrame(CGRect(x: g.screenFrame.midX - s.width / 2, y: g.screenFrame.maxY - s.height,
                              width: s.width, height: s.height), display: true)
    }

    /// 当前形状在屏幕坐标里的热区。
    func hotRect() -> CGRect {
        let g = model.geometry
        let body = model.bodySize
        let flare = model.state.flare
        var w = body.width + flare.width * 2
        var h = body.height
        if !model.hovering {
            // 收起/活动时热区略放宽，方便鼠标甩上去；没有刘海时用菜单栏中间一段
            w += 24
            h = max(h, g.notchHeight) + 4
        } else {
            // 面板高度由视图异步回报，切换页面时可能滞后一帧；留出余量，收回前还会再确认一次
            w += 16
            h += 16
        }
        return CGRect(x: g.screenFrame.midX - w / 2, y: g.screenFrame.maxY - h, width: w, height: h)
    }

    /// 上沿不设限：鼠标顶在屏幕最上沿时 `mouseLocation.y` 等于 `screenFrame.maxY`，
    /// 而 `CGRect.contains` 不含上边界，最常见的“往上一甩”会被判成不在热区。
    func isInside(_ p: CGPoint) -> Bool {
        let r = hotRect()
        return p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= model.geometry.screenFrame.maxY + 1
    }

    func trackMouse(source: String) {
        let p = NSEvent.mouseLocation
        adjustPoll(for: p)
        let inside = isInside(p)
        if inside == model.hovering {
            if pending != nil {
                hoverLog.log("cancel \(pendingTarget ? "open" : "close") [\(source)] p=\(fmt(p))")
                pending?.cancel()
                pending = nil
            }
            return
        }
        guard pending == nil else { return }
        hoverLog.log("schedule \(inside ? "open" : "close") [\(source)] p=\(fmt(p)) rect=\(fmt(hotRect()))"
                     + (p.y >= model.geometry.screenFrame.maxY ? " top-edge" : ""))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pending = nil
            let q = NSEvent.mouseLocation
            let still = isInside(q)
            guard still != model.hovering else { return }
            hoverLog.log("\(still ? "open" : "close") p=\(fmt(q)) state=\(model.state)")
            withAnimation(still ? NotchModel.openAnimation : NotchModel.closeAnimation) {
                self.model.hovering = still
            }
        }
        pending = work
        pendingTarget = inside
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? Self.openDelay : Self.closeDelay), execute: work)
    }

    /// 鼠标在刘海附近（或面板展开、有待定判定）时 60Hz 轮询，否则 6Hz。
    private func adjustPoll(for p: CGPoint) {
        let g = model.geometry
        let near = model.hovering || pending != nil
            || (p.y >= g.screenFrame.maxY - 240 && abs(p.x - g.screenFrame.midX) <= NotchModel.panelWidth / 2 + 160)
        if near != pollFast { schedulePoll(fast: near) }
    }

    private func schedulePoll(fast: Bool) {
        poll?.invalidate()
        pollFast = fast
        let t = Timer(timeInterval: fast ? Self.fastPoll : Self.slowPoll, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse(source: "poll") }
        }
        t.tolerance = fast ? 0.004 : 0.05
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    private func fmt(_ p: CGPoint) -> String { String(format: "(%.1f,%.1f)", p.x, p.y) }
    private func fmt(_ r: CGRect) -> String {
        String(format: "[x %.0f…%.0f, y %.0f…%.0f]", r.minX, r.maxX, r.minY, r.maxY)
    }
}
