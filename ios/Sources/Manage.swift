import Foundation

// 手机端的管理功能（和 Mac 客户端对齐）：pushkey、账户（用户名密码、设备、配对码）、频道、注册。
// 这个文件只放数据模型、接口和规则（只用 Foundation），界面在 ManageViews.swift；
// 规则和服务端一致（server/selfservice.go、account.go、channels.go），方便在 Mac 上单独测试。

// MARK: 数据模型

/// 账号信息（GET /v1/account、POST /v1/account/credentials）
struct AccountInfo: Decodable, Equatable {
    let id: Int64
    let username: String
    let has_password: Bool

    init(id: Int64, username: String, has_password: Bool) {
        self.id = id; self.username = username; self.has_password = has_password
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(Int64.self, forKey: .id)) ?? 0
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        has_password = (try? c.decodeIfPresent(Bool.self, forKey: .has_password)) ?? false
    }

    private enum CodingKeys: String, CodingKey { case id, username, has_password }
}

/// 一次配对 / 登录记录
struct DevicePairing: Decodable, Hashable {
    let at: Int64
    let ip: String
    let method: String
    let client: String

    var methodLabel: String { ["code": "配对码", "password": "密码登录", "register": "注册"][method] ?? method }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = (try? c.decodeIfPresent(Int64.self, forKey: .at)) ?? 0
        ip = (try? c.decodeIfPresent(String.self, forKey: .ip)) ?? ""
        method = (try? c.decodeIfPresent(String.self, forKey: .method)) ?? ""
        client = (try? c.decodeIfPresent(String.self, forKey: .client)) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case at, ip, method, client }
}

/// 本账号的一台设备
struct DeviceInfo: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let platform: String
    let client: String
    let created_at: Int64
    let last_seen: Int64?
    let last_paired: Int64
    let pair_count: Int
    let revoked: Bool
    /// 就是发请求的这台设备
    let current: Bool
    let online: Bool
    let pairings: [DevicePairing]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        platform = (try? c.decodeIfPresent(String.self, forKey: .platform)) ?? ""
        client = (try? c.decodeIfPresent(String.self, forKey: .client)) ?? ""
        created_at = (try? c.decodeIfPresent(Int64.self, forKey: .created_at)) ?? 0
        last_seen = try? c.decodeIfPresent(Int64.self, forKey: .last_seen)
        last_paired = (try? c.decodeIfPresent(Int64.self, forKey: .last_paired)) ?? 0
        pair_count = (try? c.decodeIfPresent(Int.self, forKey: .pair_count)) ?? 0
        revoked = (try? c.decodeIfPresent(Bool.self, forKey: .revoked)) ?? false
        current = (try? c.decodeIfPresent(Bool.self, forKey: .current)) ?? false
        online = (try? c.decodeIfPresent(Bool.self, forKey: .online)) ?? false
        pairings = (try? c.decodeIfPresent([DevicePairing].self, forKey: .pairings)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, platform, client, created_at, last_seen, last_paired, pair_count, revoked, current, online, pairings
    }

    /// SF Symbols 图标
    var icon: String {
        switch platform {
        case "macos": return "laptopcomputer"
        case "ios": return "iphone"
        case "android": return "candybarphone"
        default: return "desktopcomputer"
        }
    }
}

struct AccountDetail: Decodable {
    let account: AccountInfo
    let devices: [DeviceInfo]
    let register_open: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = try c.decode(AccountInfo.self, forKey: .account)
        devices = (try? c.decodeIfPresent([DeviceInfo].self, forKey: .devices)) ?? []
        register_open = (try? c.decodeIfPresent(Bool.self, forKey: .register_open)) ?? false
    }

    private enum CodingKeys: String, CodingKey { case account, devices, register_open }
}

struct PairCode: Decodable, Equatable {
    let code: String
    let expires_in: Int?
}

/// 配对码状态（0.5.6 起）：waiting / used / expired
struct PairCodeStatus: Decodable, Equatable {
    let state: String
    let expires_in: Int?
    let used_by: String?
}

/// 本机对一把 pushkey 的接收方式：notify / silent / off
struct KeySubscription: Decodable, Equatable {
    let pushkey_id: Int64
    let mode: String
}

// MARK: 接口

extension API {
    // pushkey（0.4.2 起；删除 0.5.2 起）

    /// 新建；key 为空时服务端自动生成
    func createKey(name: String, key: String) async throws -> PushKey {
        try await decode(PushKey.self, "/v1/keys", method: "POST", json: ["name": name, "key": key])
    }

    /// 改名 / 换 key：空字符串表示不改；换 key 后旧 key 立即失效
    func updateKey(id: Int64, name: String, key: String) async throws -> PushKey {
        try await decode(PushKey.self, "/v1/keys/\(id)", method: "PATCH", json: ["name": name, "key": key])
    }

    func revokeKey(id: Int64) async throws -> PushKey {
        try await decode(PushKey.self, "/v1/keys/\(id)/revoke", method: "POST")
    }

    /// 删除一把已吊销的 key（服务端 0.5.2 起）
    func deleteKey(id: Int64) async throws {
        try await send("/v1/keys/\(id)", method: "DELETE")
    }

    func subscriptions() async throws -> [KeySubscription] {
        struct R: Decodable { let subscriptions: [KeySubscription]? }
        return try await decode(R.self, "/v1/subscriptions").subscriptions ?? []
    }

    func setSubscription(keyID: Int64, mode: String) async throws {
        try await send("/v1/subscriptions/\(keyID)", method: "PUT", json: ["mode": mode])
    }

    // 账户（0.5.0 起；配对码状态 0.5.6 起）

    func account() async throws -> AccountDetail { try await decode(AccountDetail.self, "/v1/account") }

    /// 设置 / 修改用户名和密码。password 为空 = 只改用户名；已有密码时（没有「允许管理」的设备）需要当前密码
    func setCredentials(username: String, password: String, current: String) async throws -> AccountInfo {
        struct R: Decodable { let account: AccountInfo }
        return try await decode(R.self, "/v1/account/credentials", method: "POST",
                                json: ["username": username, "password": password, "current_password": current]).account
    }

    func createPairCode() async throws -> PairCode { try await decode(PairCode.self, "/v1/pair-codes", method: "POST") }

    func pairCodeStatus(_ code: String) async throws -> PairCodeStatus {
        guard ManageRules.isPathSafe(code) else { throw APIError.invalid("配对码格式不对") }
        return try await decode(PairCodeStatus.self, "/v1/pair-codes/\(code)")
    }

    func revokeDevice(_ id: String) async throws {
        guard ManageRules.isPathSafe(id) else { throw APIError.invalid("设备 ID 格式不对") }
        try await send("/v1/devices/\(id)/revoke", method: "POST")
    }

    /// 给本机改名（0.4.2 起）
    func renameMe(_ name: String) async throws -> Me { try await decode(Me.self, "/v1/me", method: "PATCH", json: ["name": name]) }

    /// 注册新账号（管理员开放注册后才可用，否则 403 并带说明）
    func register(username: String, password: String, name: String, fingerprint: String) async throws -> LoginResult {
        try await decode(LoginResult.self, "/v1/register", method: "POST", json: [
            "username": username, "password": password, "name": name, "platform": "ios", "fingerprint": fingerprint,
        ], authed: false)
    }

    // 频道（0.5.5 起）

    /// 只改传了的字段；alias 空字符串 = 恢复原名
    func updateChannel(_ topic: String, alias: String? = nil, hidden: Bool? = nil, muted: Bool? = nil, pinned: Bool? = nil) async throws -> ChannelSetting {
        var b: [String: Any] = ["topic": topic]
        if let alias { b["alias"] = alias }
        if let hidden { b["hidden"] = hidden }
        if let muted { b["muted"] = muted }
        if let pinned { b["pinned"] = pinned }
        return try await decode(ChannelSetting.self, "/v1/channels", method: "PATCH", json: b)
    }

    /// 手动排序；空列表 = 恢复按最近活跃排序
    func setChannelOrder(_ topics: [String]) async throws {
        try await send("/v1/channels/order", method: "PUT", json: ["topics": topics])
    }

    /// 删除频道：这个频道的全部消息（附件一起删）和设置，返回删除条数
    func deleteChannel(_ topic: String) async throws -> Int {
        struct R: Decodable { let deleted: Int? }
        return try await decode(R.self, "/v1/channels/delete", method: "POST", json: ["topic": topic]).deleted ?? 0
    }
}

// MARK: 规则（和服务端一致）

enum ManageRules {
    /// 自定义 key：16–64 位字母、数字、_、-（server/selfservice.go reCustomKey）
    static let keyRule = "key 需要 16–64 位字母、数字、下划线或短横线"

    static func keyProblem(_ key: String) -> String? {
        let k = key.trimmingCharacters(in: .whitespaces)
        if k.isEmpty { return nil }
        let ok = (16...64).contains(k.unicodeScalars.count) && k.unicodeScalars.allSatisfy {
            ($0.value < 128 && CharacterSet.alphanumerics.contains($0)) || $0 == "_" || $0 == "-"
        }
        return ok ? nil : keyRule
    }

    /// 随机 key：和服务端自动生成的格式一样（PK_ + 24 位 base64url），系统安全随机数
    static func randomKey() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var g = SystemRandomNumberGenerator()
        return "PK_" + String((0..<24).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &g)] })
    }

    /// 去掉首尾空白，按 Unicode 码点截断到 max 个（和服务端按 rune 计数一致；emoji 组合等不会被多算）
    static func clip(_ s: String, _ max: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.unicodeScalars.count > max else { return t }
        var v = String.UnicodeScalarView()
        v.append(contentsOf: t.unicodeScalars.prefix(max))
        return String(v)
    }

    /// key 名称最多 40 个字（服务端 cleanLabel 截断）
    static let keyNameMax = 40
    /// 频道显示名最多 32 个字
    static let aliasMax = 32

    /// 用户名规则（与服务端一致）：中文、字母、数字、下划线、点、短横线，中间可以有空格，2–32 个字
    static let usernameRule = "2–32 个字，可以用中文、字母、数字、空格、下划线、点和短横线"

    static func normalizeUsername(_ u: String) -> String {
        u.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func usernameProblem(_ raw: String) -> String? {
        let u = normalizeUsername(raw)
        if u.isEmpty { return nil }
        // 与服务端一致：按 Unicode 字符（码点）计数；字母 \p{L}、数字 \p{N}、_ . - 空格；排除显示为空白的韩文填充符
        let n = u.unicodeScalars.count
        if n < 2 || n > 32 { return "用户名需要 2–32 个字" }
        let blank: Set<UInt32> = [0x115F, 0x1160, 0x3164, 0xFFA0]
        let ok = u.unicodeScalars.allSatisfy { sc in
            if "_.- ".unicodeScalars.contains(sc) { return true }
            if blank.contains(sc.value) { return false }
            switch sc.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber: return true
            default: return false
            }
        }
        return ok ? nil : "用户名只能用中文、字母、数字、空格、下划线、点和短横线"
    }

    /// 密码至少 8 个字（服务端按字符计数，最多 256 字节）
    static func passwordProblem(_ p: String) -> String? {
        if p.isEmpty { return nil }
        if p.count < 8 { return "密码至少 8 位" }
        if p.utf8.count > 256 { return "密码太长" }
        return nil
    }

    /// 拼进路径的设备 ID、配对码只能是字母、数字、_、-
    static func isPathSafe(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 80 && s.unicodeScalars.allSatisfy {
            ($0.value < 128 && CharacterSet.alphanumerics.contains($0)) || $0 == "_" || $0 == "-"
        }
    }

    /// 发送示例：浏览器能直接打开的 URL、带标题和正文的 curl
    static func sendExamples(server: String, key: String) -> (url: String, curl: String) {
        let base = server.hasSuffix("/") ? String(server.dropLast()) : server
        let url = "\(base)/message/push?pushkey=\(key)&text=hello"
        let curl = """
        curl -d pushkey=\(key) -d text="训练完成" -d desp="val_loss **0.231**" -d priority=4 \\
             \(base)/message/push
        """
        return (url, curl)
    }

    // 频道顺序（和 Mac 端 AppModel.orderChannels / mergedOrder / moved 一致）

    /// 置顶的在前；同一组里手动顺序（sort > 0）在前，其余按最近一条消息从新到旧
    static func orderChannels(_ names: [String], settings: [String: ChannelSetting], last: [String: Int64]) -> [String] {
        names.sorted { a, b in
            let sa = settings[a], sb = settings[b]
            let pa = sa?.pinned == true, pb = sb?.pinned == true
            if pa != pb { return pa }
            let oa = (sa?.sort ?? 0) > 0 ? sa!.sort : Int.max, ob = (sb?.sort ?? 0) > 0 ? sb!.sort : Int.max
            if oa != ob { return oa < ob }
            let la = last[a] ?? 0, lb = last[b] ?? 0
            return la != lb ? la > lb : a < b
        }
    }

    /// 把看得到的频道的新顺序并进完整的手动顺序：看不到的频道留在原来的位置，看得到的按新顺序依次填进它们原来占的位置
    static func mergedOrder(_ visible: [String], settings: [String: ChannelSetting]) -> [String] {
        let vis = Set(visible)
        var base = settings.values.filter { $0.sort > 0 }.sorted { $0.sort < $1.sort }.map(\.topic)
        for t in visible where !base.contains(t) { base.append(t) }
        var it = visible.makeIterator()
        return base.map { vis.contains($0) ? it.next()! : $0 }
    }
}
