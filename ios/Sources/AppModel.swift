import BackgroundTasks
import UIKit
import Network
import SwiftUI
import UserNotifications

/// 连接状态（首页和设置页显示）
enum ConnState: Equatable {
    case loggedOut
    case connecting
    case connected
    /// App 在后台：长轮询已停，回到前台自动重连
    case paused
    case reconnecting(String)
    case unauthorized

    var text: String {
        switch self {
        case .loggedOut: return "未登录"
        case .connecting: return "正在连接…"
        case .connected: return "已连接 · 实时接收"
        case .paused: return "已暂停（App 在后台）"
        case .reconnecting(let r): return "重连中 · \(r)"
        case .unauthorized: return "登录已失效"
        }
    }

    var color: Color {
        switch self {
        case .connected: return Theme.success
        case .reconnecting, .unauthorized: return Theme.danger
        default: return Theme.text3
        }
    }
}

enum Route: Hashable {
    case message(Int64)
    case settings
    /// 设置 →「管理」
    case keys
    case account
    case channels
    /// 设置 → 账户 →「端到端加密」
    case e2e
}

enum AttState: Equatable {
    case idle
    case downloading
    case done
    case failed(String)
}

/// 正在显示的恢复码；fromSetup：刚开启加密（完成后提示 T22），否则是更换恢复码
struct E2ERecoveryShow: Equatable {
    let code: String
    let fromSetup: Bool
}

/// 串行写盘（不占主线程）。退出登录后，之前排队的写入一律作废，不会把清掉的消息写回来
actor Saver {
    private var minSession = 0
    /// 已经写到盘上的最新代次：排队顺序被打乱时，比它旧的快照不再覆盖新的
    private var written = -1

    func save(_ s: PersistedState, gen: Int, session: Int) throws {
        guard session >= minSession, gen > written else { return }
        try Persistence.save(s)
        written = gen
    }

    func clear(session: Int) {
        minSession = session
        Persistence.clear()
    }
}

/// 全局状态：消息、已读、连接状态、同步循环、后台刷新、通知、Bark 设置。界面和后台任务共用这一份
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let refreshTaskID = "io.github.hongyile.huijian.refresh"

    let settings = Settings()

    @Published private(set) var messages: [Message] = [] { didSet { msgGen &+= 1; saveGen &+= 1; idIndex = nil } }
    @Published private(set) var read: Set<Int64> = [] { didSet { readGen &+= 1; saveGen &+= 1 } }
    /// 消息文件读完了（启动时在后台读）。读完之前首页显示「正在加载」，同步和写盘都等它
    @Published private(set) var loaded = false
    @Published private(set) var conn: ConnState = .loggedOut {
        // 确认登录失效（/v1/me 也 401：设备被移除或已退出）：删除本机为这个账号保存的加密钥匙（docs/e2ee-client.md §8）
        didSet { if conn == .unauthorized && oldValue != .unauthorized { e2eWipe() } }
    }
    @Published private(set) var lastContact: Date?
    @Published private(set) var channels: [String: ChannelSetting] = [:] { didSet { msgGen &+= 1 } }
    @Published private(set) var loggedIn = false
    @Published private(set) var bark: BarkConfig?
    @Published private(set) var serverFeatures: [String]?
    @Published private(set) var serverVersion = ""
    @Published private(set) var update: UpdateInfo?
    /// 应用内下载新版 IPA 的状态（设置 →「关于」）
    @Published private(set) var updateDownload: UpdateDownloadState = .idle
    /// 打开设置页时滚到哪一节（首页「可以更新了」横幅 → about）
    @Published var settingsAnchor: String?
    @Published private(set) var latestBuild = 0
    /// 本机有没有服务器管理权限（GET /v1/me 的 can_admin）；nil = 还没拉到
    @Published private(set) var canAdmin: Bool?
    /// 账号有没有设置密码（GET /v1/me 的 account.has_password）；nil = 还没拉到或旧服务端
    @Published private(set) var accountHasPassword: Bool?
    @Published private(set) var notifyAuth: UNAuthorizationStatus = .notDetermined
    @Published private(set) var attStates: [String: AttState] = [:]
    @Published var path: [Route] = []

    // 端到端加密（接线见 E2EModel.swift，逻辑见 E2E.swift，和 Mac 共用）
    /// GET /v1/e2e 的最近结果；nil = 还没取到（或服务端不支持）
    @Published var e2eState: E2E.State?
    /// 本机为当前账号保存的私钥（从钥匙串读出）
    @Published var e2eKeys: [String] = []
    /// 钥匙串读写失败的原因（加密页显示）
    @Published var e2eStorageError: String?
    /// 登录时关于加密的一句提示（例如私钥对不上 T43），加密页显示
    @Published var e2eLoginNote: String?
    /// 本机正在请求其他设备批准（§4.3）
    @Published var e2eRequest: E2E.ApprovalRequest?
    @Published var e2eRequestPhase: E2E.ApprovalRequest.Phase?
    /// 正在批准的其他设备（§5），按 device_id
    @Published var e2eApprovals: [String: E2E.Approval] = [:]
    @Published var e2eApprovalPhases: [String: E2E.Approval.Phase] = [:]
    /// 正在显示的恢复码（开启加密或更换恢复码后只显示这一次）。放在 App 状态里：离开页面再回来还在，点「完成」才清除（§4.1）
    @Published var e2eRecovery: E2ERecoveryShow?
    /// 更换恢复码结果不确定（T.recoveryUncertain）：加密页顶部提示，确认成功后自动显示恢复码页
    @Published var e2eRecoveryNote: String?
    /// 加密钥匙的安全存储：正常运行用钥匙串；自检换成内存（不碰钥匙串）
    var e2eSecrets: E2ESecrets = KeychainSecrets(service: Keychain.service + ".e2e")
    /// 登录时解开并核对过、但还没取到账号 id 没法保存的私钥（只在内存里），拿到账号 id 后保存（§2.1）
    var e2ePendingLoginKey: (sk: String, keys: [E2E.Key])?
    /// 进行中的开启（新钥匙对和恢复码存在钥匙串里）结果还没确认、服务端也还没开启：开启页提示重试（§4.1）
    @Published var e2ePendingSetup: E2E.SetupAttempt?
    var e2eRefreshing = false
    var e2eRefreshAgain = false
    var e2eDecrypting = false
    /// decryptPending 进行中又被调用：这一轮结束后再跑一轮
    var e2eDecryptAgain = false

    /// 登录会话编号：每次登录、退出都加一。还在路上的旧请求结果核对编号后直接作废
    private(set) var session = 0
    /// 应用内更新下载的代次和任务：退出、重新登录、换服务器时加一并取消，旧任务的结果直接作废
    private var updateGen = 0
    private var updateTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var syncID: UUID?
    private var saveTask: Task<Void, Never>?
    /// 正在进行的清盘（退出 / 换账号）；之后的写盘先等它完成，避免新消息被删掉
    private var clearTask: Task<Void, Never>?
    private(set) var active = false
    private let saver = Saver()
    private var monitor: NWPathMonitor?
    private var pathSeen = false
    private var pathDebounce: Task<Void, Never>?
    private var tokenCache: String?
    /// 演示 / 测试模式下不请求通知权限（模拟器上的授权弹窗会挡住截图）
    var skipNotifyPermission = false
    /// 启动时读消息文件的任务；同步（catchUp）、写盘、后台刷新都先等它
    private var loadTask: Task<Void, Never>?
    /// 清空本地数据的次数：读文件期间退出登录 / 换了账号，读出来的旧数据作废
    private var localResets = 0

    // 派生数据缓存：只在消息 / 已读 / 频道变化时重算，界面每次刷新直接取（连接状态、下载进度等变化不重算）
    private var msgGen = 0
    private var readGen = 0
    private var inboxCache: (gen: Int, list: [Message], topics: [String])?
    private var unreadCache: (msgGen: Int, readGen: Int, n: Int)?
    /// 消息 id → 下标（message(id) 用），消息列表一变就作废，下次用到时重建
    private var idIndex: [Int64: Int]?
    /// 附件文件在不在磁盘上：查过一次就记住，界面刷新不再反复查磁盘。删文件的地方同步清掉
    private var attOnDisk: [String: Bool] = [:]

    init() {
        _ = NetKind.shared      // 尽早开始监听网络，第一轮长轮询就知道是 Wi-Fi 还是蜂窝
        // 几千条消息（带 doc）的解码放到后台，不卡启动；读完再并入
        let mark = localResets
        loadTask = Task { [weak self] in
            let r = await Task.detached(priority: .userInitiated) { () -> Result<PersistedState, Error> in
                Result {
                    var s = try Persistence.loadChecked()
                    s.messages.sort { $0.id < $1.id }
                    return s
                }
            }.value
            self?.finishLoad(r, mark: mark)
        }
        // 有设备记录、但凭证读不到（极少见：钥匙串和备份文件都丢了）：进登录页，本地数据保留，
        // 同一服务器、同一设备重新登录后接着用
        loggedIn = !settings.deviceID.isEmpty && settings.token != nil
        conn = loggedIn ? .connecting : .loggedOut
        channels = Dictionary(settings.channels.map { ($0.topic, $0) }, uniquingKeysWith: { a, _ in a })
        lastContact = settings.lastContact
        bark = settings.barkOn ? BarkConfig(url: settings.barkURL, encrypted: settings.barkEncrypted) : nil
        serverFeatures = settings.serverFeatures
        serverVersion = settings.serverVersion
        if loggedIn { loadE2EKeys() }
    }

    /// 消息文件读完：并入内存。读完之前已经有的改动（例如点通知打开消息标的已读）保留
    private func finishLoad(_ r: Result<PersistedState, Error>, mark: Int) {
        defer { loaded = true }
        // 读的过程中退出登录 / 换了账号：文件已经清掉，旧数据不要了
        guard mark == localResets else { return }
        switch r {
        case .success(let s):
            let clean = !dirty
            if messages.isEmpty {
                messages = s.messages
            } else {
                let have = Set(messages.map(\.id))
                messages = (s.messages.filter { !have.contains($0.id) } + messages).sorted { $0.id < $1.id }
            }
            read.formUnion(s.read)
            // 内存和盘上一致：不用再写一遍
            if clean { savedGen = saveGen }
            if loggedIn { updateBadge() }
            // 上次锁定时收到的加密消息：本机已经有钥匙了（例如离线启动、还没取到加密状态）就先解开
            if !e2eKeys.isEmpty, messages.contains(where: \.e2eUnreadable) { Task { await decryptPending() } }
        case .failure:
            // 消息文件损坏：游标之前的消息拉不回来了，清掉游标，下次按首次同步重新拉最新 50 条
            settings.cursor = 0
            settings.initialSyncDone = false
            settings.changesCursor = nil
        }
    }

    /// 等启动时的消息文件读完
    func waitLoaded() async { await loadTask?.value }

    // MARK: 派生数据

    func channelName(_ topic: String) -> String {
        if let a = channels[topic]?.alias, !a.isEmpty { return a }
        return topic
    }

    func isHidden(_ topic: String) -> Bool { channels[topic]?.hidden == true }

    /// 收件箱：去掉隐藏频道和已归档的，新的在前
    var inbox: [Message] { inboxData().list }

    /// 收件箱里出现的频道：置顶的在前，再按手动顺序，其余按最近活跃（和 Mac 侧栏、设置 →「频道」一致）
    var inboxTopics: [String] { inboxData().topics }

    private func inboxData() -> (list: [Message], topics: [String]) {
        if let c = inboxCache, c.gen == msgGen { return (c.list, c.topics) }
        let list: [Message] = messages.filter { !isHidden($0.topic) && $0.archive != 1 }.reversed()
        var last: [String: Int64] = [:]
        for m in list { last[m.topic] = max(last[m.topic] ?? 0, m.id) }
        let topics = ManageRules.orderChannels(Array(last.keys), settings: channels, last: last)
        inboxCache = (msgGen, list, topics)
        return (list, topics)
    }

    func isUnread(_ m: Message) -> Bool { !read.contains(m.id) }

    var unreadCount: Int {
        if let c = unreadCache, c.msgGen == msgGen, c.readGen == readGen { return c.n }
        let n = inbox.reduce(0) { $0 + (!read.contains($1.id) && $1.priority >= 2 ? 1 : 0) }
        unreadCache = (msgGen, readGen, n)
        return n
    }

    func message(_ id: Int64) -> Message? {
        if idIndex == nil {
            // id 不会重复（合并时去重）；万一重复，和原来一样取后面那条
            idIndex = Dictionary(messages.indices.map { (messages[$0].id, $0) }, uniquingKeysWith: { _, b in b })
        }
        return idIndex?[id].map { messages[$0] }
    }

    /// 服务端是否支持 Bark 转发；nil = 还没拉到功能清单
    var barkSupported: Bool? { serverFeatures.map { $0.contains("bark") } }

    var updateAvailable: Bool { update != nil || latestBuild > AppInfo.build }

    /// GBox 软件源地址（服务端 0.5.7 起提供，功能 id ios.source）
    var gboxSourceURL: String { settings.server + "/ios/gbox.appsrc" }
    /// 服务端提供 GBox 软件源；还没拉到功能清单时按有处理
    var gboxSourceAvailable: Bool { serverFeatures.map { $0.contains("ios.source") } ?? true }

    func api() -> API? {
        if tokenCache == nil { tokenCache = settings.token }
        guard let token = tokenCache, let url = URL(string: settings.server) else { return nil }
        return API(server: url, token: token)
    }

    // MARK: 前后台

    func scenePhaseChanged(_ p: ScenePhase) {
        switch p {
        case .active:
            active = true
            startMonitor()
            Task { await refreshNotifyAuth() }
            // 回到前台时刷新加密状态（docs/e2ee-client.md §3），顺便提醒等待批准的设备（T50）
            if loggedIn { Task { await refreshE2E() } }
            if conn == .paused { conn = .connecting }
            // 上次被判定为登录失效：回到前台再用 /v1/me 复核一次（可能只是代理 / 强制门户返回的 401）
            if conn == .unauthorized { Task { await recheckAuth() } } else { startSync() }
        case .background:
            active = false
            stopSync()
            stopMonitor()
            if loggedIn && conn != .unauthorized { conn = .paused }
            scheduleRefresh()
            flushSave()
        default:
            break
        }
    }

    // MARK: 同步循环

    /// 前台时启动长轮询循环；force 时重启（网络变化、下拉刷新、通知点开的消息还没同步到）
    func startSync(force: Bool = false) {
        guard loggedIn, active, conn != .unauthorized else { return }
        if syncTask != nil && !force { return }
        syncTask?.cancel()
        let gen = session
        let id = UUID()
        syncID = id
        syncTask = Task { [weak self] in
            await self?.runLoop(gen)
            // 循环不管从哪条路径退出都清掉句柄（核对仍是同一个循环，不误清新启动的）
            if self?.syncID == id { self?.syncTask = nil }
        }
    }

    /// 自检用：模拟「收到过一次 401」后的状态；模拟本机有、服务端没有的消息
    func _testForceUnauthorized() { conn = .unauthorized; stopSync() }
    func _testRemove(_ ids: [Int64]) { removeLocal(ids) }

    /// 同步循环是否在跑（自检用）
    var syncRunning: Bool { syncTask != nil }

    func stopSync() {
        syncTask?.cancel()
        syncTask = nil
        syncID = nil
    }

    private func runLoop(_ gen: Int) async {
        var backoff: Double = 5
        var caughtUp = false
        /// 出错重连后先发一个不挂起的请求确认连通，再进入长轮询（否则要等一整轮长轮询才能显示「已连接」）
        var quick = false
        while !Task.isCancelled && gen == session {
            guard let api = api() else { relogin(); return }
            do {
                if !caughtUp {
                    conn = .connecting
                    try await catchUp(api, gen)
                    caughtUp = true
                    guard !Task.isCancelled, gen == session else { return }
                    conn = .connected
                    await refreshAux(api, gen)
                    continue
                }
                if quick {
                    try await poll(api, gen, wait: 0)
                    quick = false
                    guard !Task.isCancelled, gen == session else { return }
                    conn = .connected
                    continue
                }
                // 等待时长按所在网络自适应（Heartbeat.swift）：服务端 0.6.4 起最多 10 分钟，旧服务端固定 50 秒
                let net = NetKind.shared.snapshot
                let kind = net.kind
                let wait = Heartbeat.shared.wait(for: kind)
                let start = Date()
                let progress: Int
                do {
                    progress = try await poll(api, gen, wait: wait)
                } catch {
                    // 只记「这条网络把连接断了」：切后台、重启循环、换网络、断网引起的失败都不算
                    if !Task.isCancelled, gen == session, net.ready, NetKind.shared.snapshot.gen == net.gen, Heartbeat.countsAsDrop(error) {
                        Heartbeat.shared.record(kind, wait: wait, elapsed: Date().timeIntervalSince(start), outcome: .failed)
                    }
                    throw error
                }
                // 响应回来时循环可能已经被停掉（切到后台）：不能再把状态改回「已连接」
                guard !Task.isCancelled, gen == session else { return }
                if net.ready { Heartbeat.shared.record(kind, wait: wait, elapsed: Date().timeIntervalSince(start), outcome: .ok, gotData: progress > 0) }
                conn = .connected      // 收到响应才算连上
                backoff = 5
                // 防空转：要求挂起等待却在 2 秒内返回、又没有任何进展（没有新消息、游标没动；
                // 代理不支持长连接、服务端反复返回 changes_reset 等），等 5 秒再发下一轮
                if progress == 0 && Date().timeIntervalSince(start) < 2 {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            } catch {
                // 只有循环本身被取消（切后台、重启循环）或会话变了才退出；
                // URLError.cancelled 也可能来自 VPN / 代理 / TLS，按普通错误退避重试
                if Task.isCancelled || gen != session { return }
                if case APIError.unauthorized = error {
                    // 一次 401 不算数（反向代理、强制门户也会返回 401）：用 /v1/me 复核，它也 401 才判定登录失效
                    if await confirmUnauthorized(api) {
                        if gen == session { conn = .unauthorized }
                        return
                    }
                    if Task.isCancelled || gen != session { return }
                }
                conn = .reconnecting(error.isUnauthorized ? "服务器返回 401（可能是代理拦截）" : shortError(error))
                quick = true
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, 120)
            }
        }
    }

    /// 用 GET /v1/me 复核登录是否真的失效；网络错误等无法确认时按「没失效」处理
    private func confirmUnauthorized(_ api: API) async -> Bool {
        do { _ = try await api.me(); return false } catch { return error.isUnauthorized }
    }

    /// 状态为「登录已失效」时复核（回到前台、下拉刷新）：/v1/me 成功就恢复同步
    func recheckAuth() async {
        guard loggedIn, let api = api() else { return }
        let gen = session
        do {
            _ = try await api.me()
            guard gen == session else { return }
            if conn == .unauthorized { conn = .connecting }
            startSync(force: true)
        } catch {
            // 一次 401 不算数（§8）：再问一次 /v1/me，仍是 401 才判定登录失效（会删除本机加密钥匙）
            if gen == session, error.isUnauthorized, await confirmUnauthorized(api), gen == session { conn = .unauthorized }
        }
    }

    /// 下一次拉取的起点：只用已经落盘确认过的游标（写盘失败时游标不前进，下次会重新拉到这批消息）
    private var syncSince: Int64 { settings.cursor > 0 ? settings.cursor : (messages.last?.id ?? 0) }

    /// 这个账号第一次同步只取最新 50 条，标为已读、不提醒；之后从上次的位置补拉（最多 20 页），期间错过的消息照常提醒
    func catchUp(_ api: API, _ gen: Int) async throws {
        // 本地消息还没读完：先等（否则 syncSince、去重都按空列表算，写盘还会把空列表写回去）
        await waitLoaded()
        guard gen == session else { throw CancellationError() }
        if !settings.initialSyncDone {
            let page = try await api.messages(since: nil, limit: 50)
            guard gen == session else { throw CancellationError() }
            touchContact()
            let msgs = await prepareE2E(page.messages)      // 加密消息在后台线程解密
            guard gen == session else { throw CancellationError() }
            _ = merge(msgs)
            read.formUnion(page.messages.map(\.id))
            try await persistNow()
            guard gen == session else { throw CancellationError() }
            settings.cursor = max(page.nextSince ?? 0, page.messages.map(\.id).max() ?? 0)
            settings.initialSyncDone = true
            noteLatestBuild(page.latestBuild)
            updateBadge()
            return
        }
        var cur = syncSince
        for _ in 0..<20 {
            let cs = await changesSince(api)
            let page = try await api.messages(since: cur, limit: 200, changesSince: cs)
            guard gen == session else { throw CancellationError() }
            touchContact()
            noteLatestBuild(page.latestBuild)
            let next = max(cur, page.nextSince ?? cur, page.messages.map(\.id).max() ?? cur)
            try await deliver(page, cursor: next, changesSince: cs, gen)
            if page.messages.count < 200 || next == cur { return }
            cur = next
        }
    }

    /// 返回这一轮的进展：新消息条数 + 消息游标 / 变更游标是否前进（changes_reset 不算进展）
    @discardableResult
    private func poll(_ api: API, _ gen: Int, wait: Int) async throws -> Int {
        let since = syncSince
        let cs = await changesSince(api)
        let page = try await api.messages(since: since, limit: 200, wait: wait, changesSince: cs)
        guard gen == session else { throw CancellationError() }
        touchContact()
        noteLatestBuild(page.latestBuild)
        let next = max(since, page.nextSince ?? since, page.messages.map(\.id).max() ?? since)
        let fresh = try await deliver(page, cursor: next, changesSince: cs, gen)
        let changesMoved = cs != nil && !page.changesReset && (page.changesNext ?? cs!) > cs!
        return fresh + (next > since ? 1 : 0) + (changesMoved ? 1 : 0)
    }

    /// 上次写盘失败、内存里还有没落盘的改动
    private var needsPersist = false

    /// 合并新消息并提醒 → 应用其他设备的删除 / 归档 → 落盘 → 落盘成功后才推进两个游标（写盘失败抛错退避，下次重拉）
    @discardableResult
    private func deliver(_ page: MessagePage, cursor: Int64, changesSince cs: Int64?, _ gen: Int) async throws -> Int {
        var changes: [MsgChange] = []
        var nextChanges: Int64?
        if cs != nil {
            if page.changesReset || (page.changesEpoch != nil && settings.changesEpoch != nil && page.changesEpoch != settings.changesEpoch) {
                settings.changesCursor = nil      // 游标作废：下一轮重新对账
            } else {
                changes = page.changes
                nextChanges = page.changesNext
            }
        }
        // 同一页里既有新消息又有删除它的变更：先去掉再合并，不提醒
        let deleted = Set(changes.filter { $0.kind == "delete" }.map(\.id))
        // 加密消息先在后台线程解密，通知和列表用解开后的标题（未解锁时是 T60）
        let incoming = await prepareE2E(page.messages.filter { !deleted.contains($0.id) })
        guard gen == session else { throw CancellationError() }
        let fresh = merge(incoming)
        if !fresh.isEmpty {
            notifyNew(fresh)
            updateBadge()
        }
        let changed = applyChanges(changes)
        if !fresh.isEmpty || changed || needsPersist {
            needsPersist = true
            try await persistNow()
            needsPersist = false
        }
        guard gen == session else { throw CancellationError() }
        if cursor > settings.cursor { settings.cursor = cursor }
        if let n = nextChanges { settings.changesCursor = n }
        return fresh.count
    }

    /// 合并新消息，返回真正新增的（按 id 去重）
    @discardableResult
    func merge(_ incoming: [Message]) -> [Message] {
        let have = Set(messages.map(\.id))
        var seen = Set<Int64>()
        var fresh = incoming.filter { !have.contains($0.id) && seen.insert($0.id).inserted }
        if fresh.isEmpty { return [] }
        // 没经过 prepareE2E 的加密消息：先按「已锁定」显示，之后在后台解密
        for i in fresh.indices where fresh[i].isE2E && fresh[i].e2eStatus == nil {
            fresh[i].applyE2E(.locked)
        }
        // 有没解开的（包括 prepareE2E 时还锁着、合并时已经解锁的）且本机有钥匙：合并后在后台补解（§6.1）
        if !e2eKeys.isEmpty, fresh.contains(where: \.e2eUnreadable) { Task { await decryptPending() } }
        var all = messages + fresh
        all.sort { $0.id < $1.id }
        if all.count > Persistence.maxKeep {
            let cut = all.count - Persistence.maxKeep
            dropAttachments(Array(all.prefix(cut)), keep: all.suffix(Persistence.maxKeep))
            all = Array(all.suffix(Persistence.maxKeep))
        }
        messages = all
        return fresh
    }

    /// 超出保存条数被丢掉的消息：删掉它们已下载的附件（在后台删，不卡同步）。正在下载的不动，留给切后台时的缓存清理
    private func dropAttachments(_ gone: [Message], keep: ArraySlice<Message>) {
        let kept = Set(keep.flatMap { $0.attachments.map(\.id) })
        let atts = gone.flatMap(\.attachments).filter { !kept.contains($0.id) && attStates[$0.id] != .downloading }
        guard !atts.isEmpty else { return }
        for a in atts {
            attStates[a.id] = nil
            attOnDisk[a.id] = nil
        }
        let dirs = atts.map { AppPaths.attachmentFile($0).deletingLastPathComponent() }
        Task.detached(priority: .utility) {
            for d in dirs { try? FileManager.default.removeItem(at: d) }
        }
    }

    // MARK: 多设备同步：删除 / 归档（服务端 0.5.4 起，功能 id messages.manage）

    private var reconcileRetryAt = Date.distantPast

    /// 这一轮请求要带的变更游标；服务端不支持时为 nil。还没有游标（第一次、或游标作废）时先对账
    private func changesSince(_ api: API) async -> Int64? {
        guard serverFeatures?.contains("messages.manage") == true else { return nil }
        if settings.changesCursor == nil && Date() >= reconcileRetryAt {
            // 对账失败不影响收消息：这一轮不带变更游标，一分钟后再试（被取消的不算失败）
            do { try await reconcile(api) } catch { if !isCancellation(error) { reconcileRetryAt = Date().addingTimeInterval(60) } }
        }
        return settings.changesCursor
    }

    /// 对账：本地有、服务端已经没有的消息删掉（在别的设备或管理网页删除的），归档状态以服务端为准。
    /// 服务端纪元和上次不同（服务端重建或从备份恢复）时，服务端没有的消息不能当作被删除，只同步归档状态
    func reconcile(_ api: API) async throws {
        let gen = session
        // 只处理请求前已经同步到的消息：快照请求期间并发合并进来的新消息（id 比这个大）不在快照里，但不是被删了
        let upTo = settings.cursor
        // 账号是否开启了加密（§7.4）：还没取到状态时先问一次服务器（离线很久回来，可能期间在别处开启了），取不到用上次记下的
        var e2eOn = e2eState?.enabled ?? settings.e2eEnabled
        if e2eState == nil, e2eSupported, let st = try? await E2E.API(api).state() {
            guard gen == session else { return }
            e2eOn = st.enabled
        }
        let r = try await api.messageStates()
        guard gen == session else { return }
        let sameData = settings.changesEpoch == nil || r.epoch == nil || r.epoch == settings.changesEpoch
        if sameData {
            let missing = messages.filter { $0.id <= upTo && r.states[$0.id] == nil }
            let (remove, keep) = Self.reconcileMissing(missing, e2eAccount: e2eOn, kept: settings.e2ePlainKept)
            if !keep.isEmpty { settings.e2ePlainKept = settings.e2ePlainKept.union(keep) }
            removeLocal(remove)
        }
        applyArchive(r.states)
        try await persistNow()
        guard gen == session else { return }
        settings.changesEpoch = r.epoch
        settings.changesCursor = r.next
        if let c = try? await api.channels(), gen == session { setChannels(c) }
    }

    /// 应用其他设备的删除 / 归档 / 频道设置变更；返回本地消息是否有变化
    @discardableResult
    func applyChanges(_ changes: [MsgChange]) -> Bool {
        guard !changes.isEmpty else { return false }
        var del: [Int64] = [], purge: [Int64] = [], arch: [Int64: Int] = [:]
        var channelsChanged = false, keysChanged = false, accountChanged = false, e2eChanged = false
        for c in changes {
            switch c.kind {
            case "delete": del.append(c.id); arch[c.id] = nil
            // 「删除服务器上的明文消息」删掉的（服务端 0.7.0 起）：服务器上没有了，本机保留副本（docs/e2ee-client.md §7.4）
            case "purge": purge.append(c.id); arch[c.id] = nil
            case "archive": arch[c.id] = c.state ?? 0
            case "channels": channelsChanged = true
            // 设置实时同步（服务端 0.6.1 起）：pushkey、设备、账户在别处变了，重新拉取
            case "keys": keysChanged = true
            case "devices", "account": accountChanged = true
            // 开启加密、设备请求批准 / 已批准、只接受加密消息（服务端 0.7.0 起）
            case "e2e": e2eChanged = true
            default: break   // 不认识的 kind 忽略
            }
        }
        if e2eChanged { Task { await refreshE2E() } }
        if channelsChanged, let api = api() {
            let gen = session
            Task { if let c = try? await api.channels(), gen == session { setChannels(c) } }
        }
        if keysChanged || accountChanged { noteSettingsChanged(keys: keysChanged, account: accountChanged) }
        if !purge.isEmpty {
            // 本地有的记为「仅本机保留」，不删；对账时跳过它们。之后的 delete 变更照常删除（removeLocal 里移出集合）
            let local = Set(messages.map(\.id))
            let keep = purge.filter { local.contains($0) }
            if !keep.isEmpty { settings.e2ePlainKept = settings.e2ePlainKept.union(keep) }
        }
        let a = removeLocal(del)
        let b = applyArchive(arch)
        return a || b
    }

    /// 对账时跳过「仅本机保留」的消息（服务器的「删除明文消息」删掉了、本机保留副本，docs/e2ee-client.md §7.4）
    nonisolated static func withoutKept(_ ids: [Int64], kept: Set<Int64>) -> [Int64] {
        kept.isEmpty ? ids : ids.filter { !kept.contains($0) }
    }

    /// 对账时本地有、服务器上没有的消息怎么处理（§7.4）：「仅本机保留」的跳过；账号开启了加密时，本地的明文消息记入「仅本机保留」不删
    /// （变更记录只留 90 天，离线更久的设备收不到 purge），加密消息照常删除。返回（要删的，要新记入保留的）
    nonisolated static func reconcileMissing(_ missing: [Message], e2eAccount: Bool, kept: Set<Int64>) -> (remove: [Int64], keep: [Int64]) {
        let ids = withoutKept(missing.map(\.id), kept: kept)
        guard e2eAccount else { return (ids, []) }
        let plain = Set(missing.filter { !$0.isE2E }.map(\.id))
        return (ids.filter { !plain.contains($0) }, ids.filter { plain.contains($0) })
    }

    private func setChannels(_ list: [ChannelSetting]) {
        channels = Dictionary(list.map { ($0.topic, $0) }, uniquingKeysWith: { a, _ in a })
        settings.channels = list
        updateBadge()
    }

    @discardableResult
    private func applyArchive(_ states: [Int64: Int]) -> Bool {
        guard !states.isEmpty else { return false }
        var changed = false
        var list = messages
        for i in list.indices {
            if let s = states[list[i].id], list[i].archive != s { list[i].archive = s; changed = true }
        }
        if changed { messages = list; updateBadge() }
        return changed
    }

    /// 从本机移除消息：列表、已读标记、已下载的附件、通知中心里的通知
    @discardableResult
    private func removeLocal(_ ids: [Int64]) -> Bool {
        let set = Set(ids)
        let gone = messages.filter { set.contains($0.id) }
        guard !gone.isEmpty else { return false }
        let kept = settings.e2ePlainKept
        if !kept.isDisjoint(with: set) { settings.e2ePlainKept = kept.subtracting(set) }
        messages.removeAll { set.contains($0.id) }
        read.subtract(set)
        for a in gone.flatMap(\.attachments) {
            try? FileManager.default.removeItem(at: AppPaths.attachmentFile(a).deletingLastPathComponent())
            attStates[a.id] = nil
            attOnDisk[a.id] = nil
        }
        Notifier.remove(gone.map(\.id))
        updateBadge()
        return true
    }

    /// 上次频道、账号、功能清单都拉成功的时间。只记在内存里：App 启动后第一次、重新登录后第一次一定会拉
    private var auxFetchedAt: Date?
    /// 两次自动拉取辅助信息的最短间隔（回到前台、网络切换重启同步时）
    static let auxInterval: TimeInterval = 10 * 60

    /// 频道、账号（Bark 配置）、服务端功能清单、更新；每一项失败都不影响同步。
    /// 同步循环每次启动都会调：距上次全部成功不到 10 分钟就跳过（频道、账号的变化另有变更流实时同步）；
    /// force（下拉刷新、打开设置页）时照常拉
    func refreshAux(_ api: API, _ gen: Int, force: Bool = false) async {
        if !force, let t = auxFetchedAt, Date().timeIntervalSince(t) < Self.auxInterval { return }
        async let ch = try? api.channels()
        async let me = try? api.me()
        async let info = try? api.info()
        let (c, m, i) = await (ch, me, info)
        guard gen == session else { return }
        if let c { setChannels(c) }
        if let m { applyMe(m) }
        if let i {
            serverFeatures = (i.features ?? []).map(\.id)
            settings.serverFeatures = serverFeatures
            Heartbeat.shared.serverMax = serverFeatures?.contains("poll.long") == true ? (i.long_poll_max ?? Heartbeat.oldServerMax) : Heartbeat.oldServerMax
            serverVersion = i.version ?? ""
            settings.serverVersion = serverVersion
            // 功能清单到了才知道服务端有没有端到端加密
            if supports("e2e") == true { Task { await refreshE2E() } }
        }
        if c != nil && m != nil && i != nil { auxFetchedAt = Date() }
        await checkUpdate()
        updateBadge()
    }

    private func applyMe(_ m: Me) {
        applyBark(m.bark)
        // 用户名以服务端为准（可能在别的设备上改过）；配对码登录、账号还没有用户名时为空
        if let u = m.account?.username, !u.isEmpty { settings.username = u }
        settings.deviceName = m.name
        canAdmin = m.can_admin
        accountHasPassword = m.account?.has_password
        if let id = m.account?.id, id > 0 { noteAccountID(id) }
    }

    /// 记下账号 id（加密钥匙按「服务器 + 账号 id」存）；变了就重新读钥匙
    private func noteAccountID(_ id: Int64) {
        guard settings.accountID != id else { return }
        settings.accountID = id
        loadE2EKeys()
    }

    /// 下拉刷新：补拉一次、刷新频道和账号；正在退避等待时立即重连；之前判定为登录失效时先复核
    func refresh() async {
        guard loggedIn else { return }
        guard let api = api() else { relogin(); return }
        if conn == .unauthorized {
            await recheckAuth()
            if conn == .unauthorized { return }
        }
        let gen = session
        do {
            try await catchUp(api, gen)
            await refreshAux(api, gen, force: true)
            guard gen == session else { return }
            if case .reconnecting = conn { startSync(force: true) }
        } catch {
            if error.isUnauthorized, await confirmUnauthorized(api), gen == session { conn = .unauthorized; stopSync() }
        }
    }

    /// 记下和服务器通信的时间。每次长轮询都会调用：界面上的值最多 5 秒更新一次，避免首页频繁重算
    private func touchContact() {
        let now = Date()
        if let last = lastContact, now.timeIntervalSince(last) < 5 { return }
        lastContact = now
        settings.lastContact = now
    }

    private func noteLatestBuild(_ b: Int?) {
        guard let b, b > latestBuild else { return }
        latestBuild = b
        // 服务器上出现了比已知更新还新的版本，也要重新查（不然一直停在旧的「新版本」上）
        if b > AppInfo.build && (update == nil || b > update!.build) { Task { await checkUpdate() } }
    }

    /// 下载新版 IPA → 校验 sha256 和签名 → 弹出「打开方式」交给 GBox。校验不通过就报错、删文件。
    /// 已经下好、校验过且文件还在时直接再弹菜单
    func downloadUpdate() {
        guard let u = update, api() != nil else { return }
        switch updateDownload {
        case .downloading, .verifying: return
        case .ready(let f) where FileManager.default.fileExists(atPath: f.path) && f.lastPathComponent == UpdatePackage.fileName(u):
            shareUpdate()
            return
        case .ready(let f): UpdatePackage.remove(f)
        default: break
        }
        updateGen += 1
        let gen = updateGen
        updateDownload = .downloading(0)
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let dest = try await self.fetchVerifiedUpdate(u) { [weak self] p in
                    guard let self, gen == self.updateGen, case .downloading = self.updateDownload else { return }
                    self.updateDownload = p < 1 ? .downloading(p) : .verifying
                }
                // 下载期间退出 / 重新登录（已经被重置），或者服务器上的新版本换了：这个包作废
                guard gen == self.updateGen else { UpdatePackage.remove(dest); return }
                guard u.build == self.update?.build else {
                    UpdatePackage.remove(dest)
                    self.updateDownload = .idle
                    return
                }
                self.updateDownload = .ready(dest)
                self.shareUpdate()
            } catch {
                guard gen == self.updateGen else { return }
                self.updateDownload = error is CancellationError ? .idle : .failed(shortError(error))
            }
            if gen == self.updateGen { self.updateTask = nil }
        }
    }

    /// 停掉正在进行的下载、回到初始状态（退出、重新登录、换服务器时）。已经交给 GBox 的文件不删，等下次启动清理
    func resetUpdateDownload() {
        updateGen += 1
        updateTask?.cancel()
        updateTask = nil
        if case .ready(let f) = updateDownload { UpdatePackage.remove(f) }
        updateDownload = .idle
    }

    /// 下载并校验（防降级 + sha256 + 签名），返回临时子目录里的 Huijian-<版本>-<build>.ipa。
    /// 任何一步失败（包括被取消）都删掉这次的文件再抛错。自检直接调它（不弹菜单）
    func fetchVerifiedUpdate(_ u: UpdateInfo, progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> URL {
        guard let api = api() else { throw UpdateError.msg("还没有登录") }
        try UpdatePackage.checkNewer(u, than: AppInfo.build)
        let dest = UpdatePackage.newFile(u)
        do {
            try await api.downloadUpdate(u, to: dest) { p in Task { @MainActor in progress(p) } }
            try Task.checkCancellation()
            let pk = AppInfo.updatePublicKey
            try await Task.detached(priority: .userInitiated) {
                try UpdatePackage.verify(file: dest, info: u, publicKey: pk, currentBuild: AppInfo.build)
            }.value
            try Task.checkCancellation()
            return dest
        } catch {
            UpdatePackage.remove(dest)
            throw error
        }
    }

    /// 弹出「打开方式」。交出去以后不删临时 IPA（GBox 可能还在拷贝），App 下次启动时清理；没选就关掉时保留，可以再点一次
    func shareUpdate() {
        guard case .ready(let f) = updateDownload else { return }
        let gen = updateGen
        OpenInPresenter.shared.present(f) { [weak self] app, viaOpenIn in
            guard let self, gen == self.updateGen, case .ready(let cur) = self.updateDownload, cur == f else { return }
            self.updateDownload = .handedOff(app: app, viaOpenIn: viaOpenIn)
        }
    }

    func checkUpdate() async {
        guard let api = api() else { return }
        let gen = session
        do {
            var u = try await api.update(build: AppInfo.build)
            guard gen == session else { return }
            // 防降级：服务器给的不比当前新，当作没有更新
            if let x = u, x.build <= AppInfo.build { u = nil }
            // 服务器上的新版本变了：之前下好的包作废（正在下载 / 校验时不打断，下完发现版本不对会丢弃）
            if u?.build != update?.build {
                switch updateDownload {
                case .downloading, .verifying: break
                case .ready(let f): UpdatePackage.remove(f); updateDownload = .idle
                default: updateDownload = .idle
                }
            }
            update = u
        } catch {}
    }

    // MARK: 网络变化

    private func startMonitor() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] p in
            let ok = p.status == .satisfied
            Task { @MainActor in self?.pathChanged(ok) }
        }
        m.start(queue: DispatchQueue(label: "huijian.net"))
        monitor = m
    }

    private func stopMonitor() {
        monitor?.cancel()
        monitor = nil
        pathSeen = false
        pathDebounce?.cancel()
    }

    /// 网络恢复或切换（Wi-Fi ↔ 蜂窝）时取消当前请求立即重连，不等退避
    /// 网络有任何变化（断网恢复、Wi-Fi ↔ 蜂窝、换了一个 Wi-Fi——接口名可能都是 en0，所以不比较接口）：
    /// 网络可用时 1 秒内合并成一次，取消当前请求立即重连，不等长轮询超时或退避
    private func pathChanged(_ ok: Bool) {
        guard pathSeen else { pathSeen = true; return }    // 开始监听时的第一次回调只是当前状态
        pathDebounce?.cancel()
        guard ok else { return }
        pathDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self, self.conn != .unauthorized else { return }
            self.startSync(force: true)
        }
    }

    // MARK: 已读

    /// removeNotifications = false：调用方随后自己一次性撤掉全部通知（全部已读）
    func markRead(_ ids: [Int64], removeNotifications: Bool = true) {
        let new = ids.filter { !read.contains($0) }
        guard !new.isEmpty else { return }
        read.formUnion(new)
        if removeNotifications { Notifier.remove(new) }
        updateBadge()
        scheduleSave()
    }

    func markUnread(_ id: Int64) {
        guard read.contains(id) else { return }
        read.remove(id)
        updateBadge()
        scheduleSave()
    }

    /// 打开了某条消息：标为已读，撤掉它的通知和汇总
    func opened(_ id: Int64) {
        markRead([id])
        Notifier.opened(id)
    }

    /// 全部已读：撤掉所有消息通知和汇总
    func markAllRead() {
        markRead(inbox.map(\.id), removeNotifications: false)
        Notifier.removeAll()
    }

    func updateBadge() { Notifier.setBadge(loggedIn ? unreadCount : 0) }

    // MARK: 写盘

    private func snapshot() -> PersistedState { PersistedState(messages: messages, read: read) }

    /// 写盘代次：消息 / 已读每改一次加一；savedGen 是最近一次写盘成功的快照代次
    private var saveGen = 0
    private var savedGen = 0
    /// 内存里有还没写到盘上的改动
    private var dirty: Bool { saveGen != savedGen }

    /// 立即写盘（同步落盘后才推进游标的路径用它，不看 dirty）。启动时的读文件、退出时的清盘都先等完
    func persistNow() async throws {
        await loadTask?.value
        await clearTask?.value
        let gen = saveGen
        try await saver.save(snapshot(), gen: gen, session: session)
        savedGen = max(savedGen, gen)
    }

    /// 已读状态变化：0.8 秒内合并成一次写盘（到时已经被别的写盘带上了就不再写）
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self, self.dirty else { return }
            try? await self.persistNow()
        }
    }

    /// 切到后台时：有没写完的改动才写盘，再把附件缓存控制在上限以内；向系统申请一点后台时间，做完再结束
    private func flushSave() {
        saveTask?.cancel()
        let needSave = dirty
        let bg = UIApplication.shared.beginBackgroundTask(withName: "huijian.save")
        Task {
            if needSave { try? await persistNow() }
            await trimAttachmentCache()
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }
    }

    // MARK: 通知

    /// 没配 Bark 时，P3 以上、服务端没标静默、不在隐藏频道的新消息发本地通知；配了 Bark 就不发（锁屏提醒由 Bark 负责）
    static func shouldNotify(_ m: Message, barkOn: Bool, hidden: Bool) -> Bool {
        !barkOn && !hidden && !m.silent && m.priority >= 3
    }

    private func notifyNew(_ fresh: [Message]) {
        let alert = fresh.filter { Self.shouldNotify($0, barkOn: settings.barkOn, hidden: isHidden($0.topic)) }
        if alert.isEmpty { return }
        let gen = session
        // 投递是排队异步执行的：轮到时再核对会话，退出登录后不会补发旧账号的通知
        Notifier.post(alert, channelName: { [weak self] in self?.channelName($0) ?? $0 },
                      valid: { [weak self] in self?.session == gen && self?.loggedIn == true })
    }

    func refreshNotifyAuth() async {
        notifyAuth = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestNotifyPermission() async {
        guard !skipNotifyPermission else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshNotifyAuth()
    }

    // MARK: 打开消息（通知、Bark 的 huijian://message/<id>）

    static func messageID(from url: URL) -> Int64? {
        guard let s = url.scheme?.lowercased(), s == "huijian" || s == "hongyan", url.host?.lowercased() == "message" else { return nil }
        return url.pathComponents.first { $0 != "/" }.flatMap { Int64($0) }
    }

    func open(url: URL) {
        if let id = Self.messageID(from: url) { openMessage(id) }
    }

    /// push = true：在当前页面上叠一层（正文里点 huijian://message/<id>，返回时回到原来那条）；
    /// 否则替换整个导航栈（点通知、Bark 深链）
    func openMessage(_ id: Int64, push: Bool = false) {
        guard loggedIn else { return }
        if push, !path.isEmpty {
            if path.last != .message(id) { path.append(.message(id)) }
        } else {
            path = [.message(id)]
        }
        // 从 Bark 点进来时，这条消息可能还没同步到本机：立即重连补拉（只有比已同步位置新的才可能补到）
        // 本地消息还没读完时不急：读完后同步循环本来就会补拉
        if loaded && message(id) == nil && id > settings.cursor { startSync(force: true) }
    }

    // MARK: 后台刷新（BGAppRefreshTask，系统决定什么时候跑，尽力而为）

    func scheduleRefresh() {
        guard loggedIn, conn != .unauthorized else { return }
        let r = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let t = Task { @MainActor [weak self] in
            let ok = await self?.backgroundFetch() ?? false
            task.setTaskCompleted(success: ok)
        }
        task.expirationHandler = { t.cancel() }
    }

    /// 后台拉一次（不长轮询）：补拉新消息、落盘、按需发本地通知、更新角标
    func backgroundFetch() async -> Bool {
        // 后台冷启动：先等消息文件读完（文件损坏时会重置 initialSyncDone）
        await waitLoaded()
        guard loggedIn, settings.initialSyncDone, conn != .unauthorized, let api = api() else { return false }
        let gen = session
        do {
            try await catchUp(api, gen)
            return true
        } catch {
            if error.isUnauthorized, await confirmUnauthorized(api), gen == session { conn = .unauthorized }
            return false
        }
    }

    // MARK: 设置实时同步（keys / devices / account）

    /// 本账号的 pushkey（Pushkey 页、发送示例用）；nil = 还没拉过
    @Published private(set) var keys: [PushKey]?
    /// 本机对每把 key 的接收方式；服务端不支持时为 nil
    @Published private(set) var keyModes: [Int64: String]?
    /// 账号详情和设备列表（账户与设备页用）；nil = 还没拉过
    @Published private(set) var accountDetail: AccountDetail?
    private var pendingKeysRefresh = false
    private var pendingAccountRefresh = false
    private var settingsRefreshTask: Task<Void, Never>?
    /// 自检用：实际重新拉取的次数（连续多条变更合并成一次）
    private(set) var settingsRefreshCount = (keys: 0, account: 0)

    /// 收到 keys / devices / account 变更：0.3 秒内连续到的合并成一次，在后台重新拉取
    func noteSettingsChanged(keys: Bool, account: Bool) {
        pendingKeysRefresh = pendingKeysRefresh || keys
        pendingAccountRefresh = pendingAccountRefresh || account
        guard settingsRefreshTask == nil else { return }
        let gen = session
        settingsRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.runSettingsRefresh(gen)
        }
    }

    private func runSettingsRefresh(_ gen: Int) async {
        let k = pendingKeysRefresh, a = pendingAccountRefresh
        pendingKeysRefresh = false
        pendingAccountRefresh = false
        settingsRefreshTask = nil
        guard gen == session, loggedIn, let api = api() else { return }
        if k {
            settingsRefreshCount.keys += 1
            try? await reloadKeys()
        }
        if a {
            settingsRefreshCount.account += 1
            // 设备变更包括本机名称、管理权限：/v1/me 一起刷新（接收规则、Bark 只在本机改，服务端不广播）
            do {
                let m = try await api.me()
                guard gen == session else { return }
                applyMe(m)
                try await reloadAccount()
            } catch {
                guard gen == session else { return }
                if error.isUnauthorized { await handleRemoved(api, gen) }
            }
        }
    }

    /// 本机被移除（设备列表里没有本机、或接口返回 401）：复核后按「登录失效」处理
    private func handleRemoved(_ api: API, _ gen: Int) async {
        guard await confirmUnauthorized(api), gen == session else { return }
        conn = .unauthorized
        stopSync()
    }

    /// 本机是否还在设备列表里（被移除的设备 revoked = true）
    nonisolated static func selfRemoved(_ d: AccountDetail, deviceID: String) -> Bool {
        !deviceID.isEmpty && !d.devices.contains { $0.id == deviceID && !$0.revoked }
    }

    func reloadKeys() async throws {
        let api = try requireAPI()
        let gen = session
        let list = try await api.keys()
        guard gen == session else { return }
        keys = list
        if keyModes == nil || supports("subscriptions") != false { await reloadModes(api) }
    }

    private func reloadModes(_ api: API) async {
        let gen = session
        guard supports("subscriptions") != false, let s = try? await api.subscriptions(), gen == session else { return }
        keyModes = Dictionary(s.map { ($0.pushkey_id, $0.mode) }, uniquingKeysWith: { a, _ in a })
    }

    func reloadAccount() async throws {
        let api = try requireAPI()
        let gen = session
        let d: AccountDetail
        do { d = try await api.account() } catch {
            if error.isUnauthorized { await handleRemoved(api, gen) }
            throw error
        }
        guard gen == session else { return }
        accountDetail = d
        noteAccount(d.account)
        if Self.selfRemoved(d, deviceID: settings.deviceID) { await handleRemoved(api, gen) }
    }

    /// 本机的修改（新建、改名、换 key、吊销）直接更新列表，不等变更流。
    /// gen：发请求前记下的 session；请求期间退出 / 换了账号时结果作废
    func noteKey(_ k: PushKey, session gen: Int) {
        guard gen == session else { return }
        var list = keys ?? []
        if let i = list.firstIndex(where: { $0.id == k.id }) { list[i] = k } else { list.append(k) }
        keys = list
        if keyModes != nil, keyModes?[k.id] == nil { keyModes?[k.id] = "notify" }
    }

    func noteKeyRemoved(_ id: Int64, session gen: Int) {
        guard gen == session else { return }
        keys?.removeAll { $0.id == id }
    }

    func noteKeyMode(_ id: Int64, _ mode: String, session gen: Int) {
        guard gen == session else { return }
        keyModes?[id] = mode
    }

    // MARK: 管理（pushkey、账户、频道；和 Mac 客户端对齐）

    /// 服务端有没有某个功能：true / false；nil = 还没拉到功能清单（按有处理，调用时服务端说没有再提示）
    func supports(_ feature: String) -> Bool? { serverFeatures.map { $0.contains(feature) } }

    /// 服务端明确没有这个功能时的提示；有或还不知道时为 nil
    func tooOld(_ feature: String, since: String) -> String? {
        supports(feature) == false ? "需要服务端 \(since) 以上（当前 \(serverVersion.isEmpty ? "旧版本" : serverVersion)），更新服务端后可用" : nil
    }

    func requireAPI() throws -> API {
        guard let api = api() else { throw APIError.unauthorized }
        return api
    }

    /// 设置 / 修改用户名和密码，成功后更新本地显示的用户名。期间退出 / 换了账号时不写回
    func setCredentials(username: String, password: String, current: String) async throws -> AccountInfo {
        let gen = session
        let a = try await requireAPI().setCredentials(username: ManageRules.normalizeUsername(username), password: password, current: current)
        guard gen == session else { throw CancellationError() }
        if !a.username.isEmpty { settings.username = a.username }
        accountHasPassword = a.has_password
        return a
    }

    /// 给本机改名（其他设备和管理后台的设备列表里显示）
    func renameDevice(_ name: String) async throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw APIError.invalid("名称不能为空") }
        let gen = session
        let m = try await requireAPI().renameMe(ManageRules.clip(n, 40))
        guard gen == session else { throw CancellationError() }
        settings.deviceName = m.name
    }

    /// 管理页（账户）拉到账号详情时顺便更新本地显示
    func noteAccount(_ a: AccountInfo) {
        if !a.username.isEmpty { settings.username = a.username }
        accountHasPassword = a.has_password
        if a.id > 0 { noteAccountID(a.id) }
    }

    /// 本机所有消息里出现过的频道（含隐藏的），按「置顶 → 手动顺序 → 最近活跃」排序
    var allTopics: [String] {
        var last: [String: Int64] = [:]
        for m in messages { last[m.topic] = max(last[m.topic] ?? 0, m.id) }
        // 设置过、但本机暂时没有消息的频道（例如只在别的设备上收过）也列出来，方便改设置
        for t in channels.keys where last[t] == nil { last[t] = 0 }
        return ManageRules.orderChannels(Array(last.keys), settings: channels, last: last)
    }

    func channel(_ topic: String) -> ChannelSetting { channels[topic] ?? ChannelSetting(topic: topic) }

    var hasManualChannelOrder: Bool { channels.values.contains { $0.sort > 0 } }

    /// 修改频道设置（只改传了的字段）。先改本地，失败时只把这个频道恢复原样并抛错（不影响期间别处同步来的其他频道）
    func updateChannel(_ topic: String, alias: String? = nil, hidden: Bool? = nil, muted: Bool? = nil, pinned: Bool? = nil) async throws {
        let api = try requireAPI()
        let gen = session
        let old = channels[topic]
        var c = channel(topic)
        if let alias { c.alias = alias }
        if let hidden { c.hidden = hidden }
        if let muted { c.muted = muted }
        if let pinned { c.pinned = pinned }
        setChannel(topic, c)
        do {
            let saved = try await api.updateChannel(topic, alias: alias, hidden: hidden, muted: muted, pinned: pinned)
            guard gen == session else { return }
            setChannel(topic, saved)
        } catch {
            guard gen == session else { throw error }
            setChannel(topic, old)
            throw error
        }
    }

    private func setChannel(_ topic: String, _ c: ChannelSetting?) {
        var next = channels
        next[topic] = c
        setChannels(Array(next.values))
    }

    /// 手动排序：传入看得到的频道的新顺序；空列表 = 恢复按最近活跃排序。看不到的频道（隐藏的）保留原来的位置。
    /// 失败时重新拉一次服务端的频道设置
    func setChannelOrder(_ visible: [String]) async throws {
        let api = try requireAPI()
        let gen = session
        let order = visible.isEmpty ? [] : ManageRules.mergedOrder(visible, settings: channels)
        var next = channels
        for k in next.keys { next[k]?.sort = 0 }
        for (i, t) in order.enumerated() {
            var c = next[t] ?? ChannelSetting(topic: t)
            c.sort = i + 1
            next[t] = c
        }
        setChannels(Array(next.values))
        do {
            try await api.setChannelOrder(order)
        } catch {
            if gen == session, let c = try? await api.channels(), gen == session { setChannels(c) }
            throw error
        }
    }

    /// 删除频道：服务器上这个频道的全部消息、附件和设置（所有设备同步）。返回服务端删除的条数
    @discardableResult
    func deleteChannel(_ topic: String) async throws -> Int {
        let api = try requireAPI()
        let gen = session
        let local = messages.filter { $0.topic == topic }.map(\.id)
        let n = try await api.deleteChannel(topic)
        guard gen == session else { return n }   // 期间退出 / 换了账号：不动本地
        removeLocal(local)
        setChannel(topic, nil)
        scheduleSave()
        return n
    }

    /// 注册新账号（服务端开放注册时）。成功后和登录一样进入
    func register(server raw: String, username: String, password: String, name: String) async throws {
        let s = API.normalize(raw)
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else { throw APIError.invalid("服务器地址格式不对") }
        let u = ManageRules.normalizeUsername(username)
        if let p = ManageRules.usernameProblem(u) { throw APIError.invalid(p) }
        if u.isEmpty { throw APIError.invalid("请填写用户名") }
        if password.isEmpty { throw APIError.invalid("请设置密码") }
        // 服务器拿不到密码，强度只能在本机检查（docs/e2ee-client.md §2.2）
        if let p = Core.passwordProblem(password, username: u) { throw APIError.invalid(p) }
        try await passwordSignIn(server: s, url: url, username: u, password: password, name: name, register: true)
    }

    // MARK: 登录 / 退出

    func login(server raw: String, username: String, password: String, code: String, usePair: Bool, name: String) async throws {
        let s = API.normalize(raw)
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else { throw APIError.invalid("服务器地址格式不对") }
        if usePair {
            let r = try await API(server: url, token: nil).pair(code: code, name: name, fingerprint: DeviceFingerprint.value)
            signedIn(server: s, r, username: "")
        } else {
            try await passwordSignIn(server: s, url: url, username: username, password: password, name: name, register: false)
        }
    }

    /// 账号密码登录 / 注册，新登录协议（docs/e2ee-client.md §2）：先取派生参数，在本机算凭证，从不发送密码原文
    /// （旧服务端、从未升级的账号除外）；旧账号登录后自动升级；登录响应里带了用密码锁住的私钥时解开、核对后存进钥匙串
    private func passwordSignIn(server s: String, url: URL, username: String, password: String, name: String, register: Bool) async throws {
        let r: E2E.LoginResult
        do {
            r = try await E2E.login(server: API(server: url, token: nil), authed: { API(server: url, token: $0) as E2ETransport },
                                    serverID: s, username: username, password: password,
                                    device: .init(name: name, platform: "ios", fingerprint: DeviceFingerprint.value),
                                    register: register, marks: e2eMarks, secrets: e2eSecrets)
        } catch let f as E2E.Failure where f.kind == .unsupported {
            if register { throw APIError.unsupported }
            throw APIError.invalid("这个服务端版本较旧，还不支持账号登录（需要 0.5.0 以上），请用配对码配对")
        }
        let lr: LoginResult
        do { lr = try JSONCoding.decoder.decode(LoginResult.self, from: r.response) } catch { throw APIError.invalid("服务器返回的数据格式不对") }
        e2ePendingLoginKey = r.pendingKey
        signedIn(server: s, lr, username: username, accountID: r.accountID)
        e2eLoginNote = r.note
    }

    /// 登录成功。换了服务器或设备记录（换账号）时清掉旧消息和游标，不会混在一起。
    /// accountID：登录时已经取到的账号 id（加密钥匙按它存）；配对码登录时为 nil，之后从 /v1/me 取
    func signedIn(server: String, _ r: LoginResult, username: String, accountID: Int64? = nil) {
        stopSync()
        session += 1
        resetUpdateDownload()
        let same = settings.server == server && settings.deviceID == r.device_id
        if !same {
            // §8：换了账号 / 服务器才删旧账号的加密钥匙。服务器地址只是换了写法（规范化后相同）且是同一台设备记录、
            // 或者登录时已知的账号 id 和原来相同，钥匙属于同一个账号，保留
            let oldScope = e2eRing?.scope
            let sameAccount = (E2E.normalizeServer(server) == e2eServerID && settings.deviceID == r.device_id)
                || (accountID.map { E2E.scope(server: server, accountID: $0) } == oldScope && oldScope != nil)
            resetLocal(keepE2EKeys: sameAccount)
        }
        settings.server = server
        settings.token = r.token
        tokenCache = r.token
        settings.deviceID = r.device_id
        settings.deviceName = r.name
        // 同一台设备用配对码重新登录时，保留之前记下的用户名
        if !same || !username.isEmpty { settings.username = username }
        if let accountID { settings.accountID = accountID }
        auxFetchedAt = nil
        loggedIn = true
        conn = .connecting
        loadE2EKeys()
        Task { await requestNotifyPermission() }
        startSync(force: true)
    }

    /// 重新登录（登录失效、凭证读不到）：只丢掉凭证、回到登录页，本地消息、已读、游标都保留。
    /// 同一服务器、同一设备（指纹相同，服务端沿用原设备记录）登录后接着用；换了服务器或设备才清空
    func relogin() {
        stopSync()
        session += 1
        resetUpdateDownload()
        settings.token = nil
        tokenCache = nil
        loggedIn = false
        conn = .loggedOut
        path = []
    }

    /// 退出登录：先停同步，再清本地数据和通知，最后通知服务器让 token 失效
    func logout(notifyServer: Bool) {
        let api = notifyServer ? self.api() : nil
        // §8：删除本机为这个账号保存的私钥和设备钥匙对（「已升级」标记保留）。要在清掉服务器地址、账号 id 之前
        e2eWipe()
        stopSync()
        session += 1
        settings.token = nil
        tokenCache = nil
        resetLocal()
        settings.resetAccountState()
        loggedIn = false
        conn = .loggedOut
        path = []
        Notifier.removeAll()
        Notifier.setBadge(0)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskID)
        if let api { Task { try? await api.logout() } }
    }

    private func resetLocal(keepE2EKeys: Bool = false) {
        saveTask?.cancel()
        localResets += 1
        auxFetchedAt = nil
        let gen = session
        let saver = self.saver
        clearTask = Task { await saver.clear(session: gen) }
        PreviewCache.clear()
        Thumbnail.clear()
        settings.channels = []
        // 附件缓存立即删（不等写盘队列）
        try? FileManager.default.removeItem(at: AppPaths.attDir)
        messages = []
        read = []
        channels = [:]
        attStates = [:]
        attOnDisk = [:]
        bark = nil
        update = nil
        resetUpdateDownload()
        canAdmin = nil
        accountHasPassword = nil
        keys = nil
        keyModes = nil
        accountDetail = nil
        settingsRefreshTask?.cancel()
        settingsRefreshTask = nil
        pendingKeysRefresh = false
        pendingAccountRefresh = false
        // 端到端加密（§8）：换账号、换服务器、读不到凭证回登录页后登录了另一个账号时，旧账号的私钥、设备钥匙对、
        // 进行中的开启都删掉。这时服务器地址和账号 id 还是旧的。正在进行的批准流程先停下（之后不再写钥匙串），再删
        e2eRequest?.stop()
        for a in e2eApprovals.values { a.stop() }
        if !keepE2EKeys, let ring = e2eRing {
            do { try ring.removeAll() } catch { NSLog("回笺 删除旧账号的加密钥匙失败: \(error.localizedDescription)") }
        }
        e2eState = nil
        e2eKeys = []
        e2eStorageError = nil
        e2eLoginNote = nil
        e2eRequest = nil
        e2eRequestPhase = nil
        e2eApprovals = [:]
        e2eApprovalPhases = [:]
        e2eRecovery = nil
        e2eRecoveryNote = nil
        e2ePendingSetup = nil
        settings.accountID = nil
        settings.e2eEnabled = false
        settings.e2ePlainKept = []
        latestBuild = 0
        lastContact = nil
        settings.cursor = 0
        settings.initialSyncDone = false
        settings.lastContact = nil
        settings.changesCursor = nil
        settings.changesEpoch = nil
        // 换服务器后不能沿用旧服务端的功能清单（Bark 可用、版本号、GBox 软件源）
        serverFeatures = nil
        serverVersion = ""
        settings.serverFeatures = nil
        settings.serverVersion = ""
        reconcileRetryAt = .distantPast
        needsPersist = false
    }

    // MARK: 附件

    /// 界面每次刷新都会调：磁盘只查一次，结果记在 attOnDisk
    func attState(_ a: Attachment) -> AttState {
        if let s = attStates[a.id] { return s }
        if let d = attOnDisk[a.id] { return d ? .done : .idle }
        let d = FileManager.default.fileExists(atPath: AppPaths.attachmentFile(a).path)
        attOnDisk[a.id] = d
        return d ? .done : .idle
    }

    /// 附件缓存（Caches/att）的上限
    static let attCacheLimit: Int64 = 300 << 20

    /// 切到后台时把附件缓存控制在上限以内：按最近使用时间从旧到新删；正在下载的、导航栈里打开着的消息的附件不删
    private func trimAttachmentCache() async {
        var protect = Set<String>()
        for (id, s) in attStates where s == .downloading { protect.insert(AppPaths.attachmentDirName(id)) }
        for case .message(let mid) in path {
            for a in message(mid)?.attachments ?? [] { protect.insert(AppPaths.attachmentDirName(a.id)) }
        }
        let limit = Self.attCacheLimit
        let removed = await Task.detached(priority: .utility) { AttCache.trim(limit: limit, protect: protect) }.value
        guard !removed.isEmpty else { return }
        let gone = Set(removed)
        for a in messages.flatMap(\.attachments) where gone.contains(AppPaths.attachmentDirName(a.id)) {
            if attStates[a.id] != .downloading { attStates[a.id] = nil }
            attOnDisk[a.id] = nil
        }
    }

    func download(_ a: Attachment) async {
        guard attState(a) != .downloading, let api = api() else { return }
        let gen = session
        let file = AppPaths.attachmentFile(a)
        attStates[a.id] = .downloading
        do {
            if let key = a.key {
                // 端到端加密的附件（docs/e2ee-client.md §6.4）：先下载密文（照常校验密文的 sha256），再解密成真实文件名；
                // 成功后删除密文，失败时不留文件，卡片显示「解密失败」
                let fm = FileManager.default
                let enc = fm.temporaryDirectory.appendingPathComponent("e2e-att-\(UUID().uuidString)")
                defer { try? fm.removeItem(at: enc) }
                try await api.download(a, to: enc)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: file)
                do { try await E2E.decryptAttachment(key: key, src: enc, dst: file) } catch {
                    try? fm.removeItem(at: file)
                    throw APIError.invalid("解密失败")
                }
            } else {
                try await api.download(a, to: file)
            }
            // 下载期间退出了登录 / 换了账号：附件不属于现在的账号，删掉
            guard gen == session else { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()); return }
            attStates[a.id] = .done
        } catch {
            guard gen == session else { return }
            attStates[a.id] = .failed(shortError(error))
        }
    }

    /// 加密消息重新解密后整体替换（E2EModel.swift 用；messages 的 setter 只在这个文件里可见）。
    /// 内容变了的消息清掉列表摘要缓存，再排队写盘
    func replaceMessages(_ list: [Message]) {
        let old = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        PreviewCache.forget(list.filter { m in old[m.id].map { $0 != m } ?? false }.map(\.id))
        messages = list
        updateBadge()
        scheduleSave()
    }

    /// 打开设置 → 账户 →「端到端加密」（列表顶部的锁定横幅、设备请求批准的通知）
    func openE2E() {
        guard loggedIn else { return }
        path = [.settings, .account, .e2e]
    }

    // MARK: 测试推送

    /// 发一条 P4 测试推送。不指定 key 时用本账号第一把有效的 pushkey；账号还没有 key 时新建一把 default
    func sendTestPush(with pushkey: PushKey? = nil) async throws {
        guard let api = api() else { throw APIError.unauthorized }
        let key: String
        if let pushkey { key = pushkey.key }
        else if let k = try await api.keys().first(where: { !($0.revoked ?? false) }) { key = k.key }
        else { key = try await api.createKey(name: "default").key }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let now = f.string(from: Date())
        let via = pushkey.map { "，用 pushkey「\($0.name)」" } ?? ""
        try await api.push(pushkey: key, text: "测试推送 \(now)", desp: "来自「\(settings.deviceName)」的测试\(via)，发送于 **\(now)**。",
                           priority: 4, topic: "test")
    }

    // MARK: Bark

    private func applyBark(_ c: BarkConfig?) {
        let c = (c?.url.isEmpty ?? true) ? nil : c
        bark = c
        settings.barkOn = c != nil
        settings.barkURL = c?.url ?? ""
        settings.barkEncrypted = c?.encrypted ?? false
    }

    /// 重新拉 /v1/me 和功能清单（打开设置页时）
    func refreshAccount() async {
        guard let api = api() else { return }
        await refreshAux(api, session, force: true)
    }

    func saveBark(url raw: String, encrypt: Bool, key: String, iv: String) async throws {
        guard let api = api() else { throw APIError.unauthorized }
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty {
            let l = url.lowercased()
            guard l.hasPrefix("https://") || l.hasPrefix("http://") else {
                throw APIError.invalid("Bark 地址要以 https:// 开头，例如 https://api.day.app/xxxx/")
            }
            if encrypt {
                guard [16, 24, 32].contains(key.count), iv.count == 16 else {
                    throw APIError.invalid("加密需要 32 位（或 16 / 24 位）Key 和 16 位 IV，可以点「生成」")
                }
            }
        }
        let k = url.isEmpty || !encrypt ? "" : key
        let v = url.isEmpty || !encrypt ? "" : iv
        let c = try await api.putBark(url: url, cipherKey: k, cipherIV: v)
        applyBark(c)
        BarkCipherStore.save(key: k, iv: v)
        // 开了 Bark 之后，回笺自己发过的本地通知没必要留着（避免锁屏上两份）
        if c != nil { Notifier.removeAll() }
    }

    func testBark() async throws {
        guard let api = api() else { throw APIError.unauthorized }
        try await api.testBark()
    }

    // MARK: 演示 / 测试

    /// 演示模式：把最新的几条重要消息标回未读（首次同步会把消息全部标为已读）
    func demoMarkUnread(_ n: Int) {
        let ids = Set(inbox.filter { $0.priority >= 3 }.prefix(n).map(\.id)).intersection(read)
        if !ids.isEmpty { read.subtract(ids) }
        updateBadge()
        scheduleSave()
    }
}
