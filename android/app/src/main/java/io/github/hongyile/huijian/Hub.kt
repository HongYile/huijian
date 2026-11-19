package io.github.hongyile.huijian

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class ChannelSetting(val topic: String, val alias: String, val hidden: Boolean, val muted: Boolean, val pinned: Boolean, val sort: Int)

/** 连接状态，界面和常驻通知都显示它 */
sealed interface ConnState {
    data object LoggedOut : ConnState
    data object Connecting : ConnState
    data object Connected : ConnState
    data class Waiting(val nextCheckAt: Long) : ConnState      // 定时检查模式：两次检查之间
    data class Reconnecting(val reason: String, val retryAt: Long) : ConnState
    data object Unauthorized : ConnState
}

/**
 * 全局状态：消息列表、已读集合、连接状态。界面（Compose 收集 StateFlow）和 SyncService 共用这一份。
 */
object Hub {
    lateinit var store: Store
    private lateinit var app: Context
        private set
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var saveJob: Job? = null
    /** 消息或已读每变一次加一；写盘时只写比上次更新的快照 */
    private var version = 0L
    private val writer = VersionedWriter()

    private val _messages = MutableStateFlow<List<Message>>(emptyList())
    val messages: StateFlow<List<Message>> = _messages.asStateFlow()
    private val _read = MutableStateFlow<Set<Long>>(emptySet())
    val read: StateFlow<Set<Long>> = _read.asStateFlow()
    private val _state = MutableStateFlow<ConnState>(ConnState.LoggedOut)
    val state: StateFlow<ConnState> = _state.asStateFlow()
    private val _lastContact = MutableStateFlow(0L)
    val lastContact: StateFlow<Long> = _lastContact.asStateFlow()

    /** pushkey 有变化（变更流里的 keys）：打开着的 Pushkey 页看到它变了就重新加载 */
    private val _keysTick = MutableStateFlow(0)
    val keysTick: StateFlow<Int> = _keysTick.asStateFlow()
    fun keysChanged() { _keysTick.update { it + 1 } }

    /** 同步服务按变更流（devices / account）拉到的最新账户信息，打开着的账户页直接显示它 */
    private val _account = MutableStateFlow<AccountDetail?>(null)
    val account: StateFlow<AccountDetail?> = _account.asStateFlow()
    fun setAccount(d: AccountDetail, session: Long) {
        inSession(session) {
            _account.value = d
            noteAccount(d)
        }
    }

    /** 用账户信息更新本地记的用户名和本机名（本机在别的设备上被改名时跟着变：设置页、测试推送里显示的本机名） */
    fun noteAccount(d: AccountDetail) {
        d.account.username.takeIf { it.isNotBlank() }?.let { store.username = it }
        d.devices.firstOrNull { it.current && !it.revoked }?.name?.takeIf { it.isNotBlank() && it != store.deviceName }
            ?.let { store.deviceName = it }
    }

    private val _channels = MutableStateFlow<Map<String, ChannelSetting>>(emptyMap())
    val channels: StateFlow<Map<String, ChannelSetting>> = _channels.asStateFlow()

    fun setChannels(list: List<ChannelSetting>, session: Long) { inSession(session) { _channels.value = list.associateBy { it.topic } } }
    /** 频道显示名（在 Mac 端右键「重命名」设置，所有设备共用） */
    fun channelName(topic: String) = _channels.value[topic]?.alias?.takeIf { it.isNotBlank() } ?: topic
    fun isHidden(topic: String) = _channels.value[topic]?.hidden == true

    /** 频道管理页改了设置后立即更新本地（不等下次同步） */
    fun putChannel(c: ChannelSetting) { _channels.update { it + (c.topic to c) } }

    /** 手动排序后更新本地：order 里的按 1、2、3… 编号，其余清零；空列表 = 恢复按最近活跃 */
    fun setChannelOrderLocal(order: List<String>) {
        _channels.update { cur ->
            val next = cur.mapValues { it.value.copy(sort = 0) }.toMutableMap()
            order.forEachIndexed { i, t -> next[t] = (next[t] ?: ChannelSetting(t, "", false, false, false, 0)).copy(sort = i + 1) }
            next
        }
    }

    /**
     * 消息在别处被删除（其他设备、管理网页、本机删频道）：从列表、已读里去掉，返回真正删掉的消息。
     * 锁外收尾：只撤这些消息各自的通知（不动汇总）、清下载状态，附件文件放到 IO 线程删
     */
    fun removeMessages(ids: Set<Long>, session: Long): List<Message> {
        val gone = synchronized(this) {
            if (ids.isEmpty() || session != this.session) return emptyList()
            val g = _messages.value.filter { it.id in ids }
            if (g.isEmpty()) return emptyList()
            _messages.value = _messages.value.filter { it.id !in ids }
            _read.update { it - ids }
            version++
            scheduleSave()
            g
        }
        Notifier.cancelRemoved(app, gone.map { it.id })
        val atts = gone.flatMap { m -> m.attachments.map { it.id } }
        if (atts.isNotEmpty()) {
            AttDownloads.forget(atts)
            scope.launch { store.deleteAttachmentFiles(atts) }
        }
        return gone
    }

    /** 按服务端改归档状态（id → 0/1/2）；返回是否有变化 */
    @Synchronized
    fun applyArchive(states: Map<Long, Int>, session: Long): Boolean {
        if (states.isEmpty() || session != this.session) return false
        var changed = false
        val next = _messages.value.map { m -> states[m.id]?.takeIf { it != m.archive }?.let { changed = true; m.copy(archive = it) } ?: m }
        if (!changed) return false
        _messages.value = next
        version++
        scheduleSave()
        return true
    }

    /** 删除频道后：本地去掉这个频道的消息（和同步删除走同一套清理）和设置 */
    fun removeTopic(topic: String) {
        removeMessages(_messages.value.filter { it.topic == topic }.mapTo(HashSet()) { it.id }, session)
        _channels.update { it - topic }
    }

    fun init(ctx: Context) {
        if (::store.isInitialized) return
        app = ctx.applicationContext
        store = Store(app)
        val s = store.load()
        _messages.value = s.messages.sortedBy { it.id }
        _read.value = s.read
        _lastContact.value = store.lastContact
        _state.value = if (store.hasToken) ConnState.Connecting else ConnState.LoggedOut
        trimAttachments()      // 进程启动时检查一次附件缓存（以前的版本没有上限）
    }

    /**
     * 登录会话编号：每次登录、退出都加一。同步服务启动时记下它，之后的结果（合并消息、改连接状态、保存）
     * 都先核对编号，退出登录或换账号后，还在路上的旧请求结果直接作废。
     */
    @Volatile var session = 0L
        private set

    /** 有登录凭证（即使 Keystore 暂时解不开，也不算退出登录，同步服务会退避重试并在界面显示原因） */
    val loggedIn get() = store.hasToken
    val maxId get() = _messages.value.lastOrNull()?.id

    fun api(): Api? = store.token?.let { Api(store.server, it) }

    fun setState(s: ConnState) { _state.value = s }
    fun setState(s: ConnState, session: Long) { synchronized(this) { if (session == this.session) _state.value = s } }

    fun touchContact() {
        val now = System.currentTimeMillis()
        _lastContact.value = now
        store.lastContact = now
    }

    /** 合并新消息，返回真正新增的（按 id 去重）；会话已变（退出 / 换账号）时什么都不做 */
    @Synchronized
    fun merge(incoming: List<Message>, session: Long): List<Message> {
        if (session != this.session || incoming.isEmpty()) return emptyList()
        val have = _messages.value.mapTo(HashSet()) { it.id }
        val fresh = incoming.filter { it.id !in have }
        if (fresh.isEmpty()) return emptyList()
        val all = (_messages.value + fresh).sortedBy { it.id }
        _messages.value = all.takeLast(Store.MAX_KEEP)
        version++
        scheduleSave()
        // 超过 3000 条被淘汰的旧消息：顺带删掉它们已下载的附件（同一附件还被留下的消息引用时不删）
        if (all.size > Store.MAX_KEEP) {
            val kept = _messages.value.flatMapTo(HashSet()) { m -> m.attachments.map { it.id } }
            val dropped = all.dropLast(Store.MAX_KEEP).flatMap { m -> m.attachments.map { it.id } }.filter { it !in kept }
            if (dropped.isNotEmpty()) scope.launch { store.deleteAttachmentFiles(dropped); AttDownloads.forget(dropped) }
        }
        return fresh
    }

    @Synchronized
    fun markRead(ids: Collection<Long>) {
        if (ids.all { it in _read.value }) return
        _read.update { it + ids }
        version++
        scheduleSave()
    }

    @Synchronized
    fun markRead(ids: Collection<Long>, session: Long) { if (session == this.session) markRead(ids) }

    /** 会话没变时才执行（同步服务写游标等），返回是否执行了 */
    @Synchronized
    fun inSession(session: Long, block: () -> Unit): Boolean {
        if (session != this.session) return false
        block()
        return true
    }

    fun markAllRead() = markRead(_messages.value.map { it.id })

    fun unreadCount(): Int = _messages.value.count { it.id !in _read.value && it.priority >= 2 }

    /** 登录成功。换了服务器或账号（设备记录不同）时清掉旧消息和游标，不会混在一起 */
    @Synchronized
    fun signedIn(server: String, r: LoginResult, username: String) {
        session++
        if (store.server != server || store.deviceId != r.deviceId) resetLocal()
        store.server = server
        store.token = r.token
        store.deviceId = r.deviceId
        store.deviceName = r.name
        store.username = username
        // 状态由调用方在主线程切换（切换后登录页离开界面，它的协程会被取消）
    }

    /** 界面上的「退出登录」：先停同步服务，再在后台清数据（写盘、Keystore 不放主线程），最后通知服务器 */
    fun logout(ctx: Context, notifyServer: Boolean) {
        val api = if (notifyServer) api() else null
        SyncService.stop(ctx)
        scope.launch {
            signedOut()
            Notifier.cancelAll(ctx)
            runCatching { api?.logout() }
        }
    }

    /** 退出登录：清除凭证和本地消息。调用前先停掉同步服务 */
    @Synchronized
    fun signedOut() {
        session++
        store.token = null
        resetLocal()
        _state.value = ConnState.LoggedOut
    }

    /** 附件缓存超过上限时删最旧的（每次下载完成后检查；并发的检查合并成一次） */
    fun trimAttachments() {
        synchronized(trimLock) {
            if (trimRunning) { trimAgain = true; return }      // 正在清理：结束后再查一次，不漏掉这期间新下载的
            trimRunning = true
        }
        scope.launch {
            while (true) {
                val gone = runCatching { store.trimAttachmentCache(ATT_CACHE_MAX) { AttDownloads.isDownloading(it) } }.getOrDefault(emptyList())
                if (gone.isNotEmpty()) AttDownloads.forget(gone)
                synchronized(trimLock) {
                    if (!trimAgain) { trimRunning = false; return@launch }
                    trimAgain = false
                }
            }
        }
    }
    private val trimLock = Any()
    private var trimRunning = false
    private var trimAgain = false
    private const val ATT_CACHE_MAX = 300L * 1024 * 1024

    private fun resetLocal() {
        saveJob?.cancel()
        writer.clear { store.clearMessages() }     // 等正在进行的写盘结束再删，避免删完又被写回来
        AttDownloads.reset()
        _messages.value = emptyList()
        _read.value = emptySet()
        _channels.value = emptyMap()
        _account.value = null
        version++
    }

    private class Snapshot(val messages: List<Message>, val read: Set<Long>, val version: Long, val session: Long)

    @Synchronized
    private fun snapshot() = Snapshot(_messages.value, _read.value, version, session)

    /** 立即写盘（同步服务在推进游标之前调用）。锁内取快照、锁外写文件，不阻塞界面线程 */
    fun saveNow() = write(snapshot())

    private fun write(s: Snapshot) {
        writer.write(s.version, valid = { s.session == session }) { store.save(s.messages, s.read) }
    }

    @Synchronized
    private fun scheduleSave() {
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(800)
            write(snapshot())
        }
    }
}
