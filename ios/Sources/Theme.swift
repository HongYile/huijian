import SwiftUI
import UIKit

// 配色和 Mac 客户端一致（mac/Sources/Theme.swift）：暖色宣纸底、墨色文字、靛青强调、朱砂示警。
// 控件本身用系统标准样式，iOS 26 以上自动获得新材质，这里只定颜色。

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    /// 浅色 / 深色动态色（随系统外观自动切换）
    init(light: UInt32, dark: UInt32, alpha: CGFloat = 1) {
        self.init(uiColor: UIColor { t in
            t.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: alpha) : UIColor(hex: light, alpha: alpha)
        })
    }
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

enum Theme {
    static let bg = Color(light: 0xF4F1EA, dark: 0x1A1917)
    static let surface = Color(light: 0xFBF9F5, dark: 0x24221F)
    static let surface2 = Color(light: 0xEEEAE2, dark: 0x2E2C28)
    static let border = Color(light: 0xE1DBD0, dark: 0x3A3732)
    static let text = Color(light: 0x2B2924, dark: 0xEBE6DC)
    static let text2 = Color(light: 0x6A655C, dark: 0xABA497)
    static let text3 = Color(light: 0x9D978C, dark: 0x7F7970)
    static let accent = Color(light: 0x4A63B5, dark: 0x8EA2EC)
    static let accentSoft = Color(light: 0x4A63B5, dark: 0x8EA2EC, alpha: 0.13)
    static let success = Color(light: 0x3E8E63, dark: 0x5DB585)
    static let warning = Color(hex: 0xDB7B2E)
    static let danger = Color(hex: 0xD44C3D)
}

// MARK: 优先级

struct PriorityStyle {
    let level: Int
    let name: String
    let hex: UInt32

    var color: Color { Color(hex: hex) }

    static func of(_ p: Int) -> PriorityStyle {
        switch p {
        case 5...: return PriorityStyle(level: 5, name: "紧急", hex: 0xD44C3D)
        case 4: return PriorityStyle(level: 4, name: "重要", hex: 0xDB7B2E)
        case 3: return PriorityStyle(level: 3, name: "普通", hex: 0x3F7FD0)
        case 2: return PriorityStyle(level: 2, name: "低", hex: 0x958F84)
        case 1: return PriorityStyle(level: 1, name: "日志", hex: 0xB4AEA3)
        default: return PriorityStyle(level: 0, name: "调试", hex: 0xC8C2B6)
        }
    }
}

struct PriorityBadge: View {
    let priority: Int
    var showName = true

    var body: some View {
        let s = PriorityStyle.of(priority)
        Text(showName ? "P\(s.level) \(s.name)" : "P\(s.level)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(s.level == 5 ? Color.white : s.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(s.level == 5 ? s.color : s.color.opacity(0.14)))
    }
}

/// 小标签（线程名、静默等）
struct Tag: View {
    let text: String
    var color: Color = Theme.text2

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
    }
}

// MARK: 时间

enum TimeText {
    private static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let mdhm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"; return f }()
    private static let full: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()

    /// 列表用的相对时间：刚刚 / N 分钟前 / 今天 HH:mm / 昨天 HH:mm / M月d日 HH:mm
    static func relative(_ t: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(t)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        let cal = Calendar.current
        if cal.isDateInToday(t) { return hm.string(from: t) }
        if cal.isDateInYesterday(t) { return "昨天 " + hm.string(from: t) }
        return mdhm.string(from: t)
    }

    static func full(_ t: Date) -> String { full.string(from: t) }

    static func ago(_ t: Date?, now: Date = Date()) -> String {
        guard let t else { return "还没有" }
        let s = Int(now.timeIntervalSince(t))
        if s < 5 { return "刚刚" }
        if s < 60 { return "\(s) 秒前" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        if s < 86400 { return "\(s / 3600) 小时前" }
        return full.string(from: t)
    }
}

/// 附件图标（SF Symbols）
func fileSymbol(_ a: Attachment) -> String {
    let ext = (a.name as NSString).pathExtension.lowercased()
    if a.isImage { return "photo" }
    if ext == "pdf" || a.mime == "application/pdf" { return "doc.richtext" }
    if ["doc", "docx", "rtf", "pages"].contains(ext) { return "doc.text" }
    if ["xls", "xlsx", "csv", "numbers"].contains(ext) { return "tablecells" }
    if ["ppt", "pptx", "key"].contains(ext) { return "rectangle.on.rectangle" }
    if ["zip", "gz", "tgz", "7z", "rar", "tar", "xz"].contains(ext) { return "doc.zipper" }
    if ["log", "txt", "md", "json", "yaml", "yml"].contains(ext) || a.mime.hasPrefix("text/") { return "doc.plaintext" }
    return "doc"
}
