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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException

/**
 * 端到端加密的全局状态（界面、同步服务共用一份）：GET /v1/e2e 的结果、本机私钥（Keystore 加密保存）、
 * 加密状态、新设备的批准请求、批准其他设备的进度、批准请求的系统通知、消息解密。
 * 协议逻辑在 E2E.kt（E2ELogic / DeviceRequest / Approval / E2EMessages）。
 */
object E2EHub {
    private lateinit var app: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun init(ctx: Context) { app = ctx.applicationContext }

    val logic: E2ELogic by lazy { E2ELogic(CoreCrypto, Hub.store.upgradeFlags, ::known) }

    /** 已登录时本机知道的情况（防降级）：登录时记下的用户名、GET /v1/e2e 的 auth_key、这次运行里有没有读到过 /v1/e2e */
    fun known(): Known {
        val st = _state.value
        return Known(Hub.store.loginUsername.ifBlank { null }, st?.authKey == true, st != null)
    }

    /** Argon2id 一次占 64 MiB：同一时间只算一份（登录、开启加密、解锁、改密码都走这里） */
    private val heavy = Mutex()

    /** 在后台线程执行加密操作（含网络请求），同一时间只执行一个 */
    suspend fun <T> work(block: () -> T): T = heavy.withLock { withContext(Dispatchers.IO) { block() } }

    private val _state = MutableStateFlow<E2EState?>(null)
    /** 最近一次 GET /v1/e2e；还没读到、服务端没有 e2e 时为 null */
    val state: StateFlow<E2EState?> = _state.asStateFlow()
    private val _status = MutableStateFlow(E2EStatus.UNKNOWN)
    val status: StateFlow<E2EStatus> = _status.asStateFlow()
    private val _vaultError = MutableStateFlow<String?>(null)
    /** Keystore 读写失败的原因（当作「未解锁」，加密页显示） */
    val vaultError: StateFlow<String?> = _vaultError.asStateFlow()
    /** 一次性的提示（登录时钥匙对不上 T43 等），加密页显示后清掉 */
    val notice = MutableStateFlow<String?>(null)

    private val _pendingRecovery = MutableStateFlow<Pair<String, Boolean>?>(null)
    /**
     * 还没点「完成」的恢复码（code, 是否刚开启加密）：放在 App 状态里，同时和私钥一起存进 Keystore 加密存储，
     * 转屏、关掉页面、App 被系统终止后都还能回到「保存恢复码」页（§4.1）。点「完成」才删除
     */
    val pendingRecovery: StateFlow<Pair<String, Boolean>?> = _pendingRecovery.asStateFlow()
    private val _setupPending = MutableStateFlow(false)
    /** 本机存着进行中的开启（服务器上还没开启）：加密页提示重试 */
    val setupPending: StateFlow<Boolean> = _setupPending.asStateFlow()
    private val _tick = MutableStateFlow(0)
    /** 每次刷新完加一（包括长轮询收到 kind "e2e" 的变更）：等待核对的页面看到它变了立即再查一次 */
    val tick: StateFlow<Int> = _tick.asStateFlow()
    @Volatile private var unsupported = false

    // ---------- 本机钥匙、钉住的公钥（§1、§4.5） ----------

    @Volatile private var cache: Store.E2EVault? = null
    /** cache 属于哪个 owner；null = 还不知道账号 id，只在内存里（登录时解开的私钥，拿到账号 id 后再保存） */
    @Volatile private var cacheOwner: String? = null
    private val EMPTY = Store.E2EVault(emptyList(), null)

    /** 规范化的服务器地址 + 账号 id；还不知道账号 id 时为 null */
    private fun owner(): String? = Hub.store.accountId.takeIf { it > 0 }?.let { canonicalServer(Hub.store.server) + "|" + it }

    /** 本机钉住的账号公钥；没有（或还不知道账号 id）时为 null */
    fun pinned(): String? = owner()?.let { Hub.store.pinnedPub(it) }

    /**
     * 本机保存的钥匙；Keystore 读不出来时返回空（当作未解锁），原因放在 vaultError，下次再试。
     * 刚知道账号 id 时：读出保存的，把只在内存里的私钥合并进去（先和钉住的公钥核对）再保存
     */
    @Synchronized
    fun vault(): Store.E2EVault {
        val o = owner()
        val c = cache
        if (c != null && cacheOwner == o) return c
        if (o == null) return c ?: EMPTY
        val stored = try {
            Hub.store.e2eLoad(o).also { _vaultError.value = null }
        } catch (e: Exception) {
            _vaultError.value = "读取本机保存的加密钥匙失败（${e.message ?: e.javaClass.simpleName}），可以重新解锁"
            return c ?: EMPTY
        }
        val memOnly = if (c != null && cacheOwner == null) c else null
        val merged = if (memOnly == null) stored else Store.E2EVault(
            stored.keys + pinCheck(o, memOnly.keys).filter { k -> stored.keys.none { it.kid == k.kid } },
            memOnly.device ?: stored.device,
            memOnly.setup ?: stored.setup,
            memOnly.recovery ?: stored.recovery,
            memOnly.rotation ?: stored.rotation,
        )
        cache = merged; cacheOwner = o
        if (merged != stored) persist(o, merged)
        mirror(merged)
        return merged
    }

    /** 把保存的「进行中的开启」「还没点完成的恢复码」同步到界面状态（App 重启后回到恢复码页） */
    private fun mirror(v: Store.E2EVault) {
        if (v.recovery != null) _pendingRecovery.value = v.recovery
        _setupPending.value = v.setup != null && _state.value?.enabled != true
    }

    /** 和钉住的公钥核对：对不上的丢弃并提示 T43；还没钉住时钉住第一把 */
    private fun pinCheck(owner: String, keys: List<LocalKey>): List<LocalKey> {
        if (keys.isEmpty()) return keys
        val pin = Hub.store.pinnedPub(owner)
        if (pin == null) { Hub.store.pin(owner, keys.first().pub); return keys }
        val ok = keys.filter { it.pub == pin }
        if (ok.size < keys.size) notice.value = E2EText.T43
        return ok
    }

    private fun persist(o: String, v: Store.E2EVault) {
        try {
            Hub.store.e2eSave(o, v)
            _vaultError.value = null
        } catch (e: Exception) {
            _vaultError.value = "加密钥匙没能保存到本机（${e.message ?: e.javaClass.simpleName}），重启后需要重新解锁"
        }
    }

    @Synchronized
    private fun saveVault(v: Store.E2EVault) {
        val o = owner()
        cache = v; cacheOwner = o        // 写盘失败（或还不知道账号 id）时这次运行里仍然可用
        if (o != null) persist(o, v)
        _setupPending.value = v.setup != null && _state.value?.enabled != true
    }

    // ---------- 进行中的开启、恢复码（§4.1） ----------

    /** 开启加密时生成了新钥匙对和恢复码（发请求之前）：先存起来 */
    @Synchronized
    fun setupGenerated(p: SetupResult) = saveVault(vault().copy(setup = p))

    /** 开启加密确认失败（4xx、确认没开启、别的设备开启了）：删除进行中的开启 */
    @Synchronized
    fun dropSetup() { vault().takeIf { it.setup != null }?.let { saveVault(it.copy(setup = null)) } }

    /** 本机存着的进行中的开启（重试时先核对它） */
    fun pendingSetup(): SetupResult? = vault().setup

    /**
     * 开启成功（本机发起的请求成功、或刷新状态时发现 active 公钥就是这把）：恢复码先存好、放进 App 状态，再保存私钥并钉住公钥。
     * 已经完成过（刷新和开启页同时发现）时什么都不做。钉住的公钥对不上时丢弃（T43）
     */
    fun finishSetup(p: SetupResult, st: E2EState? = null) {
        synchronized(this) {
            val v = vault()
            if (v.setup?.key?.pub != p.key.pub) return
            val o = owner()
            val pin = o?.let { Hub.store.pinnedPub(it) }
            if (pin != null && pin != p.key.pub) { notice.value = E2EText.T43; saveVault(v.copy(setup = null)); return }
            if (o != null && pin == null) Hub.store.pin(o, p.key.pub)
            val r = p.recoveryCode to true
            saveVault(v.copy(keys = v.keys.filter { it.kid != p.key.kid } + p.key, setup = null, recovery = r))
            _pendingRecovery.value = r
        }
        st?.let { _state.value = it }
        recompute()
        redecryptAll()
    }

    /** 本机正在发更换恢复码的请求：这期间刷新看到 recovery_wrap 不同不算失败（请求可能还没到） */
    @Volatile private var rotating = false

    /** 更换恢复码：新恢复码在发请求之前就存好（§7 第 3 项） */
    @Synchronized
    fun rotationGenerated(rot: RecoveryRotation) { rotating = true; saveVault(vault().copy(rotation = rot)) }

    /** 更换恢复码确认失败（4xx、确认没换成）：删除这一次的（null = 还没生成就失败了，不动之前保留的） */
    @Synchronized
    fun dropRotation(rot: RecoveryRotation?) {
        rotating = false
        if (rot == null) return
        vault().takeIf { it.rotation == rot }?.let { saveVault(it.copy(rotation = null)) }
    }

    /** 本机发起的请求结果不明：保留，等刷新时核对 */
    fun rotationUnsure() { rotating = false }

    /**
     * 更换恢复码成功（本机请求成功、或刷新时 recovery_wrap 等于这次上传的）：新恢复码放进「还没点完成」的恢复码，
     * 显示恢复码页。已经处理过时什么都不做
     */
    @Synchronized
    fun finishRotation(rot: RecoveryRotation) {
        rotating = false
        val v = vault()
        if (v.rotation != rot) return
        val r = rot.code to false
        saveVault(v.copy(rotation = null, recovery = r))
        _pendingRecovery.value = r
    }

    /** 恢复码页点「完成」：删除保存的恢复码 */
    @Synchronized
    fun recoveryDone() {
        _pendingRecovery.value = null
        vault().takeIf { it.recovery != null }?.let { saveVault(it.copy(recovery = null)) }
    }

    /** 本账号全部私钥（解密消息用） */
    fun secretKeys(): List<String> = vault().keys.map { it.sk }

    /** 本机的账号私钥：钉住的那把；没钉住时取对应服务器 active 公钥的那把 */
    private fun accountKey(): LocalKey? {
        val keys = vault().keys
        pinned()?.let { pin -> return keys.firstOrNull { it.pub == pin } }
        val pub = _state.value?.activeKey?.pub ?: return null
        return keys.firstOrNull { it.pub == pub }
    }

    /** 账号私钥（批准其他设备、改密码、换恢复码用）；锁定时为 null */
    fun activeSk(): String? = if (_status.value == E2EStatus.UNLOCKED) accountKey()?.sk else null

    private fun recompute() {
        _status.value = if (unsupported) E2EStatus.UNSUPPORTED else logic.status(_state.value, vault().keys, pinned())
        healLocked()
    }

    /**
     * 已解锁，却还有停在「解锁后查看」的消息（同步服务合并时恰好没读到钥匙、Keystore 偶发失败等）：重新解密。
     * 每次算完状态、同步服务合并新消息之后、App 启动时都检查一次
     */
    fun healLocked() {
        if (_status.value != E2EStatus.UNLOCKED) return
        if (Hub.messages.value.none { it.e2eStatus == E2EMessages.LOCKED }) return
        redecryptAll()
    }

    /** App 启动时（Hub.init 读完本地消息之后）：本机有保存的私钥就把锁着的消息解一遍（读 Keystore 放后台） */
    fun onStart() {
        // 读一次保存的钥匙：没点「完成」的恢复码回到 App 状态，打开 App 就回到「保存恢复码」页
        if (Hub.loggedIn) scope.launch { runCatching { vault() } }
        if (Hub.messages.value.none { it.e2eStatus == E2EMessages.LOCKED }) return
        redecryptAll()
    }

    /**
     * 当前账号的 id（本机私钥、钉住的公钥按它记）：不知道时用 /v1/me 取；顺带更新用户名。
     * 配对码登录的设备本地没有登录用户名：用这时 /v1/me 的用户名补上（之后不再随服务器变）
     */
    fun ensureAccount(api: Api): Long {
        val known = Hub.store.accountId
        if (known > 0) return known
        val a = api.me().optJSONObject("account") ?: return 0
        val id = a.optLong("id")
        if (id > 0) {
            a.optString("username").takeIf { it.isNotBlank() }?.let {
                Hub.store.username = it
                if (Hub.store.loginUsername.isBlank()) Hub.store.loginUsername = it
            }
            Hub.store.accountId = id
        }
        return id
    }

    /**
     * 保存一把核对过的私钥（§4.5 的服务器 keys 核对已在 E2ELogic.verify 里做过），再和钉住的公钥核对（对不上 → T43，不保存）；
     * 还没钉住时钉住它。重新计算状态，并把还没解开的消息重新解密。返回是否保存了
     */
    fun adopt(key: LocalKey, st: E2EState? = null, dropDevice: Boolean = false): Boolean {
        synchronized(this) {
            val v = vault()
            val o = owner()
            if (o != null) {
                val pin = Hub.store.pinnedPub(o)
                if (pin != null && pin != key.pub) { notice.value = E2EText.T43; return false }
                if (pin == null) Hub.store.pin(o, key.pub)
            }
            saveVault(v.copy(keys = v.keys.filter { it.kid != key.kid } + key, device = if (dropDevice) null else v.device))
        }
        st?.let { _state.value = it }
        recompute()
        redecryptAll()
        return true
    }

    /**
     * 用账号密码登录成功后（在 Hub.signedIn 之后、后台线程调用）：先取账号 id，再保存顺带解开的私钥。
     * /v1/me 失败时私钥留在内存里，下次刷新拿到账号 id 后保存，不会丢
     */
    fun afterLogin(o: LoginOutcome, api: Api?) {
        if (api != null) runCatching { ensureAccount(api) }
        o.keys.forEach { adopt(it) }
        if (o.notice != null) notice.value = o.notice
    }

    /** 界面拿到新状态（开启加密、解锁、改设置之后） */
    fun setState(st: E2EState) {
        _state.value = st
        unsupported = false
        recompute()
        pruneApprovals(st)
        _tick.update { it + 1 }
    }

    /**
     * 退出登录、换账号、换服务器、设备被移除（§8）：先停掉进行中的批准流程（请求批准、批准其他设备），
     * 再删除本机的全部私钥、设备钥匙对、进行中的开启和没点「完成」的恢复码，清空状态（「已升级」标记、钉住的公钥不删）。
     * 停掉的流程正在路上的结果一律作废（DeviceRequest.abandon、approvals 换了对象、会话编号变了）。
     * keepVault：登录失效后重新登录（同一台设备），只清内存里的状态，保存的私钥留着
     */
    fun wipe(keepVault: Boolean = false) {
        synchronized(this) {
            request?.abandon()
            request = null
            approvals.clear()
            cache = null
            cacheOwner = null
            if (!keepVault) runCatching { Hub.store.e2eClear() }
        }
        _requestStep.value = null
        _approvalStages.value = emptyMap()
        _pendingRecovery.value = null
        _setupPending.value = false
        _state.value = null
        unsupported = false
        _status.value = E2EStatus.UNKNOWN
        _vaultError.value = null
        notice.value = null
        if (::app.isInitialized) Notifier.cancelE2ERequests(app)
    }

    // ---------- 刷新（§3） ----------

    /**
     * GET /v1/e2e（阻塞，后台线程调用）。有进行中的批准请求时由它推进（读状态和登记公钥串行，不会误判）；
     * 锁定时看有没有转交给本机的钥匙；给新的批准请求发系统通知。服务端没有 e2e 时返回 null。
     */
    fun refresh(api: Api): E2EState? {
        val session = Hub.session
        // 还不知道账号 id（刚登录、/v1/me 失败过）：先取；拿到后 vault() 会把只在内存里的私钥保存下来
        try { ensureAccount(api) } catch (e: UnauthorizedException) { throw e } catch (_: Exception) {}
        val st = try {
            val req = request
            if (req != null && req.active) {
                val (step, s) = req.step(api)
                onRequestStep(req, step, session)
                s
            } else E2EState.parse(api.e2eState())
        } catch (e: ApiException) {
            if (!e.oldServer) throw e
            if (session == Hub.session) { unsupported = true; _state.value = null; recompute() }
            return null
        } catch (e: E2EError) {
            // 重新开始时账号公钥对不上（T43）等：这次请求结束，等待页显示原因和「重新请求」
            val r = request
            if (r != null && !r.active) { request = null; _requestStep.value = DeviceRequest.Step.Failed(e.message ?: E2EText.T43) }
            throw e
        }
        if (session != Hub.session) return null
        unsupported = false
        _state.value = st
        // 账号已经用新方式登录（配对码登录的设备也一样）：补记「已升级」标记（登录时记下的用户名和 /v1/me 的用户名），
        // 加强之后在这台设备上用密码登录时的防降级
        if (st.authKey) listOf(Hub.store.loginUsername, Hub.store.username).filter { it.isNotBlank() }.distinct()
            .forEach { Hub.store.upgradeFlags.markUpgraded(Hub.store.server, it) }
        // 进行中的开启（§4.1）：每次刷新都核对，不等用户再点「开启」（开启成功后那个按钮就不显示了）
        vault().setup?.let { p ->
            when (logic.pendingSetup(st, p)) {
                E2ELogic.PendingSetup.COMPLETE -> {
                    listOf(Hub.store.loginUsername, Hub.store.username).filter { it.isNotBlank() }.distinct()
                        .forEach { Hub.store.upgradeFlags.markUpgraded(Hub.store.server, it) }
                    finishSetup(p)
                }
                E2ELogic.PendingSetup.DROP -> dropSetup()
                E2ELogic.PendingSetup.KEEP -> {}
            }
        }
        // 进行中的更换恢复码（§7 第 3 项）：recovery_wrap 就是这次上传的 → 成功，显示新恢复码；
        // 不是、而且本机没有请求在路上 → 没换成，删除（旧恢复码仍然有效）
        vault().rotation?.let { rot ->
            if (logic.rotationDone(st, rot)) finishRotation(rot) else if (!rotating) dropRotation(rot)
        }
        recompute()
        _setupPending.value = vault().setup != null && !st.enabled
        // §4.5 末尾：本机有私钥、却还没钉住公钥（钉住功能之前保存的等）：用私钥重新算出公钥，是 active 的就补钉
        if (_status.value == E2EStatus.UNLOCKED && pinned() == null) owner()?.let { o ->
            accountKey()?.let { k ->
                runCatching { logic.verify(k.sk, st.keys, null) }.getOrNull()?.let { Hub.store.pin(o, it.pub) }
            }
        }
        pruneApprovals(st)
        notifyRequests(st)
        _tick.update { it + 1 }
        return st
    }

    fun refreshAsync() {
        if (!Hub.loggedIn) return
        scope.launch { runCatching { Hub.api()?.let { refresh(it) } } }
    }

    // ---------- 新设备：请另一台设备批准（§4.3） ----------

    @Volatile private var request: DeviceRequest? = null
    private val _requestStep = MutableStateFlow<DeviceRequest.Step?>(null)
    /** 批准请求的进度；null = 没有发起 */
    val requestStep: StateFlow<DeviceRequest.Step?> = _requestStep.asStateFlow()

    /** 只处理当前这个请求对象、当前会话的结果：换账号、重新发起之后，旧请求在路上的结果直接丢弃 */
    private fun onRequestStep(req: DeviceRequest, step: DeviceRequest.Step, session: Long) {
        if (request !== req || session != Hub.session) return
        _requestStep.value = step
        if (step is DeviceRequest.Step.Unlocked) {
            request = null
            // 和钉住的公钥对不上：这次请求结束，不显示「已解锁」，显示 T43 和「重新请求」
            if (!adopt(step.key, step.state, dropDevice = true)) _requestStep.value = DeviceRequest.Step.Failed(E2EText.T43)
        } else if (step is DeviceRequest.Step.Failed || step is DeviceRequest.Step.Denied) {
            request = null
        }
    }

    /**
     * 第 1–2 步：每次都生成新的设备钥匙对（服务器上转交给旧公钥的副本随之作废，App 重启后也从第 1 步重来，
     * 不会收下没有走完核对的转交），新的 nb，请求批准。账号公钥对不上（T43）等失败时停在 Failed
     */
    suspend fun startRequest() = withContext(Dispatchers.IO) {
        val session = Hub.session
        val api = Hub.api() ?: throw IOException("未登录")
        val dev = synchronized(this@E2EHub) {
            CoreCrypto.keypair().also { saveVault(vault().copy(device = it)) }
        }
        val r = DeviceRequest(CoreCrypto, logic, dev, pinned())
        // 换掉之前的请求对象：它在路上的结果作废
        synchronized(this@E2EHub) { request?.abandon(); request = r }
        try {
            r.start(api)
        } catch (e: E2EError) {
            if (request === r) { request = null; _requestStep.value = DeviceRequest.Step.Failed(e.message ?: E2EText.T43) }
            throw e
        } catch (e: Exception) {
            if (request === r) request = null
            throw e
        }
        // 发起期间换了账号、退出登录、又发起了一次：这个请求作废
        if (request !== r || session != Hub.session) { r.abandon(); return@withContext }
        _requestStep.value = DeviceRequest.Step.Waiting
        refresh(api)
    }

    /** 第 3 步：等待页每 3 秒（以及收到 e2e 变更时）调用 */
    suspend fun pollRequest() = withContext(Dispatchers.IO) { Hub.api()?.let { refresh(it) } }

    /**
     * 第 4 步：取消。先告诉服务器，成功后才清掉本机的请求；失败时抛出（页面提示原因，可以再点「取消」重试），
     * 否则服务器上的请求还在，其他设备会继续弹批准通知
     */
    suspend fun cancelRequest() = withContext(Dispatchers.IO) {
        val r = request
        if (r != null) {
            val api = Hub.api() ?: throw IOException("未登录")
            r.cancel(api)
        }
        if (request === r) { request = null; _requestStep.value = null }
    }

    /** 被拒绝、失败后关掉提示 */
    fun clearRequest() { if (request?.active != true) { request = null; _requestStep.value = null } }

    // ---------- 已解锁设备：批准其他设备（§5） ----------

    private val approvals = HashMap<String, Approval>()
    private val _approvalStages = MutableStateFlow<Map<String, Approval.Stage>>(emptyMap())
    /** device_id → 批准进度（只有点过「批准」的请求） */
    val approvalStages: StateFlow<Map<String, Approval.Stage>> = _approvalStages.asStateFlow()

    private fun publish(a: Approval) { _approvalStages.update { it + (a.deviceId to a.stage) } }

    /** 点「批准」：接手请求，交出自己的随机数 na；409 → T51 */
    suspend fun beginApproval(r: E2ERequest) = withContext(Dispatchers.IO) {
        val api = Hub.api() ?: throw IOException("未登录")
        // 用本机私钥算出的账号公钥核对承诺、计算核对码，不用服务器给的 keys（§5 第 3 步）
        val sk = activeSk() ?: throw E2EError("本机还没有解锁，不能批准其他设备")
        val a = Approval(CoreCrypto, r.deviceId, r.name, CoreCrypto.publicKey(sk).first)
        val session = Hub.session
        synchronized(this@E2EHub) { approvals[r.deviceId] = a }
        try { a.begin(api) } finally { if (live(a, session)) publish(a) }
        stepApproval(r.deviceId)
    }

    /** 这个批准流程还是不是当前的（换账号、取消、重新批准后，旧对象在路上的结果丢弃） */
    private fun live(a: Approval, session: Long) = session == Hub.session && synchronized(this) { approvals[a.deviceId] === a }

    /** 等对方揭晓：每 3 秒（以及收到 e2e 变更时）调用 */
    suspend fun stepApproval(deviceId: String) = withContext(Dispatchers.IO) {
        val session = Hub.session
        val a = synchronized(this@E2EHub) { approvals[deviceId] } ?: return@withContext
        val api = Hub.api() ?: return@withContext
        val (stage, st) = a.step(api)
        if (!live(a, session)) return@withContext
        publish(a)
        // 失败（核对不一致 T52、被别的设备接手 T51、对方取消）：请求随后会从列表里消失，原因放到页面顶部的提示里
        if (stage is Approval.Stage.Failed) notice.value = stage.message
        setState(st)
    }

    /** 「一致，批准」 */
    suspend fun approve(deviceId: String) = withContext(Dispatchers.IO) {
        val a = synchronized(this@E2EHub) { approvals[deviceId] } ?: throw E2EError("请重新点「批准」")
        val sk = activeSk() ?: throw E2EError("本机还没有解锁，不能批准其他设备")
        val api = Hub.api() ?: throw IOException("未登录")
        val session = Hub.session
        try { a.approve(api, sk) } finally { if (live(a, session)) publish(a) }
        runCatching { refresh(api) }
    }

    /** 「不一致，拒绝」/ 直接「拒绝」 */
    suspend fun deny(deviceId: String) = withContext(Dispatchers.IO) {
        val api = Hub.api() ?: throw IOException("未登录")
        val session = Hub.session
        val a = synchronized(this@E2EHub) { approvals[deviceId] }
        if (a != null) { a.reject(api); if (live(a, session)) publish(a) } else api.e2eDeny(deviceId)
        runCatching { refresh(api) }
    }

    /** 请求已经不在列表里（批准完、被拒绝、对方取消）：去掉它的批准进度，同一台设备以后再请求时从头开始 */
    private fun pruneApprovals(st: E2EState) {
        val live = st.requests.mapTo(HashSet()) { it.deviceId }
        val gone = synchronized(this) { approvals.keys.filter { it !in live }.onEach { approvals.remove(it) } }
        if (gone.isNotEmpty()) _approvalStages.update { it - gone.toSet() }
    }

    /** 批准流程结束后关掉；等对方揭晓期间点「取消」：只停止本机的等待，不发请求（§5 第 2 步） */
    fun dismissApproval(deviceId: String) {
        synchronized(this) { approvals.remove(deviceId) }
        _approvalStages.update { it - deviceId }
    }

    // ---------- 批准请求的系统通知（T50，同一个请求只通知一次） ----------

    private fun notifyRequests(st: E2EState) {
        if (!::app.isInitialized || _status.value != E2EStatus.UNLOCKED) return
        val store = Hub.store
        val seen = store.e2eNotified
        val current = st.requests.associateBy { "${it.deviceId}@${it.requestedAt}" }
        for ((k, r) in current) if (k !in seen) Notifier.postE2ERequest(app, r)
        // 已经处理掉（批准、拒绝、取消）的请求：撤掉它的通知
        val gone = seen.filter { it !in current }.map { it.substringBefore('@') }.filter { id -> current.values.none { it.deviceId == id } }
        gone.forEach { Notifier.cancelE2ERequest(app, it) }
        if (seen != current.keys) store.e2eNotified = current.keys
    }

    // ---------- 收消息（§6） ----------

    /** 解开还没解开的加密消息（同步服务合并之前调用，后台线程）；明文消息原样返回 */
    fun decrypt(list: List<Message>): List<Message> {
        if (list.none { it.sealed }) return list
        val keys = secretKeys()
        return list.map { if (it.sealed) E2EMessages.open(it, keys, CoreCrypto) else it }
    }

    private val redecrypting = Mutex()

    /**
     * 解锁后（或换了钥匙）把所有还没解开的消息重新解密一遍。只替换解密得到的字段（Hub.applyDecrypted），
     * 期间同步来的归档等状态不会被旧快照覆盖
     */
    fun redecryptAll() {
        scope.launch(Dispatchers.IO) {
            redecrypting.withLock {
                val session = Hub.session
                val keys = secretKeys()
                if (keys.isEmpty()) return@withLock
                val pending = Hub.messages.value.filter { it.sealed }
                if (pending.isEmpty()) return@withLock
                // 解开的换成内容；仍解不开的也更新说明（例如从「解锁后查看」变成「用别的钥匙加密」）
                val opened = pending.map { E2EMessages.open(it, keys, CoreCrypto) }
                Hub.applyDecrypted(opened.associateBy { it.id }, session)
            }
        }
    }

    /** 解密附件（§6.4）：失败时核心库不留半成品 */
    fun decryptFile(key: String, src: File, dst: File) = CoreCrypto.decryptFile(key, src, dst)

    /** 加密发送密钥（§7 第 1 项）：只用钉住的公钥；没钉住显示 T73，和服务器的不同显示 T43。账号没开启加密时为 null */
    fun sendKey(pushkey: String): SendKey? = logic.sendKey(pushkey, _state.value, pinned())
}
