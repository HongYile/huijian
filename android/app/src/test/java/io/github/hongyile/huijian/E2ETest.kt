package io.github.hongyile.huijian

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
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
        class Dev(var pub: String = "", var requested: Boolean = false, var commit: String = "", var na: String = "", var nb: String = "",
                  var grant: String = "", var name: String = "")
        val devs = HashMap<String, Dev>()
        /** 收到的全部请求体（检查从不发送密码原文） */
        val bodies = mutableListOf<JSONObject>()
        var tamperReveal: String? = null
        /** 给某台设备看的假 keys（被攻破的服务器给新设备看自己的公钥） */
        val fakeKeysFor = HashMap<String, List<E2EKeyInfo>>()

        val upgraded get() = authKey.isNotEmpty()
        val enabled get() = keys.isNotEmpty()

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
                    username = body.getString("username"); authSalt = body.getString("auth_salt"); authKey = body.getString("auth_key"); legacyPassword = null
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
                if (enabled) err(409, "这个账号已经开启了加密")
                checkCurrent(body)
                val pub = body.getString("pub")
                keys += E2EKeyInfo("kid" + pub.removePrefix("pub"), pub, true)
                authSalt = body.getString("auth_salt"); authKey = body.getString("auth_key"); legacyPassword = null
                passwordWrap = body.getString("password_wrap"); recoveryWrap = body.getString("recovery_wrap")
                return JSONObject().put("kid", keys.last().kid)
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
            override fun e2eGrant(deviceId: String, pub: String, grant: String) {
                val d = devs[deviceId] ?: err(409, "请求不存在")
                if (!d.requested || d.nb.isEmpty() || d.pub != pub) err(409, "对方取消了请求或换了公钥")
                d.grant = grant; d.requested = false
            }
            override fun e2eDeny(deviceId: String) { devs[deviceId]?.let { it.requested = false; it.na = ""; it.nb = "" } }
            override fun e2eRecovery(body: JSONObject) { bodies += body; checkCurrent(body); recoveryWrap = body.getString("recovery_wrap") }
            override fun e2eSetOnly(only: Boolean): JSONObject { e2eOnly = only; return JSONObject().put("e2e_only", only) }
            override fun e2eDeletePlain() = 0
            override fun accountAuth(body: JSONObject): JSONObject {
                bodies += body
                checkCurrent(body)
                if (enabled && !body.has("password_wrap")) err(400, "缺少 password_wrap")
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
        expectE2E(E2EText.T3, E2EError.Kind.WRONG_PASSWORD) { logic.unlockWithPassword(s.net("d_pad"), server, "alice", "nope-nope-nope", null) }
        assertEquals(key, logic.unlockWithPassword(s.net("d_pad"), server, "alice", "good-password-1", null))
        // 管理员重设后：账号回到旧协议，密码副本失效 → 引导用另外两种方式（已升级标记下会先被 T1 拦住）
        s.adminReset("reset-by-admin")
        flags.set.clear()
        expectE2E(kind = E2EError.Kind.WRAP_INVALID) { logic.unlockWithPassword(s.net("d_pad"), server, "alice", "reset-by-admin", null) }
    }

    @Test fun unlockWithRecoveryThenResetPassword() {
        val key = enabledAccount()
        val code = "CODE-" + s.recoveryWrap.split("|")[1].removePrefix("rk")
        expectE2E("恢复码格式不对：应为 26 位字母和数字") { logic.unlockWithRecovery(s.net("d_pad"), "garbage", null) }
        expectE2E(E2EText.T41) { logic.unlockWithRecovery(s.net("d_pad"), "CODE-12345", null) }
        s.adminReset("reset-by-admin")
        val (k, st) = logic.unlockWithRecovery(s.net("d_pad"), code, null)
        assertEquals(key, k)
        assertTrue(st.needsNewPassword)
        // 重新设置密码：当前密码是管理员重设的（旧协议，pbkdf2），新密码锁住本机私钥。
        // 本机标记了「已升级」：只有这一页允许走 pbkdf2，其他地方（改密码、用密码解锁）仍按 T1 拒绝
        assertTrue(flags.isUpgraded(server, "alice"))
        expectE2E(E2EText.T1) { logic.setPassword(s.net("d_pad"), server, "alice", "reset-by-admin", "brand-new-pass", true, k.sk) }
        expectE2E(E2EText.T44) { logic.unlockWithPassword(s.net("d_pad"), server, "alice", "reset-by-admin", null) }   // 解锁时是 T44
        expectE2E(kind = E2EError.Kind.WEAK_PASSWORD) {
            logic.setPassword(s.net("d_pad"), server, "alice", "reset-by-admin", "short", true, k.sk, afterAdminReset = true)
        }
        logic.setPassword(s.net("d_pad"), server, "alice", "reset-by-admin", "brand-new-pass", true, k.sk, afterAdminReset = true)
        val after = E2EState.parse(s.net("d_pad").e2eState())
        assertFalse(after.needsNewPassword)
        assertEquals(key, logic.unlockWithPassword(s.net("d_x"), server, "alice", "brand-new-pass", key.pub))
        // 已开启加密、本机锁定时不能改密码
        expectE2E(E2EText.LOCKED_CHANGE) { logic.setPassword(s.net("d_pad"), server, "alice", "brand-new-pass", "another-pass-1", true, null) }
    }

    @Test fun rotateRecovery() {
        val key = enabledAccount()
        val old = s.recoveryWrap
        expectE2E(E2EText.T3) { logic.rotateRecovery(s.net("d_mac"), server, "alice", "wrong", key.sk) }
        val code = logic.rotateRecovery(s.net("d_mac"), server, "alice", "good-password-1", key.sk)
        assertNotEquals(old, s.recoveryWrap)
        assertEquals(key, logic.unlockWithRecovery(s.net("d_pad"), code, null).first)
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
        a.approve(s.net("d_mac"), "sk777")          // 不是账号钥匙（和承诺里的 acc 对不上）
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
        // 钉住的公钥和服务器给的不同：请求批准、保存私钥、加密发送密钥都拒绝（T43）
        expectE2E(E2EText.T43, E2EError.Kind.MISMATCH) { DeviceRequest(c, logic, c.keypair(), "pubOther").start(s.net("d_pad")) }
        expectE2E(E2EText.T43, E2EError.Kind.MISMATCH) { logic.verify(key.sk, st.keys, "pubOther") }
        assertEquals(key, logic.verify(key.sk, st.keys, key.pub))
        assertEquals(SendKey(null, E2EText.T43), logic.sendKey("PK_x", st, "pubOther"))
        assertEquals(SendKey(null, E2EText.T73), logic.sendKey("PK_x", st, null))
        assertEquals(SendKey("PK_x.e2e.${key.pub}", null), logic.sendKey("PK_x", st, key.pub))
        assertNull(logic.sendKey("PK_x", st.copy(enabled = false), key.pub))
        // 只有和钉住的相同的本机私钥才算解锁
        assertEquals(E2EStatus.LOCKED, logic.status(st, listOf(key), "pubOther"))
        assertEquals(E2EStatus.UNLOCKED, logic.status(st, listOf(key), key.pub))
        // 解锁时钉住的公钥对不上：丢弃
        expectE2E(E2EText.T43) { logic.unlockWithPassword(s.net("d_pad"), server, "alice", "good-password-1", "pubOther") }
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
        assertTrue(logic.setInitialPassword(s.net("d_phone"), server, "alice", "long-enough-pw"))
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
        expectE2E(E2EText.T44) { logic.unlockWithPassword(s.net("d_phone"), server, "alice", "x-reset-pw", null) }
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
        assertEquals("k2", st.activeKey?.kid); assertTrue(st.e2eOnly); assertTrue(st.needsNewPassword)
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
}
