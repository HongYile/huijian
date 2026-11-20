package io.github.hongyile.huijian

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * 管理接口对真实服务端的集成测试。默认跳过；在本机起一个测试用 hub 后设置
 * HUIJIAN_IT_URL（例如 http://127.0.0.1:18890）和 HUIJIAN_IT_TOKEN（一台设备的 token）再运行。
 * 不要指向正式服务器：会新建、吊销、删除 pushkey，移除设备，删除频道。
 */
class ApiIntegrationTest {
    private lateinit var url: String
    private lateinit var api: Api

    @Before fun setUp() {
        val u = System.getenv("HUIJIAN_IT_URL"); val t = System.getenv("HUIJIAN_IT_TOKEN")
        assumeTrue("没有设置 HUIJIAN_IT_URL / HUIJIAN_IT_TOKEN，跳过", !u.isNullOrBlank() && !t.isNullOrBlank())
        url = u!!; api = Api(url, t)
    }

    private inline fun expectApi(status: Int, block: () -> Unit): ApiException {
        try { block(); fail("应当返回 $status") } catch (e: ApiException) { assertEquals(e.message, status, e.status); return e }
        throw AssertionError()
    }

    @Test fun keysLifecycle() {
        val custom = Manage.randomKey()
        val k = api.createKey("it-测试", custom)
        assertEquals(custom, k.key); assertEquals("it-测试", k.name); assertFalse(k.revoked); assertEquals(null, k.lastUsed)
        val auto = api.createKey("it-auto")
        assertTrue(auto.key.matches(Manage.KEY_PATTERN))
        expectApi(409) { api.createKey("dup", custom) }                      // 重复
        expectApi(400) { api.createKey("bad", "short") }                     // 不合规则

        assertEquals("it-改名", api.updateKey(k.id, "it-改名", "").name)
        val newKey = Manage.randomKey()
        val replaced = api.updateKey(k.id, "", newKey)
        assertEquals(newKey, replaced.key); assertEquals("it-改名", replaced.name)

        api.push(newKey, "it 测试推送", "**hello**", 2, "it-keys")
        assertNotNull(api.keys().first { it.id == k.id }.lastUsed)

        val subs = api.subscriptions()
        if (subs != null) {
            api.setSubscription(k.id, "silent")
            assertEquals("silent", api.subscriptions()!![k.id])
            api.setSubscription(k.id, "notify")
        }

        expectApi(409) { api.deleteKey(k.id) }                               // 先吊销才能删
        assertTrue(api.revokeKey(k.id).revoked)
        expectApi(400) { api.updateKey(k.id, "x", "") }                      // 已吊销不能改
        api.deleteKey(k.id)
        assertFalse(api.keys().any { it.id == k.id })
        api.revokeKey(auto.id); api.deleteKey(auto.id)
    }

    @Test fun accountDevicesAndPairCode() {
        val d = api.account()
        assertTrue(d.devices.count { it.current } == 1)

        val code = api.createPairCode()
        assertTrue(code.code.matches(Regex("\\d{6}")) && code.expiresIn in 1..600)
        assertEquals("waiting", api.pairCodeStatus(code.code).state)

        // 用配对码加一台设备，状态变成 used 并带设备名；再从本机移除它
        val other = Api(url, null).pair(code.code, "it-另一台", "ab".repeat(20))
        val st = api.pairCodeStatus(code.code)
        assertEquals("used", st.state); assertEquals("it-另一台", st.usedBy)
        val dev = api.account().devices.first { it.id == other.deviceId }
        assertFalse(dev.current)
        api.revokeDevice(dev.id)
        try { Api(url, other.token).account(); fail("被移除的设备应当失效") } catch (_: UnauthorizedException) {}

        val name = api.me().optString("name")
        assertEquals("it-本机", api.renameMe("it-本机"))
        api.renameMe(name)
    }

    @Test fun credentials() {
        val a = api.account().account
        val me = api.me()
        try {
            val saved = api.setCredentials(a.username.ifBlank { "it-user" }, if (a.hasPassword) "" else "it-password-1", "")
            assertTrue(saved.username.isNotBlank())
        } catch (e: ApiException) {
            // 已有密码时要当前密码；0.9.0 以前的服务端上，没有「允许管理」的设备也不能设初始密码（0.9.0 起本账号任何设备都能设）：服务端给出说明
            assertEquals(403, e.status); assertFalse(me.optBoolean("can_admin") && !a.hasPassword); assertTrue(e.message!!.isNotBlank())
        }
        // 用户名太短：有权限时 400；没权限时服务端先报权限（403），两种都带说明
        try { api.setCredentials("x", "", ""); fail() } catch (e: ApiException) {
            assertTrue(e.status == 400 || e.status == 403); assertTrue(e.message!!.isNotBlank())
        }
    }

    @Test fun channels() {
        val k = api.createKey("it-ch")
        try {
            api.push(k.key, "频道测试", "", 2, "it-ch-a")
            api.push(k.key, "频道测试", "", 2, "it-ch-b")
            val c = api.updateChannel("it-ch-a", alias = "频道甲", muted = true)
            assertEquals("频道甲", c.alias); assertTrue(c.muted)
            api.setChannelOrder(listOf("it-ch-b", "it-ch-a"))
            val list = api.channels().associateBy { it.topic }
            assertEquals(1, list["it-ch-b"]!!.sort); assertEquals(2, list["it-ch-a"]!!.sort)
            api.setChannelOrder(emptyList())
            assertTrue(api.channels().none { it.sort > 0 })
            assertEquals(1, api.deleteChannel("it-ch-a"))
            assertEquals(1, api.deleteChannel("it-ch-b"))
            assertTrue(api.channels().none { it.topic.startsWith("it-ch-") })
        } finally { api.revokeKey(k.id); api.deleteKey(k.id) }
    }

    @Test fun changeStreamWakesLongPoll() {
        val st = api.messageStates()
        assertTrue(st.next >= 0)
        val since = api.messages(since = null, limit = 1).messages.maxOfOrNull { it.id } ?: 0L
        // 长轮询挂着时，另一台设备新建 key：应当立即返回 keys 变更（设置实时同步，服务端 0.6.1）
        var made: PushKey? = null
        val t = Thread { Thread.sleep(800); made = Api(url, System.getenv("HUIJIAN_IT_TOKEN")).createKey("it-sync") }
        t.start()
        val started = System.currentTimeMillis()
        val page = api.messages(since = since, limit = 10, wait = 20, changesSince = st.next)
        val took = System.currentTimeMillis() - started
        t.join()
        assertTrue("长轮询应当被变更唤醒，实际 ${took}ms", took < 5000)
        val ch = page.changes!!
        assertFalse(ch.reset)
        assertTrue(ch.next!! > st.next)
        assertTrue(Changes.plan(ch.changes).refresh.contains(SettingKind.KEYS))
        // 吊销、删除也各产生一条 keys 变更；从新游标继续时只看到之后的
        api.revokeKey(made!!.id); api.deleteKey(made!!.id)
        val p2 = api.messages(since = since, limit = 10, wait = 0, changesSince = ch.next)
        assertEquals(listOf("keys", "keys"), p2.changes!!.changes.map { it.kind }.filter { it == "keys" })
    }

    @Test fun registerClosedByDefault() {
        if (Api(url, null).info().optBoolean("register_open")) return
        val e = expectApi(403) { Api(url, null).login("it-new", "it-password-1", "x", "cd".repeat(20), register = true) }
        assertTrue(e.message!!.contains("注册"))
    }
}
