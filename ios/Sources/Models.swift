import Foundation

struct Attachment: Codable, Hashable, Identifiable {
    let id: String
    // 加密消息解开后，名字、类型、大小换成载荷里的（见 Message.applyE2E）
    var name: String
    var mime: String
    var size: Int64
    /// 服务端文件的 sha256（加密附件是密文的），下载后校验
    let sha256: String
    /// 端到端加密的附件钥匙（来自解密后的载荷，和消息一起保存）；明文附件为 nil
    var key: String? = nil

    var isImage: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return mime.lowercased().hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff"].contains(ext)
    }

    init(id: String, name: String, mime: String, size: Int64, sha256: String) {
        self.id = id; self.name = name; self.mime = mime; self.size = size; self.sha256 = sha256
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "file"
        mime = (try? c.decodeIfPresent(String.self, forKey: .mime)) ?? "application/octet-stream"
        size = (try? c.decodeIfPresent(Int64.self, forKey: .size)) ?? 0
        sha256 = (try? c.decodeIfPresent(String.self, forKey: .sha256)) ?? ""
        key = try? c.decodeIfPresent(String.self, forKey: .key)
    }
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
    /// 发送这条消息的 pushkey（系统消息为 nil）
    var pushkeyID: Int64?
    /// 服务端按本机规则（key 设为静默、频道静音 / 隐藏、在别的设备上使用中）标记为不提醒
    var silent = false
    var silentReason = ""
    /// 归档状态（0 自动；1 已归档；2 保留在收件箱）
    var archive = 0
    /// 服务端 0.6.0 起：解析好的 Markdown（docs/markdown.md），v 不认识或没有时退回本地解析 desp
    var doc: MDDoc?
    /// 服务端 0.6.0 起：纯文本预览（≤200 字），列表摘要优先用它
    var preview = ""
    /// 0.7.0 起：端到端加密的信封（hje1.…）。保留原文，锁定期间收到的消息解锁后重新解密
    var e2e: String?
    /// 本机解密结果：ok 已解开 / locked 本机没有私钥 / wrong_key 别的钥匙加密的 / format 已损坏；nil = 还没处理（或明文消息）
    var e2eStatus: String?
    /// 0.8.0 起：服务器代加密的消息为 "server"（发送端没加密，服务器收到后立即加密保存，docs/e2ee-client.md §11.5）；发送端加密的没有
    var sealed: String?

    /// 服务器代加密的（详情页显示 T64，不是「🔒 端到端加密」）
    var isServerSealed: Bool { isE2E && sealed == "server" }

    /// 端到端加密的消息
    var isE2E: Bool { !(e2e ?? "").isEmpty }
    /// 加密消息还没解开（标题是 T60 / T61 / T62，附件是密文）
    var e2eUnreadable: Bool { isE2E && e2eStatus != "ok" }

    /// 套用解密结果（docs/e2ee-client.md §6.1）：解开时用载荷里的标题、正文、类型和附件（下载仍用服务端的 id 和密文 sha256），
    /// 本地解析的 doc / preview；解不开时标题显示占位文字、正文为空，服务端的附件（密文）原样保留，解锁后重新解密
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

    /// 服务端响应里的消息：丢掉只能在本机产生的字段（解密状态、附件钥匙），docs/e2ee-client.md §1「本地字段不能来自服务器」。
    /// 否则被攻破的服务器可以带上 e2e_status=ok 和自己写的文字，冒充一条已解开的 🔒 消息
    mutating func dropLocalFields() {
        e2eStatus = nil
        if attachments.contains(where: { $0.key != nil }) {
            attachments = attachments.map { var a = $0; a.key = nil; return a }
        }
    }

    /// 正文按服务端的 doc 绘制（type=text 的消息一律按纯文本）。doc 里一个认识的块都没有时退回本地解析 desp（和安卓一致）
    var renderDoc: MDDoc? {
        guard type != "text", let doc, doc.usable, doc.blocks.contains(where: \.known) else { return nil }
        return doc
    }

    var title: String { text.isEmpty ? (attachments.first?.name ?? "（无标题）") : text }

    enum CodingKeys: String, CodingKey {
        case id, topic, thread, priority, type, text, desp, source, attachments, silent, archive, doc, preview, e2e, sealed
        case createdAt = "created_at"
        case e2eStatus = "e2e_status"
        case pushkeyID = "pushkey_id"
        case silentReason = "silent_reason"
    }

    /// 可选字段用 try? decodeIfPresent：缺字段直接 nil、不构造错误；类型不对仍按没有处理（和 try? decode 结果一样）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        let t = (try? c.decodeIfPresent(String.self, forKey: .topic)) ?? ""
        topic = t.isEmpty ? "default" : t
        thread = (try? c.decodeIfPresent(String.self, forKey: .thread)) ?? ""
        priority = (try? c.decodeIfPresent(Int.self, forKey: .priority)) ?? 3
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "markdown"
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        desp = (try? c.decodeIfPresent(String.self, forKey: .desp)) ?? ""
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? ""
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        attachments = (try? c.decodeIfPresent([Attachment].self, forKey: .attachments)) ?? []
        pushkeyID = try? c.decodeIfPresent(Int64.self, forKey: .pushkeyID)
        silent = (try? c.decodeIfPresent(Bool.self, forKey: .silent)) ?? false
        silentReason = (try? c.decodeIfPresent(String.self, forKey: .silentReason)) ?? ""
        archive = (try? c.decodeIfPresent(Int.self, forKey: .archive)) ?? 0
        doc = try? c.decodeIfPresent(MDDoc.self, forKey: .doc)
        preview = (try? c.decodeIfPresent(String.self, forKey: .preview)) ?? ""
        e2e = try? c.decodeIfPresent(String.self, forKey: .e2e)
        if e2e?.isEmpty == true { e2e = nil }
        e2eStatus = try? c.decodeIfPresent(String.self, forKey: .e2eStatus)
        sealed = try? c.decodeIfPresent(String.self, forKey: .sealed)
        if sealed?.isEmpty == true { sealed = nil }
    }
}

/// 共用规则（E2E.acceptResealed 等）直接判断本地消息
extension Message: E2EMessageFacts {}

/// 频道设置（服务端 0.5.5 起，所有设备共用）
struct ChannelSetting: Codable, Hashable {
    let topic: String
    var alias: String = ""
    var hidden = false
    var muted = false
    var pinned = false
    var sort = 0

    init(topic: String) { self.topic = topic }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topic = try c.decode(String.self, forKey: .topic)
        alias = (try? c.decodeIfPresent(String.self, forKey: .alias)) ?? ""
        hidden = (try? c.decodeIfPresent(Bool.self, forKey: .hidden)) ?? false
        muted = (try? c.decodeIfPresent(Bool.self, forKey: .muted)) ?? false
        pinned = (try? c.decodeIfPresent(Bool.self, forKey: .pinned)) ?? false
        sort = (try? c.decodeIfPresent(Int.self, forKey: .sort)) ?? 0
    }
}

/// 账号的 Bark 转发配置（GET /v1/me 的 bark 字段；未配置时为 nil）
struct BarkConfig: Codable, Hashable {
    let url: String
    let encrypted: Bool

    init(url: String, encrypted: Bool) { self.url = url; self.encrypted = encrypted }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
        encrypted = (try? c.decodeIfPresent(Bool.self, forKey: .encrypted)) ?? false
    }
}

struct ServerFeature: Codable, Hashable {
    let id: String
    let title: String?
    let since: String?
}

struct ServerInfo: Codable {
    let version: String?
    let features: [ServerFeature]?
    /// 旧服务端：开放了注册（登录页显示「注册新账号」）。0.9.0 起看 register
    var register_open: Bool? = nil
    /// 0.9.0 起（功能 register.invite）：注册方式 closed / invite（必须填邀请码）/ open
    var register: String? = nil
    /// 长轮询最长等待秒数（0.6.4 起，功能 poll.long）
    var long_poll_max: Int? = nil
}

extension ServerInfo {
    /// 注册方式：closed 不显示注册入口；invite 注册要填邀请码；open 直接注册。旧服务端按 register_open 推断
    var registerMode: String {
        if let r = register, ["closed", "invite", "open"].contains(r) { return r }
        return register_open == true ? "open" : "closed"
    }
}

struct UpdateInfo: Codable, Hashable {
    let id: Int64?
    let version: String
    let build: Int
    let notes: String?
    let size: Int64?
    /// 应用内下载用：sha256、Ed25519 签名（base64）、下载路径 /v1/update/<id>
    var sha256: String? = nil
    var signature: String? = nil
    var url: String? = nil
}

enum Priority {
    static func label(_ p: Int) -> String {
        switch p {
        case 5...: return "P5 紧急"
        case 4: return "P4 重要"
        case 3: return "P3 普通"
        case 2: return "P2 低"
        case 1: return "P1 日志"
        default: return "P0 调试"
        }
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

/// 应用版本信息（来自 Info.plist）
enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    /// build.local.env 里的 DEFAULT_SERVER，登录页预填
    static let defaultServer = (Bundle.main.object(forInfoDictionaryKey: "HuijianDefaultServer") as? String ?? "")
        .trimmingCharacters(in: .whitespaces)
    static var clientLabel: String { "ios \(version) (\(build))" }
    /// 更新包签名公钥（base64 的 32 字节 Ed25519 公钥，build.sh 按 UPDATE_PUBKEY 写入）。为空时不能应用内下载更新
    static let updatePublicKey = (Bundle.main.object(forInfoDictionaryKey: "HuijianUpdatePublicKey") as? String ?? "")
        .trimmingCharacters(in: .whitespaces)
}
