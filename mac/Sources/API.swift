import Foundation

enum APIError: Error, LocalizedError, Equatable {
    case unauthorized(String)
    case http(Int, String)
    case invalid(String)
    /// 服务端没有这个接口（版本较旧）
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unsupported: return "服务端版本较旧，不支持这个功能，更新服务端后可用"
        case .unauthorized(let m): return "未授权：\(m)"
        // 服务端返回的中文说明直接给用户看；没有说明或服务端出错时才带状态码
        // （代理返回的 HTML 错误页之类不是服务端的说明，只显示状态码）
        case .http(let c, let m):
            let plain = !m.isEmpty && !m.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
            if !plain { return "请求失败（HTTP \(c)）" }
            return c >= 500 ? "服务器出错（HTTP \(c)）：\(m)" : m
        case .invalid(let m): return m
        }
    }
}

/// 最近一次响应里的服务端版本（X-Huijian-Server）；变化时客户端重新拉取功能清单
enum ServerVersionSeen {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var value: String?
    static func note(_ v: String) { lock.lock(); value = v; lock.unlock() }
    static var current: String? { lock.lock(); defer { lock.unlock() }; return value }
}

enum SSEEvent {
    case hello
    case message(Message)
    case ping
}

struct APIClient {
    let server: URL
    let token: String?

    // 会话由 NetSessions 按代理设置创建；消息、附件属于「服务器连接」，更新属于「应用更新」
    static var streamSession: URLSession { NetSessions.shared.session(.stream, .server) }
    static var pollSession: URLSession { NetSessions.shared.session(.poll, .server) }
    static var apiSession: URLSession { NetSessions.shared.session(.api, .server) }
    static var updateSession: URLSession { NetSessions.shared.session(.api, .updates) }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        let base = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = base + path
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET") -> URLRequest {
        var r = URLRequest(url: url(path, query: query))
        r.httpMethod = method
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.setValue("huijian-mac/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        r.setValue(AppInfo.clientLabel, forHTTPHeaderField: "X-Huijian-Client")
        r.setValue(AppInfo.clientLabel, forHTTPHeaderField: "X-Hongyan-Client") // 改名前的服务端只认旧名
        // 0.4.x 配对的设备没有指纹，服务端据此补上，之后退出再登录能沿用原记录
        if token != nil {
            r.setValue(DeviceFingerprint.value, forHTTPHeaderField: "X-Huijian-Fingerprint")
            r.setValue(DeviceFingerprint.value, forHTTPHeaderField: "X-Hongyan-Fingerprint")
        }
        return r
    }

    static func errorMessage(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = obj["error"] as? String {
            return e
        }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }

    static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let h = resp as? HTTPURLResponse else { throw APIError.invalid("非 HTTP 响应") }
        if let v = h.legacyHeader("Server") { ServerVersionSeen.note(v) }
        if h.statusCode == 401 { throw APIError.unauthorized(errorMessage(data)) }
        if isMissingRoute(h, data) { throw APIError.unsupported }
        if !(200...299).contains(h.statusCode) { throw APIError.http(h.statusCode, errorMessage(data)) }
    }

    /// 旧版回笺服务端没有这个接口：Go 路由层返回纯文本的 404「not found」/「404 page not found」或 405。
    /// 业务上的 404 都带 {"error":…}；反向代理、填错地址返回的 HTML 404 不算（那是地址问题，不是版本问题）。
    static func isMissingRoute(_ h: HTTPURLResponse, _ data: Data) -> Bool {
        guard h.statusCode == 404 || h.statusCode == 405, !isJSONError(data) else { return false }
        let ct = (h.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if ct.contains("html") { return false }
        let body = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return h.statusCode == 405 || body == "not found" || body == "404 page not found"
    }

    static func isJSONError(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] != nil
    }

    // MARK: 配对

    struct PairResult: Decodable {
        let device_id: String
        let name: String
        let token: String
        /// 0.5.0 起：按设备指纹沿用了原来的设备记录
        let reused: Bool?
    }

    static func pair(server: URL, code: String, name: String, fingerprint: String = DeviceFingerprint.value) async throws -> PairResult {
        let c = APIClient(server: server, token: nil)
        var r = c.request("/v1/pair", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "name": name, "platform": "macos",
                                                                 "fingerprint": fingerprint])
        let (data, resp) = try await apiSession.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode == 403 {
            throw APIError.http(403, errorMessage(data))
        }
        try check(resp, data)
        return try JSONDecoder().decode(PairResult.self, from: data)
    }

    // MARK: 账户

    /// 用户名密码登录（register=true 时为注册新账号）
    static func login(server: URL, username: String, password: String, name: String, register: Bool,
                      fingerprint: String = DeviceFingerprint.value) async throws -> PairResult {
        let c = APIClient(server: server, token: nil)
        var r = c.request(register ? "/v1/register" : "/v1/login", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password, "name": name,
                                                                 "platform": "macos", "fingerprint": fingerprint])
        let (data, resp) = try await apiSession.data(for: r)
        try check(resp, data)
        return try JSONDecoder().decode(PairResult.self, from: data)
    }

    struct AccountInfo: Codable, Equatable {
        let id: Int64
        let username: String
        let has_password: Bool
    }

    struct Me: Decodable {
        let device_id: String
        let name: String
        let platform: String?
        let can_admin: Bool?
        let admin_url: String?
        let account: AccountInfo?
        let away_silent: Bool?
    }

    struct Pairing: Codable, Equatable, Hashable {
        let at: Int64
        let ip: String
        let method: String
        let client: String
        var methodLabel: String { ["code": "配对码", "password": "密码登录", "register": "注册"][method] ?? method }
    }

    struct DeviceInfo: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let platform: String
        let client: String
        let created_at: Int64
        let last_seen: Int64?
        let last_paired: Int64
        let pair_count: Int
        let revoked: Bool
        let current: Bool
        let online: Bool
        let pairings: [Pairing]
    }

    struct AccountDetail: Codable, Equatable {
        let account: AccountInfo
        let devices: [DeviceInfo]
        let register_open: Bool
    }

    func account() async throws -> AccountDetail {
        try JSONDecoder().decode(AccountDetail.self, from: try await send("/v1/account", method: "GET", body: nil))
    }

    /// 设置 / 修改账号用户名和密码（已有密码时需要 current）
    func setCredentials(username: String, password: String, current: String) async throws -> AccountInfo {
        struct R: Decodable { let account: AccountInfo }
        let d = try await send("/v1/account/credentials", method: "POST",
                               body: ["username": username, "password": password, "current_password": current])
        return try JSONDecoder().decode(R.self, from: d).account
    }

    /// 为本账号生成配对码（只能用一次；0.5.6 起 3 分钟有效，同一台设备重新生成时旧码作废）
    func createPairCode() async throws -> String { try await createPairCodeInfo().code }

    struct NewPairCode: Decodable {
        let code: String
        let expires_in: Int?
    }

    func createPairCodeInfo() async throws -> NewPairCode {
        try JSONDecoder().decode(NewPairCode.self, from: try await send("/v1/pair-codes", method: "POST", body: nil))
    }

    /// 配对码状态（0.5.6 起，功能 id pair.status）：waiting / used / expired；used 时带使用它的设备名
    struct PairCodeStatus: Decodable {
        let state: String
        let expires_in: Int?
        let used_by: String?
    }

    func pairCodeStatus(_ code: String) async throws -> PairCodeStatus {
        try JSONDecoder().decode(PairCodeStatus.self, from: try await send("/v1/pair-codes/\(code)", method: "GET", body: nil))
    }

    func revokeDevice(_ id: String) async throws {
        _ = try await send("/v1/devices/\(id)/revoke", method: "POST", body: nil)
    }

    /// 退出登录：本机 token 立即失效
    func logout() async throws {
        _ = try await send("/v1/logout", method: "POST", body: nil)
    }

    struct Subscription: Codable, Equatable, Identifiable {
        let pushkey_id: Int64
        let name: String
        var mode: String
        var id: Int64 { pushkey_id }
    }

    func subscriptions() async throws -> (items: [Subscription], awaySilent: Bool) {
        struct R: Decodable { let subscriptions: [Subscription]; let away_silent: Bool }
        let r = try JSONDecoder().decode(R.self, from: try await send("/v1/subscriptions", method: "GET", body: nil))
        return (r.subscriptions, r.away_silent)
    }

    func setSubscription(keyID: Int64, mode: String) async throws {
        _ = try await send("/v1/subscriptions/\(keyID)", method: "PUT", body: ["mode": mode])
    }

    func setAwaySilent(_ on: Bool) async throws {
        _ = try await send("/v1/me", method: "PATCH", body: ["away_silent": on])
    }

    /// 告诉服务端「这台设备正在被使用」
    func presence() async throws {
        _ = try await send("/v1/presence", method: "POST", body: nil)
    }

    func me() async throws -> Me {
        let (data, resp) = try await Self.apiSession.data(for: request("/v1/me"))
        try Self.check(resp, data)
        return try JSONDecoder().decode(Me.self, from: data)
    }

    /// 一次性管理登录链接（60 秒有效）。未授权设备返回 HTTP 403。
    func adminLink() async throws -> URL {
        let (data, resp) = try await Self.apiSession.data(for: request("/v1/admin/link", method: "POST"))
        try Self.check(resp, data)
        struct R: Decodable { let url: String }
        let r = try JSONDecoder().decode(R.self, from: data)
        guard let u = URL(string: r.url) else { throw APIError.invalid("链接格式不对") }
        return u
    }

    // MARK: 设备自助管理（改名、pushkey）

    struct PushKey: Decodable, Identifiable, Equatable {
        let id: Int64
        let name: String
        let key: String
        let created_at: Date
        let last_used: Date?
        let revoked: Bool
    }

    private func send(_ path: String, method: String, body: [String: Any]?) async throws -> Data {
        var r = request(path, method: method)
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await Self.apiSession.data(for: r)
        try Self.check(resp, data)
        return data
    }

    private struct KeyList: Decodable { let keys: [PushKey] }

    /// 给本机改名，返回服务端保存后的名称
    func renameDevice(_ name: String) async throws -> String {
        let d = try await send("/v1/me", method: "PATCH", body: ["name": name])
        return try JSONDecoder().decode(Me.self, from: d).name
    }

    func listKeys() async throws -> [PushKey] {
        try JSONCoding.decoder.decode(KeyList.self, from: try await send("/v1/keys", method: "GET", body: nil)).keys
    }

    /// 新建；key 为空时服务端自动生成
    func createKey(name: String, key: String) async throws -> PushKey {
        var b: [String: Any] = ["name": name]
        if !key.isEmpty { b["key"] = key }
        return try JSONCoding.decoder.decode(PushKey.self, from: try await send("/v1/keys", method: "POST", body: b))
    }

    /// 改名 / 更换 key（空字符串表示不改），返回更新后的这一把
    func updateKey(id: Int64, name: String, key: String) async throws -> PushKey {
        try JSONCoding.decoder.decode(PushKey.self, from: try await send("/v1/keys/\(id)", method: "PATCH", body: ["name": name, "key": key]))
    }

    @discardableResult
    func revokeKey(id: Int64) async throws -> PushKey {
        try JSONCoding.decoder.decode(PushKey.self, from: try await send("/v1/keys/\(id)/revoke", method: "POST", body: nil))
    }

    /// 彻底删除一把已吊销的 pushkey（服务端 0.5.1 起）
    func deleteKey(id: Int64) async throws {
        _ = try await send("/v1/keys/\(id)", method: "DELETE", body: nil)
    }

    // MARK: 版本与功能协商

    struct Feature: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let since: String
    }

    struct ServerInfo: Codable, Equatable {
        let name: String
        let version: String
        let api: Int
        let features: [Feature]
        /// 长轮询最长等待秒数（0.6.4 起，功能 poll.long）
        var long_poll_max: Int? = nil
    }

    /// 服务端版本和功能清单；旧服务端（< 0.5.0）抛出 .unsupported
    func info() async throws -> ServerInfo {
        let (data, resp) = try await Self.apiSession.data(for: request("/v1/info"))
        try Self.check(resp, data)
        return try JSONDecoder().decode(ServerInfo.self, from: data)
    }

    // MARK: 服务端存储与备份（需要允许管理）

    struct BackupStatus: Codable, Equatable {
        let at: Int64
        let ok: Bool
        let error: String?
        let warning: String?
        let reason: String?
        let db: String?
        let db_size: Int64?
        let files: Bool?
        let copied: Int?
        let seconds: Double?
    }

    struct StorageInfo: Codable, Equatable {
        let version: String?
        let data_dir: String
        let db_size: Int64
        let files_dir: String
        let files_ok: Bool
        let files_error: String?
        let files_count: Int
        let files_size: Int64
        let files_free: Int64
        let pending: Int
        let legacy: Int
        let backup_enabled: Bool
        let backup_dir: String?
        let backup_ok: Bool
        let backup_error: String?
        let backup_free: Int64
        let backup_at: String?
        let backup_keep: Int?
        let backup_files: Bool?
        let next: Int64?
        let running: Bool
        let last: BackupStatus?
        let tz: String?
    }

    func storage(fresh: Bool = false) async throws -> StorageInfo {
        let q: [URLQueryItem] = fresh ? [.init(name: "fresh", value: "1")] : []
        let (data, resp) = try await Self.apiSession.data(for: request("/v1/storage", query: q))
        try Self.check(resp, data)
        return try JSONDecoder().decode(StorageInfo.self, from: data)
    }

    /// 让服务端开始一次备份（在后台进行），返回开始时的状态
    func startBackup() async throws -> StorageInfo {
        try JSONDecoder().decode(StorageInfo.self, from: try await send("/v1/storage/backup", method: "POST", body: nil))
    }

    // MARK: 消息

    /// wait>0 时为长轮询：since 之后没有消息，服务端最多挂起 wait 秒（上限见 /v1/info 的 long_poll_max，旧服务端 55），有新消息立即返回，超时返回空列表。
    func messages(since: Int64, limit: Int = 200, wait: Int = 0) async throws -> [Message] {
        try await messagesPage(since: since, limit: limit, wait: wait).messages
    }

    /// 删除 / 归档变更（同账号其他设备的操作），0.5.4 起
    struct MsgChange: Decodable, Equatable {
        let seq: Int64
        let id: Int64
        let kind: String     // delete / archive
        let state: Int?
    }

    struct MessagePage {
        let messages: [Message]
        let latestBuild: Int?
        let nextSince: Int64?
        var changes: [MsgChange] = []
        var changesNext: Int64?
        var changesReset = false
        /// 服务端变更纪元：变了说明服务端数据换过（重建或从备份恢复），游标作废
        var changesEpoch: String?
    }

    /// 同 messages，另外返回响应头里的最新客户端构建号（X-Huijian-Latest-Build），用于及时发现更新；
    /// changesSince 不为 nil 时一并取之后的删除 / 归档变更（-1 表示从现在开始）
    func messagesPage(since: Int64, limit: Int = 200, wait: Int = 0, changesSince: Int64? = nil) async throws -> MessagePage {
        var q: [URLQueryItem] = [.init(name: "since", value: String(since)), .init(name: "limit", value: String(limit))]
        if wait > 0 { q.append(.init(name: "wait", value: String(wait))) }
        if let cs = changesSince { q.append(.init(name: "changes_since", value: String(cs))) }
        var r = request("/v1/messages", query: q)
        if wait > 0 { r.timeoutInterval = TimeInterval(wait + 20) }
        let (data, resp) = try await (wait > 0 ? Self.pollSession : Self.apiSession).data(for: r)
        try Self.check(resp, data)
        // 服务端无消息时可能返回 "messages": null（Go nil 切片），按空列表处理
        // next_since（0.5.0 起）：服务端扫描到的位置，包括本机设为「不接收」的消息，下次从这里继续
        struct Wrap: Decodable {
            let messages: [Message]?; let next_since: Int64?
            let changes: [MsgChange]?; let changes_next: Int64?; let changes_reset: Bool?; let changes_epoch: String?
        }
        let latest = (resp as? HTTPURLResponse)?.legacyHeader("Latest-Build").flatMap { Int($0) }
        let w = try JSONCoding.decoder.decode(Wrap.self, from: data)
        let msgs = (w.messages ?? []).map { m -> Message in var x = m; x.stripLocalFields(); return x }
        return MessagePage(messages: msgs, latestBuild: latest, nextSince: w.next_since,
                           changes: w.changes ?? [], changesNext: w.changes_next, changesReset: w.changes_reset ?? false,
                           changesEpoch: w.changes_epoch)
    }

    /// 对账：服务端这个账号全部消息的 (id, 归档状态)，以及当时的变更游标
    func messageStates() async throws -> (items: [Int64: Int], changesNext: Int64, epoch: String?) {
        struct R: Decodable { let items: [[Int64]]; let changes_next: Int64; let epoch: String? }
        let r = try JSONCoding.decoder.decode(R.self, from: try await send("/v1/messages/state", method: "GET", body: nil))
        var out: [Int64: Int] = [:]
        for it in r.items where it.count == 2 { out[it[0]] = Int(it[1]) }
        return (out, r.changes_next, r.epoch)
    }

    // MARK: 频道设置（0.5.5 起，功能 id channels）

    struct ChannelSetting: Codable, Equatable {
        var topic: String
        var alias: String = ""
        var hidden = false
        var muted = false
        var pinned = false
        var sort = 0          // 手动顺序，0 = 按最近活跃
    }

    func channels() async throws -> [ChannelSetting] {
        struct R: Decodable { let channels: [ChannelSetting] }
        return try JSONCoding.decoder.decode(R.self, from: try await send("/v1/channels", method: "GET", body: nil)).channels
    }

    /// 只改传了的字段
    func updateChannel(_ topic: String, alias: String? = nil, hidden: Bool? = nil, muted: Bool? = nil, pinned: Bool? = nil) async throws -> ChannelSetting {
        var b: [String: Any] = ["topic": topic]
        if let alias { b["alias"] = alias }
        if let hidden { b["hidden"] = hidden }
        if let muted { b["muted"] = muted }
        if let pinned { b["pinned"] = pinned }
        return try JSONCoding.decoder.decode(ChannelSetting.self, from: try await send("/v1/channels", method: "PATCH", body: b))
    }

    /// 手动排序；空列表 = 恢复按最近活跃排序
    func setChannelOrder(_ topics: [String]) async throws {
        _ = try await send("/v1/channels/order", method: "PUT", body: ["topics": topics])
    }

    /// 删除频道：这个频道的全部消息（附件一起删）和设置
    func deleteChannel(_ topic: String) async throws -> Int {
        struct R: Decodable { let deleted: Int }
        return try JSONCoding.decoder.decode(R.self, from: try await send("/v1/channels/delete", method: "POST", body: ["topic": topic])).deleted
    }

    /// 从账号删除消息（所有设备同步消失，附件一起删除），返回删除条数
    func deleteMessages(_ ids: [Int64]) async throws -> Int {
        struct R: Decodable { let deleted: Int }
        return try JSONCoding.decoder.decode(R.self, from: try await send("/v1/messages/delete", method: "POST", body: ["ids": ids])).deleted
    }

    /// 设置归档状态：0 自动、1 归档、2 保留在收件箱
    func archiveMessages(_ ids: [Int64], state: Int) async throws -> Int {
        struct R: Decodable { let updated: Int }
        return try JSONCoding.decoder.decode(R.self, from: try await send("/v1/messages/archive", method: "POST", body: ["ids": ids, "state": state])).updated
    }

    // MARK: 应用内更新

    /// 有比 build 新的版本时返回更新信息，否则 nil
    func update(build: Int) async throws -> UpdateInfo? {
        let (data, resp) = try await Self.updateSession.data(for: request("/v1/update", query: [.init(name: "build", value: String(build))]))
        try Self.check(resp, data)
        struct R: Decodable { let update: UpdateInfo? }
        return try JSONDecoder().decode(R.self, from: data).update
    }

    /// 分页拉取 since 之后的全部消息
    func allMessages(since: Int64) async throws -> [Message] {
        var out: [Message] = []
        var cursor = since
        while true {
            let page = try await messages(since: cursor, limit: 500)
            out += page
            guard let last = page.last, page.count == 500 else { break }
            cursor = last.id
        }
        return out
    }

    // MARK: SSE（可选，默认不用）
    // 经过对 HTTPS 做中间人扫描的杀毒软件或代理时，SSE 可能被缓冲到收不到任何数据，所以 App 主用长轮询；
    // 这里保留 SSE 实现，供以后在没有中间人缓冲的网络里作为可选传输。

    /// 手工按字节解析 SSE（AsyncLineSequence 会吞掉空行，无法用来分隔事件）。
    func stream(since: Int64) -> AsyncThrowingStream<SSEEvent, Error> {
        var req = request("/v1/stream", query: [.init(name: "since", value: String(since))])
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 60
        let request = req
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, resp) = try await Self.streamSession.bytes(for: request)
                    guard let h = resp as? HTTPURLResponse else { throw APIError.invalid("非 HTTP 响应") }
                    if h.statusCode != 200 {
                        var body = Data()
                        for try await b in bytes { body.append(b); if body.count > 4096 { break } }
                        if h.statusCode == 401 { throw APIError.unauthorized(Self.errorMessage(body)) }
                        throw APIError.http(h.statusCode, Self.errorMessage(body))
                    }
                    var parser = SSEParser()
                    var line: [UInt8] = []
                    for try await b in bytes {
                        if b == 0x0A {
                            if line.last == 0x0D { line.removeLast() }
                            let s = String(decoding: line, as: UTF8.self)
                            line.removeAll(keepingCapacity: true)
                            if let ev = try parser.feed(line: s) { continuation.yield(ev) }
                        } else {
                            line.append(b)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// SSE 行解析器：遇到空行派发事件，以 ":" 开头的是注释（心跳）。
struct SSEParser {
    var event = ""
    var data: [String] = []
    var lastID: String?

    mutating func feed(line: String) throws -> SSEEvent? {
        if line.isEmpty {
            defer { event = ""; data = [] }
            guard !data.isEmpty || !event.isEmpty else { return nil }
            let payload = data.joined(separator: "\n")
            switch event {
            case "hello": return .hello
            case "message", "":
                guard !payload.isEmpty else { return nil }
                var m = try JSONCoding.decoder.decode(Message.self, from: Data(payload.utf8))
                m.stripLocalFields()
                return .message(m)
            default: return nil
            }
        }
        if line.hasPrefix(":") { return .ping }
        let field: Substring
        var value: Substring
        if let i = line.firstIndex(of: ":") {
            field = line[..<i]
            value = line[line.index(after: i)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        case "id": lastID = String(value)
        default: break
        }
        return nil
    }
}

/// 端到端加密的网络接入（E2E.swift）：照常带设备凭证、记录服务端版本；HTTP 状态由 E2E.API 解释
extension APIClient: E2ETransport {
    func e2eSend(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> E2E.Response {
        var r = request(path, query: query, method: method)
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
        }
        let (data, resp) = try await Self.apiSession.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw APIError.invalid("非 HTTP 响应") }
        if let v = h.legacyHeader("Server") { ServerVersionSeen.note(v) }
        return E2E.Response(status: h.statusCode, data: data, contentType: h.value(forHTTPHeaderField: "Content-Type") ?? "")
    }
}

extension HTTPURLResponse {
    /// 回笺响应头 X-Huijian-<name>；连到改名前的旧服务端时读 X-Hongyan-<name>
    func legacyHeader(_ name: String) -> String? {
        value(forHTTPHeaderField: "X-Huijian-" + name) ?? value(forHTTPHeaderField: "X-Hongyan-" + name)
    }
}
