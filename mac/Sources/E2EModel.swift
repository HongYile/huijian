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
        e2eAccountID.map { E2E.KeyRing(secrets: e2eSecrets, scope: E2E.scope(server: e2eServerID, accountID: $0), defaults: defaults) }
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
        if let p = e2ePendingLoginKey {
            do {
                try E2E.acceptKey(p.sk, keys: p.keys, ring: ring)
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
            // 批准请求的序号：只处理最近一次登记之后发出的 GET（§4.3 第 4 步）
            let requestGen = e2eRequest?.generation
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
            defaults.set(st.enabled, forKey: Self.key("e2eEnabled"))
            // 配对码登录的设备：账号已用新方式登录时补记「已升级」标记（§2）
            if st.auth_key, let u = account?.username, !u.isEmpty { e2eMarks.mark(server: e2eServerID, username: u) }
            if let r = e2eRequest, let g = requestGen, r === e2eRequest {
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

    /// 退出登录、设备被移除（§8）：删除本机为这个账号保存的全部私钥和设备钥匙对（只删钥匙串里的）。
    /// 「已升级」标记和钉住的账号公钥在偏好设置里，不删
    func e2eWipe() {
        if let ring = e2eRing {
            do { try ring.removeAll() } catch { NSLog("回笺 删除加密钥匙失败: \(error.localizedDescription)") }
        }
        e2eKeys = []
        e2eState = nil
        e2eLoginNote = nil
        e2ePendingLoginKey = nil
        e2ePendingSetup = nil
        e2eRecoveryCode = nil
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
            await E2E.upgradeAfterInitialPassword(api, server: e2eServerID, username: username, password: password, marks: e2eMarks)
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
        guard token == tok, let client else { throw CancellationError() }
        let a = try await client.account().account
        account = a
        await refreshE2E()
        return a
    }

    // MARK: 开启加密、解锁（§4）

    /// 开启加密。成功后恢复码放在 e2eRecoveryCode（App 状态，用户点「完成」才清除）。
    /// 结果不确定时这次的钥匙和恢复码留在内存里，下次点「开启」先核对（§4.1 第 4 步）
    func e2eSetup(current: String, newPassword: String?) async throws {
        let (api, ring, u) = try e2eContext()
        do {
            let code = try await E2E.setup(api, ring: ring, server: e2eServerID, username: u, currentPassword: current,
                                           newPassword: newPassword, marks: e2eMarks, previous: e2ePendingSetup)
            e2ePendingSetup = nil
            e2eRecoveryCode = code
            e2eRecoveryFromSetup = true
        } catch let p as E2E.SetupPending {
            e2ePendingSetup = p.attempt
            throw p
        } catch {
            e2ePendingSetup = nil
            loadE2EKeys()
            await refreshE2E()
            throw error
        }
        loadE2EKeys()
        await refreshE2E()
    }

    /// 用户在「保存恢复码」页点了「完成」
    func e2eRecoveryDone() {
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
        if let r = e2eRequest, let api = e2eAPI { await r.cancel(api) }
        e2eRequest = nil
        e2eRequestPhase = nil
    }

    /// 关掉「请另一台设备批准」的结果（已解锁 / 被拒绝）
    func e2eDismissRequest() {
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

    func e2eForgetApproval(_ deviceID: String) {
        e2eApprovals[deviceID] = nil
        e2eApprovalPhases[deviceID] = nil
    }

    // MARK: 设置项（§7）

    func e2eSetOnly(_ on: Bool) async throws {
        guard let api = e2eAPI else { return }
        try await E2E.setE2EOnly(api, on)
        await refreshE2E()
    }

    /// 更换恢复码；新的恢复码放在 e2eRecoveryCode，用户点「完成」才清除
    func e2eRotateRecovery(password: String) async throws {
        let (api, _, u) = try e2eContext()
        guard let sk = e2eAccountKey else { throw E2E.Failure(.locked, "本机还没有解锁") }
        let code = try await E2E.rotateRecovery(api, sk: sk, server: e2eServerID, username: u, password: password, marks: e2eMarks)
        e2eRecoveryCode = code
        e2eRecoveryFromSetup = false
        await refreshE2E()
    }

    /// 删除服务器上的明文消息。本机已同步的副本保留：服务端发来 purge 变更时记为「仅本机保留」（见 applyChanges）
    func e2eDeletePlain() async throws -> Int {
        guard let api = e2eAPI else { return 0 }
        return try await E2E.deletePlain(api)
    }

    /// 某把 pushkey 的加密发送密钥：只用本机钉住的账号公钥（§7 第 1 项）
    func e2eSendKey(_ pushkey: String) -> E2E.SendKey { E2E.sendKey(pushkey: pushkey, state: e2eState, pinned: e2eRing?.pinned) }
}
