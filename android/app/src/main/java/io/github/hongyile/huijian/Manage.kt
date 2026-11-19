package io.github.hongyile.huijian

import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder

/*
 * 手机端的管理功能（pushkey、账户与设备、频道）用到的数据结构、解析和校验。
 * 不依赖 Android，规则和服务端（server/selfservice.go、account.go）一致，可以直接做单元测试。
 */

data class PushKey(
    val id: Long,
    val name: String,
    val key: String,
    val createdAt: String,
    /** RFC3339；从未使用时为 null */
    val lastUsed: String?,
    val revoked: Boolean,
)

data class Pairing(val at: Long, val ip: String, val method: String, val client: String) {
    val methodLabel get() = when (method) { "code" -> "配对码"; "password" -> "密码登录"; "register" -> "注册"; else -> method }
}

data class DeviceInfo(
    val id: String,
    val name: String,
    val platform: String,
    val client: String,
    val createdAt: Long,
    val lastSeen: Long?,
    val lastPaired: Long,
    val pairCount: Int,
    val revoked: Boolean,
    val current: Boolean,
    val online: Boolean,
    val pairings: List<Pairing>,
)

data class AccountInfo(val id: Long, val username: String, val hasPassword: Boolean)

data class AccountDetail(val account: AccountInfo, val devices: List<DeviceInfo>, val registerOpen: Boolean)

data class PairCode(val code: String, val expiresIn: Int)

/** 配对码状态：waiting / used / expired */
data class PairCodeStatus(val state: String, val expiresIn: Int?, val usedBy: String?)

object Manage {
    // ---------- 解析 ----------

    fun key(o: JSONObject) = PushKey(
        id = o.optLong("id"),
        name = o.optString("name"),
        key = o.optString("key"),
        createdAt = o.optString("created_at"),
        lastUsed = if (o.isNull("last_used")) null else o.optString("last_used").ifBlank { null },
        revoked = o.optBoolean("revoked"),
    )

    fun keys(o: JSONObject): List<PushKey> = objects(o.optJSONArray("keys")).map(::key)

    fun account(o: JSONObject) = AccountInfo(o.optLong("id"), o.optString("username"), o.optBoolean("has_password"))

    fun device(o: JSONObject) = DeviceInfo(
        id = o.optString("id"),
        name = o.optString("name"),
        platform = o.optString("platform"),
        client = o.optString("client"),
        createdAt = o.optLong("created_at"),
        lastSeen = if (o.has("last_seen") && !o.isNull("last_seen")) o.optLong("last_seen") else null,
        lastPaired = o.optLong("last_paired"),
        pairCount = o.optInt("pair_count", 1),
        revoked = o.optBoolean("revoked"),
        current = o.optBoolean("current"),
        online = o.optBoolean("online"),
        pairings = objects(o.optJSONArray("pairings")).map {
            Pairing(it.optLong("at"), it.optString("ip"), it.optString("method"), it.optString("client"))
        },
    )

    fun accountDetail(o: JSONObject) = AccountDetail(
        account = account(o.optJSONObject("account") ?: JSONObject()),
        devices = objects(o.optJSONArray("devices")).map(::device),
        registerOpen = o.optBoolean("register_open"),
    )

    fun pairCode(o: JSONObject) = PairCode(o.optString("code"), o.optInt("expires_in", 180))

    fun pairStatus(o: JSONObject) = PairCodeStatus(
        state = o.optString("state"),
        expiresIn = if (o.has("expires_in") && !o.isNull("expires_in")) o.optInt("expires_in") else null,
        usedBy = o.optString("used_by").ifBlank { null },
    )

    /** 本机对每把 key 的接收方式：pushkey id → notify / silent / off */
    fun subscriptions(o: JSONObject): Map<Long, String> =
        objects(o.optJSONArray("subscriptions")).associate { it.optLong("pushkey_id") to it.optString("mode", "notify") }

    fun channel(o: JSONObject) = ChannelSetting(
        o.optString("topic"), o.optString("alias"), o.optBoolean("hidden"),
        o.optBoolean("muted"), o.optBoolean("pinned"), o.optInt("sort"),
    )

    private fun objects(a: JSONArray?): List<JSONObject> =
        if (a == null) emptyList() else (0 until a.length()).mapNotNull { a.optJSONObject(it) }

    // ---------- 校验（和服务端一致） ----------

    /** 自定义 key：16–64 位字母、数字、下划线、短横线 */
    val KEY_PATTERN = Regex("^[A-Za-z0-9_-]{16,64}$")
    const val KEY_RULE = "key 需 16–64 位字母、数字、_ 或 -"

    /** 新建时留空表示自动生成；换 key 时必须填 */
    fun keyProblem(key: String, isNew: Boolean): String? {
        val k = key.trim()
        if (k.isEmpty()) return if (isNew) null else "请填写新 key"
        return if (k.matches(KEY_PATTERN)) null else KEY_RULE
    }

    /** 随机 key，格式和服务端自动生成的一样：PK_ + 18 字节 base64url（共 27 位） */
    fun randomKey(): String {
        val b = ByteArray(18).also { java.security.SecureRandom().nextBytes(it) }
        return "PK_" + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(b)
    }

    fun nameProblem(name: String): String? = when {
        name.isBlank() -> "名称不能为空"
        name.trim().codePointCount(0, name.trim().length) > 40 -> "名称最多 40 个字"
        else -> null
    }

    /** 去掉首尾空白，中间连续空白合并成一个空格 */
    fun normalizeUsername(u: String) = u.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")

    private val BLANK_LETTERS = setOf(0x115F, 0x1160, 0x3164, 0xFFA0)
    const val USERNAME_RULE = "用户名 2–32 个字，可以用中文、字母、数字、空格、下划线、点和短横线"

    /** 用户名问题；空字符串返回 null（由调用方判断必填） */
    fun usernameProblem(raw: String): String? {
        val u = normalizeUsername(raw)
        if (u.isEmpty()) return null
        val cps = u.codePoints().toArray()
        if (cps.size < 2 || cps.size > 32) return "用户名需要 2–32 个字"
        val ok = cps.all { c ->
            when {
                c == '_'.code || c == '.'.code || c == '-'.code || c == ' '.code -> true
                c in BLANK_LETTERS -> false
                else -> when (Character.getType(c).toByte()) {
                    Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER,
                    Character.MODIFIER_LETTER, Character.OTHER_LETTER,
                    Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
                    else -> false
                }
            }
        }
        return if (ok) null else USERNAME_RULE
    }

    /** 密码至少 8 位（按字符计）；required=false 时留空表示不改 */
    fun passwordProblem(pw: String, confirm: String, required: Boolean): String? = when {
        pw.isEmpty() && required -> "请设置密码（至少 8 位）"
        pw.isEmpty() -> if (confirm.isEmpty()) null else "两次输入的密码不一样"
        pw.codePointCount(0, pw.length) < 8 -> "密码至少 8 位"
        pw != confirm -> "两次输入的密码不一样"
        else -> null
    }

    // ---------- 发送示例 ----------

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

    /** 浏览器里直接打开就能发的 URL */
    fun sendUrl(server: String, key: String, text: String = "hello") =
        "${server.trimEnd('/')}/message/push?pushkey=${enc(key)}&text=${enc(text)}"

    /** curl 示例（带正文、优先级、频道） */
    fun curlExample(server: String, key: String) =
        "curl \"${sendUrl(server, key)}\"\n\n" +
            "curl ${server.trimEnd('/')}/message/push \\\n" +
            "  -d pushkey=$key -d text=\"训练完成\" \\\n" +
            "  --data-urlencode desp=\"val_loss **0.198**\" \\\n" +
            "  -d priority=4 -d topic=train"

    // ---------- 频道 ----------

    /** 频道顺序（和 Mac 一致）：置顶在前，再按手动顺序，其余按最近一条消息从新到旧 */
    fun orderChannels(names: Collection<String>, settings: Map<String, ChannelSetting>, last: Map<String, Long>): List<String> =
        names.sortedWith { a, b ->
            val sa = settings[a]; val sb = settings[b]
            val pa = sa?.pinned == true; val pb = sb?.pinned == true
            if (pa != pb) return@sortedWith if (pa) -1 else 1
            val oa = sa?.sort?.takeIf { it > 0 } ?: Int.MAX_VALUE
            val ob = sb?.sort?.takeIf { it > 0 } ?: Int.MAX_VALUE
            if (oa != ob) return@sortedWith oa.compareTo(ob)
            val la = last[a] ?: 0; val lb = last[b] ?: 0
            if (la != lb) lb.compareTo(la) else a.compareTo(b)
        }

    /** 把第 from 个移到第 to 个位置 */
    fun <T> moved(list: List<T>, from: Int, to: Int): List<T> {
        if (from !in list.indices || to !in list.indices || from == to) return list
        return list.toMutableList().apply { add(to, removeAt(from)) }
    }
}
