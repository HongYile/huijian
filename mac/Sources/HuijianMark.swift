import CoreGraphics

/// 回笺标志：靛青箭头飞入信封（主：推送送达）+ 细虚线回程（辅：可以回复）+ 三道朱砂提醒线。
/// 与 design/icon/make.py 是同一图形，坐标同为 1024×1024、y 向下。Mac 与 iPhone 各放一份同样的文件。
enum HuijianMark {
    struct Palette {
        var bg, env, line, flap, arrow, spark, dash: CGColor
    }

    static let light = Palette(bg: rgb(0xF4F1EA), env: rgb(0x4A63B5), line: rgb(0x2B2924), flap: rgb(0xF4F1EA),
                               arrow: rgb(0x4A63B5), spark: rgb(0xD44C3D), dash: rgb(0x2B2924))
    static let dark = Palette(bg: rgb(0x1A1917), env: rgb(0x5B74C9), line: rgb(0xEBE6DC), flap: rgb(0x1A1917),
                              arrow: rgb(0x8EA2EC), spark: rgb(0xE06A5A), dash: rgb(0xABA497))

    static func rgb(_ h: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
    }

    /// 在 rect 内绘制（ctx 必须是 y 向下的坐标系，例如 SwiftUI Canvas、flipped 的 NSImage）。
    /// - background: 是否铺满底色（圆角由调用方裁切）
    /// - simple: 小尺寸简化版，去掉回程虚线、主体放大
    /// - mono: 单色剪影（菜单栏模板图标等），此时忽略 palette 与 background
    static func draw(in ctx: CGContext, rect: CGRect, palette p: Palette = light, background: Bool = true,
                     simple: Bool = false, mono: CGColor? = nil) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if background, mono == nil {
            ctx.setFillColor(p.bg)
            ctx.fill(rect)
        }
        let k = rect.width / 1024
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: k, y: k)
        let s: CGFloat = simple ? 1.12 : 1
        ctx.translateBy(x: 512, y: 512)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -534, y: simple ? -470 : -507)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        if !simple {
            let c = mono ?? p.dash
            ctx.setStrokeColor(c)
            ctx.setFillColor(c)
            ctx.saveGState()
            ctx.setLineWidth(13)
            ctx.setLineDash(phase: 0, lengths: [28, 26])
            ctx.addPath(dashArc)
            ctx.strokePath()
            ctx.restoreGState()
            ctx.setLineWidth(8)
            ctx.addPath(dashHead)
            ctx.drawPath(using: .fillStroke)
        }

        if let mono {
            // 信封实心，封口线和箭头头部周围挖空
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setFillColor(mono)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 463, y: 391, width: 446, height: 330), cornerWidth: 58, cornerHeight: 58, transform: nil))
            ctx.fillPath()
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(30)
            ctx.addPath(flap)
            ctx.strokePath()
            ctx.setLineWidth(40)
            ctx.addPath(head)
            ctx.drawPath(using: .fillStroke)
            ctx.endTransparencyLayer()
            ctx.setFillColor(mono)
            ctx.addPath(shaft)
            ctx.addPath(head)
            ctx.fillPath()
        } else {
            ctx.addPath(CGPath(roundedRect: CGRect(x: 476, y: 404, width: 420, height: 304), cornerWidth: 46, cornerHeight: 46, transform: nil))
            ctx.setFillColor(p.env)
            ctx.setStrokeColor(p.line)
            ctx.setLineWidth(26)
            ctx.drawPath(using: .fillStroke)
            ctx.setStrokeColor(p.flap)
            ctx.setLineWidth(30)
            ctx.addPath(flap)
            ctx.strokePath()
            ctx.setFillColor(p.arrow)
            ctx.addPath(shaft)
            ctx.fillPath()
            // 箭头头部先描一圈底色，和信封边框分开
            ctx.setStrokeColor(p.bg)
            ctx.setLineWidth(14)
            ctx.addPath(head)
            ctx.strokePath()
            ctx.addPath(head)
            ctx.fillPath()
        }

        ctx.setStrokeColor(mono ?? p.spark)
        ctx.setLineWidth(26)
        for (a, b) in sparks {
            ctx.move(to: a)
            ctx.addLine(to: b)
        }
        ctx.strokePath()
    }

    private static let sparks: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 812, y: 352), CGPoint(x: 784, y: 306)),
        (CGPoint(x: 862, y: 334), CGPoint(x: 862, y: 272)),
        (CGPoint(x: 912, y: 352), CGPoint(x: 940, y: 306)),
    ]

    private static let flap: CGPath = {
        let p = CGMutablePath()
        p.addLines(between: [CGPoint(x: 500, y: 446), CGPoint(x: 686, y: 572), CGPoint(x: 872, y: 446)])
        return p
    }()

    private static let shaft: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 118, y: 566))
        p.addCurve(to: CGPoint(x: 627.0, y: 317.2), control1: CGPoint(x: 130, y: 330), control2: CGPoint(x: 500.5, y: 125.1))
        p.addLine(to: CGPoint(x: 578.6, y: 349.1))
        p.addCurve(to: CGPoint(x: 118, y: 566), control1: CGPoint(x: 474.1, y: 190.5), control2: CGPoint(x: 190, y: 360))
        p.closeSubpath()
        return p
    }()

    private static let head = triangle(CGPoint(x: 660, y: 420), CGPoint(x: 557.7, y: 362.9), CGPoint(x: 647.9, y: 303.4))
    private static let dashHead = triangle(CGPoint(x: 180, y: 698), CGPoint(x: 231.4, y: 712.2), CGPoint(x: 192.7, y: 749.8))

    private static let dashArc: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 560, y: 742))
        p.addCurve(to: CGPoint(x: 206, y: 724), control1: CGPoint(x: 450, y: 830), control2: CGPoint(x: 290, y: 810))
        return p
    }()

    private static func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: [a, b, c])
        p.closeSubpath()
        return p
    }
}
