import AppKit
import Foundation
import QuickLookThumbnailing
import ServiceManagement
import UserNotifications

enum ConnState: Equatable {
    case unpaired
    case connecting
    case connected
    case reconnecting(String)
    case unauthorized

    var label: String {
        switch self {
        case .unpaired: return "未配对"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .reconnecting(let e): return "重连中（\(e)）"
        case .unauthorized: return "设备已失效，请重新配对"
        }
    }
}

enum Filter: Hashable {
    case all, unread, important, starred, attachments, archived
    case topic(String)
}

/// 消息归档状态（与服务端 messages.archive 一致）
enum ArchiveState {
    static let auto = 0      // 超过设定天数自动归档（收藏的除外）
    static let archived = 1  // 手动归档
    static let keep = 2      // 保留在收件箱，不再自动归档
}

/// 线程：同一 topic+thread 的消息折叠为一组；没有 thread 的消息单独成组。
struct ThreadGroup: Identifiable, Equatable {
    let id: String
    let messages: [Message]      // 当前筛选下属于该组的消息，按 id 升序
    let total: Int               // 该线程全部消息数（不受筛选影响）
    let unread: Int
    var latest: Message { messages.last! }
    var isThread: Bool { id.hasPrefix("t:") }
    var attachmentCount: Int { messages.reduce(0) { $0 + $1.attachments.count } }
    /// 列表的视觉优先级：有未读时取未读中最高的，否则取最新一条的
    let displayPriority: Int
}

func threadKey(_ m: Message) -> String {
    m.thread.isEmpty ? "m:\(m.id)" : "t:\(m.topic)\u{1}\(m.thread)"
}

/// 将消息分组为线程（输入任意顺序），按最新消息倒序返回。
func groupThreads(_ list: [Message], all: [Message], read: Set<Int64>) -> [ThreadGroup] {
    var totals: [String: Int] = [:]
    for m in all { totals[threadKey(m), default: 0] += 1 }
    var buckets: [String: [Message]] = [:]
    for m in list { buckets[threadKey(m), default: []].append(m) }
    return buckets.map { key, ms in
        let sorted = ms.sorted { $0.id < $1.id }
        let unreadMs = sorted.filter { !read.contains($0.id) }
        let prio = unreadMs.isEmpty ? sorted.last!.priority : unreadMs.map(\.priority).max()!
        return ThreadGroup(id: key, messages: sorted, total: totals[key] ?? sorted.count,
                           unread: unreadMs.count, displayPriority: prio)
    }
    .sorted { $0.latest.id > $1.latest.id }
}

/// 通知偏好（按优先级 P0…P5）
struct NotifyPrefs: Codable, Equatable {
    var show: [Bool] = [false, false, false, true, true, true]
    var sound: [Bool] = [false, false, false, false, true, true]
    var quietEnabled = false
    var quietStart = 23
    var quietEnd = 8

    func inQuiet(_ d: Date) -> Bool {
        guard quietEnabled, quietStart != quietEnd else { return false }
        let h = Calendar.current.component(.hour, from: d)
        return quietStart < quietEnd ? (h >= quietStart && h < quietEnd) : (h >= quietStart || h < quietEnd)
    }

    /// 返回 (是否弹出, 是否响铃)。暂停或免打扰期间只放行 P5。
    func decide(priority p: Int, now: Date, pausedUntil: Date?) -> (Bool, Bool) {
        let lvl = max(0, min(5, p))
        if let u = pausedUntil, u > now, lvl < 5 { return (false, false) }
        if inQuiet(now), lvl < 5 { return (false, false) }
        let s = show[lvl]
        return (s, s && sound[lvl])
    }
}

@MainActor
final class AppModel: ObservableObject {
    /// 正常启动用标准目录；`--demo <server> <token> <workdir>` 用于隔离的 GUI 测试
    /// （数据写测试目录、token 直接注入、不碰钥匙串、不请求通知权限、偏好写独立 suite）。
    static let shared: AppModel = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--demo"), i + 3 < a.count {
            let dir = URL(fileURLWithPath: a[i + 3])
            let suite = "io.github.hongyile.huijian.demo"
            UserDefaults().removePersistentDomain(forName: suite)
            let m = AppModel(paths: AppPaths(supportDir: dir.appendingPathComponent("support"),
                                             cacheDir: dir.appendingPathComponent("cache")),
                             keychainService: "io.github.hongyile.huijian.demo", loadToken: false,
                             defaults: UserDefaults(suiteName: suite)!)
            m.useToken(a[i + 2], server: a[i + 1])
            m.notificationsEnabled = false
            m.isDemo = true
            m.deviceName = "我的 MacBook"
            return m
        }
        return AppModel(paths: .standard)
    }()
    private(set) var isDemo = false

    @Published private(set) var messages: [Message] = [] { didSet { archGen &+= 1 } }  // 按 id 升序
    @Published var read: Set<Int64> = []
    @Published var starred: Set<Int64> = [] { didSet { archGen &+= 1 } }
    /// 频道设置（显示名、隐藏、静音、置顶、顺序），账号内所有设备共用；本机缓存一份，离线启动也能显示
    @Published private(set) var channelSettings: [String: APIClient.ChannelSetting] = [:] {
        didSet {
            archGen &+= 1
            if let d = try? JSONEncoder().encode(Array(channelSettings.values)) { defaults.set(d, forKey: Self.key("channelSettings")) }
        }
    }
    @Published var state: ConnState = .unpaired
    @Published var server: String
    @Published var filter: Filter = .all
    @Published var searchText = ""
    @Published var minPriority: Int? = nil
    @Published var selectedThread: String?
    @Published var focusedMessage: Int64?
    @Published var progress: [String: Double] = [:]
    @Published var downloadErrors: [String: String] = [:]
    @Published var localFiles: [String: URL] = [:]
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var previewURL: URL?
    @Published var scrollTarget: String?

    // 账户信息（来自 /v1/me）
    @Published var canAdmin: Bool?
    @Published var deviceName: String
    @Published var adminMessage: String?

    // 账号（来自 /v1/me）
    @Published var account: APIClient.AccountInfo?
    /// 我在用其他设备时，本机不响（紧急消息除外）
    @Published private(set) var awaySilent = true
    private var presenceTimer: Timer?

    // 服务端版本与功能（来自 /v1/info）
    @Published private(set) var serverInfo: APIClient.ServerInfo?
    /// 服务端没有 /v1/info（低于 0.5.0）
    @Published private(set) var serverLegacy = false
    private var infoTask: Task<Void, Never>?

    /// 附件保存位置（默认 Caches/Huijian/att）
    @Published private(set) var attachmentDir: URL
    var attachmentDirIsDefault: Bool { attachmentDir.standardizedFileURL == paths.attDir.standardizedFileURL }

    // 偏好
    @Published var prefs: NotifyPrefs { didSet { savePrefs() } }
    @Published var retentionHours: Int { didSet { defaults.set(retentionHours, forKey: Self.key("retentionHours")) } }
    /// 超过多少天的消息自动归档（收藏的除外）；0 = 不自动归档
    @Published var archiveDays: Int { didSet { archGen &+= 1; defaults.set(archiveDays, forKey: Self.key("archiveDays")) } }
    static let archiveOptions = [7, 30, 90, 365, 0]
    /// 删除 / 归档出错时的提示（界面弹窗显示）
    @Published var manageError: String?
    /// 等待确认的删除
    @Published var deleteRequest: DeleteRequest?
    /// 清理消息面板（nil = 不显示）
    @Published var cleanupRule: CleanupRule?
    @Published var pausedUntil: Date? { didSet { defaults.set(pausedUntil, forKey: Self.key("pausedUntil")) } }
    /// 自动下载附件的大小上限（MB）：0 关闭，-1 不限
    @Published var autoDownloadLimitMB: Int { didSet { defaults.set(autoDownloadLimitMB, forKey: Self.key("autoDownloadMB")) } }
    @Published private(set) var proxy: ProxyConfig

    // 端到端加密（接线见 E2EModel.swift，逻辑见 E2E.swift）
    /// GET /v1/e2e 的最近结果；nil = 还没取到（或服务端不支持）
    @Published var e2eState: E2E.State?
    /// 本机为当前账号保存的私钥（从钥匙串读出）
    @Published var e2eKeys: [String] = []
    /// 钥匙串读写失败的原因（加密页显示）
    @Published var e2eStorageError: String?
    /// 登录时关于加密的一句提示（例如私钥对不上 T43），加密页显示
    @Published var e2eLoginNote: String?
    /// 登录时解开、但还没取到账号 id 没法保存的私钥（只在内存里，loadE2EKeys 时保存）
    var e2ePendingLoginKey: (sk: String, keys: [E2E.Key])?
    /// 开启加密的结果提示（结果不确定 / 上次没成功，§4.1）；进行中的开启本身存在钥匙串（KeyRing.pendingSetup）
    @Published var e2eSetupNote: String?
    /// 更换恢复码结果不确定时的提示（§7 第 3 项）；新恢复码本身存在钥匙串（KeyRing.pendingRecovery）
    @Published var e2eRecoveryNote: String?
    /// 刚生成的恢复码（开启加密或更换后）：放在 App 状态里，关掉设置窗口再打开还在，用户点「完成」才清除
    @Published var e2eRecoveryCode: String?
    @Published var e2eRecoveryFromSetup = false
    /// 本机正在请求其他设备批准（§4.3）
    @Published var e2eRequest: E2E.ApprovalRequest?
    @Published var e2eRequestPhase: E2E.ApprovalRequest.Phase?
    /// 正在批准的其他设备（§5），按 device_id
    @Published var e2eApprovals: [String: E2E.Approval] = [:]
    @Published var e2eApprovalPhases: [String: E2E.Approval.Phase] = [:]
    /// 加密钥匙的安全存储：正常运行用钥匙串；自检、演示用内存（不碰钥匙串）
    let e2eSecrets: E2ESecrets
    var e2eRefreshing = false
    var e2eRefreshAgain = false
    var e2eDecrypting = false
    /// 解密进行中又有人要求重新解密：这一轮结束后再跑一轮
    var e2eDecryptAgain = false
    private var activeObserver: NSObjectProtocol?

    let paths: AppPaths
    let cache: AttachmentCache
    let engine = DownloadEngine()
    /// 更新包下载走「应用更新」代理范围，和附件下载分开
    let updateEngine = DownloadEngine(scope: .updates)
    lazy var updater = Updater(defaults: defaults, workDir: paths.cacheDir.appendingPathComponent("updates"),
                               engine: updateEngine, client: { [weak self] in self?.client })
    let keychainService: String
    let defaults: UserDefaults
    var notificationsEnabled = true
    private(set) var token: String?
    private var syncTask: Task<Void, Never>?
    private var cleanupTimer: Timer?

    /// 配对窗口预填的服务器地址，构建时由 build.sh 的 DEFAULT_SERVER 写进 Info.plist
    static let defaultServer = (Bundle.main.object(forInfoDictionaryKey: "HuijianDefaultServer") as? String) ?? ""

    /// 规范化服务器地址：去空白和末尾斜杠；没写协议时，IP 地址、localhost、*.local 按 http（公网 IP 直连的部署），
    /// 域名（不论是否带端口）按 https
    nonisolated static func normalizeServer(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        if !t.isEmpty && !t.contains("://") {
            let hostPort = String(t.split(separator: "/", maxSplits: 1).first ?? "")
            let host = String(hostPort.split(separator: ":").first ?? "").lowercased()
            let isIPv4 = host.split(separator: ".").count == 4 && host.allSatisfy { $0.isNumber || $0 == "." }
            let plain = isIPv4 || host == "localhost" || host.hasSuffix(".local")
            t = (plain ? "http://" : "https://") + t
        }
        return t
    }

    /// 明文 http 连公网地址时给出提示；内网、本机地址不提示
    nonisolated static func insecureNotice(_ s: String) -> String? {
        guard let u = URL(string: normalizeServer(s)), u.scheme == "http", let h = u.host?.lowercased() else { return nil }
        if h == "localhost" || h.hasSuffix(".local") || h.hasPrefix("127.") || h.hasPrefix("10.") || h.hasPrefix("192.168.") {
            return nil
        }
        let p = h.split(separator: ".").compactMap { Int($0) }
        if p.count == 4, (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 100 && (64...127).contains(p[1])) { return nil }
        return "这是明文 http 连接：消息内容和设备凭证可能在网络上被窃听。有域名时建议在服务器上配置 HTTPS。"
    }
    /// UserDefaults 键统一加 huijian. 前缀
    nonisolated static func key(_ k: String) -> String { "huijian." + k }

    init(paths: AppPaths, keychainService: String = Keychain.defaultService, loadToken: Bool = true,
         defaults: UserDefaults = .standard) {
        _ = NetKind.shared      // 尽早开始监听网络，第一轮长轮询就知道是 Wi-Fi 还是有线
        self.paths = paths
        self.keychainService = keychainService
        self.defaults = defaults
        e2eSecrets = loadToken ? KeychainSecrets(service: keychainService + ".e2e") : E2E.MemorySecrets()
        let s = Persistence.load(paths.messagesFile)
        messages = s.messages.sorted { $0.id < $1.id }
        read = s.read
        starred = s.starred
        server = defaults.string(forKey: Self.key("server")) ?? Self.defaultServer
        deviceName = defaults.string(forKey: Self.key("deviceName")) ?? (Host.current().localizedName ?? "我的 Mac")
        if let d = defaults.data(forKey: Self.key("notifyPrefs")), let p = try? JSONDecoder().decode(NotifyPrefs.self, from: d) {
            prefs = p
        } else {
            prefs = NotifyPrefs()
        }
        let r = defaults.integer(forKey: Self.key("retentionHours"))
        retentionHours = r == 0 ? 24 : r          // -1 = 永久保留
        archiveDays = defaults.object(forKey: Self.key("archiveDays")) as? Int ?? 30
        if let d = defaults.data(forKey: Self.key("channelSettings")),
           let cs = try? JSONDecoder().decode([APIClient.ChannelSetting].self, from: d) {
            channelSettings = Dictionary(cs.map { ($0.topic, $0) }, uniquingKeysWith: { a, _ in a })
        }
        autoDownloadLimitMB = defaults.object(forKey: Self.key("autoDownloadMB")) as? Int ?? AutoDownload.defaultLimitMB
        let px = ProxyConfig.load(defaults)
        proxy = px
        NetSessions.shared.update(px)
        engine.reloadProxy()          // 两个下载引擎是存储属性，创建时代理配置还没加载
        updateEngine.reloadProxy()
        pausedUntil = defaults.object(forKey: Self.key("pausedUntil")) as? Date
        let attDir = defaults.string(forKey: Self.key("attachmentDir")).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? paths.attDir
        attachmentDir = attDir
        cache = AttachmentCache(baseDir: attDir, indexFile: paths.cacheDir.appendingPathComponent("att-index.json"))
        if loadToken { token = Keychain.load(service: keychainService) }
        state = token == nil ? .unpaired : .connecting
        refreshLocalFiles()
    }

    private func savePrefs() {
        if let d = try? JSONEncoder().encode(prefs) { defaults.set(d, forKey: Self.key("notifyPrefs")) }
    }

    // MARK: 派生数据

    var maxID: Int64 { messages.last?.id ?? 0 }
    /// 服务端返回的扫描位置（next_since）：本机「不接收」的消息也算扫过，长轮询从这里继续
    private var serverCursor: Int64 = 0
    private var syncCursor: Int64 { max(maxID, serverCursor) }
    /// 归档里的消息不计入未读
    var unreadCount: Int { inbox.reduce(0) { $0 + (read.contains($1.id) ? 0 : 1) } }
    var hasUnreadCritical: Bool { inbox.contains { $0.priority >= 5 && !read.contains($0.id) } }

    /// 单条消息是否算归档：手动归档的算；保留在收件箱的不算；其余超过设定天数且没收藏的算
    func isArchived(_ m: Message, now: Date = Date()) -> Bool {
        switch m.archive {
        case ArchiveState.archived: return true
        case ArchiveState.keep: return false
        default:
            guard archiveDays > 0, !starred.contains(m.id) else { return false }
            return now.timeIntervalSince(m.createdAt) > Double(archiveDays) * 86400
        }
    }

    /// 归档的会话：线程里每条都算归档时整个线程归档（线程来了新消息就回到收件箱）。
    /// 界面一次渲染会用到很多次，结果缓存起来：消息 / 收藏 / 自动归档天数变化时，或者过了整点，重新计算
    var archivedThreads: Set<String> { archiveSplit().threads }

    private var archGen = 0
    private var archCache: (gen: Int, hour: Int, threads: Set<String>, inbox: [Message], archived: [Message])?

    private func archiveSplit() -> (threads: Set<String>, inbox: [Message], archived: [Message]) {
        let now = Date()
        let hour = Int(now.timeIntervalSince1970 / 3600)
        if let c = archCache, c.gen == archGen, c.hour == hour { return (c.threads, c.inbox, c.archived) }
        let threads = archivedThreads(now: now)
        let hidden = hiddenTopics
        let visible = hidden.isEmpty ? messages : messages.filter { !hidden.contains($0.topic) }
        let inbox = threads.isEmpty ? visible : visible.filter { !threads.contains(threadKey($0)) }
        let archived = threads.isEmpty ? [] : visible.filter { threads.contains(threadKey($0)) }
        archCache = (archGen, hour, threads, inbox, archived)
        return (threads, inbox, archived)
    }

    func archivedThreads(now: Date) -> Set<String> {
        var live = Set<String>(), all = Set<String>()
        for m in messages {
            let k = threadKey(m)
            all.insert(k)
            if !isArchived(m, now: now) { live.insert(k) }
        }
        return all.subtracting(live)
    }

    /// 收件箱里的消息（不含归档和隐藏频道的）
    var inbox: [Message] { archiveSplit().inbox }

    /// 归档里的消息
    var archivedMessages: [Message] { archiveSplit().archived }

    /// 当前视图（收件箱或归档）里的未读数，「全部已读」按钮用
    var visibleUnreadCount: Int {
        if filter == .archived || viewingHiddenChannel != nil {
            return visibleBase.reduce(0) { $0 + (read.contains($1.id) ? 0 : 1) }
        }
        return unreadCount
    }

    /// 正在看的隐藏频道（从侧栏「已隐藏」点开的）
    var viewingHiddenChannel: String? {
        if case .topic(let t) = filter, hiddenTopics.contains(t) { return t }
        return nil
    }

    /// 当前视图的消息范围：归档、某个隐藏频道，或收件箱
    private var visibleBase: [Message] {
        if let t = viewingHiddenChannel { return messages.filter { $0.topic == t } }
        return filter == .archived ? archivedMessages : inbox
    }

    func count(_ f: Filter) -> Int {
        switch f {
        case .archived: return archivedMessages.count
        case .unread: return unreadCount
        default:
            let list = inbox
            switch f {
            case .important: return list.filter { $0.priority >= 4 }.count
            case .starred: return list.filter { starred.contains($0.id) }.count
            case .attachments: return list.filter { !$0.attachments.isEmpty }.count
            case .topic(let t): return list.filter { $0.topic == t }.count
            default: return list.count
            }
        }
    }

    /// 全部频道名（含只剩归档消息的），清理消息时选择用
    var allTopicNames: [String] {
        var last: [String: Int64] = [:]
        for m in messages { last[m.topic] = max(last[m.topic] ?? 0, m.id) }
        return last.keys.sorted { (last[$0] ?? 0) > (last[$1] ?? 0) }
    }

    /// 频道：(名称, 总数, 未读数)。置顶的在前，再按手动顺序，没排过的按最近活跃；
    /// 不含隐藏的频道；只剩归档消息的频道不列出
    var topics: [(name: String, total: Int, unread: Int)] {
        var total: [String: Int] = [:], unread: [String: Int] = [:], last: [String: Int64] = [:]
        for m in inbox {
            total[m.topic, default: 0] += 1
            if !read.contains(m.id) { unread[m.topic, default: 0] += 1 }
        }
        for m in messages { last[m.topic] = max(last[m.topic] ?? 0, m.id) }
        return Self.orderChannels(Array(total.keys), settings: channelSettings, last: last)
            .map { ($0, total[$0] ?? 0, unread[$0] ?? 0) }
    }

    nonisolated static func orderChannels(_ names: [String], settings: [String: APIClient.ChannelSetting], last: [String: Int64]) -> [String] {
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

    /// 隐藏的频道
    var hiddenTopics: Set<String> { Set(channelSettings.values.filter(\.hidden).map(\.topic)) }

    /// 隐藏的频道里有消息的：(名称, 总数)
    var hiddenChannels: [(name: String, total: Int)] {
        let hidden = hiddenTopics
        guard !hidden.isEmpty else { return [] }
        var total: [String: Int] = [:]
        for m in messages where hidden.contains(m.topic) { total[m.topic, default: 0] += 1 }
        return total.keys.sorted { channelName($0).localizedStandardCompare(channelName($1)) == .orderedAscending }.map { ($0, total[$0]!) }
    }

    /// 频道的显示名（起了显示名用显示名，否则用 topic）
    func channelName(_ topic: String) -> String {
        let a = channelSettings[topic]?.alias ?? ""
        return a.isEmpty ? topic : a
    }

    func channel(_ topic: String) -> APIClient.ChannelSetting {
        channelSettings[topic] ?? .init(topic: topic)
    }

    /// 有没有手动排过序
    var hasManualChannelOrder: Bool { channelSettings.values.contains { $0.sort > 0 } }

    /// archived：消息所在会话是否归档（由调用方一次算好传入）
    func matches(_ m: Message, archived: Set<String>? = nil, hidden: Set<String>? = nil) -> Bool {
        let hid = hidden ?? hiddenTopics
        if case .topic(let t) = filter, hid.contains(t) {
            if m.topic != t { return false }   // 查看隐藏的频道：显示它的全部消息（含归档）
        } else {
            if hid.contains(m.topic) { return false }
            let arch = (archived ?? archivedThreads).contains(threadKey(m))
            if (filter == .archived) != arch { return false }
        }
        switch filter {
        case .all, .archived: break
        case .unread: if read.contains(m.id) { return false }
        case .important: if m.priority < 4 { return false }
        case .starred: if !starred.contains(m.id) { return false }
        case .attachments: if m.attachments.isEmpty { return false }
        case .topic(let t): if m.topic != t { return false }
        }
        if let p = minPriority, m.priority < p { return false }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let hay = [m.text, m.desp, m.topic, channelName(m.topic), m.thread, m.source] + m.attachments.map(\.name)
            if !hay.contains(where: { $0.localizedCaseInsensitiveContains(q) }) { return false }
        }
        return true
    }

    var groups: [ThreadGroup] {
        let arch = archivedThreads, hid = hiddenTopics
        return groupThreads(messages.filter { matches($0, archived: arch, hidden: hid) }, all: messages, read: read)
    }

    var isFiltering: Bool { isFiltering(ignoringFilter: false) }

    /// ignoringFilter：只看搜索词和优先级，不管侧栏选的是哪一项
    func isFiltering(ignoringFilter: Bool) -> Bool {
        (!ignoringFilter && filter != .all) || minPriority != nil || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func clearFilters() {
        filter = .all
        minPriority = nil
        searchText = ""
    }

    /// 某线程的全部消息（不受筛选影响），按时间升序
    func threadMessages(_ key: String) -> [Message] {
        messages.filter { threadKey($0) == key }
    }

    var client: APIClient? {
        guard let token, let url = URL(string: server) else { return nil }
        return APIClient(server: url, token: token)
    }

    // MARK: 生命周期

    func start() {
        if token != nil {
            loadE2EKeys()
            // §6.1：启动时把本地缓存里还没解开的消息重新解密一遍（上次退出前正好在解锁 / 同步，或钥匙串读取失败过）
            if !e2eKeys.isEmpty { Task { await decryptPending() } }
            startSync()
        }
        // 回到前台时刷新加密状态（§3）
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refreshE2E() }
            }
        }
        if !isDemo { updater.startSchedule() }
        runCleanup()
        cleanupTimer?.invalidate()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runCleanup() }
        }
    }

    func pair(server: String, code: String, name: String) async throws {
        let trimmed = Self.normalizeServer(server)
        guard !trimmed.isEmpty else { throw APIError.invalid("请填写服务器地址") }
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https", url.host != nil else {
            throw APIError.invalid("服务器地址格式不对")
        }
        let r = try await APIClient.pair(server: url, code: code.trimmingCharacters(in: .whitespaces), name: name)
        try adopt(r, server: trimmed)
    }

    /// 用户名密码登录；register=true 时注册新账号（服务器需开放注册）
    func login(server: String, username: String, password: String, name: String, register: Bool) async throws {
        let trimmed = Self.normalizeServer(server)
        guard !trimmed.isEmpty else { throw APIError.invalid("请填写服务器地址") }
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https", url.host != nil else {
            throw APIError.invalid("服务器地址格式不对")
        }
        // 新登录协议（docs/e2ee-client.md §2）：先取派生参数，在本机算凭证，从不发送密码原文（旧服务端、从未升级的账号除外）
        do {
            let r = try await E2E.login(server: APIClient(server: url, token: nil), authed: { APIClient(server: url, token: $0) },
                                        serverID: trimmed, username: username.trimmingCharacters(in: .whitespaces), password: password,
                                        device: .init(name: name, platform: "macos", fingerprint: DeviceFingerprint.value),
                                        register: register, marks: e2eMarks, secrets: e2eSecrets)
            try adopt(try JSONDecoder().decode(APIClient.PairResult.self, from: r.response), server: trimmed)
            e2eLoginNote = r.note
            e2ePendingLoginKey = r.pendingKey
        } catch APIError.unsupported {
            throw APIError.invalid("这个服务端版本较旧，还不支持账号登录（需要 0.5.0 以上），请用配对码配对")
        } catch let f as E2E.Failure where f.kind == .unsupported {
            throw APIError.invalid("这个服务端版本较旧，还不支持账号登录（需要 0.5.0 以上），请用配对码配对")
        }
    }

    /// 配对 / 登录成功：保存凭证、开始同步
    private func adopt(_ r: APIClient.PairResult, server trimmed: String) throws {
        guard Keychain.save(r.token, service: keychainService) else { throw APIError.invalid("写入钥匙串失败") }
        token = r.token
        self.server = trimmed
        deviceName = r.name
        defaults.set(trimmed, forKey: Self.key("server"))
        defaults.set(r.device_id, forKey: Self.key("deviceID"))
        defaults.set(r.name, forKey: Self.key("deviceName"))
        // 立刻拉账号和服务端信息，账号需要设置时直接进「完成账号设置」，不先闪一下消息界面
        Task { await refreshMe() }
        refreshServerInfo()
        startSync()
    }

    /// 仅 selftest/demo 使用：直接注入 token，不写钥匙串
    func useToken(_ t: String, server: String) {
        token = t
        self.server = server
        state = .connecting
    }

    func unpair() {
        syncTask?.cancel()
        syncTask = nil
        Keychain.delete(service: keychainService)
        token = nil
        canAdmin = nil
        account = nil
        changesCursor = nil     // 下次登录（可能是别的账号）先对账
        serverInfo = nil
        serverLegacy = false
        state = .unpaired
    }

    /// 退出登录：先让服务端作废本机凭证，再清除本地凭证。本地消息保留。
    /// 返回服务端是否确认作废（旧服务端没有这个接口，凭证需要在管理后台吊销）
    @discardableResult
    func logout() async -> Bool {
        var revoked = false
        if let client { revoked = (try? await client.logout()) != nil }
        e2eWipe()       // §8：删除本机为这个账号保存的私钥（「已升级」标记保留）
        unpair()
        return revoked
    }

    /// 清空本地消息（换账号登录时）
    func resetLocalMessages() {
        messages = []
        read = []
        starred = []
        serverCursor = 0
        changesCursor = nil
        changesEpoch = nil
        channelSettings = [:]
        e2eState = nil
        e2eRequest = nil
        e2eRequestPhase = nil
        e2eApprovals = [:]
        e2eApprovalPhases = [:]
        defaults.removeObject(forKey: Self.key("e2eEnabled"))
        e2ePlainKept = []
        save()
        refreshLocalFiles()
    }

    /// 「仅本机保留」的消息：服务器的「删除明文消息」删掉了（收到 purge 变更），本机保留副本（docs/e2ee-client.md §7.4）。
    /// 对账时不当作「别处删除」；之后的 delete 变更或用户手动删除照常删（同时移出这个集合）
    var e2ePlainKept: Set<Int64> {
        get { Set((defaults.array(forKey: Self.key("e2ePlainKept")) as? [Int64]) ?? []) }
        set {
            if newValue.isEmpty { defaults.removeObject(forKey: Self.key("e2ePlainKept")) }
            else { defaults.set(Array(newValue), forKey: Self.key("e2ePlainKept")) }
        }
    }

    /// 对账：服务器上找不到的本地消息里哪些要删（§7.4）。账号已开启加密时，找不到的**明文**消息可能是
    /// 「删除服务器上的明文消息」删掉的（离线超过 90 天收不到 purge 变更），记入「仅本机保留」而不删；加密消息照常删除
    nonisolated static func reconcileRemovals(missing: [Message], e2eEnabled: Bool, kept: Set<Int64>) -> (remove: [Int64], kept: Set<Int64>) {
        var k = kept
        if e2eEnabled { k.formUnion(missing.filter { !$0.isE2E }.map(\.id)) }
        return (withoutKept(missing.map(\.id), kept: k), k)
    }

    nonisolated static func withoutKept(_ ids: [Int64], kept: Set<Int64>) -> [Int64] {
        kept.isEmpty ? ids : ids.filter { !kept.contains($0) }
    }

    func startSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in await self?.syncLoop() }
    }

    func stopSync() {
        syncTask?.cancel()
        syncTask = nil
    }

    /// 同步循环：首次补拉历史（不弹通知）→ 长轮询 `GET /v1/messages?since=&wait=N`（新消息弹通知）。
    /// N 按所在网络自适应（Heartbeat.swift）：服务端 0.6.4 起最多 10 分钟，旧服务端固定 50 秒。
    /// 出错指数退避 1s→30s；401 停止并提示重新配对。
    private func syncLoop() async {
        var backoff: Double = 1
        var caughtUp = false
        while !Task.isCancelled {
            guard let client else { state = .unpaired; return }
            do {
                if !caughtUp {
                    if state != .connected { state = .connecting }
                    let hist = await prepareE2E(try await client.allMessages(since: maxID))
                    autoDownload(merge(hist, notify: false))
                    caughtUp = true
                    state = .connected
                    backoff = 1
                    Task { await refreshMe() }
                    refreshServerInfo()
                    await infoTask?.value      // 先知道服务端支不支持消息管理，第一次长轮询就带上变更游标
                    if support("channels") == .yes { await refreshChannels() }
                    if support("e2e") == .yes { Task { await refreshE2E() } }   // 功能清单到了才知道服务端有没有端到端加密
                    startPresence()
                    if updater.autoCheck, !isDemo { Task { await updater.check() } }
                    if isDemo { await demoAfterSync() }
                }
                let manage = support("messages.manage") == .yes
                if manage, changesCursor == nil, Date() >= reconcileRetryAt {
                    // 对账失败不影响收消息：这一轮照常长轮询（不带变更游标），一分钟后再试
                    do { try await reconcile(client) } catch let e as APIError {
                        if case .unauthorized = e { throw e }
                        reconcileRetryAt = Date().addingTimeInterval(60)
                    } catch {
                        if Task.isCancelled { return }
                        reconcileRetryAt = Date().addingTimeInterval(60)
                    }
                }
                let since = manage ? changesCursor : nil
                let net = NetKind.shared.snapshot
                let kind = net.kind
                let wait = Heartbeat.shared.wait(for: kind)
                let began = Date()
                let page: APIClient.MessagePage
                do {
                    page = try await client.messagesPage(since: syncCursor, limit: 200, wait: wait, changesSince: since)
                } catch {
                    // 只记「这条网络把连接断了」：重启循环、换网络、断网引起的失败都不算
                    if !Task.isCancelled, net.ready, NetKind.shared.snapshot.gen == net.gen, Heartbeat.countsAsDrop(error) {
                        Heartbeat.shared.record(kind, wait: wait, elapsed: Date().timeIntervalSince(began), outcome: .failed)
                    }
                    throw error
                }
                if Task.isCancelled { return }
                let gotData = !page.messages.isEmpty || page.changesReset || !page.changes.isEmpty
                if net.ready { Heartbeat.shared.record(kind, wait: wait, elapsed: Date().timeIntervalSince(began), outcome: .ok, gotData: gotData) }
                if let n = page.nextSince { serverCursor = max(serverCursor, n) }
                var fresh = page.messages
                var changes: [APIClient.MsgChange] = []
                if since != nil {
                    if page.changesReset || (page.changesEpoch != nil && page.changesEpoch != changesEpoch) {
                        changesCursor = nil   // 游标作废：下一轮重新对账
                    } else {
                        changes = page.changes
                        if let n = page.changesNext { changesCursor = n }
                    }
                }
                // 同一页里既有新消息又有删除它的变更：先去掉再合并，不弹通知；归档变更在合并之后应用
                let deleted = Set(changes.filter { $0.kind == "delete" }.map(\.id))
                if !deleted.isEmpty { fresh.removeAll { deleted.contains($0.id) } }
                updater.noteLatestBuild(page.latestBuild)
                // 服务端升级 / 降级后版本头会变，重新拉取功能清单
                if let v = ServerVersionSeen.current, v != serverInfo?.version { refreshServerInfo() }
                state = .connected
                backoff = 1
                autoDownload(merge(await prepareE2E(fresh), notify: true))
                applyChanges(changes)
                continue
            } catch let e as APIError {
                if case .unauthorized = e {
                    // 一次 401 不算数（反向代理、强制门户也可能返回 401）：用 /v1/me 复核，确实失效才停
                    if Task.isCancelled { return }
                    if await meUnauthorized(client) { e2eWipe(); state = .unauthorized; return }
                    if Task.isCancelled { return }
                    state = .reconnecting("服务器返回 401，复核登录有效，稍后重试")
                } else {
                    if Task.isCancelled { return }
                    state = .reconnecting(e.localizedDescription)
                }
            } catch {
                if Task.isCancelled { return }
                state = .reconnecting(Self.shortError(error))
            }
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(backoff * 2, 30)
        }
    }

    static func shortError(_ e: Error) -> String {
        if let u = e as? URLError {
            switch u.code {
            case .timedOut: return "超时"
            case .cannotConnectToHost, .cannotFindHost: return "连不上服务器"
            case .notConnectedToInternet: return "无网络"
            case .networkConnectionLost: return "连接断开"
            case .cancelled: return "已取消"
            default: return "网络错误 \(u.code.rawValue)"
            }
        }
        return e.localizedDescription
    }

    // MARK: 版本与功能协商

    /// 本客户端认识的服务端功能 id（服务端多出来的，提示「更新客户端后可用」）
    static let knownFeatures: [String: String] = [
        "push": "发送消息与附件", "stream": "实时接收", "admin.link": "一键进入管理后台", "update": "应用内更新",
        "me.rename": "修改设备名称", "keys": "管理 pushkey", "info": "版本与功能协商", "storage": "服务端存储与备份",
        "account": "账号登录", "devices": "设备身份与配对记录", "subscriptions": "按设备设置接收方式", "presence": "在用设备优先",
        "keys.delete": "删除已吊销的 pushkey", "messages.manage": "删除和归档消息", "channels": "频道改名、隐藏、静音、排序",
        "pair.status": "配对码倒计时与使用状态",
        "markdown.doc": "回笺 Markdown（表格、提示框、正文里的附件图片、进度条）",
        "sync.settings": "设置实时同步（pushkey、设备、账户）",
        "poll.long": "省电的实时接收（按网络自适应等待时长）",
        "e2e": "端到端加密",
        // 下面三项 Mac 客户端不需要做什么（iPhone 的 Bark 转发和软件源、服务端在管理后台自更新），认识即可，不提示「更新客户端」
        "bark": "iPhone 锁屏通知（Bark 转发）", "ios.source": "iPhone 客户端软件源", "server.update": "服务端一键更新",
    ]
    /// 0.5.0 以前的服务端没有功能清单；这些功能在 0.4.x 里可能有，直接调用、按「接口不存在」判断
    nonisolated static let maybeOnLegacy: Set<String> = ["push", "stream", "admin.link", "update", "me.rename", "keys"]

    enum FeatureSupport: Equatable { case yes, needsServerUpdate, unknown }

    func support(_ id: String) -> FeatureSupport { Self.support(id, info: serverInfo, legacy: serverLegacy) }

    nonisolated static func support(_ id: String, info: APIClient.ServerInfo?, legacy: Bool) -> FeatureSupport {
        if let i = info { return i.features.contains { $0.id == id } ? .yes : .needsServerUpdate }
        if legacy { return maybeOnLegacy.contains(id) ? .unknown : .needsServerUpdate }
        return .unknown
    }

    /// 服务端支持、但本客户端还不认识的功能
    var featuresNeedingClientUpdate: [APIClient.Feature] {
        serverInfo?.features.filter { Self.knownFeatures[$0.id] == nil } ?? []
    }

    /// 本客户端支持、但服务端还没有的功能
    var featuresNeedingServerUpdate: [(id: String, title: String)] {
        Self.knownFeatures.keys.sorted().filter { support($0) == .needsServerUpdate }.map { ($0, Self.knownFeatures[$0]!) }
    }

    /// 服务端版本描述
    var serverVersionText: String {
        if let v = serverInfo?.version { return v }
        return serverLegacy ? "低于 0.5.0" : "未知"
    }

    /// 某个接口报告「不存在」时调用：说明服务端比预想的旧
    func noteUnsupported(_ feature: String) {
        if serverInfo == nil { serverLegacy = true }
    }

    func refreshServerInfo() {
        guard infoTask == nil, let client else { return }
        infoTask = Task {
            defer { infoTask = nil }
            do {
                serverInfo = try await client.info()
                serverLegacy = false
                Heartbeat.shared.serverMax = support("poll.long") == .yes ? (serverInfo?.long_poll_max ?? Heartbeat.oldServerMax) : Heartbeat.oldServerMax
                // 服务端不支持频道设置（降级过）：本地缓存的隐藏 / 静音没法再改，不再生效
                if support("channels") == .needsServerUpdate, !channelSettings.isEmpty { channelSettings = [:] }
            } catch APIError.unsupported {
                serverInfo = nil
                serverLegacy = true
                Heartbeat.shared.serverMax = Heartbeat.oldServerMax
            } catch {}   // 网络错误：保留上一次的结果
        }
    }

    // MARK: 账号 / 接收规则 / 在用设备

    func setAwaySilent(_ on: Bool) async throws {
        guard let client else { throw APIError.invalid("尚未配对") }
        try await client.setAwaySilent(on)
        awaySilent = on
    }

    /// 有人在用这台 Mac（最近 60 秒有键盘鼠标操作）时，每 30 秒告诉服务端一次；
    /// 同账号的其他设备打开了「在用设备优先」就会对普通消息静默
    func startPresence() {
        presenceTimer?.invalidate()
        guard !isDemo else { return }
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.reportPresence() }
        }
        Task { await reportPresence() }
    }

    nonisolated static var userIdleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func reportPresence() async {
        guard state == .connected, let client, support("presence") == .yes, Self.userIdleSeconds < 60 else { return }
        try? await client.presence()
    }

    // MARK: 账户 / 管理后台

    /// 配对成功但账号还没有用户名密码：主窗口只显示「完成账号设置」，设置完才能使用
    /// （旧服务端不支持账号时不拦）
    var needsAccountSetup: Bool {
        token != nil && support("account") == .yes && account?.has_password == false
    }

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

    /// 服务器地址的主机部分（带非默认端口），用于界面显示
    var serverHost: String {
        guard let u = URL(string: server), let h = u.host else { return server }
        return u.port.map { "\(h):\($0)" } ?? h
    }

    /// 账户显示名：用户名，没有用户名时为空
    var accountName: String { account?.username ?? "" }

    /// 为本账号设置 / 修改用户名密码，成功后立即更新本地的账号信息
    func setCredentials(username: String, password: String, current: String) async throws -> APIClient.AccountInfo {
        guard let client else { throw APIError.invalid("还没有连接服务器") }
        let tok = token
        let a = try await client.setCredentials(username: username, password: password, current: current)
        guard token == tok else { throw CancellationError() }   // 期间退出 / 换了账号：不写回
        account = a
        return a
    }

    @discardableResult
    func refreshMe() async -> Bool {
        guard let client else { return false }
        guard let me = try? await client.me() else { return false }
        do {
            canAdmin = me.can_admin ?? false
            account = me.account
            awaySilent = me.away_silent ?? true
            // 换了账号登录：本地保存的是上一个账号的消息，清掉后按新账号重新同步
            if let a = me.account {
                let k = Self.key("accountKey"), cur = "\(server)#\(a.id)"
                if let prev = defaults.string(forKey: k), prev != cur {
                    e2eDiscardAccount(accountKey: prev)     // §8：换账号 / 换服务器，删掉旧账号的钥匙
                    defaults.set(cur, forKey: k)
                    resetLocalMessages()
                    loadE2EKeys()          // 换了账号：读新账号的钥匙
                    startSync()
                    return true
                }
                defaults.set(cur, forKey: k)
            }
            deviceName = me.name
            defaults.set(me.name, forKey: Self.key("deviceName"))
            defaults.set(me.device_id, forKey: Self.key("deviceID"))
        }
        loadE2EKeys()
        Task { await refreshE2E() }
        return true
    }

    var deviceID: String { defaults.string(forKey: Self.key("deviceID")) ?? "" }

    /// 给本机改名并同步到服务器
    func renameDevice(_ name: String) async throws {
        guard let client else { throw APIError.invalid("尚未配对") }
        let tok = token
        let saved = try await client.renameDevice(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard token == tok else { throw CancellationError() }
        deviceName = saved
        defaults.set(saved, forKey: Self.key("deviceName"))
    }

    /// 申请一次性登录链接并用默认浏览器打开（浏览器会被记住一年）
    func openAdmin() async {
        adminMessage = nil
        guard let client else { adminMessage = "尚未配对"; return }
        do {
            let url = try await client.adminLink()
            canAdmin = true
            NSWorkspace.shared.open(url)
        } catch APIError.http(403, _) {
            canAdmin = false
            adminMessage = "在管理网页的设备页为本机开启「可进入管理后台」"
        } catch {
            adminMessage = (error as? APIError)?.localizedDescription ?? Self.shortError(error)
        }
    }

    // MARK: 消息

    /// 合并消息；返回新增的消息
    @discardableResult
    func merge(_ incoming: [Message], notify: Bool) -> [Message] {
        let existing = Set(messages.map(\.id))
        var fresh = incoming.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return [] }
        // 没经过 prepareE2E 的加密消息：先按「已锁定」显示，之后在后台解密
        var undecrypted = false
        for i in fresh.indices where fresh[i].isE2E && fresh[i].e2eStatus == nil {
            fresh[i].applyE2E(.locked)
            undecrypted = true
        }
        // 也包括 prepareE2E 时还没解锁、标成 locked 的（解锁和同步同时进行，§6.1）
        if undecrypted || fresh.contains(where: \.e2eUnreadable), !e2eKeys.isEmpty { Task { await decryptPending() } }
        messages = (messages + fresh).sorted { $0.id < $1.id }
        save()
        if notify && notificationsEnabled {
            let now = Date()
            let decided = fresh.compactMap { m -> (Message, Bool)? in
                // 服务端标了静默（本机对这把 key 设为静默，或正在用别的设备）：只进列表
                if m.silent { return nil }
                // 隐藏的频道不提醒；静音的频道只有紧急消息提醒（服务端也会标静默，这里兜底）
                if hiddenTopics.contains(m.topic) || (channelSettings[m.topic]?.muted == true && m.priority < 5) { return nil }
                let (show, sound) = prefs.decide(priority: m.priority, now: now, pausedUntil: pausedUntil)
                return show ? (m, sound) : nil
            }
            if decided.count <= 5 {
                for (m, sound) in decided { Notifier.post(m, sound: sound, topicName: channelName(m.topic)) }
            } else {
                Notifier.postSummary(count: decided.count, sound: decided.contains { $0.1 })
            }
        }
        return fresh
    }

    // MARK: 删除 / 归档

    /// 删除 / 归档变更的游标（服务端 msg_changes.seq）；nil = 需要先对账
    private var changesCursor: Int64? {
        get { defaults.object(forKey: Self.key("changesCursor")) as? Int64 }
        set {
            if let v = newValue { defaults.set(v, forKey: Self.key("changesCursor")) } else { defaults.removeObject(forKey: Self.key("changesCursor")) }
        }
    }

    /// 上一次对账时服务端的变更纪元
    private var changesEpoch: String? {
        get { defaults.string(forKey: Self.key("changesEpoch")) }
        set { defaults.set(newValue, forKey: Self.key("changesEpoch")) }
    }
    private var reconcileRetryAt = Date.distantPast

    /// 对账：本地有、服务端已经没有的消息删掉（在别的设备或管理网页删除的），归档状态以服务端为准。
    /// 服务端纪元和上次不同（服务端重建或从备份恢复）时，服务端没有的消息不能当作被删除，只同步归档状态
    func reconcile(_ client: APIClient) async throws {
        let (states, next, epoch) = try await client.messageStates()
        if Task.isCancelled { return }
        let sameData = changesEpoch == nil || epoch == nil || epoch == changesEpoch
        if sameData {
            let r = Self.reconcileRemovals(missing: messages.filter { states[$0.id] == nil }, e2eEnabled: e2eAccountEnabled, kept: e2ePlainKept)
            if r.kept != e2ePlainKept { e2ePlainKept = r.kept }
            removeLocal(r.remove)
        }
        applyArchive(states)
        changesEpoch = epoch
        changesCursor = next
        // 游标作废期间漏掉的频道设置变更：重新拉一次
        if canManageChannels { await refreshChannels() }
    }

    /// 应用其他设备的删除 / 归档、频道设置变更，以及设置实时同步（服务端 0.6.1 起）的 keys / devices / account。
    /// 不认识的 kind 忽略
    func applyChanges(_ changes: [APIClient.MsgChange]) {
        guard !changes.isEmpty else { return }
        var del: [Int64] = [], purge: [Int64] = [], arch: [Int64: Int] = [:], channelsChanged = false, keys = false, account = false, e2e = false
        for c in changes {
            switch c.kind {
            case "delete": del.append(c.id); arch[c.id] = nil
            // 「删除服务器上的明文消息」删掉的（0.7.0 起）：服务器上没有了，本机保留副本（docs/e2ee-client.md §7.4）
            case "purge": purge.append(c.id); arch[c.id] = nil
            case "archive": arch[c.id] = c.state ?? 0
            case "channels": channelsChanged = true
            case "keys": keys = true
            case "devices", "account": account = true
            case "e2e": e2e = true       // 开启加密、设备请求批准 / 已批准、只接受加密消息（0.7.0 起）
            default: break
            }
        }
        if e2e { Task { await refreshE2E() } }
        if channelsChanged { Task { await refreshChannels() } }
        if keys || account { noteSettingsChanged(keys: keys, account: account) }
        if !purge.isEmpty {
            let local = Set(messages.map(\.id))
            let keep = purge.filter { local.contains($0) }
            if !keep.isEmpty { e2ePlainKept = e2ePlainKept.union(keep) }
        }
        removeLocal(del)
        applyArchive(arch)
    }

    // MARK: 设置实时同步（keys / devices / account）

    /// pushkey 在别处变了：每加一，打开着的 Pushkey 页（发送示例、本机接收方式）重新拉取
    @Published private(set) var keysRevision = 0
    /// 账户 / 设备在别处变了：每加一，打开着的账户页重新拉取设备列表
    @Published private(set) var accountRevision = 0
    private var pendingKeysRefresh = false
    private var pendingAccountRefresh = false
    private var settingsRefreshTask: Task<Void, Never>?
    /// 自检用：实际重新拉取的次数（连续多条变更合并成一次）
    private(set) var settingsRefreshCount = (keys: 0, account: 0)

    /// 连续多条变更合并：0.3 秒内到的只拉一次
    func noteSettingsChanged(keys: Bool, account: Bool) {
        pendingKeysRefresh = pendingKeysRefresh || keys
        pendingAccountRefresh = pendingAccountRefresh || account
        guard settingsRefreshTask == nil else { return }
        settingsRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.runSettingsRefresh()
        }
    }

    private func runSettingsRefresh() async {
        let keys = pendingKeysRefresh, account = pendingAccountRefresh
        pendingKeysRefresh = false
        pendingAccountRefresh = false
        settingsRefreshTask = nil
        if keys {
            settingsRefreshCount.keys += 1
            keysRevision += 1
        }
        guard account, let client else { return }
        // 拉取期间退出、换了设备凭证：结果作废
        let tok = token
        settingsRefreshCount.account += 1
        // 本机被移除：只认 /v1/me 的 401。设备列表里找不到本机时，再用 /v1/me 复核一次（列表可能因为别的原因不完整）
        do {
            _ = try await client.me()
            guard token == tok else { return }
            await refreshMe()
            guard token == tok else { return }
            if let d = try? await client.account(), !deviceID.isEmpty,
               !d.devices.contains(where: { $0.id == deviceID && !$0.revoked }) {
                if await meUnauthorized(client), token == tok { markRemoved() }
                return
            }
        } catch APIError.unauthorized {
            // §8：一次 401 不算数，再请求一次 /v1/me，仍是 401 才按设备被移除处理
            if await meUnauthorized(client), token == tok { markRemoved() }
            return
        } catch {}
        guard token == tok else { return }
        accountRevision += 1
    }

    /// /v1/me 复核：只有明确返回 401 才算本机凭证失效（网络错误、服务端 500 都不算）
    private func meUnauthorized(_ client: APIClient) async -> Bool {
        do { _ = try await client.me(); return false } catch APIError.unauthorized { return true } catch { return false }
    }

    private func markRemoved() {
        stopSync()
        e2eWipe()
        state = .unauthorized
    }

    private func applyArchive(_ states: [Int64: Int]) {
        guard !states.isEmpty else { return }
        var changed = false
        var list = messages
        for i in list.indices {
            if let s = states[list[i].id], list[i].archive != s { list[i].archive = s; changed = true }
        }
        if changed { messages = list; save() }
    }

    /// 从本机移除消息：列表、已读 / 收藏标记、已下载的附件、通知中心里的通知
    func removeLocal(_ ids: [Int64]) {
        let set = Set(ids)
        let gone = messages.filter { set.contains($0.id) }
        guard !gone.isEmpty else { return }
        let kept = e2ePlainKept
        if !kept.isDisjoint(with: set) { e2ePlainKept = kept.subtracting(set) }
        messages.removeAll { set.contains($0.id) }
        read.subtract(set)
        starred.subtract(set)
        for a in gone.flatMap(\.attachments) {
            cache.remove(a.id)
            thumbnails[a.id] = nil
            downloadErrors[a.id] = nil
        }
        if gone.contains(where: { !$0.attachments.isEmpty }) { refreshLocalFiles() }
        Notifier.remove(gone.map(\.id))
        if let f = focusedMessage, set.contains(f) { focusedMessage = nil }
        if let k = selectedThread, !messages.contains(where: { threadKey($0) == k }) { selectedThread = nil }
        save()
    }

    /// 消息管理需要服务端 0.5.4 以上
    var canManageMessages: Bool { support("messages.manage") == .yes }

    private func requireManage() -> APIClient? {
        guard let client else { manageError = "尚未配对"; return nil }
        guard canManageMessages else {
            manageError = support("messages.manage") == .unknown ? "正在连接服务器，稍后再试"
                : "服务端版本较旧，更新到 0.5.4 以上后才能删除和归档消息"
            return nil
        }
        return client
    }

    /// 从账号删除（所有设备同步消失，服务端附件一起删除）。返回是否成功
    @discardableResult
    func deleteMessages(_ ids: [Int64]) async -> Bool {
        guard !ids.isEmpty, let client = requireManage() else { return false }
        // 仅本机保留的消息服务器上已经没有了：只删本地
        let kept = e2ePlainKept
        let localOnly = ids.filter { kept.contains($0) }
        if !localOnly.isEmpty { removeLocal(localOnly) }
        let ids = localOnly.isEmpty ? ids : ids.filter { !kept.contains($0) }
        guard !ids.isEmpty else { return true }
        do {
            for chunk in stride(from: 0, to: ids.count, by: 1000).map({ Array(ids[$0..<min($0 + 1000, ids.count)]) }) {
                _ = try await client.deleteMessages(chunk)
                removeLocal(chunk)
            }
            return true
        } catch {
            manageError = "删除失败：" + ((error as? APIError)?.localizedDescription ?? Self.shortError(error))
            return false
        }
    }

    /// 设置归档状态（ArchiveState）。返回是否成功
    @discardableResult
    func setArchive(_ ids: [Int64], state: Int) async -> Bool {
        guard !ids.isEmpty, let client = requireManage() else { return false }
        // 先改本地（界面立即响应），之后以服务端的变更为准（自己的操作也会按顺序回来）；失败时把没改成的改回去
        let chunks = stride(from: 0, to: ids.count, by: 1000).map { Array(ids[$0..<min($0 + 1000, ids.count)]) }
        let wanted = Set(ids)
        let before = Dictionary(messages.filter { wanted.contains($0.id) }.map { ($0.id, $0.archive) }, uniquingKeysWith: { a, _ in a })
        applyArchive(Dictionary(ids.map { ($0, state) }, uniquingKeysWith: { a, _ in a }))
        var done = 0
        do {
            for chunk in chunks {
                _ = try await client.archiveMessages(chunk, state: state)
                done += 1
            }
            return true
        } catch {
            let undo = Set(chunks.dropFirst(done).joined())
            applyArchive(before.filter { undo.contains($0.key) })
            manageError = (state == ArchiveState.archived ? "归档失败：" : "移回收件箱失败：")
                + ((error as? APIError)?.localizedDescription ?? Self.shortError(error))
            return false
        }
    }

    /// 归档 / 移回会话：线程里的全部消息一起改
    @discardableResult
    func archiveThreads(_ keys: [String], archive: Bool) async -> Bool {
        let ks = Set(keys)
        let ids = messages.filter { ks.contains(threadKey($0)) }.map(\.id)
        return await setArchive(ids, state: archive ? ArchiveState.archived : ArchiveState.keep)
    }

    static func archiveLabel(_ days: Int) -> String {
        switch days {
        case 0: return "不自动归档"
        case 365: return "超过 1 年"
        default: return "超过 \(days) 天"
        }
    }

    /// 当前搜索词在归档里匹配的消息数（收件箱里搜不到时提示）
    var archiveMatchCount: Int {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        return archivedMessages.filter { m in
            if let p = minPriority, m.priority < p { return false }
            return ([m.text, m.desp, m.topic, m.thread, m.source] + m.attachments.map(\.name))
                .contains { $0.localizedCaseInsensitiveContains(q) }
        }.count
    }

    func deleteThreads(_ keys: [String]) async {
        let ks = Set(keys)
        await deleteMessages(messages.filter { ks.contains(threadKey($0)) }.map(\.id))
    }

    struct DeleteRequest: Identifiable {
        let id = UUID()
        let title: String
        let ids: [Int64]
        let attachments: Int
        /// 删除整个频道（服务端按频道删，包括本机没有的消息）
        var topic: String? = nil
        var detail: String {
            (topic != nil ? "这个频道的全部消息都会从账号删除，所有设备上都会消失" : "从账号删除：所有设备上都会消失")
                + (attachments > 0 ? "，服务端的 \(attachments) 个附件一起删除" : (topic != nil ? "，附件一起删除" : ""))
                + "。删除后不能恢复。" + (topic != nil ? "以后这个频道再有消息发来，它会重新出现。" : "")
        }
    }

    private static func short(_ s: String) -> String { s.count > 24 ? String(s.prefix(24)) + "…" : s }

    /// 删除会话（确认后执行）
    func requestDelete(threads keys: [String]) {
        guard requireManage() != nil else { return }
        let ks = Set(keys)
        let list = messages.filter { ks.contains(threadKey($0)) }
        guard let last = list.last else { return }
        let title = ks.count == 1
            ? "删除会话「\(Self.short(last.text))」" + (list.count > 1 ? "（共 \(list.count) 条）？" : "？")
            : "删除 \(ks.count) 个会话（共 \(list.count) 条消息）？"
        deleteRequest = DeleteRequest(title: title, ids: list.map(\.id), attachments: list.reduce(0) { $0 + $1.attachments.count })
    }

    /// 删除单条消息（确认后执行）
    func requestDelete(message id: Int64) {
        guard requireManage() != nil, let m = messages.first(where: { $0.id == id }) else { return }
        deleteRequest = DeleteRequest(title: "删除这条消息「\(Self.short(m.text))」？", ids: [id], attachments: m.attachments.count)
    }

    // MARK: 频道设置

    var canManageChannels: Bool { support("channels") == .yes }

    private func requireChannels() -> APIClient? {
        guard let client else { manageError = "尚未配对"; return nil }
        guard canManageChannels else {
            manageError = support("channels") == .unknown ? "正在连接服务器，稍后再试"
                : "服务端版本较旧，更新到 0.5.5 以上后才能管理频道"
            return nil
        }
        return client
    }

    private var channelsRefreshing = false
    private var channelsDirty = false
    private var channelEditsInFlight = 0
    private var channelEditGen = 0

    /// 从服务端拉取频道设置。同一时间只有一个请求，期间又有变更就结束后再拉一次；
    /// 本机正在改设置（请求还没回来）时不覆盖本地，等改完再拉，避免旧结果把刚改的设置冲掉
    @discardableResult
    func refreshChannels() async -> Bool {
        if channelsRefreshing { channelsDirty = true; return true }
        channelsRefreshing = true
        defer { channelsRefreshing = false }
        var ok = false
        repeat {
            channelsDirty = false
            let gen = channelEditGen
            guard let client, canManageChannels, let cs = try? await client.channels() else { return ok }
            if channelEditsInFlight > 0 || gen != channelEditGen { channelsDirty = true; continue }
            let fresh = Dictionary(cs.map { ($0.topic, $0) }, uniquingKeysWith: { a, _ in a })
            if fresh != channelSettings { channelSettings = fresh }
            ok = true
        } while channelsDirty && channelEditsInFlight == 0
        return ok
    }

    private func beginChannelEdit() { channelEditsInFlight += 1; channelEditGen += 1 }

    /// 改完（成功或失败）都以服务端为准再拉一次：失败时不用回滚快照，也不会冲掉其他设备刚改的设置
    private func endChannelEdit(failed: Bool) async {
        channelEditsInFlight -= 1
        if channelEditsInFlight == 0, failed || channelsDirty { await refreshChannels() }
    }

    /// 改频道设置：先改本地，失败时改回
    @discardableResult
    func updateChannel(_ topic: String, alias: String? = nil, hidden: Bool? = nil, muted: Bool? = nil, pinned: Bool? = nil) async -> Bool {
        guard let client = requireChannels() else { return false }
        var c = channel(topic)
        if let alias { c.alias = alias.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        if let hidden { c.hidden = hidden }
        if let muted { c.muted = muted }
        if let pinned { c.pinned = pinned }
        channelSettings[topic] = c
        beginChannelEdit()
        let tok = token
        do {
            let saved = try await client.updateChannel(topic, alias: alias, hidden: hidden, muted: muted, pinned: pinned)
            guard token == tok else { channelEditsInFlight = max(0, channelEditsInFlight - 1); return false }
            channelSettings[topic] = saved
            await endChannelEdit(failed: false)
            return true
        } catch {
            guard token == tok else { channelEditsInFlight = max(0, channelEditsInFlight - 1); return false }
            manageError = "保存频道设置失败：" + ((error as? APIError)?.localizedDescription ?? Self.shortError(error))
            await endChannelEdit(failed: true)
            return false
        }
    }

    /// 手动排序：传入侧栏里看得到的频道的新顺序；空列表 = 恢复按最近活跃排序。
    /// 本机看不到、但排过序的频道（隐藏的、只剩归档的、本机不接收的）保留原来的位置
    func setChannelOrder(_ visible: [String]) async {
        guard let client = requireChannels() else { return }
        let order = visible.isEmpty ? [] : Self.mergedOrder(visible, settings: channelSettings)
        var next = channelSettings
        for k in next.keys { next[k]?.sort = 0 }
        for (i, t) in order.enumerated() {
            var c = next[t] ?? .init(topic: t)
            c.sort = i + 1
            next[t] = c
        }
        channelSettings = next
        beginChannelEdit()
        let tok = token
        do {
            try await client.setChannelOrder(order)
            guard token == tok else { channelEditsInFlight = max(0, channelEditsInFlight - 1); return }
            await endChannelEdit(failed: false)
        } catch {
            guard token == tok else { channelEditsInFlight = max(0, channelEditsInFlight - 1); return }
            manageError = "保存频道顺序失败：" + ((error as? APIError)?.localizedDescription ?? Self.shortError(error))
            await endChannelEdit(failed: true)
        }
    }

    /// 把看得到的频道的新顺序并进完整的手动顺序：看不到的频道留在原来的位置，看得到的按新顺序依次填进它们原来占的位置
    nonisolated static func mergedOrder(_ visible: [String], settings: [String: APIClient.ChannelSetting]) -> [String] {
        let vis = Set(visible)
        var base = settings.values.filter { $0.sort > 0 }.sorted { $0.sort < $1.sort }.map(\.topic)
        for t in visible where !base.contains(t) { base.append(t) }
        var it = visible.makeIterator()
        return base.map { vis.contains($0) ? it.next()! : $0 }
    }

    /// 侧栏拖动排序：dragged 放到 target 原来的位置（往下拖排在它后面，往上拖排在它前面）
    nonisolated static func moved(_ order: [String], _ dragged: String, to target: String) -> [String] {
        guard let from = order.firstIndex(of: dragged), let to = order.firstIndex(of: target), from != to else { return order }
        var o = order
        o.remove(at: from)
        o.insert(dragged, at: to)
        return o
    }

    func moveChannel(_ dragged: String, to target: String) async {
        let order = topics.map(\.name)
        let next = Self.moved(order, dragged, to: target)
        if next != order { await setChannelOrder(next) }
    }

    func requestDeleteChannel(_ topic: String) {
        guard requireChannels() != nil else { return }
        let list = messages.filter { $0.topic == topic }
        deleteRequest = DeleteRequest(title: "删除频道「\(channelName(topic))」（本机 \(list.count) 条消息）？", ids: list.map(\.id),
                                      attachments: list.reduce(0) { $0 + $1.attachments.count }, topic: topic)
    }

    @discardableResult
    /// ids：确认删除时本机这个频道的消息。之后新到的同频道消息服务端可能还在，不在本机删（服务端删了的会通过变更同步过来）
    func deleteChannel(_ topic: String, ids: [Int64]? = nil) async -> Bool {
        guard let client = requireChannels() else { return false }
        let local = ids ?? messages.filter { $0.topic == topic }.map(\.id)
        let tok = token
        do {
            _ = try await client.deleteChannel(topic)
            guard token == tok else { return false }   // 期间退出 / 换了账号：不动本地消息
            removeLocal(local)
            channelSettings[topic] = nil
            if filter == .topic(topic) { filter = .all }
            return true
        } catch {
            manageError = "删除频道失败：" + ((error as? APIError)?.localizedDescription ?? Self.shortError(error))
            return false
        }
    }

    func openCleanup(topic: String? = nil) {
        guard requireManage() != nil else { return }
        var r = CleanupRule()
        r.topic = topic
        cleanupRule = r
    }

    /// 按条件清理：频道（nil = 全部）、早于多少天（0 = 不限）、优先级不高于（nil = 不限）、是否包括收藏
    struct CleanupRule: Equatable {
        var topic: String? = nil
        var olderThanDays = 30
        var maxPriority: Int? = nil
        var includeStarred = false
    }

    func cleanupTargets(_ r: CleanupRule, now: Date = Date()) -> [Message] {
        messages.filter { m in
            if let t = r.topic, m.topic != t { return false }
            if r.olderThanDays > 0, now.timeIntervalSince(m.createdAt) <= Double(r.olderThanDays) * 86400 { return false }
            if let p = r.maxPriority, m.priority > p { return false }
            if !r.includeStarred, starred.contains(m.id) { return false }
            return true
        }
    }

    func markRead(_ id: Int64) {
        guard !read.contains(id) else { return }
        read.insert(id)
        save()
    }

    func markRead(thread key: String) {
        let ids = threadMessages(key).map(\.id).filter { !read.contains($0) }
        guard !ids.isEmpty else { return }
        read.formUnion(ids)
        save()
    }

    func markUnread(_ id: Int64) {
        // 本来就是未读：不用整份重写消息文件
        guard read.contains(id) else { return }
        read.remove(id)
        save()
    }

    /// 在归档里点「全部已读」标归档的，其他视图标收件箱的
    func markAllRead() {
        let ids = visibleBase.map(\.id).filter { !read.contains($0) }
        // 已经全部已读：不用整份重写消息文件
        guard !ids.isEmpty else { return }
        read.formUnion(ids)
        save()
    }

    func toggleStar(_ id: Int64) {
        if starred.contains(id) { starred.remove(id) } else { starred.insert(id) }
        save()
    }

    func selectThread(_ key: String) {
        selectedThread = key
        focusedMessage = threadMessages(key).last?.id
        markRead(thread: key)
    }

    /// 从通知 / URL / 菜单栏跳转到某条消息
    func select(_ id: Int64) {
        guard let m = messages.first(where: { $0.id == id }) else { return }
        clearFilters()
        let key = threadKey(m)
        if hiddenTopics.contains(m.topic) { filter = .topic(m.topic) }      // 隐藏频道的消息在这个频道里才看得到
        else if archivedThreads.contains(key) { filter = .archived }      // 已归档的会话在「归档」里才看得到
        selectedThread = key
        focusedMessage = id
        scrollTarget = key
        markRead(thread: key)
    }

    /// 加密消息重新解密后整体替换（E2EModel.swift 用；messages 的 setter 只在这个文件里可见）
    func replaceMessages(_ list: [Message]) {
        messages = list
        save()
    }

    /// 写盘放到后台串行队列：几千条消息（带 doc）的全量编码不卡界面；同一个文件排队中只保留最新一次（见 SaveQueue.swift）
    nonisolated static let saver = CoalescingWriter(label: "io.github.hongyile.huijian.save")

    func save() {
        let s = PersistedState(messages: messages, read: read, starred: starred)
        let url = paths.messagesFile
        Self.saver.submit(key: url.path) { try? Persistence.save(s, to: url) }
    }

    /// 等排队中的写盘做完（退出前、自检读文件前）
    nonisolated static func flushSaves() { saver.flush() }

    // MARK: 附件

    // MARK: 自动下载 / 代理

    private var autoQueue: [Attachment] = []
    private var autoRunning = false

    /// 新到的消息里，大小在阈值内的附件排队依次下载（一次一个，不抢带宽）
    func autoDownload(_ msgs: [Message]) {
        let now = Date()
        for m in msgs where !m.e2eUnreadable {     // 还没解开的加密消息：附件是密文，没有钥匙，不下载
            // 永久保留时，自动下载只补最近 7 天的（刚配对时不会把全部历史附件一次拉下来）
            for a in m.attachments where AutoDownload.should(a, messageDate: m.createdAt, limitMB: autoDownloadLimitMB,
                                                              retentionHours: retentionHours > 0 ? retentionHours : 168,
                                                              alreadyLocal: localFiles[a.id] != nil, now: now)
                && !autoQueue.contains(where: { $0.id == a.id }) {
                autoQueue.append(a)
            }
        }
        guard !autoRunning, !autoQueue.isEmpty else { return }
        autoRunning = true
        Task {
            while !autoQueue.isEmpty {
                let a = autoQueue.removeFirst()
                if localFiles[a.id] == nil, progress[a.id] == nil { await download(a) }
            }
            autoRunning = false
        }
    }

    /// 应用新的代理设置：重建会话，重启长轮询，让新设置立即生效
    func setProxy(_ p: ProxyConfig) {
        guard p != proxy else { return }
        proxy = p
        p.save(defaults)
        NetSessions.shared.update(p)
        engine.reloadProxy()
        updateEngine.reloadProxy()
        if token != nil, syncTask != nil { startSync() }
    }

    func download(_ att: Attachment) async {
        guard let client else { downloadErrors[att.id] = "未配对"; return }
        guard progress[att.id] == nil else { return }
        downloadErrors[att.id] = nil
        progress[att.id] = 0
        do {
            let url = try await cache.fetch(att, client: client, engine: engine) { p in
                Task { @MainActor in
                    if self.progress[att.id] != nil { self.progress[att.id] = p }
                }
            }
            progress[att.id] = nil
            localFiles[att.id] = url
            await makeThumbnail(att.id, url: url)
        } catch {
            progress[att.id] = nil
            if (error as? URLError)?.code == .cancelled { return }
            downloadErrors[att.id] = (error as? APIError)?.localizedDescription ?? Self.shortError(error)
            if case APIError.unauthorized = error { state = .unauthorized }
        }
    }

    func cancelDownload(_ attID: String) {
        engine.cancel(tag: attID)
        progress[attID] = nil
    }

    func makeThumbnail(_ attID: String, url: URL) async {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 320, height: 200),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2,
                                               representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
            thumbnails[attID] = rep.nsImage
        }
    }

    func refreshLocalFiles() {
        var map: [String: URL] = [:]
        for m in messages {
            for a in m.attachments {
                if let u = cache.localURL(a.id) { map[a.id] = u }
            }
        }
        localFiles = map
        thumbnails = thumbnails.filter { map[$0.key] != nil }
        for (id, url) in map where thumbnails[id] == nil {
            Task { await makeThumbnail(id, url: url) }
        }
    }

    var starredAttachmentIDs: Set<String> {
        Set(messages.filter { starred.contains($0.id) }.flatMap { $0.attachments.map(\.id) })
    }

    @discardableResult
    func runCleanup(now: Date = Date()) -> [String] {
        objectWillChange.send()   // 每小时一次：让自动归档跟上时间
        let removed = cache.cleanup(now: now, keep: starredAttachmentIDs,
                                    maxAge: retentionHours > 0 ? TimeInterval(retentionHours) * 3600 : nil)
        if !removed.isEmpty { refreshLocalFiles() }
        return removed
    }

    func clearAllCache() {
        for id in Array(cache.index.keys) where !starredAttachmentIDs.contains(id) { cache.remove(id) }
        refreshLocalFiles()
    }

    /// 本地附件缓存：(文件数, 字节数)
    var cacheUsage: (Int, Int64) {
        var n = 0, bytes: Int64 = 0
        for (_, url) in localFiles {
            n += 1
            bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (n, bytes)
    }

    /// 搬移附件时的进度（已完成, 总数）
    @Published var relocateProgress: (Int, Int)?

    /// 更换附件保存位置；url 为 nil 时恢复默认。move=true 时把已下载的附件一起搬过去（在后台进行）。
    func setAttachmentDir(_ url: URL?, move: Bool) async -> String {
        let target = (url ?? paths.attDir).standardizedFileURL
        guard !AttachmentCache.samePlace(target, attachmentDir) else { return "位置没有变化" }
        attachmentDir = target
        if url == nil { defaults.removeObject(forKey: Self.key("attachmentDir")) } else { defaults.set(target.path, forKey: Self.key("attachmentDir")) }
        relocateProgress = move ? (0, 0) : nil
        let r = await cache.relocate(to: target, move: move) { [weak self] done, total in self?.relocateProgress = (done, total) }
        relocateProgress = nil
        refreshLocalFiles()
        if !move { return "已更换位置，新附件保存到这里" }
        return r.failed == 0 ? "已更换位置，搬过去 \(r.moved) 个附件" : "已更换位置，搬过去 \(r.moved) 个，\(r.failed) 个没搬成功（仍在原位置，照常可用）"
    }

    func removeLocal(_ attID: String) {
        cache.remove(attID)
        refreshLocalFiles()
    }

    func preview(_ attID: String) {
        if let u = localFiles[attID] { previewURL = u }
    }

    // MARK: 暂停通知

    func pause(hours: Double) { pausedUntil = Date().addingTimeInterval(hours * 3600) }

    func pauseUntilMorning() {
        let cal = Calendar.current
        var d = cal.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
        if d <= Date() { d = cal.date(byAdding: .day, value: 1, to: d)! }
        pausedUntil = d
    }

    var isPaused: Bool { (pausedUntil ?? .distantPast) > Date() }

    // MARK: 登录时启动

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        objectWillChange.send()
    }

    // MARK: demo

    /// demo：按环境变量预下载附件、选中消息
    private func demoAfterSync() async {
        let env = ProcessInfo.processInfo.environment
        if env["HUIJIAN_DEMO_UPDATE"] != nil {
            // 演示用的新版本号 = 当前版本的修订号 + 1，截图不会出现「新版本」比当前版本还旧
            var parts = AppInfo.version.split(separator: ".").map { Int($0) ?? 0 }
            if parts.isEmpty { parts = [0] }
            parts[parts.count - 1] += 1
            updater.demoShow(UpdateInfo(id: 1, version: parts.map(String.init).joined(separator: "."), build: AppInfo.build + 1,
                                        notes: "附件下载更快；设置页细节优化；修复若干问题。",
                                        size: 3_456_789, sha256: "", signature: "", url: ""))
        }
        switch env["HUIJIAN_DEMO_UPDATE_PHASE"] {
        case "downloading": updater.demoPhase(.downloading(0.42))
        case "verifying": updater.demoPhase(.verifying)
        case "installing": updater.demoPhase(.installing)
        default: break
        }
        if let names = env["HUIJIAN_DEMO_PREFETCH"] {
            let want = Set(names.split(separator: ",").map(String.init))
            for m in messages {
                for a in m.attachments where want.contains(a.name) && localFiles[a.id] == nil {
                    await download(a)
                }
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        if let sel = env["HUIJIAN_DEMO_SELECT"], let m = messages.last(where: { $0.text.contains(sel) }) {
            selectThread(threadKey(m))
            focusedMessage = m.id
        }
        if let n = env["HUIJIAN_DEMO_READ_OLDEST"], let k = Int(n) {
            read.formUnion(messages.prefix(k).map(\.id))
        }
        if let s = env["HUIJIAN_DEMO_STAR"], let m = messages.last(where: { $0.text.contains(s) }) {
            starred.insert(m.id)
        }
        if env["HUIJIAN_DEMO_PROGRESS"] != nil,
           let a = messages.flatMap(\.attachments).first(where: { localFiles[$0.id] == nil && FileKind.of(name: $0.name, mime: $0.mime) == .archive }) {
            progress[a.id] = 0.62 // 演示"下载中"状态
        }
        if env["HUIJIAN_DEMO_CANADMIN"] != nil { canAdmin = true }
        if env["HUIJIAN_DEMO_FILTER"] == "archived" {
            filter = .archived
            if let m = archivedMessages.last { selectThread(threadKey(m)); focusedMessage = m.id }
        }
        if let t = env["HUIJIAN_DEMO_CLEANUP"] {
            var r = CleanupRule()
            r.topic = t
            r.olderThanDays = 30
            cleanupRule = r
        }
    }
}

// MARK: 通知

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, err in
            if let err { NSLog("回笺 通知授权失败: \(err.localizedDescription)") }
            NSLog("回笺 通知授权: \(granted)")
        }
    }

    /// 一次到达太多（例如断网恢复后）时只弹一条汇总，避免刷屏
    static func postSummary(count: Int, sound: Bool) {
        let c = UNMutableNotificationContent()
        c.title = "收到 \(count) 条新消息"
        c.body = "点击打开回笺查看"
        if sound { c.sound = .default }
        let req = UNNotificationRequest(identifier: "summary-\(Date().timeIntervalSince1970)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// 有设备请求解锁加密消息（T50），点开进入设置的「加密」页
    static func postE2ERequest(_ r: E2E.Request) {
        let c = UNMutableNotificationContent()
        c.title = "端到端加密"
        c.body = E2E.T.t50(r.name.isEmpty ? "新设备" : r.name)
        c.sound = .default
        c.userInfo = ["e2e": true]
        let req = UNNotificationRequest(identifier: "e2e-\(r.notifyKey)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// 删除消息后，把通知中心里对应的通知一起撤掉
    static func remove(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids.map { "msg-\($0)" })
    }

    static func post(_ m: Message, sound: Bool, topicName: String? = nil) {
        let c = UNMutableNotificationContent()
        let s = PriorityStyle.of(m.priority)
        c.title = m.priority >= 4 ? "【\(s.name)】\(m.text)" : m.text
        // 服务端的 preview 保留换行（通知里比挤成一行好读）
        var body = m.type != "text" && !m.preview.isEmpty ? m.preview : plainSummary(m.desp, type: m.type, limit: 200)
        if !m.attachments.isEmpty {
            body += (body.isEmpty ? "" : "\n") + "📎 \(m.attachments.count) 个附件"
        }
        c.body = body
        let name = topicName ?? m.topic
        c.subtitle = [m.topic == "default" && name == "default" ? nil : "#\(name)", m.thread.isEmpty ? nil : m.thread, m.source.isEmpty ? nil : m.source]
            .compactMap { $0 }.joined(separator: " · ")
        if sound { c.sound = .default }
        c.threadIdentifier = threadKey(m)
        c.userInfo = ["id": NSNumber(value: m.id)]
        let req = UNNotificationRequest(identifier: "msg-\(m.id)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { NSLog("回笺 发送通知失败: \(err.localizedDescription)") }
        }
    }
}
