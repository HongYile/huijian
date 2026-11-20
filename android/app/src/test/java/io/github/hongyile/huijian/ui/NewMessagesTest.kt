package io.github.hongyile.huijian.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 首页新消息到达时的判断：自动滚到顶部，还是显示「有 N 条新消息」 */
class NewMessagesTest {
    @Test fun arrivedCountsOnlyNewerAtTheFront() {
        assertEquals(0, NewMessages.arrived(null, listOf(5, 4, 3)))          // 第一次显示
        assertEquals(0, NewMessages.arrived(5, listOf(5, 4, 3)))             // 没有新消息
        assertEquals(2, NewMessages.arrived(5, listOf(7, 6, 5, 4)))          // 两条新的插到前面
        assertEquals(0, NewMessages.arrived(5, listOf(4, 3)))                // 第一条被删除 / 归档
        assertEquals(1, NewMessages.arrived(5, listOf(9, 4, 3)))             // 第一条没了，同时来了一条新的
        assertEquals(0, NewMessages.arrived(5, emptyList()))
    }

    @Test fun atTopOnlyWhenOldFirstStillFirstAndBarelyScrolled() {
        val slop = 60
        assertTrue(NewMessages.wasAtTop(5, 5L, 0, slop))                    // 停在顶部
        assertTrue(NewMessages.wasAtTop(5, 5L, slop, slop))                 // 只被滚走一点点
        assertFalse(NewMessages.wasAtTop(5, 5L, slop + 1, slop))            // 第一条被滚走一半
        assertFalse(NewMessages.wasAtTop(5, 3L, 0, slop))                   // 已经往下翻了
        assertFalse(NewMessages.wasAtTop(null, 5L, 0, slop))                // 还没有上一次的第一条
        assertFalse(NewMessages.wasAtTop(5, null, 0, slop))                 // 列表还没布局
    }
}
