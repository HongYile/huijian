package io.github.hongyile.huijian

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** 多设备变更流：解析 changes、按 kind 分发、游标是否作废、对账 */
class ChangesTest {
    private fun msg(id: Long, archive: Int = 0) = Message(
        id = id, topic = "t", thread = "", priority = 3, type = "markdown", text = "m$id", desp = "", source = "",
        createdAt = Instant.EPOCH, attachments = emptyList(), archive = archive,
    )

    @Test fun parseChanges() {
        val p = Changes.parse(JSONObject("""{"messages":[],"next_since":9,
            "changes":[{"seq":41,"id":123,"kind":"delete"},{"seq":42,"id":124,"kind":"archive","state":1},
                       {"seq":43,"id":0,"kind":"keys"},{"seq":44,"id":0,"kind":"future_kind","x":1},{"seq":45,"id":7}],
            "changes_next":45,"changes_epoch":"e1"}"""))!!
        assertEquals(listOf(
            MsgChange(41, 123, "delete", null), MsgChange(42, 124, "archive", 1),
            MsgChange(43, 0, "keys", null), MsgChange(44, 0, "future_kind", null),
        ), p.changes)                                       // 没有 kind 的跳过
        assertEquals(45L, p.next); assertFalse(p.reset); assertEquals("e1", p.epoch)

        val reset = Changes.parse(JSONObject("""{"messages":[],"changes":[],"changes_next":0,"changes_reset":true,"changes_epoch":""}"""))!!
        assertTrue(reset.reset); assertNull(reset.epoch); assertTrue(reset.changes.isEmpty())
        assertNull(Changes.parse(JSONObject("""{"messages":[],"next_since":3}""")))      // 旧服务端 / 没带 changes_since
    }

    @Test fun parseStates() {
        val s = Changes.parseStates(JSONObject("""{"items":[[1,0],[2,1],[3],[]],"changes_next":88,"epoch":"e2"}"""))
        assertEquals(mapOf(1L to 0, 2L to 1, 3L to 0), s.states)
        assertEquals(88L, s.next); assertEquals("e2", s.epoch)
        assertNull(Changes.parseStates(JSONObject("""{"items":[],"changes_next":1}""")).epoch)
    }

    @Test fun planDispatchesByKind() {
        val p = Changes.plan(listOf(
            MsgChange(1, 10, "archive", 1),
            MsgChange(2, 10, "delete", null),      // 后来删掉：不再改归档
            MsgChange(3, 11, "archive", null),     // 没有 state 按 0
            MsgChange(4, 12, "archive", 2),
            MsgChange(5, 0, "channels", null),
            MsgChange(6, 0, "keys", null),
            MsgChange(7, 0, "devices", null),
            MsgChange(8, 0, "account", null),
            MsgChange(9, 0, "keys", null),         // 同一批里重复的设置只拉一次
            MsgChange(10, 0, "delete", null),      // id 0 不是消息
            MsgChange(11, 0, "archive", 1),
            MsgChange(12, 99, "something_new", 1), // 不认识的 kind 忽略
        ))
        assertEquals(setOf(10L), p.deleted)
        assertEquals(mapOf(11L to 0, 12L to 2), p.archive)
        assertEquals(setOf(SettingKind.CHANNELS, SettingKind.KEYS, SettingKind.ACCOUNT), p.refresh)
        assertTrue(Changes.plan(emptyList()).isEmpty)
        assertEquals(setOf(SettingKind.ACCOUNT), Changes.plan(listOf(MsgChange(1, 0, "devices", null))).refresh)
    }

    @Test fun cursorInvalidOnResetOrEpochChange() {
        fun page(reset: Boolean = false, epoch: String? = "e1") = ChangesPage(emptyList(), 5, reset, epoch)
        assertTrue(Changes.cursorValid(page(), "e1"))
        assertTrue(Changes.cursorValid(page(epoch = null), "e1"))     // 服务端没给纪元
        assertTrue(Changes.cursorValid(page(), null))                  // 本地还没记纪元
        assertFalse(Changes.cursorValid(page(reset = true), "e1"))
        assertFalse(Changes.cursorValid(page(epoch = "e2"), "e1"))
    }

    @Test fun reconcileDeletesWhatServerNoLongerHas() {
        val local = listOf(msg(1), msg(2, archive = 1), msg(3), msg(10))
        val states = mapOf(1L to 1, 2L to 1)          // 3 在别的设备上删了；10 是对账请求之后才同步到的
        val (del, arch) = Changes.reconcile(local, states, upTo = 5, sameData = true)
        assertEquals(setOf(3L), del)                   // 10 > upTo，不能当作被删
        assertEquals(mapOf(1L to 1), arch)             // 2 已经是 1，不算变化
    }

    @Test fun reconcileKeepsMessagesWhenEpochChanged() {
        val local = listOf(msg(1), msg(2), msg(3))
        val states = mapOf(2L to 2)
        assertFalse(Changes.sameData("old", "new"))
        val (del, arch) = Changes.reconcile(local, states, upTo = 100, sameData = Changes.sameData("old", "new"))
        assertTrue(del.isEmpty())                      // 服务端重建 / 从备份恢复：不按「服务端没有」删除本地消息
        assertEquals(mapOf(2L to 2), arch)             // 归档状态照样以服务端为准
        assertTrue(Changes.sameData(null, "new"))      // 第一次对账：按同一份数据处理
        assertTrue(Changes.sameData("e", null))
    }
}
