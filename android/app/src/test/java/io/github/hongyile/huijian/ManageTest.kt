package io.github.hongyile.huijian

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 手机端管理功能：接口返回的解析、和服务端一致的校验规则、发送示例、频道排序 */
class ManageTest {

    @Test fun parseKeys() {
        val ks = Manage.keys(JSONObject("""{"keys":[
            {"id":1,"name":"default","key":"PK_abc","created_at":"2026-11-18T01:02:03Z","last_used":null,"revoked":false},
            {"id":2,"name":"old","key":"PK_def","created_at":"2026-11-01T00:00:00Z","last_used":"2026-11-02T00:00:00Z","revoked":true,"future":1}
        ]}"""))
        assertEquals(2, ks.size)
        assertEquals(PushKey(1, "default", "PK_abc", "2026-11-18T01:02:03Z", null, false), ks[0])
        assertEquals("2026-11-02T00:00:00Z", ks[1].lastUsed)
        assertTrue(ks[1].revoked)
        assertTrue(Manage.keys(JSONObject("{}")).isEmpty())
    }

    @Test fun parseAccountDetail() {
        val d = Manage.accountDetail(JSONObject("""{
            "account":{"id":3,"username":"Alex Chen","has_password":true},
            "devices":[
              {"id":"d_1","name":"Pixel","platform":"android","client":"android 0.3.0 (40)","created_at":1700000000,"last_seen":null,
               "last_paired":1700000500,"pair_count":2,"revoked":false,"current":true,"online":true,
               "pairings":[{"at":1700000500,"ip":"10.0.0.2","method":"password","client":""},{"at":1700000000,"ip":"","method":"code","client":""}]},
              {"id":"d_2","name":"Mac","platform":"macos","client":"","created_at":1690000000,"last_seen":1700000000,
               "last_paired":1690000000,"pair_count":1,"revoked":true,"current":false,"online":false,"pairings":[]}
            ],
            "register_open":true}"""))
        assertEquals(AccountInfo(3, "Alex Chen", true), d.account)
        assertTrue(d.registerOpen)
        val me = d.devices[0]
        assertTrue(me.current && me.online && !me.revoked)
        assertNull(me.lastSeen)
        assertEquals(listOf("密码登录", "配对码"), me.pairings.map { it.methodLabel })
        assertEquals(1700000000L, d.devices[1].lastSeen)
        assertTrue(d.devices[1].revoked)
        assertEquals("注册", Pairing(0, "", "register", "").methodLabel)
    }

    @Test fun parsePairCodeAndStatus() {
        assertEquals(PairCode("123456", 180), Manage.pairCode(JSONObject("""{"code":"123456","expires_in":180}""")))
        assertEquals(180, Manage.pairCode(JSONObject("""{"code":"1"}""")).expiresIn)        // 旧服务端没有 expires_in
        assertEquals(PairCodeStatus("used", 0, "Pixel 8"), Manage.pairStatus(JSONObject("""{"state":"used","expires_in":0,"used_by":"Pixel 8","used_at":1}""")))
        assertEquals(PairCodeStatus("waiting", 120, null), Manage.pairStatus(JSONObject("""{"state":"waiting","expires_in":120,"used_by":""}""")))
    }

    @Test fun parseSubscriptionsAndChannel() {
        assertEquals(mapOf(1L to "notify", 2L to "off"), Manage.subscriptions(JSONObject(
            """{"subscriptions":[{"pushkey_id":1,"name":"a","mode":"notify"},{"pushkey_id":2,"name":"b","mode":"off"}],"away_silent":true}""")))
        assertEquals(ChannelSetting("train", "训练", false, true, true, 2),
            Manage.channel(JSONObject("""{"topic":"train","alias":"训练","hidden":false,"muted":true,"pinned":true,"sort":2}""")))
    }

    @Test fun keyRules() {
        assertNull(Manage.keyProblem("", isNew = true))                 // 新建留空 = 自动生成
        assertEquals("请填写新 key", Manage.keyProblem("  ", isNew = false))
        assertNull(Manage.keyProblem("abcdefghij_klmn-", isNew = false))  // 16 位
        assertEquals(Manage.KEY_RULE, Manage.keyProblem("short_key_123", isNew = true))
        assertEquals(Manage.KEY_RULE, Manage.keyProblem("a".repeat(65), isNew = true))
        assertEquals(Manage.KEY_RULE, Manage.keyProblem("has space in the key", isNew = true))
        assertEquals(Manage.KEY_RULE, Manage.keyProblem("中文中文中文中文中文中文中文中文", isNew = true))
        val r = Manage.randomKey()
        assertTrue(r.startsWith("PK_") && r.length == 27 && r.matches(Manage.KEY_PATTERN))
        assertNotEquals(r, Manage.randomKey())
        assertEquals("名称不能为空", Manage.nameProblem("  "))
        assertNull(Manage.nameProblem("训练机"))
    }

    @Test fun usernameRules() {
        assertEquals("Alex Chen", Manage.normalizeUsername("  Alex \t  Chen "))
        assertNull(Manage.usernameProblem("Alex  Chen"))
        assertNull(Manage.usernameProblem("回笺"))
        assertNull(Manage.usernameProblem("a.b_c-1"))
        assertNull(Manage.usernameProblem(""))                          // 必填由调用方判断
        assertEquals("用户名需要 2–32 个字", Manage.usernameProblem("a"))
        assertEquals("用户名需要 2–32 个字", Manage.usernameProblem("a".repeat(33)))
        assertNull(Manage.usernameProblem("字".repeat(32)))              // 按字计，不按字节
        assertEquals(Manage.USERNAME_RULE, Manage.usernameProblem("alex@home"))
        assertEquals(Manage.USERNAME_RULE, Manage.usernameProblem("abㅤcd"))     // 韩文填充符（显示为空白）
        assertEquals(Manage.USERNAME_RULE, Manage.usernameProblem("ab😀"))
    }

    @Test fun passwordRules() {
        assertEquals("请设置密码（至少 8 位）", Manage.passwordProblem("", "", required = true))
        assertNull(Manage.passwordProblem("", "", required = false))     // 留空只改用户名
        assertEquals("两次输入的密码不一样", Manage.passwordProblem("", "x", required = false))
        assertEquals("密码至少 8 位", Manage.passwordProblem("1234567", "1234567", required = true))
        assertEquals("两次输入的密码不一样", Manage.passwordProblem("12345678", "12345679", required = true))
        assertNull(Manage.passwordProblem("密码密码密码密码", "密码密码密码密码", required = true))
    }

    @Test fun sendExamples() {
        val url = Manage.sendUrl("https://push.example.com/", "PK_abc-_1")
        assertEquals("https://push.example.com/message/push?pushkey=PK_abc-_1&text=hello", url)
        assertEquals("https://push.example.com/message/push?pushkey=PK_x&text=%E8%AE%AD%E7%BB%83%20%E5%AE%8C%E6%88%90",
            Manage.sendUrl("https://push.example.com", "PK_x", "训练 完成"))
        val curl = Manage.curlExample("https://push.example.com", "PK_x")
        assertTrue(curl.startsWith("curl \"https://push.example.com/message/push?pushkey=PK_x&text=hello\""))
        assertTrue(curl.contains("-d pushkey=PK_x") && curl.contains("https://push.example.com/message/push \\"))
    }

    @Test fun channelOrder() {
        fun c(t: String, pinned: Boolean = false, sort: Int = 0) = ChannelSetting(t, "", false, false, pinned, sort)
        val settings = mapOf("b" to c("b", sort = 2), "c" to c("c", sort = 1), "p" to c("p", pinned = true))
        val last = mapOf("a" to 10L, "b" to 1L, "c" to 2L, "d" to 20L, "p" to 0L)
        // 置顶在前，再按手动顺序，其余按最近活跃（新的在前）
        assertEquals(listOf("p", "c", "b", "d", "a"), Manage.orderChannels(listOf("a", "b", "c", "d", "p"), settings, last))
        assertEquals(listOf("a", "b"), Manage.orderChannels(listOf("b", "a"), emptyMap(), emptyMap()))    // 都一样时按名称
        assertEquals(listOf("b", "a", "c"), Manage.moved(listOf("a", "b", "c"), 1, 0))
        assertEquals(listOf("a", "c", "b"), Manage.moved(listOf("a", "b", "c"), 1, 2))
        assertEquals(listOf("a", "b"), Manage.moved(listOf("a", "b"), 0, 5))
        assertFalse(Manage.moved(listOf(1, 2), 0, 1) === listOf(1, 2))
    }

    /** /v1/info 的注册方式：register 字段优先；旧服务端看 register_open；认不出的按关闭 */
    @Test fun registerMode() {
        assertEquals(RegisterMode.OPEN, Manage.registerMode(JSONObject().put("register", "open")))
        assertEquals(RegisterMode.INVITE, Manage.registerMode(JSONObject().put("register", "invite").put("register_open", false)))
        assertEquals(RegisterMode.CLOSED, Manage.registerMode(JSONObject().put("register", "closed").put("register_open", true)))
        assertEquals(RegisterMode.CLOSED, Manage.registerMode(JSONObject().put("register", "vip-only")))
        assertEquals(RegisterMode.OPEN, Manage.registerMode(JSONObject().put("register_open", true)))
        assertEquals(RegisterMode.CLOSED, Manage.registerMode(JSONObject().put("register_open", false)))
        assertEquals(RegisterMode.CLOSED, Manage.registerMode(JSONObject()))
        // 要邀请码时必填，只有空白也算没填；其他方式不要
        assertEquals("请填写邀请码", Manage.inviteProblem(RegisterMode.INVITE, ""))
        assertEquals("请填写邀请码", Manage.inviteProblem(RegisterMode.INVITE, "  "))
        assertNull(Manage.inviteProblem(RegisterMode.INVITE, "HJ-1"))
        assertNull(Manage.inviteProblem(RegisterMode.OPEN, ""))
    }

    /** 注册即开启加密（register.e2e）：看 /v1/info 的 features（对象数组，也兼容字符串数组） */
    @Test fun registerWithKeysFeature() {
        val info = JSONObject("""{"features":[{"id":"register.invite"},{"id":"register.e2e","title":"注册即开启加密","since":"0.9.0"}]}""")
        assertTrue(Manage.registerWithKeys(info)); assertTrue(Manage.hasFeature(info, "register.invite"))
        assertFalse(Manage.registerWithKeys(JSONObject("""{"features":[{"id":"e2e.auto"}]}""")))
        assertFalse(Manage.registerWithKeys(JSONObject()))
        assertTrue(Manage.registerWithKeys(JSONObject("""{"features":["register.e2e"]}""")))
    }

    /** 登录页注册相关的显示：正在读 / 读不到 /v1/info / closed / invite / open */
    @Test fun registerUi() {
        val tog = RegisterUi.EntryTap.TOGGLE; val fetch = RegisterUi.EntryTap.FETCH_INFO
        val login = RegisterUi.SubmitPlan.LOGIN; val reg = RegisterUi.SubmitPlan.REGISTER; val need = RegisterUi.SubmitPlan.NEED_INFO
        // 正在读（或地址还没填好）：什么都不显示；之前点过注册时注册表单照样显示，提交前先读
        val loading = Manage.registerUi(null)
        assertFalse(loading.showEntry); assertNull(loading.closedNote); assertFalse(loading.withKeys)
        assertFalse(loading.entryVisible(false)); assertTrue(loading.entryVisible(true))
        assertEquals(login, loading.submitPlan(false, false))
        assertTrue(loading.registering(true, false)); assertFalse(loading.needInvite(true))
        assertEquals(need, loading.submitPlan(true, false))
        // 读不到（连不上、地址不对）：给注册入口，点了先重新读；不说「没开放」；注册提交前要先读到
        val failed = Manage.registerUi(null, failed = true)
        assertTrue(failed.showEntry); assertNull(failed.closedNote)
        assertEquals(fetch, failed.onEntryTap(false))
        assertEquals("已经在注册时点入口是退回登录", tog, failed.onEntryTap(true))
        assertEquals(need, failed.submitPlan(true, false))
        assertEquals("配对码登录不受影响", login, failed.submitPlan(true, usePair = true))
        assertEquals("连不上服务器，请检查地址或网络后重试", Manage.INFO_UNREACHABLE)
        // closed：没有注册入口，显示关闭说明；之前点过「注册」也不再处于注册状态，提交按登录
        val closed = Manage.registerUi(JSONObject("""{"register":"closed","features":[{"id":"register.e2e"}]}"""))
        assertFalse(closed.showEntry); assertEquals(Manage.REGISTER_CLOSED, closed.closedNote)
        assertFalse(closed.registering(true, false)); assertEquals(login, closed.submitPlan(true, false))
        assertTrue("正在注册时仍能点「已有账号？直接登录」退回", closed.entryVisible(true))
        // invite：有注册入口；注册时显示必填邀请码框；带钥匙注册
        val invite = Manage.registerUi(JSONObject("""{"register":"invite","register_open":false,"features":[{"id":"register.invite"},{"id":"register.e2e"}]}"""))
        assertTrue(invite.showEntry); assertNull(invite.closedNote); assertTrue(invite.withKeys)
        assertEquals(tog, invite.onEntryTap(false))
        assertTrue(invite.registering(true, false)); assertTrue(invite.needInvite(true)); assertEquals(reg, invite.submitPlan(true, false))
        assertFalse("没点注册时不显示邀请码框", invite.needInvite(invite.registering(false, false)))
        assertFalse("配对码登录时不在注册", invite.registering(true, usePair = true))
        // open：有注册入口，不要邀请码；没有 register.e2e 的旧服务端走旧流程
        val open = Manage.registerUi(JSONObject("""{"register":"open"}"""))
        assertTrue(open.showEntry); assertNull(open.closedNote); assertFalse(open.withKeys)
        assertTrue(open.registering(true, false)); assertFalse(open.needInvite(true))
        // 0.8 以前：只有 register_open
        assertTrue(Manage.registerUi(JSONObject("""{"register_open":true}""")).showEntry)
        assertEquals(Manage.REGISTER_CLOSED, Manage.registerUi(JSONObject("""{"register_open":false}""")).closedNote)
        // 注册被拒 403 后重新读 /v1/info；其他错误不读
        assertTrue(Manage.refetchInfoAfter(ApiException(403, "邀请码已用完")))
        assertFalse(Manage.refetchInfoAfter(ApiException(409, "这个用户名已被使用")))
        assertFalse(Manage.refetchInfoAfter(java.io.IOException("timeout")))
    }
}
