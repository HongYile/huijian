import SwiftUI

/// 简单的块级 Markdown 解析：标题、段落、无序/有序列表、引用、代码块、分隔线。
/// 行内样式（粗体、斜体、行内代码、链接）交给 AttributedString。
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

func renderMarkdown(_ s: String, plain: Bool) -> AttributedString {
    if plain { return AttributedString(s) }
    let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                       failurePolicy: .returnPartiallyParsedIfPossible)
    return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
}

/// 去掉 Markdown 符号的一行摘要（列表、菜单栏、时间线用）
func plainSummary(_ desp: String, type: String = "markdown", limit: Int = 120) -> String {
    var parts: [String] = []
    if type == "text" {
        parts = [desp]
    } else {
        for b in parseMarkdownBlocks(desp) {
            switch b {
            case .heading(_, let s), .paragraph(let s), .quote(let s):
                parts.append(String(renderMarkdown(s, plain: false).characters))
            case .bullet(let items), .ordered(let items):
                parts.append(items.map { String(renderMarkdown($0, plain: false).characters) }.joined(separator: "；"))
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
func messageSummary(_ m: Message, limit: Int = 120) -> String {
    if m.type != "text", !m.preview.isEmpty { return MDLogic.oneLine(m.preview, limit: limit) }
    return plainSummary(m.desp, type: m.type, limit: limit)
}

// MARK: 视图

struct MarkdownView: View {
    let source: String
    var plain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if plain {
                Text(source).font(.system(size: Theme.fBody)).lineSpacing(3).foregroundStyle(Theme.text)
            } else {
                ForEach(Array(parseMarkdownBlocks(source).enumerated()), id: \.offset) { _, b in
                    block(b)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func block(_ b: MDBlock) -> some View {
        switch b {
        case .heading(let level, let s):
            Text(renderMarkdown(s, plain: false))
                .font(.system(size: level == 1 ? 17 : (level == 2 ? 15 : 14), weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.top, 4)
        case .paragraph(let s):
            Text(renderMarkdown(s, plain: false))
                .font(.system(size: Theme.fBody)).lineSpacing(3).foregroundStyle(Theme.text)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Theme.text3).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3.5 }
                        Text(renderMarkdown(it, plain: false)).font(.system(size: Theme.fBody)).foregroundStyle(Theme.text)
                    }
                }
            }
            .padding(.leading, 4)
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(i + 1).").font(.system(size: Theme.fBody).monospacedDigit()).foregroundStyle(Theme.text3)
                            .frame(minWidth: 18, alignment: .trailing)
                        Text(renderMarkdown(it, plain: false)).font(.system(size: Theme.fBody)).foregroundStyle(Theme.text)
                    }
                }
            }
        case .quote(let s):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.border).frame(width: 3)
                Text(renderMarkdown(s, plain: false)).font(.system(size: Theme.fBody)).foregroundStyle(Theme.text2)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let lang, let body):
            VStack(alignment: .leading, spacing: 0) {
                if !lang.isEmpty {
                    Text(lang).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.text3)
                        .padding(.horizontal, 12).padding(.top, 8)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(body).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                        .lineSpacing(2).fixedSize()
                        .padding(.horizontal, 12).padding(.vertical, lang.isEmpty ? 10 : 6).padding(.bottom, lang.isEmpty ? 0 : 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 0.5))
        case .rule:
            Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)
        }
    }
}
