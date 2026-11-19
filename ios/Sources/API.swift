import CryptoKit
import Foundation

enum APIError: Error, LocalizedError, Equatable {
    /// 设备 token 失效（设备被移除、退出登录）
    case unauthorized
    case http(Int, String)
    /// 服务端没有这个接口（版本较旧）
    case unsupported
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "登录已失效，请重新登录"
        case .unsupported: return "服务端版本较旧，不支持这个功能，更新服务端后可用"
        // 服务端返回的中文说明直接给用户看；代理返回的 HTML 错误页之类只显示状态码
        case .http(let c, let m):
            let plain = !m.isEmpty && !m.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
            if !plain { return "请求失败（HTTP \(c)）" }
            return c >= 500 && c != 502 ? "服务器出错（HTTP \(c)）：\(m)" : m
        case .invalid(let m): return m
        }
    }
}

struct LoginResult: Decodable {
    let device_id: String
    let name: String
    let token: String
}

struct MessagePage {
    let messages: [Message]
    /// 服务端已经扫过的位置（0.5.0 起）
    let nextSince: Int64?
    /// 响应头 X-Huijian-Latest-Build：服务端上本平台最新的构建号
    let latestBuild: Int?
    /// 带 changes_since 时：之后的删除 / 归档 / 频道设置变更（0.5.4 起）
    var changes: [MsgChange] = []
    var changesNext: Int64?
    var changesReset = false
    var changesEpoch: String?
}

/// 同账号其他设备的操作：delete / archive（state 0/1/2）/ channels
struct MsgChange: Decodable, Equatable {
    let seq: Int64?
    let id: Int64
    let kind: String
    let state: Int?
}

struct Me: Decodable {
    let device_id: String
    let name: String
    let account: Account?
    /// 账号的 Bark 转发配置；旧服务端没有这个字段，未配置时为 null
    let bark: BarkConfig?
    /// 这台设备有没有服务器管理权限（管理后台「设备」页的「允许管理」）
    var can_admin: Bool? = nil

    struct Account: Decodable {
        let id: Int64?
        let username: String?
        var has_password: Bool? = nil
    }
}

struct PushKey: Decodable, Identifiable, Hashable {
    let id: Int64
    let name: String
    let key: String
    let revoked: Bool?
    var created_at: Date? = nil
    var last_used: Date? = nil

    var isRevoked: Bool { revoked ?? false }
}

/// 回笺设备接口（../docs/api.md）。所有方法都是 async，Task 取消时底层请求一并取消。
struct API {
    let server: URL
    let token: String?

    /// 普通请求和长轮询共用一个会话；超时按请求单独设置。
    /// 所有请求都过 SameOriginRedirects：跨主机（协议、主机、端口任何一项不同）的跳转一律拒绝，登录 token 不会被带到别处
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c, delegate: SameOriginRedirects(), delegateQueue: nil)
    }()

    /// 跳转前后是不是同一个源（协议 + 主机 + 端口，没写端口按协议默认端口）
    static func sameOrigin(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b, let sa = a.scheme?.lowercased(), let sb = b.scheme?.lowercased(),
              let ha = a.host?.lowercased(), let hb = b.host?.lowercased() else { return false }
        func port(_ u: URL, _ scheme: String) -> Int? { u.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil) }
        return sa == sb && ha == hb && port(a, sa) == port(b, sb)
    }

    final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            // 拒绝时任务以这个 3xx 响应结束，调用方按 HTTP 错误处理
            completionHandler(API.sameOrigin(task.originalRequest?.url ?? response.url, request.url) ? request : nil)
        }
    }

    // MARK: 地址

    /// 规范化服务器地址：去空白和末尾斜杠；没写协议时，IP / localhost 用 http，域名用 https（与 Mac、安卓一致）
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty { return s }
        if !s.contains("://") {
            let hostPort = s.split(separator: "/", maxSplits: 1).first.map(String.init) ?? s
            let host = hostPort.split(separator: ":").first.map(String.init) ?? hostPort
            let isIPv4 = host.split(separator: ".").count == 4 && host.split(separator: ".").allSatisfy { Int($0) != nil }
            let plain = host == "localhost" || host.hasSuffix(".local") || isIPv4 || s.hasPrefix("[")
            s = (plain ? "http://" : "https://") + s
        }
        return s
    }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        let base = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = base + path
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", timeout: TimeInterval = 30) -> URLRequest {
        var r = URLRequest(url: url(path, query: query))
        r.httpMethod = method
        r.timeoutInterval = timeout
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.setValue("huijian-ios/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        r.setValue(AppInfo.clientLabel, forHTTPHeaderField: "X-Huijian-Client")
        r.setValue(AppInfo.clientLabel, forHTTPHeaderField: "X-Hongyan-Client") // 改名前的服务端只认旧名
        return r
    }

    static func errorMessage(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = obj["error"] as? String {
            return e
        }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }

    /// 检查响应。authed=false（登录、配对）时 401 不算「登录失效」，按普通错误显示服务端的说明
    static func check(_ resp: URLResponse, _ data: Data, authed: Bool = true) throws -> HTTPURLResponse {
        guard let h = resp as? HTTPURLResponse else { throw APIError.invalid("非 HTTP 响应") }
        if h.statusCode == 401 && authed { throw APIError.unauthorized }
        if isMissingRoute(h, data) { throw APIError.unsupported }
        if (300...399).contains(h.statusCode) {
            // 跨源跳转被 SameOriginRedirects 拒绝（比如 http 跳到 https、换了域名）
            let to = h.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: h.url)?.absoluteURL }
            throw APIError.invalid("服务器要求跳转到" + (to.map { " \($0.scheme ?? "")://\($0.host ?? "")\($0.port.map { ":\($0)" } ?? "")" } ?? "别的地址")
                                   + "，为了不把登录凭证带到别处，回笺不跟随跨地址跳转。请把服务器地址改成跳转后的地址")
        }
        if !(200...299).contains(h.statusCode) { throw APIError.http(h.statusCode, errorMessage(data)) }
        return h
    }

    /// 旧版服务端没有这个接口：Go 路由层返回纯文本的 404「not found」或 405。业务上的 404 都带 {"error":…}
    static func isMissingRoute(_ h: HTTPURLResponse, _ data: Data) -> Bool {
        guard h.statusCode == 404 || h.statusCode == 405 else { return false }
        if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] != nil { return false }
        let ct = (h.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if ct.contains("html") { return false }
        let body = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return h.statusCode == 405 || body == "not found" || body == "404 page not found"
    }

    @discardableResult
    func send(_ path: String, method: String = "GET", query: [URLQueryItem] = [], json: Any? = nil,
              timeout: TimeInterval = 30, authed: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var r = request(path, query: query, method: method, timeout: timeout)
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, resp) = try await API.session.data(for: r)
        return (data, try API.check(resp, data, authed: authed))
    }

    func decode<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET", query: [URLQueryItem] = [],
                              json: Any? = nil, authed: Bool = true) async throws -> T {
        let (data, _) = try await send(path, method: method, query: query, json: json, authed: authed)
        do { return try JSONCoding.decoder.decode(T.self, from: data) } catch { throw APIError.invalid("服务器返回的数据格式不对") }
    }

    // MARK: 登录

    func info() async throws -> ServerInfo { try await decode(ServerInfo.self, "/v1/info", authed: false) }

    /// 旧登录协议（发送密码原文）。App 登录已改走 E2E.login（新登录协议，docs/e2ee-client.md §2），这里只留给自检准备测试账号
    func login(username: String, password: String, name: String, fingerprint: String) async throws -> LoginResult {
        try await decode(LoginResult.self, "/v1/login", method: "POST", json: [
            "username": username, "password": password, "name": name, "platform": "ios", "fingerprint": fingerprint,
        ], authed: false)
    }

    func pair(code: String, name: String, fingerprint: String) async throws -> LoginResult {
        try await decode(LoginResult.self, "/v1/pair", method: "POST", json: [
            "code": code, "name": name, "platform": "ios", "fingerprint": fingerprint,
        ], authed: false)
    }

    func logout() async throws { try await send("/v1/logout", method: "POST", timeout: 10) }

    func me() async throws -> Me { try await decode(Me.self, "/v1/me") }

    // MARK: 消息

    /// 拉取 id > since 的消息；since 为 nil 时返回最新的 limit 条。wait > 0 时是长轮询（服务端上限见 /v1/info 的 long_poll_max，旧服务端 55 秒）。
    /// changesSince 不为 nil 时一并返回之后的删除 / 归档变更（有新变更也会立即唤醒长轮询）
    func messages(since: Int64?, limit: Int = 200, wait: Int = 0, changesSince: Int64? = nil) async throws -> MessagePage {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let since { q.append(URLQueryItem(name: "since", value: String(since))) }
        if wait > 0 { q.append(URLQueryItem(name: "wait", value: String(wait))) }
        if let changesSince { q.append(URLQueryItem(name: "changes_since", value: String(changesSince))) }
        // 长轮询：超时 = wait + 20 秒，比服务端挂起的时间长，又能及时发现静默断开的连接（wait 见 Heartbeat.swift）
        let (data, h) = try await send("/v1/messages", query: q, timeout: wait > 0 ? TimeInterval(wait + 20) : 30)
        struct R: Decodable {
            let messages: [Message]?
            let next_since: Int64?
            let changes: [MsgChange]?
            let changes_next: Int64?
            let changes_reset: Bool?
            let changes_epoch: String?
        }
        let r: R
        do { r = try JSONCoding.decoder.decode(R.self, from: data) } catch { throw APIError.invalid("服务器返回的消息格式不对") }
        // 解密状态、附件钥匙只能由本机写入：服务端带来的一律丢弃
        let msgs = (r.messages ?? []).map { m -> Message in var x = m; x.dropLocalFields(); return x }
        return MessagePage(messages: msgs, nextSince: r.next_since,
                           latestBuild: h.legacyHeader("Latest-Build").flatMap { Int($0) },
                           changes: r.changes ?? [], changesNext: r.changes_next, changesReset: r.changes_reset ?? false,
                           changesEpoch: (r.changes_epoch?.isEmpty ?? true) ? nil : r.changes_epoch)
    }

    /// 对账：本账号全部消息的归档状态（id → archive）、变更游标、服务端数据纪元
    func messageStates() async throws -> (states: [Int64: Int], next: Int64, epoch: String?) {
        struct R: Decodable { let items: [[Int64]]?; let changes_next: Int64?; let epoch: String? }
        let r = try await decode(R.self, "/v1/messages/state")
        var states: [Int64: Int] = [:]
        for it in r.items ?? [] where !it.isEmpty { states[it[0]] = it.count > 1 ? Int(it[1]) : 0 }
        return (states, r.changes_next ?? 0, (r.epoch?.isEmpty ?? true) ? nil : r.epoch)
    }

    /// 频道设置（服务端 0.5.5 起）；旧服务端没有这个接口时返回空
    func channels() async throws -> [ChannelSetting] {
        struct R: Decodable { let channels: [ChannelSetting]? }
        do { return try await decode(R.self, "/v1/channels").channels ?? [] } catch APIError.unsupported { return [] }
    }

    // MARK: pushkey 与测试推送

    func keys() async throws -> [PushKey] {
        struct R: Decodable { let keys: [PushKey]? }
        return try await decode(R.self, "/v1/keys").keys ?? []
    }

    func createKey(name: String) async throws -> PushKey {
        try await decode(PushKey.self, "/v1/keys", method: "POST", json: ["name": name])
    }

    /// 用本账号的一把 pushkey 给自己发一条消息（走公开的发送接口）
    func push(pushkey: String, text: String, desp: String, priority: Int, topic: String) async throws {
        var r = request("/message/push", method: "POST")
        r.setValue(nil, forHTTPHeaderField: "Authorization")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "pushkey", value: pushkey), URLQueryItem(name: "text", value: text),
                            URLQueryItem(name: "desp", value: desp), URLQueryItem(name: "priority", value: String(priority)),
                            URLQueryItem(name: "topic", value: topic)]
        // URLComponents 不转义 +，表单里 + 会被当成空格
        r.httpBody = Data((comps.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, resp) = try await API.session.data(for: r)
        _ = try API.check(resp, data, authed: false)
    }

    // MARK: Bark 转发

    /// 保存 Bark 推送地址；url 为空表示关闭。cipherKey / cipherIV 为空表示不加密
    func putBark(url: String, cipherKey: String, cipherIV: String) async throws -> BarkConfig? {
        let (data, _) = try await send("/v1/bark", method: "PUT", json: ["url": url, "cipher_key": cipherKey, "cipher_iv": cipherIV])
        let c = try? JSONCoding.decoder.decode(BarkConfig.self, from: data)
        return (c?.url.isEmpty ?? true) ? nil : c
    }

    func testBark() async throws { try await send("/v1/bark/test", method: "POST", timeout: 20) }

    // MARK: 更新

    func update(build: Int) async throws -> UpdateInfo? {
        struct R: Decodable { let update: UpdateInfo? }
        return try await decode(R.self, "/v1/update", query: [URLQueryItem(name: "build", value: String(build))]).update
    }

    /// 下载新版 IPA（GET /v1/update/<id>，带登录 token）到 dest，边下边报进度（0–1）。
    /// 只负责下载和大小检查，sha256 / 签名由 UpdatePackage.verify 校验
    func downloadUpdate(_ u: UpdateInfo, to dest: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let path = u.url, path.hasPrefix("/v1/update/") else { throw APIError.invalid("更新信息里没有下载地址") }
        let maxBytes: Int64 = 500 << 20
        let (bytes, resp) = try await API.session.bytes(for: request(path, timeout: 60))
        if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 65536 { break } }
            _ = try API.check(resp, body)
            throw APIError.invalid("下载失败（HTTP \(h.statusCode)）")
        }
        let total = resp.expectedContentLength > 0 ? resp.expectedContentLength : (u.size ?? 0)
        if total > maxBytes { throw APIError.invalid("更新包太大（\(humanSize(total))）") }
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        guard fm.createFile(atPath: dest.path, contents: nil) else { throw APIError.invalid("不能写临时文件") }
        let h = try FileHandle(forWritingTo: dest)
        var ok = false
        defer {
            try? h.close()
            if !ok { try? fm.removeItem(at: dest) }
        }
        var buf = Data()
        buf.reserveCapacity(256 << 10)
        var written: Int64 = 0
        var lastPct = -1
        for try await b in bytes {
            buf.append(b)
            if buf.count >= 256 << 10 {
                try Task.checkCancellation()
                try h.write(contentsOf: buf)
                written += Int64(buf.count)
                buf.removeAll(keepingCapacity: true)
                if written > maxBytes { throw APIError.invalid("更新包太大") }
                if total > 0 {
                    let pct = Int(Double(written) / Double(total) * 100)
                    if pct != lastPct { lastPct = pct; progress(min(Double(written) / Double(total), 1)) }
                }
            }
        }
        try h.write(contentsOf: buf)
        written += Int64(buf.count)
        if let size = u.size, size > 0, written != size { throw APIError.invalid("下载不完整（\(humanSize(written)) / \(humanSize(size))）") }
        progress(1)
        ok = true
    }

    // MARK: 附件

    /// 下载附件到 dest 并校验 sha256（响应头 X-Huijian-Sha256，没有时用消息里的值）；失败时不留半成品
    func download(_ att: Attachment, to dest: URL) async throws {
        // 附件 id 原样交给 URLComponents.path，由它做一次转义（先手动转义会变成 %2520）
        let r = request("/v1/att/\(att.id)", timeout: 60)
        let (tmp, resp) = try await API.session.download(for: r)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
            _ = try API.check(resp, (try? Data(contentsOf: tmp)) ?? Data())
        }
        let want = ((resp as? HTTPURLResponse)?.legacyHeader("Sha256") ?? att.sha256).lowercased()
        let got = try API.sha256(of: tmp)
        if !want.isEmpty && got != want { throw APIError.invalid("附件校验失败（sha256 不一致）") }
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
    }

    /// 流式计算文件的 sha256（大附件不整个读进内存）
    static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 端到端加密的网络接入（E2E.swift）：照常带设备凭证、走同源跳转限制；HTTP 状态不在这里抛错，由 E2E.API 解释
extension API: E2ETransport {
    func e2eSend(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> E2E.Response {
        var r = request(path, query: query, method: method)
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
        }
        let (data, resp) = try await API.session.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw APIError.invalid("非 HTTP 响应") }
        return E2E.Response(status: h.statusCode, data: data, contentType: h.value(forHTTPHeaderField: "Content-Type") ?? "")
    }
}

/// 网络错误的简短中文说明（连接状态、重连提示用）
func shortError(_ e: Error) -> String {
    if let a = e as? APIError { return a.errorDescription ?? "请求失败" }
    if let u = e as? URLError {
        switch u.code {
        case .notConnectedToInternet: return "没有网络"
        case .cannotFindHost, .dnsLookupFailed: return "找不到服务器（DNS）"
        case .cannotConnectToHost: return "连不上服务器"
        case .timedOut: return "超时"
        case .networkConnectionLost: return "连接中断"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return "HTTPS 证书有问题"
        case .appTransportSecurityRequiresSecureConnection: return "系统不允许 http 连接"
        case .cancelled: return "连接已重置"
        default: return "网络错误（\(u.code.rawValue)）"
        }
    }
    return e.localizedDescription
}

extension Error {
    var isUnauthorized: Bool { (self as? APIError) == .unauthorized }
}

/// 请求被取消（切到后台、网络变化时主动取消）
func isCancellation(_ e: Error) -> Bool {
    if e is CancellationError { return true }
    if let u = e as? URLError, u.code == .cancelled { return true }
    return false
}

extension HTTPURLResponse {
    /// 回笺响应头 X-Huijian-<name>；连到改名前的旧服务端时读 X-Hongyan-<name>
    func legacyHeader(_ name: String) -> String? {
        value(forHTTPHeaderField: "X-Huijian-" + name) ?? value(forHTTPHeaderField: "X-Hongyan-" + name)
    }
}
