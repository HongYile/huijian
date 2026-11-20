import Foundation

/// agent 双向（docs/agent-mcp.md §8）：会话列表、批准 agent 登录、回复 agent 消息。逻辑在共用的 Agent.swift
extension AppModel {
    var agentSupported: Bool { supports("agent") == true }

    /// 重新拉会话列表、核实会话证明、推进正在进行的批准；新的登录请求通知一次；核实结果变了就重新解密 agent 消息
    func refreshAgent() async {
        guard agentSupported, let api = e2eAPI else { return }
        if agentRefreshing { agentRefreshAgain = true; return }
        agentRefreshing = true
        defer { agentRefreshing = false }
        repeat {
            agentRefreshAgain = false
            let gen = session
            guard let list = try? await Agent.sessions(api), session == gen else {
                if agentRefreshAgain, session == gen { continue }   // 这次失败了，但期间又有人要求刷新：再试一次
                return
            }
            if list != agentSessions { agentSessions = list }
            let keys = e2eKeys
            let current = e2eAccountKey
            let v = (try? await E2E.background { Agent.verify(list, keys: keys, current: current) }) ?? [:]
            guard session == gen else { return }
            let changed = v != agentVerified
            if changed { agentVerified = v }
            for (id, a) in agentApprovals {
                let ph = await a.handle(list, api: api)
                if agentPhases[id] != ph { agentPhases[id] = ph }
            }
            notifyAgentRequests(list)
            if changed { await decryptPending() }
            agentRevision &+= 1
        } while agentRefreshAgain
    }

    /// 有 agent 请求登录：通知一次。只有已解锁的设备能批准（要用账号私钥写证明），锁定的设备不提醒
    private func notifyAgentRequests(_ list: [Agent.Session]) {
        guard e2eStatus == .unlocked else { return }
        let k = "agentNotified"
        var seen = UserDefaults.standard.stringArray(forKey: k) ?? []
        var changed = false
        for s in list where s.pending && !seen.contains(s.id) {
            Notifier.postAgentRequest(s)
            seen.append(s.id)
            changed = true
        }
        if changed { UserDefaults.standard.set(Array(seen.suffix(50)), forKey: k) }
    }

    func resetAgent() {
        for a in agentApprovals.values { a.stop() }
        agentSessions = []
        agentVerified = [:]
        agentKeys = []
        agentApprovals = [:]
        agentPhases = [:]
    }

    // MARK: Agent key

    func refreshAgentKeys() async throws {
        guard let api = e2eAPI else { return }
        agentKeys = try await Agent.keys(api)
    }

    func createAgentKey() async throws -> Agent.NewKey {
        guard let api = e2eAPI else { throw E2E.Failure(.server, "未登录") }
        let k = try await Agent.createKey(api)
        try? await refreshAgentKeys()
        return k
    }

    func revokeAgentKey(_ id: Int64) async throws {
        guard let api = e2eAPI else { return }
        try await Agent.revokeKey(api, id: id)
        try? await refreshAgentKeys()
        await refreshAgent()
    }

    // MARK: 会话与批准

    func endAgentSession(_ id: String) async throws {
        guard let api = e2eAPI else { return }
        try await Agent.end(api, sessionID: id)
        await refreshAgent()
    }

    func agentBeginApproval(_ s: Agent.Session) async throws {
        guard let api = e2eAPI else { return }
        guard let sk = e2eAccountKey else { throw E2E.Failure(.locked, "本机还没有解锁加密，不能批准") }
        let gen = session
        let a = try await Agent.Approval.begin(api, session: s, sk: sk)
        guard session == gen else { a.stop(); return }   // 等待期间换了账号：结果不写进新账号的状态
        agentApprovals[s.id] = a
        agentPhases[s.id] = a.phase
        await refreshAgent()
    }

    func agentApprove(_ id: String) async throws {
        guard let api = e2eAPI, let a = agentApprovals[id] else { return }
        guard let sk = e2eAccountKey else { throw E2E.Failure(.locked, "本机还没有解锁加密，不能批准") }
        defer { agentPhases[id] = a.phase }
        try await a.approve(api, sk: sk)
        await refreshAgent()
    }

    func agentDeny(_ id: String) async throws {
        guard let api = e2eAPI else { return }
        if let a = agentApprovals[id] {
            a.stop()
            try await a.reject(api)
            agentPhases[id] = a.phase
        } else {
            try await Agent.deny(api, sessionID: id)
        }
        await refreshAgent()
    }

    func agentForgetApproval(_ id: String) {
        agentApprovals[id]?.stop()
        agentApprovals[id] = nil
        agentPhases[id] = nil
    }

    // MARK: 回复

    /// 能不能回复这条消息：agent 发来、来源核实过、会话还在
    func agentCanReply(_ m: Message) -> Bool {
        guard let sid = m.agentSession, m.e2eStatus == "ok", m.agentSeq > 0, agentVerified[sid]?.current == true else { return false }
        return agentSessions.first { $0.id == sid }?.active ?? false
    }

    func agentReply(_ m: Message, text: String) async throws {
        guard let api = e2eAPI, let sid = m.agentSession, let v = agentVerified[sid] else { throw E2E.Failure(.server, Agent.T.unverified) }
        guard let sk = e2eAccountKey else { throw E2E.Failure(.locked, "本机还没有解锁加密，不能回复") }
        try await Agent.reply(api, msgID: m.id, seq: m.agentSeq, sessionID: sid, verified: v, sk: sk, text: text, device: settings.deviceName)
    }

    func agentReplies(_ m: Message) async throws -> [Agent.ReplyView] {
        guard let api = e2eAPI, let sid = m.agentSession else { return [] }
        return try await Agent.replies(api, msgID: m.id, sessionID: sid, keys: e2eKeys, verified: agentVerified[sid])
    }
}
