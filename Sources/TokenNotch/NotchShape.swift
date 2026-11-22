import SwiftUI

/// 刘海形状：顶边贴屏幕，两侧上角是向外张开的平滑外圆角（和屏幕边缘相接），底部两角圆角。
///
/// 形状的外框宽 = 主体宽 + 2 × flare.width。外圆角曲线与设计稿一致：
/// 从顶边 (0,0) 出发，控制点 (⅔·fw, 0) 和 (fw, 0.47·fh)，落到主体侧边 (fw, fh)。
struct NotchShape: Shape {
    var flare: CGSize
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(flare.width, flare.height), bottomRadius) }
        set {
            flare = CGSize(width: newValue.first.first, height: newValue.first.second)
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let fw = min(flare.width, w / 4), fh = min(flare.height, h / 2)
        let r = max(0, min(bottomRadius, h - fh, (w - 2 * fw) / 2))
        let k: CGFloat = 0.55   // 底角三次曲线的手柄比例，接近连续曲率

        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w, y: 0))
        // 右上外圆角
        p.addCurve(to: CGPoint(x: w - fw, y: fh),
                   control1: CGPoint(x: w - fw * 2 / 3, y: 0),
                   control2: CGPoint(x: w - fw, y: fh * 0.47))
        p.addLine(to: CGPoint(x: w - fw, y: h - r))
        // 右下角
        p.addCurve(to: CGPoint(x: w - fw - r, y: h),
                   control1: CGPoint(x: w - fw, y: h - r * (1 - k)),
                   control2: CGPoint(x: w - fw - r * (1 - k), y: h))
        p.addLine(to: CGPoint(x: fw + r, y: h))
        // 左下角
        p.addCurve(to: CGPoint(x: fw, y: h - r),
                   control1: CGPoint(x: fw + r * (1 - k), y: h),
                   control2: CGPoint(x: fw, y: h - r * (1 - k)))
        p.addLine(to: CGPoint(x: fw, y: fh))
        // 左上外圆角
        p.addCurve(to: CGPoint(x: 0, y: 0),
                   control1: CGPoint(x: fw, y: fh * 0.47),
                   control2: CGPoint(x: fw * 2 / 3, y: 0))
        p.closeSubpath()
        return p
    }
}

extension NotchState {
    var flare: CGSize {
        switch self {
        case .idle, .active: return CGSize(width: 12, height: 10)
        case .expanded: return CGSize(width: 36, height: 30)
        }
    }

    var bottomRadius: CGFloat {
        switch self {
        case .idle: return 10
        case .active: return 14
        case .expanded: return 32
        }
    }
}
