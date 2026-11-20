package io.github.hongyile.huijian

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.time.Instant

/**
 * 端到端加密的客户端状态机和协议规则（docs/e2ee-client.md §10）。
 * 密码学换成可预测的假实现（FakeCrypto），服务端换成内存里的模拟（FakeServer），
 * 测试只看客户端有没有按规格发请求、核对、拒绝。真实密码学 + 真实服务端的测试见 E2EHostTest。
 */
class E2ETest {

    // ---------- 假实现 ----------

    class FakeCrypto : E2ECrypto {
        private var n = 0
        private fun next() = ++n
        override fun passwordKeys(password: String, saltHex: String) = "auth:$password:$saltHex" to "unlock:$password:$saltHex"
        override fun pbkdf2(password: String, saltHex: String, iterations: Int): String {
            if (iterations < 600_000) throw Core.Failure("weak_params", "轮数不够")
            return "pk:$password:$saltHex:$iterations"
        }
        override fun newSalt() = "%032x".format(next())
        override fun passwordProblem(password: String, username: String) =
            if (password.length < 10) "密码太短" else if (password.startsWith("old")) "这是常见密码" else null
        override fun keypair(): Core.KeyPair { val i = next(); return Core.KeyPair("sk$i", "pub$i", "kid$i") }
        override fun publicKey(sk: String) = "pub" + sk.removePrefix("sk") to "kid" + sk.removePrefix("sk")
        override fun random32() = "r${next()}"
        override fun wrap(prefix: String, key: String, data: String) = "$prefix|$key|$data"
        override fun unwrap(prefix: String, key: String, wrap: String): String {
            val p = wrap.split("|")
            if (p.size != 3 || p[0] != prefix) throw Core.Failure("format", "格式不对")
            if (p[1] != key) throw Core.Failure("wrong_key", "钥匙不对")
            return p[2]
        }
        override fun recoveryNew(): Pair<String, String> { val i = next(); return "CODE-$i" to "rk$i" }
        override fun recoveryKey(code: String): String {
            if (!code.startsWith("CODE-")) throw Core.Failure("format", "恢复码格式不对：应为 26 位字母和数字")
            return "rk" + code.removePrefix("CODE-")
        }
        override fun grantSeal(sk: String, pub: String) = "hjg1|$pub|$sk"
        override fun grantOpen(deviceSk: String, grant: String): String {
            val p = grant.split("|")
            if (p[1] != publicKey(deviceSk).first) throw Core.Failure("wrong_key", "钥匙不对")
            return p[2]
        }
        override fun sasCommit(pub: String, account: String, nonce: String) = "commit:$pub:$account:$nonce"
        override fun sasCode(pub: String, account: String, na: String, nb: String) =
            "%06d".format(Math.floorMod("$pub|$account|$na|$nb".hashCode(), 1_000_000))
        /** 信封：env|<公钥>|<载荷 JSON> */
        override fun openMessage(keys: List<String>, envelope: String): JSONObject {
            val p = envelope.split("|", limit = 3)
            if (p.size != 3 || p[0] != "env") throw Core.Failure("format", "格式不对")
            if (keys.none { publicKey(it).first == p[1] }) throw Core.Failure("wrong_key", "钥匙不对")
            return JSONObject(p[2])
        }
        override fun mdBuild(text: String, desp: String, atts: List<Map<String, Any?>>) =
            JSONObject().put("v", 1).put("atts", JSONArray(atts.map { it["name"] })).toString() to "预览：$desp"
        override fun decryptFile(key: String, src: File, dst: File) = throw UnsupportedOperationException()
        /** 配对码带钥匙：hjc1|<一次性钥匙>|<私钥> */
        override fun pairKeyNew(sk: String): Pair<String, String> { val sec = "SECRET-${next()}"; return sec to "hjc1|$sec|$sk" }
        override fun pairKeyOpen(secret: String, wrap: String): String {
            val p = wrap.split("|")
            if (p.size != 3 || p[0] != "hjc1" || p[1] != secret) throw Core.Failure("format", "配对码里的钥匙对不上")
            return p[2]
        }
    }

    class Flags : UpgradeFlags {
        val set = HashSet<String>()
        override fun isUpgraded(server: String, username: String) = UpgradeFlags.key(server, username) in set
        override fun markUpgraded(server: String, username: String) { set += UpgradeFlags.key(server, username) }
    }

    /** 内存里的服务端，规则照 server/e2e_api.go、account.go */
    class FakeServer(val c: FakeCrypto) {
        var oldServer = false
        var preloginOverride: JSONObject? = null
        /** 0.9.0 注册即开启加密（register.e2e）：注册请求必须带 pub / password_wrap / auth_key */
        var registerE2E = false
        /** 注册要的邀请码（null = 不要） */
        var inviteCode: String? = null
        // 账号
        var username = "alice"
        var pbkdfSalt = "aa".repeat(16)
        var iterations = 600_000
        var legacyPassword: String? = "old-password"   // 旧账号（还没升级）的密码，服务端用它核对 password_key
        var hasPassword = true                         // false：账号还没有密码（只能设置初始密码）
        var authSalt = ""
        var authKey = ""                               // 已升级：期望的登录凭证
        // 加密
        var keys = mutableListOf<E2EKeyInfo>()
        var passwordWrap = ""
        var recoveryWrap = ""
        var e2eOnly = false
        /** 开启过加密（setup 只能用一次，之后用 reset） */
        var everEnabled = false
        /** GET /v1/e2e 的 server_seal（0.8.0 起始终为 true）；false = 0.7 服务端，不自动开启 */
        var serverSeal = true
        var plainMessages = 0
        class Dev(var pub: String = "", var requested: Boolean = false, var commit: String = "", var na: String = "", var nb: String = "",
                  var grant: String = "", var name: String = "")
        val devs = HashMap<String, Dev>()
        /** 收到的全部请求体（检查从不发送密码原文） */
        val bodies = mutableListOf<JSONObject>()
        /** 批准时带的 kid */
        val grantKids = mutableListOf<String>()
        var tamperReveal: String? = null
        /** 给某台设备看的假 keys（被攻破的服务器给新设备看自己的公钥） */
        val fakeKeysFor = HashMap<String, List<E2EKeyInfo>>()
        /** 配对码 → key_wrap（不带钥匙时为空串）；用掉即删 */
        val pairCodes = HashMap<String, String>()

        val upgraded get() = authKey.isNotEmpty()
        val enabled get() = keys.isNotEmpty()

        /** 上传锁住的副本时带的 kid 必须是启用中的钥匙（server/e2e_store.go checkWrapKID）；不带不检查 */
        fun checkKid(o: JSONObject) {
            val kid = o.optString("kid")
            if (kid.isNotEmpty() && keys.none { it.active && it.kid == kid }) err(409, "这把钥匙已经停用（账号重置过加密）：请先用密码或恢复码解锁新的钥匙")
        }

        private fun err(status: Int, msg: String): Nothing = throw ApiException(status, msg)

        fun checkCurrent(o: JSONObject) {
            val ak = o.optString("current_auth_key"); val pk = o.optString("current_password_key"); val pw = o.optString("current_password")
            if (upgraded && ak.isEmpty()) err(426, "请把回笺更新到最新版")
            val ok = when {
                ak.isNotEmpty() -> upgraded && ak == authKey
                pk.isNotEmpty() -> !upgraded && legacyPassword != null && pk == c.pbkdf2(legacyPassword!!, pbkdfSalt, iterations)
                pw.isNotEmpty() -> !upgraded && pw == legacyPassword
                else -> false
            }
            if (!ok) err(403, "当前密码不对")
        }

        fun net(deviceId: String): E2ENet = object : E2ENet {
            override fun prelogin(username: String): JSONObject {
                if (oldServer) throw ApiException(404, Api.OLD_SERVER, oldServer = true)
                preloginOverride?.let { return it }
                return if (upgraded) JSONObject().put("kdf", "argon2id").put("salt", authSalt).put("time", 3).put("memory_kib", 65536).put("lanes", 1)
                else JSONObject().put("kdf", "pbkdf2-sha256").put("salt", pbkdfSalt).put("iterations", iterations)
            }
            override fun loginRaw(body: JSONObject, register: Boolean): JSONObject {
                bodies += body
                val id = "d_" + body.optString("name")
                if (register) {
                    inviteCode?.let { if (body.optString("invite_code") != it) err(403, "邀请码不对或已经用完，请向服务器管理员索取新的") }
                    // 0.9.0（register.e2e）：缺加密字段 400，什么都不建
                    if (registerE2E && (!body.has("pub") || !body.has("password_wrap") || !body.has("auth_key")))
                        err(400, "请更新回笺客户端后注册（新版注册时同时开启端到端加密）")
                    username = body.getString("username"); authSalt = body.getString("auth_salt"); authKey = body.getString("auth_key"); legacyPassword = null
                    if (body.has("pub")) {      // 同一个事务里存账号钥匙
                        val pub = body.getString("pub")
                        keys = mutableListOf(E2EKeyInfo("kid" + pub.removePrefix("pub"), pub, true))
                        passwordWrap = body.getString("password_wrap"); recoveryWrap = body.optString("recovery_wrap"); everEnabled = true
                    }
                } else {
                    val ak = body.optString("auth_key"); val pk = body.optString("password_key"); val pw = body.optString("password")
                    if (upgraded && ak.isEmpty()) err(426, "请把回笺更新到最新版")
                    val ok = when {
                        ak.isNotEmpty() -> ak == authKey
                        pk.isNotEmpty() -> pk == c.pbkdf2(legacyPassword ?: "", pbkdfSalt, iterations)
                        else -> pw == legacyPassword
                    }
                    if (!ok) err(403, "用户名或密码不对")
                }
                devs.getOrPut(id) { Dev(name = body.optString("name")) }
                val o = JSONObject().put("device_id", id).put("name", body.optString("name")).put("token", "tok-$id")
                if (body.has("auth_key")) o.put("e2e", JSONObject().put("enabled", enabled).put("keys", keysJson()).put("password_wrap", passwordWrap))
                return o
            }
            private fun keysJson(list: List<E2EKeyInfo> = keys) = JSONArray(list.map { JSONObject().put("kid", it.kid).put("pub", it.pub).put("active", it.active) })
            override fun e2eState(): JSONObject {
                val d = devs.getOrPut(deviceId) { Dev() }
                return JSONObject().put("enabled", enabled).put("keys", keysJson(fakeKeysFor[deviceId] ?: keys)).put("e2e_only", e2eOnly).put("auth_key", upgraded)
                    .put("server_seal", serverSeal).put("plain_messages", plainMessages)
                    .put("has_password_wrap", passwordWrap.isNotEmpty()).put("recovery_wrap", recoveryWrap)
                    .put("device", JSONObject().put("pub", d.pub).put("grant", d.grant).put("requested", d.requested)
                        .put("challenge", d.na).put("revealed", d.nb.isNotEmpty()))
                    .put("requests", JSONArray(devs.filter { it.key != deviceId && it.value.requested }.map { (id, x) ->
                        JSONObject().put("device_id", id).put("name", x.name).put("platform", "android").put("pub", x.pub).put("requested_at", 1)
                            .put("commit", x.commit).put("challenge", x.na).put("reveal", tamperReveal ?: x.nb)
                    }))
            }
            override fun e2eSetup(body: JSONObject): JSONObject {
                bodies += body
                if (enabled || everEnabled) err(409, "这个账号已经开启了加密")
                checkCurrent(body)
                val pub = body.getString("pub")
                keys += E2EKeyInfo("kid" + pub.removePrefix("pub"), pub, true)
                authSalt = body.getString("auth_salt"); authKey = body.getString("auth_key"); legacyPassword = null
                passwordWrap = body.getString("password_wrap"); recoveryWrap = body.optString("recovery_wrap")     // 0.8 起恢复码可选
                everEnabled = true
                return JSONObject().put("kid", keys.last().kid)
            }
            override fun e2eReset(body: JSONObject): JSONObject {
                bodies += body
                if (!everEnabled) err(409, "这个账号还没有开启加密：请用 /v1/e2e/setup 开启")
                checkCurrent(body)
                val pub = body.getString("pub")
                val kid = "kid" + pub.removePrefix("pub")
                keys = keys.filter { it.pub != pub }.map { it.copy(active = false) }.toMutableList()
                keys += E2EKeyInfo(kid, pub, true)
                authSalt = body.getString("auth_salt"); authKey = body.getString("auth_key"); legacyPassword = null
                passwordWrap = body.getString("password_wrap"); recoveryWrap = body.optString("recovery_wrap")
                devs.values.forEach { it.requested = false; it.commit = ""; it.na = ""; it.nb = "" }
                return JSONObject().put("kid", kid)
            }
            override fun e2eUnlock(authKey: String): JSONObject {
                if (!enabled) err(409, "这个账号还没有开启加密")
                if (!upgraded || passwordWrap.isEmpty()) err(409, "用密码锁住的私钥已失效（管理员重设过密码）")
                checkCurrent(JSONObject().put("current_auth_key", authKey))
                return JSONObject().put("password_wrap", passwordWrap)
            }
            override fun e2eDevice(pub: String, request: Boolean, commit: String?): JSONObject {
                val d = devs.getOrPut(deviceId) { Dev() }
                if (d.pub != pub) d.grant = ""
                d.pub = pub; d.requested = request; d.commit = commit.orEmpty(); d.na = ""; d.nb = ""
                return JSONObject()
            }
            override fun e2eChallenge(deviceId: String, nonce: String) {
                val d = devs[deviceId] ?: err(409, "请求不存在")
                if (!d.requested || d.na.isNotEmpty()) err(409, "这个请求已经由另一台设备处理")
                d.na = nonce
            }
            override fun e2eReveal(nonce: String) {
                val d = devs[deviceId]!!
                // 服务端用账号当前 active 的钥匙核对承诺
                val acc = keys.firstOrNull { it.active }?.pub.orEmpty()
                // 冒充中的服务器（fakeKeysFor）不核对，照单全收
                val honest = deviceId !in fakeKeysFor
                if (d.na.isEmpty() || d.nb.isNotEmpty() || (honest && c.sasCommit(d.pub, acc, nonce) != d.commit)) err(409, "揭晓失败")
                d.nb = nonce
            }
            override fun e2eGrant(deviceId: String, pub: String, grant: String, kid: String) {
                grantKids += kid
                checkKid(JSONObject().put("kid", kid))
                val d = devs[deviceId] ?: err(409, "请求不存在")
                if (!d.requested || d.nb.isEmpty() || d.pub != pub) err(409, "对方取消了请求或换了公钥")
                d.grant = grant; d.requested = false
            }
            override fun e2eDeny(deviceId: String) { devs[deviceId]?.let { it.requested = false; it.na = ""; it.nb = "" } }
            override fun e2eRecovery(body: JSONObject) { bodies += body; checkCurrent(body); checkKid(body); recoveryWrap = body.getString("recovery_wrap") }
            override fun accountAuth(body: JSONObject): JSONObject {
                bodies += body
                checkCurrent(body)
                if (enabled && !body.has("password_wrap")) err(400, "缺少 password_wrap")
                checkKid(body)
                authSalt = body.getString("auth_salt"); authKey = body.getString("auth_key"); legacyPassword = null
                if (body.has("password_wrap")) passwordWrap = body.getString("password_wrap")
                return JSONObject()
            }
            override fun credentials(body: JSONObject): JSONObject {
                bodies += body
                if (body.has("password") && body.optString("password").isNotEmpty() && upgraded) err(426, "请把回笺更新到最新版")
                if (hasPassword) checkCurrent(body)
                username = body.getString("username")
                if (!hasPassword) { legacyPassword = body.getString("password"); hasPassword = true }
                return JSONObject().put("account", JSONObject().put("username", username))
            }
            override fun createPairCodeRaw(keyWrap: String?): JSONObject {
                val code = "%06d".format(100000 + pairCodes.size)
                pairCodes[code] = keyWrap.orEmpty()
                return JSONObject().put("code", code).put("expires_in", 180)
            }
            override fun pairRaw(body: JSONObject): JSONObject {
                bodies += body
                val wrap = pairCodes.remove(body.getString("code")) ?: err(403, "配对码无效或已过期")
                val name = body.optString("name")
                return JSONObject().put("device_id", "d_$name").put("name", name).put("token", "d_$name")
                    .apply { if (wrap.isNotEmpty()) put("key_wrap", wrap) }
            }
        }

        /** 管理员在后台用原文重设密码：账号回到旧协议，密码副本作废 */
        fun adminReset(pw: String) { legacyPassword = pw; authKey = ""; authSalt = ""; passwordWrap = "" }
    }

    private val server = "https://push.example.com"
    private val c = FakeCrypto()
    private val flags = Flags()
    /** 已登录时本机知道的情况（E2EHub.known） */
    private var known = Known()
    private val logic = E2ELogic(c, flags) { known }
    private val s = FakeServer(c)

    private inline fun expectE2E(text: String? = null, kind: E2EError.Kind? = null, block: () -> Unit): E2EError {
        try { block() } catch (e: E2EError) {
            text?.let { assertEquals(it, e.message) }
            kind?.let { assertEquals(it, e.kind) }
            return e
        }
        fail("应当失败"); throw AssertionError()
    }

    private fun login(pw: String, name: String = "phone") =
        logic.login(s.net("?"), server, "Alice", pw, name, "fp") { tok -> s.net(tok.removePrefix("tok-")) }

    /** 一个已升级、已开启加密的账号，密码 good-password-1 */
    private fun enabledAccount(): LocalKey {
        login("old-password", "mac")
        return logic.setup(s.net("d_mac"), server, "alice", "old-password", "good-password-1").key
    }

    // ---------- 配对码带钥匙（§12） ----------

    @Test fun pairCodeCarriesKey() {
        val key = enabledAccount()
        val st = E2EState.parse(s.net("d_mac").e2eState())
        // 本机有 active 钥匙的私钥才带钥匙；没有（没解锁、只有别的钥匙）时不带
        assertEquals(key.sk, logic.activeSecretKey(listOf("skX", key.sk), st))
        assertNull(logic.activeSecretKey(emptyList(), st))
        assertNull(logic.activeSecretKey(listOf("skX"), st))
        assertNull(logic.activeSecretKey(listOf(key.sk), null))

        val (code, ttl, secret) = logic.createPairCode(s.net("d_mac"), key.sk, supportsKey = true)
        assertEquals(180, ttl); assertNotNull(secret)
        val o = logic.pair(s.net("?"), code, secret, "phone", "fp9") { s.net(it) }
        assertEquals(key, o.keys.single()); assertNull(o.notice)
        // 一次性钥匙不发给服务器
        assertTrue(s.bodies.last().toString().let { !it.contains(secret!!) && it.contains(code) })
        // 只能用一次
        try { logic.pair(s.net("?"), code, secret, "again", "fp8") { s.net(it) }; fail() } catch (e: ApiException) { assertEquals(403, e.status) }
    }

    @Test fun pairCodeKeyProblems() {
        val key = enabledAccount()
        // 一次性钥匙不对：登录成功、不解锁、T82
        val (c1, _, _) = logic.createPairCode(s.net("d_mac"), key.sk, supportsKey = true)
        logic.pair(s.net("?"), c1, "SECRET-999", "p1", "f1") { s.net(it) }.let { assertTrue(it.keys.isEmpty()); assertEquals(E2EText.T82, it.notice) }
        // 服务端不支持 / 本机没解锁：不带钥匙；新设备却有一次性钥匙 → T83
        val (c2, _, s2) = logic.createPairCode(s.net("d_mac"), key.sk, supportsKey = false)
        assertNull(s2)
        logic.pair(s.net("?"), c2, "SECRET-1", "p2", "f2") { s.net(it) }.let { assertTrue(it.keys.isEmpty()); assertEquals(E2EText.T83, it.notice) }
        // 只输 6 位：照旧锁定、不提示
        val (c3, _, s3) = logic.createPairCode(s.net("d_mac"), key.sk, supportsKey = true)
        logic.pair(s.net("?"), c3, null, "p3", "f3") { s.net(it) }.let { assertTrue(it.keys.isEmpty()); assertNull(it.notice) }
        // 服务器给新设备看的 active 钥匙不是锁在配对码里的那把（被攻破的服务器把新设备登进别的账号）：T43，不保存
        val (c4, _, s4) = logic.createPairCode(s.net("d_mac"), key.sk, supportsKey = true)
        s.fakeKeysFor["d_p4"] = listOf(E2EKeyInfo("kidX", "pubX", true))
        logic.pair(s.net("?"), c4, s4, "p4", "f4") { s.net(it) }.let { assertTrue(it.keys.isEmpty()); assertEquals(E2EText.T43, it.notice) }
        // 取不到加密状态（断网）：不保存，提示用密码解锁
        val (c5, _, s5) = logic.createPairCode(s.net("d_mac"), key.sk, supportsKey = true)
        val down = { _: String -> object : E2ENet by s.net("?") { override fun e2eState(): JSONObject = throw java.io.IOException("断网") } }
        logic.pair(s.net("?"), c5, s5, "p5", "f5", down).let { assertTrue(it.keys.isEmpty()); assertEquals(E2EText.PAIR_NO_STATE, it.notice) }
        assertNotNull(s3)
    }

    // ---------- 登录（§2.1） ----------

    @Test fun argonParamsTamperedRejected() {
        login("old-password")       // 升级到 argon
        for (bad in listOf(
            JSONObject().put("time", 2), JSONObject().put("memory_kib", 1024), JSONObject().put("lanes", 4),
            JSONObject().put("salt", "ab".repeat(8)), JSONObject().put("salt", "zz".repeat(16)),
        )) {
            val o = JSONObject().put("kdf", "argon2id").put("salt", s.authSalt).put("time", 3).put("memory_kib", 65536).put("lanes", 1)
            for (k in bad.keys()) o.put(k, bad.get(k))
            s.preloginOverride = o
            expectE2E(E2EText.T2) { login("old-password") }
        }
        s.preloginOverride = JSONObject().put("kdf", "scrypt")
        expectE2E(E2EText.T2) { login("old-password") }
    }

    @Test fun upgradedAccountRefusesPbkdf2AndOldServer() {
        flags.markUpgraded(server, "alice")
        expectE2E(E2EText.T1) { login("old-password") }           // 服务器谎称还是旧账号
        s.oldServer = true
        expectE2E(E2EText.T1) { login("old-password") }           // 服务器谎称没有 e2e 功能
        assertTrue(s.bodies.isEmpty())                             // 一个登录请求都没发出去
    }

    @Test fun legacyServerSendsPasswordOnlyWhenNeverUpgraded() {
        s.oldServer = true
        val o = login("old-password")
        assertEquals("tok-d_phone", o.result.token)
        assertEquals("old-password", s.bodies.single().optString("password"))
        assertFalse(o.upgraded)
    }

    @Test fun weakPbkdf2Rejected() {
        s.iterations = 1000
        expectE2E(E2EText.T2) { login("old-password") }
    }

    @Test fun pbkdf2LoginAutoUpgradesAndNeverSendsPassword() {
        val o = login("old-password")
        assertTrue(o.upgraded)
        assertTrue(s.upgraded)
        assertTrue(flags.isUpgraded(server, "ALICE "))               // 用户名不区分大小写
        assertTrue(s.bodies.none { it.has("password") || it.has("current_password") })
        // 升级后：同一个密码用 argon 登录
        s.bodies.clear()
        val again = login("old-password")
        assertTrue(s.bodies.single().has("auth_key"))
        assertTrue(again.keys.isEmpty())
        // 密码不对：服务端 403，显示服务端的说明
        try { login("wrong-password"); fail() } catch (e: ApiException) { assertEquals(403, e.status) }
    }

    @Test fun pbkdf2LoginWithEncryptionEnabledDoesNotUpgrade() {
        enabledAccount()
        s.adminReset("reset-by-admin")
        flags.set.clear()           // 另一台从没升级过的设备
        val o = login("reset-by-admin", "pad")
        assertFalse(o.upgraded)
        assertFalse(s.upgraded)
        assertTrue(o.keys.isEmpty())
    }

    @Test fun argonLoginUnlocksAndVerifiesKey() {
        val key = enabledAccount()
        val o = login("good-password-1", "pad")
        assertEquals(listOf(key), o.keys)
        assertNull(o.notice)
        // 服务器塞来一把不是账号钥匙的私钥：丢弃并提示 T43，但不阻止登录
        s.passwordWrap = c.wrap("hjp1", "unlock:good-password-1:${s.authSalt}", "sk999")
        val bad = login("good-password-1", "pad")
        assertTrue(bad.keys.isEmpty()); assertEquals(E2EText.T43, bad.notice)
        // 副本解不开（管理员重设过）：进入已锁定，不提示
        s.passwordWrap = c.wrap("hjp1", "other", key.sk)
        val locked = login("good-password-1", "pad")
        assertTrue(locked.keys.isEmpty()); assertNull(locked.notice)
    }

    // ---------- 注册（§2.2） ----------

    @Test fun registerChecksStrengthAndUsesNewProtocol() {
        s.authKey = ""; s.legacyPassword = null
        s.preloginOverride = JSONObject().put("kdf", "argon2id").put("salt", "cd".repeat(16)).put("time", 3).put("memory_kib", 65536).put("lanes", 1)
        expectE2E("密码太短", E2EError.Kind.WEAK_PASSWORD) { logic.register(s.net("?"), server, "bob", "short", "phone", "fp") }
        val o = logic.register(s.net("?"), server, "bob", "long-enough-pw", "phone", "fp")
        val b = s.bodies.single()
        assertFalse(b.has("password")); assertTrue(b.has("auth_key")); assertEquals(32, b.getString("auth_salt").length)
        assertTrue(o.upgraded); assertTrue(flags.isUpgraded(server, "Bob"))
    }

    /**
     * 注册即开启加密（服务端 0.9.0，register.e2e）：本机生成钥匙随注册一起提交（和 /v1/e2e/setup 同样的字段），
     * 不带恢复码、不发密码原文；返回的 keys 里就是这把，作为「本机生成」的钥匙交给调用方，不再自动开启
     */
    @Test fun registerWithKeysEnablesE2E() {
        s.authKey = ""; s.legacyPassword = null; s.registerE2E = true
        // 旧方式（不带钥匙）被 0.9.0 服务端拒绝：400，说明原样抛出
        try { logic.register(s.net("?"), server, "bob", "long-enough-pw", "phone", "fp"); fail("应返回 400") }
        catch (e: ApiException) { assertEquals(400, e.status); assertTrue(e.message!!.contains("更新")) }
        assertFalse(s.enabled)
        expectE2E("密码太短", E2EError.Kind.WEAK_PASSWORD) { logic.register(s.net("?"), server, "bob", "short", "phone", "fp", withKeys = true) }
        val o = logic.register(s.net("?"), server, "bob", "long-enough-pw", "phone", "fp", inviteCode = "", withKeys = true)
        val b = s.bodies.last()
        assertFalse(b.has("password")); assertFalse(b.has("recovery_wrap")); assertFalse(b.has("invite_code"))
        assertEquals(32, b.getString("auth_salt").length)
        val k = o.keys.single()
        assertEquals(b.getString("pub"), k.pub)
        assertTrue(b.getString("password_wrap").startsWith("hjp1|")); assertTrue(b.getString("password_wrap").endsWith("|" + k.sk))
        assertTrue(o.upgraded); assertTrue(flags.isUpgraded(server, "bob"))
        // 服务器已经用这把开启了加密：之后用密码登录能解开同一把
        assertTrue(s.enabled); assertEquals(k.pub, s.keys.single { it.active }.pub)
        assertEquals(k, logic.login(s.net("?"), server, "bob", "long-enough-pw", "pad", "fp2") { s.net(it) }.keys.single())
    }

    /** 注册即开启加密：服务器回的 active 钥匙不是本机这把 → 不保存，提示 T43（本机进入锁定） */
    @Test fun registerWithKeysRejectsForeignKey() {
        s.authKey = ""; s.legacyPassword = null; s.registerE2E = true
        val net = object : E2ENet by s.net("?") {
            override fun loginRaw(body: JSONObject, register: Boolean): JSONObject = s.net("?").loginRaw(body, register).also {
                it.put("e2e", JSONObject().put("enabled", true).put("keys", JSONArray().put(JSONObject().put("kid", "kidX").put("pub", "pubX").put("active", true))))
            }
        }
        val o = logic.register(net, server, "bob", "long-enough-pw", "phone", "fp", withKeys = true)
        assertTrue(o.keys.isEmpty()); assertEquals(E2EText.T43, o.notice)
    }

    /** 注册即开启加密：响应里没有 keys（e2e 缺省）时照样用本机生成的那把（服务器在同一事务里存了它） */
    @Test fun registerWithKeysWithoutKeysInResponse() {
        s.authKey = ""; s.legacyPassword = null; s.registerE2E = true
        val net = object : E2ENet by s.net("?") {
            override fun loginRaw(body: JSONObject, register: Boolean): JSONObject = s.net("?").loginRaw(body, register).also { it.remove("e2e") }
        }
        val o = logic.register(net, server, "bob", "long-enough-pw", "phone", "fp", withKeys = true)
        val k = o.keys.single()
        assertEquals(s.bodies.last().getString("pub"), k.pub); assertEquals(k.pub, s.keys.single { it.active }.pub)
        assertNull(o.notice)
    }

    /**
     * 注册请求到了服务器、账号建好了，响应却丢了（超时 / 断网，不是 ApiException）：提示「结果不确定，先登录」；
     * 之后用密码登录，解开的就是注册时本机生成的那把（LoginOutcome.keys，afterLogin 以可信来源保存）
     */
    @Test fun registerUnsureThenLoginUnlocksSameKey() {
        s.authKey = ""; s.legacyPassword = null; s.registerE2E = true
        val lost = object : E2ENet by s.net("?") {
            override fun loginRaw(body: JSONObject, register: Boolean): JSONObject {
                s.net("?").loginRaw(body, register)
                throw java.net.SocketTimeoutException("timeout")
            }
        }
        val e = try { logic.register(lost, server, "bob", "long-enough-pw", "phone", "fp", withKeys = true); null } catch (x: Exception) { x }
        assertTrue(e is java.io.IOException && e !is ApiException)
        assertEquals(E2EText.REGISTER_UNSURE to true, logic.registerError(e!!, unsureBefore = false))
        val sent = s.bodies.last().getString("pub")
        assertTrue(s.enabled); assertEquals(sent, s.keys.single { it.active }.pub)
        val o = logic.login(s.net("?"), server, "bob", "long-enough-pw", "phone", "fp") { s.net(it) }
        assertEquals(sent, o.keys.single().pub)
        assertNull(o.notice)
    }

    /** 注册失败时的提示：不确定之后再被拒（409 / 403）→ 提示去登录；连不上服务器不改变「不确定」；其他照服务器说明 */
    @Test fun registerErrorMessages() {
        assertEquals(E2EText.REGISTER_UNSURE to true, logic.registerError(java.net.SocketTimeoutException("t"), false))
        assertEquals(E2EText.REGISTER_UNSURE to true, logic.registerError(java.io.IOException("reset"), true))
        assertEquals("这个用户名已被使用" to false, logic.registerError(ApiException(409, "这个用户名已被使用"), false))
        val (m409, u409) = logic.registerError(ApiException(409, "这个用户名已被使用"), true)
        assertTrue(u409); assertTrue(m409!!.startsWith("这个用户名已被使用。")); assertTrue(m409.endsWith(E2EText.REGISTER_MAYBE_DONE))
        val (m403, _) = logic.registerError(ApiException(403, "邀请码已用完"), true)
        assertTrue(m403!!.contains("邀请码已用完") && m403.contains(E2EText.REGISTER_MAYBE_DONE))
        assertEquals("用户名不合法" to false, logic.registerError(ApiException(400, "用户名不合法"), true))
        assertEquals("连不上服务器" to true, logic.registerError(java.net.ConnectException("refused"), true))
        assertEquals("连不上服务器" to false, logic.registerError(java.net.ConnectException("refused"), false))
        // 限速、本地检查：保持「上次是否不确定」
        assertEquals("密码太短" to true, logic.registerError(E2EError("密码太短", E2EError.Kind.WEAK_PASSWORD), true))
        assertEquals("密码太短" to false, logic.registerError(E2EError("密码太短", E2EError.Kind.WEAK_PASSWORD), false))
        assertEquals("尝试太频繁，请稍后再试" to true, logic.registerError(ApiException(429, "尝试太频繁，请稍后再试"), true))
        assertEquals("尝试太频繁，请稍后再试" to false, logic.registerError(ApiException(429, "尝试太频繁，请稍后再试"), false))
        // 不确定 → 429 → 409：仍提示去登录
        val afterLimit = logic.registerError(ApiException(429, "尝试太频繁，请稍后再试"), true).second
        assertTrue(logic.registerError(ApiException(409, "这个用户名已被使用"), afterLimit).first!!.endsWith(E2EText.REGISTER_MAYBE_DONE))
        // 网关 5xx（反向代理等不到回应）：结果不确定；服务端自己回的 500「注册失败」是明确失败
        for (code in listOf(502, 503, 504)) assertEquals("$code", E2EText.REGISTER_UNSURE to true, logic.registerError(ApiException(code, "Bad Gateway"), false))
        assertEquals("注册失败" to false, logic.registerError(ApiException(500, "注册失败"), false))
        assertEquals("注册失败" to false, logic.registerError(ApiException(500, "注册失败"), true))
        // 拼接：「<服务端说明>。」+ REGISTER_MAYBE_DONE
        assertEquals("这个用户名已被使用。上次注册可能已经成功，请改用登录，用这个用户名和密码登录", m409)
    }

    /** 注册一律不发密码原文：没有 prelogin 的旧服务端（0.6 及以前）提示先升级服务端，不发请求 */
    @Test fun registerRefusesLegacyServer() {
        s.oldServer = true
        val n = s.bodies.size
        expectE2E(E2EText.REGISTER_OLD_SERVER) { logic.register(s.net("?"), server, "bob", "long-enough-pw", "phone", "fp") }
        assertEquals(n, s.bodies.size)
        // 登录的旧路径不变
        assertEquals("old-password", login("old-password").let { s.bodies.last().optString("password") })
    }

    /** 注册要邀请码（服务端 0.9.0）：带上去掉首尾空白的 invite_code，空的不带；被拒时服务端的 403 说明原样抛出 */
    @Test fun registerSendsInviteCode() {
        s.authKey = ""; s.legacyPassword = null
        s.preloginOverride = JSONObject().put("kdf", "argon2id").put("salt", "cd".repeat(16)).put("time", 3).put("memory_kib", 65536).put("lanes", 1)
        s.inviteCode = "HJ-1234"
        try {
            logic.register(s.net("?"), server, "bob", "long-enough-pw", "phone", "fp", inviteCode = "wrong")
            fail("邀请码不对应当被拒")
        } catch (e: ApiException) {
            assertEquals(403, e.status); assertEquals("邀请码不对或已经用完，请向服务器管理员索取新的", e.message)
        }
        assertEquals("wrong", s.bodies.last().getString("invite_code"))
        logic.register(s.net("?"), server, "bob", "long-enough-pw", "phone", "fp", inviteCode = "  HJ-1234 ")
        assertEquals("HJ-1234", s.bodies.last().getString("invite_code"))
        // 不要邀请码时不带这个字段
        s.inviteCode = null
        logic.register(s.net("?"), server, "carol", "long-enough-pw", "phone", "fp")
        assertFalse(s.bodies.last().has("invite_code"))
        logic.register(s.net("?"), server, "dave", "long-enough-pw", "phone", "fp", inviteCode = "   ")
        assertFalse(s.bodies.last().has("invite_code"))
    }

    // ---------- 开启加密（§4.1） ----------

    @Test fun setupRequiresStrongPasswordAndReturnsRecoveryCode() {
        login("old-password", "mac")
        expectE2E(kind = E2EError.Kind.WEAK_CURRENT) { logic.setup(s.net("d_mac"), server, "alice", "old-password", null) }
        expectE2E(kind = E2EError.Kind.WEAK_PASSWORD) { logic.setup(s.net("d_mac"), server, "alice", "old-password", "short") }
        expectE2E(E2EText.T3, E2EError.Kind.WRONG_PASSWORD) { logic.setup(s.net("d_mac"), server, "alice", "wrong-pass", "good-password-1") }
        val r = logic.setup(s.net("d_mac"), server, "alice", "old-password", "good-password-1")
        assertTrue(s.enabled)
        assertEquals(r.key.pub, s.keys.single().pub)
        assertTrue(r.recoveryCode.startsWith("CODE-"))
        assertEquals(E2EStatus.UNLOCKED, logic.status(E2EState.parse(s.net("d_mac").e2eState()), listOf(r.key)))
        assertEquals(E2EStatus.LOCKED, logic.status(E2EState.parse(s.net("d_mac").e2eState()), emptyList()))
        expectE2E(kind = E2EError.Kind.CONFLICT) { logic.setup(s.net("d_mac"), server, "alice", "good-password-1", "good-password-2") }
    }

    // ---------- 解锁（§4.2、§4.4） ----------

    @Test fun unlockWithPassword() {
        val key = enabledAccount()
        expectE2E(E2EText.T3, E2EError.Kind.WRONG_PASSWORD) { logic.unlockWithPassword(s.net("d_pad"), server, "alice", "nope-nope-nope") }
        assertEquals(key, logic.unlockWithPassword(s.net("d_pad"), server, "alice", "good-password-1"))
        // 管理员重设后：账号回到旧协议，密码副本失效 → 引导用另外两种方式（已升级标记下会先被 T1 拦住）
        s.adminReset("reset-by-admin")
        flags.set.clear()
        expectE2E(kind = E2EError.Kind.WRAP_INVALID) { logic.unlockWithPassword(s.net("d_pad"), server, "alice", "reset-by-admin") }
    }

    @Test fun unlockWithRecoveryThenResetPassword() {
        val key = enabledAccount()
        val code = "CODE-" + s.recoveryWrap.split("|")[1].removePrefix("rk")
        expectE2E("恢复码格式不对：应为 26 位字母和数字") { logic.unlockWithRecovery(s.net("d_pad"), "garbage") }
        expectE2E(E2EText.T41) { logic.unlockWithRecovery(s.net("d_pad"), "CODE-12345") }
        s.adminReset("reset-by-admin")
        val (k, st) = logic.unlockWithRecovery(s.net("d_pad"), code)
        assertEquals(key, k)
        assertTrue(st.needsNewPassword)
        // 重新设置密码：当前密码是管理员重设的（旧协议，pbkdf2），新密码锁住本机私钥。
        // 本机标记了「已升级」：只有这一页允许走 pbkdf2，其他地方（改密码、用密码解锁）仍按 T1 拒绝
        assertTrue(flags.isUpgraded(server, "alice"))
        expectE2E(E2EText.T1) { logic.setPassword(s.net("d_pad"), server, "alice", "reset-by-admin", "brand-new-pass", true, k.sk) }
        expectE2E(E2EText.T44) { logic.unlockWithPassword(s.net("d_pad"), server, "alice", "reset-by-admin") }   // 解锁时是 T44
        expectE2E(kind = E2EError.Kind.WEAK_PASSWORD) {
            logic.setPassword(s.net("d_pad"), server, "alice", "reset-by-admin", "short", true, k.sk, afterAdminReset = true)
        }
        logic.setPassword(s.net("d_pad"), server, "alice", "reset-by-admin", "brand-new-pass", true, k.sk, afterAdminReset = true)
        val after = E2EState.parse(s.net("d_pad").e2eState())
        assertFalse(after.needsNewPassword)
        assertEquals(key, logic.unlockWithPassword(s.net("d_x"), server, "alice", "brand-new-pass"))
        // 已开启加密、本机锁定时不能改密码
        expectE2E(E2EText.LOCKED_CHANGE) { logic.setPassword(s.net("d_pad"), server, "alice", "brand-new-pass", "another-pass-1", true, null) }
    }

    @Test fun rotateRecovery() {
        val key = enabledAccount()
        val old = s.recoveryWrap
        expectE2E(E2EText.T3) { logic.rotateRecovery(s.net("d_mac"), server, "alice", "wrong", key.sk) }
        val code = logic.rotateRecovery(s.net("d_mac"), server, "alice", "good-password-1", key.sk)
        assertNotEquals(old, s.recoveryWrap)
        assertEquals(key, logic.unlockWithRecovery(s.net("d_pad"), code).first)
    }

    @Test fun rotateRecoveryFailureAndUnsureResult() {
        val key = enabledAccount()
        val net = s.net("d_mac")
        // 4xx（当前密码不对）：新恢复码已在发请求前交给调用方保存，请求失败照常抛出（调用方删除）
        var gen: RecoveryRotation? = null
        expectE2E(E2EText.T3) { logic.rotateRecovery(net, server, "alice", "wrong-password", key.sk) { gen = it } }
        assertTrue(gen != null && gen!!.wrap != s.recoveryWrap)
        // 服务器换成了但响应丢了：GET 核对 recovery_wrap 等于这次上传的 → 成功
        val lost = object : E2ENet by net {
            override fun e2eRecovery(body: JSONObject) { net.e2eRecovery(body); throw java.io.IOException("连接被重置") }
        }
        var r1: RecoveryRotation? = null
        val code = logic.rotateRecovery(lost, server, "alice", "good-password-1", key.sk) { r1 = it }
        assertEquals(r1!!.code, code); assertEquals(r1!!.wrap, s.recoveryWrap)
        // 请求没到服务器：核对后不等 → ROTATE_RETRY（调用方删除，旧恢复码仍然有效）
        val dropped = object : E2ENet by net {
            override fun e2eRecovery(body: JSONObject) { throw java.io.IOException("断网") }
        }
        expectE2E(E2EText.ROTATE_RETRY) { logic.rotateRecovery(dropped, server, "alice", "good-password-1", key.sk) }
        assertEquals(r1!!.wrap, s.recoveryWrap)
        // 结果不明（核对也读不到）：ROTATE_UNSURE，调用方保留；之后刷新时 recovery_wrap 等于这次上传的就当作成功
        var down = false
        val flaky = object : E2ENet by net {
            override fun e2eRecovery(body: JSONObject) { net.e2eRecovery(body); down = true; throw java.io.IOException("断网") }
            override fun e2eState(): JSONObject = if (down) throw java.io.IOException("断网") else net.e2eState()
        }
        var r2: RecoveryRotation? = null
        expectE2E(E2EText.ROTATE_UNSURE, E2EError.Kind.SETUP_UNSURE) {
            logic.rotateRecovery(flaky, server, "alice", "good-password-1", key.sk) { r2 = it }
        }
        val st = E2EState.parse(net.e2eState())
        assertTrue(logic.rotationDone(st, r2!!))
        assertFalse(logic.rotationDone(st, r1!!))
    }

    // ---------- 批准（§4.3、§5） ----------

    /** 批准设备用本机私钥算出的账号公钥 */
    private fun accPub() = s.keys.first { it.active }.pub

    private fun pair(name: String) { s.devs["d_$name"] = FakeServer.Dev(name = name) }

    @Test fun approvalFlowCodesMatch() {
        val key = enabledAccount()
        pair("pad")
        val b = DeviceRequest(c, logic, c.keypair(), null)
        b.start(s.net("d_pad"))
        assertEquals(DeviceRequest.Step.Waiting, b.step(s.net("d_pad")).first)

        val reqs = E2EState.parse(s.net("d_mac").e2eState()).requests
        assertEquals("pad", reqs.single().name)
        val a = Approval(c, "d_pad", "pad", accPub())
        a.begin(s.net("d_mac"))
        assertEquals(Approval.Stage.Waiting, a.step(s.net("d_mac")).first)    // 对方还没揭晓
        val codeB = (b.step(s.net("d_pad")).first as DeviceRequest.Step.Code).code
        val codeA = (a.step(s.net("d_mac")).first as Approval.Stage.Code).code
        assertEquals(codeA, codeB)
        assertEquals(DeviceRequest.Step.Code(codeB), b.step(s.net("d_pad")).first)   // 再查一次仍是同一个核对码
        a.approve(s.net("d_mac"), key.sk)
        val done = b.step(s.net("d_pad")).first as DeviceRequest.Step.Unlocked
        assertEquals(key, done.key)
        assertFalse(b.active)
    }

    @Test fun commitMismatchDeniesAutomatically() {
        enabledAccount()
        pair("pad")
        val b = DeviceRequest(c, logic, c.keypair(), null)
        b.start(s.net("d_pad"))
        val a = Approval(c, "d_pad", "pad", accPub())
        a.begin(s.net("d_mac"))
        b.step(s.net("d_pad"))                      // 揭晓
        s.tamperReveal = "r-forged"                 // 服务器冒充新设备，换了揭晓的随机数
        assertEquals(Approval.Stage.Failed(E2EText.T52), a.step(s.net("d_mac")).first)
        s.tamperReveal = null
        assertFalse(s.devs["d_pad"]!!.requested)    // 已经自动拒绝
        assertEquals(DeviceRequest.Step.Denied, b.step(s.net("d_pad")).first)
    }

    @Test fun challengeTakenByAnotherDevice() {
        enabledAccount()
        pair("pad")
        DeviceRequest(c, logic, c.keypair(), null).start(s.net("d_pad"))
        Approval(c, "d_pad", "pad", accPub()).begin(s.net("d_mac"))
        val other = Approval(c, "d_pad", "pad", accPub())
        expectE2E(E2EText.T51) { other.begin(s.net("d_phone")) }
        assertEquals(Approval.Stage.Failed(E2EText.T51), other.stage)
    }

    @Test fun challengeChangedAfterRevealRestarts() {
        enabledAccount()
        pair("pad")
        val b = DeviceRequest(c, logic, c.keypair(), null)
        b.start(s.net("d_pad"))
        val firstCommit = s.devs["d_pad"]!!.commit
        Approval(c, "d_pad", "pad", accPub()).begin(s.net("d_mac"))
        assertTrue(b.step(s.net("d_pad")).first is DeviceRequest.Step.Code)
        s.devs["d_pad"]!!.na = "r-other"           // 对方（或服务器）换了 challenge
        assertEquals(DeviceRequest.Step.Waiting, b.step(s.net("d_pad")).first)
        val d = s.devs["d_pad"]!!
        assertNotEquals(firstCommit, d.commit)      // 新的 nb、重新登记
        assertTrue(d.requested); assertEquals("", d.na)
    }

    @Test fun grantForWrongKeyIsDiscarded() {
        enabledAccount()
        pair("pad")
        val b = DeviceRequest(c, logic, c.keypair(), null)
        b.start(s.net("d_pad"))
        val a = Approval(c, "d_pad", "pad", accPub())
        a.begin(s.net("d_mac")); b.step(s.net("d_pad")); a.step(s.net("d_mac"))
        // 不是账号钥匙（和承诺里的 acc 对不上）。正常的批准方会带 kid，被服务器拒绝（409）；这里模拟不带 kid 的转交
        val padPub = s.devs["d_pad"]!!.pub
        s.net("d_mac").e2eGrant("d_pad", padPub, c.grantSeal("sk777", padPub), "")
        // 停在明确的失败状态（显示 T43 和「重新请求」），不会一直等
        assertEquals(DeviceRequest.Step.Failed(E2EText.T43), b.step(s.net("d_pad")).first)
        assertFalse(b.active)
        // 解不开的转交同样结束
        val b2 = DeviceRequest(c, logic, c.keypair(), null)
        b2.start(s.net("d_pad"))
        val a2 = Approval(c, "d_pad", "pad", accPub())
        a2.begin(s.net("d_mac")); b2.step(s.net("d_pad")); a2.step(s.net("d_mac"))
        s.devs["d_pad"]!!.grant = "garbage"
        assertEquals(DeviceRequest.Step.Failed(E2EText.GRANT_BAD), b2.step(s.net("d_pad")).first)
    }

    @Test fun grantBeforeRevealIsIgnored() {
        val key = enabledAccount()
        pair("pad")
        val dev = c.keypair()
        val b = DeviceRequest(c, logic, dev, null)
        b.start(s.net("d_pad"))
        // 服务器在揭晓之前伪造一份转交（谁都能加密给 dev.pub），带着账号真的私钥也不接受
        s.devs["d_pad"]!!.grant = c.grantSeal(key.sk, dev.pub)
        assertEquals(DeviceRequest.Step.Waiting, b.step(s.net("d_pad")).first)
        assertTrue(b.active)
        // 伪造一份转交并把请求标成结束：当作被拒绝，不会解锁
        s.devs["d_pad"]!!.grant = c.grantSeal("sk999", dev.pub); s.devs["d_pad"]!!.requested = false
        assertEquals(DeviceRequest.Step.Denied, b.step(s.net("d_pad")).first)
    }

    @Test fun fakeAccountKeyBreaksCommit() {
        enabledAccount()
        pair("pad")
        // 被攻破的服务器给新设备看自己的公钥：新设备把它写进承诺，批准设备用自己算出的公钥核对，对不上 → 自动拒绝 T52
        s.fakeKeysFor["d_pad"] = listOf(E2EKeyInfo("kid999", "pub999", true))
        val b = DeviceRequest(c, logic, c.keypair(), null)
        b.start(s.net("d_pad"))
        assertTrue(s.devs["d_pad"]!!.commit.contains(":pub999:"))
        val a = Approval(c, "d_pad", "pad", accPub())
        a.begin(s.net("d_mac"))
        assertTrue(b.step(s.net("d_pad")).first is DeviceRequest.Step.Code)       // 新设备揭晓（服务器照单全收）
        assertEquals(Approval.Stage.Failed(E2EText.T52), a.step(s.net("d_mac")).first)
        assertFalse(s.devs["d_pad"]!!.requested)
    }

    @Test fun pinnedKeyMustMatch() {
        val key = enabledAccount()
        val st = E2EState.parse(s.net("d_mac").e2eState())
        // 钉住的公钥不是服务器启用中的钥匙（别的设备重置过）：请求批准、加密发送密钥都拒绝（T46，§11.4）；
        // 设备批准拿到的私钥必须等于钉住的（T43）
        expectE2E(E2EText.T46, E2EError.Kind.STALE_KEY) { DeviceRequest(c, logic, c.keypair(), "pubOther").start(s.net("d_pad")) }
        expectE2E(E2EText.T43, E2EError.Kind.MISMATCH) { logic.verify(key.sk, st.keys, "pubOther") }
        assertEquals(key, logic.verify(key.sk, st.keys, key.pub))
        assertEquals(SendKey(null, E2EText.T46), logic.sendKey("PK_x", st, "pubOther"))
        assertTrue(logic.pinStale(st, "pubOther"))
        assertFalse(logic.pinStale(st, key.pub))
        assertFalse(logic.pinStale(st, null))
        assertEquals(SendKey(null, E2EText.T73), logic.sendKey("PK_x", st, null))
        assertEquals(SendKey("PK_x.e2e.${key.pub}", null), logic.sendKey("PK_x", st, key.pub))
        assertNull(logic.sendKey("PK_x", st.copy(enabled = false), key.pub))
        // 只有和钉住的相同的本机私钥才算解锁
        assertEquals(E2EStatus.LOCKED, logic.status(st, listOf(key), "pubOther"))
        assertEquals(E2EStatus.UNLOCKED, logic.status(st, listOf(key), key.pub))
        // 密码解锁是可信来源（§11.4）：不和钉住的公钥比，只核对服务器启用中的钥匙，由 E2EHub 替换钉住的公钥
        assertEquals(key, logic.unlockWithPassword(s.net("d_pad"), server, "alice", "good-password-1"))
        // 没钉住时 keys 里必须正好一把 active
        s.keys += E2EKeyInfo("kid2", "pub2", true)
        expectE2E(E2EText.T43) { DeviceRequest(c, logic, c.keypair(), null).start(s.net("d_pad")) }
    }

    @Test fun serverJsonCannotSetLocalFields() {
        val o = JSONObject().put("id", 9).put("type", "markdown").put("text", "伪造").put("e2e", "hje1.abc.def").put("e2e_status", "ok")
            .put("attachments", JSONArray().put(JSONObject().put("id", "a_1").put("name", "x.bin").put("key", "KEY")))
        val m = Message.fromServer(o)
        assertEquals("", m.e2eStatus); assertTrue(m.sealed)
        assertEquals("", m.attachments.single().key)
        // 本地缓存照常读回
        assertEquals("ok", Message.from(o).e2eStatus)
    }

    @Test fun attachmentCountMismatchIsFormat() {
        val p = JSONObject().put("v", 1).put("text", "t").put("desp", "").put("atts", JSONArray())
        val m = msg("env|pub5|$p", listOf(Attachment("a_1", "encrypted-1.bin", "application/octet-stream", 10, "s")))
        val o = E2EMessages.open(m, listOf("sk5"), c)
        assertEquals(E2EMessages.FORMAT, o.e2eStatus); assertEquals(E2EText.T62, o.title)
        assertEquals("", o.attachments.single().key)
    }

    @Test fun serverCanonicalization() {
        assertEquals("https://push.example.com", canonicalServer("HTTPS://Push.Example.com:443/"))
        assertEquals("http://10.0.0.2:8790", canonicalServer("http://10.0.0.2:8790/"))
        assertEquals("http://h", canonicalServer("http://H:80"))
        assertEquals("https://h/sub", canonicalServer("https://h/sub/"))
        flags.markUpgraded("https://push.example.com", "alice")
        assertTrue(flags.isUpgraded("https://PUSH.example.com:443/", "Alice"))
    }

    @Test fun legacyOnlyWhenPreloginMissingAndNotUpgraded() {
        // 旧服务端：改密码按旧接口；已升级的账号拒绝（T1）；加密接口直接报错
        s.oldServer = true
        logic.changeCredentials(s.net("d_phone"), server, "alice", "alice", "old-password", "another-pass-1", false, null)
        assertEquals("old-password", s.bodies.last().getString("current_password"))
        expectE2E(E2EText.NO_PRELOGIN) { logic.credential(s.net("d_phone"), server, "alice", "x", E2ELogic.Use.E2E) }
        flags.markUpgraded(server, "alice")
        expectE2E(E2EText.T1) { logic.changeCredentials(s.net("d_phone"), server, "alice", "alice", "old-password", null, false, null) }
        expectE2E(E2EText.T1) { logic.register(s.net("?"), server, "alice", "long-enough-pw", "x", "fp") }
        expectE2E(E2EText.T1) { logic.setInitialPassword(s.net("?"), server, "alice", "long-enough-pw") }
    }

    @Test fun initialPasswordSendsPlainThenUpgrades() {
        // 账号还没有密码（新服务端）：只能发原文，成功后立即升级
        s.hasPassword = false; s.legacyPassword = null
        val pre = logic.setInitialPassword(s.net("d_phone"), server, "alice", "long-enough-pw")!!
        // 返回升级后的凭证，给自动开启加密复用（§11.1）
        assertEquals(s.authSalt, pre.salt); assertEquals(s.authKey, pre.auth)
        assertEquals(c.passwordKeys("long-enough-pw", s.authSalt).second, pre.unlock)
        assertEquals("long-enough-pw", s.bodies.first { it.has("password") }.getString("password"))
        assertTrue(s.upgraded)
        assertTrue(flags.isUpgraded(server, "alice"))
        assertTrue(s.bodies.last().has("current_password_key"))      // 升级时用 PBKDF2 结果核对，不再发原文
        // 本机标记了「已升级」、或服务器说 auth_key 为真：拒绝（T1），什么都不发
        val n = s.bodies.size
        expectE2E(E2EText.T1) { logic.setInitialPassword(s.net("d_phone"), server, "alice", "long-enough-pw") }
        flags.set.clear()
        known = Known(authKey = true)
        expectE2E(E2EText.T1) { logic.setInitialPassword(s.net("d_phone"), server, "bob", "long-enough-pw") }
        known = Known(localUsername = "carol"); flags.markUpgraded(server, "carol")
        expectE2E(E2EText.T1) { logic.setInitialPassword(s.net("d_phone"), server, "bob", "long-enough-pw") }
        assertEquals(n, s.bodies.size)
    }

    @Test fun knownStateBlocksDowngrade() {
        login("old-password")                      // pbkdf2 登录、自动升级
        s.adminReset("x-reset-pw")                  // 服务器又说回到了旧协议（pbkdf2）
        flags.set.clear()
        // 服务器给了另一个用户名（标记查不到），但本机登录时记下的用户名有标记：拒绝
        flags.markUpgraded(server, "alice")
        known = Known(localUsername = "alice")
        expectE2E(E2EText.T1) { logic.credential(s.net("d_phone"), server, "mallory", "x-reset-pw", E2ELogic.Use.E2E) }
        // 没有标记，但 GET /v1/e2e 说 auth_key 为真：同样拒绝 pbkdf2；解锁时显示 T44；只有 T42 页放行
        flags.set.clear()
        known = Known(authKey = true, hasE2E = true)
        expectE2E(E2EText.T1) { logic.credential(s.net("d_phone"), server, "alice", "x-reset-pw", E2ELogic.Use.E2E) }
        expectE2E(E2EText.T1) { logic.changeCredentials(s.net("d_phone"), server, "alice", "alice", "x-reset-pw", null, null, null) }
        expectE2E(E2EText.T44) { logic.unlockWithPassword(s.net("d_phone"), server, "alice", "x-reset-pw") }
        assertEquals("current_password_key", logic.credential(s.net("d_phone"), server, "alice", "x-reset-pw", E2ELogic.Use.RESET).field)
        // 这次运行里读到过 /v1/e2e，prelogin 却是纯文本 404：不发原文
        known = Known(hasE2E = true)
        s.oldServer = true
        val n = s.bodies.size
        expectE2E(E2EText.NO_PRELOGIN) { logic.changeCredentials(s.net("d_phone"), server, "alice", "alice", "x-reset-pw", "another-pass-1", null, null) }
        assertEquals(n, s.bodies.size)
        assertTrue(s.bodies.none { it.has("password") || it.has("current_password") })
    }

    @Test fun changeCredentialsChecksBeforeSending() {
        val key = enabledAccount()
        val n = s.bodies.size
        // 加密状态还没读到（enabled 为 null）、本机锁定：先读状态，发现已开启就拒绝，用户名也不改
        expectE2E(E2EText.LOCKED_CHANGE) {
            logic.changeCredentials(s.net("d_phone"), server, "alice", "alice2", "good-password-1", "another-pass-1", null, null)
        }
        assertEquals(n, s.bodies.size); assertEquals("alice", s.username)
        // 新密码不合格：同样什么都不发
        expectE2E(kind = E2EError.Kind.WEAK_PASSWORD) {
            logic.changeCredentials(s.net("d_phone"), server, "alice", "alice2", "good-password-1", "weak", null, key.sk)
        }
        assertEquals(n, s.bodies.size)
        // 已解锁：改名 + 改密码，新密码重新锁住私钥
        logic.changeCredentials(s.net("d_phone"), server, "alice", "alice2", "good-password-1", "another-pass-1", null, key.sk)
        assertEquals("alice2", s.username)
        assertTrue(s.bodies.last().has("password_wrap"))
    }

    @Test fun setupNetworkErrorKeepsKeysAndConfirms() {
        login("old-password", "mac")
        val net = s.net("d_mac")
        // 服务器其实开启成功了，但响应丢了：核对后当作成功
        val lost = object : E2ENet by net {
            override fun e2eSetup(body: JSONObject): JSONObject { net.e2eSetup(body); throw java.io.IOException("连接被重置") }
        }
        val r = logic.setup(lost, server, "alice", "old-password", "good-password-1")
        assertEquals(r.key.pub, s.keys.single().pub)
        // 取不到状态：钥匙和恢复码留着（SETUP_UNSURE），重试时先核对
        val s2 = FakeServer(c); val f2 = Flags(); val l2 = E2ELogic(c, f2)
        l2.login(s2.net("?"), server, "alice", "old-password", "mac", "fp") { s2.net(it.removePrefix("tok-")) }
        val n2 = s2.net("d_mac")
        var down = false
        val flaky = object : E2ENet by n2 {
            override fun e2eSetup(body: JSONObject): JSONObject { n2.e2eSetup(body); down = true; throw java.io.IOException("断网") }
            override fun e2eState(): JSONObject = if (down) throw java.io.IOException("断网") else n2.e2eState()
        }
        val e = expectE2E(kind = E2EError.Kind.SETUP_UNSURE) { l2.setup(flaky, server, "alice", "old-password", "good-password-1") }
        val pending = e.pending!!
        down = false
        assertEquals(pending, l2.setup(n2, server, "alice", "x", "y", pending))     // 先核对：已经开启成功，直接用
    }

    @Test fun setupKeysSavedBeforeRequestAndCheckedOnRefresh() {
        login("old-password", "mac")
        val net = s.net("d_mac")
        var saved: SetupResult? = null
        var postedBeforeSave = false
        val watch = object : E2ENet by net {
            override fun e2eSetup(body: JSONObject): JSONObject { postedBeforeSave = saved == null; return net.e2eSetup(body) }
        }
        val r = logic.setup(watch, server, "alice", "old-password", "good-password-1", onGenerated = { saved = it })
        assertEquals(r, saved); assertFalse(postedBeforeSave)        // 发请求之前就交给调用方保存了
        // 刷新时核对：active 公钥就是这把 → 完成；不是 → 删除；还没开启 → 保留
        val st = E2EState.parse(net.e2eState())
        assertEquals(E2ELogic.PendingSetup.COMPLETE, logic.pendingSetup(st, r))
        val other = SetupResult(LocalKey("kid9", "pub9", "sk9"), "CODE-9")
        assertEquals(E2ELogic.PendingSetup.DROP, logic.pendingSetup(st, other))
        assertEquals(E2ELogic.PendingSetup.KEEP, logic.pendingSetup(st.copy(enabled = false, keys = emptyList()), other))
    }

    @Test fun abandonedRequestIgnoresLateResults() {
        val key = enabledAccount()
        pair("pad")
        val b = DeviceRequest(c, logic, c.keypair(), null)
        b.start(s.net("d_pad"))
        val a = Approval(c, "d_pad", "pad", accPub())
        a.begin(s.net("d_mac"))
        b.abandon()                                  // 换账号：停掉
        assertEquals(DeviceRequest.Step.Waiting, b.step(s.net("d_pad")).first)
        assertEquals("", s.devs["d_pad"]!!.nb)       // 没有揭晓
        assertFalse(b.active)
        // 停掉之后即使有转交也不接受，再 start 也不会重新激活
        s.devs["d_pad"]!!.grant = c.grantSeal(key.sk, b.dev.pub)
        b.start(s.net("d_pad"))
        assertFalse(b.active)
        assertEquals(DeviceRequest.Step.Waiting, b.step(s.net("d_pad")).first)
    }

    @Test fun cancelRequest() {
        enabledAccount()
        pair("pad")
        val b = DeviceRequest(c, logic, c.keypair(), null)
        b.start(s.net("d_pad"))
        b.cancel(s.net("d_pad"))
        assertFalse(s.devs["d_pad"]!!.requested)
        assertTrue(E2EState.parse(s.net("d_mac").e2eState()).requests.isEmpty())
    }

    // ---------- 用户名、凭证（§2.4、§7.5） ----------

    @Test fun changeUsernameUsesAuthKeyAndMovesFlag() {
        login("old-password")
        logic.changeCredentials(s.net("d_phone"), server, "alice", "alice2", "old-password", null, false, null)
        assertTrue(s.bodies.last().has("current_auth_key"))
        assertEquals("alice2", s.username)
        assertTrue(flags.isUpgraded(server, "alice2"))
    }

    @Test fun credentialFollowsUpgradeFlag() {
        login("old-password")
        s.adminReset("x-reset-pw")                  // 服务器说回到了旧协议
        expectE2E(E2EText.T1) { logic.credential(s.net("d_phone"), server, "alice", "x-reset-pw") }
    }

    // ---------- 收消息（§6.1） ----------

    private fun msg(e2e: String?, atts: List<Attachment> = emptyList()) = Message(
        7, "default", "", 3, if (e2e != null) "e2e" else "markdown", "🔒 加密消息（请把回笺更新到最新版查看）", "", "", Instant.EPOCH, atts, e2e = e2e,
    )

    @Test fun openMessageReplacesContentAndAttachments() {
        val payload = JSONObject().put("v", 1).put("text", "训练完成").put("desp", "**val** 0.2").put("type", "markdown")
            .put("atts", JSONArray().put(JSONObject().put("name", "loss.png").put("mime", "image/png").put("size", 1234).put("key", "K1")))
        val m = msg("env|pub5|$payload", listOf(Attachment("a_1", "encrypted-1.bin", "application/octet-stream", 1300, "abc")))
        val o = E2EMessages.open(m, listOf("sk5"), c)
        assertEquals("训练完成", o.text); assertEquals("**val** 0.2", o.desp); assertEquals("markdown", o.type)
        assertEquals(E2EMessages.OK, o.e2eStatus); assertFalse(o.sealed); assertTrue(o.encrypted)
        val a = o.attachments.single()
        assertEquals(Attachment("a_1", "loss.png", "image/png", 1234, "abc", "K1"), a)
        assertEquals("loss.png", JSONObject(o.doc!!).getJSONArray("atts").getString(0))
        assertEquals("预览：**val** 0.2", o.preview)
        assertEquals(m.e2e, o.e2e)                                // 保留信封原文
        assertEquals(o, E2EMessages.open(o, listOf("sk5"), c))     // 已解开的不再处理
        // 存盘再读回
        assertEquals(o, Message.from(o.toJson()))
    }

    @Test fun textTypeHasNoDoc() {
        val p = JSONObject().put("v", 1).put("text", "t").put("desp", "plain *x*").put("type", "text")
        val o = E2EMessages.open(msg("env|pub5|$p"), listOf("sk5"), c)
        assertNull(o.doc); assertEquals("", o.preview); assertEquals("text", o.type)
    }

    @Test fun sealedMessages() {
        val p = JSONObject().put("v", 1).put("text", "t").put("desp", "")
        val locked = E2EMessages.open(msg("env|pub5|$p"), emptyList(), c)
        assertEquals(E2EText.T60, locked.title); assertEquals("", locked.desp); assertTrue(locked.sealed)
        assertEquals(E2EMessages.LOCKED, locked.e2eStatus)
        assertEquals(E2EText.T61, E2EMessages.open(msg("env|pub9|$p"), listOf("sk5"), c).title)
        assertEquals(E2EText.T62, E2EMessages.open(msg("garbage"), listOf("sk5"), c).title)
        // 解锁后重新解密：sealed 的消息仍带着信封原文
        val again = E2EMessages.open(locked, listOf("sk5"), c)
        assertEquals("t", again.title); assertFalse(again.sealed)
        // 存盘再读回：仍是 sealed、信封还在
        assertEquals(locked, Message.from(locked.toJson()))
        // 明文消息原样返回
        val plain = msg(null)
        assertEquals(plain, E2EMessages.open(plain, listOf("sk5"), c))
        assertFalse(plain.encrypted)
    }

    @Test fun serverMessageParsing() {
        val o = JSONObject().put("id", 9).put("type", "e2e").put("text", "🔒").put("e2e", "hje1.abc.def")
        val m = Message.from(o)
        assertEquals("hje1.abc.def", m.e2e); assertEquals("", m.e2eStatus); assertTrue(m.sealed)
        assertNull(Message.from(JSONObject().put("id", 1)).e2e)
    }

    @Test fun stateParsing() {
        val o = JSONObject("""{"enabled":true,"keys":[{"kid":"k1","pub":"P1","active":false},{"kid":"k2","pub":"P2","active":true}],
            "e2e_only":true,"auth_key":false,"has_password_wrap":true,"recovery_wrap":"hjr1.x",
            "device":{"pub":"D","grant":"","requested":true,"challenge":"na","revealed":false},
            "requests":[{"device_id":"d_1","name":"新手机","platform":"android","pub":"Q","requested_at":5,"commit":"c","challenge":"","reveal":""}]}""")
        val st = E2EState.parse(o)
        // 旧服务端还会给 e2e_only：0.9.0 起客户端没有这个开关，忽略它，照常解析其余字段
        assertEquals("k2", st.activeKey?.kid); assertTrue(st.needsNewPassword)
        assertEquals("na", st.device.challenge); assertEquals("新手机", st.requests.single().name)
        assertEquals(E2EStatus.UNLOCKED, logic.status(st, listOf(LocalKey("k2", "P2", "s"))))
        assertEquals(E2EStatus.LOCKED, logic.status(st, listOf(LocalKey("k1", "P1", "s"))))   // 只有停用的旧钥匙
        assertEquals(E2EStatus.DISABLED, logic.status(st.copy(enabled = false), emptyList()))
        assertEquals(E2EStatus.UNKNOWN, logic.status(null, emptyList()))
    }

    @Test fun e2eChangeKind() {
        val p = Changes.plan(listOf(MsgChange(1, 0, "e2e", null), MsgChange(2, 0, "keys", null)))
        assertEquals(setOf(SettingKind.E2E, SettingKind.KEYS), p.refresh)
    }

    @Test fun purgeKeepsLocalCopies() {
        // purge：服务器删了明文，本机保留；同一批里之后又有普通删除，以删除为准
        val p = Changes.plan(listOf(MsgChange(1, 5, "purge", null), MsgChange(2, 6, "purge", null), MsgChange(3, 6, "delete", null),
            MsgChange(4, 0, "purge", null)))
        assertEquals(setOf(5L), p.purged); assertEquals(setOf(6L), p.deleted); assertFalse(p.isEmpty)
        // 先删后 purge：仍然删除
        assertEquals(emptySet<Long>(), Changes.plan(listOf(MsgChange(1, 7, "delete", null), MsgChange(2, 7, "purge", null))).purged)
    }

    @Test fun reconcileKeepsPlainWhenEncrypted() {
        // §7.4：离线超过 90 天收不到 purge，对账时服务器上找不到的明文消息记为「仅本机保留」，加密消息照常删除
        val local = listOf(msg(null).copy(id = 1), msg("hje1.x").copy(id = 2), msg(null).copy(id = 3))
        val (keep, remove) = Changes.splitPlain(local, setOf(1L, 2L))
        assertEquals(setOf(1L), keep); assertEquals(setOf(2L), remove)
    }

    @Test fun sasFormatting() {
        assertEquals("482 913", E2EText.sasText("482913"))
        assertTrue(E2EText.t31("012345").contains("012 345"))
    }

    // ---------- 默认自动加密（§11） ----------

    /** 自动开启：不生成恢复码、不换密码，复用这次登录算出的 salt / auth / unlock（§11.1） */
    @Test fun autoSetupReusesLoginKeysWithoutRecovery() {
        s.legacyPassword = "good-password-0"
        val o = login("good-password-0")              // pbkdf2 登录、自动升级到 argon，返回这次的凭证
        val pre = o.pre!!
        assertFalse(o.weak)
        assertEquals(s.authSalt, pre.salt); assertEquals(s.authKey, pre.auth)
        val n = s.bodies.size
        var saved: SetupResult? = null
        val r = logic.setup(s.net("d_phone"), server, "alice", "", null, onGenerated = { saved = it }, mode = SetupMode.AUTO, pre = pre)
        assertEquals(r, saved)
        assertEquals(SetupMode.AUTO, r.mode)
        assertEquals("", r.recoveryCode)
        val body = s.bodies.drop(n).single()
        assertFalse(body.has("recovery_wrap"))
        assertEquals(pre.auth, body.getString("current_auth_key"))
        assertEquals(pre.salt, body.getString("auth_salt"))       // 不换密码：salt、auth 不变
        assertEquals(pre.auth, body.getString("auth_key"))
        assertEquals(r.key.sk, c.unwrap("hjp1", pre.unlock, body.getString("password_wrap")))
        assertEquals("", s.recoveryWrap)
        assertTrue(s.keys.single { it.active }.pub == r.key.pub)
        // 之后照样能用这个密码登录、在别的设备上用密码解锁
        assertEquals(r.key, login("good-password-0", "pad").keys.single())
    }

    /** 密码弱也照样自动开启（§11.1 第 5 步，T24 由界面显示）；手动开启仍然要求换掉弱密码 */
    @Test fun autoSetupWithWeakPassword() {
        val o = login("old-password")                 // 「old」开头的在假实现里算常见密码
        assertTrue(o.weak)
        expectE2E(kind = E2EError.Kind.WEAK_CURRENT) { logic.setup(s.net("d_phone"), server, "alice", "old-password", null) }
        val r = logic.setup(s.net("d_phone"), server, "alice", "", null, mode = SetupMode.AUTO, pre = o.pre)
        assertTrue(s.enabled)
        assertEquals(r.key.pub, s.keys.single().pub)
    }

    /** 自动开启遇到 409（别的设备刚开启了）：用这次的凭证按 §4.2 解锁（§11.1 第 4 步） */
    @Test fun autoSetupConflictThenUnlockWithLoginKeys() {
        s.legacyPassword = "good-password-0"
        val phone = login("good-password-0").pre!!
        val mac = login("good-password-0", "mac").pre!!         // 已升级：argon 登录
        val macKey = logic.setup(s.net("d_mac"), server, "alice", "", null, mode = SetupMode.AUTO, pre = mac).key
        expectE2E(kind = E2EError.Kind.CONFLICT) {
            logic.setup(s.net("d_phone"), server, "alice", "", null, mode = SetupMode.AUTO, pre = phone)
        }
        assertEquals(macKey, logic.unlockWithKeys(s.net("d_phone"), phone.auth, phone.unlock))
        // 凭证已经失效（密码在别处改过）：T3
        expectE2E(E2EText.T3, E2EError.Kind.WRONG_PASSWORD) { logic.unlockWithKeys(s.net("d_phone"), "auth:x", phone.unlock) }
    }

    /** 注册成功也返回这次的凭证（注册后自动开启） */
    @Test fun registerReturnsLoginKeys() {
        val o = logic.register(s.net("?"), server, "bob", "long-enough-pw", "phone", "fp")
        val pre = o.pre!!
        assertEquals(s.authSalt, pre.salt); assertEquals(s.authKey, pre.auth)
        assertEquals(c.passwordKeys("long-enough-pw", pre.salt).second, pre.unlock)
    }

    /** 进行中的自动开启结果不明：核对 active 公钥；没开启时可以重新生成 */
    @Test fun autoSetupUnsureThenConfirmed() {
        s.legacyPassword = "good-password-0"
        val pre = login("good-password-0").pre!!
        val base = s.net("d_phone")
        val lost = object : E2ENet by base {
            override fun e2eSetup(body: JSONObject): JSONObject { base.e2eSetup(body); throw java.io.IOException("响应丢了") }
        }
        val r = logic.setup(lost, server, "alice", "", null, mode = SetupMode.AUTO, pre = pre)
        assertEquals(r.key.pub, s.keys.single().pub)
        val st = E2EState.parse(base.e2eState())
        assertEquals(E2ELogic.PendingSetup.COMPLETE, logic.pendingSetup(st, r))
    }

    /** 重置加密（§11.3）：新钥匙启用、旧钥匙停用保留，不生成恢复码、服务器上的旧恢复码作废；需要当前密码 */
    @Test fun resetReplacesActiveKey() {
        val old = enabledAccount()
        assertTrue(s.recoveryWrap.isNotEmpty())
        expectE2E(E2EText.T3, E2EError.Kind.WRONG_PASSWORD) {
            logic.setup(s.net("d_mac"), server, "alice", "wrong-password", null, mode = SetupMode.RESET)
        }
        val n = s.bodies.size
        val r = logic.setup(s.net("d_mac"), server, "alice", "good-password-1", null, mode = SetupMode.RESET)
        assertEquals(SetupMode.RESET, r.mode)
        assertEquals("", r.recoveryCode)
        val body = s.bodies.drop(n).single()
        assertFalse(body.has("recovery_wrap"))
        assertEquals("", s.recoveryWrap)
        assertEquals(listOf(old.pub to false, r.key.pub to true), s.keys.map { it.pub to it.active })
        // 不换密码：salt 沿用，仍然用 good-password-1 登录，新钥匙能用密码解锁
        assertEquals(r.key, logic.unlockWithPassword(s.net("d_pad"), server, "alice", "good-password-1"))
        // 别的设备上：钉住的还是旧公钥 → T46
        val st = E2EState.parse(s.net("d_pad").e2eState())
        assertTrue(logic.pinStale(st, old.pub))
        assertEquals(SendKey(null, E2EText.T46), logic.sendKey("PK_x", st, old.pub))
        assertEquals(E2EStatus.LOCKED, logic.status(st, listOf(old), old.pub))
        // 解锁拿到新钥匙、替换钉住的公钥之后：已解锁，旧私钥也留着解旧消息
        assertEquals(E2EStatus.UNLOCKED, logic.status(st, listOf(old, r.key), r.key.pub))
    }

    @Test fun resetRequiresEverEnabled() {
        login("old-password")
        expectE2E(kind = E2EError.Kind.CONFLICT) { logic.setup(s.net("d_phone"), server, "alice", "old-password", null, mode = SetupMode.RESET) }
    }

    /** 管理员重设密码后（账号回到旧登录方式）也能重置：用 pbkdf2 算当前密码凭证，顺带升级 */
    @Test fun resetAfterAdminReset() {
        val old = enabledAccount()
        s.adminReset("x-reset-pw-long")
        // 只有重置页允许已升级的账号走 pbkdf2（其他地方 T1，防降级）
        expectE2E(E2EText.T1) { logic.setup(s.net("d_mac"), server, "alice", "x-reset-pw-long", null, mode = SetupMode.RESET) }
        val r = logic.setup(s.net("d_mac"), server, "alice", "x-reset-pw-long", null, mode = SetupMode.RESET, allowLegacy = true)
        assertTrue(s.upgraded)
        assertTrue(s.keys.single { it.active }.pub == r.key.pub && r.key.pub != old.pub)
        assertEquals(r.key, logic.unlockWithPassword(s.net("d_pad"), server, "alice", "x-reset-pw-long"))
    }

    /** 重置的结果不明：active 公钥是新的那把 → 成功；还是旧的 → 保留（RESET_NOT_YET_CALL，之后再核对）；第三把 → CONFLICT；读不到状态 → 保留（RESET_UNSURE） */
    @Test fun resetUnsure() {
        enabledAccount()
        val base = s.net("d_mac")
        val lost = object : E2ENet by base {
            override fun e2eReset(body: JSONObject): JSONObject { base.e2eReset(body); throw java.io.IOException("响应丢了") }
        }
        val r = logic.setup(lost, server, "alice", "good-password-1", null, mode = SetupMode.RESET)
        assertEquals(r.key.pub, s.keys.single { it.active }.pub)
        val dropped = object : E2ENet by base {
            override fun e2eReset(body: JSONObject): JSONObject = throw java.io.IOException("没发出去")
        }
        // 网络出错后核对还是旧钥匙：不马上删（请求可能还在服务器上处理），带着记录交给调用方保留
        val ny = expectE2E(E2EText.RESET_NOT_YET_CALL, E2EError.Kind.SETUP_UNSURE) {
            logic.setup(dropped, server, "alice", "good-password-1", null, mode = SetupMode.RESET)
        }
        assertNotNull(ny.pending); assertEquals(SetupMode.RESET, ny.pending!!.mode)
        // 网络出错后核对发现换成了第三把（别的设备也重置过）：确定失败
        val raced = object : E2ENet by base {
            override fun e2eReset(body: JSONObject): JSONObject {
                s.keys = s.keys.map { it.copy(active = false) }.toMutableList().apply { add(E2EKeyInfo("kidR", "pubR", true)) }
                throw java.io.IOException("断网")
            }
        }
        expectE2E(kind = E2EError.Kind.CONFLICT) { logic.setup(raced, server, "alice", "good-password-1", null, mode = SetupMode.RESET) }
        s.keys = s.keys.map { it.copy(active = it.pub == r.key.pub) }.toMutableList()
        var p: SetupResult? = null
        val offline = object : E2ENet by base {
            var reads = 0
            override fun e2eReset(body: JSONObject): JSONObject = throw java.io.IOException("断网")
            // 第一次（发请求前记下被换掉的钥匙）还能读，发出请求后断网
            override fun e2eState(): JSONObject = if (reads++ == 0) base.e2eState() else throw java.io.IOException("断网")
        }
        val e = expectE2E(E2EText.RESET_UNSURE, E2EError.Kind.SETUP_UNSURE) {
            logic.setup(offline, server, "alice", "good-password-1", null, mode = SetupMode.RESET, onGenerated = { p = it })
        }
        assertEquals(p, e.pending)
        // 刷新时核对（和 §4.1 同一条规则，确定失败才删）：还是被换掉的那把 → 保留；
        // 换成了第三把（别的设备也重置过）→ 删除；新钥匙已启用 → 完成
        val st = E2EState.parse(base.e2eState())
        assertEquals(st.activeKey!!.pub, p!!.replaces)
        assertEquals(E2ELogic.PendingSetup.KEEP, logic.pendingSetup(st, p!!, inFlight = true))
        assertEquals(E2ELogic.PendingSetup.KEEP, logic.pendingSetup(st, p!!))
        val third = st.copy(keys = st.keys.map { it.copy(active = false) } + E2EKeyInfo("kidT", "pubT", true))
        assertEquals(E2ELogic.PendingSetup.DROP, logic.pendingSetup(third, p!!))
        assertEquals(E2ELogic.PendingSetup.KEEP, logic.pendingSetup(third, p!!, inFlight = true))
        val done = st.copy(keys = st.keys.map { it.copy(active = false) } + E2EKeyInfo(p!!.key.kid, p!!.key.pub, true))
        assertEquals(E2ELogic.PendingSetup.COMPLETE, logic.pendingSetup(done, p!!))
        // 手动开启的进行中：没开启时保留，已用别的公钥开启时删除
        val manual = SetupResult(LocalKey("kidZ", "pubZ", "skZ"), "CODE-9")
        assertEquals(E2ELogic.PendingSetup.KEEP, logic.pendingSetup(st.copy(enabled = false, keys = emptyList()), manual))
        assertEquals(E2ELogic.PendingSetup.DROP, logic.pendingSetup(st, manual))
    }

    /** 上传 wrap / grant 都带本机私钥的 kid（§11.5）；钥匙已停用（别的设备重置过）→ T46 */
    @Test fun uploadsCarryKidAndStaleKeyIsT46() {
        val key = enabledAccount()
        // 更换恢复码、改密码带 kid
        logic.rotateRecovery(s.net("d_mac"), server, "alice", "good-password-1", key.sk)
        assertEquals(key.kid, s.bodies.last().getString("kid"))
        logic.changeCredentials(s.net("d_mac"), server, "alice", "alice", "good-password-1", "good-password-2", true, key.sk)
        assertEquals(key.kid, s.bodies.last { it.has("password_wrap") }.getString("kid"))
        // 批准设备带 kid
        val pad = DeviceRequest(c, logic, c.keypair(), key.pub)
        pad.start(s.net("d_pad"))
        val st = E2EState.parse(s.net("d_mac").e2eState())
        val a = Approval(c, "d_pad", "pad", key.pub)
        a.begin(s.net("d_mac"))
        pad.step(s.net("d_pad"))
        a.step(s.net("d_mac"))
        a.approve(s.net("d_mac"), key.sk)
        assertEquals(listOf(key.kid), s.grantKids)
        assertTrue(st.enabled)
        // 别的设备重置了加密：本机还拿着旧私钥
        val fresh = logic.setup(s.net("d_x"), server, "alice", "good-password-2", null, mode = SetupMode.RESET)
        expectE2E(E2EText.T46, E2EError.Kind.STALE_KEY) { logic.rotateRecovery(s.net("d_mac"), server, "alice", "good-password-2", key.sk) }
        expectE2E(E2EText.T46, E2EError.Kind.STALE_KEY) {
            logic.changeCredentials(s.net("d_mac"), server, "alice", "alice", "good-password-2", "good-password-3", true, key.sk)
        }
        // 用新钥匙照常
        logic.rotateRecovery(s.net("d_x"), server, "alice", "good-password-2", fresh.key.sk)
        assertEquals(fresh.key.kid, s.bodies.last().getString("kid"))
        // 批准时 409、本机钥匙已停用：T46
        s.devs["d_q"] = FakeServer.Dev(pub = "pubQ", requested = true, name = "q")
        val b = Approval(c, "d_q", "q", key.pub)
        b.begin(s.net("d_mac"))
        val qd = s.devs["d_q"]!!
        qd.nb = "nbQ"; qd.commit = c.sasCommit("pubQ", key.pub, "nbQ")
        b.step(s.net("d_mac"))
        expectE2E(E2EText.T46, E2EError.Kind.STALE_KEY) { b.approve(s.net("d_mac"), key.sk) }
        assertEquals(Approval.Stage.Failed(E2EText.T46), b.stage)
    }

    /** §11.4：设备批准拿到的私钥必须等于钉住的公钥，不能替换；密码 / 恢复码解锁的只核对服务器启用中的钥匙 */
    @Test fun grantCannotReplacePin() {
        val key = enabledAccount()
        val reset = logic.setup(s.net("d_x"), server, "alice", "good-password-1", null, mode = SetupMode.RESET).key
        val st = E2EState.parse(s.net("d_pad").e2eState())
        // 批准来的（verify 传钉住的公钥）：新钥匙和钉住的旧公钥不同 → T43
        expectE2E(E2EText.T43, E2EError.Kind.MISMATCH) { logic.verify(reset.sk, st.keys, key.pub) }
        // 旧钥匙已经不是 active：哪种来源都不行
        expectE2E(E2EText.T43, E2EError.Kind.MISMATCH) { logic.verify(key.sk, st.keys, null) }
        // 密码解锁、恢复码解锁（不传钉住的）：是 active 就接受，由 E2EHub 替换钉住的公钥
        assertEquals(reset, logic.verify(reset.sk, st.keys, null))
        assertEquals(reset, logic.unlockWithPassword(s.net("d_pad"), server, "alice", "good-password-1"))
        // 钉住旧公钥的新设备请求批准：T46（要用密码或恢复码解锁）
        expectE2E(E2EText.T46, E2EError.Kind.STALE_KEY) { DeviceRequest(c, logic, c.keypair(), key.pub).start(s.net("d_pad")) }
    }

    @Test fun stateParsesServerSeal() {
        enabledAccount()
        s.plainMessages = 3
        val st = E2EState.parse(s.net("d_mac").e2eState())
        assertTrue(st.serverSeal)
        assertEquals(3, st.plainMessages)
        s.serverSeal = false
        assertFalse(E2EState.parse(s.net("d_mac").e2eState()).serverSeal)
        assertFalse(E2EState.parse(JSONObject().put("enabled", true)).serverSeal)      // 0.7 服务端没有这个字段
    }

    /** 服务器代加密的消息（sealed: "server"）：解析、本地缓存往返；本机字段仍然不能由服务器写 */
    @Test fun serverSealedMessage() {
        val o = JSONObject().put("id", 9).put("type", "e2e").put("text", "🔒 加密消息").put("e2e", "env|pub1|{}").put("sealed", "server")
            .put("e2e_status", "ok")
        val m = Message.fromServer(o)
        assertTrue(m.serverSealed)
        assertTrue(m.encrypted)
        assertEquals("", m.e2eStatus)
        assertTrue(Message.from(m.toJson()).serverSealed)
        assertFalse(Message.fromServer(o.put("sealed", "")).serverSealed)
        assertFalse(Message.from(Message.fromServer(JSONObject().put("id", 1)).toJson()).serverSealed)
    }

    // ---------- 已经登录、内存里没有密码的设备（§11.1 末尾，T67） ----------

    @Test fun autoPromptShownOnlyWithoutCredentials() {
        val off = E2EState.parse(JSONObject().put("enabled", false).put("server_seal", true))
        assertTrue(logic.autoPrompt(off, hasCreds = false))
        assertFalse("内存里有这次的密码凭证：后台自动开启，不打扰", logic.autoPrompt(off, hasCreds = true))
        assertFalse("别的设备开启后消失", logic.autoPrompt(off.copy(enabled = true), hasCreds = false))
        assertFalse("0.7 服务端没有 server_seal：不提示", logic.autoPrompt(E2EState.parse(JSONObject().put("enabled", false)), hasCreds = false))
        assertFalse("还没读到状态", logic.autoPrompt(null, hasCreds = false))
    }

    /** 已升级（argon）的账号：输入当前密码算出凭证，走自动开启；密码错了在 setup 时 T3 */
    @Test fun autoKeysForArgonAccount() {
        s.legacyPassword = "good-password-0"
        login("good-password-0", "mac")                 // 别的设备上升级过了；本机（配对码登录）内存里没有密码
        expectE2E(E2EText.T3, E2EError.Kind.WRONG_PASSWORD) {
            logic.setup(s.net("d_pad"), server, "alice", "", null, mode = SetupMode.AUTO,
                pre = logic.autoKeys(s.net("d_pad"), server, "alice", "wrong-password-0"))
        }
        assertFalse(s.enabled)
        val pre = logic.autoKeys(s.net("d_pad"), server, "alice", "good-password-0")
        assertEquals(s.authSalt, pre.salt); assertEquals(s.authKey, pre.auth)
        val r = logic.setup(s.net("d_pad"), server, "alice", "", null, mode = SetupMode.AUTO, pre = pre)
        assertEquals(r.key.pub, s.keys.single().pub)
        assertEquals("", s.recoveryWrap)
        assertFalse(s.bodies.any { it.has("password") || it.has("current_password") })      // 从不发送密码原文
    }

    /** 还没升级（pbkdf2，升级前就登录的设备）：先按 §2.1 第 7 步升级（核对当前密码），再用升级后的凭证开启 */
    @Test fun autoKeysUpgradesPbkdf2Account() {
        s.legacyPassword = "good-password-0"
        expectE2E(E2EText.T3, E2EError.Kind.WRONG_PASSWORD) { logic.autoKeys(s.net("d_phone"), server, "alice", "wrong-password-0") }
        assertFalse(s.upgraded)
        val pre = logic.autoKeys(s.net("d_phone"), server, "alice", "good-password-0")
        assertTrue(s.upgraded)
        assertTrue(flags.isUpgraded(server, "alice"))
        assertEquals(s.authSalt, pre.salt); assertEquals(s.authKey, pre.auth)
        logic.setup(s.net("d_phone"), server, "alice", "", null, mode = SetupMode.AUTO, pre = pre)
        assertTrue(s.enabled)
        assertFalse(s.bodies.any { it.has("password") || it.has("current_password") })
    }

    /** 点开小窗时别的设备刚开启了（还没升级的账号）：不升级、不开启，提示已开启 */
    @Test fun autoKeysWhenAlreadyEnabled() {
        enabledAccount()
        s.adminReset("x-reset-pw-long")             // 回到 pbkdf2，但账号已开启
        flags.set.clear()
        expectE2E(kind = E2EError.Kind.CONFLICT) { logic.autoKeys(s.net("d_pad"), server, "alice", "x-reset-pw-long") }
    }

    // ---------- 审查补充（§11） ----------

    @Test fun autoRetryBackoff() {
        assertEquals(0L, AutoRetry.delayMs(0))
        assertEquals(30_000L, AutoRetry.delayMs(1))
        assertEquals(60_000L, AutoRetry.delayMs(2))
        assertEquals(16 * 60_000L, AutoRetry.delayMs(6))
        assertEquals(30 * 60_000L, AutoRetry.delayMs(7))          // 32 分钟封顶到 30 分钟
        assertEquals(30 * 60_000L, AutoRetry.delayMs(1000))
        // 密码不对、太频繁：停止自动重试；网络错误、5xx 照常退避重试
        assertTrue(AutoRetry.stops(E2EError(E2EText.T3, E2EError.Kind.WRONG_PASSWORD)))
        assertTrue(AutoRetry.stops(ApiException(403, "当前密码不对")))
        assertTrue(AutoRetry.stops(ApiException(429, "尝试太频繁")))
        assertFalse(AutoRetry.stops(ApiException(500, "x")))
        assertFalse(AutoRetry.stops(java.io.IOException("断网")))
        assertFalse(AutoRetry.stops(E2EError(E2EText.SETUP_UNSURE, E2EError.Kind.SETUP_UNSURE)))
    }

    /** 自动开启的 429：原样抛出 ApiException（不当作 T3），由 AutoRetry.stops 停止重试 */
    @Test fun autoSetup429Stops() {
        val pre = login("old-password").pre!!
        val base = s.net("d_phone")
        val limited = object : E2ENet by base {
            override fun e2eSetup(body: JSONObject): JSONObject = throw ApiException(429, "尝试太频繁")
        }
        try { logic.setup(limited, server, "alice", "", null, mode = SetupMode.AUTO, pre = pre); fail() }
        catch (e: ApiException) { assertEquals(429, e.status); assertTrue(AutoRetry.stops(e)) }
        assertFalse(s.enabled)
    }

    /** 只接受「本地明文 → 服务器代加密」的替换；发送端加密的、已解开的、id 对不上的、没标 sealed 的一律丢弃 */
    @Test fun resealedReplacementRules() {
        fun msg(id: Long, e2e: String?, sealed: Boolean = false, status: String = "") =
            Message.from(JSONObject().put("id", id).put("text", "t").apply { if (e2e != null) put("e2e", e2e); if (sealed) put("sealed", "server"); put("e2e_status", status) })
        val plain = msg(5, null)
        val sealed = msg(5, "hje1.a.b", sealed = true)
        assertTrue(Changes.acceptResealed(plain, sealed, 5))
        assertFalse("本地没有", Changes.acceptResealed(null, sealed, 5))
        assertFalse("id 对不上", Changes.acceptResealed(plain, msg(6, "hje1.a.b", sealed = true), 5))
        assertFalse("请求的不是这条", Changes.acceptResealed(plain, sealed, 6))
        assertFalse("没标 sealed: server", Changes.acceptResealed(plain, msg(5, "hje1.a.b"), 5))
        assertFalse("新记录不是加密的", Changes.acceptResealed(plain, msg(5, null, sealed = true), 5))
        assertFalse("本地是发送端加密的", Changes.acceptResealed(msg(5, "hje1.x.y"), sealed, 5))
        assertFalse("本地已经解开", Changes.acceptResealed(msg(5, "hje1.x.y", status = E2EMessages.OK), sealed, 5))
        assertFalse("本地已经是代加密的", Changes.acceptResealed(msg(5, "hje1.x.y", sealed = true), sealed, 5))
    }

    /** 410 sealed：同一条消息最多重新拉 2 次；没有 message_id 时不拉 */
    @Test fun resealRefetchLimit() {
        val counts = HashMap<Long, Int>()
        assertTrue(AttDownloads.allowRefetch(counts, 42))
        assertTrue(AttDownloads.allowRefetch(counts, 42))
        assertFalse(AttDownloads.allowRefetch(counts, 42))
        assertTrue(AttDownloads.allowRefetch(counts, 43))
        assertFalse(AttDownloads.allowRefetch(counts, 0))
    }

    /** 410 sealed 重拉以后接着下载同一位置的新附件（和 Mac 一致）；对不上就不自动下载（提示挂到新附件上） */
    @Test fun resealedSuccessorPicksSamePosition() {
        fun att(id: String, key: String = "") = Attachment(id, "$id.txt", "text/plain", 1, "s", key)
        val holder = plainMsg(7).copy(attachments = listOf(att("a1"), att("a2")))
        val fresh = sealedMsg(7).copy(attachments = listOf(att("n1", "k"), att("n2", "k")), e2eStatus = E2EMessages.OK)
        assertEquals("n2", AttDownloads.resealedSuccessor(holder, 7, "a2", fresh)?.id)
        assertEquals("n1", AttDownloads.resealedSuccessor(holder, 7, "a1", fresh)?.id)
        assertNull("服务端说的是另一条消息", AttDownloads.resealedSuccessor(holder, 8, "a2", fresh.copy(id = 8)))
        assertNull("拉到的还没解开", AttDownloads.resealedSuccessor(holder, 7, "a2", fresh.copy(e2eStatus = E2EMessages.LOCKED)))
        assertNull("拉到的不是加密的", AttDownloads.resealedSuccessor(holder, 7, "a2", plainMsg(7).copy(attachments = fresh.attachments, e2eStatus = E2EMessages.OK)))
        assertNull("新记录附件少了", AttDownloads.resealedSuccessor(holder, 7, "a2", fresh.copy(attachments = listOf(att("n1", "k")))))
        assertNull("附件 id 没换", AttDownloads.resealedSuccessor(holder, 7, "a2", fresh.copy(attachments = listOf(att("n1", "k"), att("a2", "k")))))
        assertNull("本地找不到放这个附件的消息", AttDownloads.resealedSuccessor(null, 7, "a2", fresh))
        assertNull("这条消息里没有这个附件", AttDownloads.resealedSuccessor(holder, 7, "zz", fresh))
        assertNull("没重新拉到", AttDownloads.resealedSuccessor(holder, 7, "a2", null))
    }

    /** 链式下载最多接 1 层：第一次 410 sealed 可以接着下载新附件，新附件再遇到就不再往下接（防 A→B→A 互相等待） */
    @Test fun resealChainDepthCap() {
        assertEquals(1, AttDownloads.MAX_RESEAL_CHAIN)
        assertTrue(AttDownloads.canChain(0))
        assertFalse(AttDownloads.canChain(1))
        assertFalse(AttDownloads.canChain(2))
    }

    /** 文案对齐：T45 中性说法（更换和重置共用），结尾「确定继续吗？」 */
    @Test fun t45Neutral() {
        assertTrue(E2EText.T45.endsWith("确定继续吗？"))
        assertFalse(E2EText.T45.contains("重置"))
    }

    /** 普通 pushkey 发的（服务器代加密）：列表「明文发送」小标签、不显示 🔒，详情 T64；发送端加密的 🔒；本机旧明文「未加密」/ T63 */
    @Test fun sealedMessageMarks() {
        val sealed = sealedMsg(1)
        val e2e = Message.fromServer(JSONObject().put("id", 2).put("type", "e2e").put("e2e", "env|pub1|{}"))
        val plain = plainMsg(3)
        assertTrue(sealed.encrypted && sealed.serverSealed); assertTrue(e2e.encrypted && !e2e.serverSealed)
        assertEquals(E2EMessages.ListMark.SENT_PLAIN, E2EMessages.listMark(sealed, e2eOn = true))
        assertEquals(E2EMessages.ListMark.SENT_PLAIN, E2EMessages.listMark(sealed, e2eOn = false))
        assertEquals(E2EMessages.ListMark.LOCK, E2EMessages.listMark(e2e, e2eOn = true))
        assertEquals(E2EMessages.ListMark.PLAIN, E2EMessages.listMark(plain, e2eOn = true))
        assertEquals(E2EMessages.ListMark.NONE, E2EMessages.listMark(plain, e2eOn = false))
        assertEquals(E2EText.T64, E2EMessages.detailMark(sealed, true))
        assertEquals(E2EText.ENCRYPTED, E2EMessages.detailMark(e2e, true))
        assertEquals(E2EText.T63, E2EMessages.detailMark(plain, true))
        assertEquals("", E2EMessages.detailMark(plain, false))
        assertEquals("明文发送", E2EText.SENT_PLAIN)
        assertTrue(E2EText.T64.startsWith("明文发送：")); assertFalse(E2EText.T64.contains("🔐"))
    }

    /** 0.9.0 起所有消息都加密：T63 只用于本机保留的旧消息，不再说「发送端用的是普通 pushkey」 */
    @Test fun t63OnlyForOldLocalMessages() {
        assertEquals("未加密：开启加密以前收到、只留在本机的旧消息", E2EText.T63)
        assertFalse(E2EText.T63.contains("普通 pushkey"))
        assertFalse(E2EText.T22.contains("新消息就会加密"))      // 不暗示用普通 pushkey 时消息不加密
    }

    /** 进行中的开启按 mode 区分：手动开启留下的（带恢复码）保存读回不丢，自动开启、重置的恢复码为空也能读回 */
    @Test fun pendingSetupModes() {
        val st = E2EState.parse(JSONObject().put("enabled", false))
        val manual = SetupResult(LocalKey("k1", "pub1", "sk1"), "CODE-1")
        val auto = SetupResult(LocalKey("k2", "pub2", "sk2"), "", SetupMode.AUTO)
        assertEquals(E2ELogic.PendingSetup.KEEP, logic.pendingSetup(st, manual))
        assertEquals(E2ELogic.PendingSetup.KEEP, logic.pendingSetup(st, auto))
        val on = E2EState.parse(JSONObject().put("enabled", true).put("keys", JSONArray().put(JSONObject().put("kid", "k1").put("pub", "pub1").put("active", true))))
        assertEquals(E2ELogic.PendingSetup.COMPLETE, logic.pendingSetup(on, manual))
        assertEquals(E2ELogic.PendingSetup.DROP, logic.pendingSetup(on, auto))
    }

    // ---------- android-review（REVIEW-11）补充 ----------

    /** 手动 / 自动开启：网络出错后核对还没开启，不马上删，带着记录抛 SETUP_UNSURE */
    @Test fun setupNotYetKeepsPending() {
        login("old-password", "mac")
        val net = s.net("d_mac")
        val dropped = object : E2ENet by net {
            override fun e2eSetup(body: JSONObject): JSONObject = throw java.io.IOException("超时")
        }
        var saved: SetupResult? = null
        val e = expectE2E(E2EText.SETUP_NOT_YET, E2EError.Kind.SETUP_UNSURE) {
            logic.setup(dropped, server, "alice", "old-password", "good-password-1", onGenerated = { saved = it })
        }
        assertEquals(saved, e.pending)
        assertEquals(E2ELogic.PendingSetup.KEEP, logic.pendingSetup(E2EState.parse(net.e2eState()), e.pending!!))
        // 5xx 同样
        val five = object : E2ENet by net {
            override fun e2eSetup(body: JSONObject): JSONObject = throw ApiException(502, "网关错误")
        }
        expectE2E(E2EText.SETUP_NOT_YET, E2EError.Kind.SETUP_UNSURE) { logic.setup(five, server, "alice", "old-password", "good-password-1") }
    }

    /** 「还没生效」要同一把连续两次、间隔 30 秒以上才算确定失败 */
    @Test fun pendingCheckNeedsTwoObservations() {
        val pc = E2ELogic.PendingCheck(30_000)
        assertFalse(pc.notYet("pub1", 1_000))
        assertFalse(pc.notYet("pub1", 20_000))           // 间隔不够
        assertTrue(pc.notYet("pub1", 31_000))
        assertFalse("换了一把重新计", pc.notYet("pub2", 40_000))
        assertTrue(pc.notYet("pub2", 70_000))
        pc.clear()
        assertFalse(pc.notYet("pub2", 200_000))
    }

    private fun plainMsg(id: Long) = Message.from(JSONObject().put("id", id).put("text", "明文$id"))
    private fun sealedMsg(id: Long) = Message.fromServer(JSONObject().put("id", id).put("type", "e2e").put("e2e", "env|pub1|{}").put("sealed", "server"))

    /** 补加密的消息批量拉取：本地已加密 / 本地没有的不发请求；单条失败不影响其他条；404 算完成；不合规的丢弃 */
    @Test fun fetchResealedBatch() {
        val local = mapOf(1L to plainMsg(1), 2L to plainMsg(2), 3L to plainMsg(3), 4L to plainMsg(4),
            5L to Message.from(JSONObject().put("id", 5).put("e2e", "env|pub1|{}")), 6L to plainMsg(6))
        val asked = java.util.Collections.synchronizedList(ArrayList<Long>())
        val r = Changes.fetchResealed(listOf(1L, 2L, 3L, 4L, 5L, 6L, 99L), local) { id ->
            asked += id
            when (id) {
                2L -> throw java.io.IOException("超时")
                3L -> null                                             // 404：已被删除，保留本地
                4L -> plainMsg(4)                                      // 服务器给的不是代加密的：丢弃
                6L -> sealedMsg(7)                                     // id 对不上：丢弃
                else -> sealedMsg(id)
            }
        }
        assertEquals(setOf(1L, 2L, 3L, 4L, 6L), asked.toSet())        // 5（本地已加密）、99（本地没有）不发请求
        assertEquals(listOf(1L), r.accepted.map { it.id })
        assertEquals(setOf(2L), r.failed)
        assertEquals(setOf(1L, 3L, 4L, 5L, 6L, 99L), r.done)
    }

    /** 并发不超过上限；登录失效这类致命错误照常抛出 */
    @Test fun fetchResealedParallelLimitAndFatal() {
        val local = (1L..20L).associateWith { plainMsg(it) }
        val now = java.util.concurrent.atomic.AtomicInteger()
        val peak = java.util.concurrent.atomic.AtomicInteger()
        val r = Changes.fetchResealed(local.keys, local, parallel = 4) { id ->
            val n = now.incrementAndGet(); peak.accumulateAndGet(n) { a, b -> maxOf(a, b) }
            Thread.sleep(20); now.decrementAndGet(); sealedMsg(id)
        }
        assertEquals(20, r.accepted.size)
        assertTrue("同时最多 4 条，实际 ${peak.get()}", peak.get() in 1..4)
        try {
            Changes.fetchResealed(listOf(1L, 2L), local, fatal = { it is UnauthorizedException }) { throw UnauthorizedException() }
            fail("登录失效应当抛出")
        } catch (_: UnauthorizedException) {}
    }

    // ---------- android-review 复核（N1–N3）和三端对齐 ----------

    /** 进行中的重置：服务器还是旧钥匙时保留，24 小时后按失败处理；请求还在路上时不算 */
    @Test fun pendingResetExpiresAfter24h() {
        val st = E2EState.parse(JSONObject().put("enabled", true).put("keys", JSONArray().put(JSONObject().put("kid", "k0").put("pub", "pub0").put("active", true))))
        val t0 = 1_000_000_000_000L
        val p = SetupResult(LocalKey("k1", "pub1", "sk1"), "", SetupMode.RESET, replaces = "pub0", createdAt = t0)
        assertEquals(E2ELogic.PendingSetup.KEEP, logic.pendingSetup(st, p, now = t0 + 3600_000L))
        assertEquals(E2ELogic.PendingSetup.KEEP, logic.pendingSetup(st, p, now = t0 + E2ELogic.RESET_EXPIRE_MS - 1))
        assertEquals(E2ELogic.PendingSetup.DROP, logic.pendingSetup(st, p, now = t0 + E2ELogic.RESET_EXPIRE_MS))
        assertEquals(E2ELogic.PendingSetup.KEEP, logic.pendingSetup(st, p, inFlight = true, now = t0 + E2ELogic.RESET_EXPIRE_MS * 2))
        // 手动开启的（带恢复码）不按时间删：只有确定失败（别的公钥开启了）才删
        val m = SetupResult(LocalKey("k2", "pub2", "sk2"), "CODE-2", createdAt = t0)
        val off = E2EState.parse(JSONObject().put("enabled", false))
        assertEquals(E2ELogic.PendingSetup.KEEP, logic.pendingSetup(off, m, now = t0 + E2ELogic.RESET_EXPIRE_MS * 10))
        assertEquals(E2ELogic.PendingSetup.DROP, logic.pendingSetup(st, m))
    }

    /** sealed 重试集合：失败次数累加，连续 5 次放弃；4xx（404 / 410 除外）立即放弃；被取消的不算失败 */
    @Test fun resealRetryCounting() {
        val local = (1L..6L).associateWith { plainMsg(it) }
        val r1 = Changes.fetchResealed(listOf(1L, 2L, 3L, 4L), local) { id ->
            when (id) {
                1L -> sealedMsg(1)
                2L -> throw ApiException(400, "参数不对")             // 4xx：放弃
                3L -> throw ApiException(410, "gone")                 // 410：算失败，下次再试
                else -> throw ApiException(503, "忙")                 // 5xx：失败
            }
        }
        assertEquals(setOf(1L), r1.done)
        assertEquals(setOf(2L), r1.dropped)
        assertEquals(setOf(3L, 4L), r1.failed)
        // 同步循环重启：请求被取消的、还没发出的都算跳过，次数不变
        var stop = false
        val r2 = Changes.fetchResealed(listOf(5L), local, cancelled = { stop }) { stop = true; throw java.io.IOException("Canceled") }
        assertEquals(setOf(5L), r2.skipped); assertTrue(r2.failed.isEmpty())
        val asked = ArrayList<Long>()
        val r3 = Changes.fetchResealed(listOf(6L), local, cancelled = { true }) { asked += it; sealedMsg(it) }
        assertEquals(setOf(6L), r3.skipped); assertTrue(asked.isEmpty())
        val r = Changes.ResealResult(emptyList(), r1.done, r1.failed, r1.dropped, r2.skipped + r3.skipped)
        val cur = mapOf(1L to 0, 2L to 0, 3L to 0, 4L to 4, 5L to 2, 6L to 0, 7L to 0)    // 7：处理期间新记进来的
        val next = Changes.nextRetry(cur, r)
        assertEquals(mapOf(3L to 1, 5L to 2, 6L to 0, 7L to 0), next)  // 4 第 5 次失败，放弃
        // 存储格式往返；旧格式（只有 id）次数按 0
        assertEquals(next, Changes.decodeRetry(Changes.encodeRetry(next)))
        assertEquals(mapOf(8L to 0, 9L to 0), Changes.decodeRetry("8,9"))
        assertEquals(emptyMap<Long, Int>(), Changes.decodeRetry(""))
    }

    /** 408 / 429 是暂时的：按失败计次重试，不直接放弃；其余 4xx（404 / 410 除外）放弃（三端一致） */
    @Test fun resealRetryOn408And429() {
        val local = (1L..5L).associateWith { plainMsg(it) }
        val r = Changes.fetchResealed(listOf(1L, 2L, 3L, 4L, 5L), local) { id ->
            when (id) {
                1L -> throw ApiException(408, "超时")
                2L -> throw ApiException(429, "太频繁")
                3L -> throw ApiException(403, "无权")
                4L -> throw ApiException(422, "不对")
                else -> null                                               // 404：保留本地，算完成
            }
        }
        assertEquals(setOf(1L, 2L), r.failed)
        assertEquals(setOf(3L, 4L), r.dropped)
        assertEquals(setOf(5L), r.done)
        // 408 / 429 连续失败照样计次，到 5 次放弃
        assertEquals(mapOf(1L to 1, 2L to 4), Changes.nextRetry(mapOf(1L to 0, 2L to 3, 3L to 0, 4L to 0, 5L to 0), r).filterKeys { it <= 2L })
        assertEquals(emptyMap<Long, Int>(), Changes.nextRetry(mapOf(1L to 4, 2L to 4), r))
        listOf(404, 408, 410, 429).forEach { assertFalse("$it", Changes.resealGiveUp(it)) }
        listOf(400, 401, 403, 409, 413, 422, 499).forEach { assertTrue("$it", Changes.resealGiveUp(it)) }
        listOf(500, 503).forEach { assertFalse("$it", Changes.resealGiveUp(it)) }
    }
}
