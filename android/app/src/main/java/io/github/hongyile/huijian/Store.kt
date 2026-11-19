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
        prefs.edit().remove("cursor").remove("initialSyncDone").remove("changesCursor").remove("changesEpoch").commit()
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
