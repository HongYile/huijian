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
