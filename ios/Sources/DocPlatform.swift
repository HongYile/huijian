import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// DocView.swift 的 iPhone 部分：字号、附件图片、附件卡片、剪贴板。Mac 版在 mac/Sources/DocPlatform.swift，
// 两边的类型名和接口保持一致（MDStyle / MDAttachmentImage / MDFileCard / MDPasteboard）。

enum MDStyle {
    static let body: Font = .body
    static let small: Font = .footnote
    static let lineSpacing: CGFloat = 3
    static let blockSpacing: CGFloat = 12
    static let tightSpacing: CGFloat = 5
    static let code: Font = .system(.footnote, design: .monospaced)
    static let codeLabel: Font = .caption.weight(.medium)
    static let footnoteRef: Font = .caption2.weight(.semibold)
    static let footnoteRaise: CGFloat = 6
    static let digitWidth: CGFloat = 10
    static let bulletWidth: CGFloat = 14
    static let tableCellMaxWidth: CGFloat = 240
    static let imageMaxHeight: CGFloat = 420
    static let cardMaxWidth: CGFloat = .infinity
    static let showScrollIndicators = false
    /// http(s) 链接包成内部链接 x-huijian-web：长按时系统的链接预览不认识，不会提前请求网页（短按照常打开）
    static let wrapWebLinks = true

    static func heading(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.bold)
        case 2: return .title3.weight(.semibold)
        case 3: return .headline
        case 4: return .subheadline.weight(.semibold)
        default: return .footnote.weight(.semibold)
        }
    }
}

enum MDPasteboard {
    static func copy(_ s: String) { UIPasteboard.general.string = s }
}

enum MDPlatformImage {
    /// 外部图片的数据 → (SwiftUI Image, 文件扩展名)。用 ImageIO 按需缩小解码（最长边 maxPixel），解不开时 nil
    static func make(_ data: Data, maxPixel: Int) -> (image: Image, width: CGFloat, ext: String)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let ext = CGImageSourceGetType(src).flatMap { UTType($0 as String)?.preferredFilenameExtension } ?? "img"
        // 宽度和附件图片一致：iPhone 按像素数当点数（最多撑满屏宽）
        return (Image(uiImage: UIImage(cgImage: cg)), CGFloat(cg.width), ext)
    }
}

/// 详情页的 QuickLook 预览（附件卡片要用）
private struct MDPreviewKey: EnvironmentKey { static let defaultValue: Binding<URL?> = .constant(nil) }

extension EnvironmentValues {
    var mdPreview: Binding<URL?> {
        get { self[MDPreviewKey.self] }
        set { self[MDPreviewKey.self] = newValue }
    }
}

/// 正文里的附件图片：走附件区同一套下载 / 缓存（校验 sha256），小图打开就自动下载，点图片全屏预览
struct MDAttachmentImage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.mdActions) private var actions
    let att: Attachment
    let alt: String
    @State private var image: UIImage?

    var body: some View {
        let state = model.attState(att)
        let file = AppPaths.attachmentFile(att)
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                Button { actions.openAttachment(att) } label: {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: max(image.size.width, 60), maxHeight: MDStyle.imageMaxHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("图片 \(alt.isEmpty ? att.name : alt)，点按查看大图")
            } else {
                Button {
                    if case .downloading = state { return }
                    Task { await model.download(att) }
                } label: {
                    placeholder(state)
                }
                .buttonStyle(.plain)
            }
            if !alt.isEmpty {
                Text(alt).font(MDStyle.small).foregroundStyle(Theme.text3)
            }
        }
        .task(id: att.id) {
            if att.size <= AttachmentCard.autoImageBytes, model.attState(att) == .idle { await model.download(att) }
        }
        .task(id: state == .done) {
            guard state == .done, image == nil else { return }
            let px = Thumbnail.screenPixels
            image = await Task.detached(priority: .userInitiated) {
                AttCache.touch(file)
                return Thumbnail.load(file, maxPixel: px)
            }.value
        }
    }

    private func placeholder(_ s: AttState) -> some View {
        VStack(spacing: 8) {
            switch s {
            case .downloading:
                ProgressView()
                Text("正在下载 \(att.name)…").font(MDStyle.small).foregroundStyle(Theme.text3)
            case .failed(let e):
                Image(systemName: "exclamationmark.triangle").font(.title3).foregroundStyle(Theme.danger)
                Text("下载失败，点按重试：\(e)").font(MDStyle.small).foregroundStyle(Theme.danger).multilineTextAlignment(.center)
            default:
                Image(systemName: "photo").font(.title3).foregroundStyle(Theme.accent)
                Text("\(att.name) · \(humanSize(att.size)) · 点按下载").font(MDStyle.small).foregroundStyle(Theme.text2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface2))
        .contentShape(Rectangle())
    }
}

/// 正文里的附件卡片：和下方附件区同一个卡片（下载、打开、分享）
struct MDFileCard: View {
    @Environment(\.mdPreview) private var preview
    let att: Attachment
    let alt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AttachmentCard(a: att, preview: preview)
            if !alt.isEmpty && alt != att.name {
                Text(alt).font(MDStyle.small).foregroundStyle(Theme.text3)
            }
        }
    }
}
