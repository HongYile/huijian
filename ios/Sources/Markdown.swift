import SwiftUI

/// 块级 Markdown（与 Mac 端相同的解析规则）：标题、段落、无序/有序列表、引用、代码块、分隔线。
/// 行内样式（粗体、斜体、行内代码、链接）交给 AttributedString；链接只放行 http / https / mailto。
enum MDBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case bullet([String])
    case ordered([String])
    case quote(String)
    case code(String, String) // lang, body
    case rule
}

func parseMarkdownBlocks(_ src: String) -> [MDBlock] {
    var out: [MDBlock] = []
    let lines = src.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var para: [String] = []
    var i = 0

    func flushPara() {
        if !para.isEmpty {
            out.append(.paragraph(para.joined(separator: "\n")))
            para.removeAll()
        }
    }
    func bulletItem(_ l: String) -> String? {
        let t = l.trimmingCharacters(in: .whitespaces)
        for p in ["- ", "* ", "+ ", "• "] where t.hasPrefix(p) { return String(t.dropFirst(p.count)) }
        return nil
    }
    func orderedItem(_ l: String) -> String? {
        let t = l.trimmingCharacters(in: .whitespaces)
        guard let dot = t.firstIndex(where: { $0 == "." || $0 == ")" || $0 == "、" }) else { return nil }
        let num = t[..<dot]
        guard !num.isEmpty, num.count <= 3, num.allSatisfy(\.isNumber) else { return nil }
        let rest = t[t.index(after: dot)...]
        guard rest.hasPrefix(" ") else { return nil }
        return String(rest.dropFirst())
    }

    while i < lines.count {
        let line = lines[i]
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("```") {
            flushPara()
            let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var body: [String] = []
            i += 1
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                body.append(lines[i])
                i += 1
            }
            out.append(.code(lang, body.joined(separator: "\n")))
            i += 1
            continue
        }
        if t.isEmpty { flushPara(); i += 1; continue }
        if t == "---" || t == "***" || t == "___" { flushPara(); out.append(.rule); i += 1; continue }
        if t.hasPrefix("#") {
            let level = t.prefix(while: { $0 == "#" }).count
            if level <= 6, t.dropFirst(level).hasPrefix(" ") {
                flushPara()
                out.append(.heading(min(level, 3), String(t.dropFirst(level + 1))))
                i += 1
                continue
            }
        }
        if t.hasPrefix(">") {
            flushPara()
            var q: [String] = []
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                var s = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                if s.hasPrefix(" ") { s = s.dropFirst() }
                q.append(String(s))
                i += 1
            }
            out.append(.quote(q.joined(separator: "\n")))
            continue
        }
        if bulletItem(line) != nil {
            flushPara()
            var items: [String] = []
            while i < lines.count, let it = bulletItem(lines[i]) { items.append(it); i += 1 }
            out.append(.bullet(items))
            continue
        }
        if orderedItem(line) != nil {
            flushPara()
            var items: [String] = []
            while i < lines.count, let it = orderedItem(lines[i]) { items.append(it); i += 1 }
            out.append(.ordered(items))
            continue
        }
        para.append(line)
        i += 1
    }
    flushPara()
    return out
}

/// 只放行这几种链接；javascript: file: 以及其他 App 的 URL scheme 一律变成普通文字
func isSafeLink(_ u: URL) -> Bool {
    guard let s = u.scheme?.lowercased() else { return false }
    return s == "http" || s == "https" || s == "mailto"
}

/// 行内 Markdown → AttributedString，去掉不安全的链接
func renderInline(_ s: String) -> AttributedString {
    let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                       failurePolicy: .returnPartiallyParsedIfPossible)
    var a = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    for run in a.runs {
        if let link = run.link, !isSafeLink(link) { a[run.range].link = nil }
    }
    return a
}

/// 去掉 Markdown 符号的一行摘要（列表预览、通知正文用）
func plainSummary(_ desp: String, type: String = "markdown", limit: Int = 160) -> String {
    var parts: [String] = []
    if type == "text" {
        parts = [desp]
    } else {
        for b in parseMarkdownBlocks(desp) {
            switch b {
            case .heading(_, let s), .paragraph(let s), .quote(let s):
                parts.append(String(renderInline(s).characters))
            case .bullet(let items), .ordered(let items):
                parts.append(items.map { String(renderInline($0).characters) }.joined(separator: "；"))
            case .code(_, let body):
                parts.append(body.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "")
            case .rule: break
            }
        }
    }
    let joined = parts.joined(separator: " ")
        .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    return joined.count > limit ? String(joined.prefix(limit)) + "…" : joined
}

/// 消息的一行摘要：服务端给了 preview（0.6.0 起）就用它，否则本地解析 desp
func messageSummary(_ m: Message, limit: Int = 160) -> String {
    if m.type != "text", !m.preview.isEmpty { return MDLogic.oneLine(m.preview, limit: limit) }
    return plainSummary(m.desp, type: m.type, limit: limit)
}

/// 列表预览缓存：消息内容不会变（加密消息解开时由 forget 作废），按 id 缓存摘要，列表每次刷新（相对时间每 30 秒走一次）不再重新解析 Markdown
enum PreviewCache {
    private static let cache: NSCache<NSNumber, NSString> = {
        let c = NSCache<NSNumber, NSString>()
        c.countLimit = 4000
        return c
    }()

    /// 退出登录 / 换服务器时清空（新服务器的消息 id 会从 1 重新开始）
    static func clear() { cache.removeAllObjects() }

    static func cached(_ id: Int64) -> Bool { cache.object(forKey: NSNumber(value: id)) != nil }

    /// 内容变了的消息（加密消息解锁后解开）：丢掉旧摘要，下次重新算
    static func forget(_ ids: [Int64]) {
        for id in ids { cache.removeObject(forKey: NSNumber(value: id)) }
    }

    static func summary(_ m: Message) -> String {
        if let s = cache.object(forKey: NSNumber(value: m.id)) { return s as String }
        let s = messageSummary(m)
        cache.setObject(s as NSString, forKey: NSNumber(value: m.id))
        return s
    }
}

// MARK: 视图

struct MarkdownView: View {
    let source: String
    var plain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if plain {
                Text(source).font(.body).lineSpacing(3).foregroundStyle(Theme.text)
            } else {
                ForEach(Array(parseMarkdownBlocks(source).enumerated()), id: \.offset) { _, b in
                    block(b)
                }
            }
        }
        .textSelection(.enabled)
        .tint(Theme.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func block(_ b: MDBlock) -> some View {
        switch b {
        case .heading(let level, let s):
            Text(renderInline(s))
                .font(level == 1 ? .title3.weight(.semibold) : (level == 2 ? .headline : .subheadline.weight(.semibold)))
                .foregroundStyle(Theme.text)
                .padding(.top, 4)
        case .paragraph(let s):
            Text(renderInline(s)).font(.body).lineSpacing(3).foregroundStyle(Theme.text)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("•").font(.body).foregroundStyle(Theme.text3)
                        Text(renderInline(it)).font(.body).foregroundStyle(Theme.text)
                    }
                }
            }
            .padding(.leading, 2)
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(i + 1).").font(.body.monospacedDigit()).foregroundStyle(Theme.text3)
                            .frame(minWidth: 20, alignment: .trailing)
                        Text(renderInline(it)).font(.body).foregroundStyle(Theme.text)
                    }
                }
            }
        case .quote(let s):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.border).frame(width: 3)
                Text(renderInline(s)).font(.body).foregroundStyle(Theme.text2)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let lang, let body):
            VStack(alignment: .leading, spacing: 0) {
                if !lang.isEmpty {
                    Text(lang).font(.caption2.weight(.medium)).foregroundStyle(Theme.text3)
                        .padding(.horizontal, 12).padding(.top, 8)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(body).font(.system(.footnote, design: .monospaced)).foregroundStyle(Theme.text)
                        .lineSpacing(2).fixedSize()
                        .padding(.horizontal, 12).padding(.vertical, lang.isEmpty ? 10 : 6).padding(.bottom, lang.isEmpty ? 0 : 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface2))
        case .rule:
            Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)
        }
    }
}
