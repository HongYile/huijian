package io.github.hongyile.huijian

import android.content.Context
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 本地存储：
 * - 设置放 SharedPreferences；
 * - 设备 token 用 Android Keystore 里的 AES-GCM 密钥加密后保存（密钥不可导出）；
 * - 消息和已读状态存 App 私有目录下的 messages.json，只保留最新 MAX_KEEP 条。
 */
class Store(private val ctx: Context) {
    private val prefs = ctx.getSharedPreferences("huijian", Context.MODE_PRIVATE)
    private val file = File(ctx.filesDir, "messages.json")

    var server: String
        get() = prefs.getString("server", "") ?: ""
        set(v) = prefs.edit().putString("server", v).apply()
    var deviceId: String
        get() = prefs.getString("deviceId", "") ?: ""
        set(v) = prefs.edit().putString("deviceId", v).apply()
    var deviceName: String
        get() = prefs.getString("deviceName", "") ?: ""
        set(v) = prefs.edit().putString("deviceName", v).apply()
    var username: String
        get() = prefs.getString("username", "") ?: ""
        set(v) = prefs.edit().putString("username", v).apply()
    /**
     * 本机登录时记下的用户名（账号密码登录、注册时输入的；配对码登录时用第一次 /v1/me 的；在本机改用户名成功后更新）。
     * 不随服务器 /v1/account 返回的变：判断「已升级」标记时用它，服务器换一个用户名绕不过去（e2ee-client.md §2.1 第 4 条）
     */
    var loginUsername: String
        get() = prefs.getString("loginUsername", "") ?: ""
        set(v) = prefs.edit().putString("loginUsername", v).commit().let { }
    var mode: ReceiveMode
        get() = ReceiveMode.of(prefs.getString("mode", null))
        set(v) = prefs.edit().putString("mode", v.key).apply()
    var intervalMin: Int
        get() = prefs.getInt("intervalMin", 15)
        set(v) = prefs.edit().putInt("intervalMin", v).apply()
    /** 服务端已扫过的位置（next_since），下次从这里继续拉 */
    var cursor: Long
        get() = prefs.getLong("cursor", 0)
        set(v) = prefs.edit().putLong("cursor", v).apply()
    /** 这个账号是否已做过首次同步（首次只取最新 50 条且不提醒）。退出登录、换账号时清除 */
    var initialSyncDone: Boolean
        // 老版本没有这个标记：已经有游标说明同步过，不能当成第一次（否则会跳过升级期间的消息）
        get() = prefs.getBoolean("initialSyncDone", prefs.contains("cursor"))
        set(v) = prefs.edit().putBoolean("initialSyncDone", v).apply()
    /** 多设备变更流的游标；null = 还没对过账（第一次、或游标作废），下一轮先调 /v1/messages/state */
    var changesCursor: Long?
        get() = prefs.getLong("changesCursor", -1).takeIf { it >= 0 }
        set(v) = prefs.edit().apply { if (v == null) remove("changesCursor") else putLong("changesCursor", v) }.apply()
    /** 上次对账时服务端的数据纪元；变了说明服务端重建或从备份恢复 */
    var changesEpoch: String?
        get() = prefs.getString("changesEpoch", null)
        set(v) = prefs.edit().apply { if (v == null) remove("changesEpoch") else putString("changesEpoch", v) }.apply()
    var lastContact: Long
        get() = prefs.getLong("lastContact", 0)
        set(v) = prefs.edit().putLong("lastContact", v).apply()

    /**
     * 「仅本机保留」的消息 id：服务器上已被「删除服务器上的明文消息」删掉（变更 kind purge），本机副本保留，
     * 对账时不当作被删除（e2ee-client.md §7.4）。之后普通删除时移出。换账号、退出登录时清掉
     */
    var keepLocal: Set<Long>
        get() = prefs.getString("keepLocal", "").orEmpty().split(',').mapNotNullTo(HashSet()) { it.toLongOrNull() }
        set(v) = prefs.edit().putString("keepLocal", v.joinToString(",")).apply()

    @Volatile private var tokenCache: String? = null
    val hasToken get() = tokenCache != null || prefs.contains("tokenEnc")
    /** 加密的 token 永久解不开（换机迁移、Keystore 密钥丢失）：只能重新登录 */
    @Volatile var tokenLost = false
        private set

    /** 设备 token。解密结果缓存在内存里；Keystore 偶发异常时返回 null，但 hasToken 仍为真（不当作退出登录） */
    var token: String?
        get() {
            tokenCache?.let { return it }
            val enc = prefs.getString("tokenEnc", null) ?: return null
            return try {
                decrypt(enc).also { tokenCache = it; tokenLost = false }
            } catch (e: javax.crypto.AEADBadTagException) {
                tokenLost = true; null
            } catch (e: android.security.keystore.KeyPermanentlyInvalidatedException) {
                tokenLost = true; null
            } catch (e: Exception) {
                null            // Keystore 偶发异常：下次再试
            }
        }
        set(v) {
            if (v == null) {
                prefs.edit().remove("tokenEnc").commit()
                tokenCache = null
            } else {
                val enc = encrypt(v)
                check(prefs.edit().putString("tokenEnc", enc).commit()) { "保存登录凭证失败" }
                tokenCache = v
            }
            tokenLost = false
        }

    /** 设备指纹：同一台手机重新登录时服务端沿用原来的设备记录（ANDROID_ID 按签名密钥区分，卸载重装不变） */
    fun fingerprint(): String {
        val aid = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ANDROID_ID) ?: "unknown"
        // 前缀是改名前定下的内部常量，保持不变：换装「回笺」后登录仍接管原来的设备记录
        return MessageDigest.getInstance("SHA-256").digest("hongyan-android:$aid".toByteArray())
            .joinToString("") { "%02x".format(it) }
    }

    data class Saved(val messages: List<Message>, val read: Set<Long>)

    fun load(): Saved = runCatching {
        val o = JSONObject(file.readText())
        val arr = o.getJSONArray("messages")
        val ids = o.optJSONArray("read") ?: JSONArray()
        Saved(List(arr.length()) { Message.from(arr.getJSONObject(it)) }, (0 until ids.length()).map { ids.getLong(it) }.toSet())
    }.getOrDefault(Saved(emptyList(), emptySet()))

    @Synchronized
    fun save(messages: List<Message>, read: Set<Long>) {
        val keep = messages.takeLast(MAX_KEEP)
        val keepIds = keep.mapTo(HashSet()) { it.id }
        val o = JSONObject()
            .put("messages", JSONArray().apply { keep.forEach { put(it.toJson()) } })
            .put("read", JSONArray().apply { read.filter { it in keepIds }.forEach { put(it) } })
        val tmp = File(file.path + ".tmp")
        tmp.writeText(o.toString())
        tmp.renameTo(file)
    }

    @Synchronized
    fun clearMessages() {
        file.delete()
        File(ctx.cacheDir, "att").deleteRecursively()     // 附件缓存：换账号后不能留着上一个账号的文件
        prefs.edit().remove("cursor").remove("initialSyncDone").remove("changesCursor").remove("changesEpoch").remove("keepLocal").remove("accountId").commit()
    }

    /** 删除这些附件已下载的文件（消息被其他设备删除、或超过 3000 条被淘汰时） */
    fun deleteAttachmentFiles(ids: Collection<String>) {
        for (id in ids) File(File(ctx.cacheDir, "att"), id.replace(Regex("[^A-Za-z0-9_-]"), "_")).deleteRecursively()
    }

    /**
     * 附件缓存超过 maxBytes 时，按下载时间从旧到新删除，直到不超过上限；busy(目录名) 为真的（正在下载）跳过。
     * 返回删掉的目录名（即附件 id）。
     */
    fun trimAttachmentCache(maxBytes: Long, busy: (String) -> Boolean): List<String> {
        val dirs = File(ctx.cacheDir, "att").listFiles()?.filter { it.isDirectory } ?: return emptyList()
        class Entry(val dir: File, val size: Long, val time: Long)
        val all = dirs.map { d ->
            val files = d.walkTopDown().filter { it.isFile }.toList()
            Entry(d, files.sumOf { it.length() }, files.maxOfOrNull { it.lastModified() } ?: d.lastModified())
        }
        var total = all.sumOf { it.size }
        if (total <= maxBytes) return emptyList()
        val removed = ArrayList<String>()
        // 最新下载的一项永远保留：单个附件就超过上限时（服务端允许 512MB），不能刚下完就被删掉
        for (e in all.sortedBy { it.time }.dropLast(1)) {
            if (total <= maxBytes) break
            if (busy(e.dir.name)) continue
            if (e.dir.deleteRecursively()) { total -= e.size; removed += e.dir.name }
        }
        return removed
    }

    // ---- 端到端加密：账号私钥、等待批准时的设备钥匙对（和 token 一样用 Keystore 加密）、「已升级」标记 ----

    /**
     * 本机保存的加密钥匙。owner = 规范化的服务器地址 + 账号 id，对不上的当作没有。
     * setup：开启加密进行中生成的新钥匙对和恢复码（§4.1，结果确认前）；recovery：还没点「完成」的恢复码（code, 是否刚开启加密）。
     * 和私钥同等保护，App 被系统终止也不丢
     */
    data class E2EVault(
        val keys: List<LocalKey>, val device: Core.KeyPair?,
        val setup: SetupResult? = null, val recovery: Pair<String, Boolean>? = null,
        /** 更换恢复码进行中（结果确认前）：新恢复码和这次上传的 recovery_wrap */
        val rotation: RecoveryRotation? = null,
    ) {
        val isEmpty get() = keys.isEmpty() && device == null && setup == null && recovery == null && rotation == null
    }

    /** 读取；Keystore 解不开时抛异常（调用方当作「未解锁」并显示原因） */
    @Synchronized
    fun e2eLoad(owner: String): E2EVault {
        val enc = prefs.getString("e2eEnc", null) ?: return E2EVault(emptyList(), null)
        val o = JSONObject(decrypt(enc))
        if (o.optString("owner") != owner) return E2EVault(emptyList(), null)
        val arr = o.optJSONArray("keys") ?: JSONArray()
        val keys = (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
            .map { LocalKey(it.optString("kid"), it.optString("pub"), it.optString("sk")) }.filter { it.sk.isNotEmpty() }
        val d = o.optJSONObject("device")?.let { Core.KeyPair(it.optString("sk"), it.optString("pub"), it.optString("kid")) }
        val setup = o.optJSONObject("setup")?.let {
            SetupResult(LocalKey(it.optString("kid"), it.optString("pub"), it.optString("sk")), it.optString("code"))
        }?.takeIf { it.key.sk.isNotEmpty() && it.recoveryCode.isNotEmpty() }
        val rec = o.optJSONObject("recovery")?.let { it.optString("code") to it.optBoolean("enabled") }?.takeIf { it.first.isNotEmpty() }
        val rot = o.optJSONObject("rotation")?.let { RecoveryRotation(it.optString("code"), it.optString("wrap")) }
            ?.takeIf { it.code.isNotEmpty() && it.wrap.isNotEmpty() }
        return E2EVault(keys, d?.takeIf { it.sk.isNotEmpty() }, setup, rec, rot)
    }

    @Synchronized
    fun e2eSave(owner: String, v: E2EVault) {
        if (v.isEmpty) { e2eClear(); return }
        val o = JSONObject().put("owner", owner)
            .put("keys", JSONArray().apply { v.keys.forEach { put(JSONObject().put("kid", it.kid).put("pub", it.pub).put("sk", it.sk)) } })
        v.device?.let { o.put("device", JSONObject().put("sk", it.sk).put("pub", it.pub).put("kid", it.kid)) }
        v.setup?.let { o.put("setup", JSONObject().put("sk", it.key.sk).put("pub", it.key.pub).put("kid", it.key.kid).put("code", it.recoveryCode)) }
        v.recovery?.let { o.put("recovery", JSONObject().put("code", it.first).put("enabled", it.second)) }
        v.rotation?.let { o.put("rotation", JSONObject().put("code", it.code).put("wrap", it.wrap)) }
        check(prefs.edit().putString("e2eEnc", encrypt(o.toString())).commit()) { "保存加密钥匙失败" }
    }

    /** 退出登录、设备被移除：删除本机为这个账号保存的全部私钥和设备钥匙对（「已升级」标记不删） */
    @Synchronized
    fun e2eClear() { prefs.edit().remove("e2eEnc").remove("e2eNotified").commit() }

    /** 已经发过系统通知的批准请求（device_id@requested_at），同一个请求只通知一次 */
    var e2eNotified: Set<String>
        get() = prefs.getStringSet("e2eNotified", null)?.toSet() ?: emptySet()
        set(v) = prefs.edit().putStringSet("e2eNotified", v).apply()

    /** 当前账号的 id（GET /v1/me 的 account.id）；0 = 还不知道。本机私钥、钉住的公钥按「服务器 + 账号 id」记 */
    var accountId: Long
        get() = prefs.getLong("accountId", 0)
        set(v) = prefs.edit().putLong("accountId", v).apply()

    /** 钉住的账号公钥（§1）：owner = 规范化的服务器地址 + 账号 id。第一次保存私钥时写入，之后不改；退出登录也不删 */
    fun pinnedPub(owner: String): String? = prefs.getString("e2ePin:$owner", null)?.takeIf { it.isNotEmpty() }

    fun pin(owner: String, pub: String) {
        if (pinnedPub(owner) == null) prefs.edit().putString("e2ePin:$owner", pub).commit()
    }

    /** 「这个服务器上的这个账号已升级」（UpgradeFlags.key）：退出登录也不删 */
    val upgradeFlags: UpgradeFlags = object : UpgradeFlags {
        override fun isUpgraded(server: String, username: String) =
            prefs.getStringSet("e2eUpgraded", null)?.contains(UpgradeFlags.key(server, username)) == true

        override fun markUpgraded(server: String, username: String) {
            if (username.isBlank()) return
            synchronized(this) {
                val cur = prefs.getStringSet("e2eUpgraded", null)?.toSet() ?: emptySet()
                val k = UpgradeFlags.key(server, username)
                if (k !in cur) prefs.edit().putStringSet("e2eUpgraded", cur + k).commit()
            }
        }
    }

    // ---- token 加密 ----

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return gen.generateKey()
    }

    private fun encrypt(s: String): String {
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val enc = c.doFinal(s.toByteArray())
        return Base64.encodeToString(c.iv + enc, Base64.NO_WRAP)
    }

    private fun decrypt(s: String): String {
        val raw = Base64.decode(s, Base64.NO_WRAP)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, raw, 0, 12))
        return String(c.doFinal(raw, 12, raw.size - 12))
    }

    companion object {
        const val MAX_KEEP = 3000
        private const val KEY_ALIAS = "huijian-token"
    }
}
