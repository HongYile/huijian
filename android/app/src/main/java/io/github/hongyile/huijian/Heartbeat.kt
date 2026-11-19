package io.github.hongyile.huijian

import android.content.Context
import android.content.SharedPreferences

/**
 * 实时模式的长轮询等待时长：按所在网络自适应（服务端 0.6.4 起支持超过 55 秒，见 /v1/info 的 long_poll_max）。
 *
 * 等待越久，手机网络被唤醒的次数越少；但等太久会被运营商 NAT、路由器或反向代理悄悄断开，消息就要等到发现断开才能收到。
 * 做法类似 TCP 的「慢慢加、快速减」：
 * - 从 2 分钟起步；连续 3 轮正常等满就加 1 分钟，最多 10 分钟（且不超过服务端上限）；
 * - 被中途切断（代理超时返回 502/504、连接被关闭）：退到切断点前 15 秒，并把切断点记为上限；
 * - 到点没有任何响应（静默断开）：减半，并把这次的时长记为上限；
 * - 上限 6 小时后失效，重新试探（网络情况会变）；
 * - 请求刚发出 20 秒内就失败（多半是切换网络）、或者耗时远超等待时长（手机休眠、App 被挂起）：不算数。
 * Wi-Fi、流量、VPN、有线各记各的。规则和 Mac / iPhone 的 Heartbeat.swift 一致。
 */
class Heartbeat(private val store: Store, private val now: () -> Long = System::currentTimeMillis) {

    /** 持久化：每种网络一条记录 */
    interface Store {
        fun load(kind: String): State?
        fun save(kind: String, s: State)
    }

    data class State(val cur: Int, val ceil: Int = 0, val ceilAt: Long = 0, val streak: Int = 0)

    /** 一轮长轮询的结果 */
    enum class Outcome {
        /** 正常返回：fullWait 表示没有消息、等满了时长才返回 */
        OK,
        /** 网络错误、超时、看门狗发现卡住，或网关返回 502 / 504 */
        FAILED,
    }

    /** 服务端允许的最长等待（旧服务端 55） */
    @Volatile var serverMax: Int = OLD_SERVER_MAX

    private fun limit(): Int = if (serverMax <= OLD_SERVER_MAX) LEGACY_WAIT else minOf(serverMax, MAX)

    private fun state(kind: String): State {
        val s = store.load(kind) ?: State(START)
        return if (s.ceil > 0 && now() - s.ceilAt > CEIL_TTL_MS) s.copy(ceil = 0, ceilAt = 0) else s
    }

    /** 这一轮要等多少秒 */
    fun waitFor(kind: String): Int {
        val lim = limit()
        if (lim <= LEGACY_WAIT) return lim
        return state(kind).cur.coerceIn(MIN, lim)
    }

    /**
     * 记录一轮结果。wait：这一轮请求的等待秒数；elapsedMs：从发出到结束（返回或失败）的时间；
     * gotData：返回了消息或变更（提前返回，说明不了能等多久）。返回调整后的下一轮等待秒数。
     */
    fun record(kind: String, wait: Int, elapsedMs: Long, outcome: Outcome, gotData: Boolean = false): Int {
        val lim = limit()
        if (lim <= LEGACY_WAIT) return lim
        val s = state(kind)
        val e = (elapsedMs / 1000).toInt()
        val next: State = when (outcome) {
            Outcome.OK -> {
                if (gotData || e < wait - 5) s     // 有数据提前返回 / 服务端重启等提前返回：不算数
                else {
                    val streak = s.streak + 1
                    if (streak < PROBE_STREAK) s.copy(cur = wait.coerceAtLeast(MIN), streak = streak)
                    else {
                        var up = minOf(wait + STEP, lim)
                        if (s.ceil > 0) up = minOf(up, s.ceil - 30)
                        s.copy(cur = maxOf(wait, up, MIN), streak = 0)
                    }
                }
            }
            Outcome.FAILED -> when {
                e < NEUTRAL_EARLY_SEC || e > wait + NEUTRAL_LATE_SEC -> s   // 切换网络 / 休眠挂起：不算数
                e >= wait - 5 -> State(cur = maxOf(MIN, wait / 2), ceil = wait, ceilAt = now())   // 静默断开
                else -> State(cur = maxOf(MIN, e - 15), ceil = maxOf(MIN, e), ceilAt = now())      // 被中途切断
            }
        }
        if (next != s) store.save(kind, next)
        return waitFor(kind)
    }

    companion object {
        const val OLD_SERVER_MAX = 55
        /** 旧服务端（上限 55）时沿用的固定等待 */
        const val LEGACY_WAIT = 50
        const val MIN = 50
        const val START = 120
        const val STEP = 60
        const val MAX = 600
        const val PROBE_STREAK = 3
        const val NEUTRAL_EARLY_SEC = 20
        const val NEUTRAL_LATE_SEC = 90
        const val CEIL_TTL_MS = 6 * 3600_000L

        /** SharedPreferences 存储：键 hb.<kind>，值 cur,ceil,ceilAt,streak */
        fun prefsStore(ctx: Context): Store = PrefsStore(ctx.getSharedPreferences("huijian_heartbeat", Context.MODE_PRIVATE))
    }

    private class PrefsStore(private val p: SharedPreferences) : Store {
        override fun load(kind: String): State? {
            val v = p.getString("hb.$kind", null)?.split(',') ?: return null
            if (v.size != 4) return null
            return runCatching { State(v[0].toInt(), v[1].toInt(), v[2].toLong(), v[3].toInt()) }.getOrNull()
        }
        override fun save(kind: String, s: State) {
            p.edit().putString("hb.$kind", "${s.cur},${s.ceil},${s.ceilAt},${s.streak}").apply()
        }
    }
}
