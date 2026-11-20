import Foundation

// 端到端加密：和界面无关的客户端逻辑（规格见 docs/e2ee-client.md，设计见 docs/e2ee.md）。
// 只依赖 Foundation 和 Core.swift。Mac 与 iPhone 共用同一份文件（ios/Sources/E2E.swift 原样复制），
// 不要在这里引用 AppKit / UIKit / SwiftUI，也不要引用某一端自己的类型（Message、APIClient、AppModel……）。
//
// 接入方式：
//   - 网络：实现 E2ETransport（发请求，返回状态码和响应体；不按状态码抛错，由这里统一解释）；
//   - 安全存储：实现 E2ESecrets（Mac / iPhone 是钥匙串，仅本机、不同步 iCloud）；
//   - 「已升级」标记：E2E.UpgradeMarks（UserDefaults，不是秘密，退出登录也不删）。
// 密码派生（Argon2id / PBKDF2）都在后台线程做，同一时间只算一个；其余核心库调用都在微秒级，可以在主线程调。

/// 网络接入：发一个请求到回笺服务端。body 是已编码的 JSON（nil 表示没有请求体）。
/// 只在网络层失败（连不上、超时）时抛错；HTTP 错误状态照常返回，由 E2E.API 解释。
protocol E2ETransport {
    func e2eSend(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> E2E.Response
}

/// 各端的消息类型（Mac / iPhone 的 Message）实现它，共用的规则（acceptResealed）就能直接判断
protocol E2EMessageFacts {
    var id: Int64 { get }
    /// 带 e2e 信封（发送端加密，或服务器代加密）
    var isE2E: Bool { get }
    /// "server" = 服务器代加密
    var sealed: String? { get }
}

/// 安全存储接入（钥匙串 / Keystore）。读不到返回 nil；读写失败抛错（界面当作「未解锁」并显示原因）。
protocol E2ESecrets {
    func read(_ name: String) throws -> Data?
    func write(_ name: String, _ value: Data) throws
    func remove(_ name: String) throws
}

enum E2E {
    // MARK: - 文案（规格 §9，各端一致）

    enum T {
        static let t1 = "这个账号已经升级到新的登录方式，服务器却要求用旧方式登录。可能有人冒充服务器，已停止登录。如果管理员刚重设过你的密码：请用配对码登录，解锁后重新设置密码。"
        static let t2 = "服务器给的密码保护参数不安全，已拒绝登录。可能有人冒充服务器。"
        static let t3 = "密码不对"
        static let t10 = "🔒 加密消息已锁定：点这里解锁"
        static let t20Title = "开启端到端加密"
        static let t20 = "开启后，新消息的标题、正文和附件只有你登录过的设备能解开，服务器和备份里只有密文。服务器上已有的旧消息也会被加密；用普通 pushkey 发来的消息由服务器收到后立即加密，想让服务器完全看不到内容，发送端请改用「加密发送密钥」。"
        static let t21Title = "保存恢复码"
        static let t21 = "忘记密码、又没有其他设备可以批准时，只能用它解锁加密消息。恢复码只显示这一次，请抄下来或存进密码管理器。"
        static let t21Check = "我已把恢复码保存好"
        static let t22 = "已开启端到端加密。用普通 pushkey 发来的消息由服务器收到后立即加密；想让服务器也看不到内容，到「Pushkey」页复制「加密发送密钥」，换掉脚本里原来的 pushkey。"
        static let t30Title = "请另一台设备批准"
        static let t30 = "在另一台已解锁的设备上打开回笺，它会提示有设备请求解锁。"
        static func t31(_ code: String) -> String { "核对码 \(formatCode(code))：确认和另一台设备上显示的一样，再在那台设备上点「一致，批准」。" }
        static let t32 = "另一台设备拒绝了这次请求。"
        static let t40Title = "用恢复码解锁"
        static let t40Placeholder = "XXXXX-XXXXX-XXXXX-XXXXX-XXXXXX"
        static let t41 = "恢复码不对，或者已经被更换。"
        static let t42Title = "重新设置密码"
        static let t42 = "管理员重设过你的密码，需要设置一个新密码来保护加密钥匙。"
        /// T42 页「当前密码」输入框的说明
        static let t42Field = "填管理员告诉你的临时密码，不要填你自己原来的密码。"
        static let t43 = "收到的钥匙和账号的钥匙对不上，已丢弃。可能有人冒充服务器。"
        static let t44 = "用密码解锁失败：管理员可能重设过你的密码。请用恢复码或另一台设备解锁，解锁后重新设置密码。"
        static func t50(_ device: String) -> String { "「\(device)」请求解锁加密消息：打开回笺核对后批准。" }
        static let t51 = "这个请求已经由另一台设备处理。"
        static let t52 = "核对失败，可能有人冒充这台设备，已拒绝。"
        static func t53(_ code: String) -> String { "核对码 \(formatCode(code))：和新设备上显示的一致吗？" }
        static let t60 = "🔒 加密消息（解锁后查看）"
        static let t61 = "🔒 用别的钥匙加密的消息，这台设备解不开"
        static let t62 = "🔒 加密消息已损坏，无法解开"
        /// 只用于开启加密以前收到、只留在本机的旧明文消息（0.9.0 起服务器上没有明文）
        static let t63 = "未加密：开启加密以前收到、只留在本机的旧消息"
        static let t70 = "发送端用它代替 pushkey，消息会在发送端加密，只有你的设备能解开。它只能加密、不能解密，泄露了也看不到你的消息。"
        static let t73 = "本机解锁一次后才显示（防止被冒充的服务器换掉公钥）。"
        // §11.7（服务端 0.8.0 起：默认自动加密）
        static let t23 = "还没有设置恢复码。忘记密码、又没有其他设备时，只能靠恢复码找回加密消息。"
        static let t24 = "你的密码比较弱，加密钥匙是用密码保护的，建议换一个更长的密码。"
        static let t45 = "这会换一把新的加密钥匙：以前的加密消息只有还留着旧钥匙的设备能看，其他设备上会显示「用别的钥匙加密的消息」。发送端要换成新的加密发送密钥。确定继续吗？"
        static let t46 = "账号的加密钥匙已经更换（可能在别的设备上重置过）。请用密码或恢复码解锁，确认新钥匙。"
        /// 普通 pushkey 发来、服务器代加密的消息（sealed == "server"）：详情元信息行；列表里显示小标签 plainSentTag（§11.5）
        static let t64 = "明文发送：发送端用的是普通 pushkey，没有加密，服务器收到时能看到内容；之后加密保存，数据库和备份里没有明文。想让服务器也看不到，请改用加密发送密钥。"
        static let plainSentTag = "明文发送"
        static let t65 = "用普通 pushkey 发来的消息，服务器收到后立即用你的公钥加密再保存，数据库和备份里没有明文。服务器在收到的那一刻能看到内容；想让服务器完全看不到，请改用加密发送密钥。"
        static let t66 = "普通 pushkey 适合 curl 等无法加密的发送端，消息由服务器收到后立即代为加密。"
        static let t67 = "输入一次密码，开启端到端加密：之后服务器上只保存密文。"
        // §12.6（服务端 0.10.0 起：配对码带钥匙）
        static let t80 = "用新设备扫这个二维码，或在登录页输入下面的配对码：登录后直接解锁加密消息，不用输密码。3 分钟内有效，只能用一次。只给自己的设备用，不要截图发给别人。"
        static let t81 = "新设备在登录页输入这 6 位配对码，登录后需要输入密码（或用这台设备批准）解锁加密消息。这台设备解锁后，生成的配对码可以让新设备直接解锁。"
        static let t82 = "配对码里的钥匙对不上，加密消息还没解锁：请输入密码解锁。"
        static let t83 = "这个配对码没有带钥匙，加密消息还没解锁：请输入密码解锁。"
        static let t84 = "这台设备已经登录。要用这个配对码加入另一个账号，请先退出登录。"

        // 规格里没有编号、但各端最好一致的提示
        static let weakCurrent = "当前密码不够安全，请换一个新密码"
        static let lockedCannotChange = "本机还没有解锁加密消息，请先解锁（设置里的「加密」或「端到端加密」页），再改密码"
        static let noPrelogin = "服务器没有给出新登录方式的参数（加密功能的服务器一定有），可能有人冒充服务器，已停止。"
        static let setupUncertain = "网络出错，暂时无法确认加密是否已经开启。新钥匙和恢复码已保存在本机，网络恢复后会自动检查结果；也可以稍后再点一次「开启」。"
        static let setupNotDone = "上次开启加密没有成功，请重新点「开启」。"
        static let autoSetupRunning = "正在开启加密…"
        static let autoSetupFailed = "自动开启加密暂时没有成功，下次刷新或用密码登录时会自动重试；也可以在下面手动开启。"
        /// 重置加密 / 更换加密钥匙成功后的提示（带「去 Pushkey 页」跳转）
        static let resetDone = "加密钥匙已更换，请到 Pushkey 页复制新的加密发送密钥，替换脚本里的旧密钥。"
        /// 注册请求网络出错 / 超时（服务端可能已经建号）
        static let registerUncertain = "注册结果不确定：可能已经注册成功，请先用这个用户名和密码登录"
        /// 上次注册结果不确定，这次注册又被拒（用户名已被使用 409、邀请码已用完等 403）：多半上次已经成功，改去登录
        static let registerTryLogin = "上次注册可能已经成功，请改用登录，用这个用户名和密码登录"
        /// 取不到服务器信息（/v1/info）：不猜是新是旧，不提交注册
        static let serverUnreachable = "连不上服务器，请检查地址或网络后重试"
        /// 注册一律不发密码原文：服务端没有新登录协议（没有 prelogin，0.6 及以前）
        static let registerServerTooOld = "服务器版本太旧，请先升级回笺服务端"
        static let resetUncertain = "网络出错，暂时无法确认是否已经重置。新钥匙已保存在本机，确认重置成功后会自动换上；24 小时内没有换上就按没有成功处理。也可以现在放弃这次重置，或者再试一次。"
        static let recoveryUncertain = "网络出错，暂时无法确认恢复码是否已经更换。新恢复码已保存在本机，确认更换成功后会自动显示；如果一直没有显示，说明没换成，旧恢复码仍然有效，可以稍后再换一次。"
        static let noRecovery = "这个账号没有设置恢复码，请用密码或另一台设备解锁"
        static let restarted = "对方重新发起了请求，请在列表里重新批准"
        static let requestGone = "对方已取消请求，或已由其他设备处理"
        static let unsupported = "服务端版本较旧，不支持端到端加密，更新服务端到 0.7.0 以上后可用"
    }

    /// 核对码按 3+3 位显示：482913 → 482 913
    static func formatCode(_ c: String) -> String {
        c.count == 6 ? "\(c.prefix(3)) \(c.suffix(3))" : c
    }

    // MARK: - 错误

    struct Failure: LocalizedError, Equatable {
        enum Kind: String {
            case downgrade          // T1
            case weakParams         // T2
            case wrongPassword      // T3
            case weakPassword       // 新密码不合格（原因在 message 里）
            case keyMismatch        // T43
            case keyChanged         // T46：账号的钥匙已经更换（别的设备重置过加密），本机拿的是旧钥匙
            case conflict           // 409：状态变了（别的设备刚开启过、请求被接手……）
            case server             // 其他 HTTP 错误，message 是服务端的说明
            case unsupported        // 服务端没有这个接口（旧版本）
            case locked             // 本机没有可用的私钥
            case badRecovery        // 恢复码格式不对 / T41
            case denied             // T32 / T52
            case uncertain          // 注册结果不确定（registerUncertain）：之后再注册被拒时提示改去登录（registerAfterUncertain）
            case storage            // 钥匙串读写失败
            case core               // 核心库报错
        }
        let kind: Kind
        let message: String
        var status = 0
        var errorDescription: String? { message }

        init(_ kind: Kind, _ message: String, status: Int = 0) {
            self.kind = kind
            self.message = message
            self.status = status
        }
    }

    // MARK: - 网络

    struct Response {
        let status: Int
        let data: Data
        var contentType = ""
    }

    /// 服务端返回的错误说明：JSON 的 error 字段；代理返回的 HTML 错误页不显示
    static func errorMessage(_ r: Response) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any], let e = obj["error"] as? String { return e }
        let s = String(decoding: r.data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.hasPrefix("<") { return "请求失败（HTTP \(r.status)）" }
        return r.status >= 500 ? "服务器出错（HTTP \(r.status)）：\(s)" : s
    }

    /// 旧服务端没有这个接口：路由层返回纯文本 404 / 405（业务上的 404 都带 {"error":…}；HTML 404 是地址问题）
    static func isMissingRoute(_ r: Response) -> Bool {
        guard r.status == 404 || r.status == 405 else { return false }
        if (try? JSONSerialization.jsonObject(with: r.data) as? [String: Any])?["error"] != nil { return false }
        if r.contentType.lowercased().contains("html") { return false }
        let body = String(decoding: r.data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return r.status == 405 || body == "not found" || body == "404 page not found"
    }

    /// 对一个 E2ETransport 的薄封装：编码请求体、按状态码抛 Failure
    struct API {
        let transport: E2ETransport
        init(_ transport: E2ETransport) { self.transport = transport }

        @discardableResult
        func call(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Data {
            let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
            let r = try await transport.e2eSend(method, path, query: query, body: data)
            if (200...299).contains(r.status) { return r.data }
            if E2E.isMissingRoute(r) { throw Failure(.unsupported, T.unsupported, status: r.status) }
            throw Failure(r.status == 409 ? .conflict : .server, E2E.errorMessage(r), status: r.status)
        }

        func get<R: Decodable>(_ type: R.Type, _ path: String, query: [URLQueryItem] = []) async throws -> R {
            try JSONDecoder().decode(R.self, from: try await call("GET", path, query: query))
        }

        func state() async throws -> State { try await get(State.self, "/v1/e2e") }
    }

    // MARK: - 服务端结构

    /// GET /v1/prelogin
    struct Prelogin: Decodable, Equatable {
        var kdf: String
        var salt: String
        var time: Int?
        var memory_kib: Int?
        var lanes: Int?
        var iterations: Int?
    }

    struct Key: Codable, Equatable, Hashable {
        var kid: String
        var pub: String
        var active: Bool
    }

    /// GET /v1/e2e 的 device：本机登记的公钥和批准进度
    struct DeviceInfo: Codable, Equatable {
        var pub = ""
        var grant = ""
        var requested = false
        var challenge = ""
        var revealed = false

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            pub = (try? c.decodeIfPresent(String.self, forKey: .pub)) ?? ""
            grant = (try? c.decodeIfPresent(String.self, forKey: .grant)) ?? ""
            requested = (try? c.decodeIfPresent(Bool.self, forKey: .requested)) ?? false
            challenge = (try? c.decodeIfPresent(String.self, forKey: .challenge)) ?? ""
            revealed = (try? c.decodeIfPresent(Bool.self, forKey: .revealed)) ?? false
        }
    }

    /// 等待批准的其他设备
    struct Request: Codable, Equatable, Identifiable {
        var device_id: String
        var name = ""
        var platform = ""
        var pub = ""
        var requested_at: Int64 = 0
        var commit = ""
        var challenge = ""
        var reveal = ""
        var id: String { device_id }

        init(device_id: String, name: String = "", platform: String = "", pub: String = "", requested_at: Int64 = 0,
             commit: String = "", challenge: String = "", reveal: String = "") {
            self.device_id = device_id; self.name = name; self.platform = platform; self.pub = pub
            self.requested_at = requested_at; self.commit = commit; self.challenge = challenge; self.reveal = reveal
        }

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            device_id = try c.decode(String.self, forKey: .device_id)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
            platform = (try? c.decodeIfPresent(String.self, forKey: .platform)) ?? ""
            pub = (try? c.decodeIfPresent(String.self, forKey: .pub)) ?? ""
            requested_at = (try? c.decodeIfPresent(Int64.self, forKey: .requested_at)) ?? 0
            commit = (try? c.decodeIfPresent(String.self, forKey: .commit)) ?? ""
            challenge = (try? c.decodeIfPresent(String.self, forKey: .challenge)) ?? ""
            reveal = (try? c.decodeIfPresent(String.self, forKey: .reveal)) ?? ""
        }

        /// 同一个请求只通知一次：设备 + 请求时间
        var notifyKey: String { "\(device_id)@\(requested_at)" }
    }

    /// GET /v1/e2e
    struct State: Codable, Equatable {
        var enabled = false
        var keys: [Key] = []
        /// 旧服务端的「只接受加密消息」：0.9.0 起取消，只为兼容解码保留
        var e2e_only = false
        /// 账号是否已升级到新登录协议
        var auth_key = false
        var has_password_wrap = false
        var recovery_wrap = ""
        var device = DeviceInfo()
        var requests: [Request] = []
        /// 0.8.0 起：服务器代加密（始终为 true，没有开关）
        var server_seal = false
        /// 0.8.0 起：服务器上本账号还剩的明文消息条数
        var plain_messages = 0

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
            keys = (try? c.decodeIfPresent([Key].self, forKey: .keys)) ?? []
            e2e_only = (try? c.decodeIfPresent(Bool.self, forKey: .e2e_only)) ?? false
            auth_key = (try? c.decodeIfPresent(Bool.self, forKey: .auth_key)) ?? false
            has_password_wrap = (try? c.decodeIfPresent(Bool.self, forKey: .has_password_wrap)) ?? false
            recovery_wrap = (try? c.decodeIfPresent(String.self, forKey: .recovery_wrap)) ?? ""
            device = (try? c.decodeIfPresent(DeviceInfo.self, forKey: .device)) ?? DeviceInfo()
            requests = (try? c.decodeIfPresent([Request].self, forKey: .requests)) ?? []
            server_seal = (try? c.decodeIfPresent(Bool.self, forKey: .server_seal)) ?? false
            plain_messages = (try? c.decodeIfPresent(Int.self, forKey: .plain_messages)) ?? 0
        }

        /// 当前有效（接收新消息）的钥匙
        var activeKey: Key? { keys.first { $0.active } }
        var hasRecovery: Bool { !recovery_wrap.isEmpty }
    }

    /// 登录响应里的 e2e（用登录凭证登录时才有）
    struct LoginInfo: Decodable {
        var enabled = false
        var keys: [Key] = []
        var password_wrap = ""

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
            keys = (try? c.decodeIfPresent([Key].self, forKey: .keys)) ?? []
            password_wrap = (try? c.decodeIfPresent(String.self, forKey: .password_wrap)) ?? ""
        }
        enum CodingKeys: String, CodingKey { case enabled, keys, password_wrap }
    }

    // MARK: - 「已升级」标记、钉住的公钥（§1、§2）

    /// 服务器地址规范化后才能当作键：scheme、host 小写，去掉默认端口（http 80、https 443）和末尾的 /
    static func normalizeServer(_ server: String) -> String {
        var t = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        guard var c = URLComponents(string: t), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased() else {
            return t.lowercased()
        }
        c.scheme = scheme
        c.host = host
        if (scheme == "http" && c.port == 80) || (scheme == "https" && c.port == 443) { c.port = nil }
        var out = c.string ?? t.lowercased()
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// 「这个服务器上的这个账号已升级到新登录协议」：之后再收到 pbkdf2 就拒绝（防降级）。不是秘密，退出登录也不删
    struct UpgradeMarks {
        let defaults: UserDefaults
        var key = "huijian.e2e.upgraded"

        init(defaults: UserDefaults) { self.defaults = defaults }

        /// 服务器地址规范化（normalizeServer）；用户名按服务端规则（空白合并、不区分大小写）
        static func id(server: String, username: String) -> String {
            let u = username.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
            return normalizeServer(server) + "|" + u
        }

        func isUpgraded(server: String, username: String) -> Bool {
            (defaults.stringArray(forKey: key) ?? []).contains(Self.id(server: server, username: username))
        }

        func mark(server: String, username: String) {
            let id = Self.id(server: server, username: username)
            var all = defaults.stringArray(forKey: key) ?? []
            guard !all.contains(id) else { return }
            all.append(id)
            defaults.set(all, forKey: key)
        }
    }

    // MARK: - 本机保存的钥匙（§1）

    /// 按「服务器 + 账号 id」区分
    static func scope(server: String, accountID: Int64) -> String { "\(normalizeServer(server))#\(accountID)" }

    /// 一个账号在本机的钥匙：账号私钥（可能多把）、等待批准时生成的设备钥匙对（都在安全存储里），
    /// 以及钉住的账号公钥（普通偏好设置，第一次保存私钥时写入，之后不改，退出登录也不删）
    struct KeyRing {
        let secrets: E2ESecrets
        let scope: String
        /// 钉住的公钥存在这里（不是秘密）
        let defaults: UserDefaults
        var pinsKey = "huijian.e2e.pinned"
        /// 这个账号在本机还「活着」（没有退出登录、没有换账号）。退出时调用方 kill()：
        /// 正在进行的自动开启、重置等完成时，不再往钥匙串和偏好设置里写这个账号的东西（删除照常）
        let alive: AliveFlag

        init(secrets: E2ESecrets, scope: String, defaults: UserDefaults, alive: AliveFlag = AliveFlag()) {
            self.secrets = secrets
            self.scope = scope
            self.defaults = defaults
            self.alive = alive
        }

        /// 写入都在 alive 的锁里执行：已经退出登录 / 换了账号就报错（调用方多数用 try?，等于丢弃）；
        /// kill() 要等正在进行的写入结束，所以 kill() 之后的 removeAll() 一定在最后一次写入之后
        private func write(_ body: () throws -> Void) throws {
            try alive.whileAlive(body)
        }

        /// 钉住的账号公钥（§1）；本机从没保存过私钥时 nil
        var pinned: String? { (defaults.dictionary(forKey: pinsKey) as? [String: String])?[scope] }

        /// 用新公钥替换钉住的（§11.4）：只用于服务器伪造不了的来源——本机生成、用密码解锁、用恢复码解锁
        func replacePin(_ pub: String) {
            try? write {
                var all = (defaults.dictionary(forKey: pinsKey) as? [String: String]) ?? [:]
                guard all[scope] != pub else { return }
                all[scope] = pub
                defaults.set(all, forKey: pinsKey)
            }
        }

        /// 还没钉住时钉住这把公钥；已经钉住的不改
        func pinIfNeeded(_ pub: String) {
            try? write {
                var all = (defaults.dictionary(forKey: pinsKey) as? [String: String]) ?? [:]
                guard all[scope] == nil else { return }
                all[scope] = pub
                defaults.set(all, forKey: pinsKey)
            }
        }

        var keysName: String { "e2e-keys|" + scope }
        var deviceName: String { "e2e-device|" + scope }
        var setupName: String { "e2e-setup|" + scope }
        var recoveryName: String { "e2e-recovery|" + scope }

        /// 进行中的更换恢复码（§7 第 3 项）：新恢复码和这次上传的 recovery_wrap，发请求前存进安全存储，点「完成」、请求被拒（4xx）、退出登录时删除
        func pendingRecovery() throws -> RecoveryAttempt? {
            guard let d = try secrets.read(recoveryName) else { return nil }
            return try? JSONDecoder().decode(RecoveryAttempt.self, from: d)
        }

        func savePendingRecovery(_ a: RecoveryAttempt) throws {
            let d = try JSONEncoder().encode(a)
            try write { try secrets.write(recoveryName, d) }
        }

        func deletePendingRecovery() throws { try secrets.remove(recoveryName) }

        /// 进行中的开启（§4.1）：新钥匙对和恢复码，从生成起就存在安全存储里，点「完成」、确认开启失败、退出登录时删除
        func pendingSetup() throws -> SetupAttempt? {
            guard let d = try secrets.read(setupName) else { return nil }
            return try? JSONDecoder().decode(SetupAttempt.self, from: d)
        }

        func savePendingSetup(_ a: SetupAttempt) throws {
            let d = try JSONEncoder().encode(a)
            try write { try secrets.write(setupName, d) }
        }

        func deletePendingSetup() throws { try secrets.remove(setupName) }

        func accountKeys() throws -> [String] {
            guard let d = try secrets.read(keysName) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: d)) ?? []
        }

        func addAccountKey(_ sk: String) throws {
            try write {
                var ks = try accountKeys()
                guard !ks.contains(sk) else { return }
                ks.append(sk)
                try secrets.write(keysName, try JSONEncoder().encode(ks))
            }
        }

        func removeAccountKey(_ sk: String) throws {
            let ks = try accountKeys().filter { $0 != sk }
            if ks.isEmpty { try secrets.remove(keysName) } else { try secrets.write(keysName, try JSONEncoder().encode(ks)) }
        }

        func deviceKeypair() throws -> (sk: String, pub: String)? {
            guard let d = try secrets.read(deviceName),
                  let o = try? JSONDecoder().decode([String: String].self, from: d),
                  let sk = o["sk"], let pub = o["pub"] else { return nil }
            return (sk, pub)
        }

        func saveDeviceKeypair(sk: String, pub: String) throws {
            let d = try JSONEncoder().encode(["sk": sk, "pub": pub])
            try write { try secrets.write(deviceName, d) }
        }

        func deleteDeviceKeypair() throws { try secrets.remove(deviceName) }

        /// 退出登录、设备被移除、换账号时：删除这个账号的全部私钥、设备钥匙对和进行中的开启。
        /// 钉住的公钥（偏好设置里）不删
        func removeAll() throws {
            try secrets.remove(keysName)
            try secrets.remove(deviceName)
            try secrets.remove(setupName)
            try secrets.remove(recoveryName)
        }
    }

    /// 账号「活着」的标记（线程安全）：KeyRing.alive。退出登录、换账号时 kill，之后这个账号的 KeyRing 不再写入。
    /// 写入在锁里执行（whileAlive），kill() 拿同一把锁：kill() 返回时没有进行中的写入，之后也不会再有
    final class AliveFlag: @unchecked Sendable {
        /// 可重入：写入里再调用 isAlive / 嵌套写入不会死锁
        private let lock = NSRecursiveLock()
        private var value = true
        init() {}
        var isAlive: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func kill() { lock.lock(); value = false; lock.unlock() }

        /// 还活着就在锁里执行 body，否则报错（不执行）
        func whileAlive<R>(_ body: () throws -> R) throws -> R {
            lock.lock(); defer { lock.unlock() }
            guard value else { throw Failure(.storage, "已经退出登录，不再保存这个账号的钥匙") }
            return try body()
        }
    }

    /// 内存里的存储：自检、测试、演示用（不碰钥匙串）
    final class MemorySecrets: E2ESecrets {
        private var items: [String: Data] = [:]
        private let lock = NSLock()
        init() {}
        func read(_ name: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return items[name] }
        func write(_ name: String, _ value: Data) throws { lock.lock(); items[name] = value; lock.unlock() }
        func remove(_ name: String) throws { lock.lock(); items[name] = nil; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    }

    // MARK: - 状态（§3）

    enum Status: Equatable {
        case off        // 未开启
        case unlocked   // 本机有私钥，且对应账号某把有效的钥匙
        case locked     // 已开启，本机没有可用的私钥
    }

    /// 本机钥匙里对应账号有效钥匙的那把私钥（没有 → nil）
    static func usableKey(_ st: State, localKeys: [String]) -> String? {
        let active = Set(st.keys.filter(\.active).map(\.pub))
        return localKeys.first { sk in (try? Core.publicKey(sk).pub).map { active.contains($0) } ?? false }
    }

    static func status(_ st: State, localKeys: [String]) -> Status {
        guard st.enabled else { return .off }
        return usableKey(st, localKeys: localKeys) != nil ? .unlocked : .locked
    }

    /// 解锁后要重新设置密码（§4.4.4）：账号回到了旧登录方式，或者用密码锁住的副本已失效
    static func needsPasswordReset(_ st: State) -> Bool { st.enabled && (!st.auth_key || !st.has_password_wrap) }

    /// §4.5：核对私钥对应的公钥是 keys 里一把有效的钥匙，并且和钉住的公钥（有的话）相同；对不上抛 T43
    @discardableResult
    static func verify(sk: String, keys: [Key], pinned: String?) throws -> String {
        guard let pub = try? Core.publicKey(sk).pub, keys.contains(where: { $0.active && $0.pub == pub }),
              pinned == nil || pinned == pub else {
            throw Failure(.keyMismatch, T.t43)
        }
        return pub
    }

    /// §4.5 核对后保存私钥；还没钉住公钥时钉住它。用于设备批准转交来的私钥：必须等于钉住的公钥，不能用来替换（§11.4）
    static func acceptKey(_ sk: String, keys: [Key], ring: KeyRing) throws {
        let pub = try verify(sk: sk, keys: keys, pinned: ring.pinned)
        try saveKey(sk, ring: ring)
        ring.pinIfNeeded(pub)
    }

    /// §11.4：服务器伪造不了的来源（本机生成、用密码解锁、用恢复码解锁）拿到的私钥。
    /// 核对它是账号一把有效的钥匙（不和钉住的比），保存，并用它的公钥**替换**钉住的公钥；本机原有的旧私钥保留（解旧消息用）
    static func acceptOwnKey(_ sk: String, keys: [Key], ring: KeyRing) throws {
        let pub = try verify(sk: sk, keys: keys, pinned: nil)
        try saveKey(sk, ring: ring)
        ring.replacePin(pub)
    }

    /// §11.3 第 6 步：本机钉住过公钥，服务器的有效钥匙却不是它（别的设备重置过加密）→ 加密页显示 T46，引导用密码或恢复码解锁
    static func keyChanged(_ st: State, pinned: String?) -> Bool {
        guard st.enabled, let pin = pinned, let active = st.activeKey else { return false }
        return active.pub != pin
    }

    /// 私钥对应的 kid（和信封里同一个算法）。上传锁住的副本（password_wrap、recovery_wrap、grant）时一并发送（§11.5）
    static func kid(of sk: String) -> String { (try? Core.publicKey(sk).kid) ?? "" }

    /// 上传副本时服务端返回 409：看看本机这把钥匙是否已经停用（账号在别的设备上重置过加密）→ T46；否则原样返回
    static func staleKeyError(_ api: API, kid: String, _ error: Error) async -> Error {
        guard let f = error as? Failure, f.status == 409, !kid.isEmpty else { return error }
        guard let st = try? await api.state() else { return error }
        if !st.keys.contains(where: { $0.kid == kid && $0.active }) { return Failure(.keyChanged, T.t46, status: 409) }
        return error
    }

    /// Pushkey 页「加密发送密钥」这一行显示什么（§7 第 1 项）
    enum SendKey: Equatable {
        case hidden             // 账号没开启加密：不显示这一行
        case key(String)        // <pushkey>.e2e.<钉住的公钥>
        case needsUnlock        // 本机从没解锁过（没有钉住的公钥）：显示 T73
        case mismatch           // 服务器的有效钥匙和钉住的不同：显示 T46（§11.3 第 6 步）
    }

    /// 只用钉住的公钥（等于本机私钥算出的），不用服务器 keys 里给的
    static func sendKey(pushkey: String, state: State?, pinned: String?) -> SendKey {
        guard let st = state, st.enabled else { return .hidden }
        guard let pin = pinned, pin.count == 43 else { return .needsUnlock }
        guard st.activeKey?.pub == pin else { return .mismatch }
        return .key("\(pushkey).e2e.\(pin)")
    }

    // MARK: - 后台计算

    private static let kdfLock = NSLock()

    /// 在后台线程执行（Argon2id 约 0.1–0.4 秒、占 64 MiB，不能在主线程算）
    static func background<R>(_ work: @escaping () throws -> R) async throws -> R {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try work() })
            }
        }
    }

    /// Argon2id：同一时间只算一个（每次占 64 MiB）
    static func passwordKeys(_ password: String, salt: String) async throws -> (authKey: String, unlockKey: String) {
        try await background {
            kdfLock.lock()
            defer { kdfLock.unlock() }
            return try coreCall { try Core.passwordKeys(password, saltHex: salt) }
        }
    }

    /// 核心库错误转成 Failure（weak_params → T2）
    static func coreCall<R>(_ f: () throws -> R) throws -> R {
        do { return try f() } catch let e as Core.Failure {
            if e.code == "weak_params" { throw Failure(.weakParams, T.t2) }
            throw Failure(.core, e.message)
        }
    }

    // MARK: - 登录凭证（§2.1、§2.4）

    /// Argon2id 参数写死（服务端给的不一致就拒绝）
    static let argonTime = 3, argonMemoryKiB = 65536, argonLanes = 1

    /// 派生好的密码凭证
    struct Credential {
        enum Kind { case auth, pbkdf2, plain }
        let kind: Kind
        /// auth_key / password_key / 密码原文（只在服务端没有新登录协议、账号也从未升级时）
        let value: String
        /// Argon2id 才有：解锁钥匙，只在内存里用完即弃
        let unlockKey: String?
        /// Argon2id 才有：prelogin 给的盐（自动开启加密要用，省掉第二次 prelogin）
        var salt: String? = nil

        /// 登录 / 注册请求里的字段
        var loginFields: [String: Any] {
            switch kind {
            case .auth: return ["auth_key": value]
            case .pbkdf2: return ["password_key": value]
            case .plain: return ["password": value]
            }
        }

        /// 核对当前密码的字段（改密码、开启加密、换恢复码……）
        var currentFields: [String: Any] {
            switch kind {
            case .auth: return ["current_auth_key": value]
            case .pbkdf2: return ["current_password_key": value]
            case .plain: return ["current_password": value]
            }
        }
    }

    static func isHex(_ s: String) -> Bool { !s.isEmpty && s.count % 2 == 0 && s.allSatisfy(\.isHexDigit) }

    /// 核对 Argon2id 参数：3 轮、64 MiB、1 线程，盐至少 16 字节
    static func checkArgon(_ p: Prelogin) throws {
        guard p.time == argonTime, p.memory_kib == argonMemoryKiB, p.lanes == argonLanes,
              p.salt.count >= 32, isHex(p.salt) else { throw Failure(.weakParams, T.t2) }
    }

    /// 按 prelogin 的结果在本机派生凭证。upgraded：本机记得这个账号已升级，再收到 pbkdf2 就拒绝（T1）
    static func derive(password: String, prelogin p: Prelogin, upgraded: Bool) async throws -> Credential {
        switch p.kdf {
        case "argon2id":
            try checkArgon(p)
            let k = try await passwordKeys(password, salt: p.salt)
            return Credential(kind: .auth, value: k.authKey, unlockKey: k.unlockKey, salt: p.salt)
        case "pbkdf2-sha256":
            if upgraded { throw Failure(.downgrade, T.t1) }
            guard let n = p.iterations, isHex(p.salt) else { throw Failure(.weakParams, T.t2) }
            let v = try await background { try coreCall { try Core.pbkdf2(password, saltHex: p.salt, iterations: n) } }
            return Credential(kind: .pbkdf2, value: v, unlockKey: nil)
        default:
            throw Failure(.weakParams, T.t2)
        }
    }

    /// 上次注册结果不确定（Failure.uncertain），这次同一个用户名再注册又被拒（409 用户名已被使用、403 邀请码已用完等）：
    /// 多半上次已经成功，提示改去登录（T.registerTryLogin）；其他错误返回 nil，照常显示
    static func registerAfterUncertain(_ error: Error) -> String? {
        guard let f = error as? Failure, f.status == 409 || f.status == 403 else { return nil }
        var m = f.message
        while m.hasSuffix("。") || m.hasSuffix(".") { m.removeLast() }
        return m + "。" + T.registerTryLogin
    }

    /// GET /v1/info 的功能清单里有没有这个功能。没有 /v1/info 的旧服务端算没有；
    /// 取不到（网络出错、超时、响应不对）时不猜，抛 T.serverUnreachable（三端一致：不能把新服务端当成旧的）
    static func supports(_ api: API, feature: String) async throws -> Bool {
        struct Info: Decodable { struct F: Decodable { let id: String }; let features: [F] }
        do {
            return try await api.get(Info.self, "/v1/info").features.contains { $0.id == feature }
        } catch let f as Failure where f.kind == .unsupported {
            return false
        } catch {
            throw Failure(.server, T.serverUnreachable)
        }
    }

    /// GET /v1/prelogin；nil = 服务端没有新登录协议（旧服务端，纯文本 404）
    static func prelogin(_ api: API, username: String) async throws -> Prelogin? {
        do {
            return try await api.get(Prelogin.self, "/v1/prelogin", query: [URLQueryItem(name: "username", value: username)])
        } catch let f as Failure where f.kind == .unsupported {
            return nil
        }
    }

    /// §2.4「当前密码」凭证。
    /// - allowPlain：prelogin 返回纯文本 404（服务端没有新登录协议）、账号也没有「已升级」标记时，可以按旧接口发原文。
    ///   只有改用户名 / 改密码可以这样；开启加密、更换恢复码、重新设置密码、用密码解锁一定是新服务端，404 直接报错。
    /// - allowLegacy：只用于「重新设置密码」页（§4.4.4）：允许 pbkdf2，即使本机标记了已升级——那时的当前密码是管理员用原文设的
    static func currentCredential(_ api: API, server: String, username: String, password: String, marks: UpgradeMarks,
                                  allowPlain: Bool = false, allowLegacy: Bool = false) async throws -> Credential {
        let upgraded = marks.isUpgraded(server: server, username: username)
        guard let p = try await prelogin(api, username: username) else {
            if upgraded { throw Failure(.downgrade, T.t1) }
            guard allowPlain else { throw Failure(.unsupported, T.noPrelogin) }
            return Credential(kind: .plain, value: password, unlockKey: nil)
        }
        return try await derive(password: password, prelogin: p, upgraded: upgraded && !allowLegacy)
    }

    /// 设置初始密码前（只能以原文设置）：本机记得这个用户名已升级过，服务器却说账号没有密码 → 拒绝（T1）
    static func checkInitialPassword(server: String, username: String, marks: UpgradeMarks) throws {
        if marks.isUpgraded(server: server, username: username) { throw Failure(.downgrade, T.t1) }
    }

    /// 核对当前密码的接口返回 403 → T3
    static func mapCurrent(_ e: Error) -> Error {
        if let f = e as? Failure, f.kind == .server, f.status == 403 { return Failure(.wrongPassword, T.t3, status: 403) }
        return e
    }

    // MARK: - 登录、注册、自动升级（§2）

    struct Device {
        var name: String
        var platform: String
        var fingerprint: String
    }

    /// 用当前密码按 Argon2id 算出的一组钥匙（只在内存里）：自动开启加密（§11.1）时直接复用，不用再算、也不用留着密码原文。
    /// weak：这个密码没通过 Core.passwordProblem（照样开启，加密页显示 T24）
    struct PasswordKeys: Equatable {
        let salt: String
        let authKey: String
        let unlockKey: String
        var weak = false
    }

    struct LoginResult {
        /// /v1/login 或 /v1/register 的原始响应（各端自己解码 device_id、name、token、reused）
        let response: Data
        let token: String
        /// 账号 id（登录后 GET /v1/me 取得；失败时 nil，钥匙要等之后再存）
        let accountID: Int64?
        /// 登录后本机已经拿到私钥
        var unlocked = false
        /// 这次登录把账号升级到了新登录协议
        var upgradedNow = false
        /// 给用户的一句说明（例如私钥对不上 T43）；nil = 不用提示
        var note: String?
        /// 已解开并核对过、但还没取到账号 id 没法保存的私钥（只在内存里）：拿到账号 id 后用 acceptOwnKey 保存（来自密码，可以替换钉住的公钥）
        var pendingKey: (sk: String, keys: [Key])?
        /// 这次用密码算出的钥匙（Argon2id；旧服务端原文登录时 nil）：账号还没开启加密时，调用方拿它在后台自动开启（§11.1）
        var passwordKeys: PasswordKeys?
    }

    /// 账号密码登录 / 注册（§2.1、§2.2）。server：没有 token 的传输；authed：用新 token 创建传输（取账号 id、自动升级用）。
    /// 解锁得到的私钥核对后存进 secrets（需要账号 id）。
    /// alive：保存钥匙用的「账号还活着」标记（调用方的 KeyRing 用同一个；期间退出登录 / 换账号时不再写入，审查 L3）
    /// inviteCode：注册时的邀请码（服务端 0.9.0 起 /v1/info 的 register 为 "invite" 时必填；邀请码不对时服务端 403，说明原样显示）
    static func login(server: E2ETransport, authed: (String) -> E2ETransport, serverID: String,
                      username: String, password: String, device: Device, register: Bool,
                      marks: UpgradeMarks, secrets: E2ESecrets, inviteCode: String? = nil,
                      alive: AliveFlag = AliveFlag()) async throws -> LoginResult {
        let api = API(server)
        let upgraded = marks.isUpgraded(server: serverID, username: username)
        var body: [String: Any] = ["username": username, "name": device.name, "platform": device.platform, "fingerprint": device.fingerprint]
        if register, let c = inviteCode?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { body["invite_code"] = c }
        let p = try await prelogin(api, username: username)

        var registerUnlock: String?
        /// 注册即开启加密（服务端 0.9.0，功能 register.e2e）：本机生成的账号钥匙，随注册一起提交
        var registerKey: (sk: String, pub: String)?
        if register {
            if let problem = Core.passwordProblem(password, username: username) { throw Failure(.weakPassword, problem) }
            if p == nil {
                // 注册一律不发密码原文（三端一致）：没有新登录协议的旧服务端不能注册
                throw Failure(.unsupported, T.registerServerTooOld)
            } else {
                let salt = try coreCall { try Core.newSalt() }
                let k = try await passwordKeys(password, salt: salt)
                body["auth_key"] = k.authKey
                body["auth_salt"] = salt
                registerUnlock = k.unlockKey
                // 格式同 POST /v1/e2e/setup（pub + 用解锁钥匙锁住的私钥）；不生成恢复码（注册后再建议设置，§11.2）。
                // 0.8 及以前的服务端没有这个功能：照旧只注册，之后由调用方用 passwordKeys 自动开启（§11.1）
                if try await supports(api, feature: "register.e2e") {
                    let kp = try coreCall { try Core.keypair() }
                    body["pub"] = kp.pub
                    body["password_wrap"] = try coreCall { try Core.wrap("hjp1", key: k.unlockKey, data: kp.sk) }
                    registerKey = (kp.sk, kp.pub)
                }
            }
            let data: Data
            do {
                data = try await api.call("POST", "/v1/register", body: body)
            } catch let f as Failure where f.status == 500 || (400...499).contains(f.status) {
                throw f                                   // 服务端明确拒绝或明确失败（同一事务，不留数据）
            } catch {
                // 网络出错、超时、网关 5xx：服务端可能已经建号
                throw Failure(.uncertain, T.registerUncertain, status: (error as? Failure)?.status ?? 0)
            }
            if p != nil { marks.mark(server: serverID, username: username) }
            // 拿到 200 以后：账号已经建好（邀请码已扣），之后的失败都按「结果不确定」处理，提示先去登录
            guard let token = try? tokenOf(data) else { throw Failure(.uncertain, T.registerUncertain) }
            let authedAPI = API(authed(token))
            var aid = await accountID(authedAPI)
            for _ in 0..<2 where aid == nil && registerKey != nil {
                try? await Task.sleep(nanoseconds: 500_000_000)
                aid = await accountID(authedAPI)
            }
            var out = LoginResult(response: data, token: token, accountID: aid, upgradedNow: p != nil)
            if let salt = body["auth_salt"] as? String, let auth = body["auth_key"] as? String, let unlock = registerUnlock {
                out.passwordKeys = PasswordKeys(salt: salt, authKey: auth, unlockKey: unlock)
            }
            // 注册即开启：响应里的 e2e 有这把公钥 → 本机生成的钥匙，保存并钉住（§11.4 本机生成，可以替换钉住的）。
            // 响应里没有 e2e（不该发生）：当作没开启，调用方照旧自动开启
            struct Wrap: Decodable { let e2e: LoginInfo? }
            if let kp = registerKey, let info = (try? JSONDecoder().decode(Wrap.self, from: data))?.e2e, info.enabled {
                do {
                    if let aid {
                        try acceptOwnKey(kp.sk, keys: info.keys, ring: KeyRing(secrets: secrets, scope: scope(server: serverID, accountID: aid),
                                                                              defaults: marks.defaults, alive: alive))
                        out.unlocked = true
                    } else {
                        // 取不到账号 id：先核对，留在内存里，之后再保存（同登录）
                        try verify(sk: kp.sk, keys: info.keys, pinned: nil)
                        out.pendingKey = (kp.sk, info.keys)
                    }
                } catch let f as Failure where f.kind == .keyMismatch || f.kind == .storage {
                    out.note = f.message      // 私钥已用密码锁在服务器上：之后用密码解锁照样能取回
                } catch {}
            }
            return out
        }

        let cred: Credential
        if let p {
            cred = try await derive(password: password, prelogin: p, upgraded: upgraded)
        } else {
            if upgraded { throw Failure(.downgrade, T.t1) }
            cred = Credential(kind: .plain, value: password, unlockKey: nil)
        }
        body.merge(cred.loginFields) { _, b in b }
        let data = try await api.call("POST", "/v1/login", body: body)
        let token = try tokenOf(data)
        let authedAPI = API(authed(token))
        var aid = await accountID(authedAPI)
        for _ in 0..<2 where aid == nil && cred.kind == .auth {
            try? await Task.sleep(nanoseconds: 500_000_000)
            aid = await accountID(authedAPI)
        }
        var out = LoginResult(response: data, token: token, accountID: aid)

        switch cred.kind {
        case .auth:
            marks.mark(server: serverID, username: username)
            if let unlock = cred.unlockKey, let p {
                out.passwordKeys = PasswordKeys(salt: p.salt, authKey: cred.value, unlockKey: unlock,
                                                weak: Core.passwordProblem(password, username: username) != nil)
            }
            // 响应里带了用密码锁住的私钥：解开、核对后保存；失败（例如管理员重设过密码）进入「已锁定」，不阻止登录
            struct Wrap: Decodable { let e2e: LoginInfo? }
            if let info = (try? JSONDecoder().decode(Wrap.self, from: data))?.e2e, info.enabled, !info.password_wrap.isEmpty,
               let unlock = cred.unlockKey {
                do {
                    let sk = try coreCall { try Core.unwrap("hjp1", key: unlock, wrap: info.password_wrap) }
                    if let aid {
                        // 用密码解开的：服务器伪造不了（hjp1 用只有本机知道的 unlock_key 锁住），可以替换钉住的公钥（§11.4）
                        try acceptOwnKey(sk, keys: info.keys, ring: KeyRing(secrets: secrets, scope: scope(server: serverID, accountID: aid),
                                                                             defaults: marks.defaults, alive: alive))
                        out.unlocked = true
                    } else {
                        // 取不到账号 id：先核对（还不知道钉住的公钥，保存时再核对一次），留在内存里，之后再保存
                        try verify(sk: sk, keys: info.keys, pinned: nil)
                        out.pendingKey = (sk, info.keys)
                    }
                } catch let f as Failure where f.kind == .keyMismatch || f.kind == .storage {
                    out.note = f.message
                } catch {}
            }
        case .pbkdf2:
            // §2.1.7：旧账号用 PBKDF2 登录成功后立即升级；失败不影响登录，下次再试
            if var k = await autoUpgrade(authedAPI, passwordKey: cred.value, password: password, server: serverID, username: username, marks: marks) {
                out.upgradedNow = true
                k.weak = Core.passwordProblem(password, username: username) != nil
                out.passwordKeys = k
            }
        case .plain:
            break
        }
        return out
    }

    // MARK: - 配对码带钥匙（§12）

    /// 生成配对码时要锁进去的私钥：本机有账号 active 钥匙的私钥才带（§12.2）；没有（没解锁、钥匙已更换）返回 nil
    static func activeSecretKey(_ keys: [String], state: State?) -> String? {
        guard let st = state, st.enabled, let active = st.activeKey else { return nil }
        return keys.first { (try? Core.publicKey($0).pub) == active.pub }
    }

    /// 生成配对码（§12.2）：sk 不为 nil 且服务端支持 pair.key 时带钥匙。返回 6 位配对码、有效秒数、一次性钥匙（不带钥匙时 nil）
    static func createPairCode(_ api: API, sk: String?, supportsKey: Bool) async throws -> (code: String, expiresIn: Int, secret: String?) {
        struct R: Decodable { let code: String; let expires_in: Int? }
        var secret: String?
        var body: [String: Any]?
        if let sk, supportsKey {
            let k = try coreCall { try Core.pairKeyNew(sk: sk) }
            secret = k.secret
            body = ["key_wrap": k.wrap]
        }
        let data = try await api.call("POST", "/v1/pair-codes", body: body)
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { throw Failure(.server, "配对码响应格式不对") }
        return (r.code, r.expires_in ?? 180, secret)
    }

    /// 配对码登录（§2.3、§12.3）。secret：用户输入的长配对码 / 链接里的一次性钥匙（只输 6 位时 nil），不发给服务器。
    /// 带钥匙时解开服务器交来的 key_wrap，核对后保存（来自配对码钥匙，服务器伪造不了，可以替换钉住的公钥，§12.3 第 4 步）；
    /// 解不开、没带钥匙时登录照常成功，note 给出说明（T82 / T83），进入「已锁定」
    static func pair(server: E2ETransport, authed: (String) -> E2ETransport, serverID: String, code: String, secret: String?,
                     device: Device, marks: UpgradeMarks, secrets: E2ESecrets, alive: AliveFlag = AliveFlag()) async throws -> LoginResult {
        let api = API(server)
        let data = try await api.call("POST", "/v1/pair", body: ["code": code, "name": device.name, "platform": device.platform,
                                                                 "fingerprint": device.fingerprint])
        let token = try tokenOf(data)
        let authedAPI = API(authed(token))
        var aid = await accountID(authedAPI)
        for _ in 0..<2 where aid == nil && secret != nil {
            try? await Task.sleep(nanoseconds: 500_000_000)
            aid = await accountID(authedAPI)
        }
        var out = LoginResult(response: data, token: token, accountID: aid)
        guard let secret else { return out }
        struct W: Decodable { let key_wrap: String? }
        guard let wrap = (try? JSONDecoder().decode(W.self, from: data))?.key_wrap, !wrap.isEmpty else {
            out.note = T.t83
            return out
        }
        let sk: String
        do { sk = try coreCall { try Core.pairKeyOpen(secret: secret, wrap: wrap) } } catch { out.note = T.t82; return out }
        var st: State?
        for i in 0..<3 where st == nil {
            if i > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
            st = try? await authedAPI.state()
        }
        guard let st else { out.note = "暂时取不到账号的加密状态，加密消息还没解锁：请输入密码解锁。"; return out }
        do {
            if let aid {
                try acceptOwnKey(sk, keys: st.keys, ring: KeyRing(secrets: secrets, scope: scope(server: serverID, accountID: aid),
                                                                  defaults: marks.defaults, alive: alive))
                out.unlocked = true
            } else {
                try verify(sk: sk, keys: st.keys, pinned: nil)
                out.pendingKey = (sk, st.keys)
            }
        } catch let f as Failure where f.kind == .keyMismatch || f.kind == .storage {
            out.note = f.message
        } catch {}
        return out
    }

    /// 旧账号（PBKDF2）升级到 Argon2id：先看加密是否已开启（已开启说明管理员重设过密码，旧副本失效，等解锁后在「重新设置密码」里完成），
    /// 否则 PUT /v1/account/auth。成功时返回新的一组钥匙（自动开启加密时复用），失败 nil
    @discardableResult
    static func autoUpgrade(_ api: API, passwordKey: String, password: String, server: String, username: String,
                            marks: UpgradeMarks) async -> PasswordKeys? {
        guard let st = try? await api.state(), !st.enabled else { return nil }
        do {
            let salt = try coreCall { try Core.newSalt() }
            let k = try await passwordKeys(password, salt: salt)
            try await api.call("PUT", "/v1/account/auth", body: ["current_password_key": passwordKey, "auth_salt": salt, "auth_key": k.authKey])
            marks.mark(server: server, username: username)
            return PasswordKeys(salt: salt, authKey: k.authKey, unlockKey: k.unlockKey)
        } catch {
            return nil
        }
    }

    /// T67 提示条（§11.1 末尾）：已经登录、内存里没有密码的设备，用户输入一次当前密码，算出自动开启要用的那组钥匙。
    /// argon2id：按 prelogin 的盐重算（之后 setup 会核对当前凭证，密码不对返回 403 → T3）；
    /// pbkdf2（还没升级的旧账号）：顺带升级到 Argon2id（PUT /v1/account/auth 会核对当前密码）。没有新登录协议的服务端报错。
    /// 返回的钥匙只在调用方的局部变量里用一次，不要存起来
    static func keysForPassword(_ api: API, server: String, username: String, password: String, marks: UpgradeMarks) async throws -> PasswordKeys {
        let cred = try await currentCredential(api, server: server, username: username, password: password, marks: marks)
        let weak = Core.passwordProblem(password, username: username) != nil
        switch cred.kind {
        case .auth:
            // currentCredential 已经请求过 prelogin，盐就用那一次的（prelogin 按 IP 限流，不重复请求）
            guard let salt = cred.salt, let unlock = cred.unlockKey else { throw Failure(.unsupported, T.noPrelogin) }
            return PasswordKeys(salt: salt, authKey: cred.value, unlockKey: unlock, weak: weak)
        case .pbkdf2:
            let salt = try coreCall { try Core.newSalt() }
            let k = try await passwordKeys(password, salt: salt)
            do {
                try await api.call("PUT", "/v1/account/auth", body: ["current_password_key": cred.value, "auth_salt": salt, "auth_key": k.authKey])
            } catch { throw mapCurrent(error) }
            marks.mark(server: server, username: username)
            return PasswordKeys(salt: salt, authKey: k.authKey, unlockKey: k.unlockKey, weak: weak)
        case .plain:
            throw Failure(.unsupported, T.noPrelogin)
        }
    }

    /// 刚设置了初始密码（只能以原文设置，服务端没有别的接口）：马上按 PBKDF2 → Argon2id 升级。
    /// 成功时返回这组钥匙（weak 已按密码强度填好），调用方拿它自动开启加密（§11.1）
    @discardableResult
    static func upgradeAfterInitialPassword(_ api: API, server: String, username: String, password: String, marks: UpgradeMarks) async -> PasswordKeys? {
        guard let p = try? await prelogin(api, username: username), p.kdf == "pbkdf2-sha256",
              let cred = try? await derive(password: password, prelogin: p, upgraded: false) else { return nil }
        guard var k = await autoUpgrade(api, passwordKey: cred.value, password: password, server: server, username: username, marks: marks) else {
            return nil
        }
        k.weak = Core.passwordProblem(password, username: username) != nil
        return k
    }

    private static func tokenOf(_ data: Data) throws -> String {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = o["token"] as? String, !t.isEmpty else {
            throw Failure(.server, "登录响应格式不对")
        }
        return t
    }

    /// GET /v1/me 的账号 id
    static func accountID(_ api: API) async -> Int64? {
        struct Me: Decodable { struct A: Decodable { let id: Int64 }; let account: A? }
        return (try? await api.get(Me.self, "/v1/me"))?.account?.id
    }

    static func saveKey(_ sk: String, ring: KeyRing) throws {
        do { try ring.addAccountKey(sk) } catch { throw Failure(.storage, "保存加密钥匙失败：\(error.localizedDescription)") }
    }

    // MARK: - 开启加密（§4.1）

    /// 一次开启加密：新钥匙对和恢复码。从生成起存在 KeyRing.pendingSetup，用户在「保存恢复码」页点「完成」才删除。
    /// 自动开启（§11.1）和重置加密（§11.3）不生成恢复码：code 为空，确认成功后直接删除，不显示恢复码页
    struct SetupAttempt: Codable, Equatable {
        let sk: String
        let pub: String
        let code: String
        /// 重置加密（§11.3）留下的：服务器上原来的钥匙仍然有效时不能断定失败（核对规则见 checkPendingSetup）。旧记录没有这个字段 = nil
        var reset: Bool? = nil
        /// 生成时间（Unix 秒）。旧记录没有 = nil：从第一次读到时开始算（见 checkPendingSetup）
        var createdAt: Double? = nil
        var isReset: Bool { reset == true }
    }

    /// 重置加密结果不确定的记录最多保留多久：超过就按失败处理（私钥留着，记录删除）
    static let resetPendingTTL: TimeInterval = 24 * 3600

    /// 用户点了「放弃这次重置」（§11.3 结果不确定时）：删除记录，新私钥留在本机（万一其实重置成功了，这段时间的消息还能解开）。
    /// 只处理重置留下的记录；返回是否删除了
    @discardableResult
    static func abandonReset(ring: KeyRing) -> Bool {
        guard let a = try? ring.pendingSetup(), a.isReset else { return false }
        try? ring.addAccountKey(a.sk)
        try? ring.deletePendingSetup()
        return true
    }

    /// 开启加密的结果暂时无法确认：attempt 已存在 KeyRing.pendingSetup，之后每次刷新状态由 checkPendingSetup 核对
    struct SetupPending: LocalizedError {
        let attempt: SetupAttempt
        /// 重置加密（§11.3）的结果不确定
        var reset = false
        var errorDescription: String? { reset ? T.resetUncertain : T.setupUncertain }
    }

    /// 核对进行中的开启（§4.1）的结果
    enum SetupCheck: Equatable {
        case none                       // 没有进行中的开启
        case resetPending(SetupAttempt) // 进行中的重置：服务器还是原来的钥匙，还不能断定成败，保留
        case completed(SetupAttempt)    // 服务端已经用这把钥匙开启：私钥已保存、公钥已钉住、已标记升级 → code 不为空时显示恢复码页
        case notEnabled(SetupAttempt)   // 服务端还没开启：保留，提示用户重试（T.setupNotDone）
        case discarded                  // 服务端用的是别的钥匙（或本机钉住的不是这把）：已删除
    }

    /// 有进行中的开启时，每次拿到 GET /v1/e2e 都调用（§4.1）。username 为空时不写「已升级」标记
    @discardableResult
    static func checkPendingSetup(_ st: State, ring: KeyRing, server: String, username: String, marks: UpgradeMarks, now: Date = Date()) throws -> SetupCheck {
        guard let a = try ring.pendingSetup() else { return .none }
        guard st.enabled else { return .notEnabled(a) }
        guard st.activeKey?.pub == a.pub else {
            if a.isReset {
                // 重置：服务器上原来的钥匙仍然有效不说明失败（请求可能还在处理），保留，确定了再删。
                // 这把钥匙出现在停用列表里 = 重置生效过、之后又被别处重置：私钥留着看那段时间的消息，记录删除
                if let k = st.keys.first(where: { $0.pub == a.pub }), !k.active {
                    try? ring.addAccountKey(a.sk)
                    try? ring.deletePendingSetup()
                    return .discarded
                }
                // 24 小时还没确认 = 重置没有成功：按放弃处理（私钥留着）。旧记录没有时间：补上现在，从现在开始算
                guard let created = a.createdAt else {
                    var b = a
                    b.createdAt = now.timeIntervalSince1970
                    try? ring.savePendingSetup(b)
                    return .resetPending(b)
                }
                if now.timeIntervalSince1970 - created >= resetPendingTTL {
                    abandonReset(ring: ring)
                    return .discarded
                }
                return .resetPending(a)
            }
            try? ring.removeAccountKey(a.sk)
            try? ring.deletePendingSetup()
            return .discarded
        }
        do {
            // 本机生成的钥匙：可以替换钉住的公钥（§11.4；重置加密后钉住的还是旧公钥）
            try acceptOwnKey(a.sk, keys: st.keys, ring: ring)
        } catch let f as Failure where f.kind == .keyMismatch {
            try? ring.deletePendingSetup()
            return .discarded
        }
        if !username.isEmpty { marks.mark(server: server, username: username) }
        // 没有恢复码（自动开启、重置加密）：不用等用户点「完成」
        if a.code.isEmpty { try? ring.deletePendingSetup() }
        return .completed(a)
    }

    /// 已经确认开启、用户还没在「保存恢复码」页点「完成」的那次开启（私钥已经存进钥匙串就说明确认过）。
    /// App 启动、读钥匙时调用：不为 nil 就直接回到恢复码页，不用等联网
    static func confirmedSetup(ring: KeyRing) -> SetupAttempt? {
        guard let a = try? ring.pendingSetup(), !a.code.isEmpty, ((try? ring.accountKeys()) ?? []).contains(a.sk) else { return nil }
        return a
    }

    /// 用户在「保存恢复码」页点了「完成」。这一页只在确认开启后显示：私钥万一当时没存进钥匙串就补存、补钉，
    /// 存好了才删除进行中的开启（没存好就留着，下次刷新状态 checkPendingSetup 再处理）
    static func finishRecovery(ring: KeyRing) {
        guard let a = try? ring.pendingSetup() else { return }
        if !((try? ring.accountKeys()) ?? []).contains(a.sk) { try? ring.addAccountKey(a.sk) }
        guard ((try? ring.accountKeys()) ?? []).contains(a.sk) else { return }
        ring.pinIfNeeded(a.pub)
        try? ring.deletePendingSetup()
    }

    /// §4.5 末尾：本机存着私钥、却没有钉住的公钥（例如重装后偏好设置清空了）时，用核对通过的私钥补钉。返回补钉的公钥
    @discardableResult
    static func repinIfNeeded(_ st: State, ring: KeyRing, localKeys: [String]) -> String? {
        guard ring.pinned == nil else { return nil }
        for sk in localKeys {
            if let pub = try? verify(sk: sk, keys: st.keys, pinned: nil) {
                ring.pinIfNeeded(pub)
                return pub
            }
        }
        return nil
    }

    /// 开启端到端加密，返回恢复码。newPassword 不为 nil 时同时换成新密码。
    /// 调用前界面已检查密码强度；这里再检查一次实际使用的密码。
    /// 新钥匙对和恢复码在提交前存进 ring.pendingSetup（§4.1），成功后也不删，用户在「保存恢复码」页点「完成」时调用方删除。
    /// 网络出错或 5xx 时先重新 GET /v1/e2e 核对（§4.1 第 4 步）；仍无法确认时抛 SetupPending（之后每次刷新状态会自动核对）
    static func setup(_ api: API, ring: KeyRing, server: String, username: String, currentPassword: String, newPassword: String?,
                      marks: UpgradeMarks) async throws -> String {
        // 上次的开启还没确认：先核对结果
        if let p = try? ring.pendingSetup() {
            let st: State
            do { st = try await api.state() } catch { throw SetupPending(attempt: p) }
            switch try checkPendingSetup(st, ring: ring, server: server, username: username, marks: marks) {
            case .completed(let a): return a.code
            case .notEnabled: try? ring.deletePendingSetup()      // 上次其实没开启：丢掉，重新生成
            case .discarded, .resetPending: throw Failure(.conflict, "别的设备刚开启了加密，已重新读取状态")
            case .none: break
            }
        }
        let actual = newPassword ?? currentPassword
        if let problem = Core.passwordProblem(actual, username: username) {
            throw Failure(.weakPassword, newPassword == nil ? T.weakCurrent : problem)
        }
        let cur = try await currentCredential(api, server: server, username: username, password: currentPassword, marks: marks)
        let kp = try coreCall { try Core.keypair() }
        let salt = try coreCall { try Core.newSalt() }
        let k = try await passwordKeys(actual, salt: salt)
        let (passwordWrap, recovery, recoveryWrap) = try coreCall { () -> (String, (code: String, key: String), String) in
            let pw = try Core.wrap("hjp1", key: k.unlockKey, data: kp.sk)
            let r = try Core.recoveryNew()
            return (pw, r, try Core.wrap("hjr1", key: r.key, data: kp.sk))
        }
        // 先存新钥匙对和恢复码再提交：存不进钥匙串就不开启（否则账号开启了、本机却没有钥匙，恢复码也可能丢）
        let attempt = SetupAttempt(sk: kp.sk, pub: kp.pub, code: recovery.code)
        do { try ring.savePendingSetup(attempt) } catch { throw Failure(.storage, "保存加密钥匙失败：\(error.localizedDescription)") }
        var body = cur.currentFields
        body["pub"] = kp.pub
        body["auth_salt"] = salt
        body["auth_key"] = k.authKey
        body["password_wrap"] = passwordWrap
        body["recovery_wrap"] = recoveryWrap
        do {
            try await api.call("POST", "/v1/e2e/setup", body: body)
        } catch {
            if let f = error as? Failure, (400...499).contains(f.status) {
                // 服务端明确拒绝（403 密码不对、409 已开启……）：丢掉这次的钥匙
                try? ring.deletePendingSetup()
                throw mapCurrent(error)
            }
            // 网络出错或 5xx：服务端可能其实已经开启了，先看结果
            guard let st = try? await api.state() else { throw SetupPending(attempt: attempt) }
            switch try checkPendingSetup(st, ring: ring, server: server, username: username, marks: marks) {
            case .completed(let a): return a.code
            case .discarded, .resetPending: throw Failure(.conflict, "别的设备刚开启了加密，已重新读取状态")
            case .notEnabled, .none: throw error            // 没开启：钥匙留着，下次点「开启」会先核对再重新生成
            }
        }
        // 第 5 步：保存私钥（我们自己生成、服务端刚接受的公钥）、钉住、标记升级。
        // 保存失败也照样返回恢复码：pendingSetup 还在，下次刷新状态时 checkPendingSetup 会再保存
        try? saveKey(kp.sk, ring: ring)
        ring.replacePin(kp.pub)
        marks.mark(server: server, username: username)
        return recovery.code
    }

    // MARK: - 自动开启（§11.1）、重置加密（§11.3）

    enum AutoSetupResult: Equatable {
        case enabled            // 这次开启成功（或核对出上次其实已经开启）
        case unlocked           // 别的设备刚开启过（409）：改为用这个密码解锁
        case alreadyEnabled     // 账号早已开启，本机已解锁
        case manualPending      // 有用户手动开启留下、还没核对出结果的记录（带恢复码）：不自动开启，交给 checkPendingSetup 和用户
    }

    /// 自动开启加密（§11.1）：注册、账号密码登录、设置初始密码之后，账号还没开启时在后台调用。
    /// 复用这次登录算出的钥匙（auth_salt、auth_key 不变），不生成恢复码。密码弱也照样开启（keys.weak → 加密页显示 T24）。
    /// 进行中的开启照样先存进钥匙串，结果不确定时抛 SetupPending（之后刷新时 checkPendingSetup 核对，或下次再调用）
    static func autoSetup(_ api: API, ring: KeyRing, server: String, username: String, keys: PasswordKeys,
                          marks: UpgradeMarks) async throws -> AutoSetupResult {
        let st = try await api.state()
        if st.enabled {
            if case .completed = try checkPendingSetup(st, ring: ring, server: server, username: username, marks: marks) { return .enabled }
            if usableKey(st, localKeys: (try? ring.accountKeys()) ?? []) != nil { return .alreadyEnabled }
            try await unlock(api, ring: ring, authKey: keys.authKey, unlockKey: keys.unlockKey)
            return .unlocked
        }
        if let p = try? ring.pendingSetup() {
            // 用户手动开启留下的（带恢复码）：不能删——那次可能晚到生效、也可能同时换了密码
            if !p.code.isEmpty { return .manualPending }
            // 自己上次留下、服务端确实没开启：作废，重新生成
            try? ring.deletePendingSetup()
        }
        let kp = try coreCall { try Core.keypair() }
        let wrap = try coreCall { try Core.wrap("hjp1", key: keys.unlockKey, data: kp.sk) }
        let attempt = SetupAttempt(sk: kp.sk, pub: kp.pub, code: "")
        do { try ring.savePendingSetup(attempt) } catch { throw Failure(.storage, "保存加密钥匙失败：\(error.localizedDescription)") }
        let body: [String: Any] = ["current_auth_key": keys.authKey, "pub": kp.pub, "auth_salt": keys.salt, "auth_key": keys.authKey,
                                   "password_wrap": wrap]
        do {
            try await api.call("POST", "/v1/e2e/setup", body: body)
        } catch {
            if let f = error as? Failure, f.status == 409 {
                // 别的设备刚开启过：用这个密码解锁（§11.1 第 4 步）
                try? ring.deletePendingSetup()
                try await unlock(api, ring: ring, authKey: keys.authKey, unlockKey: keys.unlockKey)
                return .unlocked
            }
            if let f = error as? Failure, (400...499).contains(f.status) {
                try? ring.deletePendingSetup()
                throw mapCurrent(error)
            }
            guard let st2 = try? await api.state() else { throw SetupPending(attempt: attempt) }
            switch try checkPendingSetup(st2, ring: ring, server: server, username: username, marks: marks) {
            case .completed: return .enabled
            case .discarded, .resetPending:
                try await unlock(api, ring: ring, authKey: keys.authKey, unlockKey: keys.unlockKey)
                return .unlocked
            case .notEnabled, .none: throw error
            }
        }
        try? saveKey(kp.sk, ring: ring)
        ring.replacePin(kp.pub)
        marks.mark(server: server, username: username)
        try? ring.deletePendingSetup()
        return .enabled
    }

    /// 重置加密（§11.3）：换一把新钥匙。旧钥匙在服务端停用保留，本机的旧私钥也保留（解旧消息用）；新公钥替换钉住的。
    /// 需要当前密码（管理员重设密码后账号回到旧登录方式时也能用，同 §4.4 第 4 步）。不换密码、不生成恢复码。
    /// 新钥匙对先存进 pendingSetup：结果不确定时抛 SetupPending(reset: true)，之后刷新时 checkPendingSetup 核对
    static func resetE2E(_ api: API, ring: KeyRing, server: String, username: String, password: String, marks: UpgradeMarks) async throws {
        // 上次的重置结果不确定：先看是不是其实已经生效了
        if let p = try? ring.pendingSetup(), p.isReset, let st = try? await api.state(),
           case .completed = try checkPendingSetup(st, ring: ring, server: server, username: username, marks: marks) {
            return
        }
        let cur = try await currentCredential(api, server: server, username: username, password: password, marks: marks, allowLegacy: true)
        // 上次的重置还没有结果：这次的记录会覆盖它，先按放弃处理（那把私钥留着，万一上次其实生效了还能解开那段时间的消息）
        abandonReset(ring: ring)
        let kp = try coreCall { try Core.keypair() }
        let salt = try coreCall { try Core.newSalt() }
        let k = try await passwordKeys(password, salt: salt)
        let wrap = try coreCall { try Core.wrap("hjp1", key: k.unlockKey, data: kp.sk) }
        let attempt = SetupAttempt(sk: kp.sk, pub: kp.pub, code: "", reset: true, createdAt: Date().timeIntervalSince1970)
        do { try ring.savePendingSetup(attempt) } catch { throw Failure(.storage, "保存加密钥匙失败：\(error.localizedDescription)") }
        var body = cur.currentFields
        body["pub"] = kp.pub
        body["auth_salt"] = salt
        body["auth_key"] = k.authKey
        body["password_wrap"] = wrap
        do {
            try await api.call("POST", "/v1/e2e/reset", body: body)
        } catch {
            if let f = error as? Failure, (400...499).contains(f.status) {
                try? ring.deletePendingSetup()
                throw mapCurrent(error)
            }
            // 网络出错或 5xx：服务端可能已经重置了（同一把公钥重复提交服务端照样成功）
            guard let st = try? await api.state() else { throw SetupPending(attempt: attempt, reset: true) }
            guard st.activeKey?.pub == kp.pub else { throw SetupPending(attempt: attempt, reset: true) }
        }
        try saveKey(kp.sk, ring: ring)
        ring.replacePin(kp.pub)
        marks.mark(server: server, username: username)
        try? ring.deletePendingSetup()
    }

    // MARK: - 解锁（§4.2、§4.4）

    /// 用密码解锁（配对码登录的设备）
    static func unlockWithPassword(_ api: API, ring: KeyRing, server: String, username: String, password: String,
                                   marks: UpgradeMarks) async throws {
        let cred: Credential
        do {
            cred = try await currentCredential(api, server: server, username: username, password: password, marks: marks)
        } catch let f as Failure where f.kind == .downgrade {
            // 已升级的账号收到 pbkdf2：最常见的原因是管理员重设过密码（T44，不是 T1）
            throw Failure(.downgrade, T.t44)
        }
        guard cred.kind == .auth, let unlockKey = cred.unlockKey else { throw Failure(.conflict, T.t44) }
        try await unlock(api, ring: ring, authKey: cred.value, unlockKey: unlockKey)
    }

    /// POST /v1/e2e/unlock 取回用密码锁住的私钥，解开、核对后保存。来自密码，可以替换钉住的公钥（§11.4）
    static func unlock(_ api: API, ring: KeyRing, authKey: String, unlockKey: String) async throws {
        struct R: Decodable { let password_wrap: String }
        let r: R
        do {
            r = try JSONDecoder().decode(R.self, from: try await api.call("POST", "/v1/e2e/unlock", body: ["auth_key": authKey]))
        } catch {
            throw mapCurrent(error)
        }
        guard let sk = try? Core.unwrap("hjp1", key: unlockKey, wrap: r.password_wrap) else { throw Failure(.conflict, T.t44) }
        try acceptOwnKey(sk, keys: try await api.state().keys, ring: ring)
    }

    /// 用恢复码解锁
    static func unlockWithRecovery(_ api: API, ring: KeyRing, code: String) async throws {
        let key: String
        do { key = try Core.recoveryKey(code) } catch let e as Core.Failure { throw Failure(.badRecovery, e.message) }
        let st = try await api.state()
        guard st.hasRecovery else { throw Failure(.badRecovery, T.noRecovery) }
        guard let sk = try? Core.unwrap("hjr1", key: key, wrap: st.recovery_wrap) else { throw Failure(.badRecovery, T.t41) }
        try acceptOwnKey(sk, keys: st.keys, ring: ring)      // 来自恢复码，可以替换钉住的公钥（§11.4）
    }

    /// 解锁后重新设置密码（§4.4.4）：用新密码派生凭证并重新锁住本机私钥
    static func resetPassword(_ api: API, sk: String, server: String, username: String, currentPassword: String, newPassword: String,
                              marks: UpgradeMarks) async throws {
        if let problem = Core.passwordProblem(newPassword, username: username) { throw Failure(.weakPassword, problem) }
        let cur = try await currentCredential(api, server: server, username: username, password: currentPassword, marks: marks, allowLegacy: true)
        try await putAuth(api, current: cur, newPassword: newPassword, sk: sk)
        marks.mark(server: server, username: username)
    }

    /// PUT /v1/account/auth：新的盐、登录凭证；sk 不为 nil 时附上用新密码锁住的私钥
    private static func putAuth(_ api: API, current: Credential, newPassword: String, sk: String?) async throws {
        let salt = try coreCall { try Core.newSalt() }
        let k = try await passwordKeys(newPassword, salt: salt)
        var body = current.currentFields
        body["auth_salt"] = salt
        body["auth_key"] = k.authKey
        var kid = ""
        if let sk {
            body["password_wrap"] = try coreCall { try Core.wrap("hjp1", key: k.unlockKey, data: sk) }
            kid = self.kid(of: sk)
            body["kid"] = kid           // §11.5：服务端发现它已停用时返回 409 → T46
        }
        do { try await api.call("PUT", "/v1/account/auth", body: body) } catch { throw mapCurrent(await staleKeyError(api, kid: kid, error)) }
    }

    // MARK: - 设置项（§7）

    /// 改用户名 / 密码（§7.5）。newPassword 为空表示只改用户名。返回最后一个请求的响应（{"account": …}）。
    /// sk：已开启加密时本机的私钥（用来重新锁住）；账号已开启加密而 sk 为 nil 时不能改密码
    static func changeCredentials(_ api: API, state: State?, sk: String?, server: String, username: String,
                                  newUsername: String, currentPassword: String, newPassword: String,
                                  marks: UpgradeMarks) async throws -> Data {
        if !newPassword.isEmpty, state?.enabled == true, sk == nil { throw Failure(.locked, T.lockedCannotChange) }
        let cur = try await currentCredential(api, server: server, username: username, password: currentPassword, marks: marks, allowPlain: true)
        if cur.kind == .plain {
            // 旧服务端：原来的接口
            do {
                return try await api.call("POST", "/v1/account/credentials",
                                          body: ["username": newUsername, "password": newPassword, "current_password": currentPassword])
            } catch { throw mapCurrent(error) }
        }
        if !newPassword.isEmpty, let problem = Core.passwordProblem(newPassword, username: newUsername) {
            throw Failure(.weakPassword, problem)
        }
        var last = Data()
        // 先改用户名（用当前凭证核对），再改密码（改完当前凭证就失效了）
        if newUsername != username {
            var body = cur.currentFields
            body["username"] = newUsername
            do { last = try await api.call("POST", "/v1/account/credentials", body: body) } catch { throw mapCurrent(error) }
            if marks.isUpgraded(server: server, username: username) { marks.mark(server: server, username: newUsername) }
        }
        if !newPassword.isEmpty {
            try await putAuth(api, current: cur, newPassword: newPassword, sk: state?.enabled == true ? sk : nil)
            marks.mark(server: server, username: newUsername)
            last = Data()
        }
        return last
    }

    /// 更换恢复码（§7.3），返回新的恢复码
    /// 一次更换恢复码：新恢复码、这次上传的 recovery_wrap；confirmed = 已确认服务端换成了这份（重启后直接回到恢复码页）
    struct RecoveryAttempt: Codable, Equatable {
        let code: String
        let wrap: String
        var confirmed = false
    }

    /// 更换恢复码的结果暂时无法确认：新恢复码已存在 KeyRing.pendingRecovery，之后每次刷新状态由 checkPendingRecovery 核对
    struct RecoveryPending: LocalizedError {
        let attempt: RecoveryAttempt
        var errorDescription: String? { T.recoveryUncertain }
    }

    /// 更换恢复码（§7 第 3 项），返回新恢复码。新恢复码在发请求前存进 ring.pendingRecovery，成功后也不删，
    /// 用户在「保存恢复码」页点「完成」时调用 finishRotation。4xx 删除；网络出错或 5xx 时重新读状态核对，仍无法确认抛 RecoveryPending
    static func rotateRecovery(_ api: API, ring: KeyRing, sk: String, server: String, username: String, password: String,
                               marks: UpgradeMarks) async throws -> String {
        let cur = try await currentCredential(api, server: server, username: username, password: password, marks: marks)
        let (code, wrap) = try coreCall { () -> (String, String) in
            let r = try Core.recoveryNew()
            return (r.code, try Core.wrap("hjr1", key: r.key, data: sk))
        }
        // 先存再发：服务端一换，旧恢复码就失效了，新的不能丢
        var attempt = RecoveryAttempt(code: code, wrap: wrap)
        do { try ring.savePendingRecovery(attempt) } catch { throw Failure(.storage, "保存恢复码失败：\(error.localizedDescription)") }
        var body = cur.currentFields
        body["recovery_wrap"] = wrap
        let kid = self.kid(of: sk)
        body["kid"] = kid               // §11.5：服务端发现它已停用时返回 409 → T46
        do {
            try await api.call("PUT", "/v1/e2e/recovery", body: body)
        } catch {
            if let f = error as? Failure, (400...499).contains(f.status) {
                try? ring.deletePendingRecovery()          // 明确被拒：旧恢复码仍然有效
                throw mapCurrent(await staleKeyError(api, kid: kid, error))
            }
            // 网络出错或 5xx：服务端可能已经换了，先看结果；不一样或取不到都先保留（可能还在处理），之后刷新再核对
            guard let st = try? await api.state(), st.recovery_wrap == wrap else { throw RecoveryPending(attempt: attempt) }
        }
        attempt.confirmed = true
        try? ring.savePendingRecovery(attempt)
        return code
    }

    /// 有进行中的更换恢复码时，每次拿到 GET /v1/e2e 都调用：已确认过，或服务端的 recovery_wrap 就是这次上传的那份 → 返回它（显示恢复码页）。
    /// 对不上时保留、返回 nil（结果不确定时服务端可能还没处理完；没换成的话旧恢复码仍然有效，下次更换会覆盖它）
    @discardableResult
    static func checkPendingRecovery(_ st: State, ring: KeyRing) -> RecoveryAttempt? {
        guard var a = try? ring.pendingRecovery() else { return nil }
        if a.confirmed { return a }
        guard st.hasRecovery, st.recovery_wrap == a.wrap else { return nil }
        a.confirmed = true
        try? ring.savePendingRecovery(a)
        return a
    }

    /// 已确认更换、用户还没点「完成」的新恢复码。App 启动、读钥匙时调用：不为 nil 就直接回到恢复码页
    static func confirmedRecovery(ring: KeyRing) -> RecoveryAttempt? {
        guard let a = try? ring.pendingRecovery(), a.confirmed else { return nil }
        return a
    }

    /// 更换恢复码后，用户在「保存恢复码」页点了「完成」
    static func finishRotation(ring: KeyRing) {
        try? ring.deletePendingRecovery()
    }

    // 「只接受加密消息」（PATCH /v1/e2e e2e_only）和「删除服务器上的明文消息」（POST /v1/e2e/delete-plain）：
    // 0.9.0 起取消（§7 第 2、4 项）。所有消息都加密，普通 pushkey 的消息由服务器代加密；purge 变更的处理保留（兼容旧服务端）

    // MARK: - 请另一台设备批准：新设备一侧（§4.3）

    /// 一次批准请求。账号公钥 acc 和 nb 只在内存里；App 重启后重新开始。在同一个 actor（主线程）上使用
    @MainActor
    final class ApprovalRequest {
        enum Phase: Equatable {
            case waiting            // 等对方接手
            case code(String)       // 显示核对码（T31）
            case granted            // 已解锁
            case denied             // T32
            case failed(String)     // T43 等
        }

        let ring: KeyRing
        private(set) var phase: Phase = .waiting
        /// 请求序号：每次登记（PUT）成功后加一。调用方发 GET /v1/e2e 之前记下它，handle 时传回来；
        /// 比当前小的说明是登记之前发出、晚到的响应，丢弃（否则会把旧的 requested=false 当成被拒绝）
        private(set) var generation = 0
        private var dev: (sk: String, pub: String)?
        /// 本次请求认定的账号公钥（写进承诺；只接受和它配对的私钥）
        private(set) var account = ""
        private var nb = ""
        private var revealedFor: String?
        private var busy = false
        /// 已停止（退出登录、换账号）：之后不再登记、不再写钥匙串
        private(set) var stopped = false

        init(ring: KeyRing) { self.ring = ring }

        /// 退出登录、换账号时先停下（§8）：正在 await 的 handle / start 回来后不会再写设备钥匙对或私钥
        func stop() { stopped = true }

        /// 第 1–3 步：定下账号公钥 acc；生成（或沿用已保存的）设备钥匙对和新的 nb；登记并请求批准。
        /// acc 定不下来（钉住的公钥不是服务器的有效钥匙，或者没钉住而有效钥匙不是正好一把）时显示 T43 并停止
        func start(_ api: API, state: State? = nil) async throws {
            guard !stopped else { throw CancellationError() }
            let st: State
            if let state { st = state } else { st = try await api.state() }
            guard !stopped else { throw CancellationError() }
            let active = st.keys.filter(\.active)
            if let pin = ring.pinned {
                // 钉住的公钥不是服务器的有效钥匙：账号重置过加密（§11.3）。批准转交来的私钥不能替换钉住的公钥（§11.4），只能用密码或恢复码解锁
                guard active.contains(where: { $0.pub == pin }) else { phase = .failed(T.t46); throw Failure(.keyChanged, T.t46) }
                account = pin
            } else {
                guard active.count == 1 else { phase = .failed(T.t43); throw Failure(.keyMismatch, T.t43) }
                account = active[0].pub
            }
            if dev == nil {
                if let saved = try? ring.deviceKeypair() {
                    dev = saved
                } else {
                    let kp = try coreCall { try Core.keypair() }
                    do { try ring.saveDeviceKeypair(sk: kp.sk, pub: kp.pub) } catch {
                        throw Failure(.storage, "保存设备钥匙失败：\(error.localizedDescription)")
                    }
                    dev = (kp.sk, kp.pub)
                }
            }
            guard let dev else { return }
            let n = try coreCall { try Core.random32() }
            let commit = try coreCall { try Core.sasCommit(pub: dev.pub, account: account, nonce: n) }
            try await api.call("PUT", "/v1/e2e/device", body: ["pub": dev.pub, "request": true, "commit": commit])
            guard !stopped else { throw CancellationError() }
            nb = n
            revealedFor = nil
            phase = .waiting
            generation += 1
        }

        /// 第 4 步：每次拿到新的 GET /v1/e2e 时调用（generation 是发 GET 之前记下的请求序号），推进流程，返回新的阶段
        @discardableResult
        func handle(_ st: State, api: API, generation g: Int) async -> Phase {
            guard !busy, !stopped, let dev, g == generation else { return phase }
            busy = true
            defer { busy = false }
            switch phase {
            case .granted, .denied, .failed: return phase
            default: break
            }
            let d = st.device
            if d.pub != dev.pub {
                // 服务端登记的不是本机这把公钥（例如别处重新登记过）：重来
                try? await start(api)
                return phase
            }
            // 转交：只在本次请求已经揭晓、核对码已经显示之后才处理（hjg1 谁都能加密给 dev.pub，之前看到的一律忽略）
            if revealedFor != nil, !d.grant.isEmpty {
                guard !stopped else { return phase }
                do {
                    let sk = try coreCall { try Core.grantOpen(deviceSK: dev.sk, grant: d.grant) }
                    guard (try? Core.publicKey(sk).pub) == account else { throw Failure(.keyMismatch, T.t43) }
                    try acceptKey(sk, keys: st.keys, ring: ring)
                    try? ring.deleteDeviceKeypair()
                    phase = .granted
                } catch {
                    phase = .failed(error.localizedDescription)
                }
                return phase
            }
            if !d.requested {
                phase = .denied
                return phase
            }
            if !d.challenge.isEmpty {
                if let r = revealedFor {
                    if r != d.challenge {
                        // 揭晓之后 challenge 变了：对方重新开始，换新的 nb 重新请求
                        try? await start(api)
                    }
                    return phase
                }
                // 先算出核对码（算不出来就重来），再揭晓
                guard let code = try? Core.sasCode(pub: dev.pub, account: account, na: d.challenge, nb: nb) else {
                    try? await start(api)
                    return phase
                }
                do {
                    try await api.call("POST", "/v1/e2e/reveal", body: ["nonce": nb])
                    guard !stopped else { return phase }
                    revealedFor = d.challenge
                    phase = .code(code)
                } catch let f as Failure where f.kind == .conflict {
                    try? await start(api)        // 已经揭晓过 / 对方换了：重新请求
                } catch {
                    // 网络问题：下次刷新再试
                }
            }
            return phase
        }

        /// 用户点「取消」
        func cancel(_ api: API) async {
            if let dev { _ = try? await api.call("PUT", "/v1/e2e/device", body: ["pub": dev.pub, "request": false]) }
            phase = .denied
        }
    }

    // MARK: - 批准其他设备：已解锁设备一侧（§5）

    @MainActor
    final class Approval {
        enum Phase: Equatable {
            case challenged         // 已接手，等对方揭晓
            case code(String)       // T53
            case approved
            case rejected           // 用户点了拒绝
            case failed(String)     // T51 / T52 / 对方取消……
        }

        let request: Request
        private let na: String
        /// 本机私钥算出的账号公钥（不用服务器给的 keys）
        private let account: String
        private(set) var phase: Phase = .challenged
        /// 已停止（用户点「取消」、退出登录、换账号）：之后的 handle / approve 什么都不做
        private(set) var stopped = false

        /// 只停止本机的等待（§5 第 2 步的「取消」；§8）
        func stop() { stopped = true }

        private init(request: Request, na: String, account: String) {
            self.request = request
            self.na = na
            self.account = account
        }

        /// 第 1 步：生成自己的 na（只用自己生成的）并接手请求；409 → T51。sk：本机的账号私钥
        static func begin(_ api: API, request: Request, sk: String) async throws -> Approval {
            let account = try coreCall { try Core.publicKey(sk).pub }
            let na = try coreCall { try Core.random32() }
            do {
                try await api.call("POST", "/v1/e2e/challenge", body: ["device_id": request.device_id, "nonce": na])
            } catch let f as Failure where f.kind == .conflict {
                throw Failure(.conflict, T.t51, status: 409)
            }
            return Approval(request: request, na: na, account: account)
        }

        /// 第 2–4 步：每次拿到新的 GET /v1/e2e 时调用
        @discardableResult
        func handle(_ st: State, api: API) async -> Phase {
            guard !stopped, phase == .challenged else { return phase }
            guard let r = st.requests.first(where: { $0.device_id == request.device_id }) else {
                phase = .failed(T.requestGone)
                return phase
            }
            // 对方重新请求（新的公钥 / 承诺），或者 challenge 已不是自己的 na：这一轮作废
            guard r.pub == request.pub, r.commit == request.commit, r.challenge == na else {
                phase = .failed(T.restarted)
                return phase
            }
            guard !r.reveal.isEmpty else { return phase }
            // 用本机的账号公钥核对承诺：新设备看到的是假的账号公钥时对不上
            let commit = try? Core.sasCommit(pub: r.pub, account: account, nonce: r.reveal)
            guard commit == r.commit, let code = try? Core.sasCode(pub: r.pub, account: account, na: na, nb: r.reveal) else {
                _ = try? await api.call("POST", "/v1/e2e/deny", body: ["device_id": r.device_id])
                phase = .failed(T.t52)
                return phase
            }
            phase = .code(code)
            return phase
        }

        /// 「一致，批准」：把账号私钥转交给对方的公钥；409 时抛服务端说明
        func approve(_ api: API, sk: String) async throws {
            guard !stopped, case .code = phase else { return }
            let grant = try coreCall { try Core.grantSeal(sk: sk, to: request.pub) }
            let kid = E2E.kid(of: sk)
            do {
                try await api.call("POST", "/v1/e2e/grant", body: ["device_id": request.device_id, "pub": request.pub, "grant": grant, "kid": kid])
                phase = .approved
            } catch let f as Failure where f.kind == .conflict {
                // 本机的钥匙已经停用（别的设备重置过加密）→ T46；其他 409 显示服务端说明
                let e = await E2E.staleKeyError(api, kid: kid, f)
                phase = .failed(e.localizedDescription)
                throw e
            }
        }

        /// 「不一致，拒绝」
        func reject(_ api: API) async throws {
            try await api.call("POST", "/v1/e2e/deny", body: ["device_id": request.device_id])
            phase = .rejected
        }
    }

    /// 不核对，直接拒绝
    static func deny(_ api: API, deviceID: String) async throws {
        try await api.call("POST", "/v1/e2e/deny", body: ["device_id": deviceID])
    }

    // MARK: - 收消息（§6）

    /// 收到 kind "sealed" 变更（或下载附件 410 reason=sealed）后重新拉取的消息，能不能替换本地记录（审查 M2）：
    /// 只有「本地是明文、拉回来的是服务器代加密的（带信封且 sealed == "server"）、id 就是请求的那条」才替换。
    /// 否则丢弃——不然被攻破的服务器发一条 sealed 变更，就能改写任意本地消息（发送端加密的、已经解开的、已是代加密的）
    static func acceptResealed<M: E2EMessageFacts>(old: M, new: M, id: Int64) -> Bool {
        old.id == id && new.id == id && !old.isE2E && new.isE2E && new.sealed == "server"
    }

    /// 410 reason=sealed 时，同一次下载最多重新拉取几次（防止服务器一直给新 id）
    static let maxResealedRetries = 2

    /// 下载附件返回 410 的原因（服务端 0.8.0 起带 reason）：sealed = 消息被服务器补加密、附件换了新 id，
    /// 要用 GET /v1/messages/{id} 重新拉取这条消息（续传从头开始）；missing = 附件文件丢失
    struct Gone: Equatable {
        let reason: String
        let messageID: Int64?
        var sealed: Bool { reason == "sealed" }
    }

    static let sealedGoneMessage = "附件已加密，请刷新消息"

    static func gone(_ data: Data) -> Gone {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // 没有 reason（0.8.0 以前的服务端，没有补加密）一律按附件丢失处理，不比较说明文字
        var reason = obj["reason"] as? String ?? ""
        if reason.isEmpty { reason = "missing" }
        let id = (obj["message_id"] as? NSNumber)?.int64Value
        return Gone(reason: reason, messageID: id)
    }

    /// 解密后的附件：id、sha256 用服务端的（下载和校验密文），名字、类型、大小用载荷里的
    struct OpenedAttachment: Equatable {
        let id: String
        let name: String
        let mime: String
        let size: Int64
        /// 附件钥匙，和消息一起保存，解密附件时用
        let key: String
    }

    struct Opened: Equatable {
        let text: String
        let desp: String
        /// markdown / text / image
        let type: String
        let atts: [OpenedAttachment]
        /// 本地解析的 doc（JSON，各端按自己的 MDDoc 解码）；不需要时 nil
        let doc: Data?
        let preview: String
    }

    enum OpenResult: Equatable {
        case ok(Opened)
        case locked         // 本机没有私钥
        case wrongKey       // 不是本机任何一把钥匙加密的
        case broken         // 信封格式不对或被篡改

        /// 保存在消息里的状态
        var code: String {
            switch self {
            case .ok: return "ok"
            case .locked: return "locked"
            case .wrongKey: return "wrong_key"
            case .broken: return "format"
            }
        }
    }

    /// 解不开时显示的标题（T60 / T61 / T62）
    static func placeholder(_ code: String?) -> String {
        switch code {
        case "wrong_key": return T.t61
        case "format": return T.t62
        default: return T.t60
        }
    }

    /// 解开一条加密消息。serverAttachments：服务端 attachments 的 id（按顺序，和载荷 atts 一一对应）。
    /// 单条约 0.1 ms，批量时在后台线程调用
    static func open(envelope: String, keys: [String], serverAttachments: [String]) -> OpenResult {
        guard !keys.isEmpty else { return .locked }
        let p: [String: Any]
        do {
            p = try Core.openMessage(keys: keys, envelope: envelope)
        } catch let e as Core.Failure {
            return e.code == "wrong_key" ? .wrongKey : .broken
        } catch {
            return .broken
        }
        var type = (p["type"] as? String) ?? "markdown"
        if !["markdown", "text", "image"].contains(type) { type = "markdown" }
        let desp = (p["desp"] as? String) ?? ""
        let rawAtts = (p["atts"] as? [[String: Any]]) ?? []
        var atts: [OpenedAttachment] = []
        // 载荷里的附件和服务端的附件数量不一致：整条按已损坏处理（不截断，也不把多出的服务端附件当明文）
        guard rawAtts.count == serverAttachments.count else { return .broken }
        for (i, a) in rawAtts.enumerated() {
            guard let key = a["key"] as? String, !key.isEmpty else { return .broken }
            atts.append(OpenedAttachment(id: serverAttachments[i], name: a["name"] as? String ?? "file",
                                         mime: a["mime"] as? String ?? "application/octet-stream",
                                         size: (a["size"] as? NSNumber)?.int64Value ?? 0, key: key))
        }
        // 标题：和服务端对明文消息的处理一致（没有标题时用附件名，最长 2000 字）
        var text = ((p["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, !atts.isEmpty { text = "📎 " + atts.map(\.name).joined(separator: "、") }
        if text.count > 2000 { text = String(text.prefix(2000)) }
        // Markdown 在本机解析（服务端的条件：type 不是 text / image，正文非空）
        var doc: Data?
        var preview = ""
        if type != "text", type != "image", !desp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let mdAtts: [[String: Any]] = atts.map { ["id": $0.id, "name": $0.name, "mime": $0.mime, "size": $0.size] }
            if let r = try? Core.mdBuild(text: text, desp: desp, atts: mdAtts) {
                doc = r.doc
                preview = r.preview
            }
        }
        return .ok(Opened(text: text, desp: desp, type: type, atts: atts, doc: doc, preview: preview))
    }

    /// 解密附件：密文 src → 真实文件 dst（成功后删除密文；失败时删除临时文件并抛错）。大文件耗时，放在后台线程
    static func decryptAttachment(key: String, src: URL, dst: URL) async throws {
        try await background {
            defer { try? FileManager.default.removeItem(at: src) }
            do { try Core.decryptFile(key: key, src: src, dst: dst) } catch { throw Failure(.core, "解密失败") }
        }
    }
}
