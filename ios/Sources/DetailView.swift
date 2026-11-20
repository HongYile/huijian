import ImageIO
import QuickLook
import SwiftUI
import UIKit

struct DetailView: View {
    @EnvironmentObject private var model: AppModel
    let id: Int64
    @State private var preview: URL?
    /// 等了 10 秒还没同步到：不再转圈
    @State private var gaveUp = false
    /// 正文里 huijian://message/<id> 指向本机没有的消息
    @State private var missingLink = false
    /// 正文动作（MDActions）只在换了消息时重建：每次刷新都新建闭包，环境值就变了，整篇正文跟着重绘
    @State private var actionsBox = DetailActionsBox()

    /// 这条消息还可能在路上：id 比已同步的位置新，且连接正常。更旧的（早于首次同步、超出本机保存条数、已被删除）不会再来
    private var mayArrive: Bool {
        // 冷启动点通知时消息还在后台读取：读完之前也按「还会出现」处理，不先闪一下「找不到这条消息」
        !model.loaded || (!gaveUp && id > model.settings.cursor && [.connecting, .connected, .paused].contains(model.conn))
    }

    var body: some View {
        Group {
            if let m = model.message(id) {
                content(m)
            } else if mayArrive {
                ProgressView("正在同步这条消息…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("找不到这条消息", systemImage: "questionmark.folder",
                                       description: Text("可能已被删除，或者还没同步到这台手机（本机只保存最近 \(Persistence.maxKeep) 条）。"))
            }
        }
        .background(Theme.bg)
        .navigationTitle(model.message(id).map { "# " + model.channelName($0.topic) } ?? "消息")
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($preview)
        .onChange(of: preview) { _, f in
            // 打开过的附件算「最近使用」，切后台清理缓存时最后才删
            if let f { Task.detached(priority: .utility) { AttCache.touch(f) } }
        }
        .onAppear { model.opened(id) }
        .task(id: id) {
            gaveUp = false
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            gaveUp = true
        }
        .onChange(of: model.message(id) != nil) { _, have in if have { model.opened(id) } }
    }

    private func content(_ m: Message) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    PriorityBadge(priority: m.priority)
                    if !m.thread.isEmpty { Tag(text: m.thread) }
                    if m.silent { Tag(text: "静默") }
                }
                Text(m.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(m.priority >= 5 ? Theme.danger : Theme.text)
                    .textSelection(.enabled)
                // 端到端加密标记（docs/e2ee-client.md §6.3、§11.5）：普通 pushkey 发来的（服务器代加密）写「明文发送」，下面单独一行完整的 T64；
                // 发送端加密的「🔒 端到端加密」；账号开启了加密、这条却是明文（开启加密以前收到、只留在本机的旧消息）时显示 T63
                Text(([m.isAgent ? "agent · " + (m.agentName ?? "未核实") : m.source, TimeText.full(m.createdAt), "#\(m.id)"]
                      + (m.isServerSealed ? [E2E.T.plainSentTag] : m.isE2E ? ["🔒 端到端加密"] : model.e2eAccountEnabled ? [E2E.T.t63] : []))
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.text3)
                if m.isServerSealed {
                    Text(E2E.T.t64)
                        .font(.caption)
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                if m.e2eUnreadable {
                    E2ELockedBody(message: m)
                } else if let doc = m.renderDoc {
                    // 服务端 0.6.0 起：按解析好的 doc 绘制（表格、提示框、正文里的附件图片……）
                    DocView(doc: doc)
                        .environment(\.mdActions, stableActions(m, proxy: proxy))
                        .environment(\.mdPreview, $preview)
                } else if !m.desp.isEmpty {
                    MarkdownView(source: m.desp, plain: m.type == "text")
                }
                // agent 消息：回复区（快捷回复、回复框、送达状态）
                if m.isAgent { AgentReplySection(message: m) }
                // 还没解开的加密消息：附件是密文，没有钥匙，不显示也不下载
                if !m.attachments.isEmpty && !m.e2eUnreadable {
                    Text("附件 \(m.attachments.count) 个").font(.footnote.weight(.medium)).foregroundStyle(Theme.text2)
                        .padding(.top, 6)
                    // 正文里已经显示过的图片，附件区照常列出但不再显示大图
                    let inBody = m.renderDoc.map { MDLogic.imageAttachmentIDs($0.blocks) } ?? []
                    ForEach(m.attachments) { a in
                        AttachmentCard(a: a, preview: $preview, showImage: !inBody.contains(a.id))
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: m.id) {
            // 演示截图：滚到正文里的某种块（-demoScrollBlock table / image …，锚点见 DocView）
            if let t = UserDefaults.standard.string(forKey: "demoScrollBlock") {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                proxy.scrollTo("md-first-" + t, anchor: .top)
            }
        }
        }
        .alert("消息不存在或已被删除", isPresented: $missingLink) {
            Button("好", role: .cancel) {}
        } message: {
            Text("本机没有这条消息（可能已被删除，或者早于本机保存的范围）。")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { model.markUnread(m.id); model.path.removeAll() } label: { Label("标为未读", systemImage: "envelope.badge") }
                    ShareLink(item: m.title + (m.desp.isEmpty ? "" : "\n\n" + m.desp)) { Label("分享文字", systemImage: "square.and.arrow.up") }
                    Button { UIPasteboard.general.string = m.desp.isEmpty ? m.title : m.desp } label: {
                        Label("复制正文", systemImage: "doc.on.doc")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }
}

/// 详情页正文动作的缓存：同一条消息（附件没变）一直用同一份 MDActions，环境值不变，正文不跟着整页刷新重绘
final class DetailActionsBox {
    private var key: (id: Int64, attachments: [Attachment])?
    private var value = MDActions()
    /// 每次刷新更新成最新的；滚动动作执行时再取
    var proxy: ScrollViewProxy?

    func get(_ m: Message, make: () -> MDActions) -> MDActions {
        if let k = key, k.id == m.id, k.attachments == m.attachments { return value }
        key = (m.id, m.attachments)
        value = make()
        return value
    }
}

extension DetailView {
    fileprivate func stableActions(_ m: Message, proxy: ScrollViewProxy) -> MDActions {
        actionsBox.proxy = proxy
        return actionsBox.get(m) { actions(m) }
    }

    /// 正文里的链接、附件、脚注要用的动作。闭包只捕获模型、绑定和缓存盒子（不捕获视图本身），换了消息才重建
    fileprivate func actions(_ m: Message) -> MDActions {
        let model = self.model
        let preview = $preview
        let missingLink = $missingLink
        let box = actionsBox
        return MDActions(attachments: m.attachments,
                  openMessage: { id in
                      // 本机没有就提示，不单独向服务端请求（docs/markdown.md「客户端绘制要求」）
                      if model.message(id) != nil { model.openMessage(id, push: true) } else { missingLink.wrappedValue = true }
                  },
                  openAttachment: { a in
                      let file = AppPaths.attachmentFile(a)
                      if model.attState(a) == .done { preview.wrappedValue = file; return }
                      let mid = m.id
                      Task {
                          // 正在下载（自动下载或附件区点的）：等它下完；否则开始下载
                          if model.attState(a) == .downloading {
                              while model.attState(a) == .downloading { try? await Task.sleep(nanoseconds: 200_000_000) }
                          } else {
                              await model.download(a)
                          }
                          // 下完时用户已经离开这条消息（这一页不在栈顶）：不再弹预览
                          if model.attState(a) == .done, model.path.last == .message(mid) { preview.wrappedValue = file }
                      }
                  },
                  scrollTo: { [weak box] anchor in
                      guard let p = box?.proxy else { return }
                      withAnimation { p.scrollTo(anchor, anchor: .top) }
                  },
                  previewFile: { preview.wrappedValue = $0 })
    }
}

/// 附件卡片：下载到缓存并校验 sha256；图片直接预览（点开全屏），其他文件用 QuickLook 打开或分享
struct AttachmentCard: View {
    @EnvironmentObject private var model: AppModel
    let a: Attachment
    @Binding var preview: URL?
    /// false：正文里已经显示了这张图，这里只列文件（下载、打开、分享）
    var showImage = true
    @State private var image: UIImage?
    /// 图片小于这个大小时打开详情就自动下载预览
    static let autoImageBytes: Int64 = 20 << 20

    var body: some View {
        let state = model.attState(a)
        let file = AppPaths.attachmentFile(a)
        VStack(alignment: .leading, spacing: 10) {
            if showImage, a.isImage, state == .done, let img = image {
                Button { preview = file } label: {
                    Image(uiImage: img).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("预览 \(a.name)")
            }
            HStack(spacing: 12) {
                Image(systemName: fileSymbol(a)).font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    Text(status(state)).font(.caption).foregroundStyle(isFailed(state) ? Theme.danger : Theme.text3).lineLimit(2)
                }
                Spacer(minLength: 4)
                switch state {
                case .downloading:
                    ProgressView()
                case .done:
                    Button("打开") { preview = file }.buttonStyle(.bordered).controlSize(.small)
                    ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityLabel("分享")
                default:
                    Button("下载") { Task { await model.download(a) } }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
        .task(id: a.id) {
            if a.isImage, a.size <= Self.autoImageBytes, model.attState(a) == .idle { await model.download(a) }
        }
        .task(id: state == .done) {
            // 大图解码放到后台，不卡主线程
            guard showImage, a.isImage, state == .done, image == nil else { return }
            let px = Thumbnail.screenPixels
            image = await Task.detached(priority: .userInitiated) {
                AttCache.touch(file)
                return Thumbnail.load(file, maxPixel: px)
            }.value
        }
    }

    private func status(_ s: AttState) -> String {
        switch s {
        case .failed(let e): return e == "解密失败" ? e : "下载失败：\(e)"
        case .downloading: return humanSize(a.size) + " · 下载中…"
        case .done: return humanSize(a.size) + " · 已校验"
        case .idle: return humanSize(a.size)
        }
    }

    private func isFailed(_ s: AttState) -> Bool { if case .failed = s { return true }; return false }
}

/// 图片缩略图：用 ImageIO 按需缩小解码（大图不整张解进内存），结果缓存（按解码后的字节数计，最多约 64MB）
enum Thumbnail {
    private static let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.totalCostLimit = 64 << 20
        return c
    }()

    static func clear() { cache.removeAllObjects() }

    /// 缩略图最长边：屏幕宽度 × scale（iPhone 上约 1200 像素），够撑满屏宽；第一次用到时在主线程算好记住
    @MainActor static var screenPixels: Int {
        if let p = cachedScreenPixels { return p }
        guard let screen = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.screen }).first else { return 1200 }
        let p = min(max(Int(min(screen.bounds.width, screen.bounds.height) * screen.scale), 800), 1600)
        cachedScreenPixels = p
        return p
    }
    @MainActor private static var cachedScreenPixels: Int?

    static func load(_ url: URL, maxPixel: Int = 1200) -> UIImage? {
        if let c = cache.object(forKey: url as NSURL) { return c }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = UIImage(cgImage: cg)
        cache.setObject(img, forKey: url as NSURL, cost: cg.width * cg.height * 4)
        return img
    }
}
