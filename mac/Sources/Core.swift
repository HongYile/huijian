import Foundation
import HuijianCore

/// 回笺共用核心（Rust，见 core/src/api.rs）：端到端加密、Markdown 解析、密码强度检查。
/// 只有一个入口 hj_call：JSON 进、JSON 出。钥匙、随机数、凭证都是 base64url 字符串，盐是十六进制。
/// Mac 与 iPhone 各放一份同样的文件。
enum Core {
    struct Failure: LocalizedError {
        /// bad_request / format / wrong_key / io / weak_params / panic
        let code: String
        let message: String
        var errorDescription: String? { message }
    }

    /// 调用核心库；失败抛 Failure
    @discardableResult
    static func call(_ op: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
        var req = args
        req["op"] = op
        let data = try JSONSerialization.data(withJSONObject: req)
        var out: UnsafeMutablePointer<UInt8>?
        var n = 0
        let rc = data.withUnsafeBytes { hj_call($0.bindMemory(to: UInt8.self).baseAddress, data.count, &out, &n) }
        guard rc == 0, let out else { throw Failure(code: "panic", message: "核心库调用失败") }
        defer { hj_free(out, n) }
        let obj = (try? JSONSerialization.jsonObject(with: Data(bytes: out, count: n))) as? [String: Any] ?? [:]
        if obj["ok"] as? Bool == true { return obj }
        throw Failure(code: obj["error"] as? String ?? "unknown", message: obj["message"] as? String ?? "核心库返回了无法识别的结果")
    }

    private static func str(_ r: [String: Any], _ k: String) throws -> String {
        guard let v = r[k] as? String else { throw Failure(code: "format", message: "核心库结果缺少 \(k)") }
        return v
    }

    // MARK: 登录凭证

    /// Argon2id（参数写死在核心库里）→ (登录凭证, 解锁钥匙)。约 0.1–0.3 秒，不要在主线程调用
    static func passwordKeys(_ password: String, saltHex: String) throws -> (authKey: String, unlockKey: String) {
        let r = try call("password_keys", ["password": password, "salt": saltHex])
        return (try str(r, "auth_key"), try str(r, "unlock_key"))
    }

    /// 旧账号登录用的 PBKDF2-HMAC-SHA256；轮数少于 600000 时抛 weak_params
    static func pbkdf2(_ password: String, saltHex: String, iterations: Int) throws -> String {
        try str(try call("pbkdf2", ["password": password, "salt": saltHex, "iterations": iterations]), "password_key")
    }

    static func newSalt() throws -> String { try str(try call("new_salt"), "salt") }

    /// 密码强度：合格返回 nil，否则返回原因（直接显示给用户）
    static func passwordProblem(_ password: String, username: String = "") -> String? {
        guard let r = try? call("check_password", ["password": password, "username": username]) else { return "无法检查密码强度" }
        return r["strong"] as? Bool == true ? nil : (r["reason"] as? String ?? "密码太弱")
    }

    // MARK: 钥匙

    static func keypair() throws -> (sk: String, pub: String, kid: String) {
        let r = try call("keypair")
        return (try str(r, "sk"), try str(r, "pub"), try str(r, "kid"))
    }

    static func publicKey(_ sk: String) throws -> (pub: String, kid: String) {
        let r = try call("public_key", ["sk": sk])
        return (try str(r, "pub"), try str(r, "kid"))
    }

    static func random32() throws -> String { try str(try call("random32"), "value") }

    /// prefix：hjp1（密码解锁钥匙）/ hjr1（恢复码钥匙）
    static func wrap(_ prefix: String, key: String, data: String) throws -> String {
        try str(try call("wrap", ["prefix": prefix, "key": key, "data": data]), "wrap")
    }

    static func unwrap(_ prefix: String, key: String, wrap: String) throws -> String {
        try str(try call("unwrap", ["prefix": prefix, "key": key, "wrap": wrap]), "data")
    }

    // MARK: 恢复码

    /// 新恢复码：code 显示给用户（XXXXX-XXXXX-XXXXX-XXXXX-XXXXXX），key 用来锁住私钥
    static func recoveryNew() throws -> (code: String, key: String) {
        let r = try call("recovery_new")
        return (try str(r, "code"), try str(r, "key"))
    }

    /// 用户输入的恢复码（大小写、空格、横线、O/0、I/L/1 都容错）→ 钥匙；格式不对抛 format
    static func recoveryKey(_ code: String) throws -> String { try str(try call("recovery_key", ["code": code]), "key") }

    // MARK: 设备批准

    /// 把账号私钥 sk 转交给公钥为 pub 的设备
    static func grantSeal(sk: String, to pub: String) throws -> String {
        try str(try call("grant_seal", ["sk": sk, "pub": pub]), "grant")
    }

    /// 本机（设备私钥 deviceSK）解开转交来的账号私钥
    static func grantOpen(deviceSK: String, grant: String) throws -> String {
        try str(try call("grant_open", ["sk": deviceSK, "grant": grant]), "data")
    }

    /// 核对码的承诺。pub 是新设备公钥；account 是新设备看到的账号公钥（批准设备用自己私钥算出的公钥）
    static func sasCommit(pub: String, account: String, nonce: String) throws -> String {
        try str(try call("sas_commit", ["pub": pub, "account": account, "nonce": nonce]), "commit")
    }

    /// 6 位核对码（字符串，保留前导 0）
    static func sasCode(pub: String, account: String, na: String, nb: String) throws -> String {
        try str(try call("sas_code", ["pub": pub, "account": account, "na": na, "nb": nb]), "code")
    }

    // MARK: 配对码带钥匙（e2ee-client.md §12）

    /// 生成一次性钥匙 S 并用它锁住账号私钥：secret 只放进二维码 / 长配对码，wrap 交给服务器暂存
    static func pairKeyNew(sk: String) throws -> (secret: String, wrap: String) {
        let r = try call("pair_key_new", ["sk": sk])
        return (try str(r, "secret"), try str(r, "wrap"))
    }

    /// 新设备用配对码里的 S 解开服务器交来的 key_wrap → 账号私钥；钥匙不对抛 format
    static func pairKeyOpen(secret: String, wrap: String) throws -> String {
        try str(try call("pair_key_open", ["secret": secret, "wrap": wrap]), "data")
    }

    /// 长配对码（123456-XXXXX-…）和配对链接（huijian://pair?server=…&code=…，二维码内容）
    static func pairFormat(server: String, code: String, secret: String) throws -> (text: String, link: String) {
        let r = try call("pair_format", ["server": server, "code": code, "secret": secret])
        return (try str(r, "text"), try str(r, "link"))
    }

    /// 用户输入的配对码：6 位、长配对码或配对链接 → 6 位配对码、一次性钥匙（可能没有）、服务器地址（只有链接里有）
    static func pairParse(_ input: String) throws -> (code: String, secret: String?, server: String?) {
        let r = try call("pair_parse", ["input": input])
        return (try str(r, "code"), r["secret"] as? String, r["server"] as? String)
    }

    /// 二维码矩阵：size × size，modules[y * size + x] 为 true 表示黑色（不含四周留白）
    static func qr(_ text: String) throws -> (size: Int, modules: [Bool]) {
        let r = try call("qr", ["text": text])
        guard let n = r["size"] as? Int, let m = r["modules"] as? String, m.utf8.count == n * n else {
            throw Failure(code: "format", message: "核心库结果缺少二维码")
        }
        return (n, m.utf8.map { $0 == UInt8(ascii: "1") })
    }

    // MARK: agent 双向（docs/agent-mcp.md §11）

    static func agentCommit(pub: String, account: String, nonce: String) throws -> String {
        try str(try call("agent_commit", ["pub": pub, "account": account, "nonce": nonce]), "commit")
    }

    static func agentSAS(pub: String, account: String, na: String, nb: String) throws -> String {
        try str(try call("agent_sas", ["pub": pub, "account": account, "na": na, "nb": nb]), "code")
    }

    static func agentAttestSeal(sk: String, sessionID: String, pub: String, name: String, approvedAt: Int64) throws -> String {
        try str(try call("agent_attest_seal", ["sk": sk, "session_id": sessionID, "pub": pub, "name": name, "approved_at": approvedAt]), "attest")
    }

    /// 核对会话证明 → 证明里写的名称（会话 id、公钥对不上时抛 format）
    static func agentAttestOpen(sk: String, attest: String, sessionID: String, pub: String) throws -> String {
        try str(try call("agent_attest_open", ["sk": sk, "attest": attest, "session_id": sessionID, "pub": pub]), "name")
    }

    /// 解开 agent 消息或回执（hje2）→ 载荷
    static func agentOpen(keys: [String], sessionPub: String, sessionID: String, envelope: String) throws -> [String: Any] {
        guard let p = try call("agent_open", ["keys": keys, "session_pub": sessionPub, "session_id": sessionID, "envelope": envelope])["payload"] as? [String: Any] else {
            throw Failure(code: "format", message: "解开的内容格式不对")
        }
        return p
    }

    /// agent 一侧（自检用）：会话私钥把载荷加密给账号公钥 → hje2
    static func agentSeal(account: String, sk: String, sessionID: String, payload: String) throws -> String {
        try str(try call("agent_seal", ["account": account, "sk": sk, "session_id": sessionID, "payload": payload]), "envelope")
    }

    /// agent 一侧（自检用）：会话私钥解开回复
    static func agentReplyOpen(sk: String, account: String, envelope: String, msgID: Int64) throws -> [String: Any] {
        guard let p = try call("agent_reply_open", ["sk": sk, "account": account, "envelope": envelope, "msg_id": msgID])["payload"] as? [String: Any] else {
            throw Failure(code: "format", message: "解开的内容格式不对")
        }
        return p
    }

    /// 回复 agent → (给会话的 hjq1, 给账号自己的 hje1 副本)
    static func agentReplySeal(sk: String, sessionPub: String, sessionID: String, msgID: Int64, payload: String) throws -> (envelope: String, copy: String) {
        let r = try call("agent_reply_seal", ["sk": sk, "session_pub": sessionPub, "session_id": sessionID, "msg_id": msgID, "payload": payload])
        return (try str(r, "envelope"), try str(r, "copy"))
    }

    // MARK: 消息与附件

    /// 用账号的私钥（可以多把）解开信封 → 载荷 {v, text, desp, type, atts:[{name, mime, size, key}]}
    static func openMessage(keys: [String], envelope: String) throws -> [String: Any] {
        guard let p = try call("open_message", ["keys": keys, "envelope": envelope])["payload"] as? [String: Any] else {
            throw Failure(code: "format", message: "解开的内容格式不对")
        }
        return p
    }

    /// 解密附件到 dst（先写临时文件，成功后改名；失败不留半成品）
    static func decryptFile(key: String, src: URL, dst: URL) throws {
        try call("decrypt_file", ["key": key, "src": src.path, "dst": dst.path])
    }

    /// 本地解析 Markdown（与服务端完全一致）：atts 为 [{id, name, mime, size}] → (doc 的 JSON, 预览文字)
    static func mdBuild(text: String, desp: String, atts: [[String: Any]]) throws -> (doc: Data, preview: String) {
        let r = try call("md_build", ["text": text, "desp": desp, "atts": atts])
        guard let doc = r["doc"] else { throw Failure(code: "format", message: "核心库结果缺少 doc") }
        return (try JSONSerialization.data(withJSONObject: doc), r["preview"] as? String ?? "")
    }
}
