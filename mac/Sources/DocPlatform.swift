import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// DocView.swift 的 Mac 部分：字号、附件图片、附件卡片、剪贴板。iPhone 版在 ios/Sources/DocPlatform.swift，
// 两边的类型名和接口保持一致（MDStyle / MDAttachmentImage / MDFileCard / MDPasteboard）。

enum MDStyle {
    static let body: Font = .system(size: Theme.fBody)
    static let small: Font = .system(size: 12)
    static let lineSpacing: CGFloat = 3
    static let blockSpacing: CGFloat = 10
    static let tightSpacing: CGFloat = 4
    static let code: Font = .system(size: 12, design: .monospaced)
    static let codeLabel: Font = .system(size: 11, weight: .medium)
    static let footnoteRef: Font = .system(size: 9.5, weight: .semibold)
    static let footnoteRaise: CGFloat = 5
    static let digitWidth: CGFloat = 8.5
    static let bulletWidth: CGFloat = 12
    static let tableCellMaxWidth: CGFloat = 320
    static let imageMaxHeight: CGFloat = 460
    static let cardMaxWidth: CGFloat = 460
    static let showScrollIndicators = true
    /// Mac 没有长按链接预览，链接用原地址（右键「拷贝链接」拿到真实地址）
    static let wrapWebLinks = false

    static func heading(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 18, weight: .bold)
        case 2: return .system(size: 16, weight: .semibold)
        case 3: return .system(size: 14.5, weight: .semibold)
        case 4: return .system(size: 13.5, weight: .semibold)
        default: return .system(size: 12.5, weight: .semibold)
        }
    }
}

enum MDPlatformImage {
    /// 外部图片的数据 → (SwiftUI Image, 文件扩展名)。用 ImageIO 按需缩小解码（最长边 maxPixel，按 2 倍屏换算成点），解不开时 nil
    static func make(_ data: Data, maxPixel: Int) -> (image: Image, width: CGFloat, ext: String)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let ext = CGImageSourceGetType(src).flatMap { UTType($0 as String)?.preferredFilenameExtension } ?? "img"
        let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        return (Image(nsImage: img), img.size.width, ext)
    }
}

enum MDPasteboard {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// 正文里的附件图片：走附件区同一套下载 / 缓存（AttachmentCache），20 MB 以内打开就自动下载，点图片用 QuickLook 预览
struct MDAttachmentImage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.mdActions) private var actions
    let att: Attachment
    let alt: String
    @State private var image: NSImage?
    @State private var hover = false

    static let autoBytes: Int64 = 20 << 20

    var body: some View {
        let local = model.localFiles[att.id]
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: max(image.size.width, 60), maxHeight: MDStyle.imageMaxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(hover ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: hover ? 1 : 0.5))
                    .contentShape(Rectangle())
                    .onHover { hover = $0 }
                    .onTapGesture { actions.openAttachment(att) }
                    .help("点击预览原图 \(att.name)")
                    .contextMenu {
                        Button("QuickLook 预览") { actions.openAttachment(att) }
                        if let local {
                            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([local]) }
                            Button("用默认应用打开") { NSWorkspace.shared.open(local) }
                        }
                    }
            } else {
                placeholder
                    .onTapGesture { if model.progress[att.id] == nil { Task { await model.download(att) } } }
            }
            if !alt.isEmpty {
                Text(alt).font(MDStyle.small).foregroundStyle(Theme.text3)
            }
        }
        .task(id: att.id) {
            if model.localFiles[att.id] == nil, model.progress[att.id] == nil, att.size <= Self.autoBytes {
                await model.download(att)
            }
        }
        .task(id: local) {
            guard let local else { image = nil; return }
            image = await Task.detached(priority: .userInitiated) { Self.load(local) }.value
        }
    }

    private var placeholder: some View {
        let p = model.progress[att.id]
        let err = model.downloadErrors[att.id]
        return VStack(spacing: 8) {
            if let p {
                ProgressRing(progress: p).frame(width: 30, height: 30)
                Text("正在下载 \(att.name)…").font(MDStyle.small).foregroundStyle(Theme.text3)
            } else if let err {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 18)).foregroundStyle(Theme.danger)
                Text("下载失败，点击重试：\(err)").font(MDStyle.small).foregroundStyle(Theme.danger).multilineTextAlignment(.center)
            } else {
                Image(systemName: "photo").font(.system(size: 18)).foregroundStyle(Theme.accent)
                Text("\(att.name) · \(humanSize(att.size)) · 点击下载").font(MDStyle.small).foregroundStyle(Theme.text2)
            }
        }
        .padding(16)
        .frame(maxWidth: MDStyle.cardMaxWidth, minHeight: 140)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface2))
        .contentShape(Rectangle())
    }

    /// ImageIO 按需缩小解码（大图不整张解进内存）。尺寸按 2 倍屏换算成点
    nonisolated static func load(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }
}

/// 正文里的附件卡片：和下方附件区同一个卡片（点击下载 / 预览，右键更多操作）
struct MDFileCard: View {
    let att: Attachment
    let alt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AttachmentCard(att: att)
            if !alt.isEmpty && alt != att.name {
                Text(alt).font(MDStyle.small).foregroundStyle(Theme.text3)
            }
        }
    }
}
