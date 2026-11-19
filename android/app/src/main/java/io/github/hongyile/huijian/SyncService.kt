package io.github.hongyile.huijian

import android.app.AlarmManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.IOException
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resume

/**
 * 常驻前台服务（foregroundServiceType=specialUse）：和回笺服务器保持长轮询。
 *
 * 设计依据见 claude_test/android-research/报告.md（参考 ntfy / Gotify 的做法）：
 * - 实时模式：GET /v1/messages?wait=N 一直循环，有消息立即返回；N 按所在网络自适应（Heartbeat.kt，服务端 0.6.4 起最多 10 分钟，
 *   旧服务端固定 50 秒），等得越久，手机网络被唤醒的次数越少；
 * - 定时模式：每 N 分钟用闹钟唤醒一次，发一个 wait=0 的短请求，平时不保持连接；
 * - 重连等待、定时间隔、看门狗都用 AllowWhileIdle 闹钟（Doze 中也会触发；普通闹钟会被推迟到维护窗口）。
 *   能用精确闹钟（加入了电池优化白名单，或 12 以下）时用精确的，否则用不精确的；
 * - 闹钟回调里先拿 WakeLock（带超时，自动释放），保证请求发出去、响应处理完之前 CPU 不会又睡下；
 * - 每轮长轮询另设一个「到点」闹钟（wait+25 秒）：手机睡眠时 OkHttp 的读超时会暂停，NAT 静默断开要靠它发现，发现后立即重连并把等待时长调低；
 * - 看门狗每 10 分钟检查一次：长轮询超过 wait+60 秒没返回就强制重连；
 *   等待超过预定时间没醒就强制唤醒；循环卡住（既没在等待也没在请求）就重启循环；
 * - 网络切换（Wi-Fi ↔ 流量、断网后恢复）时取消当前请求立即重连；
 * - 同一时间只有一个同步循环：重启时新循环先等旧循环彻底退出。
 */
class SyncService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var loop: Job? = null
    private lateinit var alarms: AlarmManager
    private lateinit var wakeLock: PowerManager.WakeLock
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var api: Api? = null
    @Volatile private var destroyed = false
    /** 正在请求服务器的开始时间（elapsedRealtime），0 表示没有请求 */
    @Volatile private var busySince = 0L
    /** 循环最近一次前进的时间，看门狗用它判断循环是否卡住 */
    @Volatile private var lastStep = 0L
    /** 当前这一次等待，唤醒时原子地取走，不会重复 resume */
    private val sleeping = AtomicReference<Sleep?>(null)
    /** 主动取消了当前请求（网络切换 / 看门狗），出错后不退避、立即重连 */
    @Volatile private var kicked = false
    private var lastNetwork: Network? = null
    private var networkSeen = false
    @Volatile private var lastNoticeText = ""
    /** 对账失败后，下一次重试的时间（elapsedRealtime）；失败不影响收消息 */
    @Volatile private var reconcileRetryAt = 0L
    /** 服务端没有 /v1/messages/state（0.5.4 以前）：这次运行不再带 changes_since */
    @Volatile private var changesUnsupported = false
    /** 自适应长轮询等待时长 */
    private lateinit var heartbeat: Heartbeat
    /** 当前这一轮长轮询的等待秒数、真正发出长轮询请求的时间（elapsedRealtime，0 表示不在长轮询） */
    @Volatile private var curWait = Heartbeat.LEGACY_WAIT
    @Volatile private var longSince = 0L
    /** 这次主动取消是因为长轮询到点没响应（算作断开，要调低等待时长）；网络切换引起的取消不算 */
    @Volatile private var kickIsFailure = false
    /** 网络代数：每次网络可用 / 丢失都加一。长轮询失败时代数变了，说明是换网络或断网，不算这条网络的断开 */
    @Volatile private var netGen = 0
    /** 上次读取服务端 long_poll_max 的时间（elapsedRealtime） */
    private var infoAt = 0L
    /** 上次读取 /v1/info 时的服务端版本：响应头里的版本变了（服务端升级），下一轮立即重新读取 */
    private var infoVersion: String? = null

    private class Sleep(val cont: CancellableContinuation<Unit>, val deadline: Long)

    private val netCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            netGen++
            val changed = networkSeen && lastNetwork != network      // 包括断网后重新连上
            networkSeen = true
            lastNetwork = network
            if (changed) kick("网络变化") else wake("network")
        }
        override fun onLost(network: Network) {
            netGen++
            if (network == lastNetwork) lastNetwork = null
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Hub.init(this)
        alarms = getSystemService(AlarmManager::class.java)
        heartbeat = Heartbeat(Heartbeat.prefsStore(this))
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "huijian:sync").apply { setReferenceCounted(false) }
        val type = if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
        try {
            ServiceCompat.startForeground(this, Notifier.ID_SERVICE, Notifier.serviceNotification(this, "正在连接…"), type)
            Notifier.serviceText = "正在连接…"
        } catch (e: Exception) {
            // 12 以上没有电池优化豁免时，系统可能不允许从后台启动前台服务（例如被杀后自动重启）
            Log.w(TAG, "无法进入前台：${e.message}")
            destroyed = true
            stopSelf()
            return
        }
        instance = this
        // 回调放主线程，和闹钟回调串行执行
        getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(netCallback, main)
        scheduleWatchdog()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (destroyed) return START_NOT_STICKY
        if (!Hub.loggedIn) { stopSelf(); return START_NOT_STICKY }
        when (intent?.action) {
            ACTION_RESTART -> restartLoop()
            else -> if (loop?.isActive != true) restartLoop() else if (Hub.store.mode == ReceiveMode.REALTIME) wake("start")
        }
        return START_STICKY
    }

    override fun onDestroy() {
        destroyed = true
        if (instance === this) instance = null
        Notifier.serviceText = null
        alarms.cancel(alarmIntent(this, KIND_WAKE))
        alarms.cancel(alarmIntent(this, KIND_WATCHDOG))
        alarms.cancel(alarmIntent(this, KIND_DEADLINE))
        sleeping.set(null)
        runCatching { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(netCallback) }
        api?.cancelAll()
        scope.cancel()
        if (wakeLock.isHeld) wakeLock.release()
        super.onDestroy()
    }

    /** 重启同步循环。新循环先等旧循环彻底退出（取消它正在进行的请求），保证同一时间只有一个循环 */
    private fun restartLoop() {
        if (destroyed) return
        val old = loop
        old?.cancel()
        api?.cancelAll()
        lastStep = SystemClock.elapsedRealtime()
        loop = scope.launch {
            // 不可取消地等：即使这个新循环自己马上又被取消，后来者 join 它时，旧循环也一定已经结束
            withContext(NonCancellable) { old?.join() }
            currentCoroutineContext().ensureActive()
            runLoop()
        }
    }

    private suspend fun runLoop() {
        var backoff = 5_000L
        var caughtUp = false
        /** 上一轮长轮询正常返回（CPU 本来就醒着，只需护住下一个请求发出去） */
        var steady = false
        val session = Hub.session
        while (true) {
            currentCoroutineContext().ensureActive()
            lastStep = SystemClock.elapsedRealtime()
            if (!Hub.loggedIn || Hub.session != session) { stopSelf(); return }
            val store = Hub.store
            // 请求发出、握手完成之前不让 CPU 睡下；超时自动释放。长轮询等待期间不需要：有数据到达时系统会唤醒 CPU
            wakeLock.acquire(if (steady) STEADY_WAKE_MS else WAKE_MS)
            steady = false
            try {
                val a = Hub.api() ?: if (store.tokenLost) throw UnauthorizedException() else throw IOException("读取登录凭证失败")
                api = a
                currentCoroutineContext().ensureActive()   // 重启发生在拿到新 Api 之前：这里退出，不会用没被取消的新实例继续拉
                if (!caughtUp) {
                    Hub.setState(ConnState.Connecting, session)
                    notice("正在连接…", session)
                    busy { catchUp(a, session) }
                    caughtUp = true
                    busy { refreshChannels(a, session) }
                }
                if (store.mode == ReceiveMode.INTERVAL) {
                    busy { poll(a, wait = 0, session = session) }
                    backoff = 5_000L
                    val next = System.currentTimeMillis() + store.intervalMin * 60_000L
                    Hub.setState(ConnState.Waiting(next), session)
                    notice("定时检查 · 每 ${store.intervalMin} 分钟", session)
                    releaseWake()
                    sleepFor(store.intervalMin * 60_000L)
                } else {
                    Hub.setState(ConnState.Connected, session)
                    notice("已连接 · 实时接收", session)
                    val seen = a.serverVersion
                    if (infoAt == 0L || SystemClock.elapsedRealtime() - infoAt > INFO_EVERY_MS || (seen != null && seen != infoVersion))
                        busy { refreshServerMax(a) }
                    val kind = netKind()
                    val w = heartbeat.waitFor(kind)
                    curWait = w
                    val gen = netGen
                    val net = getSystemService(ConnectivityManager::class.java).activeNetwork
                    var r = PollResult(early = false, gotData = true)
                    try {
                        busy { r = poll(a, wait = w, session = session) }
                    } catch (e: Exception) {
                        val began = longSince
                        // 只记「这条网络把连接断了」：循环重启 / 停服务（cancelAll）、换网络、断网引起的失败都不算
                        val sameNet = gen == netGen && net != null && net == getSystemService(ConnectivityManager::class.java).activeNetwork
                        if (began > 0 && !a.wasCancelled && sameNet && e !is CancellationException && e !is UnauthorizedException &&
                            (!kicked || kickIsFailure) && countsAsDrop(e))
                            heartbeat.record(kind, w, SystemClock.elapsedRealtime() - began, Heartbeat.Outcome.FAILED)
                        throw e
                    } finally {
                        longSince = 0L
                        kickIsFailure = false
                        alarms.cancel(alarmIntent(this, KIND_DEADLINE))
                    }
                    heartbeat.record(kind, w, r.elapsedMs, Heartbeat.Outcome.OK, r.gotData)
                    backoff = 5_000L
                    steady = true
                    if (r.early) { steady = false; releaseWake(); sleepFor(5_000L) }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: UnauthorizedException) {
                currentCoroutineContext().ensureActive()
                Hub.setState(ConnState.Unauthorized, session)
                notice("登录已失效，请打开回笺重新登录", session)
                stopSelf()
                return
            } catch (e: Exception) {
                currentCoroutineContext().ensureActive()
                if (kicked) { kicked = false; continue }
                val reason = shortError(e)
                Log.i(TAG, "同步出错：$reason，${backoff / 1000} 秒后重试")
                Hub.setState(ConnState.Reconnecting(reason, System.currentTimeMillis() + backoff), session)
                notice("重连中 · $reason", session)
                releaseWake()
                sleepFor(backoff)
                backoff = (backoff * 2).coerceAtMost(120_000L)
            }
        }
    }

    /** 包住一次阻塞请求：记下开始时间给看门狗；请求返回后如果循环已被取消，立即退出，不再写任何状态 */
    private suspend fun busy(block: () -> Unit) {
        kicked = false
        kickIsFailure = false
        busySince = SystemClock.elapsedRealtime()
        try { block() } finally { busySince = 0L; lastStep = SystemClock.elapsedRealtime() }
        currentCoroutineContext().ensureActive()
    }

    /**
     * 这个账号第一次同步：只取最新 50 条，标为已读、不提醒；
     * 之后（包括服务重启、切换接收方式）都从上次的位置补拉，期间错过的消息照常提醒。
     */
    private fun catchUp(a: Api, session: Long) {
        val store = Hub.store
        if (!store.initialSyncDone) {
            val page = a.messages(since = null, limit = 50)
            Hub.merge(page.messages, session)
            Hub.markRead(page.messages.map { it.id }, session)
            Hub.saveNow()
            Hub.inSession(session) {
                store.cursor = maxOf(page.nextSince ?: 0L, page.messages.maxOfOrNull { it.id } ?: 0L)
                store.initialSyncDone = true
            }
            Hub.touchContact()
            return
        }
        var cur = startCursor()
        val pending = HashSet<SettingKind>()
        repeat(20) {
            val cs = changesSince(a, session)
            val page = a.messages(since = cur, limit = 200, changesSince = cs)
            Hub.touchContact()
            val next = maxOf(page.nextSince ?: cur, page.messages.maxOfOrNull { it.id } ?: cur)
            val r = deliver(page, next, cs, session) ?: return
            pending += r
            if (page.messages.size < 200 || next == cur) { refreshSettings(pending, a, session); return }
            cur = next
        }
        refreshSettings(pending, a, session)
    }

    /**
     * 一轮长轮询的结果。early：要求挂起等待却没等就返回了空结果（不正常，调用方要稍等再发下一轮）；
     * gotData：返回了消息或变更（提前返回，说明不了这条网络能等多久）；elapsedMs：长轮询请求本身的耗时
     */
    private class PollResult(val early: Boolean, val gotData: Boolean, val elapsedMs: Long = 0L)

    private fun poll(a: Api, wait: Int, session: Long): PollResult {
        val since = startCursor()
        val cs = changesSince(a, session)
        val started = SystemClock.elapsedRealtime()
        if (wait > 0) {
            longSince = started
            setAlarm(KIND_DEADLINE, started + (wait + DEADLINE_GRACE_SEC) * 1000L)
        }
        // 长轮询：请求一发出就放开 WakeLock，等待期间 CPU 可以睡；有数据到达时系统会唤醒 CPU
        val page = a.messages(since = since, limit = 200, wait = wait, changesSince = cs, onSent = if (wait > 0) ::releaseWake else null)
        val elapsed = SystemClock.elapsedRealtime() - started
        if (wait > 0) { longSince = 0L; alarms.cancel(alarmIntent(this, KIND_DEADLINE)) }
        Hub.touchContact()
        val next = maxOf(since, page.nextSince ?: since, page.messages.maxOfOrNull { it.id } ?: since)
        val pending = HashSet(deliver(page, next, cs, session) ?: return PollResult(early = false, gotData = true, elapsedMs = elapsed))
        // 设置变更常常连着来几条（例如批量改 key）：短暂等一下，把紧接着的变更一起收下，每种设置只拉一次
        var drain = 0
        var last = pending.size
        while (pending.isNotEmpty() && drain++ < 3) {
            wakeLock.acquire(WAKE_MS)      // 长轮询发出时放开了唤醒锁：合并等待和补拉期间不让 CPU 睡下
            Thread.sleep(SETTINGS_SETTLE_MS)
            val s2 = startCursor()
            val cs2 = Hub.store.changesCursor ?: break
            val p2 = a.messages(since = s2, limit = 200, wait = 0, changesSince = cs2)
            val n2 = maxOf(s2, p2.nextSince ?: s2, p2.messages.maxOfOrNull { it.id } ?: s2)
            pending += deliver(p2, n2, cs2, session) ?: return PollResult(early = false, gotData = true, elapsedMs = elapsed)
            if (pending.size == last && p2.changes?.changes.isNullOrEmpty()) break
            last = pending.size
        }
        refreshSettings(pending, a, session)
        // 防空转：要求挂起等待却在 2 秒内返回、又没有任何进展（没有新消息、变更游标没动；
        // 代理不支持长连接、服务端反复返回 changes_reset 等）
        val changesMoved = cs != null && page.changes != null && !page.changes.reset && (page.changes.next ?: cs) > cs
        val noProgress = page.messages.isEmpty() && !changesMoved
        return PollResult(early = wait > 0 && noProgress && elapsed < 2_000L,
            gotData = !noProgress || page.changes?.reset == true, elapsedMs = elapsed)
    }

    /** 读取服务端允许的最长等待（/v1/info 的 long_poll_max，需要功能 poll.long）；失败时沿用上次的值，10 分钟后再试 */
    private fun refreshServerMax(a: Api) {
        try {
            val o = a.info()
            val feats = o.optJSONArray("features")
            val long = feats != null && (0 until feats.length()).any { feats.optJSONObject(it)?.optString("id") == "poll.long" }
            heartbeat.serverMax = if (long) o.optInt("long_poll_max", Heartbeat.OLD_SERVER_MAX) else Heartbeat.OLD_SERVER_MAX
            infoAt = SystemClock.elapsedRealtime()
            infoVersion = o.optString("version").ifBlank { a.serverVersion }
        } catch (e: UnauthorizedException) {
            throw e
        } catch (e: Exception) {
            if (a.wasCancelled) throw e
            infoAt = SystemClock.elapsedRealtime() - INFO_EVERY_MS + 10 * 60_000L
            infoVersion = a.serverVersion      // 失败时不因为版本头每轮都重试，10 分钟后再试
        }
    }

    /** 当前网络的种类：不同网络的 NAT 超时差别很大，等待时长分开记 */
    private fun netKind(): String {
        val cm = getSystemService(ConnectivityManager::class.java)
        val c = cm.getNetworkCapabilities(cm.activeNetwork) ?: return "other"
        return when {
            c.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
            c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cell"
            c.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "eth"
            else -> "other"
        }
    }

    /**
     * 这种失败是不是「连接被断开」：网络错误、读超时，或反向代理 / CDN 因读超时返回的状态码
     * （408、502、503、504，Cloudflare 的 520–524，例如 100 秒超时返回 524）。服务端自己的错误（500 等）不算
     */
    private fun countsAsDrop(e: Exception): Boolean = when (e) {
        is ApiException -> e.status == 408 || e.status in 502..504 || e.status in 520..524
        is IOException -> true
        else -> false
    }

    /** 长轮询到点（wait+25 秒）还没响应：多半是 NAT / 代理悄悄断开了，取消它立即重连 */
    private fun onDeadline() {
        val began = longSince
        if (began > 0 && api?.inFlight != null && SystemClock.elapsedRealtime() - began >= (curWait + 20) * 1000L) {
            kickIsFailure = true
            kick("长轮询 ${curWait} 秒到点没有响应")
        }
    }

    // ---- 多设备变更流：删除 / 归档 / 设置（docs/api.md「多设备同步」，行为和 iPhone 端一致） ----

    /** 这一轮要带的变更游标；服务端不支持时为 null。还没有游标（第一次、或游标作废）时先对账 */
    private fun changesSince(a: Api, session: Long): Long? {
        if (changesUnsupported) return null
        val store = Hub.store
        if (store.changesCursor == null && SystemClock.elapsedRealtime() >= reconcileRetryAt) {
            try {
                reconcile(a, session)
            } catch (e: UnauthorizedException) {
                throw e
            } catch (e: CancellationException) {
                throw e
            } catch (e: ApiException) {
                if (e.oldServer) changesUnsupported = true else reconcileRetryAt = SystemClock.elapsedRealtime() + 60_000L
            } catch (e: Exception) {
                if (a.wasCancelled || Hub.session != session) throw e      // 请求被取消（重启循环）：交给外层
                // 其他失败（网络、代理返回 HTML 导致 JSON 解析失败等）不影响收消息：这一轮不带游标，一分钟后再试
                reconcileRetryAt = SystemClock.elapsedRealtime() + 60_000L
            }
        }
        return store.changesCursor
    }

    /**
     * 对账：本地有、服务端已经没有的消息删掉（在别的设备或管理网页删除的），归档状态以服务端为准，再拿到变更游标。
     * 服务端纪元和上次不同（服务端重建或从备份恢复）时，服务端没有的消息不能当作被删除，只同步归档状态。
     */
    private fun reconcile(a: Api, session: Long) {
        val store = Hub.store
        val upTo = store.cursor        // 只处理请求前已同步到的消息
        val r = a.messageStates()
        if (Hub.session != session) return
        val (del, arch) = Changes.reconcile(Hub.messages.value, r.states, upTo, Changes.sameData(store.changesEpoch, r.epoch))
        Hub.removeMessages(del, session)
        Hub.applyArchive(arch, session)
        Hub.saveNow()
        Hub.inSession(session) {
            store.changesEpoch = r.epoch
            store.changesCursor = r.next
        }
        refreshChannels(a, session)
    }

    /** 按变更流重新拉设置：频道直接更新首页；pushkey 通知打开着的页面重新加载；账户信息交给账户页，并检查本机是否已被移除 */
    private fun refreshSettings(kinds: Set<SettingKind>, a: Api, session: Long) {
        if (kinds.isEmpty() || Hub.session != session) return
        if (SettingKind.CHANNELS in kinds) refreshChannels(a, session)
        if (SettingKind.KEYS in kinds) Hub.keysChanged()
        if (SettingKind.ACCOUNT in kinds) {
            val d = try { a.account() } catch (e: UnauthorizedException) { throw e } catch (e: Exception) { null } ?: return
            Hub.setAccount(d, session)
            // 设备列表里没有本机了：用 /v1/me 复核，它返回 401 就走登录失效流程（UnauthorizedException 交给外层）
            if (d.devices.none { it.current && !it.revoked }) {
                try { a.me() } catch (e: UnauthorizedException) { throw e } catch (_: Exception) {}
            }
        }
    }

    /** 合并、先落盘、再推进游标、最后提醒；返回 false 表示期间已退出登录 / 换了账号，结果作废 */
    /**
     * 从哪里继续拉：只看已保存的游标（不看内存里的最大 id）。写盘失败时内存里已有这批消息、游标却没前进，
     * 下一轮会从游标重新拉，不会漏。老版本没有游标时退回本地最大 id。
     */
    private fun startCursor(): Long = Hub.store.cursor.takeIf { it > 0 } ?: (Hub.maxId ?: 0L)

    /**
     * 合并新消息 → 应用其他设备的删除 / 归档 → 写盘 → 提醒 → 推进两个游标（写盘失败抛错退避，下次重拉）。
     * 返回这批变更里要重新拉的设置；返回 null 表示期间已退出登录 / 换了账号，结果作废。
     */
    private fun deliver(page: MessagePage, cursor: Long, cs: Long?, session: Long): Set<SettingKind>? {
        if (Hub.session != session) return null
        val store = Hub.store
        var plan = Changes.plan(emptyList())
        var nextChanges: Long? = null
        val ch = page.changes
        if (cs != null && ch != null) {
            if (!Changes.cursorValid(ch, store.changesEpoch)) {
                Hub.inSession(session) { store.changesCursor = null }     // 游标作废：下一轮重新对账
            } else {
                plan = Changes.plan(ch.changes)
                nextChanges = ch.next
            }
        }
        // 同一页里既有新消息又有删除它的变更：先去掉再合并，不提醒
        val incoming = if (plan.deleted.isEmpty()) page.messages else page.messages.filter { it.id !in plan.deleted }
        val fresh = if (incoming.isEmpty()) emptyList() else {
            wakeLock.acquire(WAKE_MS)
            Hub.merge(incoming, session)
        }
        Hub.removeMessages(plan.deleted, session)
        Hub.applyArchive(plan.archive, session)
        // 无条件写盘：上一轮写盘失败时这批消息已在内存里，这一轮 fresh 为空，不写就推进游标会丢消息。
        // 版本号没变时 write 直接返回（VersionedWriter）
        val saved = runCatching { Hub.saveNow() }.isSuccess
        // 提醒和写盘结果无关：内存里已有的消息重拉时不算新消息，这里不发就再也不会发了
        if (fresh.isNotEmpty()) Notifier.post(this, fresh.filter { !Hub.isHidden(it.topic) })
        // 先保存再推进游标：进程随时被杀也不会漏；写盘失败时游标不动，退避后从原位置重拉
        if (!saved) throw IOException("保存消息失败（存储空间不足？）")
        val ok = Hub.inSession(session) {
            store.cursor = cursor
            nextChanges?.let { store.changesCursor = it }
        }
        return if (ok) plan.refresh else null
    }

    private fun refreshChannels(a: Api, session: Long) {
        runCatching { a.channels() }.onSuccess { Hub.setChannels(it, session) }
    }

    // ---- 闹钟、看门狗、唤醒 ----

    /** 睡 ms 毫秒：用闹钟计时（Doze 中也会叫醒），网络恢复或用户操作时提前醒来 */
    private suspend fun sleepFor(ms: Long) {
        currentCoroutineContext().ensureActive()
        suspendCancellableCoroutine { cont ->
            val s = Sleep(cont, SystemClock.elapsedRealtime() + ms)
            setAlarm(KIND_WAKE, s.deadline)   // 先设闹钟再登记：wake 取走等待时一定能取消到这个闹钟
            sleeping.set(s)       // 同一时间只有一个循环，不会覆盖别人的等待
            cont.invokeOnCancellation {
                if (sleeping.compareAndSet(s, null)) alarms.cancel(alarmIntent(this, KIND_WAKE))
            }
        }
    }

    /** 提前结束当前等待（网络恢复、闹钟到点、用户打开 App、看门狗） */
    private fun wake(why: String) {
        if (destroyed) return
        // 定时模式下网络回调不提前醒来（否则每次切网络都多查一次）
        if (why == "network" && Hub.store.mode == ReceiveMode.INTERVAL) return
        val s = sleeping.getAndSet(null) ?: return
        if (why != KIND_WAKE) alarms.cancel(alarmIntent(this, KIND_WAKE))
        wakeLock.acquire(WAKE_MS)
        if (s.cont.isActive) s.cont.resume(Unit)
    }

    private fun releaseWake() { if (wakeLock.isHeld) wakeLock.release() }

    /** 取消当前请求并立即重连（网络变化、看门狗发现卡住）。定时模式下只打断正在进行的请求，不提前检查 */
    private fun kick(why: String) {
        if (destroyed) return
        Log.i(TAG, "立即重连：$why")
        val call = api?.inFlight
        if (call != null) { kicked = true; call.cancel() }
        if (Hub.store.mode != ReceiveMode.INTERVAL) wake("kick")
    }

    /** 闹钟到点（AlarmReceiver 在 onReceive 里同步调用，系统此时持有唤醒锁） */
    private fun onAlarm(kind: String?) {
        if (destroyed) return
        wakeLock.acquire(WAKE_MS)
        when (kind) {
            KIND_WAKE -> wake(KIND_WAKE)
            KIND_WATCHDOG -> onWatchdog()
            KIND_DEADLINE -> onDeadline()
        }
    }

    private fun scheduleWatchdog() {
        if (!destroyed) setAlarm(KIND_WATCHDOG, SystemClock.elapsedRealtime() + WATCHDOG_MS)
    }

    private fun onWatchdog() {
        val now = SystemClock.elapsedRealtime()
        val started = busySince
        val s = sleeping.get()
        when {
            // 长轮询按这一轮的等待时长判断；补拉、定时检查这些短请求按 50 秒
            started > 0 && now - started > ((if (longSince > 0) curWait else Heartbeat.LEGACY_WAIT) + 60) * 1000L ->
                if (api?.inFlight != null) {
                    if (longSince > 0) kickIsFailure = true
                    kick("看门狗：请求超过 ${(now - started) / 1000} 秒没有返回")
                } else restartLoop()
            s != null && now - s.deadline > 60_000L -> { Log.i(TAG, "看门狗：等待超时未醒，强制唤醒"); wake("watchdog") }
            loop?.isActive != true -> if (Hub.loggedIn) restartLoop()
            s == null && started == 0L && now - lastStep > STUCK_MS -> { Log.i(TAG, "看门狗：同步循环卡住，重启"); restartLoop() }
        }
        scheduleWatchdog()
    }

    private fun setAlarm(kind: String, at: Long) {
        val pi = alarmIntent(this, kind)
        val exact = Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()
        try {
            if (exact) alarms.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi)
            else alarms.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi)
        } catch (e: SecurityException) {
            alarms.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi)
        }
    }

    private fun notice(text: String, session: Long) {
        if (destroyed || Hub.session != session || text == lastNoticeText) return
        lastNoticeText = text
        Notifier.updateService(this, text)
    }

    private fun shortError(e: Exception): String = when (e) {
        is ApiException -> e.message ?: "HTTP ${e.status}"
        is java.net.UnknownHostException -> "找不到服务器（DNS）"
        is java.net.ConnectException -> "连不上服务器"
        is java.net.SocketTimeoutException -> "超时"
        is IOException -> if (e.message?.contains("Canceled", true) == true) "连接已重置" else (e.message ?: "网络错误")
        else -> e.javaClass.simpleName
    }

    /** 闹钟广播：转给正在运行的服务；服务不在时（被杀后）重新拉起 */
    class AlarmReceiver : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            val kind = intent.getStringExtra(EXTRA_KIND)
            val svc = instance
            if (svc != null) { svc.onAlarm(kind); return }
            Hub.init(ctx)
            if (Hub.loggedIn) runCatching { start(ctx) }
        }
    }

    companion object {
        /** 设置变更后等多久再拉（把紧接着的几条变更合并成一次拉取） */
        private const val SETTINGS_SETTLE_MS = 300L
        private const val TAG = "HuijianSync"
        /** 长轮询的「到点」闹钟比等待时长晚多少秒 */
        private const val DEADLINE_GRACE_SEC = 25
        /** 多久重新读一次服务端的 long_poll_max（服务端升级后能用上更长的等待） */
        private const val INFO_EVERY_MS = 6 * 3600_000L
        private const val WATCHDOG_MS = 10 * 60_000L
        private const val STUCK_MS = 5 * 60_000L
        private const val WAKE_MS = 30_000L
        private const val STEADY_WAKE_MS = 5_000L
        const val ACTION_RESTART = "restart"
        private const val EXTRA_KIND = "kind"
        private const val KIND_WAKE = "wake"
        private const val KIND_WATCHDOG = "watchdog"
        private const val KIND_DEADLINE = "deadline"

        @Volatile private var instance: SyncService? = null

        private fun alarmIntent(ctx: Context, kind: String): PendingIntent {
            val i = Intent(ctx, AlarmReceiver::class.java).setAction("io.github.hongyile.huijian.alarm.$kind").putExtra(EXTRA_KIND, kind)
            val code = when (kind) { KIND_WAKE -> 1; KIND_WATCHDOG -> 2; else -> 3 }
            return PendingIntent.getBroadcast(ctx, code, i,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }

        fun start(ctx: Context, restart: Boolean = false) {
            val i = Intent(ctx, SyncService::class.java)
            if (restart) i.action = ACTION_RESTART
            ContextCompat.startForegroundService(ctx, i)
        }

        fun stop(ctx: Context) = ctx.stopService(Intent(ctx, SyncService::class.java))
    }
}
