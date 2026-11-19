package io.github.hongyile.huijian

import io.github.hongyile.huijian.Heartbeat.Outcome.FAILED
import io.github.hongyile.huijian.Heartbeat.Outcome.OK
import org.junit.Assert.assertEquals
import org.junit.Test

/** 自适应长轮询等待时长（规则和 Mac / iPhone 的 Heartbeat.swift 一致，两边的用例也一致） */
class HeartbeatTest {
    private class Mem : Heartbeat.Store {
        val m = HashMap<String, Heartbeat.State>()
        override fun load(kind: String) = m[kind]
        override fun save(kind: String, s: Heartbeat.State) { m[kind] = s }
    }

    private var clock = 1_000_000_000L
    private fun hb(max: Int = 600) = Heartbeat(Mem()) { clock }.apply { serverMax = max }

    /** 等满 wait 秒、没有消息 */
    private fun Heartbeat.full(kind: String = "wifi"): Int { val w = waitFor(kind); return record(kind, w, w * 1000L, OK) }

    @Test fun oldServerKeepsFixedWait() {
        val h = hb(55)
        assertEquals(50, h.waitFor("wifi"))
        repeat(10) { assertEquals(50, h.full()) }
        assertEquals(50, h.record("wifi", 50, 30_000, FAILED))
    }

    @Test fun growsSlowlyUpToLimit() {
        val h = hb()
        assertEquals(120, h.waitFor("wifi"))
        h.full(); h.full()
        assertEquals(180, h.full())            // 连续 3 轮等满才加 1 分钟
        repeat(3) { h.full() }
        assertEquals(240, h.waitFor("wifi"))
        repeat(30) { h.full() }
        assertEquals(600, h.waitFor("wifi"))   // 最多 10 分钟
        assertEquals(300, hb(300).run { repeat(30) { full() }; waitFor("wifi") })   // 不超过服务端上限
    }

    @Test fun dataAndEarlyReturnsDoNotCount() {
        val h = hb()
        repeat(5) { h.record("wifi", 120, 3_000, OK, gotData = true) }
        repeat(5) { h.record("wifi", 120, 60_000, OK) }          // 服务端重启等提前返回
        assertEquals(120, h.waitFor("wifi"))
    }

    @Test fun silentDropHalvesAndCaps() {
        val h = hb()
        repeat(9) { h.full() }
        assertEquals(300, h.waitFor("wifi"))
        assertEquals(150, h.record("wifi", 300, 325_000, FAILED))  // 到点没响应：减半，300 记为上限
        repeat(3) { h.full() }
        assertEquals(210, h.waitFor("wifi"))
        repeat(3) { h.full() }
        assertEquals(270, h.waitFor("wifi"))  // 不超过上限前 30 秒
        repeat(6) { h.full() }
        assertEquals(270, h.waitFor("wifi"))
        clock += 6 * 3600_000L + 1             // 上限 6 小时后失效，继续试探
        repeat(3) { h.full() }
        assertEquals(330, h.waitFor("wifi"))
    }

    @Test fun cutByProxyFallsBelowCutPoint() {
        val h = hb()
        assertEquals(50, h.record("wifi", 120, 60_000, FAILED))   // 默认 nginx 60 秒读超时：退到 50（不低于下限）
        repeat(9) { h.full() }
        assertEquals(50, h.waitFor("wifi"))                        // 上限 60 - 30 < 50：保持 50
        val h2 = hb()
        repeat(6) { h2.full() }                                       // 240
        assertEquals(120, h2.record("wifi", 240, 240_000, FAILED))    // 恰好在等满时被切断（代理超时 = 等待时长）：按静默断开处理
    }

    @Test fun cutMidWait() {
        val h = hb()
        repeat(6) { h.full() }                                     // 240
        assertEquals(165, h.record("wifi", 240, 180_000, FAILED))  // 第 180 秒被切断：退到 165，上限 180
        repeat(3) { h.full() }
        assertEquals(165, h.waitFor("wifi"))                       // 165 + 60 > 180 - 30：保持
    }

    @Test fun neutralFailures() {
        val h = hb()
        assertEquals(120, h.record("wifi", 120, 5_000, FAILED))     // 刚发出就失败（切换网络）
        assertEquals(120, h.record("wifi", 120, 900_000, FAILED))   // 远超等待时长（休眠、被挂起）
    }

    @Test fun kindsAreIndependent() {
        val h = hb()
        repeat(9) { h.full("wifi") }
        h.record("cell", 120, 145_000, FAILED)
        assertEquals(300, h.waitFor("wifi"))
        assertEquals(60, h.waitFor("cell"))
    }

    @Test fun serverUpgradeStartsProbing() {
        val h = hb(55)
        repeat(5) { h.full() }
        h.serverMax = 600
        assertEquals(120, h.waitFor("wifi"))
    }
}
