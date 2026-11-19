import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 设计令牌：见 ../DESIGN.md 第 1 节。所有颜色都同时给出浅色/深色值。

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}

extension Color {
    /// 浅色 / 深色动态色（随系统外观自动切换）
    init(light: UInt32, dark: UInt32) { self.init(nsColor: .dynamic(light, dark)) }
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

/// 「宣纸与墨」：暖色宣纸底、墨色文字、靛青强调、朱砂示警。不用纯白，不用纯黑。
enum Theme {
    static let bg = Color(light: 0xF4F1EA, dark: 0x1A1917)
    static let sidebar = Color(light: 0xEDE9E0, dark: 0x151412)
    static let surface = Color(light: 0xFBF9F5, dark: 0x22201E)
    static let surface2 = Color(light: 0xF0ECE4, dark: 0x2B2926)
    static let border = Color(light: 0xE1DBD0, dark: 0x35322E)
    static let text = Color(light: 0x2B2924, dark: 0xEBE6DC)
    static let text2 = Color(light: 0x6A655C, dark: 0xABA497)
    static let text3 = Color(light: 0x9D978C, dark: 0x77716A)
    static let accent = Color(light: 0x4A63B5, dark: 0x8EA2EC)
    static let accentSoft = Color(nsColor: NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0x8EA2EC, alpha: 0.16) : NSColor(hex: 0x4A63B5, alpha: 0.11)
    })
    static let hover = Color(nsColor: NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0xEBE6DC, alpha: 0.05) : NSColor(hex: 0x2B2924, alpha: 0.045)
    })
    static let success = Color(light: 0x3E8E63, dark: 0x5DB585)
    static let warning = Color(hex: 0xDB7B2E)
    static let danger = Color(hex: 0xD44C3D)
    static let star = Color(hex: 0xD9A23A)
    static let nsBg = NSColor.dynamic(0xF4F1EA, 0x1A1917)

    // 字号
    static let fTitle: CGFloat = 20
    static let fRowTitle: CGFloat = 13.5
    static let fBody: CGFloat = 13.5
    static let fMeta: CGFloat = 12
    static let fBadge: CGFloat = 11
}

// MARK: 优先级

struct PriorityStyle {
    let level: Int
    let name: String
    let hex: UInt32
    let symbol: String

    var color: Color { Color(nsColor: NSColor(hex: hex)) }
    var nsColor: NSColor { NSColor(hex: hex) }
    /// P4/P5：列表左侧色条
    var hasBar: Bool { level >= 4 }
    /// P2/P3：小圆点
    var hasDot: Bool { level == 2 || level == 3 }
    /// P0/P1：整行弱化
    var muted: Bool { level <= 1 }

    static func of(_ p: Int) -> PriorityStyle {
        switch p {
        case 5...: return PriorityStyle(level: 5, name: "紧急", hex: 0xD44C3D, symbol: "exclamationmark.octagon.fill")
        case 4: return PriorityStyle(level: 4, name: "重要", hex: 0xDB7B2E, symbol: "bell.badge.fill")
        case 3: return PriorityStyle(level: 3, name: "普通", hex: 0x3F7FD0, symbol: "bell.fill")
        case 2: return PriorityStyle(level: 2, name: "低", hex: 0x958F84, symbol: "circle")
        case 1: return PriorityStyle(level: 1, name: "日志", hex: 0xB4AEA3, symbol: "text.alignleft")
        default: return PriorityStyle(level: 0, name: "调试", hex: 0xC8C2B6, symbol: "ladybug")
        }
    }
}

struct PriorityBadge: View {
    let priority: Int
    var showName = true

    var body: some View {
        let s = PriorityStyle.of(priority)
        Text(showName ? "P\(s.level) \(s.name)" : "P\(s.level)")
            .font(.system(size: Theme.fBadge, weight: .semibold))
            .foregroundStyle(s.level == 5 ? Color.white : s.color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(s.level == 5 ? s.color : s.color.opacity(0.14)))
    }
}

struct PriorityDot: View {
    let priority: Int
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(PriorityStyle.of(priority).color).frame(width: size, height: size)
    }
}

// MARK: 文件类型

enum FileKind: String, CaseIterable {
    case image, pdf, word, excel, ppt, archive, text, other

    static func of(name: String, mime: String) -> FileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        let m = mime.lowercased()
        if m.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg"].contains(ext) { return .image }
        if m == "application/pdf" || ext == "pdf" { return .pdf }
        if ["doc", "docx", "rtf", "pages"].contains(ext) || m.contains("wordprocessing") || m == "application/msword" { return .word }
        if ["xls", "xlsx", "csv", "numbers", "tsv"].contains(ext) || m.contains("spreadsheet") || m == "text/csv" { return .excel }
        if ["ppt", "pptx", "key"].contains(ext) || m.contains("presentation") { return .ppt }
        if ["zip", "tar", "gz", "tgz", "7z", "rar", "xz", "bz2", "zst"].contains(ext) || m.contains("zip") || m.contains("compressed") { return .archive }
        if m.hasPrefix("text/") || ["log", "txt", "json", "py", "md", "yaml", "yml", "toml", "sh", "go", "swift", "js", "ts", "c", "cpp", "h", "ipynb"].contains(ext) || m == "application/json" { return .text }
        return .other
    }

    var label: String {
        switch self {
        case .image: return "图片"
        case .pdf: return "PDF"
        case .word: return "Word"
        case .excel: return "表格"
        case .ppt: return "演示文稿"
        case .archive: return "压缩包"
        case .text: return "文本"
        case .other: return "文件"
        }
    }

    var color: Color {
        switch self {
        case .image: return Color(hex: 0x8758BF)
        case .pdf: return Color(hex: 0xD44C3D)
        case .word: return Color(hex: 0x3E6BC4)
        case .excel: return Color(hex: 0x3E8E63)
        case .ppt: return Color(hex: 0xDB7B2E)
        case .archive, .other: return Color(hex: 0x958F84)
        case .text: return Theme.text2
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .word: return "doc.text"
        case .excel: return "tablecells"
        case .ppt: return "rectangle.on.rectangle"
        case .archive: return "archivebox"
        case .text: return "doc.plaintext"
        case .other: return "doc"
        }
    }
}

// MARK: 时间

enum TimeFmt {
    private static func fmt(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "zh_CN")
        d.dateFormat = f
        return d
    }
    private static let hm = fmt("HH:mm")
    private static let md = fmt("MM-dd")
    private static let ymd = fmt("yyyy-MM-dd")
    private static let full = fmt("yyyy-MM-dd HH:mm:ss")
    private static let mdhm = fmt("MM-dd HH:mm")

    /// 列表用相对时间：刚刚 / 5 分钟前 / 14:32 / 昨天 / 11-15 / 2025-11-15
    static func relative(_ d: Date, now: Date = Date()) -> String {
        let dt = now.timeIntervalSince(d)
        if dt < 60 { return "刚刚" }
        if dt < 3600 { return "\(Int(dt / 60)) 分钟前" }
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return hm.string(from: d) }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "昨天" }
        if cal.component(.year, from: d) == cal.component(.year, from: now) { return md.string(from: d) }
        return ymd.string(from: d)
    }

    static func full(_ d: Date) -> String { full.string(from: d) }

    /// 线程时间线：当天只显示时分，否则显示月日时分
    static func compact(_ d: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(d, inSameDayAs: now) ? hm.string(from: d) : mdhm.string(from: d)
    }
}

// MARK: 小组件

struct TopicChip: View {
    let topic: String

    var body: some View {
        HStack(spacing: 2) {
            Text("#").foregroundStyle(Theme.text3)
            Text(topic).foregroundStyle(Theme.text2)
        }
        .font(.system(size: Theme.fBadge, weight: .medium))
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface2))
    }
}

/// 连接状态颜色
extension ConnState {
    var color: Color {
        switch self {
        case .connected: return Theme.success
        case .connecting, .reconnecting: return Theme.warning
        case .unpaired, .unauthorized: return Theme.danger
        }
    }

    var shortLabel: String {
        switch self {
        case .unpaired: return "未配对"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .reconnecting: return "重连中"
        case .unauthorized: return "需重新配对"
        }
    }
}

struct StatusDot: View {
    let state: ConnState
    var body: some View {
        Circle().fill(state.color).frame(width: 7, height: 7)
            .overlay(Circle().stroke(state.color.opacity(0.25), lineWidth: 3))
    }
}

/// 卡片：暖白底 + 柔和暖色阴影（深色模式不用阴影，改用细边框）
struct CardStyle: ViewModifier {
    @Environment(\.colorScheme) var scheme
    var radius: CGFloat = 10
    var lifted = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(Theme.surface))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .stroke(scheme == .dark ? Theme.border : Theme.border.opacity(lifted ? 0.9 : 0.55), lineWidth: 1))
            .shadow(color: scheme == .dark ? .clear : Color(red: 60 / 255, green: 48 / 255, blue: 30 / 255).opacity(0.06), radius: 1, y: 1)
            .shadow(color: scheme == .dark ? .clear : Color(red: 60 / 255, green: 48 / 255, blue: 30 / 255).opacity(lifted ? 0.10 : 0.05), radius: lifted ? 10 : 8, y: lifted ? 6 : 4)
    }
}

extension View {
    func card(radius: CGFloat = 10, lifted: Bool = false) -> some View { modifier(CardStyle(radius: radius, lifted: lifted)) }
}

/// 可悬停高亮的行背景
struct HoverHighlight: ViewModifier {
    @State private var hover = false
    var radius: CGFloat = 6
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(hover ? Theme.hover : .clear))
            .onHover { hover = $0 }
    }
}

extension View {
    func hoverHighlight(radius: CGFloat = 6) -> some View { modifier(HoverHighlight(radius: radius)) }
}
