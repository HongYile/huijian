package io.github.hongyile.huijian

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import kotlin.concurrent.thread
import java.nio.file.Files

/**
 * 服务器代加密（§11.5）的接口细节：附件 410 按 reason 区分（sealed / missing），GET /v1/messages/{id} 重新拉取。
 * 用一个极简的本机 HTTP 服务（ServerSocket）模拟服务端响应（Android 单元测试的类路径里没有 JDK 的 HttpServer）
 */
class SealedApiTest {
    private lateinit var sock: ServerSocket
    private lateinit var url: String
    private val routes = HashMap<String, Pair<Int, String>>()

    @Before fun setUp() {
        routes["/v1/att/sealed1"] = 410 to """{"code":410,"error":"附件已加密，请刷新消息","reason":"sealed","message_id":42}"""
        routes["/v1/att/gone1"] = 410 to """{"code":410,"error":"附件文件已丢失","reason":"missing"}"""
        routes["/v1/messages/42"] = 200 to """{"message":{"id":42,"type":"e2e","text":"🔒 加密消息","e2e":"hje1.x.y","sealed":"server","e2e_status":"ok",""" +
            """"attachments":[{"id":"new-att","name":"a.bin","mime":"application/octet-stream","size":3,"sha256":"","key":"forged"}]}}"""
        routes["/v1/messages/43"] = 404 to """{"code":404,"error":"消息不存在"}"""
        sock = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        thread(isDaemon = true) {
            while (!sock.isClosed) {
                val c = try { sock.accept() } catch (_: Exception) { break }
                c.use {
                    val r = c.getInputStream().bufferedReader()
                    val path = r.readLine()?.split(" ")?.getOrNull(1).orEmpty()
                    while (r.readLine()?.isNotEmpty() == true) {}
                    val (status, body) = routes[path] ?: (404 to "not found")
                    val b = body.toByteArray()
                    c.getOutputStream().apply {
                        write(("HTTP/1.1 $status X\r\nContent-Type: application/json\r\nContent-Length: ${b.size}\r\nConnection: close\r\n\r\n").toByteArray())
                        write(b); flush()
                    }
                }
            }
        }
        url = "http://127.0.0.1:${sock.localPort}"
    }

    @After fun tearDown() { sock.close() }

    private fun download(id: String): ApiException {
        val dir = Files.createTempDirectory("att").toFile()
        try {
            Api(url, "t").download(Attachment(id, "a.bin", "application/octet-stream", 3, ""), File(dir, "a.bin"))
            fail("应当返回 410")
        } catch (e: ApiException) {
            assertTrue("下载失败时不留半截文件", dir.listFiles().isNullOrEmpty())
            return e
        } finally { dir.deleteRecursively() }
        throw AssertionError()
    }

    @Test fun attachment410Reasons() {
        val sealed = download("sealed1")
        assertEquals(410, sealed.status)
        assertEquals("sealed", sealed.reason)
        assertEquals(42L, sealed.messageId)
        val missing = download("gone1")
        assertEquals(410, missing.status)
        assertEquals("missing", missing.reason)
        assertEquals(0L, missing.messageId)
        assertFalse(missing.oldServer)
    }

    @Test fun refetchSingleMessage() {
        val m = Api(url, "t").message(42)
        assertEquals(42L, m.id)
        assertTrue(m.serverSealed)
        assertEquals("hje1.x.y", m.e2e)
        // 本机字段（解密状态、附件钥匙）不能由服务器写
        assertEquals("", m.e2eStatus)
        assertEquals("", m.attachments.single().key)
        assertEquals("new-att", m.attachments.single().id)
        try { Api(url, "t").message(43); fail() } catch (e: ApiException) { assertEquals(404, e.status); assertNull(e.reason) }
    }

    /** 并发请求用子实例：父实例 cancelAll 时子实例一起取消；取消之后再开的子实例一开始就是取消状态 */
    @Test fun childApisCancelledWithParent() {
        val parent = Api(url, "t")
        parent.withChild { c ->
            assertFalse(c.wasCancelled)
            parent.cancelAll()
            assertTrue(c.wasCancelled)
            try { c.message(42); fail("取消后不应再发请求") } catch (_: java.io.IOException) {}
        }
        parent.withChild { c -> assertTrue(c.wasCancelled) }
        // 没取消的父实例：子实例照常请求
        assertEquals(42L, Api(url, "t").withChild { it.message(42) }.id)
    }
}
