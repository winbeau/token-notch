// 画应用图标：深色圆角方块上的五根柱子（五个 agent 的颜色，最高的一根是强调色）。
// 用法：swift scripts/make-logo.swift
// 产出 docs/images/logo-1024.png、docs/images/logo.png、site/assets/logo.png、assets/AppIcon.icns。
import AppKit

let size: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, alpha])!
}

func draw() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // 左上角原点
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    func fill(_ path: CGPath, top: UInt32, bottom: UInt32, in rect: CGRect) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let g = CGGradient(colorsSpace: space, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        ctx.restoreGState()
    }

    // 底板
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    fill(tilePath, top: 0x1F1F24, bottom: 0x0B0B0D, in: tile)
    // 顶部一道很淡的高光
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184.5, cornerHeight: 184.5, transform: nil))
    ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let hl = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.minY + 300), options: [])
    ctx.restoreGState()

    // 五根柱子：(高度, 上端颜色, 下端颜色)
    let bars: [(CGFloat, UInt32, UInt32)] = [
        (132, 0xF28B68, 0xD9694A),   // Claude 珊瑚橙
        (196, 0x6590FF, 0x4662EA),   // DeepSeek 蓝
        (264, 0xB9A0FF, 0x9A7BF5),   // Gemini 紫
        (338, 0xF4F4F7, 0xD2D2DA),   // Codex 近白
        (424, 0xFFC61A, 0xFF8A00),   // 强调色
    ]
    let w: CGFloat = 94, gap: CGFloat = 16, baseline: CGFloat = 728
    let left = (size - (w * 5 + gap * 4)) / 2
    let rects = bars.enumerated().map { i, bar in
        CGRect(x: left + CGFloat(i) * (w + gap), y: baseline - bar.0, width: w, height: bar.0)
    }
    func barPath(_ r: CGRect) -> CGPath { CGPath(roundedRect: r, cornerWidth: 22, cornerHeight: 22, transform: nil) }
    // 最高的一根带一圈光晕；先画光晕，免得盖到旁边的柱子上
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 70, color: color(0xFF9F0A, 0.75))
    ctx.addPath(barPath(rects[4]))
    ctx.setFillColor(color(0xFF9F0A))
    ctx.fillPath()
    ctx.restoreGState()
    for (rect, bar) in zip(rects, bars) {
        fill(barPath(rect), top: bar.1, bottom: bar.2, in: rect)
    }
    return ctx.makeImage()!
}

func png(_ image: CGImage, side: Int) -> Data {
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let image = draw()
let fm = FileManager.default
func write(_ side: Int, _ path: String) throws {
    try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try png(image, side: side).write(to: URL(fileURLWithPath: path))
}
try write(1024, "docs/images/logo-1024.png")
try write(256, "docs/images/logo.png")
try write(256, "site/assets/logo.png")

let iconset = NSTemporaryDirectory() + "TokenNotch-\(ProcessInfo.processInfo.processIdentifier).iconset"
for side in [16, 32, 128, 256, 512] {
    try write(side, "\(iconset)/icon_\(side)x\(side).png")
    try write(side * 2, "\(iconset)/icon_\(side)x\(side)@2x.png")
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", "assets/AppIcon.icns"]
try task.run()
task.waitUntilExit()
try? fm.removeItem(atPath: iconset)
print("logo 已更新")
