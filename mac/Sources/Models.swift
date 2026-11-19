import Foundation

struct Attachment: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let mime: String
    let size: Int64
    let sha256: String
}

struct Message: Codable, Hashable, Identifiable {
    let id: Int64
    let topic: String
    let thread: String
    let priority: Int
    let type: String
    let text: String
    let desp: String
    let source: String
    let createdAt: Date
    let attachments: [Attachment]
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

    /// 正文按服务端的 doc 绘制（type=text 的消息一律按纯文本）。doc 里一个认识的块都没有时退回本地解析 desp（和安卓一致）
    var renderDoc: MDDoc? {
        guard type != "text", let doc, doc.usable, doc.blocks.contains(where: \.known) else { return nil }
        return doc
    }

    enum CodingKeys: String, CodingKey {
        case id, topic, thread, priority, type, text, desp, source, attachments, silent, archive, doc, preview
        case createdAt = "created_at"
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
