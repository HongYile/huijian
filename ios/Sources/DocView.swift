import SwiftUI

// 回笺 Markdown 的绘制（按服务端下发的 doc 画，规范见 docs/markdown.md）。
// 这个文件在 Mac（mac/Sources/DocView.swift）和 iPhone（ios/Sources/DocView.swift）两端内容完全相同，改动时两边一起改。
// 平台相关的部分放在各自的 DocPlatform.swift：字号（MDStyle）、附件图片（MDAttachmentImage）、
// 附件卡片（MDFileCard）、剪贴板（MDPasteboard）、外部图片解码（MDPlatformImage）。颜色用两端同名的 Theme。

// MARK: 环境

/// 宿主（详情页）提供的动作：消息的附件、跳到另一条消息、打开附件、滚动到脚注。
/// openMessage：本机没有这条消息时由宿主提示「消息不存在或已被删除」，不单独向服务端请求
struct MDActions {
    var attachments: [Attachment] = []
    var openMessage: (Int64) -> Void = { _ in }
    var openAttachment: (Attachment) -> Void = { _ in }
    var scrollTo: (String) -> Void = { _ in }
    /// 在应用内全屏查看一个本地文件（外部图片加载后点开：iPhone / Mac 都用 QuickLook，不交给浏览器再请求一次）
    var previewFile: (URL) -> Void = { _ in }

    func attachment(_ id: String?) -> Attachment? {
        guard let id else { return nil }
        return attachments.first { $0.id == id }
    }
}

private struct MDActionsKey: EnvironmentKey { static let defaultValue = MDActions() }
private struct MDTextColorKey: EnvironmentKey { static let defaultValue: Color? = nil }
private struct MDSmallKey: EnvironmentKey { static let defaultValue = false }
private struct MDListDepthKey: EnvironmentKey { static let defaultValue = 0 }

extension EnvironmentValues {
    var mdActions: MDActions {
        get { self[MDActionsKey.self] }
        set { self[MDActionsKey.self] = newValue }
    }
    /// 引用里的文字用次要色
    var mdTextColor: Color? {
        get { self[MDTextColorKey.self] }
        set { self[MDTextColorKey.self] = newValue }
    }
    /// 脚注里的文字用小一号的字
    var mdSmall: Bool {
        get { self[MDSmallKey.self] }
        set { self[MDSmallKey.self] = newValue }
    }
    /// 列表嵌套层数（决定项目符号）
    var mdListDepth: Int {
        get { self[MDListDepthKey.self] }
        set { self[MDListDepthKey.self] = newValue }
    }
}

// MARK: 入口

struct DocView: View {
    let doc: MDDoc
    @Environment(\.mdActions) private var actions

    var body: some View {
        // 顶层用 LazyVStack：几千个块的大文档只画看得见的部分。ForEach 直接用锚点做 id，
        // ScrollViewReader 能滚到还没画出来的块（脚注跳转、演示截图定位）
        let items = Array(zip(MDLogic.anchors(doc.blocks), doc.blocks)).filter { $0.1.known }
        LazyVStack(alignment: .leading, spacing: MDStyle.blockSpacing) {
            ForEach(items, id: \.0) { _, b in
                MDBlockView(node: b)
            }
        }
            .textSelection(.enabled)
            .tint(Theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { handle($0) })
    }

    /// 链接：http / https / mailto 交给系统；huijian://message/<id> 在应用内打开；附件链接、脚注在本页处理
    private func handle(_ u: URL) -> OpenURLAction.Result {
        if let id = MDLogic.attID(u) {
            if let a = actions.attachment(id) { actions.openAttachment(a) }
            return .handled
        }
        if let t = MDLogic.webTarget(u) {
            return .systemAction(t)
        }
        if MDLogic.fnNumber(u) != nil {
            actions.scrollTo(MDLogic.footnotesAnchor)
            return .handled
        }
        if let id = MDLogic.messageID(u) {
            actions.openMessage(id)
            return .handled
        }
        switch u.scheme?.lowercased() {
        case "http", "https", "mailto": return .systemAction
        default: return .discarded
        }
    }
}

// MARK: 行内文字

enum MDInline {
    /// runs → AttributedString。粗体 / 斜体 / 删除线 / 行内代码用 inlinePresentationIntent（继承外层字号），
    /// 链接、附件链接、脚注上标用 link 属性，由 DocView 的 openURL 处理
    static func attributed(_ runs: [MDRun]?) -> AttributedString {
        var out = AttributedString()
        for r in runs ?? [] {
            if let n = r.fn {
                // 脚注：上标「[1]」
                var a = AttributedString("[\(n)]")
                a.font = MDStyle.footnoteRef
                a.baselineOffset = MDStyle.footnoteRaise
                a.link = MDLogic.fnURL(n)
                out += a
                continue
            }
            // 附件链接显示为「📎 文字」
            var a = AttributedString(r.att != nil ? "📎 " + r.text : r.text)
            var intent: InlinePresentationIntent = []
            if r.b { intent.insert(.stronglyEmphasized) }
            if r.i { intent.insert(.emphasized) }
            if r.s { intent.insert(.strikethrough) }
            if r.code { intent.insert(.code) }
            if !intent.isEmpty { a.inlinePresentationIntent = intent }
            if r.code { a.backgroundColor = Theme.surface2 }
            if let id = r.att {
                a.link = MDLogic.attURL(id)
            } else if let h = r.href, let u = MDLogic.safeLink(h) {
                let web = ["http", "https"].contains(u.scheme?.lowercased() ?? "")
                // iPhone 包成内部链接（长按预览不去请求网页）；Mac 没有长按预览，直接用原地址（右键「拷贝链接」拿到的是真实地址）
                a.link = web && MDStyle.wrapWebLinks ? (MDLogic.webURL(u) ?? u) : u
            }
            out += a
        }
        return out
    }
}

/// 一段文字（段落、标题、表格单元格都用它）
struct MDText: View {
    let runs: [MDRun]?
    var font: Font? = nil
    @Environment(\.mdTextColor) private var color
    @Environment(\.mdSmall) private var small

    var body: some View {
        Text(MDInline.attributed(runs))
            .font(font ?? (small ? MDStyle.small : MDStyle.body))
            .lineSpacing(small ? 2 : MDStyle.lineSpacing)
            .foregroundStyle(color ?? Theme.text)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: 块

struct MDBlocksView: View {
    let blocks: [MDNode]
    var spacing: CGFloat = MDStyle.blockSpacing

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                if b.known { MDBlockView(node: b) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MDBlockView: View {
    let node: MDNode

    var body: some View {
        switch node.type {
        case "heading":
            let level = min(max(node.level ?? 1, 1), 6)
            MDText(runs: node.runs, font: MDStyle.heading(level))
                .padding(.top, level <= 2 ? 6 : 2)
                .accessibilityAddTraits(.isHeader)
        case "paragraph":
            MDText(runs: node.runs)
        case "list":
            MDListView(node: node)
        case "quote":
            MDQuoteView(blocks: node.blocks ?? [])
        case "callout":
            MDCalloutView(node: node)
        case "code":
            MDCodeView(lang: node.lang ?? "", text: node.text ?? "")
        case "rule":
            Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)
        case "table":
            MDTableView(node: node)
        case "image":
            MDImageBlock(node: node)
        case "file":
            MDFileBlock(node: node)
        case "progress":
            MDProgressView(node: node)
        case "footnotes":
            MDFootnotesView(items: node.items ?? [])
        default:
            EmptyView()
        }
    }
}

// MARK: 列表

struct MDListView: View {
    let node: MDNode
    @Environment(\.mdListDepth) private var depth
    @Environment(\.mdSmall) private var small

    var body: some View {
        let items = node.items ?? []
        let ordered = node.ordered ?? false
        let start = MDLogic.listStart(node)
        let tight = node.tight ?? false
        // 序号列按最长的编号定宽，各项文字左边对齐
        let digits = ordered ? String(start + max(items.count - 1, 0)).count : 0
        VStack(alignment: .leading, spacing: tight ? MDStyle.tightSpacing : MDStyle.blockSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(it, ordered: ordered, number: start + i)
                        .frame(width: ordered ? MDStyle.digitWidth * CGFloat(digits + 1) : MDStyle.bulletWidth,
                               alignment: ordered ? .trailing : .center)
                    MDBlocksView(blocks: it.blocks, spacing: tight ? MDStyle.tightSpacing : MDStyle.blockSpacing)
                        .environment(\.mdListDepth, depth + 1)
                }
            }
        }
        .padding(.leading, depth == 0 ? 2 : 0)
    }

    @ViewBuilder
    private func marker(_ it: MDItem, ordered: Bool, number: Int) -> some View {
        let font = small ? MDStyle.small : MDStyle.body
        if let c = it.check {
            // 任务列表：只读的勾选框
            Text(Image(systemName: c ? "checkmark.square.fill" : "square"))
                .font(font)
                .foregroundStyle(c ? Theme.accent : Theme.text3)
                .accessibilityLabel(c ? "已完成" : "未完成")
        } else if ordered {
            Text("\(number).").font(font.monospacedDigit()).foregroundStyle(Theme.text3)
        } else {
            Text(["•", "◦", "▪︎"][depth % 3]).font(font).foregroundStyle(Theme.text3)
        }
    }
}

// MARK: 引用

struct MDQuoteView: View {
    let blocks: [MDNode]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(Theme.border).frame(width: 3)
            MDBlocksView(blocks: blocks)
                .environment(\.mdTextColor, Theme.text2)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: 提示框

/// 七种提示框的颜色、图标和默认标题（图标、标题见 docs/markdown.md；颜色和安卓一致，深色模式提亮）
struct MDCalloutStyle {
    let color: Color
    let icon: String
    let name: String

    static func of(_ kind: String?) -> MDCalloutStyle {
        switch kind ?? "" {
        case "tip": return MDCalloutStyle(color: Color(light: 0x2E9E7A, dark: 0x5CC4A2), icon: "💡", name: "建议")
        case "important": return MDCalloutStyle(color: Color(light: 0x8250DF, dark: 0xB394F2), icon: "❗", name: "重要")
        case "warning": return MDCalloutStyle(color: Color(light: 0xD9822B, dark: 0xEFA65C), icon: "⚠️", name: "警告")
        case "caution": return MDCalloutStyle(color: Color(light: 0xC0392B, dark: 0xEA7468), icon: "⛔", name: "危险")
        case "success": return MDCalloutStyle(color: Color(light: 0x3C8D5A, dark: 0x66C08A), icon: "✅", name: "成功")
        case "failure": return MDCalloutStyle(color: Color(light: 0xD64545, dark: 0xF08080), icon: "❌", name: "失败")
        default: return MDCalloutStyle(color: Color(light: 0x4A6FD6, dark: 0x8EA8F0), icon: "ℹ️", name: "说明")
        }
    }

    /// 背景：kind 颜色加透明度，浅色 9%、深色 14%（三端一致）
    static func backgroundOpacity(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.14 : 0.09 }
}

struct MDCalloutView: View {
    let node: MDNode
    @State private var open: Bool
    @Environment(\.colorScheme) private var scheme

    init(node: MDNode) {
        self.node = node
        _open = State(initialValue: node.fold != "closed")
    }

    private var foldable: Bool { node.fold == "open" || node.fold == "closed" }

    var body: some View {
        let st = MDCalloutStyle.of(node.kind)
        let title = (node.title ?? "").isEmpty ? st.name : node.title!
        let blocks = node.blocks ?? []
        VStack(alignment: .leading, spacing: 8) {
            if foldable {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { open.toggle() }
                } label: {
                    header(st, title: title, chevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint(open ? "折叠" : "展开")
            } else {
                header(st, title: title, chevron: false)
            }
            if open && !blocks.isEmpty {
                MDBlocksView(blocks: blocks, spacing: MDStyle.blockSpacing - 2)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(st.color.opacity(MDCalloutStyle.backgroundOpacity(scheme)))
        .overlay(alignment: .leading) { Rectangle().fill(st.color).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func header(_ st: MDCalloutStyle, title: String, chevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(st.icon).font(MDStyle.body)
            Text(title).font(MDStyle.body.weight(.semibold)).foregroundStyle(st.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(MDStyle.small.weight(.semibold))
                    .foregroundStyle(st.color.opacity(0.8))
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: 代码块

struct MDCodeView: View {
    let lang: String
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(lang.isEmpty ? "代码" : lang)
                    .font(MDStyle.codeLabel)
                    .foregroundStyle(Theme.text3)
                Spacer(minLength: 8)
                Button {
                    MDPasteboard.copy(text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(MDStyle.codeLabel)
                        .foregroundStyle(copied ? Theme.success : Theme.text2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("复制代码")
            }
            .padding(.horizontal, 12)
            .padding(.top, 7)
            .padding(.bottom, 2)
            ScrollView(.horizontal, showsIndicators: MDStyle.showScrollIndicators) {
                Text(text)
                    .font(MDStyle.code)
                    .foregroundStyle(Theme.text)
                    .lineSpacing(2)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
    }
}

// MARK: 表格

/// 子视图的宽度上限：超过时在这个宽度内换行（表格单元格用，避免一格长文字把表格撑得特别宽）
struct MDMaxWidth: Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let v = subviews.first else { return .zero }
        let w = Swift.min(proposal.width ?? max, max)
        return v.sizeThatFits(ProposedViewSize(width: w, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

struct MDTableView: View {
    let node: MDNode
    /// 超过 200 行时默认只画前 200 行
    @State private var showAll = false

    var body: some View {
        let g = MDLogic.tableGrid(node)
        let limit = MDLogic.tableRowLimit
        let rows = showAll ? g.rows : Array(g.rows.prefix(limit))
        VStack(alignment: .leading, spacing: 8) {
            grid(head: g.head, rows: rows, align: g.align)
            if !showAll && g.rows.count > limit {
                Button("显示全部 \(g.rows.count) 行") { showAll = true }
                    .font(MDStyle.small)
                    .buttonStyle(.borderless)
                    .tint(Theme.accent)
            }
        }
    }

    private func grid(head: [[MDRun]], rows: [[[MDRun]]], align: [String]) -> some View {
        let g = (head: head, rows: rows, align: align)
        return ScrollView(.horizontal, showsIndicators: MDStyle.showScrollIndicators) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                if !g.head.isEmpty {
                    GridRow {
                        ForEach(Array(g.head.enumerated()), id: \.offset) { c, cell in
                            self.cell(cell, align: g.align[c], header: true, shaded: true, last: c == g.align.count - 1)
                        }
                    }
                }
                ForEach(Array(g.rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
                            self.cell(cell, align: g.align[c], header: false, shaded: r % 2 == 1, last: c == g.align.count - 1)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(1)
        }
    }

    private func cell(_ runs: [MDRun], align: String, header: Bool, shaded: Bool, last: Bool) -> some View {
        let a: Alignment = align == "right" ? .trailing : (align == "center" ? .center : .leading)
        let ta: TextAlignment = align == "right" ? .trailing : (align == "center" ? .center : .leading)
        return MDMaxWidth(max: MDStyle.tableCellMaxWidth) {
            Text(MDInline.attributed(runs))
                .font(header ? MDStyle.body.weight(.semibold) : MDStyle.body)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(ta)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 36, maxWidth: .infinity, maxHeight: .infinity, alignment: a)
        .background(header ? Theme.surface2 : (shaded ? Theme.surface2.opacity(0.45) : Color.clear))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: header ? 1 : 0.5) }
        .overlay(alignment: .trailing) { if !last { Rectangle().fill(Theme.border).frame(width: 0.5) } }
    }
}

// MARK: 图片 / 附件

struct MDImageBlock: View {
    let node: MDNode
    @Environment(\.mdActions) private var actions

    var body: some View {
        let alt = node.alt ?? ""
        if let a = actions.attachment(node.att) {
            MDAttachmentImage(att: a, alt: alt)
        } else if let s = node.src, let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
            MDExternalImage(url: u, alt: alt)
        } else {
            // 附件不在这条消息里（理论上服务端已经处理过），按文字显示
            MDText(runs: [MDRun("🖼 " + (alt.isEmpty ? (node.name ?? "图片") : alt))])
        }
    }
}

struct MDFileBlock: View {
    let node: MDNode
    @Environment(\.mdActions) private var actions

    var body: some View {
        if let a = actions.attachment(node.att) {
            MDFileCard(att: a, alt: node.alt ?? "")
        } else {
            MDText(runs: [MDRun("📎 " + (node.name ?? node.alt ?? "附件"))])
        }
    }
}

/// 外部图片：默认不加载（不向陌生服务器暴露 IP 和打开时间），点按后才下载；加载后点图片在应用内全屏查看
/// （QuickLook 看本地临时文件，不交给浏览器再请求一次；临时文件只在点开时才写，App 启动时清空）。
/// 请求用临时会话：不带 Cookie、不带任何登录凭据；单次请求 30 秒、整体 60 秒超时；跳转最多跟 5 次，https 跳到 http 拒绝；
/// 声明的大小或实际读到的超过 20 MB 立刻中止；解码用 ImageIO 缩略图（最长边 2048），超大图不会整张解进内存
struct MDExternalImage: View {
    let url: URL
    let alt: String
    enum Phase: Equatable { case idle, loading, failed(String), done }
    @State private var phase = Phase.idle
    @State private var loaded: Loaded?
    @State private var file: URL?
    @Environment(\.mdActions) private var actions

    /// 下载并解码好的图片：显示用的 Image、显示宽度（点）、原始数据和扩展名（点开全屏时写临时文件用）
    struct Loaded: @unchecked Sendable {
        let image: Image
        let width: CGFloat
        let data: Data
        let ext: String
    }

    nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.httpCookieStorage = nil
        c.urlCredentialStorage = nil
        c.urlCache = nil
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        return URLSession(configuration: c)
    }()
    nonisolated static let maxBytes = 20 << 20
    nonisolated static let maxRedirects = 5

    /// 全屏查看用的临时文件目录（tmp/huijian-ext-img）
    nonisolated static var tempDir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("huijian-ext-img") }

    /// App 启动时清空上次留下的临时文件
    nonisolated static func clearTempFiles() { try? FileManager.default.removeItem(at: tempDir) }

    var body: some View {
        switch phase {
        case .done:
            VStack(alignment: .leading, spacing: 6) {
                // 和附件图片一样不放大小图：最宽不超过原图宽度
                (loaded?.image ?? Image(systemName: "photo")).resizable().scaledToFit()
                    .frame(maxWidth: max(loaded?.width ?? 60, 60), maxHeight: MDStyle.imageMaxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { openFull() }
                    .accessibilityLabel("图片 \(alt)，点按全屏查看")
                if !alt.isEmpty { Text(alt).font(MDStyle.small).foregroundStyle(Theme.text3) }
            }
        case .loading:
            placeholder(symbol: nil, title: "正在加载图片…", tint: Theme.text2)
        case .failed(let why):
            Button { load() } label: { placeholder(symbol: "exclamationmark.triangle", title: "\(why)，点按重试", tint: Theme.danger) }
                .buttonStyle(.plain)
        case .idle:
            Button { load() } label: { placeholder(symbol: "photo", title: "点按加载图片", tint: Theme.accent) }
                .buttonStyle(.plain)
                .accessibilityLabel("加载外部图片 \(alt)")
        }
    }

    private func load() {
        phase = .loading
        let url = url
        Task {
            let r = await Task.detached(priority: .userInitiated) { await Self.fetch(url) }.value
            switch r {
            case .success(let l): loaded = l; phase = .done
            case .failure(let e): phase = .failed(e.message)
            }
        }
    }

    /// 点开全屏：第一次点时才把图片写进临时文件
    private func openFull() {
        if let file, FileManager.default.fileExists(atPath: file.path) { actions.previewFile(file); return }
        guard let loaded, let f = Self.writeTemp(loaded) else { return }
        file = f
        actions.previewFile(f)
    }

    nonisolated static func writeTemp(_ l: Loaded) -> URL? {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let f = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(l.ext)
        return (try? l.data.write(to: f, options: .atomic)) == nil ? nil : f
    }

    struct LoadError: Error, Sendable { let message: String }

    /// 跳转规则（和安卓一致）：最多跟 5 次，https → http 拒绝。返回 nil 表示允许，否则是拦截原因
    nonisolated static func redirectBlock(from: URL?, to: URL?, count: Int) -> String? {
        if count > maxRedirects { return "跳转次数过多，已拦截" }
        guard let scheme = to?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return "跳转地址不支持，已拦截" }
        if from?.scheme?.lowercased() == "https" && scheme == "http" { return "从 https 跳到 http，已拦截" }
        return nil
    }

    /// 每个请求一个：数跳转次数，按上面的规则放行或拦截
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var reason: String?
        var blocked: String? { lock.lock(); defer { lock.unlock() }; return reason }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            lock.lock()
            count += 1
            let why = MDExternalImage.redirectBlock(from: response.url ?? task.currentRequest?.url, to: request.url, count: count)
            if let why { reason = why }
            lock.unlock()
            completionHandler(why == nil ? request : nil)
        }
    }

    /// 下载（边读边计数，超过上限立刻中止）→ ImageIO 缩略图。不在主线程上跑
    nonisolated static func fetch(_ url: URL) async -> Result<Loaded, LoadError> {
        var req = URLRequest(url: url)
        req.httpShouldHandleCookies = false
        let guardian = RedirectGuard()
        do {
            let (bytes, resp) = try await session.bytes(for: req, delegate: guardian)
            if let why = guardian.blocked {
                bytes.task.cancel()
                return .failure(LoadError(message: why))
            }
            // 正文里的外部图片只会是 http(s)；自检用 file:// 地址，没有 HTTP 状态码
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                bytes.task.cancel()
                return .failure(LoadError(message: "图片加载失败"))
            }
            if resp.expectedContentLength > Int64(maxBytes) {
                bytes.task.cancel()
                return .failure(LoadError(message: "图片超过 20 MB，没有加载"))
            }
            var data = Data()
            if resp.expectedContentLength > 0 { data.reserveCapacity(Int(resp.expectedContentLength)) }
            for try await b in bytes {
                data.append(b)
                if data.count > maxBytes {
                    bytes.task.cancel()
                    return .failure(LoadError(message: "图片超过 20 MB，没有加载"))
                }
            }
            guard let made = MDPlatformImage.make(data, maxPixel: 2048) else {
                return .failure(LoadError(message: "不是能显示的图片"))
            }
            return .success(Loaded(image: made.image, width: made.width, data: data, ext: made.ext))
        } catch {
            return .failure(LoadError(message: guardian.blocked ?? "图片加载失败"))
        }
    }

    private func placeholder(symbol: String?, title: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Group {
                if let symbol { Image(systemName: symbol).font(MDStyle.body.weight(.medium)) } else { ProgressView().controlSize(.small) }
            }
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.1)))
            VStack(alignment: .leading, spacing: 2) {
                Text(alt.isEmpty ? title : "\(alt) · \(title)").font(MDStyle.body).foregroundStyle(Theme.text).lineLimit(2)
                Text(url.host ?? url.absoluteString).font(MDStyle.small).foregroundStyle(Theme.text3).lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: MDStyle.cardMaxWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(Rectangle())
    }
}

// MARK: 进度条

struct MDProgressView: View {
    let node: MDNode

    var body: some View {
        let v = MDLogic.clamp01(node.value)
        let color = MDLogic.percent(node.value) >= 100 ? Theme.success : Theme.accent
        VStack(alignment: .leading, spacing: 6) {
            // 「训练进度 75%（15000/20000）」
            Text(MDLogic.progressCaption(node))
                .font(MDStyle.body.monospacedDigit())
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface2)
                    Capsule().fill(color).frame(width: v > 0 ? max(6, geo.size.width * v) : 0)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MDLogic.progressCaption(node))
    }
}

// MARK: 脚注

struct MDFootnotesView: View {
    let items: [MDItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(Theme.border).frame(width: 80, height: 1).padding(.top, 6).padding(.bottom, 2)
            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                let n = it.n ?? (i + 1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // 编号写成「[1]」，和服务端的纯文本预览一致
                    Text("[\(n)]").font(MDStyle.small.monospacedDigit()).foregroundStyle(Theme.text3)
                    MDBlocksView(blocks: it.blocks, spacing: 4)
                }
            }
        }
        .environment(\.mdSmall, true)
        .environment(\.mdTextColor, Theme.text2)
    }
}
