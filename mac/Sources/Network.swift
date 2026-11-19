import Foundation

/// 网络代理设置。很多人本地开了代理（例如 127.0.0.1:7890），更新包和境外服务器走代理会快很多。
/// 两个作用范围可以分别勾选：应用更新、服务器连接（消息与附件）。
struct ProxyConfig: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case http, socks5
        var label: String { self == .http ? "HTTP" : "SOCKS5" }
    }

    var enabled = false
    var kind: Kind = .http
    var host = "127.0.0.1"
    var port = 7890
    var forUpdates = true
    var forServer = false

    static let storageKey = "huijian.proxy"

    static func load(_ d: UserDefaults) -> ProxyConfig {
        guard let data = d.data(forKey: storageKey), let c = try? JSONDecoder().decode(ProxyConfig.self, from: data) else {
            return ProxyConfig()
        }
        return c
    }

    func save(_ d: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.storageKey) }
    }

    var valid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(port)
    }

    func applies(to scope: NetScope) -> Bool {
        guard enabled, valid else { return false }
        return scope == .updates ? forUpdates : forServer
    }

    /// URLSessionConfiguration.connectionProxyDictionary；不走自定义代理时返回 nil，按系统网络设置（含系统代理 / PAC）
    func dictionary(for scope: NetScope) -> [AnyHashable: Any]? {
        guard applies(to: scope) else { return nil }
        let h = host.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .http:
            return [kCFNetworkProxiesHTTPEnable: 1, kCFNetworkProxiesHTTPProxy: h, kCFNetworkProxiesHTTPPort: port,
                    kCFNetworkProxiesHTTPSEnable: 1, kCFNetworkProxiesHTTPSProxy: h, kCFNetworkProxiesHTTPSPort: port]
        case .socks5:
            return [kCFNetworkProxiesSOCKSEnable: 1, kCFNetworkProxiesSOCKSProxy: h, kCFNetworkProxiesSOCKSPort: port]
        }
    }

    var summary: String { "\(kind.label) \(host):\(port)" }
}

enum NetScope { case server, updates }

/// 按作用范围和代理设置创建 URLSession。代理设置变化时整体重建（旧会话上的请求会正常完成）。
final class NetSessions: @unchecked Sendable {
    static let shared = NetSessions()

    private let lock = NSLock()
    private var proxy = ProxyConfig()
    private var cache: [String: URLSession] = [:]

    var currentProxy: ProxyConfig {
        lock.lock(); defer { lock.unlock() }
        return proxy
    }

    func update(_ p: ProxyConfig) {
        lock.lock()
        let old = cache
        proxy = p
        cache = [:]
        lock.unlock()
        // 延迟失效：其他线程可能刚取到旧会话、还没创建任务，立即失效会导致创建任务时崩溃。
        // finishTasksAndInvalidate 会让已经开始的请求（例如长轮询）正常完成。
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { old.values.forEach { $0.finishTasksAndInvalidate() } }
    }

    enum Kind: String { case api, poll, stream }

    func session(_ kind: Kind, _ scope: NetScope) -> URLSession {
        let key = "\(kind.rawValue)-\(scope == .server ? "s" : "u")"
        lock.lock(); defer { lock.unlock() }
        if let s = cache[key] { return s }
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.connectionProxyDictionary = proxy.dictionary(for: scope)
        switch kind {
        case .api:
            c.timeoutIntervalForRequest = 30
        case .poll:
            // 长轮询：等待时长自适应（Heartbeat.swift，最多 10 分钟）；每个请求再单独设 timeoutInterval = wait + 20 秒。
            // 整个请求的总时长上限要比服务端可配置的最大挂起时间（3600 秒）还长，否则会被会话本身切断
            c.timeoutIntervalForRequest = 70
            c.timeoutIntervalForResource = 3700
            c.urlCache = nil
        case .stream:
            c.timeoutIntervalForRequest = 60
            c.timeoutIntervalForResource = 7 * 24 * 3600
        }
        let s = URLSession(configuration: c)
        cache[key] = s
        return s
    }

    /// 下载引擎用的配置
    func downloadConfiguration(_ scope: NetScope) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.connectionProxyDictionary = currentProxy.dictionary(for: scope)
        return c
    }
}

/// 自动下载附件的阈值（MB）。0 = 关闭，-1 = 不限。
enum AutoDownload {
    static let defaultLimitMB = 10
    static let options: [(Int, String)] = [(0, "关闭"), (1, "1 MB"), (10, "10 MB"), (50, "50 MB"), (100, "100 MB"), (-1, "不限")]

    /// 是否应该自动下载：未下载、大小在阈值内、消息还在缓存保留期内（否则下载完马上会被清理）
    static func should(_ att: Attachment, messageDate: Date, limitMB: Int, retentionHours: Int,
                       alreadyLocal: Bool, now: Date = Date()) -> Bool {
        guard limitMB != 0, !alreadyLocal else { return false }
        if limitMB > 0, att.size > Int64(limitMB) << 20 { return false }
        return now.timeIntervalSince(messageDate) < Double(retentionHours) * 3600
    }
}
