import Foundation

// 端到端加密在 iPhone 上的接线：状态刷新、钥匙读写、消息解密、各个操作。计算和协议细节都在 E2E.swift（和 Mac 共用）。
// 和 Mac 的 E2EModel.swift 一一对应；差别只在 iPhone 的 AppModel（API、Settings、session）。

extension AppModel {
    // MARK: 上下文

    /// 「已升级」标记、钥匙、钉住的公钥按规范化后的服务器地址记（scheme / host 小写、去掉默认端口和末尾的 /，§1）
    var e2eServerID: String { E2E.normalizeServer(settings.server) }

    var e2eRing: E2E.KeyRing? {
        guard !settings.server.isEmpty, let id = settings.accountID else { return nil }
        return E2E.KeyRing(secrets: e2eSecrets, scope: E2E.scope(server: e2eServerID, accountID: id), defaults: .standard)
    }

    var e2eAPI: E2E.API? { api().map { E2E.API($0) } }
    var e2eMarks: E2E.UpgradeMarks { E2E.UpgradeMarks(defaults: .standard) }
    var e2eSupported: Bool { supports("e2e") == true }

    /// 加密状态（§3）；nil = 还没取到
    var e2eStatus: E2E.Status? { e2eState.map { E2E.status($0, localKeys: e2eKeys) } }
    var e2eLocked: Bool { e2eStatus == .locked }

    /// 账号开启了加密（离线时用上次的结果）：明文消息标「未加密」
    var e2eAccountEnabled: Bool { e2eState?.enabled ?? settings.e2eEnabled }

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

    /// 当前账号的用户名（「当前密码」凭证要用它请求 prelogin）
    private func e2eUsername() throws -> String {
        let u = accountDetail?.account.username ?? settings.username
        guard !u.isEmpty else { throw E2E.Failure(.server, "还没有取到账号信息，请稍后再试") }
        return u
    }

    /// 操作期间 session 变了：返回 true。换成了别的账号 / 服务器（§8）时，这次操作可能已经往旧账号存了私钥、设备钥匙对，一并删掉；
    /// 同一账号重新登录（钥匙范围没变）时不删
    func e2eStale(_ gen: Int, _ ring: E2E.KeyRing) -> Bool {
        guard gen != session else { return false }
        if ring.scope != e2eRing?.scope {
            do { try ring.removeAll() } catch { NSLog("回笺 删除旧账号的加密钥匙失败: \(error.localizedDescription)") }
        }
        return true
    }

    private func e2eContext() throws -> (E2E.API, E2E.KeyRing, String) {
        guard let api = e2eAPI, let ring = e2eRing else { throw E2E.Failure(.server, "尚未登录，或者还没有取到账号信息，请稍后再试") }
        return (api, ring, try e2eUsername())
    }

    // MARK: 钥匙与状态

    /// 从钥匙串读出本账号的私钥；失败时当作「未解锁」，在加密页显示原因。
    /// 登录时解开、但当时取不到账号 id 的私钥（只在内存里），这时核对后保存（§2.1）
    func loadE2EKeys() {
        guard let ring = e2eRing else { e2eKeys = []; return }
        if let p = e2ePendingLoginKey {
            do {
                try E2E.acceptKey(p.sk, keys: p.keys, ring: ring)
                e2ePendingLoginKey = nil
            } catch let f as E2E.Failure where f.kind == .keyMismatch {
                e2ePendingLoginKey = nil
                e2eLoginNote = f.message
            } catch {}      // 钥匙串写失败：留在内存里，下次再试
        }
        do {
            let ks = try ring.accountKeys()
            if ks != e2eKeys { e2eKeys = ks }
            e2eStorageError = nil
            // 已确认开启、用户还没在「保存恢复码」页点「完成」（例如切去密码管理器时 App 被系统终止）：不用联网，直接回到这一页（§4.1）
            if let a = E2E.confirmedSetup(ring: ring) { showSetupRecovery(a) }
            // 更换恢复码同理（§7 第 3 项）
            if let a = E2E.confirmedRecovery(ring: ring) { showRecovery(E2ERecoveryShow(code: a.code, fromSetup: false)) }
            // 读到了私钥：还有没解开的消息就在后台解（启动时、换账号、钥匙串恢复可读后，§6.1）
            if !ks.isEmpty, messages.contains(where: \.e2eUnreadable) { Task { await decryptPending() } }
        } catch {
            e2eKeys = []
            e2eStorageError = "读取钥匙串失败，加密消息暂时无法解开：\(error.localizedDescription)"
        }
    }

    /// GET /v1/e2e 并推进批准流程。登录后、回到前台、长轮询收到 e2e 变更、加密页等待批准时调用；同时只跑一个，期间又要刷新就结束后再跑一次
    func refreshE2E() async {
        guard loggedIn, e2eSupported, let api = e2eAPI else { return }
        if e2eRefreshing { e2eRefreshAgain = true; return }
        e2eRefreshing = true
        defer { e2eRefreshing = false }
        repeat {
            e2eRefreshAgain = false
            let gen = session
            // 批准请求和它的序号：只处理这个请求最近一次登记之后发出的 GET（§4.3 第 4 步）。
            // 期间请求被取消、换成新的请求对象时，这次的结果不交给新请求
            let req = e2eRequest
            let requestGen = req?.generation
            let st: E2E.State
            do { st = try await api.state() } catch { return }
            guard gen == session else { return }
            let wasUnlocked = e2eStatus == .unlocked
            if st != e2eState { e2eState = st }
            // 账号开启了加密、本机却没读到私钥（钥匙串偶发读取失败）：重读一次
            if st.enabled, e2eKeys.isEmpty || e2eStorageError != nil { loadE2EKeys() }
            settings.e2eEnabled = st.enabled
            // 配对码登录的设备没输过密码：账号已用新方式登录时，按 /v1/me 的用户名补记「已升级」（§2.1）
            if st.auth_key, let u = accountDetail?.account.username ?? (settings.username.isEmpty ? nil : settings.username) {
                e2eMarks.mark(server: e2eServerID, username: u)
            }
            if let ring = e2eRing {
                checkE2ESetup(st, ring: ring)
                // 更换恢复码结果不确定时：服务端的 recovery_wrap 就是这次上传的那份 → 显示恢复码页（§7 第 3 项）
                if let a = E2E.checkPendingRecovery(st, ring: ring) {
                    e2eRecoveryNote = nil
                    showRecovery(E2ERecoveryShow(code: a.code, fromSetup: false))
                }
                E2E.repinIfNeeded(st, ring: ring, localKeys: e2eKeys)     // §4.5 末尾：有私钥没钉住时补钉
            }
            if let r = req, let g = requestGen, r === e2eRequest {
                let ph = await r.handle(st, api: api, generation: g)
                guard !e2eStale(gen, r.ring) else { return }
                if ph != e2eRequestPhase { e2eRequestPhase = ph }
                if ph == .granted {
                    loadE2EKeys()
                    e2eRequest = nil
                    e2eRequestPhase = nil
                }
            }
            for (id, a) in e2eApprovals {
                let ph = await a.handle(st, api: api)
                guard gen == session else { return }
                if e2eApprovalPhases[id] != ph { e2eApprovalPhases[id] = ph }
            }
            notifyE2ERequests(st)
            // §6.1：刚解锁，或已解锁但还有没解开的消息（解锁时正好在同步、上次读钥匙串失败）→ 重新解密一遍
            if e2eStatus == .unlocked, !wasUnlocked || messages.contains(where: \.e2eUnreadable) {
                await decryptPending()
            }
        } while e2eRefreshAgain
    }

    /// 进行中的开启（§4.1）：每次拿到状态都核对钥匙串里存着的新钥匙对。服务端已经用它开启 → 保存私钥、显示「保存恢复码」页
    /// （App 被系统终止、结果当时没确认，重新打开后也能回到这一页）；还没开启 → 保留，开启页提示重试；用的是别的钥匙 → 已删除
    func checkE2ESetup(_ st: E2E.State, ring: E2E.KeyRing) {
        let u = accountDetail?.account.username ?? settings.username
        let r: E2E.SetupCheck
        do { r = try E2E.checkPendingSetup(st, ring: ring, server: e2eServerID, username: u, marks: e2eMarks) } catch { return }
        switch r {
        case .none, .discarded:
            e2ePendingSetup = nil
        case .notEnabled(let a):
            e2ePendingSetup = a
        case .completed(let a):
            e2ePendingSetup = nil
            loadE2EKeys()
            showSetupRecovery(a)
        }
    }

    /// 显示开启加密的「保存恢复码」页；不在加密页（重启后、结果后来才确认）时带用户过去
    private func showSetupRecovery(_ a: E2E.SetupAttempt) { showRecovery(E2ERecoveryShow(code: a.code, fromSetup: true)) }

    /// 显示「保存恢复码」页（已经在显示的不换）；不在加密页时带用户过去
    private func showRecovery(_ r: E2ERecoveryShow) {
        guard e2eRecovery == nil else { return }
        e2eRecovery = r
        if loggedIn, path.last != .e2e { openE2E() }
    }

    /// 「保存恢复码」页点「完成」：清掉 App 状态里的恢复码，并从钥匙串删除对应的那份（开启加密 §4.1 / 更换恢复码 §7 第 3 项）
    func e2eFinishRecovery() {
        if let r = e2eRecovery, let ring = e2eRing {
            // 开启加密：私钥万一当时没存进钥匙串就补存、补钉，存好了才删除进行中的开启
            if r.fromSetup { E2E.finishRecovery(ring: ring) } else { E2E.finishRotation(ring: ring) }
        }
        e2eRecovery = nil
    }

    /// 有设备请求批准：通知一次（T50，App 在前台或下次打开时）。只有已解锁的设备能批准，锁定的设备不提醒
    private func notifyE2ERequests(_ st: E2E.State) {
        guard e2eStatus == .unlocked, !st.requests.isEmpty else { return }
        var seen = settings.e2eNotified
        var changed = false
        for r in st.requests where !seen.contains(r.notifyKey) {
            Notifier.postE2ERequest(r)
            seen.append(r.notifyKey)
            changed = true
        }
        if changed { settings.e2eNotified = seen }
    }

    /// 退出登录、设备被移除（§8）：删除本机为这个账号保存的全部私钥、设备钥匙对和进行中的开启。「已升级」标记、钉住的公钥不删
    func e2eWipe() {
        // 先停下正在进行的批准流程（请求、批准），它们 await 回来后不会再写钥匙串；再删
        e2eRequest?.stop()
        for a in e2eApprovals.values { a.stop() }
        if let ring = e2eRing {
            do { try ring.removeAll() } catch { NSLog("回笺 删除加密钥匙失败: \(error.localizedDescription)") }
        }
        e2eKeys = []
        e2eState = nil
        e2eStorageError = nil
        e2eLoginNote = nil
        e2eRequest = nil
        e2eRequestPhase = nil
        e2eApprovals = [:]
        e2eApprovalPhases = [:]
        e2eRecovery = nil
        e2eRecoveryNote = nil
        e2ePendingLoginKey = nil
        e2ePendingSetup = nil
        settings.e2eEnabled = false
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
        let gen = session
        let results = await Self.openAll(pending, keys: keys)
        guard gen == session else { return }
        var list = messages
        for i in list.indices where list[i].e2eUnreadable {
            guard let r = results[list[i].id], r.code != list[i].e2eStatus else { continue }
            list[i].applyE2E(r)
        }
        guard list != messages else { return }
        replaceMessages(list)
    }

    // MARK: 账户（§7.5）

    /// 设置初始密码（账号还没有密码）：服务端只有原文接口（§2.1 第 4 条的例外）。本机标记过这个账号「已升级」时拒绝（T1），
    /// 否则发原文，成功后马上升级到新协议
    func setInitialCredentials(username: String, password: String) async throws -> AccountInfo {
        // 先向服务器确认账号确实还没有密码（审查 M1）：已经有密码时这个表单不该出现（没有「当前密码」），让用户重新进入
        let gen = session
        let now = try await requireAPI().account().account
        guard gen == session else { throw CancellationError() }
        if now.has_password {
            noteAccount(now)
            throw APIError.invalid("这个账号已经有密码了。请返回后重新进入「修改用户名和密码」，输入当前密码再修改。")
        }
        if !password.isEmpty {
            for u in [username, accountDetail?.account.username ?? "", settings.username] where !u.isEmpty {
                try E2E.checkInitialPassword(server: e2eServerID, username: u, marks: e2eMarks)
            }
        }
        let a = try await setCredentials(username: username, password: password, current: "")
        if !password.isEmpty { await upgradeAfterInitialPassword(username: username, password: password) }
        return a
    }

    /// 刚用原文设置了初始密码（服务端没有别的接口）：服务端支持新登录协议时马上升级
    func upgradeAfterInitialPassword(username: String, password: String) async {
        // 不看功能清单（还没取到不算没有 e2e）：由 prelogin 决定，旧服务端返回纯文本 404 时什么也不做
        guard let api = e2eAPI else { return }
        await E2E.upgradeAfterInitialPassword(api, server: e2eServerID, username: ManageRules.normalizeUsername(username),
                                              password: password, marks: e2eMarks)
    }

    /// 改用户名 / 密码（账号已有密码时）：一律按 §2.4 / §7.5 用当前密码派生的凭证（不发密码原文、已开启加密时重新锁住私钥），
    /// 不看功能清单、也不管本机是不是管理员设备；只有 prelogin 返回纯文本 404 且没有「已升级」标记时，E2E 才按旧接口发原文。
    /// 还没有密码时设置初始密码用 setCredentials（服务端只有这个接口），之后调 upgradeAfterInitialPassword
    func changeCredentials(username: String, password: String, current: String) async throws -> AccountInfo {
        guard let api = e2eAPI else { throw APIError.unauthorized }
        let gen = session
        let old = try e2eUsername()
        let st = try? await api.state()
        _ = try await E2E.changeCredentials(api, state: st ?? e2eState, sk: st.flatMap { E2E.usableKey($0, localKeys: e2eKeys) },
                                            server: e2eServerID, username: old, newUsername: ManageRules.normalizeUsername(username),
                                            currentPassword: current, newPassword: password, marks: e2eMarks)
        guard gen == session else { throw CancellationError() }
        let a = try await requireAPI().account().account
        guard gen == session else { throw CancellationError() }
        noteAccount(a)
        await refreshE2E()
        return a
    }

    // MARK: 开启加密、解锁（§4）

    /// 开启加密。新钥匙对和恢复码从生成起存在钥匙串（ring.pendingSetup），成功后恢复码放在 e2eRecovery（App 状态），
    /// 用户点「完成」（e2eFinishRecovery）才都删掉。结果不确定时之后每次刷新状态都会核对（§4.1）
    func e2eSetup(current: String, newPassword: String?) async throws {
        let (api, ring, u) = try e2eContext()
        let gen = session
        do {
            let code = try await E2E.setup(api, ring: ring, server: e2eServerID, username: u, currentPassword: current,
                                           newPassword: newPassword, marks: e2eMarks)
            if e2eStale(gen, ring) { throw CancellationError() }
            e2ePendingSetup = nil
            e2eRecovery = E2ERecoveryShow(code: code, fromSetup: true)
        } catch let p as E2E.SetupPending {
            if e2eStale(gen, ring) { throw CancellationError() }
            e2ePendingSetup = p.attempt
            throw p
        } catch {
            if e2eStale(gen, ring) { throw error }
            loadE2EKeys()
            await refreshE2E()
            throw error
        }
        loadE2EKeys()
        await refreshE2E()
    }

    func e2eUnlock(password: String) async throws {
        let (api, ring, u) = try e2eContext()
        let gen = session
        try await E2E.unlockWithPassword(api, ring: ring, server: e2eServerID, username: u, password: password, marks: e2eMarks)
        if e2eStale(gen, ring) { throw CancellationError() }
        await e2eAfterUnlock()
    }

    func e2eUnlock(recovery: String) async throws {
        let (api, ring, _) = try e2eContext()
        let gen = session
        try await E2E.unlockWithRecovery(api, ring: ring, code: recovery)
        if e2eStale(gen, ring) { throw CancellationError() }
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
        let gen = session
        try await r.start(api)
        if e2eStale(gen, ring) { throw CancellationError() }
        e2eRequest = r
        e2eRequestPhase = r.phase
    }

    func e2eCancelRequest() async {
        if let r = e2eRequest, let api = e2eAPI { await r.cancel(api) }
        e2eRequest = nil
        e2eRequestPhase = nil
    }

    /// 关掉「请另一台设备批准」的结果（被拒绝 / 失败）
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
        let gen = session
        let a = try await E2E.Approval.begin(api, request: r, sk: sk)
        guard gen == session else { return }        // 期间换了账号：这个批准属于旧账号，丢弃（§8）
        e2eApprovals[r.device_id] = a
        e2eApprovalPhases[r.device_id] = a.phase
        await refreshE2E()
    }

    func e2eApprove(_ deviceID: String) async throws {
        guard let api = e2eAPI, let a = e2eApprovals[deviceID] else { return }
        guard let sk = e2eAccountKey else { throw E2E.Failure(.locked, "本机还没有解锁，不能批准其他设备") }
        let gen = session
        defer { if gen == session, e2eApprovals[deviceID] === a { e2eApprovalPhases[deviceID] = a.phase } }
        try await a.approve(api, sk: sk)
        await refreshE2E()
    }

    /// 「不一致，拒绝」（已接手的请求）或直接拒绝
    func e2eDeny(_ deviceID: String) async throws {
        guard let api = e2eAPI else { return }
        if let a = e2eApprovals[deviceID] {
            let gen = session
            try await a.reject(api)
            guard gen == session else { return }
            if e2eApprovals[deviceID] === a { e2eApprovalPhases[deviceID] = a.phase }
        } else {
            try await E2E.deny(api, deviceID: deviceID)
        }
        await refreshE2E()
    }

    /// 「取消」（§5 第 2 步）、关掉结果：只停止本机的等待，不通知服务器
    func e2eForgetApproval(_ deviceID: String) {
        e2eApprovals[deviceID]?.stop()
        e2eApprovals[deviceID] = nil
        e2eApprovalPhases[deviceID] = nil
    }

    // MARK: 设置项（§7）

    func e2eSetOnly(_ on: Bool) async throws {
        guard let api = e2eAPI else { return }
        try await E2E.setE2EOnly(api, on)
        await refreshE2E()
    }

    /// 更换恢复码（§7 第 3 项）。新恢复码发请求前先存进钥匙串，成功后放在 e2eRecovery，点「完成」才都删掉；
    /// 结果不确定时提示 T.recoveryUncertain，之后刷新状态确认成功会自动显示
    func e2eRotateRecovery(password: String) async throws {
        let (api, ring, u) = try e2eContext()
        guard let sk = e2eAccountKey else { throw E2E.Failure(.locked, "本机还没有解锁") }
        let gen = session
        let code: String
        do {
            code = try await E2E.rotateRecovery(api, ring: ring, sk: sk, server: e2eServerID, username: u, password: password, marks: e2eMarks)
        } catch let p as E2E.RecoveryPending {
            if e2eStale(gen, ring) { throw CancellationError() }
            e2eRecoveryNote = p.localizedDescription
            throw p
        }
        if e2eStale(gen, ring) { throw CancellationError() }
        e2eRecoveryNote = nil
        e2eRecovery = E2ERecoveryShow(code: code, fromSetup: false)
        await refreshE2E()
    }

    /// 删除服务器上的明文消息。本机已同步的副本保留：服务端发来 purge 变更时记为「仅本机保留」（见 AppModel.applyChanges）
    func e2eDeletePlain() async throws -> Int {
        guard let api = e2eAPI else { return 0 }
        return try await E2E.deletePlain(api)
    }

    /// 某把 pushkey 的加密发送密钥：只用本机钉住的账号公钥（§7 第 1 项）
    func e2eSendKey(_ pushkey: String) -> E2E.SendKey { E2E.sendKey(pushkey: pushkey, state: e2eState, pinned: e2eRing?.pinned) }
}
