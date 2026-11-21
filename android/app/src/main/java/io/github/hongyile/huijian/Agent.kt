package io.github.hongyile.huijian

import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom
import java.util.Base64

/*
 * agent 双向（docs/agent-mcp.md §5.1、§8、§11）：设备一侧的纯逻辑，和 Mac / iPhone 的 Agent.swift 对应。
 * 不依赖 Android：密码学经 AgentCrypto（正式实现是 CoreCrypto，Rust 共用核心），网络经 AgentNet（正式实现是 Api）。
 * 服务器给的内容一律不信：会话公钥要有本账号私钥写的会话证明，agent 消息、回执都用核实过的会话公钥解开（auth 模式核对发送方）。
 * 界面、通知这些和 Android 有关的部分在 AgentHub.kt。
 */

/** 文案（和 Mac 的 Agent.T 一致） */
object AgentText {
    const val UNVERIFIED = "🔒 来源无法核实的 agent 消息"
    const val TAKEN = "这个请求已被另一台设备接手"
    const val RESTARTED = "对方重新发起了请求，请重新批准"
    const val GONE = "请求已结束（超时、被拒绝或已在别的设备上处理）"
    const val COMMIT_MISMATCH = "核对失败：agent 看到的不是你账号的公钥，可能有人冒充，已拒绝"
    const val ENDED = "这个 agent 会话已结束，不能再回复"
    const val TOO_LONG = "回复太长（最多 16 KB）"
    const val EMPTY = "回复不能为空"
    const val WAITING_REPLY = "等你回复"
    const val CHOICE_HINT = "选好选项、写好补充（都可选），再点发送。"
    const val TOOK_REPLY = "agent 已拿到你的回复，现在没在等你；再发的回复要等它下次查看才会收到。"

    /** 回复正文：快捷选项和补充文字一起发。都有时第一行是选项、后面是补充（docs/agent-mcp.md §5.1；和 Mac / iPhone 一致） */
    fun composeReply(choice: String?, text: String): String {
        val t = text.trim()
        if (choice.isNullOrEmpty()) return t
        return if (t.isEmpty()) choice else choice + "\n" + t
    }
    const val LOCKED_APPROVE = "本机还没有解锁加密，不能批准"
    const val LOCKED_APPROVE_HINT = "本机还没有解锁加密，不能批准（批准要用账号私钥写会话证明）。"
    const val LOCKED_REPLY = "本机还没有解锁加密，不能回复"
    fun codeHint(name: String) = "确认「$name」那边显示的也是这 6 位数字，再批准。"

    // 回复区不能回复时显示的原因（和 Mac 的 AgentReplyPanel.reason 一致）
    const val NO_REPLY_UNVERIFIED = "来源无法核实，不能回复。"
    const val NO_REPLY_SEALED = "消息还没解开，不能回复。"
    const val NO_REPLY_LOCKED = "本机还没有解锁加密，不能回复。"
    const val NO_REPLY_LOADING = "正在读取 agent 会话…"
    const val NO_REPLY_OLD_KEY = "这个会话是重置加密前批准的，不能再回复。"
    const val NO_REPLY_NO_SEQ = "这条消息没有序号，不能回复。"
    const val UNSUPPORTED = "服务端版本较旧，agent 双向需要回笺服务端 0.10.0 及以上，请更新服务端"

    // 连接 agent（连接码，服务端 0.11.0，功能 agent.connect；和 Mac / iPhone 一致）
    const val CONNECT_STEPS = "1. 在 agent 所在的电脑上安装 huijian 命令行（GitHub Releases 下载，Windows 版首次运行会自动装好）。\n2. 运行上面这行命令，或运行 huijian agent setup 再输入连接码。\n3. 本页最上方出现登录请求时点「批准」，核对两边的 6 位核对码。\nsetup 会自动把回笺接入这台电脑上的 Claude Code、Codex、Cursor、DeepSeek Harness、Hermes、Qwen Code、Pi。"
    const val CLI_DOWNLOAD = "https://github.com/HongYile/huijian/releases/latest"

    /** 给用户复制的一行命令 */
    fun setupCommand(server: String, code: String) = "huijian agent setup -u $server $code"
}

// ---------- 接口：正式实现是 Core / Api，测试时换成假的 ----------

/** 共用核心里 agent 用到的操作（Core 的子集，签名一致） */
interface AgentCrypto {
    fun publicKey(sk: String): Pair<String, String>
    fun random32(): String
    fun openMessage(keys: List<String>, envelope: String): JSONObject
    fun mdBuild(text: String, desp: String, atts: List<Map<String, Any?>>): Pair<String, String>
    fun agentCommit(pub: String, account: String, nonce: String, name: String): String
    fun agentSas(pub: String, account: String, na: String, nb: String): String
    fun agentAttestSeal(sk: String, sessionId: String, pub: String, name: String, approvedAt: Long): String
    fun agentAttestOpen(sk: String, attest: String, sessionId: String, pub: String): String
    fun agentOpen(keys: List<String>, sessionPub: String, sessionId: String, envelope: String): JSONObject
    fun agentReplySeal(sk: String, sessionPub: String, sessionId: String, msgId: Long, payload: String): Pair<String, String>
}

/** 正式实现：Rust 共用核心 */
object CoreAgentCrypto : AgentCrypto {
    override fun publicKey(sk: String) = Core.publicKey(sk)
    override fun random32() = Core.random32()
    override fun openMessage(keys: List<String>, envelope: String) = Core.openMessage(keys, envelope)
    override fun mdBuild(text: String, desp: String, atts: List<Map<String, Any?>>) = Core.mdBuild(text, desp, atts)
    override fun agentCommit(pub: String, account: String, nonce: String, name: String) = Core.agentCommit(pub, account, nonce, name)
    override fun agentSas(pub: String, account: String, na: String, nb: String) = Core.agentSas(pub, account, na, nb)
    override fun agentAttestSeal(sk: String, sessionId: String, pub: String, name: String, approvedAt: Long) =
        Core.agentAttestSeal(sk, sessionId, pub, name, approvedAt)
    override fun agentAttestOpen(sk: String, attest: String, sessionId: String, pub: String) = Core.agentAttestOpen(sk, attest, sessionId, pub)
    override fun agentOpen(keys: List<String>, sessionPub: String, sessionId: String, envelope: String) =
        Core.agentOpen(keys, sessionPub, sessionId, envelope)
    override fun agentReplySeal(sk: String, sessionPub: String, sessionId: String, msgId: Long, payload: String) =
        Core.agentReplySeal(sk, sessionPub, sessionId, msgId, payload)
}

/**
 * 设备一侧的 agent 接口（docs/agent-mcp.md §11.3），Api 实现它。
 * 失败抛 ApiException（oldServer = 服务端没有这个接口）/ UnauthorizedException / IOException
 */
interface AgentNet {
    /** GET /v1/agent/keys */
    fun agentKeys(): JSONObject
    /** POST /v1/agent/keys：明文只返回这一次；已满时 409 */
    fun agentCreateKey(): JSONObject
    /** POST /v1/agent/connect-codes：生成连接码（服务端 0.11.0）；key 已满 10 把、账号没有加密钥匙时 409（error 是中文说明） */
    fun agentConnectCode(): JSONObject
    /** DELETE /v1/agent/keys/{id} */
    fun agentRevokeKey(id: Long)
    /** GET /v1/agent/sessions */
    fun agentSessions(): JSONObject
    /** DELETE /v1/agent/sessions/{id}：结束会话 */
    fun agentEnd(id: String)
    /** POST /v1/agent/sessions/{id}/challenge：已被别的设备接手时 409 */
    fun agentChallenge(id: String, nonce: String)
    /** POST /v1/agent/sessions/{id}/approve */
    fun agentApprove(id: String, attest: String)
    /** POST /v1/agent/sessions/{id}/deny */
    fun agentDeny(id: String)
    /** POST /v1/agent/replies → {reply_id}；会话已结束时 409 */
    fun agentReply(msgId: Long, envelope: String, copy: String): JSONObject
    /** GET /v1/agent/replies/status?msg_id= */
    fun agentReplyStatus(msgId: Long): JSONObject
}

// ---------- 数据 ----------

/** name：连接码兑换时 agent 报的名字（服务端 0.11.0 起；手动新建的为空） */
data class AgentKeyInfo(val id: Long, val prefix: String, val createdAt: String? = null, val lastUsed: String? = null, val name: String? = null) {
    /** 列表里显示的标签：有名字时「名字 · 前缀…」，否则「前缀…」 */
    val label get() = if (name.isNullOrEmpty()) "$prefix…" else "$name · $prefix…"
}

/** 连接码：10 分钟有效、只能用一次，agent 用 huijian agent setup 兑换自己的 Agent key。expiresIn 是秒 */
data class AgentConnectCode(val code: String, val expiresIn: Long, val expiresAt: String? = null)

data class AgentNewKey(val id: Long, val key: String, val prefix: String)

/** GET /v1/agent/sessions 的一项；state：pending / approved / denied / expired / ended。时间是 RFC 3339 字符串（没有时 null） */
data class AgentSession(
    val id: String, val name: String = "", val pub: String = "", val state: String = "pending",
    val commit: String = "", val challenge: String = "", val reveal: String = "", val attest: String = "",
    val createdAt: String? = null, val approvedAt: String? = null, val endedAt: String? = null, val lastSeen: String? = null,
    val online: Boolean = false,
) {
    val pending get() = state == "pending"
    val active get() = state == "approved"
}

data class AgentReplyStatus(
    val replyId: Long, val sessionId: String = "", val state: String = "", val createdAt: String? = null, val receivedAt: String? = null,
    val copy: String = "", val receipt: String = "", val device: String = "",
)

/**
 * 核实过的会话：名称取自会话证明（服务器给的 name 不用），公钥用来解开它的消息、加密给它的回复。
 * current：证明是账号**当前**钥匙写的，只有这样的会话能回复；重置加密前的旧钥匙写的只用来显示历史消息
 * （旧私钥可能已经泄露：拿着旧私钥又控制服务器的人能给自己的公钥伪造证明）
 */
data class AgentVerified(val name: String, val pub: String, val current: Boolean = true)

/** 一条回复在本机显示的样子。sentAt / receivedAt 是 Unix 秒；received 只在回执核对通过时才算 */
data class AgentReplyView(val id: Long, val text: String, val device: String, val sentAt: Long?, val state: State, val receivedAt: Long?) {
    enum class State { SENT, RECEIVED, EXPIRED }

    val label get() = when (state) {
        State.SENT -> "已发出"
        State.RECEIVED -> "✓✓ agent 已收到"
        State.EXPIRED -> "已过期（agent 没有取走）"
    }
}

/** 批准 agent 登录的进度（§11.2：同设备批准，只换前缀） */
sealed interface AgentPhase {
    /** 已出 na，等 agent 揭晓 */
    data object Challenged : AgentPhase
    /** 核对码 */
    data class Code(val code: String) : AgentPhase
    data object Approved : AgentPhase
    data object Rejected : AgentPhase
    data class Failed(val message: String) : AgentPhase
}

/**
 * 批准一个 agent 登录请求。na 只用自己生成的随机数；account 是用本机私钥算出的账号公钥，
 * 不用服务器给的（agent 看到的是假的账号公钥时，承诺对不上，自动拒绝）。
 */
class AgentApproval private constructor(private val c: AgentCrypto, val session: AgentSession, private val na: String, private val account: String) {
    @Volatile var phase: AgentPhase = AgentPhase.Challenged
        private set
    @Volatile var stopped = false
        private set

    fun stop() { stopped = true }

    companion object {
        /** 第 1 步：生成自己的 na 并接手请求；sk：本机的账号私钥。已被别的设备接手（409）→ TAKEN */
        fun begin(net: AgentNet, c: AgentCrypto, session: AgentSession, sk: String): AgentApproval {
            val account = c.publicKey(sk).first
            val na = c.random32()
            try {
                net.agentChallenge(session.id, na)
            } catch (e: ApiException) {
                if (e.status == 409) throw E2EError(AgentText.TAKEN)
                throw e
            }
            return AgentApproval(c, session, na, account)
        }
    }

    /** 每次拿到新的会话列表时调用 */
    @Synchronized
    fun handle(sessions: List<AgentSession>, net: AgentNet): AgentPhase {
        if (stopped || phase != AgentPhase.Challenged) return phase
        val s = sessions.firstOrNull { it.id == session.id }
        if (s == null || !s.pending) { phase = AgentPhase.Failed(AgentText.GONE); return phase }
        if (s.pub != session.pub || s.commit != session.commit || s.name != session.name || s.challenge != na) {
            phase = AgentPhase.Failed(AgentText.RESTARTED); return phase
        }
        if (s.reveal.isEmpty()) return phase
        // 用本机私钥算出的账号公钥核对承诺：agent 看到的是假的账号公钥时对不上。
        // 名称也在承诺里（用接手时快照的名称）：服务器改不了设备上显示、写进证明的名称
        val commit = runCatching { c.agentCommit(s.pub, account, s.reveal, session.name) }.getOrNull()
        val code = if (commit == s.commit) runCatching { c.agentSas(s.pub, account, na, s.reveal) }.getOrNull() else null
        if (code == null) {
            runCatching { net.agentDeny(s.id) }
            phase = AgentPhase.Failed(AgentText.COMMIT_MISMATCH)
            return phase
        }
        phase = AgentPhase.Code(code)
        return phase
    }

    /** 「一致，批准」：写会话证明。nowSec：批准时间（Unix 秒）。409 → 失败（显示服务端说明）并抛出 */
    @Synchronized
    fun approve(net: AgentNet, sk: String, nowSec: Long = System.currentTimeMillis() / 1000) {
        if (stopped || phase !is AgentPhase.Code) return
        val attest = c.agentAttestSeal(sk, session.id, session.pub, session.name, nowSec)
        try {
            net.agentApprove(session.id, attest)
        } catch (e: ApiException) {
            if (e.status == 409) {
                val m = e.message ?: AgentText.GONE
                phase = AgentPhase.Failed(m)
                throw E2EError(m)
            }
            throw e
        }
        phase = AgentPhase.Approved
    }

    @Synchronized
    fun reject(net: AgentNet) {
        net.agentDeny(session.id)
        phase = AgentPhase.Rejected
    }
}

object Agent {
    /** 回复文字最长 16 KB（UTF-8） */
    const val MAX_REPLY_BYTES = 16 shl 10
    /** 快捷回复：最多 4 个、每个 1–20 字 */
    const val MAX_CHOICES = 4
    const val MAX_CHOICE_LEN = 20
    /** 标题最长 2000 字（和 Mac 一致） */
    const val MAX_TEXT = 2000

    // ---------- 解析服务端结构 ----------

    /** JSON 里的可选字符串：没有、null、空串都是 null（org.json 的 optString 遇到 null 会返回 "null"） */
    private fun JSONObject.str(k: String): String? = if (!has(k) || isNull(k)) null else optString(k).ifEmpty { null }

    private fun objects(a: JSONArray?): List<JSONObject> = if (a == null) emptyList() else (0 until a.length()).mapNotNull { a.optJSONObject(it) }

    fun parseKeys(o: JSONObject): List<AgentKeyInfo> = objects(o.optJSONArray("keys")).map {
        AgentKeyInfo(it.optLong("id"), it.optString("prefix"), it.str("created_at"), it.str("last_used"), it.str("name"))
    }

    /** POST /v1/agent/connect-codes 的结果；没有连接码时报错，有效期缺失或不合理时按 10 分钟算 */
    fun parseConnectCode(o: JSONObject): AgentConnectCode {
        val code = o.str("code") ?: throw E2EError("服务器没有返回连接码")
        val sec = o.optLong("expires_in", 0)
        return AgentConnectCode(code, if (sec > 0) sec else 600, o.str("expires_at"))
    }

    fun parseNewKey(o: JSONObject): AgentNewKey {
        val key = o.str("key") ?: throw E2EError("服务器没有返回新的 Agent key")
        return AgentNewKey(o.optLong("id"), key, o.optString("prefix"))
    }

    fun parseSession(o: JSONObject) = AgentSession(
        id = o.optString("id"), name = o.str("name").orEmpty(), pub = o.str("pub").orEmpty(), state = o.str("state").orEmpty(),
        commit = o.str("commit").orEmpty(), challenge = o.str("challenge").orEmpty(), reveal = o.str("reveal").orEmpty(),
        attest = o.str("attest").orEmpty(), createdAt = o.str("created_at"), approvedAt = o.str("approved_at"),
        endedAt = o.str("ended_at"), lastSeen = o.str("last_seen"), online = o.optBoolean("online"),
    )

    fun parseSessions(o: JSONObject): List<AgentSession> = objects(o.optJSONArray("sessions")).map(::parseSession).filter { it.id.isNotEmpty() }

    fun parseReplyStatus(o: JSONObject): List<AgentReplyStatus> = objects(o.optJSONArray("replies")).map {
        AgentReplyStatus(it.optLong("reply_id"), it.str("session_id").orEmpty(), it.str("state").orEmpty(), it.str("created_at"),
            it.str("received_at"), it.str("copy").orEmpty(), it.str("receipt").orEmpty(), it.str("device").orEmpty())
    }

    // ---------- 核实会话 ----------

    /**
     * 用账号私钥（可以多把：重置加密前批准的会话用旧钥匙写的证明）核对每个会话的证明；核对不过的不在结果里。
     * current：账号当前的私钥（null = 不知道，全部按旧钥匙处理，不能回复）
     */
    fun verify(sessions: List<AgentSession>, keys: List<String>, current: String?, c: AgentCrypto): Map<String, AgentVerified> {
        val out = LinkedHashMap<String, AgentVerified>()
        for (s in sessions) {
            if (s.attest.isEmpty() || s.pub.isEmpty()) continue
            for (k in keys) {
                val name = runCatching { c.agentAttestOpen(k, s.attest, s.id, s.pub) }.getOrNull() ?: continue
                out[s.id] = AgentVerified(name, s.pub, current = current != null && k == current)
                break
            }
        }
        return out
    }

    // ---------- 收消息 ----------

    private fun cps(s: String) = s.codePointCount(0, s.length)
    private fun takeCps(s: String, n: Int) = if (cps(s) <= n) s else s.substring(0, s.offsetByCodePoints(0, n))

    /**
     * 解开一条 agent 消息（hje2）。没有私钥 → locked；会话没核实（证明缺失、对不上）→ unverified；
     * 带附件（第一版 agent 消息只有文字）、kind 不是 message、发送方核对失败 → format；不是本账号钥匙 → wrong_key。
     * 不是 agent 消息、或已经解开的原样返回
     */
    fun open(m: Message, keys: List<String>, verified: Map<String, AgentVerified>, c: AgentCrypto): Message {
        val env = m.e2e ?: return m
        val sid = m.agentSession ?: return m
        if (m.e2eStatus == E2EMessages.OK) return m
        if (keys.isEmpty()) return E2EMessages.sealed(m, E2EMessages.LOCKED)
        val v = verified[sid] ?: return E2EMessages.sealed(m, E2EMessages.UNVERIFIED)
        if (m.attachments.isNotEmpty()) return E2EMessages.sealed(m, E2EMessages.FORMAT)
        val p = try {
            c.agentOpen(keys, v.pub, sid, env)
        } catch (e: Core.Failure) {
            return E2EMessages.sealed(m, if (e.code == "wrong_key") E2EMessages.WRONG_KEY else E2EMessages.FORMAT)
        } catch (_: Exception) {
            return E2EMessages.sealed(m, E2EMessages.FORMAT)
        }
        if (p.optString("kind") != "message") return E2EMessages.sealed(m, E2EMessages.FORMAT)
        val text = takeCps(p.optString("text").trim(), MAX_TEXT)
        val desp = p.optString("desp")
        // 快捷回复：最多 4 个、每个 1–20 字，不合格的丢掉
        val arr = p.optJSONArray("choices")
        val choices = (0 until (arr?.length() ?: 0)).mapNotNull { arr!!.opt(it) as? String }
            .map { it.trim() }.filter { cps(it) in 1..MAX_CHOICE_LEN }.take(MAX_CHOICES)
        val (doc, preview) = if (desp.isBlank()) null to "" else try { c.mdBuild(text, desp, emptyList()) } catch (_: Exception) { null to "" }
        // 「等你回复」用载荷里的 ask（服务器给的只在解开前显示占位）；seq 回复时写进 re_seq
        return m.copy(text = text, desp = desp, type = "markdown", doc = doc, preview = preview, e2eStatus = E2EMessages.OK,
            agentName = v.name, choices = choices, ask = p.optBoolean("ask"), agentSeq = p.optLong("seq"))
    }

    // ---------- 回复 ----------

    /**
     * 这条消息现在能不能回复：null = 可以；否则是显示给用户的原因。
     * 要求：已解开且带 seq + 本机已解锁 + 会话由当前钥匙核实 + 会话还在（approved）。loaded：会话列表读到过了
     */
    fun replyBlock(m: Message, unlocked: Boolean, verified: Map<String, AgentVerified>, sessions: List<AgentSession>, loaded: Boolean = true): String? {
        val sid = m.agentSession ?: return AgentText.ENDED
        if (m.e2eStatus != E2EMessages.OK) return if (m.e2eStatus == E2EMessages.UNVERIFIED) AgentText.NO_REPLY_UNVERIFIED else AgentText.NO_REPLY_SEALED
        if (!unlocked) return AgentText.NO_REPLY_LOCKED
        if (!loaded) return AgentText.NO_REPLY_LOADING
        val v = verified[sid] ?: return AgentText.NO_REPLY_UNVERIFIED
        if (!v.current) return AgentText.NO_REPLY_OLD_KEY
        if (m.agentSeq <= 0) return AgentText.NO_REPLY_NO_SEQ
        if (sessions.none { it.id == sid && it.active }) return AgentText.ENDED
        return null
    }

    private val rnd = SecureRandom()

    /** 回复载荷里的随机数 n：16 字节 base64url（agent 靠它去重，回执靠它对上这条回复） */
    fun newNonce(): String = ByteArray(16).also { rnd.nextBytes(it) }.let { Base64.getUrlEncoder().withoutPadding().encodeToString(it) }

    /** 序列化后的回复载荷上限（转义后会变长；信封上限 32 KB） */
    const val MAX_REPLY_PAYLOAD = 20 shl 10

    /** 回复载荷（§11.2）：{"v":1,"re_seq","text","n","sent_at","device"}；reSeq = 被回复消息载荷里的 seq */
    fun replyPayload(reSeq: Long, text: String, n: String, sentAt: Long, device: String): String =
        JSONObject().put("v", 1).put("re_seq", reSeq).put("text", text).put("n", n).put("sent_at", sentAt).put("device", device).toString()

    /**
     * 回复一条 agent 消息 → reply_id。seq：被回复消息载荷里的 seq（写进 re_seq）；sk：本机账号私钥；device：本机名称（写进载荷，agent 看得到）。
     * 空、文字超过 16 KB、序列化后超过 20 KB、seq ≤ 0、会话证明不是当前钥匙写的：直接报错，不发请求；会话已结束（409）→ ENDED
     */
    fun reply(net: AgentNet, c: AgentCrypto, msgId: Long, seq: Long, sessionId: String, verified: AgentVerified, sk: String, text: String,
              device: String, nowSec: Long = System.currentTimeMillis() / 1000, nonce: () -> String = ::newNonce): Long {
        val t = text.trim()
        if (t.isEmpty()) throw E2EError(AgentText.EMPTY)
        if (t.toByteArray(Charsets.UTF_8).size > MAX_REPLY_BYTES) throw E2EError(AgentText.TOO_LONG)
        if (!verified.current) throw E2EError(AgentText.NO_REPLY_OLD_KEY)
        if (seq <= 0) throw E2EError(AgentText.NO_REPLY_NO_SEQ)
        val payload = replyPayload(seq, t, nonce(), nowSec, device)
        if (payload.toByteArray(Charsets.UTF_8).size > MAX_REPLY_PAYLOAD) throw E2EError(AgentText.TOO_LONG)
        val (env, copy) = c.agentReplySeal(sk, verified.pub, sessionId, msgId, payload)
        val o = try {
            net.agentReply(msgId, env, copy)
        } catch (e: ApiException) {
            if (e.status == 409) throw E2EError(AgentText.ENDED)
            throw e
        }
        return o.optLong("reply_id")
    }

    /**
     * 某条消息的回复：副本用账号私钥解开（解不开的不显示），回执用会话公钥核对——
     * 必须是 kind receipt、reply_id 和 n 都对得上这条回复，才显示「✓✓ agent 已收到」
     */
    fun replyViews(list: List<AgentReplyStatus>, sessionId: String, keys: List<String>, verified: AgentVerified?, c: AgentCrypto): List<AgentReplyView> =
        list.mapNotNull { r ->
            if (r.sessionId.isNotEmpty() && r.sessionId != sessionId) return@mapNotNull null
            val p = runCatching { c.openMessage(keys, r.copy) }.getOrNull() ?: return@mapNotNull null
            if (!p.has("text") || p.isNull("text")) return@mapNotNull null
            val text = p.optString("text")
            val n = p.optString("n").takeIf { p.has("n") && it.isNotEmpty() } ?: return@mapNotNull null
            val sentAt = if (p.has("sent_at")) p.optLong("sent_at") else null
            var state = if (r.state == "expired") AgentReplyView.State.EXPIRED else AgentReplyView.State.SENT
            var receivedAt: Long? = null
            if (r.state == "received" && verified != null && r.receipt.isNotEmpty()) {
                val rc = runCatching { c.agentOpen(keys, verified.pub, sessionId, r.receipt) }.getOrNull()
                if (rc != null && rc.optString("kind") == "receipt" && rc.has("reply_id") && rc.optLong("reply_id") == r.replyId &&
                    rc.optString("n") == n) {
                    state = AgentReplyView.State.RECEIVED
                    receivedAt = if (rc.has("received_at")) rc.optLong("received_at") else null
                }
            }
            val device = if (p.has("device") && !p.isNull("device")) p.optString("device") else r.device
            AgentReplyView(r.replyId, text, device, sentAt, state, receivedAt)
        }

    /** 读回复状态并核对（阻塞，后台线程调用） */
    fun replies(net: AgentNet, c: AgentCrypto, msgId: Long, sessionId: String, keys: List<String>, verified: AgentVerified?): List<AgentReplyView> =
        replyViews(parseReplyStatus(net.agentReplyStatus(msgId)), sessionId, keys, verified, c)
}
