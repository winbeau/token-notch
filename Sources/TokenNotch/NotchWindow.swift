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
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchWindowController {
    let panel = NotchPanel()
    let model: NotchModel
    private var monitors: [Any] = []
    private var bag: Set<AnyCancellable> = []
    private var pending: DispatchWorkItem?

    static let windowSize = CGSize(width: NotchModel.panelWidth + 36 * 2 + 40, height: 760)
    static let openDelay: TimeInterval = 0.12
    static let closeDelay: TimeInterval = 0.35

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

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.trackMouse() }
            return e
        }) { monitors.append(l) }
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
            w += 16
            h += 12
        }
        return CGRect(x: g.screenFrame.midX - w / 2, y: g.screenFrame.maxY - h, width: w, height: h)
    }

    func trackMouse() {
        let inside = hotRect().contains(NSEvent.mouseLocation)
        if inside == model.hovering {
            pending?.cancel()
            pending = nil
            return
        }
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pending = nil
            let still = hotRect().contains(NSEvent.mouseLocation)
            if still != self.model.hovering {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { self.model.hovering = still }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? Self.openDelay : Self.closeDelay), execute: work)
    }
}
