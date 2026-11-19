package io.github.hongyile.huijian

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 回笺共用核心（Rust，见 core/src/api.rs）：端到端加密、Markdown 解析、密码强度检查。
 * 只有一个入口 [call]：JSON 进、JSON 出。钥匙、随机数、凭证都是 base64url 字符串，盐是十六进制。
 * 和 Mac / iPhone 的 Core.swift 一一对应。
 */
object Core {
    init {
        System.loadLibrary("huijian_core")
    }

    /** 核心库报错：code = bad_request / format / wrong_key / io / weak_params / panic */
    class Failure(val code: String, message: String) : Exception(message)

    @JvmStatic
    private external fun call(req: ByteArray): ByteArray

    /** 调用核心库；失败抛 [Failure] */
    fun call(op: String, args: Map<String, Any?> = emptyMap()): JSONObject {
        val req = JSONObject()
        for ((k, v) in args) req.put(k, if (v is List<*>) JSONArray(v) else v)
        req.put("op", op)
        val res = runCatching { JSONObject(String(call(req.toString().toByteArray()), Charsets.UTF_8)) }
            .getOrElse { throw Failure("panic", "核心库调用失败") }
        if (res.optBoolean("ok")) return res
        throw Failure(res.optString("error", "unknown"), res.optString("message", "核心库返回了无法识别的结果"))
    }

    private fun JSONObject.str(k: String): String =
        optString(k).takeIf { has(k) } ?: throw Failure("format", "核心库结果缺少 $k")

    // ---------- 登录凭证 ----------

    /** Argon2id（参数写死在核心库里）→ (登录凭证, 解锁钥匙)。约 0.2–0.4 秒，不要在主线程调用 */
    fun passwordKeys(password: String, saltHex: String): Pair<String, String> =
        call("password_keys", mapOf("password" to password, "salt" to saltHex)).let { it.str("auth_key") to it.str("unlock_key") }

    /** 旧账号登录用的 PBKDF2-HMAC-SHA256；轮数少于 600000 时抛 weak_params */
    fun pbkdf2(password: String, saltHex: String, iterations: Int): String =
        call("pbkdf2", mapOf("password" to password, "salt" to saltHex, "iterations" to iterations)).str("password_key")

    fun newSalt(): String = call("new_salt").str("salt")

    /** 密码强度：合格返回 null，否则返回原因（直接显示给用户） */
    fun passwordProblem(password: String, username: String = ""): String? = runCatching {
        val r = call("check_password", mapOf("password" to password, "username" to username))
        if (r.optBoolean("strong")) null else r.optString("reason", "密码太弱")
    }.getOrElse { "无法检查密码强度" }

    // ---------- 钥匙 ----------

    data class KeyPair(val sk: String, val pub: String, val kid: String)

    fun keypair(): KeyPair = call("keypair").let { KeyPair(it.str("sk"), it.str("pub"), it.str("kid")) }

    /** → (公钥, kid) */
    fun publicKey(sk: String): Pair<String, String> = call("public_key", mapOf("sk" to sk)).let { it.str("pub") to it.str("kid") }

    fun random32(): String = call("random32").str("value")

    /** prefix：hjp1（密码解锁钥匙）/ hjr1（恢复码钥匙） */
    fun wrap(prefix: String, key: String, data: String): String =
        call("wrap", mapOf("prefix" to prefix, "key" to key, "data" to data)).str("wrap")

    fun unwrap(prefix: String, key: String, wrap: String): String =
        call("unwrap", mapOf("prefix" to prefix, "key" to key, "wrap" to wrap)).str("data")

    // ---------- 恢复码 ----------

    /** 新恢复码 → (显示给用户的 XXXXX-XXXXX-XXXXX-XXXXX-XXXXXX, 用来锁住私钥的钥匙) */
    fun recoveryNew(): Pair<String, String> = call("recovery_new").let { it.str("code") to it.str("key") }

    /** 用户输入的恢复码（大小写、空格、横线、O/0、I/L/1 都容错）→ 钥匙；格式不对抛 format */
    fun recoveryKey(code: String): String = call("recovery_key", mapOf("code" to code)).str("key")

    // ---------- 设备批准 ----------

    /** 把账号私钥 sk 转交给公钥为 pub 的设备 */
    fun grantSeal(sk: String, pub: String): String = call("grant_seal", mapOf("sk" to sk, "pub" to pub)).str("grant")

    /** 本机（设备私钥 deviceSk）解开转交来的账号私钥 */
    fun grantOpen(deviceSk: String, grant: String): String = call("grant_open", mapOf("sk" to deviceSk, "grant" to grant)).str("data")

    /** 核对码的承诺。pub 是新设备公钥；account 是新设备看到的账号公钥（批准设备用自己私钥算出的公钥） */
    fun sasCommit(pub: String, account: String, nonce: String): String =
        call("sas_commit", mapOf("pub" to pub, "account" to account, "nonce" to nonce)).str("commit")

    /** 6 位核对码（字符串，保留前导 0） */
    fun sasCode(pub: String, account: String, na: String, nb: String): String =
        call("sas_code", mapOf("pub" to pub, "account" to account, "na" to na, "nb" to nb)).str("code")

    // ---------- 消息与附件 ----------

    /** 用账号的私钥（可以多把）解开信封 → 载荷 {v, text, desp, type, atts:[{name, mime, size, key}]} */
    fun openMessage(keys: List<String>, envelope: String): JSONObject =
        call("open_message", mapOf("keys" to keys, "envelope" to envelope)).optJSONObject("payload")
            ?: throw Failure("format", "解开的内容格式不对")

    /** 解密附件到 dst（先写临时文件，成功后改名；失败不留半成品） */
    fun decryptFile(key: String, src: File, dst: File) {
        call("decrypt_file", mapOf("key" to key, "src" to src.path, "dst" to dst.path))
    }

    /** 本地解析 Markdown（与服务端完全一致）：atts 为 [{id, name, mime, size}] → (doc 的 JSON, 预览文字) */
    fun mdBuild(text: String, desp: String, atts: List<Map<String, Any?>>): Pair<String, String> {
        val r = call("md_build", mapOf("text" to text, "desp" to desp, "atts" to atts.map { JSONObject(it) }))
        val doc = r.optJSONObject("doc") ?: throw Failure("format", "核心库结果缺少 doc")
        return doc.toString() to r.optString("preview")
    }
}
