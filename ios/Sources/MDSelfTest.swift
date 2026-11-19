import Foundation
import ImageIO
import SwiftUI

// 回笺 Markdown（doc）的自检：解码、兼容旧缓存、绘制用的纯逻辑、行内样式、整篇绘制。
// 这个文件在 Mac（mac/Sources/MDSelfTest.swift）和 iPhone（ios/Sources/MDSelfTest.swift）两端内容完全相同。
// check(名称, 是否通过, 失败时的说明)；render 由各端提供：把 DocView 画成图片，返回尺寸（nil = 失败）。

enum MDSelfTest {
    /// 覆盖全部块类型的 doc（和 server/md.go 的输出格式一致），另加一个不认识的块类型
    static let sampleDoc = #"""
    {"v":1,"blocks":[
     {"type":"heading","level":1,"runs":[{"text":"实验 exp42 完成"}]},
     {"type":"paragraph","runs":[{"text":"注意：","b":true},{"text":"斜体","i":true},{"text":"旧","s":true},{"text":"code","code":true},
       {"text":"链接","href":"https://example.com"},{"text":"坏链接","href":"javascript:alert(1)"},{"text":"#12","href":"huijian://message/12"},
       {"text":"report.pdf","att":"a_2"},{"text":"1","fn":1},{"text":"\n第二行"}]},
     {"type":"progress","text":"15000/20000","value":0.75,"label":"训练进度"},
     {"type":"progress","value":1.7},
     {"type":"table","align":["left","right"],"head":[[{"text":"模型"}],[{"text":"val_loss"}]],
       "rows":[[[{"text":"base","b":true}],[{"text":"0.231"}],[{"text":"多出来的一列"}]],[[{"text":"large"}]]]},
     {"type":"image","att":"a_1","alt":"损失曲线","name":"loss.png","mime":"image/png","size":1000},
     {"type":"image","src":"https://example.com/a.png","alt":"外部图片"},
     {"type":"file","att":"a_2","name":"report.pdf","mime":"application/pdf","size":577,"alt":"评估报告"},
     {"type":"callout","kind":"warning","title":"磁盘 95%","blocks":[{"type":"paragraph","runs":[{"text":"清理旧 checkpoint"}]}]},
     {"type":"callout","kind":"note","title":"完整日志","fold":"closed","blocks":[{"type":"code","text":"step 1 loss 2.3"}]},
     {"type":"quote","blocks":[{"type":"paragraph","runs":[{"text":"普通引用"}]},{"type":"quote","blocks":[{"type":"paragraph","runs":[{"text":"嵌套"}]}]}]},
     {"type":"list","tight":true,"items":[{"check":true,"blocks":[{"type":"paragraph","runs":[{"text":"数据清洗"}]}]},
       {"check":false,"blocks":[{"type":"paragraph","runs":[{"text":"评估"}]},
         {"type":"list","ordered":true,"start":1,"tight":true,"items":[{"blocks":[{"type":"paragraph","runs":[{"text":"子项"}]}]}]}]}]},
     {"type":"list","ordered":true,"start":3,"items":[{"blocks":[{"type":"paragraph","runs":[{"text":"从三开始"}]}]}]},
     {"type":"rule"},
     {"type":"code","lang":"python","text":"print(\"hi\")"},
     {"type":"mermaid","text":"graph TD","future":true},
     {"type":"footnotes","items":[{"n":1,"blocks":[{"type":"paragraph","runs":[{"text":"这是脚注。"}]}]}]}
    ]}
    """#

    static func message(_ extra: String) -> String {
        ##"{"id":42,"priority":3,"text":"t","desp":"# 实验","created_at":"2026-11-17T06:32:05Z","##
            + #""attachments":[{"id":"a_1","name":"loss.png","mime":"image/png","size":1000,"sha256":""},"#
            + #"{"id":"a_2","name":"report.pdf","mime":"application/pdf","size":577,"sha256":""}]"# + extra + "}"
    }

    /// 外部图片下载：上限、解码、写临时文件（用 file:// 地址，不联网）
    static func runAsync(_ report: (String, Bool, String) -> Void) async {
        func check(_ name: String, _ cond: Bool, _ detail: String = "") { report(name, cond, detail) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("huijian-md-selftest")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 一张 3000×1000 的 PNG：解码后最长边应缩到 2048
        let png = dir.appendingPathComponent("a.png")
        if let ctx = CGContext(data: nil, width: 3000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let cg = { ctx.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.7, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 1000)); return ctx.makeImage() }(),
           let dst = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dst, cg, nil)
            CGImageDestinationFinalize(dst)
        }
        MDExternalImage.clearTempFiles()
        switch await MDExternalImage.fetch(png) {
        case .success(let l):
            let tmpBefore = (try? FileManager.default.contentsOfDirectory(atPath: MDExternalImage.tempDir.path)) ?? []
            check("外部图片：下载、解码，加载时不写临时文件", l.ext == "png" && tmpBefore.isEmpty, "\(tmpBefore)")
            // iPhone 按像素当点数（2048），Mac 按 2 倍屏（1024）
            check("外部图片显示宽度不超过原图（缩略图最长边 2048）：\(Int(l.width))", l.width == 2048 || l.width == 1024)
            if let f = MDExternalImage.writeTemp(l) {
                check("点开全屏时才写临时文件（\(f.lastPathComponent)）", f.pathExtension == "png" && f.path.hasPrefix(MDExternalImage.tempDir.path)
                      && FileManager.default.fileExists(atPath: f.path))
            } else {
                check("点开全屏时写临时文件", false, "写入失败")
            }
            MDExternalImage.clearTempFiles()
            check("启动时清空外部图片临时目录", !FileManager.default.fileExists(atPath: MDExternalImage.tempDir.path))
        case .failure(let e):
            check("外部图片：下载、解码", false, e.message)
        }
        // 跳转规则（和安卓一致）
        let hs = URL(string: "https://a.example/x.png")!, h = URL(string: "http://b.example/y.png")!
        check("跳转：http → https、https → https 放行，第 5 次仍放行", MDExternalImage.redirectBlock(from: h, to: hs, count: 1) == nil
              && MDExternalImage.redirectBlock(from: hs, to: hs, count: 5) == nil)
        check("跳转：https → http 拒绝、第 6 次拒绝、跳到非 http(s) 拒绝", MDExternalImage.redirectBlock(from: hs, to: h, count: 1)?.contains("已拦截") == true
              && MDExternalImage.redirectBlock(from: h, to: h, count: 6)?.contains("已拦截") == true
              && MDExternalImage.redirectBlock(from: h, to: URL(string: "file:///etc/passwd"), count: 1) != nil)
        let guardian = MDExternalImage.RedirectGuard()
        let task = MDExternalImage.session.dataTask(with: hs)   // 不启动，只用来调用代理方法
        var allowed: [Bool] = []
        for (from, to) in [(h, hs), (hs, h)] {
            let r = HTTPURLResponse(url: from, statusCode: 302, httpVersion: nil, headerFields: ["Location": to.absoluteString])!
            guardian.urlSession(MDExternalImage.session, task: task, willPerformHTTPRedirection: r, newRequest: URLRequest(url: to)) { allowed.append($0 != nil) }
        }
        task.cancel()
        check("跳转代理：放行 http → https，拦截 https → http 并记下原因", allowed == [true, false] && guardian.blocked?.contains("https 跳到 http") == true,
              "\(allowed) \(guardian.blocked ?? "")")
        let many = MDExternalImage.RedirectGuard()
        let t2 = MDExternalImage.session.dataTask(with: hs)
        var last = true
        for _ in 0..<6 {
            let r = HTTPURLResponse(url: hs, statusCode: 302, httpVersion: nil, headerFields: nil)!
            many.urlSession(MDExternalImage.session, task: t2, willPerformHTTPRedirection: r, newRequest: URLRequest(url: hs)) { last = $0 != nil }
        }
        t2.cancel()
        check("跳转代理：最多跟 5 次，第 6 次拦截", !last && many.blocked?.contains("次数过多") == true, many.blocked ?? "")
        if let data = try? Data(contentsOf: png), let made = MDPlatformImage.make(data, maxPixel: 2048) {
            check("外部图片用 ImageIO 缩略图解码", made.ext == "png")
        } else {
            check("外部图片用 ImageIO 缩略图解码", false, "解不开")
        }
        let huge = dir.appendingPathComponent("huge.png")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: huge) { try? h.truncate(atOffset: UInt64(MDExternalImage.maxBytes) + 1); try? h.close() }
        if case .failure(let e) = await MDExternalImage.fetch(huge) {
            check("外部图片超过 20 MB：中止，不加载（\(e.message)）", e.message.contains("20 MB"), e.message)
        } else {
            check("外部图片超过 20 MB：中止", false, "竟然加载成功")
        }
        let junk = dir.appendingPathComponent("junk.png")
        try? Data("not an image".utf8).write(to: junk)
        if case .failure = await MDExternalImage.fetch(junk) { check("不是图片的内容：报错，不崩溃", true) } else { check("不是图片的内容", false, "竟然成功") }
    }

    @MainActor
    static func run(_ report: (String, Bool, String) -> Void, render: (MDDoc, [Attachment]) -> CGSize?) {
        func check(_ name: String, _ cond: Bool, _ detail: String = "") { report(name, cond, detail) }
        let dec = JSONCoding.decoder
        guard let doc = try? dec.decode(MDDoc.self, from: Data(sampleDoc.utf8)) else {
            check("doc 解码", false, "解码失败")
            return
        }
        let types = doc.blocks.map(\.type)
        check("doc 解码：v=1，\(doc.blocks.count) 个块", doc.usable && doc.blocks.count == 17, "\(types)")
        check("不认识的块类型保留但不绘制", doc.blocks.filter { !$0.known }.map(\.type) == ["mermaid"], "\(types)")

        // 消息模型：带 doc / preview、v 不认识、type=text、旧缓存没有这两个字段
        let withDoc = message(#","preview":"实验\n第二行","doc":"# + sampleDoc)
        if let m = try? dec.decode(Message.self, from: Data(withDoc.utf8)) {
            check("消息带 doc：按 doc 绘制，preview 已解码", m.renderDoc != nil && m.preview == "实验\n第二行")
            if let back = try? dec.decode(Message.self, from: JSONCoding.encoder.encode(m)) {
                check("消息编码再解码：doc、preview 一致（本地缓存）", back.doc == m.doc && back.preview == m.preview && back.renderDoc != nil)
            } else {
                check("消息编码再解码", false, "失败")
            }
            let enc = String(data: (try? JSONCoding.encoder.encode(m)) ?? Data(), encoding: .utf8) ?? ""
            check("缓存里省略 runs 的默认值（不写 \"b\":false）", !enc.contains(#""b":false"#) && enc.contains(#""b":true"#))
        } else {
            check("消息带 doc 解码", false, "失败")
        }
        let v2 = try? dec.decode(Message.self, from: Data(message(#","doc":{"v":2,"blocks":[{"type":"paragraph"}]}"#).utf8))
        check("doc 版本不认识（v=2）→ 退回本地解析", v2 != nil && v2?.doc?.v == 2 && v2?.renderDoc == nil)
        let bad = try? dec.decode(Message.self, from: Data(message(#","doc":"oops","preview":7"#).utf8))
        check("doc / preview 类型不对 → 忽略，消息照常解码", bad != nil && bad?.doc == nil && bad?.preview == "")
        let old = try? dec.decode(Message.self, from: Data(message("").utf8))
        check("旧缓存（没有 doc / preview）照常读取", old != nil && old?.doc == nil && old?.preview == "" && old?.renderDoc == nil)
        let text = try? dec.decode(Message.self, from: Data(message(#","type":"text","doc":"# + sampleDoc).utf8))
        check("type=text 的消息不按 doc 绘制", text != nil && text?.renderDoc == nil)
        let onlyUnknown = try? dec.decode(Message.self, from: Data(message(#","doc":{"v":1,"blocks":[{"type":"mermaid"},{"type":"future"}]}"#).utf8))
        check("doc 里一个认识的块都没有 → 退回本地解析 desp", onlyUnknown != nil && onlyUnknown?.renderDoc == nil)
        let mixed = try? dec.decode(Message.self, from: Data(message(#","doc":{"v":1,"blocks":[{"type":"mermaid"},{"type":"rule"}]}"#).utf8))
        check("有一个认识的块就按 doc 绘制", mixed?.renderDoc != nil)
        let oldState = #"{"messages":["# + message("") + #"],"read":[42],"starred":[]}"#
        check("旧版本的消息缓存文件可以读取", (try? dec.decode(PersistedState.self, from: Data(oldState.utf8)))?.messages.first?.id == 42)

        // 宽容解码：数组里坏掉的元素只跳过那一个
        let lossyJSON = #"""
        {"v":1,"blocks":[
         {"type":"paragraph","runs":[{"text":"好"},{"text":7},"坏",{"text":"也好","b":true}]},
         7,
         {"type":"table","head":[[{"text":"a"}],"坏",[{"text":"b"}]],"rows":[[[{"text":"1"}],[{"text":2}],[{"text":"3"}]],"坏行",[[{"text":"4"},5]]]},
         {"type":"list","ordered":true,"start":99999999999999,"items":[{"blocks":[{"type":"paragraph","runs":[{"text":"x"}]}]},"坏项"]},
         {"type":"list","ordered":true,"start":1e300,"items":[]},
         {"type":"rule"}
        ]}
        """#
        if let ld = try? dec.decode(MDDoc.self, from: Data(lossyJSON.utf8)) {
            check("坏掉的块只跳过那一个（6 → 5 块）", ld.blocks.map(\.type) == ["paragraph", "table", "list", "list", "rule"], "\(ld.blocks.map(\.type))")
            // {"text":7} 按字段宽容解成空文字的一段；"坏" 不是对象，跳过
            check("runs 里坏掉的跳过", MDLogic.plain(ld.blocks[0].runs) == "好也好" && ld.blocks[0].runs?.count == 3, MDLogic.plain(ld.blocks[0].runs))
            let t = ld.blocks[1]
            check("表头 / 行 / 单元格 / runs 每层坏元素跳过", t.head?.count == 2 && t.rows?.count == 2 && t.rows?[0].count == 3
                  && MDLogic.plain(t.rows?[0][1]) == "" && MDLogic.plain(t.rows?[1][0]) == "4", "\(t.head?.count ?? -1) \(t.rows?.map(\.count) ?? [])")
            check("列表项坏掉的跳过", ld.blocks[2].items?.count == 1)
            check("起始号夹到 ±10 亿（不会溢出崩溃）", MDLogic.listStart(ld.blocks[2]) == 1_000_000_000 && MDLogic.listStart(ld.blocks[3]) == 1,
                  "\(MDLogic.listStart(ld.blocks[2])) \(MDLogic.listStart(ld.blocks[3]))")
        } else {
            check("宽容解码", false, "整篇解码失败")
        }
        let zero = try? dec.decode(MDDoc.self, from: Data(#"{"v":1,"blocks":[{"type":"list","ordered":true,"start":0,"items":[]}]}"#.utf8))
        check("有序列表从 0 开始（start=0）", zero.map { MDLogic.listStart($0.blocks[0]) } == 0)

        // 纯逻辑
        let prog = doc.blocks[2], prog2 = doc.blocks[3]
        check("进度条文字「训练进度 75%（15000/20000）」", MDLogic.progressCaption(prog) == "训练进度 75%（15000/20000）", MDLogic.progressCaption(prog))
        check("百分比四舍六入五取偶（12.5% → 12%，13.5% → 14%）", MDLogic.percent(0.125) == 12 && MDLogic.percent(0.135) == 14
              && MDLogic.percent(0.126) == 13, "\(MDLogic.percent(0.125)) \(MDLogic.percent(0.135))")
        var noLabel = MDNode(type: "progress"); noLabel.value = 0.4; noLabel.text = "2/5"
        check("进度条没有 label 时只显示百分比部分", MDLogic.progressCaption(noLabel) == "40%（2/5）", MDLogic.progressCaption(noLabel))
        check("正文里显示的附件图片（含嵌套）", MDLogic.imageAttachmentIDs(doc.blocks + [{ var q = MDNode(type: "quote"); var i = MDNode(type: "image"); i.att = "a_9"; q.blocks = [i]; return q }()]) == ["a_1", "a_9"])
        check("进度超出范围按 100%", MDLogic.percent(prog2.value) == 100 && MDLogic.percent(-0.5) == 0 && MDLogic.percent(nil) == 0
              && MDLogic.progressCaption(prog2) == "100%", MDLogic.progressCaption(prog2))
        let g = MDLogic.tableGrid(doc.blocks[4])
        check("表格按表头列数补齐 / 截断", g.head.count == 2 && g.rows.map(\.count) == [2, 2] && g.rows[1][1].isEmpty
              && g.align == ["left", "right"], "\(g.rows.map(\.count))")
        let g2 = MDLogic.tableGrid({ var n = MDNode(type: "table"); n.rows = [[[MDRun("a")]], [[MDRun("b")], [MDRun("c")]]]; return n }())
        check("表格没有表头时按最宽的行、对齐补空", g2.head.isEmpty && g2.rows.map(\.count) == [2, 2] && g2.align == ["", ""])
        check("有序列表起始号（start=3；省略时 1）", MDLogic.listStart(doc.blocks[12]) == 3
              && MDLogic.listStart(doc.blocks[11].items![1].blocks[1]) == 1)
        check("任务列表勾选状态", doc.blocks[11].items?.map(\.check) == [true, false])
        check("提示框折叠状态（closed）", doc.blocks[9].fold == "closed" && doc.blocks[8].fold == nil)
        check("七种提示框各自的颜色图标", Set(["note", "tip", "important", "warning", "caution", "success", "failure"]
            .map { MDCalloutStyle.of($0).icon }).count == 7 && MDCalloutStyle.of("xyz").name == "说明")
        check("huijian://message/12 → 12", MDLogic.messageID(URL(string: "huijian://message/12")!) == 12
              && MDLogic.messageID(URL(string: "huijian://msg/7")!) == 7 && MDLogic.messageID(URL(string: "https://x/message/1")!) == nil)
        check("链接只放行 http/https/mailto/huijian", MDLogic.safeLink("javascript:alert(1)") == nil && MDLogic.safeLink("file:///etc/passwd") == nil
              && MDLogic.safeLink("mailto:a@b.c") != nil && MDLogic.safeLink("huijian://message/1") != nil)
        check("huijian:// 只认 message/<id>（和旧写法 msg/<id>），其他显示成纯文字", MDLogic.safeLink("huijian://msg/2") != nil
              && MDLogic.safeLink("huijian://settings") == nil && MDLogic.safeLink("huijian://message/abc") == nil && MDLogic.safeLink("huijian://") == nil)
        let anchors = MDLogic.anchors(doc.blocks)
        check("顶层锚点：每种块第一次出现是 md-first-<type>，全部不重复", Set(anchors).count == anchors.count
              && anchors.contains(MDLogic.footnotesAnchor) && anchors[2] == "md-first-progress" && anchors[3] == "md-3", "\(anchors.prefix(4))")
        check("提示框背景透明度：浅色 9%、深色 14%", MDCalloutStyle.backgroundOpacity(.light) == 0.09 && MDCalloutStyle.backgroundOpacity(.dark) == 0.14)
        let au = MDLogic.attURL("a_1 x")
        check("附件内部链接往返（含空格）", au.flatMap(MDLogic.attID) == "a_1 x", au?.absoluteString ?? "nil")
        check("脚注内部链接往返", MDLogic.fnURL(3).flatMap(MDLogic.fnNumber) == 3)
        check("预览压成一行并截断", MDLogic.oneLine("a\n\n b  c", limit: 10) == "a b c" && MDLogic.oneLine("一二三四五", limit: 3) == "一二三…")

        // 行内样式
        let a = MDInline.attributed(doc.blocks[1].runs)
        check("行内文字按顺序拼接（附件链接加 📎，脚注 [1]）", String(a.characters) == "注意：斜体旧code链接坏链接#12📎 report.pdf[1]\n第二行", String(a.characters))
        var links: [String] = [], raw: [String] = [], bold = false, italic = false, strike = false, code = false, sup = false
        for r in a.runs {
            if let l = r.link { raw.append(l.absoluteString); links.append((MDLogic.webTarget(l) ?? l).absoluteString) }
            let ip = r.inlinePresentationIntent ?? []
            let s = String(a[r.range].characters)
            if s == "注意：" { bold = ip.contains(.stronglyEmphasized) }
            if s == "斜体" { italic = ip.contains(.emphasized) }
            if s == "旧" { strike = ip.contains(.strikethrough) }
            if s == "code" { code = ip.contains(.code) }
            if s == "[1]" { sup = (r.baselineOffset ?? 0) > 0 }
        }
        check("粗体 / 斜体 / 删除线 / 行内代码 / 脚注上标", bold && italic && strike && code && sup, "\(bold) \(italic) \(strike) \(code) \(sup)")
        check(MDStyle.wrapWebLinks ? "iPhone：http(s) 链接包成内部链接（长按预览不去请求网页），短按还原成原地址"
                                   : "Mac：http(s) 链接用原地址（右键拷贝链接拿到真实地址），内部链接往返仍然正确",
              (MDStyle.wrapWebLinks ? raw.first?.hasPrefix(MDLogic.webScheme + "://") == true : raw.first == "https://example.com")
              && MDLogic.webURL(URL(string: "https://a.b/c?x=1&y=中")!).flatMap(MDLogic.webTarget)?.absoluteString
                == URL(string: "https://a.b/c?x=1&y=中")!.absoluteString && MDLogic.webTarget(URL(string: "x-huijian-web://open?u=javascript:alert(1)")!) == nil,
              "\(raw.first ?? "")")
        check("链接：去掉 javascript:，附件和脚注用内部链接", links == ["https://example.com", "huijian://message/12",
                                                         MDLogic.attURL("a_2")!.absoluteString, MDLogic.fnURL(1)!.absoluteString], "\(links)")

        // 整篇绘制（所有块，含附件图片、外部图片占位、折叠的提示框）
        let atts = (try? dec.decode(Message.self, from: Data(message("").utf8)))?.attachments ?? []
        if let size = render(doc, atts) {
            check("整篇 doc 绘制成功 \(Int(size.width))×\(Int(size.height))", size.width > 100 && size.height > 600, "\(size)")
        } else {
            check("整篇 doc 绘制", false, "ImageRenderer 没有输出")
        }
        // 折叠：fold=closed 时只画标题，open / 不可折叠时画出内容
        var callout = doc.blocks[9]
        let closedH = render(MDDoc(blocks: [callout]), [])?.height ?? 0
        callout.fold = "open"
        let openH = render(MDDoc(blocks: [callout]), [])?.height ?? 0
        check("可折叠提示框：默认折叠时不画内容（\(Int(closedH)) < \(Int(openH))）", closedH > 0 && closedH + 20 < openH)
        // 大表格默认只画前 200 行
        var big = MDNode(type: "table")
        big.head = [[MDRun("n")]]
        big.rows = (1...1000).map { [[MDRun("\($0)")]] }
        let h200 = render(MDDoc(blocks: [{ var t = big; t.rows = Array(big.rows!.prefix(200)); return t }()]), []) ?? .zero
        let hBig = render(MDDoc(blocks: [big]), []) ?? .zero
        check("1000 行的表格只画前 200 行（加「显示全部」按钮）", hBig.height > h200.height && hBig.height < h200.height + 80,
              "\(Int(h200.height)) / \(Int(hBig.height))")
        let empty = render(MDDoc(blocks: [MDNode(type: "table"), MDNode(type: "list"), MDNode(type: "image"), MDNode(type: "callout")]), [])
        check("缺字段的块也能绘制（不崩溃）", empty != nil)
    }
}
