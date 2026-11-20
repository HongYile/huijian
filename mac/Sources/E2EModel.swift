import AppKit
import Foundation

// 端到端加密在 Mac 上的接线：状态刷新、钥匙读写、消息解密、各个操作。计算和协议细节都在 E2E.swift（和 iPhone 共用）。

extension AppModel {
    // MARK: 上下文

    /// 「已升级」标记、钥匙按规范化后的服务器地址记
    var e2eServerID: String { Self.normalizeServer(server) }

    /// 当前账号 id：已取到账号信息时用它，否则用上次登录记下的（启动时还没请求 /v1/me 也能先读出钥匙）
    var e2eAccountID: Int64? {
        if let a = account { return a.id }
        guard let k = defaults.string(forKey: Self.key("accountKey")), k.hasPrefix(server + "#") else { return nil }
        return Int64(k.dropFirst(server.count + 1))
    }

    var e2eRing: E2E.KeyRing? {
        e2eAccountID.map { E2E.KeyRing(secrets: e2eSecrets, scope: E2E.scope(server: e2eServerID, accountID: $0), defaults: defaults, alive: e2eAlive) }
    }

    var e2eAPI: E2E.API? { client.map { E2E.API($0) } }
    var e2eMarks: E2E.UpgradeMarks { E2E.UpgradeMarks(defaults: defaults) }
    var e2eSupported: Bool { support("e2e") == .yes }

    /// 加密状态（§3）；nil = 还没取到
    var e2eStatus: E2E.Status? { e2eState.map { E2E.status($0, localKeys: e2eKeys) } }
    var e2eLocked: Bool { e2eStatus == .locked }

    /// 账号开启了加密（离线时用上次的结果）：明文消息标「未加密」
    var e2eAccountEnabled: Bool { e2eState?.enabled ?? defaults.bool(forKey: Self.key("e2eEnabled")) }

    /// 本机对应账号有效钥匙的私钥
    var e2eAccountKey: String? { e2eState.flatMap { E2E.usableKey($0, localKeys: e2eKeys) } }

    /// 解锁后要重新设置密码（§4.4.4）
    var e2eNeedsPasswordReset: Bool { e2eStatus == .unlocked && e2eState.map(E2E.needsPasswordReset) == true }

    /// 等待批准、等待核对时加密页每 3 秒刷新一次
    var e2eFastPoll: Bool {
        if let p = e2eRequestPhase {
            switch p {
            case .waiting, .code: return true
            default: break
            }
        }
        return e2eApprovalPhases.values.contains { $0 == .challenged }
    }

    private func e2eUsername() throws -> String {
        guard let u = account?.username, !u.isEmpty else { throw E2E.Failure(.server, "还没有取到账号信息，请稍后再试") }
        return u
    }

    private func e2eContext() throws -> (E2E.API, E2E.KeyRing, String) {
        guard let api = e2eAPI, let ring = e2eRing else { throw E2E.Failure(.server, "尚未登录") }
        return (api, ring, try e2eUsername())
    }

    // MARK: 钥匙与状态

    /// 从钥匙串读出本账号的私钥；失败时当作「未解锁」，在加密页显示原因。
    /// 登录时解开、但当时取不到账号 id 的私钥（只在内存里），这时核对后保存
    func loadE2EKeys() {
        guard let ring = e2eRing else { e2eKeys = []; return }
        // 登录时暂存的私钥：等 /v1/me 确认了这次登录的账号再存（account 还是上次记下的账号时不能存，审查 6）
        if let p = e2ePendingLoginKey, account != nil {
            do {
                try E2E.acceptOwnKey(p.sk, keys: p.keys, ring: ring)      // 来自密码（§11.4）
                e2ePendingLoginKey = nil
            } catch let f as E2E.Failure where f.kind == .keyMismatch {
                e2ePendingLoginKey = nil
                e2eLoginNote = f.message
            } catch {}
        }
        do {
            let ks = try ring.accountKeys()
            if ks != e2eKeys { e2eKeys = ks }
            e2eStorageError = nil
            // 已经确认开启、用户还没点「完成」就退出了（§4.1）：重新打开后回到「保存恢复码」页
            if e2eRecoveryCode == nil {
                if let a = E2E.confirmedSetup(ring: ring) {
                    e2eRecoveryCode = a.code
                    e2eRecoveryFromSetup = true
                } else if let a = E2E.confirmedRecovery(ring: ring) {
                    // 已确认更换的恢复码，用户还没点「完成」（§7 第 3 项）
                    e2eRecoveryCode = a.code
                    e2eRecoveryFromSetup = false
                }
            }
        } catch {
            e2eKeys = []
            e2eStorageError = "读取钥匙串失败，加密消息暂时无法解开：\(error.localizedDescription)"
        }
    }

    /// GET /v1/e2e 并推进批准流程。登录后、回到前台、长轮询收到 e2e 变更、加密页等待批准时调用；同时只跑一个，期间又要刷新就结束后再跑一次
    func refreshE2E() async {
        guard e2eSupported, let api = e2eAPI else { return }
        if e2eRefreshing { e2eRefreshAgain = true; return }
        e2eRefreshing = true
        defer { e2eRefreshing = false }
        repeat {
            e2eRefreshAgain = false
            let tok = token
            // 批准请求的对象和序号：只处理同一个请求对象最近一次登记之后发出的 GET（§4.3 第 4 步）
            let req = e2eRequest
            let requestGen = req?.generation
            let st: E2E.State
            do { st = try await api.state() } catch {
                if let f = error as? E2E.Failure, f.kind == .unsupported { noteUnsupported("e2e") }
                return
            }
            guard token == tok else { return }
            let wasUnlocked = e2eStatus == .unlocked
            if st != e2eState { e2eState = st }
            // 账号开启了加密、本机却没读到私钥（钥匙串偶发读取失败）：重读一次
            if st.enabled, e2eKeys.isEmpty || e2eStorageError != nil { loadE2EKeys() }
            if let ring = e2eRing {
                checkPendingSetup(st, ring: ring)
                // 更换恢复码结果不确定时：服务端的 recovery_wrap 就是这次上传的那份 → 显示恢复码页
                if let a = E2E.checkPendingRecovery(st, ring: ring) {
                    e2eRecoveryNote = nil
                    if e2eRecoveryCode == nil {
                        e2eRecoveryCode = a.code
                        e2eRecoveryFromSetup = false
                    }
                }
                // §4.5 末尾：有私钥却没钉住公钥（重装后偏好设置清空等）：核对通过就补钉
                E2E.repinIfNeeded(st, ring: ring, localKeys: e2eKeys)
                if let w = e2ePendingWeak { e2eWeakPassword = w; e2ePendingWeak = nil }
                if st.enabled, let k = e2ePasswordKeys {
                    // 已经开启：这组钥匙用完即弃（审查 M1）。本机还锁着就用它解锁一次
                    e2ePasswordKeys = nil
                    if e2eStatus != .unlocked {
                        try? await E2E.unlock(api, ring: ring, authKey: k.authKey, unlockKey: k.unlockKey)
                        guard token == tok else { return }
                        loadE2EKeys()
                    }
                } else if !st.enabled, e2ePasswordKeys != nil, !st.server_seal {
                    // 服务端不支持自动开启（0.7 没有 server_seal）：钥匙没用，立即丢掉
                    e2ePasswordKeys = nil
                } else if !st.enabled, let k = e2ePasswordKeys, support("e2e.auto") == .yes, !e2eAutoSetupRunning, !e2eManualSetupRunning,
                          Date() >= e2eAutoSetupNext {
                    // §11.1：账号还没开启、内存里有这次的密码钥匙 → 后台自动开启（失败按退避重试，成功后再刷新一次）
                    if await e2eAutoSetup(k, ring: ring) { e2eRefreshAgain = true }
                    guard token == tok else { return }
                }
            }
            defaults.set(st.enabled, forKey: Self.key("e2eEnabled"))
            // 配对码登录的设备：账号已用新方式登录时补记「已升级」标记（§2）
            if st.auth_key, let u = account?.username, !u.isEmpty { e2eMarks.mark(server: e2eServerID, username: u) }
            if let r = req, let g = requestGen, r === e2eRequest {
                let ph = await r.handle(st, api: api, generation: g)
                if ph != e2eRequestPhase { e2eRequestPhase = ph }
                if ph == .granted {
                    loadE2EKeys()
                    e2eRequest = nil
                    e2eRequestPhase = nil
                }
            }
            for (id, a) in e2eApprovals {
                let ph = await a.handle(st, api: api)
                if e2eApprovalPhases[id] != ph { e2eApprovalPhases[id] = ph }
            }
            notifyE2ERequests(st)
            // §6.1：刚解锁，或已解锁但还有没解开的消息（解锁时正好在同步、上次读钥匙串失败）→ 重新解密一遍
            if e2eStatus == .unlocked, !wasUnlocked || messages.contains(where: \.e2eUnreadable) {
                await decryptPending()
            }
        } while e2eRefreshAgain
    }

    /// 有设备请求批准：通知一次（T50）。只有已解锁的设备能批准，锁定的设备不提醒
    private func notifyE2ERequests(_ st: E2E.State) {
        guard e2eStatus == .unlocked, !st.requests.isEmpty else { return }
        let k = Self.key("e2eNotified")
        var seen = defaults.stringArray(forKey: k) ?? []
        var changed = false
        for r in st.requests where !seen.contains(r.notifyKey) {
            if notificationsEnabled { Notifier.postE2ERequest(r) }
            seen.append(r.notifyKey)
            changed = true
        }
        if changed { defaults.set(Array(seen.suffix(50)), forKey: k) }
    }

    /// 有进行中的开启时（§4.1）每次刷新状态都核对：已用这把钥匙开启 → 保存、钉住、显示恢复码页；
    /// 服务端用的是别的钥匙 → 已删除；还没开启 → 保留，提示重试
    private func checkPendingSetup(_ st: E2E.State, ring: E2E.KeyRing) {
        let r: E2E.SetupCheck
        do {
            r = try E2E.checkPendingSetup(st, ring: ring, server: e2eServerID, username: account?.username ?? "", marks: e2eMarks)
        } catch { return }       // 钥匙串暂时读不了：下次再查
        switch r {
        case .none:
            if e2eSetupNote != nil { e2eSetupNote = nil }
        case .completed(let a):
            loadE2EKeys()
            // 自动开启、重置加密没有恢复码：不显示恢复码页
            if e2eRecoveryCode == nil, !a.code.isEmpty {
                e2eRecoveryCode = a.code
                e2eRecoveryFromSetup = true
            }
            e2eSetupNote = nil
            e2eAutoSetupFailed = false
        case .notEnabled(let a):
            // 自动开启留下的（没有恢复码）：用户没点过「开启」，不提示「请重新点开启」，由自动开启重试
            let note: String? = a.code.isEmpty ? nil : E2E.T.setupNotDone
            if e2eSetupNote != note { e2eSetupNote = note }
        case .resetPending:
            // 重置结果还不确定：保留记录，提示和行为一致（确认成功后自动换上）
            if e2eSetupNote != E2E.T.resetUncertain { e2eSetupNote = E2E.T.resetUncertain }
        case .discarded:
            e2eSetupNote = nil
            loadE2EKeys()
        }
    }

    // MARK: 默认自动加密（§11）

    /// 登录 / 注册 / 设置初始密码后：keep 时留下这次的密码钥匙（只在内存里，自动开启用）；
    /// 密码是否偏弱先记在内存里，拿到账号 id 后按账号保存（T24）
    func e2eNotePasswordKeys(_ k: E2E.PasswordKeys?, keep: Bool = true) {
        guard let k else { return }
        e2ePendingWeak = k.weak
        e2ePasswordKeys = keep ? k : nil
        e2eAutoSetupDelay = 0
        e2eAutoSetupNext = .distantPast
    }

    /// 已解锁、账号还没有恢复码、用户没点过「以后再说」：消息列表顶部显示一条不打断的建议（T23，§11.2）。
    /// 注册即开启加密时不生成恢复码，靠它提醒；「以后再说」按「服务器 + 账号」记在偏好设置里
    var e2eSuggestRecovery: Bool {
        guard e2eStatus == .unlocked, e2eState?.hasRecovery == false, let ring = e2eRing else { return false }
        return !defaults.bool(forKey: Self.key("e2eRecoveryHintDismissed|" + ring.scope))
    }

    func e2eDismissRecoveryHint() {
        guard let ring = e2eRing else { return }
        objectWillChange.send()
        defaults.set(true, forKey: Self.key("e2eRecoveryHintDismissed|" + ring.scope))
    }

    /// 密码偏弱（§11.1 第 5 步）：照样开启加密，加密页显示 T24。按「服务器 + 账号」记在偏好设置里，改密码后清除
    var e2eWeakPassword: Bool {
        get { e2eRing.map { defaults.bool(forKey: Self.key("e2eWeakPassword|" + $0.scope)) } ?? false }
        set {
            guard let ring = e2eRing else { return }
            let k = Self.key("e2eWeakPassword|" + ring.scope)
            if newValue { defaults.set(true, forKey: k) } else { defaults.removeObject(forKey: k) }
        }
    }

    /// 后台自动开启加密（§11.1）。返回是否有变化（开启了 / 解锁了），失败不影响登录：下次刷新或下次用密码登录再试
    private func e2eAutoSetup(_ k: E2E.PasswordKeys, ring: E2E.KeyRing) async -> Bool {
        guard let api = e2eAPI, let u = account?.username, !u.isEmpty else { return false }
        e2eAutoSetupRunning = true
        defer { e2eAutoSetupRunning = false }
        do {
            let r = try await E2E.autoSetup(api, ring: ring, server: e2eServerID, username: u, keys: k, marks: e2eMarks)
            guard ring.alive.isAlive else { return false }      // 期间退出登录 / 换了账号：丢弃
            // 有用户手动开启、还没核对出结果的记录：不自动开启（审查 M2）。服务端还没开启，钥匙也帮不上核对（解锁不了），
            // 不能一直留着：丢掉，交给 checkPendingSetup 和用户（安卓审查）
            if r == .manualPending { e2ePasswordKeys = nil; return false }
            e2ePasswordKeys = nil               // 用完即弃（审查 M1）
            e2eAutoSetupFailed = false
            e2eAutoSetupDelay = 0
            e2eSetupNote = nil
            if k.weak { e2eWeakPassword = true }
            loadE2EKeys()
            return true
        } catch where !ring.alive.isAlive {
            return false
        } catch let f as E2E.Failure where f.kind == .wrongPassword || f.status == 403 || f.status == 429 {
            // 密码已经在别处改过，或者核对次数太多被限速：这组钥匙作废，停止自动重试，等下次输入密码（审查 L6）
            e2ePasswordKeys = nil
            e2eAutoSetupFailed = true
        } catch {
            NSLog("回笺 自动开启加密没有成功: \(error.localizedDescription)")
            e2eAutoSetupFailed = true
            // 退避：30 秒起翻倍，最多 30 分钟（审查 L4）
            e2eAutoSetupDelay = min(max(30, e2eAutoSetupDelay * 2), 1800)
            e2eAutoSetupNext = Date().addingTimeInterval(e2eAutoSetupDelay)
        }
        return false
    }

    /// 重置加密 / 更换加密钥匙（§11.3）：确认 T45 之后调用。成功后新公钥替换钉住的，本机旧私钥保留
    func e2eReset(password: String) async throws {
        let (api, ring, u) = try e2eContext()
        do {
            try await E2E.resetE2E(api, ring: ring, server: e2eServerID, username: u, password: password, marks: e2eMarks)
        } catch let p as E2E.SetupPending {
            if ring.alive.isAlive { e2eSetupNote = p.localizedDescription }
            throw p
        }
        guard ring.alive.isAlive else { throw CancellationError() }     // 期间退出登录 / 换了账号：丢弃
        e2eSetupNote = nil
        e2eResetDone = true
        e2eWeakPassword = Core.passwordProblem(password, username: u) != nil
        if e2eRequest != nil { await e2eCancelRequest() }
        loadE2EKeys()
        await refreshE2E()
        await decryptPending()
    }

    /// T67 提示条（§11.1 末尾）：账号还没开启加密、服务端支持自动开启（server_seal 为 true）时，主窗口顶部一直显示
    var e2eNeedsEnable: Bool {
        guard let st = e2eState, !st.enabled, st.server_seal else { return false }
        return support("e2e.auto") == .yes
    }

    /// T67 小窗：输入一次当前密码，按 §2.4 核对后自动开启。算出的钥匙只在这个函数里用一次，不留在内存里
    func e2eEnableWithPassword(_ password: String) async throws {
        let (api, ring, u) = try e2eContext()
        if e2eAutoSetupRunning || e2eManualSetupRunning { throw E2E.Failure(.conflict, E2E.T.autoSetupRunning) }
        // 先占住再算钥匙（算 Argon2id 要几秒，期间刷新状态不能再发起自动开启，审查 N6）
        e2eAutoSetupRunning = true
        defer { e2eAutoSetupRunning = false }
        let k = try await E2E.keysForPassword(api, server: e2eServerID, username: u, password: password, marks: e2eMarks)
        let r = try await E2E.autoSetup(api, ring: ring, server: e2eServerID, username: u, keys: k, marks: e2eMarks)
        guard ring.alive.isAlive else { throw CancellationError() }     // 期间退出登录 / 换了账号：丢弃
        if r == .manualPending { throw E2E.Failure(.conflict, E2E.T.setupUncertain) }
        e2eAutoSetupFailed = false
        e2eAutoSetupDelay = 0
        e2eSetupNote = nil
        e2eWeakPassword = k.weak
        loadE2EKeys()
        await refreshE2E()
    }

    /// 重置加密的结果还不确定（加密页显示 T.resetUncertain 和「放弃这次重置」）
    var e2eResetPending: Bool { e2eSetupNote == E2E.T.resetUncertain }

    /// 用户确认「放弃这次重置」：删除记录，新私钥留在本机（万一其实成功了还能解开那段时间的消息），之后可以重新重置
    func e2eAbandonReset() async {
        guard let ring = e2eRing else { return }
        E2E.abandonReset(ring: ring)
        e2eSetupNote = nil
        loadE2EKeys()
        await refreshE2E()
    }

    /// 钉住的公钥和服务器有效钥匙不同（别的设备重置过加密）：加密页显示 T46
    var e2eKeyChanged: Bool { e2eState.map { E2E.keyChanged($0, pinned: e2eRing?.pinned) } ?? false }

    /// 退出登录、设备被移除（§8）：删除本机为这个账号保存的全部私钥、设备钥匙对和进行中的开启（只删钥匙串里的）。
    /// 「已升级」标记和钉住的账号公钥在偏好设置里，不删
    func e2eWipe() {
        e2eDiscard(ring: e2eRing)
        e2eLoginNote = nil
        e2ePendingLoginKey = nil
        e2ePasswordKeys = nil       // 换账号时不清：那时的钥匙属于新登录的账号
        e2ePendingWeak = nil
    }

    /// 换账号、换服务器（§8）：accountKey 是上一个账号的「服务器#账号 id」，删掉它在本机的钥匙。
    /// 不动登录时留下的提示和待保存的私钥（它们属于新账号）
    func e2eDiscardAccount(accountKey prev: String) {
        guard let i = prev.lastIndex(of: "#"), let id = Int64(prev[prev.index(after: i)...]) else {
            e2eDiscard(ring: nil)
            return
        }
        let old = E2E.scope(server: String(prev[..<i]), accountID: id)
        // 只是同一个服务器地址换了写法（规范化后相同）：是同一个账号，不删
        if let cur = account?.id, old == E2E.scope(server: e2eServerID, accountID: cur) { return }
        e2eDiscard(ring: E2E.KeyRing(secrets: e2eSecrets, scope: old, defaults: defaults))
    }

    /// 先停下正在进行的批准流程（请求、批准），再删钥匙串里的东西，最后清掉内存状态
    private func e2eDiscard(ring: E2E.KeyRing?) {
        // 进行中的自动开启、重置、T67 开启拿着的是旧标记：完成时不再写这个账号的钥匙
        e2eAlive.kill()
        e2eAlive = E2E.AliveFlag()
        e2eRequest?.stop()
        for a in e2eApprovals.values { a.stop() }
        if let ring {
            do { try ring.removeAll() } catch { NSLog("回笺 删除加密钥匙失败: \(error.localizedDescription)") }
        }
        e2eKeys = []
        e2eState = nil
        e2eSetupNote = nil
        e2eRecoveryNote = nil
        e2eRecoveryCode = nil
        if let ring { defaults.removeObject(forKey: Self.key("e2eWeakPassword|" + ring.scope)) }   // 按账号记的：只清这个账号的
        e2eAutoSetupDelay = 0
        e2eAutoSetupNext = .distantPast
        e2eAutoSetupFailed = false
        e2eResetDone = false
        e2eRequest = nil
        e2eRequestPhase = nil
        e2eApprovals = [:]
        e2eApprovalPhases = [:]
        defaults.removeObject(forKey: Self.key("e2eEnabled"))
    }

    // MARK: 收消息（§6）

    /// 新到的消息：在后台线程解密加密消息（还没处理过的）
    func prepareE2E(_ msgs: [Message]) async -> [Message] {
        let todo = msgs.filter { $0.isE2E && $0.e2eStatus == nil }
        guard !todo.isEmpty else { return msgs }
        let results = await Self.openAll(todo, keys: e2eKeys)
        return msgs.map { m in
            guard let r = results[m.id] else { return m }
            var x = m
            x.applyE2E(r)
            return x
        }
    }

    nonisolated static func openAll(_ msgs: [Message], keys: [String]) async -> [Int64: E2E.OpenResult] {
        let items = msgs.map { ($0.id, $0.e2e ?? "", $0.attachments.map(\.id)) }
        return (try? await E2E.background {
            var out: [Int64: E2E.OpenResult] = [:]
            for (id, env, atts) in items { out[id] = E2E.open(envelope: env, keys: keys, serverAttachments: atts) }
            return out
        }) ?? [:]
    }

    /// 把还没解开的消息重新解密一遍（§6.1）：解锁后、钥匙变了、App 启动时、刷新状态后发现已解锁但还有没解开的消息时调用。
    /// 正在解密时又被调用（例如解锁和后台同步同时进行），记下来，这一轮结束后用最新的钥匙和消息再跑一轮，不会漏
    func decryptPending() async {
        if e2eDecrypting { e2eDecryptAgain = true; return }
        e2eDecrypting = true
        defer { e2eDecrypting = false }
        repeat {
            e2eDecryptAgain = false
            await decryptPendingOnce()
        } while e2eDecryptAgain
    }

    private func decryptPendingOnce() async {
        let keys = e2eKeys
        guard !keys.isEmpty else { return }
        let pending = messages.filter(\.e2eUnreadable)
        guard !pending.isEmpty else { return }
        let results = await Self.openAll(pending, keys: keys)
        var list = messages
        var opened: [Message] = []
        for i in list.indices where list[i].e2eUnreadable {
            guard let r = results[list[i].id], r.code != list[i].e2eStatus else { continue }
            list[i].applyE2E(r)
            if case .ok = r { opened.append(list[i]) }
        }
        guard list != messages else { return }
        replaceMessages(list)
        refreshLocalFiles()
        autoDownload(opened)
    }

    // MARK: 登录后的辅助

    /// 设置初始密码（账号还没有密码）：只能以原文设置（服务端没有别的接口），设置前先查「已升级」标记，设置后马上升级到新登录协议
    func setInitialCredentials(username: String, password: String) async throws -> APIClient.AccountInfo {
        try E2E.checkInitialPassword(server: e2eServerID, username: username, marks: e2eMarks)
        let a = try await setCredentials(username: username, password: password, current: "")
        if let api = e2eAPI {
            // 升级成功后拿这组钥匙在后台自动开启加密（§11.1）
            e2eNotePasswordKeys(await E2E.upgradeAfterInitialPassword(api, server: e2eServerID, username: username, password: password, marks: e2eMarks))
            Task { await refreshE2E() }
        }
        return a
    }

    /// 改用户名 / 密码：服务端支持新登录协议时按 §7.5（不发密码原文、重新锁住私钥），否则用原来的接口
    /// 账号有密码时一律走 E2E.changeCredentials：由 prelogin 和「已升级」标记决定，只有 prelogin 纯文本 404 且从未升级时才发原文（§2.4）
    func changeCredentials(username: String, password: String, current: String) async throws -> APIClient.AccountInfo {
        guard account?.has_password == true else { return try await setInitialCredentials(username: username, password: password) }
        guard let api = e2eAPI else { throw E2E.Failure(.server, "尚未登录") }
        let tok = token
        let old = try e2eUsername()
        let st = try? await api.state()
        _ = try await E2E.changeCredentials(api, state: st ?? e2eState, sk: st.flatMap { E2E.usableKey($0, localKeys: e2eKeys) },
                                            server: e2eServerID, username: old, newUsername: username,
                                            currentPassword: current, newPassword: password, marks: e2eMarks)
        if !password.isEmpty {
            // 密码换了：内存里那组钥匙作废；新密码已经通过强度检查，不再提示 T24
            e2ePasswordKeys = nil
            e2eWeakPassword = false
        }
        guard token == tok, let client else { throw CancellationError() }
        let a = try await client.account().account
        account = a
        await refreshE2E()
        return a
    }

    // MARK: 开启加密、解锁（§4）

    /// 开启加密。成功后恢复码放在 e2eRecoveryCode（App 状态，用户点「完成」才清除）。
    /// 新钥匙对和恢复码在钥匙串里（KeyRing.pendingSetup），结果不确定时之后每次刷新状态都会自动核对（§4.1）
    func e2eSetup(current: String, newPassword: String?) async throws {
        let (api, ring, u) = try e2eContext()
        // 自动开启进行中不能手动开启（两者用同一个进行中记录，抢起来会丢私钥）；手动开启期间也不自动开启
        if e2eAutoSetupRunning { throw E2E.Failure(.conflict, E2E.T.autoSetupRunning) }
        e2eManualSetupRunning = true
        defer { e2eManualSetupRunning = false }
        do {
            let code = try await E2E.setup(api, ring: ring, server: e2eServerID, username: u, currentPassword: current,
                                           newPassword: newPassword, marks: e2eMarks)
            e2eSetupNote = nil
            e2eRecoveryCode = code
            e2eRecoveryFromSetup = true
        } catch let p as E2E.SetupPending {
            e2eSetupNote = p.localizedDescription
            throw p
        } catch {
            loadE2EKeys()
            await refreshE2E()
            throw error
        }
        loadE2EKeys()
        await refreshE2E()
    }

    /// 用户在「保存恢复码」页点了「完成」：开启加密时的新钥匙对和恢复码从钥匙串删除（私钥已另存）
    func e2eRecoveryDone() {
        // 这一页只在服务端确认开启之后才显示：私钥万一当时没存进钥匙串，这里补存，存好了才删进行中的开启
        if let ring = e2eRing {
            if e2eRecoveryFromSetup {
                E2E.finishRecovery(ring: ring)
                loadE2EKeys()
            } else {
                E2E.finishRotation(ring: ring)
            }
        }
        e2eRecoveryCode = nil
    }

    func e2eUnlock(password: String) async throws {
        let (api, ring, u) = try e2eContext()
        try await E2E.unlockWithPassword(api, ring: ring, server: e2eServerID, username: u, password: password, marks: e2eMarks)
        await e2eAfterUnlock()
    }

    func e2eUnlock(recovery: String) async throws {
        let (api, ring, _) = try e2eContext()
        try await E2E.unlockWithRecovery(api, ring: ring, code: recovery)
        await e2eAfterUnlock()
    }

    private func e2eAfterUnlock() async {
        // 用别的方式解锁了：撤回还在等待的批准请求，免得其他设备继续提示
        if e2eRequest != nil { await e2eCancelRequest() }
        loadE2EKeys()
        await refreshE2E()
        await decryptPending()
    }

    /// 请另一台设备批准
    func e2eStartRequest() async throws {
        let (api, ring, _) = try e2eContext()
        let r = e2eRequest ?? E2E.ApprovalRequest(ring: ring)
        try await r.start(api)
        e2eRequest = r
        e2eRequestPhase = r.phase
    }

    func e2eCancelRequest() async {
        let r = e2eRequest
        r?.stop()                       // 先停下：等撤回请求的这段时间里，刷新状态不再推进它
        e2eRequest = nil
        e2eRequestPhase = nil
        if let r, let api = e2eAPI { await r.cancel(api) }
    }

    /// 关掉「请另一台设备批准」的结果（已解锁 / 被拒绝）
    func e2eDismissRequest() {
        e2eRequest?.stop()
        e2eRequest = nil
        e2eRequestPhase = nil
    }

    /// 重新设置密码（§4.4.4）
    func e2eResetPassword(current: String, newPassword: String) async throws {
        let (api, _, u) = try e2eContext()
        guard let sk = e2eAccountKey else { throw E2E.Failure(.locked, E2E.T.lockedCannotChange) }
        try await E2E.resetPassword(api, sk: sk, server: e2eServerID, username: u, currentPassword: current, newPassword: newPassword, marks: e2eMarks)
        await refreshE2E()
    }

    // MARK: 批准其他设备（§5）

    func e2eBeginApproval(_ r: E2E.Request) async throws {
        guard let api = e2eAPI else { return }
        guard let sk = e2eAccountKey else { throw E2E.Failure(.locked, "本机还没有解锁，不能批准其他设备") }
        let a = try await E2E.Approval.begin(api, request: r, sk: sk)
        e2eApprovals[r.device_id] = a
        e2eApprovalPhases[r.device_id] = a.phase
        await refreshE2E()
    }

    func e2eApprove(_ deviceID: String) async throws {
        guard let api = e2eAPI, let a = e2eApprovals[deviceID] else { return }
        guard let sk = e2eAccountKey else { throw E2E.Failure(.locked, "本机还没有解锁，不能批准其他设备") }
        defer { e2eApprovalPhases[deviceID] = a.phase }
        try await a.approve(api, sk: sk)
        await refreshE2E()
    }

    /// 「不一致，拒绝」（已接手的请求）或直接拒绝
    func e2eDeny(_ deviceID: String) async throws {
        guard let api = e2eAPI else { return }
        if let a = e2eApprovals[deviceID] {
            try await a.reject(api)
            e2eApprovalPhases[deviceID] = a.phase
        } else {
            try await E2E.deny(api, deviceID: deviceID)
        }
        await refreshE2E()
    }

    /// 等待对方揭晓时点「取消」：只停止本机的等待，不发拒绝（§5 第 2 步）
    func e2eCancelApproval(_ deviceID: String) {
        e2eApprovals[deviceID]?.stop()
        e2eForgetApproval(deviceID)
    }

    func e2eForgetApproval(_ deviceID: String) {
        e2eApprovals[deviceID] = nil
        e2eApprovalPhases[deviceID] = nil
    }

    // MARK: 设置项（§7）

    /// 更换恢复码；新的恢复码放在 e2eRecoveryCode，用户点「完成」才清除
    func e2eRotateRecovery(password: String) async throws {
        let (api, ring, u) = try e2eContext()
        guard let sk = e2eAccountKey else { throw E2E.Failure(.locked, "本机还没有解锁") }
        let code: String
        do {
            code = try await E2E.rotateRecovery(api, ring: ring, sk: sk, server: e2eServerID, username: u, password: password, marks: e2eMarks)
        } catch let p as E2E.RecoveryPending {
            e2eRecoveryNote = p.localizedDescription
            throw p
        }
        e2eRecoveryNote = nil
        e2eRecoveryCode = code
        e2eRecoveryFromSetup = false
        await refreshE2E()
    }

    /// 某把 pushkey 的加密发送密钥：只用本机钉住的账号公钥（§7 第 1 项）
    func e2eSendKey(_ pushkey: String) -> E2E.SendKey { E2E.sendKey(pushkey: pushkey, state: e2eState, pinned: e2eRing?.pinned) }
}
