package io.github.hongyile.huijian

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

class SavingTest {
    /** 模拟同步服务的一轮：合并（有新消息时版本号加一）→ 无条件写盘 → 写成功才推进游标 */
    private class Round(val writer: VersionedWriter) {
        var version = 0L
        val memory = mutableListOf<Long>()
        var disk = emptyList<Long>()
        var cursor = 0L
        var diskFull = false

        fun deliver(ids: List<Long>, next: Long) {
            val fresh = ids.filter { it !in memory }
            if (fresh.isNotEmpty()) { memory += fresh; version++ }
            val saved = runCatching {
                writer.write(version) {
                    if (diskFull) throw IOException("空间不足")
                    disk = memory.toList()
                }
            }.isSuccess
            if (!saved) throw IOException("保存消息失败")
            cursor = next
        }
    }

    @Test fun retryAfterFailedSaveStillWritesBeforeAdvancing() {
        val r = Round(VersionedWriter())
        r.diskFull = true
        runCatching { r.deliver(listOf(1, 2), next = 2) }
        assertEquals("写盘失败时游标不动", 0L, r.cursor)
        assertEquals(listOf(1L, 2L), r.memory)
        // 退避后重拉同一批：内存里已有，不算新消息；仍要写盘，写成了才推进游标
        r.diskFull = false
        r.deliver(listOf(1, 2), next = 2)
        assertEquals(listOf(1L, 2L), r.disk)
        assertEquals(2L, r.cursor)
    }

    @Test fun retryStillFailingKeepsCursor() {
        val r = Round(VersionedWriter())
        r.diskFull = true
        runCatching { r.deliver(listOf(1), next = 1) }
        runCatching { r.deliver(listOf(1), next = 1) }
        assertEquals(0L, r.cursor)
        assertTrue(r.disk.isEmpty())
    }

    @Test fun unchangedVersionSkipsWrite() {
        val w = VersionedWriter()
        var writes = 0
        assertTrue(w.write(1) { writes++ })
        assertFalse(w.write(1) { writes++ })
        assertFalse(w.write(0) { writes++ })
        assertTrue(w.write(2) { writes++ })
        assertEquals(2, writes)
    }

    @Test fun failedWriteIsNotRecorded() {
        val w = VersionedWriter()
        runCatching { w.write(1) { throw IOException("x") } }
        var wrote = false
        assertTrue(w.write(1) { wrote = true })
        assertTrue(wrote)
    }

    @Test fun invalidSessionSkipsAndClearResets() {
        val w = VersionedWriter()
        assertFalse(w.write(5, valid = { false }) { error("不应写") })
        assertTrue(w.write(5) {})
        var cleared = false
        w.clear { cleared = true }
        assertTrue(cleared)
        assertTrue("清空后旧版本号也会重新写", w.write(1) {})
    }
}
