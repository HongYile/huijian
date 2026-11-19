package io.github.hongyile.huijian

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.fail
import org.junit.Assert.assertTrue
import org.junit.Test

class PathTest {
    @Test fun segmentFormat() {
        for (ok in listOf("123456", "d_20261118084142_ff8e", "A-b_9")) assertTrue(ok, Api.SEGMENT.matches(ok))
        for (bad in listOf("", "../x", "a/b", "a?b", "a#b", "a b", "%2e%2e", "中文", "x".repeat(129))) assertFalse(bad, Api.SEGMENT.matches(bad))
    }

    /** 格式不对的参数在发请求之前就拒绝（地址指向不存在的端口，真发出去会是连接错误而不是 400） */
    @Test fun badParamRejectedBeforeRequest() {
        val a = Api("http://127.0.0.1:9", "t")
        for (call in listOf<() -> Unit>({ a.pairCodeStatus("../keys") }, { a.revokeDevice("x/../../v1/keys") }, { a.revokeDevice("") })) {
            try { call(); fail("应当拒绝") } catch (e: ApiException) { assertEquals(400, e.status) }
        }
    }
}
