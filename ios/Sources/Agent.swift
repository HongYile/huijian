import Foundation

/// agent 双向（docs/agent-mcp.md §8、§11）：设备一侧的共用逻辑。Mac 与 iPhone 各放一份同样的文件。
/// 只用 E2E.API 和共用核心；不碰钥匙串（账号私钥由调用方传进来）。服务器给的内容一律不信：
/// 会话公钥要有本账号私钥写的会话证明，agent 消息、回执都用核实过的会话公钥解开（auth 模式核对发送方）。
enum Agent {
    // MARK: - 文字

    enum T {
        static let unverified = "🔒 来源无法核实的 agent 消息"
        static let taken = "这个请求已被另一台设备接手"
        static let restarted = "对方重新发起了请求，请重新批准"
        static let gone = "请求已结束（超时、被拒绝或已在别的设备上处理）"
        static let commitMismatch = "核对失败：agent 看到的不是你账号的公钥，可能有人冒充，已拒绝"
        static let ended = "这个 agent 会话已结束，不能再回复"
        static let tooLong = "回复太长（最多 16 KB）"
        static let waitingReply = "等你回复"
        static let choiceHint = "选好选项、写好补充（都可选），再点发送。"
        static let tookReply = "agent 已拿到你的回复，现在没在等你；再发的回复要等它下次查看才会收到。"
        static func codeHint(_ name: String) -> String { "确认「\(name)」那边显示的也是这 6 位数字，再批准。" }
    }

    /// 回复正文：快捷选项和补充文字一起发。都有时第一行是选项、后面是补充（docs/agent-mcp.md §5.1）
    static func composeReply(choice: String?, text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = choice, !c.isEmpty else { return t }
        return t.isEmpty ? c : c + "\n" + t
    }

    // MARK: - 服务端结构

    struct KeyInfo: Decodable, Equatable, Identifiable {
        let id: Int64
        let prefix: String
        var created_at: String?
        var last_used: String?
    }

    struct NewKey: Decodable, Equatable {
        let id: Int64
        let key: String
        let prefix: String
    }

    struct Session: Decodable, Equatable, Identifiable {
        var id = ""
        var name = ""
        var pub = ""
        /// pending / approved / denied / expired / ended
        var state = ""
        var commit = ""
        var challenge = ""
        var reveal = ""
        var attest = ""
        var created_at: String?
        var approved_at: String?
        var ended_at: String?
        var last_seen: String?
        var online = false

        init(id: String, name: String = "", pub: String = "", state: String = "pending", commit: String = "", challenge: String = "",
             reveal: String = "", attest: String = "") {
            self.id = id; self.name = name; self.pub = pub; self.state = state
            self.commit = commit; self.challenge = challenge; self.reveal = reveal; self.attest = attest
        }

        enum CodingKeys: String, CodingKey { case id, name, pub, state, commit, challenge, reveal, attest, created_at, approved_at, ended_at, last_seen, online }

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
            id = s(.id); name = s(.name); pub = s(.pub); state = s(.state); commit = s(.commit)
            challenge = s(.challenge); reveal = s(.reveal); attest = s(.attest)
            created_at = try? c.decodeIfPresent(String.self, forKey: .created_at)
            approved_at = try? c.decodeIfPresent(String.self, forKey: .approved_at)
            ended_at = try? c.decodeIfPresent(String.self, forKey: .ended_at)
            last_seen = try? c.decodeIfPresent(String.self, forKey: .last_seen)
            online = (try? c.decodeIfPresent(Bool.self, forKey: .online)) ?? false
        }

        var pending: Bool { state == "pending" }
        var active: Bool { state == "approved" }
    }

    struct ReplyStatus: Decodable, Equatable {
        let reply_id: Int64
        var session_id = ""
        var state = ""
        var created_at: String?
        var received_at: String?
        var copy = ""
        var receipt = ""
        var device = ""

        enum CodingKeys: String, CodingKey { case reply_id, session_id, state, created_at, received_at, copy, receipt, device }

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            reply_id = try c.decode(Int64.self, forKey: .reply_id)
            func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
            session_id = s(.session_id); state = s(.state); copy = s(.copy); receipt = s(.receipt); device = s(.device)
            created_at = try? c.decodeIfPresent(String.self, forKey: .created_at)
            received_at = try? c.decodeIfPresent(String.self, forKey: .received_at)
        }
    }

    // MARK: - 接口

    static func keys(_ api: E2E.API) async throws -> [KeyInfo] {
        struct R: Decodable { let keys: [KeyInfo] }
        return try await api.get(R.self, "/v1/agent/keys").keys
    }

    /// 新建 Agent key：明文只返回这一次；已有时 409
    static func createKey(_ api: E2E.API) async throws -> NewKey {
        try JSONDecoder().decode(NewKey.self, from: try await api.call("POST", "/v1/agent/keys"))
    }

    static func revokeKey(_ api: E2E.API, id: Int64) async throws {
        try await api.call("DELETE", "/v1/agent/keys/\(id)")
    }

    static func sessions(_ api: E2E.API) async throws -> [Session] {
        struct R: Decodable { let sessions: [Session] }
        return try await api.get(R.self, "/v1/agent/sessions").sessions
    }

    static func end(_ api: E2E.API, sessionID: String) async throws {
        try await api.call("DELETE", "/v1/agent/sessions/\(sessionID)")
    }

    static func deny(_ api: E2E.API, sessionID: String) async throws {
        try await api.call("POST", "/v1/agent/sessions/\(sessionID)/deny")
    }

    // MARK: - 核实会话

    /// 核实过的会话：名称取自会话证明（服务器给的 name 不用），公钥用来解开它的消息、加密给它的回复
    struct Verified: Equatable, Codable {
        let name: String
        let pub: String
        /// 证明是账号**当前**钥匙写的：只有这样的会话能回复。重置加密前的旧钥匙写的只用来显示历史消息
        /// （旧私钥可能已经泄露：拿着旧私钥又控制服务器的人能给自己的公钥伪造证明）
        var current = true
    }

    /// 用账号私钥（可以多把：重置加密前批准的会话用旧钥匙写的证明）核对每个会话的证明；核对不过的不在结果里。
    /// current：账号当前的私钥（nil = 不知道，全部按旧钥匙处理）
    static func verify(_ sessions: [Session], keys: [String], current: String?) -> [String: Verified] {
        var out: [String: Verified] = [:]
        for s in sessions where !s.attest.isEmpty && !s.pub.isEmpty {
            for k in keys {
                if let name = try? Core.agentAttestOpen(sk: k, attest: s.attest, sessionID: s.id, pub: s.pub) {
                    out[s.id] = Verified(name: name, pub: s.pub, current: k == current)
                    break
                }
            }
        }
        return out
    }

    // MARK: - 批准登录（§11.2：同设备批准，只换前缀）

    enum Phase: Equatable {
        case challenged       // 已出 na，等 agent 揭晓
        case code(String)     // 核对码
        case approved
        case rejected
        case failed(String)
    }

    final class Approval {
        let session: Session
        private let na: String
        private let account: String
        private(set) var phase: Phase = .challenged
        private(set) var stopped = false

        func stop() { stopped = true }

        private init(session: Session, na: String, account: String) {
            self.session = session
            self.na = na
            self.account = account
        }

        /// 第 1 步：生成自己的 na 并接手请求；sk：本机的账号私钥
        static func begin(_ api: E2E.API, session: Session, sk: String) async throws -> Approval {
            let account = try E2E.coreCall { try Core.publicKey(sk).pub }
            let na = try E2E.coreCall { try Core.random32() }
            do {
                try await api.call("POST", "/v1/agent/sessions/\(session.id)/challenge", body: ["nonce": na])
            } catch let f as E2E.Failure where f.kind == .conflict {
                throw E2E.Failure(.conflict, T.taken, status: 409)
            }
            return Approval(session: session, na: na, account: account)
        }

        /// 每次拿到新的会话列表时调用
        @discardableResult
        func handle(_ sessions: [Session], api: E2E.API) async -> Phase {
            guard !stopped, phase == .challenged else { return phase }
            guard let s = sessions.first(where: { $0.id == session.id }), s.pending else {
                phase = .failed(T.gone)
                return phase
            }
            guard s.pub == session.pub, s.commit == session.commit, s.name == session.name, s.challenge == na else {
                phase = .failed(T.restarted)
                return phase
            }
            guard !s.reveal.isEmpty else { return phase }
            // 用本机私钥算出的账号公钥核对承诺：agent 看到的是假的账号公钥时对不上
            // 名称也在承诺里：服务器改不了设备上显示、写进证明的名称
            let commit = try? Core.agentCommit(pub: s.pub, account: account, nonce: s.reveal, name: session.name)
            guard commit == s.commit, let code = try? Core.agentSAS(pub: s.pub, account: account, na: na, nb: s.reveal) else {
                _ = try? await Agent.deny(api, sessionID: s.id)
                phase = .failed(T.commitMismatch)
                return phase
            }
            phase = .code(code)
            return phase
        }

        /// 「一致，批准」：写会话证明
        func approve(_ api: E2E.API, sk: String, now: Date = Date()) async throws {
            guard !stopped, case .code = phase else { return }
            let attest = try E2E.coreCall {
                try Core.agentAttestSeal(sk: sk, sessionID: session.id, pub: session.pub, name: session.name, approvedAt: Int64(now.timeIntervalSince1970))
            }
            do {
                try await api.call("POST", "/v1/agent/sessions/\(session.id)/approve", body: ["attest": attest])
                phase = .approved
            } catch let f as E2E.Failure where f.kind == .conflict {
                phase = .failed(f.message)
                throw f
            }
        }

        func reject(_ api: E2E.API) async throws {
            try await Agent.deny(api, sessionID: session.id)
            phase = .rejected
        }
    }

    // MARK: - 收消息

    /// 解开一条 agent 消息（hje2）。会话没核实（证明缺失、对不上）→ unverified；kind 不是 message → broken
    static func open(envelope: String, sessionID: String, keys: [String], verified: [String: Verified]) -> E2E.OpenResult {
        guard !keys.isEmpty else { return .locked }
        guard let v = verified[sessionID] else { return .unverified }
        let p: [String: Any]
        do {
            p = try Core.agentOpen(keys: keys, sessionPub: v.pub, sessionID: sessionID, envelope: envelope)
        } catch let e as Core.Failure {
            return e.code == "wrong_key" ? .wrongKey : .broken
        } catch {
            return .broken
        }
        guard p["kind"] as? String == "message" else { return .broken }
        var text = ((p["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 2000 { text = String(text.prefix(2000)) }
        let desp = (p["desp"] as? String) ?? ""
        // 快捷回复：最多 4 个、每个 1–20 字，不合格的丢掉
        let choices = ((p["choices"] as? [Any]) ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { (1...20).contains($0.count) }
        var doc: Data?
        var preview = ""
        if !desp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let r = try? Core.mdBuild(text: text, desp: desp, atts: []) {
            doc = r.doc
            preview = r.preview
        }
        var o = E2E.Opened(text: text, desp: desp, type: "markdown", atts: [], doc: doc, preview: preview)
        o.agentName = v.name
        o.ask = p["ask"] as? Bool ?? false
        o.choices = Array(choices.prefix(4))
        o.agentSeq = (p["seq"] as? NSNumber)?.int64Value ?? 0
        return .ok(o)
    }

    // MARK: - 回复

    static let maxReplyBytes = 16 << 10

    /// 回复一条 agent 消息 → reply_id。seq：被回复消息载荷里的 seq（写进 re_seq）；sk：本机账号私钥；device：本机名称（写进载荷，agent 看得到）
    @discardableResult
    static func reply(_ api: E2E.API, msgID: Int64, seq: Int64, sessionID: String, verified: Verified, sk: String, text: String, device: String,
                      now: Date = Date()) async throws -> Int64 {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw E2E.Failure(.server, "回复不能为空") }
        guard t.utf8.count <= maxReplyBytes else { throw E2E.Failure(.server, T.tooLong) }
        guard verified.current, seq > 0 else { throw E2E.Failure(.server, T.unverified) }
        var n = [UInt8](repeating: 0, count: 16)
        var g = SystemRandomNumberGenerator()
        for i in n.indices { n[i] = g.next() }
        let payload: [String: Any] = ["v": 1, "re_seq": seq, "text": t, "n": b64url(Data(n)), "sent_at": Int64(now.timeIntervalSince1970), "device": device]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
        // 转义后可能变长（引号、控制字符）：信封上限 32 KB，载荷超过 20 KB 就不发
        guard json.utf8.count <= 20 << 10 else { throw E2E.Failure(.server, T.tooLong) }
        let sealed = try E2E.coreCall { try Core.agentReplySeal(sk: sk, sessionPub: verified.pub, sessionID: sessionID, msgID: msgID, payload: json) }
        do {
            let d = try await api.call("POST", "/v1/agent/replies", body: ["msg_id": msgID, "e2e": sealed.envelope, "copy": sealed.copy])
            return ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["reply_id"].flatMap { ($0 as? NSNumber)?.int64Value } ?? 0
        } catch let f as E2E.Failure where f.kind == .conflict {
            throw E2E.Failure(.conflict, T.ended, status: 409)
        }
    }

    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// 一条回复在本机显示的样子
    struct ReplyView: Equatable, Identifiable {
        enum State: Equatable { case sent, received, expired }
        let id: Int64
        let text: String
        let device: String
        let sentAt: Date?
        /// received 只在回执核对通过（agent 的会话私钥写的、对得上这条回复）时才算
        let state: State
        let receivedAt: Date?

        var label: String {
            switch state {
            case .sent: return "已发出"
            case .received: return "✓✓ agent 已收到"
            case .expired: return "已过期（agent 没有取走）"
            }
        }
    }

    /// 某条消息的回复：副本用账号私钥解开（解不开的不显示），回执用会话公钥核对
    static func replies(_ api: E2E.API, msgID: Int64, sessionID: String, keys: [String], verified: Verified?) async throws -> [ReplyView] {
        struct R: Decodable { let replies: [ReplyStatus] }
        let list = try await api.get(R.self, "/v1/agent/replies/status", query: [URLQueryItem(name: "msg_id", value: String(msgID))]).replies
        return try await E2E.background { replyViews(list, sessionID: sessionID, keys: keys, verified: verified) }
    }

    static func replyViews(_ list: [ReplyStatus], sessionID: String, keys: [String], verified: Verified?) -> [ReplyView] {
        list.compactMap { r in
            guard r.session_id.isEmpty || r.session_id == sessionID,
                  let p = try? Core.openMessage(keys: keys, envelope: r.copy),
                  let text = p["text"] as? String, let n = p["n"] as? String, !n.isEmpty else { return nil }
            let sentAt = (p["sent_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            var state: ReplyView.State = r.state == "expired" ? .expired : .sent
            var receivedAt: Date?
            if r.state == "received", let v = verified, !r.receipt.isEmpty,
               let rc = try? Core.agentOpen(keys: keys, sessionPub: v.pub, sessionID: sessionID, envelope: r.receipt),
               rc["kind"] as? String == "receipt", (rc["reply_id"] as? NSNumber)?.int64Value == r.reply_id, rc["n"] as? String == n {
                state = .received
                receivedAt = (rc["received_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            }
            return ReplyView(id: r.reply_id, text: text, device: (p["device"] as? String) ?? r.device, sentAt: sentAt, state: state, receivedAt: receivedAt)
        }
    }
}
