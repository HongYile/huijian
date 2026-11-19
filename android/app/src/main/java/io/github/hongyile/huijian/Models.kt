package io.github.hongyile.huijian

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

data class Attachment(
    val id: String,
    val name: String,
    val mime: String,
    val size: Long,
    val sha256: String,
) {
    val isImage get() = mime.startsWith("image/")

    fun toJson() = JSONObject().put("id", id).put("name", name).put("mime", mime).put("size", size).put("sha256", sha256)

    companion object {
        fun from(o: JSONObject) = Attachment(
            id = o.optString("id"),
            name = o.optString("name"),
            mime = o.optString("mime", "application/octet-stream"),
            size = o.optLong("size"),
            sha256 = o.optString("sha256"),
        )
    }
}

data class Message(
    val id: Long,
    val topic: String,
    val thread: String,
    val priority: Int,
    val type: String,
    val text: String,
    val desp: String,
    val source: String,
    val createdAt: Instant,
    val attachments: List<Attachment>,
    /** 服务端按本机规则（key 设为静默、频道静音 / 隐藏、在别的设备上使用中）标记为不提醒 */
    val silent: Boolean = false,
    val silentReason: String = "",
    val archive: Int = 0,
    /** 服务端 0.6.0 起解析好的回笺 Markdown（{"v":1,"blocks":[…]}）的 JSON 文本；只存字符串，打开详情时再用 MdDoc.parse 解析 */
    val doc: String? = null,
    /** 服务端生成的纯文本预览（≤200 字），列表摘要和通知优先用它 */
    val preview: String = "",
) {
    val title get() = text.ifBlank { attachments.firstOrNull()?.name ?: "（无标题）" }

    fun toJson(): JSONObject = JSONObject()
        .put("id", id).put("topic", topic).put("thread", thread).put("priority", priority)
        .put("type", type).put("text", text).put("desp", desp).put("source", source)
        .put("created_at", createdAt.toString())
        .put("attachments", JSONArray().apply { attachments.forEach { put(it.toJson()) } })
        .put("silent", silent).put("silent_reason", silentReason).put("archive", archive)
        .apply { if (doc != null) put("doc", doc); if (preview.isNotEmpty()) put("preview", preview) }   // 本地缓存里 doc 存成字符串

    /** 列表摘要 / 通知正文：优先用服务端的 preview，旧服务端或旧缓存退回本地去标记 */
    fun summary(): String = preview.ifBlank { if (type == "text") desp.trim() else Markdown.plain(desp) }

    companion object {
        fun from(o: JSONObject): Message {
            val atts = o.optJSONArray("attachments")
            return Message(
                id = o.getLong("id"),
                topic = o.optString("topic", "default").ifBlank { "default" },
                thread = o.optString("thread"),
                priority = o.optInt("priority", 3),
                type = o.optString("type", "markdown"),
                text = o.optString("text"),
                desp = o.optString("desp"),
                source = o.optString("source"),
                createdAt = runCatching { Instant.parse(o.optString("created_at")) }.getOrDefault(Instant.now()),
                attachments = if (atts == null) emptyList() else List(atts.length()) { Attachment.from(atts.getJSONObject(it)) },
                silent = o.optBoolean("silent"),
                silentReason = o.optString("silent_reason"),
                archive = o.optInt("archive"),
                // 服务端下发的是对象；本地缓存里是字符串（0.2.0 开发版缓存过对象，两种都认）
                doc = when (val d = o.opt("doc")) { is JSONObject -> d.toString(); is String -> d.ifBlank { null }; else -> null },
                preview = o.optString("preview"),
            )
        }
    }
}

object Priority {
    fun label(p: Int) = when (p) {
        5 -> "P5 紧急"; 4 -> "P4 重要"; 3 -> "P3 普通"; 2 -> "P2 低"; 1 -> "P1 日志"; else -> "P0 调试"
    }
}

/** 接收方式：实时长轮询，或按固定间隔检查一次 */
enum class ReceiveMode(val key: String) {
    REALTIME("realtime"), INTERVAL("interval");

    companion object {
        fun of(k: String?) = entries.firstOrNull { it.key == k } ?: REALTIME
        val intervalOptions = listOf(5, 15, 30, 60)
    }
}
