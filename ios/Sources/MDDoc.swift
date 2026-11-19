import Foundation

// 回笺 Markdown 的结构化结果（服务端 0.6.0 起随消息下发的 doc 字段），规范见 docs/markdown.md「给客户端开发者」。
// 这个文件在 Mac（mac/Sources/MDDoc.swift）和 iPhone（ios/Sources/MDDoc.swift）两端内容完全相同，改动时两边一起改。
// 解码尽量宽容：字段类型不对就当没有，不认识的块类型保留下来但绘制时跳过，不能因为一个块坏了丢掉整条消息。
// 可选字段一律用 try? decodeIfPresent：缺字段、null 直接得到 nil，不用每次构造 keyNotFound 错误（启动解码几千条消息快很多）；
// 类型不对时照样抛错、被 try? 变成 nil，结果和 try? decode 完全一样。

// MARK: 宽容的数组解码：数组里坏掉的元素只跳过那一个（和安卓一致）

/// 什么都不读的占位类型：用来让 unkeyed 容器跳过一个解不开的元素
private struct MDSkip: Decodable { init(from decoder: Decoder) {} }

/// 逐个解码数组元素，解不开的跳过
struct MDLossy<T: Decodable>: Decodable {
    var items: [T]

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [T] = []
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) { out.append(v) } else if (try? c.decode(MDSkip.self)) == nil { break }
        }
        items = out
    }
}

extension KeyedDecodingContainer {
    /// 字段不存在或不是数组 → nil；数组里坏掉的元素跳过
    func lossy<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T]? {
        (try? decodeIfPresent(MDLossy<T>.self, forKey: key))?.items
    }
}

/// doc 整体：{"v": 1, "blocks": [...]}
struct MDDoc: Codable, Hashable {
    var v: Int
    var blocks: [MDNode]

    /// 这个客户端认识的 doc 版本；v 不同时退回自己解析 desp
    static let supportedVersion = 1
    var usable: Bool { v == Self.supportedVersion }

    init(v: Int = MDDoc.supportedVersion, blocks: [MDNode]) { self.v = v; self.blocks = blocks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = (try? c.decodeIfPresent(Int.self, forKey: .v)) ?? 0
        blocks = c.lossy(MDNode.self, forKey: .blocks) ?? []
    }
}

/// 行内文字片段
struct MDRun: Codable, Hashable {
    var text: String
    var b = false
    var i = false
    var s = false
    var code = false
    var href: String?
    var att: String?
    var fn: Int?

    enum CodingKeys: String, CodingKey { case text, b, i, s, code, href, att, fn }

    init(_ text: String, b: Bool = false, i: Bool = false, s: Bool = false, code: Bool = false,
         href: String? = nil, att: String? = nil, fn: Int? = nil) {
        self.text = text; self.b = b; self.i = i; self.s = s; self.code = code; self.href = href; self.att = att; self.fn = fn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        b = (try? c.decodeIfPresent(Bool.self, forKey: .b)) ?? false
        i = (try? c.decodeIfPresent(Bool.self, forKey: .i)) ?? false
        s = (try? c.decodeIfPresent(Bool.self, forKey: .s)) ?? false
        code = (try? c.decodeIfPresent(Bool.self, forKey: .code)) ?? false
        href = (try? c.decodeIfPresent(String.self, forKey: .href)).flatMap { $0.isEmpty ? nil : $0 }
        att = (try? c.decodeIfPresent(String.self, forKey: .att)).flatMap { $0.isEmpty ? nil : $0 }
        fn = (try? c.decodeIfPresent(Int.self, forKey: .fn)).flatMap { $0 > 0 ? $0 : nil }
    }

    /// 和服务端一样省略默认值，本地缓存小一些
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        if b { try c.encode(true, forKey: .b) }
        if i { try c.encode(true, forKey: .i) }
        if s { try c.encode(true, forKey: .s) }
        if code { try c.encode(true, forKey: .code) }
        try c.encodeIfPresent(href, forKey: .href)
        try c.encodeIfPresent(att, forKey: .att)
        try c.encodeIfPresent(fn, forKey: .fn)
    }
}

/// 列表项（check：任务列表的勾选状态）/ 脚注项（n：脚注编号）
struct MDItem: Codable, Hashable {
    var check: Bool?
    var n: Int?
    var blocks: [MDNode]

    init(check: Bool? = nil, n: Int? = nil, blocks: [MDNode]) { self.check = check; self.n = n; self.blocks = blocks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        check = try? c.decodeIfPresent(Bool.self, forKey: .check)
        n = (try? c.decodeIfPresent(Int.self, forKey: .n)).map(MDLogic.clampInt)
        blocks = c.lossy(MDNode.self, forKey: .blocks) ?? []
    }
}

/// 一个块。字段和服务端 server/md.go 的 MDBlock 一一对应，按 type 取用；没有的字段为 nil
struct MDNode: Codable, Hashable {
    var type: String
    var level: Int?
    var runs: [MDRun]?
    var ordered: Bool?
    var start: Int?
    var tight: Bool?
    var items: [MDItem]?
    var blocks: [MDNode]?
    var kind: String?
    var title: String?
    var fold: String?
    var lang: String?
    var text: String?
    var align: [String]?
    var head: [[MDRun]]?
    var rows: [[[MDRun]]]?
    var att: String?
    var src: String?
    var alt: String?
    var name: String?
    var mime: String?
    var size: Int64?
    var value: Double?
    var label: String?

    init(type: String) { self.type = type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? ""
        level = (try? c.decodeIfPresent(Int.self, forKey: .level)).map(MDLogic.clampInt)
        runs = c.lossy(MDRun.self, forKey: .runs)
        ordered = try? c.decodeIfPresent(Bool.self, forKey: .ordered)
        // 起始号夹到 ±10 亿：后面算「起始号 + 项数」不会溢出崩溃
        start = (try? c.decodeIfPresent(Int.self, forKey: .start)).map(MDLogic.clampInt)
        tight = try? c.decodeIfPresent(Bool.self, forKey: .tight)
        items = c.lossy(MDItem.self, forKey: .items)
        blocks = c.lossy(MDNode.self, forKey: .blocks)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        fold = try? c.decodeIfPresent(String.self, forKey: .fold)
        lang = try? c.decodeIfPresent(String.self, forKey: .lang)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        align = (try? c.decodeIfPresent(MDLossy<String>.self, forKey: .align))?.items
        // 表头 / 行 / 单元格 / runs 每一层都宽容：坏掉的那一个跳过
        head = c.lossy(MDLossy<MDRun>.self, forKey: .head)?.map(\.items)
        rows = c.lossy(MDLossy<MDLossy<MDRun>>.self, forKey: .rows)?.map { $0.items.map(\.items) }
        att = try? c.decodeIfPresent(String.self, forKey: .att)
        src = try? c.decodeIfPresent(String.self, forKey: .src)
        alt = try? c.decodeIfPresent(String.self, forKey: .alt)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        mime = try? c.decodeIfPresent(String.self, forKey: .mime)
        size = try? c.decodeIfPresent(Int64.self, forKey: .size)
        value = try? c.decodeIfPresent(Double.self, forKey: .value)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
    }

    /// 绘制端支持的块类型；其他类型跳过（规范：未知 type 的块跳过）
    static let knownTypes: Set<String> = ["heading", "paragraph", "list", "quote", "callout", "code", "rule",
                                          "table", "image", "file", "progress", "footnotes"]
    var known: Bool { Self.knownTypes.contains(type) }
}

// MARK: 绘制要用的纯逻辑（两端共用，自检直接测这些函数）

enum MDLogic {
    /// 进度条旁的文字：label + 百分比 + （text），例如「训练进度 75%（15000/20000）」
    static func progressCaption(_ n: MDNode) -> String {
        let pct = "\(percent(n.value))%"
        let label = (n.label ?? "").trimmingCharacters(in: .whitespaces)
        let text = (n.text ?? "").trimmingCharacters(in: .whitespaces)
        return (label.isEmpty ? "" : label + " ") + pct + (text.isEmpty ? "" : "（\(text)）")
    }

    /// 0–1 → 0–100 的整数百分比（超出范围按 0 / 100）。四舍六入五取偶，和服务端 Go 的 %.0f 一致：12.5% → 12%
    static func percent(_ v: Double?) -> Int { Int((clamp01(v) * 100).rounded(.toNearestOrEven)) }

    static func clamp01(_ v: Double?) -> Double {
        guard let v, v.isFinite else { return 0 }
        return min(max(v, 0), 1)
    }

    /// 表格：按表头列数补齐或截断每一行（表头为空时取最宽的一行）
    static func tableGrid(_ n: MDNode) -> (head: [[MDRun]], rows: [[[MDRun]]], align: [String]) {
        let head = n.head ?? []
        let rows = n.rows ?? []
        let cols = head.isEmpty ? (rows.map(\.count).max() ?? 0) : head.count
        func fit(_ r: [[MDRun]]) -> [[MDRun]] {
            r.count >= cols ? Array(r.prefix(cols)) : r + Array(repeating: [], count: cols - r.count)
        }
        var align = n.align ?? []
        if align.count < cols { align += Array(repeating: "", count: cols - align.count) }
        return (head.isEmpty ? [] : fit(head), rows.map(fit), Array(align.prefix(cols)))
    }

    /// 有序列表的起始数字（服务端 0.6.0 起总会带 start，可能是 0；没带时从 1 开始）
    static func listStart(_ n: MDNode) -> Int { n.start ?? 1 }

    /// 整数字段夹到 ±10 亿（起始号、级别等，防止后续加法溢出）
    static func clampInt(_ v: Int) -> Int { min(max(v, -1_000_000_000), 1_000_000_000) }

    /// 只放行 http / https / mailto 和 huijian://message/<id>（服务端已经过滤过，这里再守一道）；
    /// 其他 huijian:// 链接显示成纯文字
    static func safeLink(_ s: String) -> URL? {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased() else { return nil }
        if scheme == "huijian" || scheme == "hongyan" { return messageID(u) != nil ? u : nil } // 旧消息里可能还有改名前的 hongyan://
        return ["http", "https", "mailto"].contains(scheme) ? u : nil
    }

    /// 行内附件链接、脚注上标在 AttributedString 里用的内部链接（点击时由 DocView 拦下，不交给系统）
    static let attScheme = "x-huijian-att"
    static let fnScheme = "x-huijian-fn"
    /// http / https 链接也包一层内部链接：短按由 DocView 还原后交给系统打开；
    /// 长按时系统的链接预览不认识这个 scheme，不会提前去请求网页（SwiftUI Text 没有关掉链接预览的接口）
    static let webScheme = "x-huijian-web"

    static func webURL(_ u: URL) -> URL? {
        var c = URLComponents()
        c.scheme = webScheme
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "u", value: u.absoluteString)]
        return c.url
    }

    /// 内部 web 链接 → 原来的 http(s) 地址
    static func webTarget(_ u: URL) -> URL? {
        guard u.scheme == webScheme, let s = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "u" })?.value,
              let t = URL(string: s), ["http", "https"].contains(t.scheme?.lowercased() ?? "") else { return nil }
        return t
    }

    static func attURL(_ id: String) -> URL? {
        var c = URLComponents()
        c.scheme = attScheme
        c.host = "a"
        c.path = "/" + id
        return c.url
    }

    static func fnURL(_ n: Int) -> URL? { URL(string: "\(fnScheme)://n/\(n)") }

    /// 内部链接 → 附件 id / 脚注编号
    static func attID(_ u: URL) -> String? {
        guard u.scheme == attScheme else { return nil }
        let id = String(u.path.dropFirst())
        return id.isEmpty ? nil : id
    }

    static func fnNumber(_ u: URL) -> Int? {
        guard u.scheme == fnScheme else { return nil }
        return Int(u.lastPathComponent)
    }

    /// huijian://message/<id>（Mac 早期用的 huijian://msg/<id>、改名前的 hongyan:// 也认）
    static func messageID(_ u: URL) -> Int64? {
        guard let s = u.scheme?.lowercased(), s == "huijian" || s == "hongyan", let h = u.host?.lowercased(), h == "message" || h == "msg" else { return nil }
        return u.pathComponents.first { $0 != "/" }.flatMap { Int64($0) }
    }

    /// 一组 runs 的纯文本（无障碍标签、复制用）
    static func plain(_ runs: [MDRun]?) -> String { (runs ?? []).map(\.text).joined() }

    /// doc 里（含嵌套在列表、引用、提示框里的）以图片显示的附件 id：附件区不再重复显示这些大图
    static func imageAttachmentIDs(_ blocks: [MDNode]) -> Set<String> {
        var out = Set<String>()
        for b in blocks {
            if b.type == "image", let a = b.att { out.insert(a) }
            out.formUnion(imageAttachmentIDs(b.blocks ?? []))
            for it in b.items ?? [] { out.formUnion(imageAttachmentIDs(it.blocks)) }
        }
        return out
    }

    /// 脚注块的锚点（ScrollViewReader 用）：顶层是 LazyVStack，只能滚到顶层块，点脚注上标时滚到脚注块
    static let footnotesAnchor = "md-first-footnotes"

    /// 顶层每个块的锚点：每种块第一次出现的位置是 md-first-<type>（脚注跳转、演示截图滚动定位用），其余 md-<序号>
    static func anchors(_ blocks: [MDNode]) -> [String] {
        var seen = Set<String>()
        return blocks.enumerated().map { i, b in seen.insert(b.type).inserted ? "md-first-" + b.type : "md-\(i)" }
    }

    /// 表格默认只画前这么多行，下面放「显示全部 N 行」
    static let tableRowLimit = 200

    /// 列表摘要：优先用服务端的 preview（多行 → 一行），没有时用客户端解析的摘要
    static func oneLine(_ s: String, limit: Int) -> String {
        let joined = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return joined.count > limit ? String(joined.prefix(limit)) + "…" : joined
    }
}
