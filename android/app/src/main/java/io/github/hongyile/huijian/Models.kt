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
    /** 加密附件的钥匙（载荷 atts[i].key，base64url）；空 = 明文附件。name / mime / size 已换成载荷里的真实值，sha256 是密文的 */
    val key: String = "",
) {
    val isImage get() = mime.startsWith("image/")
    val encrypted get() = key.isNotEmpty()

    fun toJson() = JSONObject().put("id", id).put("name", name).put("mime", mime).put("size", size).put("sha256", sha256)
        .apply { if (key.isNotEmpty()) put("key", key) }

    companion object {
        fun from(o: JSONObject) = Attachment(
            id = o.optString("id"),
            name = o.optString("name"),
            mime = o.optString("mime", "application/octet-stream"),
            size = o.optLong("size"),
            sha256 = o.optString("sha256"),
            key = o.optString("key"),
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
    /** 端到端加密的信封原文（hje1.…）；明文消息为 null。解开后仍保留，换钥匙、重新解密时要用 */
    val e2e: String? = null,
    /** 加密消息的解密结果：ok / locked / wrong_key / format（E2EMessages）；空 = 还没处理（刚从服务端拉到） */
    val e2eStatus: String = "",
    /** 服务器代加密（§11.5，服务端 0.8.0 起消息 JSON 的 sealed: "server"）：发送方发的是明文，服务器收到后才加密。详情页显示 T64 */
    val serverSealed: Boolean = false,
    /** 0.10.0 起 agent 发来的消息（docs/agent-mcp.md）：会话 id、是否在等回复（服务器给的，只用来路由和突出显示） */
    val agentSession: String? = null,
    val ask: Boolean = false,
    /** 本机解开 agent 消息后得到的：会话证明里的名称、快捷回复（只在本机产生，fromServer 一律清空） */
    val agentName: String? = null,
    val choices: List<String> = emptyList(),
    /** 本机解开的载荷里的 seq（回复时写进 re_seq）；0 = 没有 */
    val agentSeq: Long = 0,
) {
    val title get() = text.ifBlank { attachments.firstOrNull()?.name ?: "（无标题）" }

    /** 端到端加密的消息 */
    val encrypted get() = e2e != null
    /** 加密消息还没解开（已锁定、或解不开）：标题是说明文字，正文为空，附件是密文 */
    val sealed get() = e2e != null && e2eStatus != E2EMessages.OK

    fun toJson(): JSONObject = JSONObject()
        .put("id", id).put("topic", topic).put("thread", thread).put("priority", priority)
        .put("type", type).put("text", text).put("desp", desp).put("source", source)
        .put("created_at", createdAt.toString())
        .put("attachments", JSONArray().apply { attachments.forEach { put(it.toJson()) } })
        .put("silent", silent).put("silent_reason", silentReason).put("archive", archive)
        .apply { if (doc != null) put("doc", doc); if (preview.isNotEmpty()) put("preview", preview) }   // 本地缓存里 doc 存成字符串
        .apply { if (e2e != null) put("e2e", e2e); if (e2eStatus.isNotEmpty()) put("e2e_status", e2eStatus) }
        .apply { if (serverSealed) put("sealed", "server") }
        .apply {
            if (agentSession != null) put("agent_session", agentSession)
            if (ask) put("ask", true)
            if (agentName != null) put("agent_name", agentName)
            if (choices.isNotEmpty()) put("choices", JSONArray(choices))
            if (agentSeq > 0) put("agent_seq", agentSeq)
        }

    /** agent 发来的消息（可以回复，能不能回复见 Agent.replyBlock） */
    val isAgent get() = agentSession != null

    /** 列表摘要 / 通知正文：优先用服务端的 preview，旧服务端或旧缓存退回本地去标记 */
    fun summary(): String = preview.ifBlank { if (type == "text") desp.trim() else Markdown.plain(desp) }

    companion object {
        /**
         * 解码服务端发来的消息：只在本机产生的字段（解密状态、附件钥匙）一律清空，只能由本机解密写入。
         * 否则被攻破的服务器可以带上「已解密」和自己写的文字，冒充一条 🔒 消息（e2ee-client.md §1）
         */
        fun fromServer(o: JSONObject): Message = from(o).let { m ->
            m.copy(e2eStatus = "", attachments = m.attachments.map { if (it.key.isEmpty()) it else it.copy(key = "") },
                agentName = null, choices = emptyList(), agentSeq = 0)
        }

        /** 解码本地缓存（messages.json）；服务端响应要用 fromServer */
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
                e2e = o.optString("e2e").ifBlank { null },
                e2eStatus = o.optString("e2e_status"),
                serverSealed = o.optString("sealed") == "server",
                agentSession = if (o.isNull("agent_session")) null else o.optString("agent_session").ifBlank { null },
                ask = o.optBoolean("ask"),
                agentName = if (o.isNull("agent_name")) null else o.optString("agent_name").ifBlank { null },
                choices = o.optJSONArray("choices")?.let { a -> (0 until a.length()).mapNotNull { a.opt(it) as? String } }.orEmpty(),
                agentSeq = o.optLong("agent_seq"),
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
