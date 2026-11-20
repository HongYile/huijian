package io.github.hongyile.huijian

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.IOException

/**
 * agent 双向的全局状态（界面、同步服务共用一份，docs/agent-mcp.md §8）：会话列表、核实过的会话、Agent key、
 * 正在批准的登录请求、登录请求的系统通知、回复。逻辑在 Agent.kt（Agent / AgentApproval），和 Mac 的 AgentModel.swift 对应。
 */
object AgentHub {
    private lateinit var app: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun init(ctx: Context) { app = ctx.applicationContext }

    private val _sessions = MutableStateFlow<List<AgentSession>>(emptyList())
    val sessions: StateFlow<List<AgentSession>> = _sessions.asStateFlow()
    private val _verified = MutableStateFlow<Map<String, AgentVerified>>(emptyMap())
    /** 会话 id → 核实过的会话（名称取自会话证明） */
    val verified: StateFlow<Map<String, AgentVerified>> = _verified.asStateFlow()
    private val _keys = MutableStateFlow<List<AgentKeyInfo>?>(null)
    /** Agent key 列表；null = 还没读到 */
    val keys: StateFlow<List<AgentKeyInfo>?> = _keys.asStateFlow()
    private val _phases = MutableStateFlow<Map<String, AgentPhase>>(emptyMap())
    /** 会话 id → 批准进度（只有点过「批准」的请求） */
    val phases: StateFlow<Map<String, AgentPhase>> = _phases.asStateFlow()
    private val _loaded = MutableStateFlow(false)
    /** 这次登录里读到过会话列表 */
    val loaded: StateFlow<Boolean> = _loaded.asStateFlow()
    private val _unsupported = MutableStateFlow(false)
    /** 服务端没有 agent 功能（0.10.0 以前） */
    val unsupported: StateFlow<Boolean> = _unsupported.asStateFlow()
    private val _revision = MutableStateFlow(0)
    /** 每次刷新完加一（包括收到 kind "agent" 的变更）：打开着的消息详情重新拉回复状态，等待核对码的页面立即再查 */
    val revision: StateFlow<Int> = _revision.asStateFlow()

    private val approvals = HashMap<String, AgentApproval>()

    // ---------- 刷新 ----------

    private val lock = Any()
    private var running = false
    private var again = false

    /**
     * GET /v1/agent/sessions（阻塞，后台线程调用）：核实会话证明、推进正在进行的批准；新的登录请求通知一次；
     * 核实结果变了就重新解密 agent 消息。正在刷新时再调用：等这一轮结束后再刷一次（不并发）
     */
    fun refresh(api: Api) {
        synchronized(lock) {
            if (running) { again = true; return }
            running = true
        }
        try {
            while (true) {
                once(api)
                synchronized(lock) {
                    if (!again) { running = false; return }
                    again = false
                }
            }
        } catch (e: Throwable) {
            synchronized(lock) { running = false; again = false }
            throw e
        }
    }

    private fun once(api: Api) {
        val session = Hub.session
        val list = try {
            Agent.parseSessions(api.agentSessions())
        } catch (e: ApiException) {
            if (!e.oldServer) throw e
            if (session == Hub.session) { _unsupported.value = true; _loaded.value = true }
            return
        }
        if (session != Hub.session) return
        _unsupported.value = false
        if (list != _sessions.value) _sessions.value = list
        _loaded.value = true
        val v = Agent.verify(list, E2EHub.secretKeys(), CoreAgentCrypto)
        if (session != Hub.session) return
        val changed = v != _verified.value
        if (changed) _verified.value = v
        val current = synchronized(this) { approvals.values.toList() }
        for (a in current) {
            val ph = a.handle(list, api)
            if (live(a, session)) _phases.update { it + (a.session.id to ph) }
        }
        notifyRequests(list)
        if (changed) E2EHub.redecryptAll()
        _revision.update { it + 1 }
    }

    fun refreshAsync() {
        if (!Hub.loggedIn) return
        scope.launch { runCatching { Hub.api()?.let { refresh(it) } } }
    }

    /** 界面里调用（IO 线程，失败照常抛出） */
    suspend fun reload() = withContext(Dispatchers.IO) { refresh(Hub.api() ?: throw IOException("未登录")) }

    @Volatile private var lastKids: List<String> = emptyList()

    /** E2EHub 每次重新算状态时调用：本机钥匙变了（解锁、重置、换账号后重新登录）就重新核实会话证明 */
    fun keysMaybeChanged(kids: List<String>) {
        if (kids == lastKids) return
        lastKids = kids
        if (!_unsupported.value) refreshAsync()
    }

    /** 退出登录、换账号：停掉进行中的批准，清空状态，撤掉登录请求的通知 */
    fun wipe() {
        synchronized(this) {
            approvals.values.forEach { it.stop() }
            approvals.clear()
        }
        _sessions.value = emptyList()
        _verified.value = emptyMap()
        _keys.value = null
        _phases.value = emptyMap()
        _loaded.value = false
        _unsupported.value = false
        lastKids = emptyList()
        if (::app.isInitialized) {
            runCatching { Hub.store.agentNotified = emptyList() }
            Notifier.cancelAgentRequests(app)
        }
    }

    // ---------- 登录请求的系统通知（同一个请求只通知一次） ----------

    /** 有 agent 请求登录：通知一次。只有已解锁的设备能批准（要用账号私钥写证明），锁定的设备不提醒 */
    private fun notifyRequests(list: List<AgentSession>) {
        if (!::app.isInitialized) return
        val store = Hub.store
        val seen = store.agentNotified
        val pending = list.filter { it.pending }
        // 已经处理掉（批准、拒绝、过期）的请求：撤掉它的通知
        seen.filter { id -> pending.none { it.id == id } }.forEach { Notifier.cancelAgentRequest(app, it) }
        if (E2EHub.status.value != E2EStatus.UNLOCKED) return
        val fresh = pending.filter { it.id !in seen }
        if (fresh.isEmpty()) return
        fresh.forEach { Notifier.postAgentRequest(app, it) }
        store.agentNotified = seen + fresh.map { it.id }
    }

    // ---------- Agent key ----------

    suspend fun loadKeys() = withContext(Dispatchers.IO) {
        val api = Hub.api() ?: throw IOException("未登录")
        val session = Hub.session
        val k = Agent.parseKeys(api.agentKeys())
        if (session == Hub.session) _keys.value = k
    }

    /** 新建 Agent key：明文只返回这一次 */
    suspend fun createKey(): AgentNewKey = withContext(Dispatchers.IO) {
        val api = Hub.api() ?: throw IOException("未登录")
        val k = Agent.parseNewKey(api.agentCreateKey())
        runCatching { loadKeys() }
        k
    }

    /** 吊销：它登录的会话全部结束 */
    suspend fun revokeKey(id: Long) = withContext(Dispatchers.IO) {
        val api = Hub.api() ?: throw IOException("未登录")
        api.agentRevokeKey(id)
        runCatching { loadKeys() }
        runCatching { refresh(api) }
        Unit
    }

    // ---------- 会话与批准 ----------

    /** 结束会话：令牌作废，未取走的回复删除 */
    suspend fun endSession(id: String) = withContext(Dispatchers.IO) {
        val api = Hub.api() ?: throw IOException("未登录")
        api.agentEnd(id)
        runCatching { refresh(api) }
        Unit
    }

    /** 这个批准流程还是不是当前的（换账号、关掉、重新批准后，旧对象在路上的结果丢弃） */
    private fun live(a: AgentApproval, session: Long) = session == Hub.session && synchronized(this) { approvals[a.session.id] === a }

    private fun publish(a: AgentApproval) { _phases.update { it + (a.session.id to a.phase) } }

    /** 点「批准」：接手请求，交出自己的随机数 na；已被别的设备接手 → TAKEN */
    suspend fun beginApproval(s: AgentSession) = withContext(Dispatchers.IO) {
        val api = Hub.api() ?: throw IOException("未登录")
        val sk = E2EHub.activeSk() ?: throw E2EError(AgentText.LOCKED_APPROVE)
        val session = Hub.session
        val a = AgentApproval.begin(api, CoreAgentCrypto, s, sk)
        if (session != Hub.session) { a.stop(); return@withContext }
        synchronized(this@AgentHub) { approvals.put(s.id, a)?.stop() }
        publish(a)
        runCatching { refresh(api) }
        Unit
    }

    /** 「一致，批准」：写会话证明 */
    suspend fun approve(id: String) = withContext(Dispatchers.IO) {
        val a = synchronized(this@AgentHub) { approvals[id] } ?: throw E2EError("请重新点「批准」")
        val sk = E2EHub.activeSk() ?: throw E2EError(AgentText.LOCKED_APPROVE)
        val api = Hub.api() ?: throw IOException("未登录")
        val session = Hub.session
        try { a.approve(api, sk) } finally { if (live(a, session)) publish(a) }
        runCatching { refresh(api) }
        Unit
    }

    /** 「拒绝」/「不一致，拒绝」 */
    suspend fun deny(id: String) = withContext(Dispatchers.IO) {
        val api = Hub.api() ?: throw IOException("未登录")
        val session = Hub.session
        val a = synchronized(this@AgentHub) { approvals[id] }
        if (a != null) {
            a.stop()
            a.reject(api)
            if (live(a, session)) publish(a)
        } else api.agentDeny(id)
        runCatching { refresh(api) }
        Unit
    }

    /** 批准流程结束后「关闭」 */
    fun forgetApproval(id: String) {
        synchronized(this) { approvals.remove(id)?.stop() }
        _phases.update { it - id }
    }

    /** 请求的名称（请求已经不在列表里时显示结果用） */
    fun approvalName(id: String): String = synchronized(this) { approvals[id]?.session?.name }?.ifBlank { null } ?: "agent"

    // ---------- 回复 ----------

    /** 这条消息现在能不能回复：null = 可以；否则是原因。unlocked：本机已解锁（界面收集 E2EHub.status 传进来） */
    fun replyBlock(m: Message, unlocked: Boolean): String? =
        Agent.replyBlock(m, unlocked, _verified.value, _sessions.value, _loaded.value)

    suspend fun reply(m: Message, text: String): Long = withContext(Dispatchers.IO) {
        val api = Hub.api() ?: throw IOException("未登录")
        val sid = m.agentSession ?: throw E2EError(AgentText.NO_REPLY_UNVERIFIED)
        val v = _verified.value[sid] ?: throw E2EError(AgentText.NO_REPLY_UNVERIFIED)
        val sk = E2EHub.activeSk() ?: throw E2EError(AgentText.LOCKED_REPLY)
        Agent.reply(api, CoreAgentCrypto, m.id, sid, v, sk, text, Hub.store.deviceName)
    }

    suspend fun replies(m: Message): List<AgentReplyView> = withContext(Dispatchers.IO) {
        val api = Hub.api() ?: throw IOException("未登录")
        val sid = m.agentSession ?: return@withContext emptyList()
        Agent.replies(api, CoreAgentCrypto, m.id, sid, E2EHub.secretKeys(), _verified.value[sid])
    }
}
