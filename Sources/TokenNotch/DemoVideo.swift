import AppKit
import SwiftUI
import TokenCore

/// `TOKEN_NOTCH_DEMO_VIDEO=<目录>`（配合 `TOKEN_NOTCH_DEMO=1`）：生成演示视频的逐帧图片和几张静态截图，然后退出。
/// 用 `scripts/make-demo.sh` 调用，再由 ffmpeg 合成 MP4 / GIF。
///
/// 关键帧是真实视图离屏渲染出来的；中间帧在这里合成：刘海形状用和应用里一样的 NotchShape、
/// 一样的弹簧参数插值，内容按应用里的节奏淡入淡出，外加一个移动的鼠标指针。
@MainActor
enum DemoVideo {
    static var directory: String? { ProcessInfo.processInfo.environment["TOKEN_NOTCH_DEMO_VIDEO"] }

    static let canvas = CGSize(width: 1000, height: 660)
    static let scale: CGFloat = 2
    static let fps = 30.0
    static let viewSize = CGSize(width: NotchWindowController.windowSize.width, height: 640)

    struct Shape {
        var w: CGFloat, h: CGFloat, flareW: CGFloat, flareH: CGFloat, radius: CGFloat

        static func lerp(_ a: Shape, _ b: Shape, _ t: CGFloat) -> Shape {
            func l(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
            return Shape(w: l(a.w, b.w), h: max(1, l(a.h, b.h)), flareW: max(0, l(a.flareW, b.flareW)),
                         flareH: max(0, l(a.flareH, b.flareH)), radius: max(0, l(a.radius, b.radius)))
        }
    }

    struct Key {
        var image: CGImage
        var shape: Shape
    }

    // MARK: 曲线

    /// 阻尼弹簧的位移（0→1），与 SwiftUI .spring(response:dampingFraction:) 同一模型。
    static func spring(_ t: Double, response: Double, damping: Double) -> Double {
        guard t > 0 else { return 0 }
        let w = 2 * Double.pi / response, z = damping
        let wd = w * sqrt(1 - z * z)
        return 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
    }

    static func ease(_ t: Double) -> Double { t <= 0 ? 0 : t >= 1 ? 1 : t * t * (3 - 2 * t) }

    /// 从 delay 开始、持续 dur 的淡入（ease-out）。
    static func fadeIn(_ t: Double, delay: Double, dur: Double) -> Double {
        let x = max(0, min(1, (t - delay) / dur))
        return 1 - (1 - x) * (1 - x)
    }

    // MARK: 入口

    static func run(model: NotchModel, into dir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fakeScreen = CGRect(origin: .zero, size: canvas)
        model.geometry = NotchGeometry(screenFrame: fakeScreen, notchWidth: 190, notchHeight: 32, hasNotch: true)
        for lang in Lang.allCases {
            render(model: model, lang: lang, dir: (dir as NSString).appendingPathComponent(lang.rawValue))
        }
        NSApp.terminate(nil)
    }

    static func render(model: NotchModel, lang: Lang, dir: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: dir)
        try? fm.createDirectory(atPath: dir + "/frames", withIntermediateDirectories: true)
        model.lang = lang
        let snap = model.snapshot
        let live = snap.activeAgents()
        let claude = live.first { $0.agent == .claude } ?? LiveStat(agent: .claude, today: 0, lastActivity: Date(), tokPerSec: 128)
        let codex = live.first { $0.agent == .codex } ?? LiveStat(agent: .codex, today: 0, lastActivity: Date(), tokPerSec: 46)

        // 两翼轮播：Claude、Codex 打头，其余正在跑的 agent 跟在后面
        let active = [claude, codex] + live.filter { $0.agent != .claude && $0.agent != .codex }

        func key(_ state: NotchState, active: [LiveStat]? = nil, rotation: Int = 0,
                 tab: PanelTab = .overview, range: TimeRange = .week) -> Key? {
            model.forced = state
            model.overrideActive = active
            model.rotation = rotation
            model.tab = tab
            model.range = range
            let view = NotchRootView(model: model).frame(width: viewSize.width, height: viewSize.height)
            let r = ImageRenderer(content: view)
            r.scale = scale
            guard let img = r.cgImage else { return nil }
            let flare = state.flare
            return Key(image: img, shape: Shape(w: model.bodySize.width + flare.width * 2, h: measuredHeight(img),
                                                flareW: flare.width, flareH: flare.height, radius: state.bottomRadius))
        }

        guard let idle = key(.idle, active: []),
              let wingsA = key(.active, active: active, rotation: 0),
              let wingsB = key(.active, active: active, rotation: 1),
              let overview = key(.expanded, tab: .overview, range: .week),
              let agent = key(.expanded, tab: .agent(.claude), range: .week),
              let detail = key(.expanded, tab: .detail, range: .month),
              let background = backgroundImage(lang: lang) else { return }

        // 标签在画面里的大致位置（按 tab 文案宽度估计），鼠标点过去
        let left = (canvas.width - viewSize.width) / 2
        let tabY: CGFloat = 50
        let tabClaude = CGPoint(x: left + (lang == .en ? 186 : 150), y: tabY)
        let tabDetail = CGPoint(x: left + (lang == .en ? 470 : 426), y: tabY)
        let notch = CGPoint(x: canvas.width / 2 + 6, y: 12)
        let rest = CGPoint(x: canvas.width * 0.7, y: canvas.height * 0.82)

        var frames: [(Key, Key?, Double, Double, Double, CGPoint, Bool)] = []   // a, b, 形状进度, a 透明度, b 透明度, 鼠标, 按下
        var cursor = rest

        func hold(_ k: Key, _ secs: Double, moveTo target: CGPoint? = nil, moveDur: Double = 0.6) {
            let n = Int(secs * fps)
            let start = cursor
            for i in 0..<n {
                let t = Double(i) / fps
                if let target {
                    let p = CGFloat(ease(t / moveDur))
                    cursor = CGPoint(x: start.x + (target.x - start.x) * p, y: start.y + (target.y - start.y) * p)
                }
                frames.append((k, nil, 1, 1, 0, cursor, false))
            }
        }
        func click(_ k: Key) {
            for _ in 0..<Int(0.12 * fps) { frames.append((k, nil, 1, 1, 0, cursor, true)) }
        }
        func transition(_ a: Key, _ b: Key, _ secs: Double, shape: (Double) -> Double,
                        outA: (Double) -> Double, inB: (Double) -> Double) {
            for i in 0..<Int(secs * fps) {
                let t = Double(i) / fps
                frames.append((a, b, shape(t), outA(t), inB(t), cursor, false))
            }
        }
        let wings = { (t: Double) in spring(t, response: 0.4, damping: 0.88) }
        let open = { (t: Double) in spring(t, response: 0.46, damping: 0.84) }
        let close = { (t: Double) in spring(t, response: 0.3, damping: 0.96) }
        let page = { (t: Double) in ease(t / 0.3) }

        hold(idle, 0.5)
        transition(idle, wingsA, 0.6, shape: wings, outA: { _ in 1 }, inB: { fadeIn($0, delay: 0.08, dur: 0.2) })
        hold(wingsA, 0.9)
        transition(wingsA, wingsB, 0.4, shape: { _ in 1 }, outA: { 1 - ease($0 / 0.4) }, inB: { ease($0 / 0.4) })
        hold(wingsB, 0.65, moveTo: notch, moveDur: 0.55)
        transition(wingsB, overview, 0.8, shape: open, outA: { 1 - ease($0 / 0.09) },
                   inB: { fadeIn($0, delay: 0.12, dur: 0.24) })
        hold(overview, 1.5, moveTo: CGPoint(x: canvas.width / 2 + 40, y: 230), moveDur: 0.5)
        hold(overview, 0.45, moveTo: tabClaude, moveDur: 0.4)
        click(overview)
        transition(overview, agent, 0.35, shape: page, outA: { 1 - ease($0 / 0.2) }, inB: { ease($0 / 0.25) })
        hold(agent, 1.5)
        hold(agent, 0.45, moveTo: tabDetail, moveDur: 0.4)
        click(agent)
        transition(agent, detail, 0.35, shape: page, outA: { 1 - ease($0 / 0.2) }, inB: { ease($0 / 0.25) })
        hold(detail, 1.7)
        hold(detail, 0.5, moveTo: rest, moveDur: 0.45)
        transition(detail, wingsB, 0.55, shape: close, outA: { 1 - ease($0 / 0.09) },
                   inB: { fadeIn($0, delay: 0.15, dur: 0.2) })
        hold(wingsB, 0.8)
        transition(wingsB, idle, 0.5, shape: wings, outA: { 1 - ease($0 / 0.1) }, inB: { _ in 0 })
        hold(idle, 0.3)

        // 桌面上的 agent 窗口随时间往下滚
        let windowStates = DemoDesktop.renderStates()
        for (i, f) in frames.enumerated() {
            guard let img = compose(background: background, desktop: DemoDesktop.layers(windowStates, at: Double(i) / fps),
                                    a: f.0, b: f.1, p: f.2, alphaA: f.3, alphaB: f.4,
                                    cursor: f.5, pressed: f.6) else { continue }
            write(img, to: String(format: "%@/frames/%04d.jpg", dir, i), jpeg: true)
        }
        // 静态截图：各页面停稳时的样子
        for (name, k) in [("overview", overview), ("agent", agent), ("detail", detail), ("wings", wingsA)] {
            if let img = compose(background: background, desktop: DemoDesktop.layers(windowStates, at: 0),
                                 a: k, b: nil, p: 1, alphaA: 1, alphaB: 0, cursor: nil, pressed: false) {
                write(img, to: "\(dir)/\(name).jpg", jpeg: true)
            }
        }
    }

    // MARK: 合成

    /// 关键帧里黑色形状的高度：中间一列最后一个不透明像素。
    static func measuredHeight(_ img: CGImage) -> CGFloat {
        guard let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return 32 }
        let bpr = img.bytesPerRow, bpp = img.bitsPerPixel / 8
        let alphaOffset: Int = {
            switch img.alphaInfo {
            case .premultipliedFirst, .first, .noneSkipFirst: return 0
            default: return bpp - 1
            }
        }()
        let x = img.width / 2 + Int(60 * scale)   // 避开刘海中线，取主体一侧
        var last = 0
        for y in 0..<img.height where p[y * bpr + x * bpp + alphaOffset] > 128 { last = y }
        return CGFloat(last + 1) / scale
    }

    static func backgroundImage(lang: Lang) -> CGImage? {
        // 壁纸：`TOKEN_NOTCH_DEMO_WALLPAPER` 指向一张图片时铺满画面，否则用渐变
        let wallpaper = ProcessInfo.processInfo.environment["TOKEN_NOTCH_DEMO_WALLPAPER"].flatMap { NSImage(contentsOfFile: $0) }
        let view = ZStack(alignment: .top) {
            if let wallpaper {
                Image(nsImage: wallpaper).resizable().scaledToFill()
                    .frame(width: canvas.width, height: canvas.height).clipped()
            } else {
                LinearGradient(colors: [Color(red: 0.13, green: 0.16, blue: 0.27), Color(red: 0.30, green: 0.24, blue: 0.40),
                                        Color(red: 0.55, green: 0.38, blue: 0.42)],
                               startPoint: .top, endPoint: .bottom)
            }
            HStack(spacing: 18) {
                Text("Token Notch").fontWeight(.semibold)
                Text(lang == .en ? "File" : "文件")
                Text(lang == .en ? "View" : "显示")
                Spacer()
                Text(lang == .en ? "Sun 10:41" : "周日 10:41")
            }
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(Color.black.opacity(0.22))
        }
        .frame(width: canvas.width, height: canvas.height)
        let r = ImageRenderer(content: view)
        r.scale = scale
        return r.cgImage
    }

    static func compose(background: CGImage, desktop: [(CGImage, CGRect)] = [], a: Key, b: Key?, p: Double, alphaA: Double, alphaB: Double,
                        cursor: CGPoint?, pressed: Bool) -> CGImage? {
        let pw = Int(canvas.width * scale), ph = Int(canvas.height * scale)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // 换成左上角原点，和 SwiftUI 的坐标一致
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)
        func draw(_ img: CGImage, in rect: CGRect, alpha: CGFloat = 1) {
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
            ctx.restoreGState()
        }
        draw(background, in: CGRect(origin: .zero, size: canvas))
        for (image, rect) in desktop { draw(image, in: rect) }

        let s = b.map { Shape.lerp(a.shape, $0.shape, CGFloat(p)) } ?? a.shape
        let rect = CGRect(x: canvas.width / 2 - s.w / 2, y: 0, width: s.w, height: s.h)
        // NotchShape 从 (0,0) 画起，不看 rect 的原点，自己平移
        var move = CGAffineTransform(translationX: rect.minX, y: rect.minY)
        let path = NotchShape(flare: CGSize(width: s.flareW, height: s.flareH), bottomRadius: s.radius)
            .path(in: CGRect(origin: .zero, size: rect.size)).cgPath.copy(using: &move)!
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let viewRect = CGRect(x: (canvas.width - viewSize.width) / 2, y: 0, width: viewSize.width, height: viewSize.height)
        if alphaA > 0.001 { draw(a.image, in: viewRect, alpha: CGFloat(min(1, alphaA))) }
        if let b, alphaB > 0.001 { draw(b.image, in: viewRect, alpha: CGFloat(min(1, alphaB))) }
        ctx.restoreGState()

        if let c = cursor { drawCursor(ctx, at: c, pressed: pressed) }
        return ctx.makeImage()
    }

    /// 普通箭头指针（自己画的多边形）。
    static func drawCursor(_ ctx: CGContext, at c: CGPoint, pressed: Bool) {
        let k: CGFloat = pressed ? 0.88 : 1
        let pts: [CGPoint] = [(0, 0), (0, 17), (4.2, 13.2), (7.2, 20), (9.8, 18.9), (6.9, 12.3), (12.4, 12.3)]
            .map { CGPoint(x: c.x + $0.0 * k, y: c.y + $0.1 * k) }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3, color: CGColor(gray: 0, alpha: 0.45))
        ctx.addLines(between: pts)
        ctx.closePath()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(1.4)
        ctx.setLineJoin(.round)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }

    static func write(_ img: CGImage, to path: String, jpeg: Bool) {
        let rep = NSBitmapImageRep(cgImage: img)
        let data = jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
                        : rep.representation(using: .png, properties: [:])
        try? data?.write(to: URL(fileURLWithPath: path))
    }
}
