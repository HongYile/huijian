import Foundation

struct Attachment: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var mime: String
    var size: Int64
    /// 服务端文件的 sha256（加密附件是密文的），下载后校验
    let sha256: String
    /// 端到端加密的附件钥匙（来自解密后的载荷，和消息一起保存）；明文附件为 nil
    var key: String? = nil
}

struct Message: Codable, Hashable, Identifiable {
    let id: Int64
    let topic: String
    let thread: String
    let priority: Int
    // 加密消息解开后，标题、正文、类型、附件换成载荷里的（见 applyE2E）
    var type: String
    var text: String
    var desp: String
    let source: String
    let createdAt: Date
    var attachments: [Attachment]
    /// 0.5.0 起：发送这条消息的 pushkey（系统消息为 nil）
    var pushkeyID: Int64?
    /// 0.5.0 起：按本机的接收规则（静默）或「在用设备优先」，这条消息在本机不弹不响
    var silent = false
    /// 0.5.4 起：归档状态（0 自动：超过设定天数归档；1 已归档；2 保留在收件箱）
    var archive = 0
    /// 0.6.0 起：服务端解析好的 Markdown（docs/markdown.md），v 不认识或没有时退回本地解析 desp
    var doc: MDDoc?
    /// 0.6.0 起：纯文本预览（≤200 字），列表摘要优先用它
    var preview = ""
    /// 0.7.0 起：端到端加密的信封（hje1.…）。保留原文，锁定期间收到的消息解锁后重新解密
    var e2e: String?
    /// 本机解密结果：ok 已解开 / locked 本机没有私钥 / wrong_key 别的钥匙加密的 / format 已损坏；nil = 还没处理（或明文消息）
    var e2eStatus: String?

    /// 服务端响应里不能带只在本机产生的字段（docs/e2ee-client.md §1）：解码网络消息后清空解密状态和附件钥匙，
    /// 否则被攻破的服务器可以写一条「已解密」的 🔒 消息
    mutating func stripLocalFields() {
        e2eStatus = nil
        for i in attachments.indices { attachments[i].key = nil }
    }

    /// 端到端加密的消息
    var isE2E: Bool { !(e2e ?? "").isEmpty }
    /// 加密消息还没解开（标题是 T60 / T61 / T62，附件是密文）
    var e2eUnreadable: Bool { isE2E && e2eStatus != "ok" }

    /// 套用解密结果：解开时用载荷里的标题、正文、类型和附件（下载仍用服务端的 id 和密文 sha256），本地解析的 doc / preview；
    /// 解不开时标题显示占位文字、正文为空，服务端的附件（密文）原样保留，解锁后重新解密
    mutating func applyE2E(_ r: E2E.OpenResult) {
        e2eStatus = r.code
        guard case .ok(let o) = r else {
            text = E2E.placeholder(r.code)
            desp = ""
            doc = nil
            preview = ""
            return
        }
        text = o.text
        desp = o.desp
        type = o.type
        doc = o.doc.flatMap { try? JSONDecoder().decode(MDDoc.self, from: $0) }
        preview = o.preview
        attachments = attachments.map { a in
            guard let x = o.atts.first(where: { $0.id == a.id }) else { return a }
            var b = a
            b.name = x.name
            b.mime = x.mime
            b.size = x.size
            b.key = x.key
            return b
        }
    }

    /// 正文按服务端的 doc 绘制（type=text 的消息一律按纯文本）。doc 里一个认识的块都没有时退回本地解析 desp（和安卓一致）
    var renderDoc: MDDoc? {
        guard type != "text", let doc, doc.usable, doc.blocks.contains(where: \.known) else { return nil }
        return doc
    }

    enum CodingKeys: String, CodingKey {
        case id, topic, thread, priority, type, text, desp, source, attachments, silent, archive, doc, preview, e2e
        case createdAt = "created_at"
        case e2eStatus = "e2e_status"
        case pushkeyID = "pushkey_id"
    }

    /// 可选字段用 try? decodeIfPresent：缺字段直接 nil、不构造错误；类型不对仍按没有处理（和 try? decode 结果一样）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        topic = (try? c.decodeIfPresent(String.self, forKey: .topic)) ?? "default"
        thread = (try? c.decodeIfPresent(String.self, forKey: .thread)) ?? ""
        priority = (try? c.decodeIfPresent(Int.self, forKey: .priority)) ?? 3
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "markdown"
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        desp = (try? c.decodeIfPresent(String.self, forKey: .desp)) ?? ""
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        attachments = (try? c.decodeIfPresent([Attachment].self, forKey: .attachments)) ?? []
        pushkeyID = try? c.decodeIfPresent(Int64.self, forKey: .pushkeyID)
        silent = (try? c.decodeIfPresent(Bool.self, forKey: .silent)) ?? false
        archive = (try? c.decodeIfPresent(Int.self, forKey: .archive)) ?? 0
        doc = try? c.decodeIfPresent(MDDoc.self, forKey: .doc)
        preview = (try? c.decodeIfPresent(String.self, forKey: .preview)) ?? ""
        e2e = try? c.decodeIfPresent(String.self, forKey: .e2e)
        if e2e?.isEmpty == true { e2e = nil }
        e2eStatus = try? c.decodeIfPresent(String.self, forKey: .e2eStatus)
    }
}

enum JSONCoding {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = iso.date(from: s) ?? isoFrac.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "无法解析时间 \(s)"))
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(iso.string(from: date))
        }
        return e
    }()
}

/// 文件大小的人类可读格式
func humanSize(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: n)
}

/// 本地数据目录；selftest 时指向测试目录，避免污染真实数据。
struct AppPaths {
    let supportDir: URL
    let cacheDir: URL

    static var standard: AppPaths {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Huijian")
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Huijian")
        return AppPaths(supportDir: support, cacheDir: cache)
    }

    var messagesFile: URL { supportDir.appendingPathComponent("messages.json") }
    var attDir: URL { cacheDir.appendingPathComponent("att") }
}
