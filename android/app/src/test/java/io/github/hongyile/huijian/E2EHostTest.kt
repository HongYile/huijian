package io.github.hongyile.huijian

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runners.MethodSorters
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * 真实密码学（本机编译的共用核心）+ 真实服务端的端到端测试（docs/e2ee-client.md §10）。默认跳过；
 * 用 claude_test/android-e2e/run_host_test.sh 起一个临时 hub（0.9.0：注册模式 invite、注册即开启加密）后运行，需要的环境变量：
 * - HUIJIAN_CORE_HOST_LIB：libhuijian_core.dylib 所在目录（build.gradle.kts 把它设成 java.library.path）
 * - HUIJIAN_E2E_URL：测试服务端；HUIJIAN_E2E_USER、HUIJIAN_E2E_PASS：要注册的新账号（还不存在）；
 *   HUIJIAN_E2E_INVITE：给它用的邀请码（单次）
 * - HUIJIAN_E2E_USER2、HUIJIAN_E2E_PASS2、HUIJIAN_E2E_KEY2：用 huijian register 命令行注册好的账号和它的私钥文件（可选）
 * - HUIJIAN_E2E_CLI：huijian 命令行（发加密消息）
 * 不要指向正式服务器：会注册账号、改密码、重置加密。
 * 0.9.0 起不能再建旧账号（PBKDF2、没开启加密）：旧账号登录升级、开启以前的明文补加密（sealed 变更、410）这两段没法在新服务端上测，
 * 由单元测试（E2ETest、SealedApiTest）覆盖
 */
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class E2EHostTest {
    private val url = System.getenv("HUIJIAN_E2E_URL").orEmpty()
    private val user = System.getenv("HUIJIAN_E2E_USER").orEmpty()
    private val pass = System.getenv("HUIJIAN_E2E_PASS").orEmpty()
    private val cli = System.getenv("HUIJIAN_E2E_CLI").orEmpty()
    private val invite = System.getenv("HUIJIAN_E2E_INVITE").orEmpty()
    /** 命令行注册的第二个账号（和安卓客户端的钥匙格式互通）；没有时跳过那一段 */
    private val user2 = System.getenv("HUIJIAN_E2E_USER2").orEmpty()
    private val pass2 = System.getenv("HUIJIAN_E2E_PASS2").orEmpty()
    private val key2 = System.getenv("HUIJIAN_E2E_KEY2").orEmpty()

    private class MemFlags : UpgradeFlags {
        val set = HashSet<String>()
        override fun isUpgraded(server: String, username: String) = UpgradeFlags.key(server, username) in set
        override fun markUpgraded(server: String, username: String) { set += UpgradeFlags.key(server, username) }
    }

    private fun fp(name: String) = java.security.MessageDigest.getInstance("SHA-256").digest(name.toByteArray()).joinToString("") { "%02x".format(it) }

    private fun push(key: String, vararg args: String): String {
        val p = ProcessBuilder(listOf(cli, "push", "-u", url, "-k", key) + args).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        assertTrue("命令行发送超时", p.waitFor(60, TimeUnit.SECONDS))
        assertEquals(out, 0, p.exitValue())
        return out
    }

    /** 一张随机噪点的 RGB PNG（单元测试用的 android.jar 里没有 ImageIO，手写编码） */
    private fun noisePng(w: Int, h: Int): ByteArray {
        val rnd = java.util.Random(42)
        val raw = java.io.ByteArrayOutputStream()
        repeat(h) { raw.write(0); raw.write(ByteArray(w * 3).also { rnd.nextBytes(it) }) }
        val out = java.io.ByteArrayOutputStream()
        fun chunk(type: String, data: ByteArray) {
            val d = java.io.DataOutputStream(out)
            d.writeInt(data.size); val t = type.toByteArray(); d.write(t); d.write(data)
            d.writeInt(java.util.zip.CRC32().apply { update(t); update(data) }.value.toInt())
        }
        out.write(byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte(), 13, 10, 26, 10))
        chunk("IHDR", java.nio.ByteBuffer.allocate(13).putInt(w).putInt(h).put(8).put(2).put(0).put(0).put(0).array())
        val z = java.io.ByteArrayOutputStream()
        java.util.zip.DeflaterOutputStream(z).use { it.write(raw.toByteArray()) }
        chunk("IDAT", z.toByteArray())
        chunk("IEND", ByteArray(0))
        return out.toByteArray()
    }

    /** JSON 规范化（对象按键排序），比较两份 doc 是否一样 */
    private fun canon(v: Any?): String = when (v) {
        is JSONObject -> v.keys().asSequence().sorted().joinToString(",", "{", "}") { "\"$it\":" + canon(v.get(it)) }
        is org.json.JSONArray -> (0 until v.length()).joinToString(",", "[", "]") { canon(v.get(it)) }
        is String -> JSONObject.quote(v)
        else -> v.toString()
    }

    @Test fun fullFlow() {
        assumeTrue("没有设置 HUIJIAN_E2E_URL 等环境变量，跳过", url.isNotBlank() && System.getenv("HUIJIAN_CORE_HOST_LIB") != null)
        val flagsA = MemFlags()
        val logicA = E2ELogic(CoreCrypto, flagsA)
        val anon = Api(url, null)

        // 0. 服务端：注册要邀请码、注册即开启加密
        val info = anon.info()
        assertEquals(RegisterMode.INVITE, Manage.registerMode(info))
        assertTrue("0.9.0 服务端应有 register.e2e", Manage.registerWithKeys(info))
        assertFalse(info.optBoolean("register_open"))

        // 1. 注册即开启加密（register.e2e）：没带邀请码、邀请码无效时 403，说明原样返回；不带钥匙的旧方式 400（什么都不建，不扣邀请码）
        try { logicA.register(anon, url, user, pass, "it-mac", fp("it-mac"), withKeys = true); throw AssertionError("应返回 403") }
        catch (e: ApiException) { assertEquals(403, e.status); assertTrue(e.message!!.contains("邀请码")) }
        try { logicA.register(anon, url, user, pass, "it-mac", fp("it-mac"), inviteCode = "ZZZZZZZZZZ", withKeys = true); throw AssertionError("应返回 403") }
        catch (e: ApiException) { assertEquals(403, e.status); assertTrue(e.message!!.isNotBlank()) }
        // 定稿（claude_test/0.9.0-register-api.md）：缺 auth_key / pub / password_wrap 返回 400「请更新回笺客户端后注册…」；426 只在 /v1/login 发 password 原文时出现
        try { logicA.register(anon, url, user, pass, "it-mac", fp("it-mac"), inviteCode = invite); throw AssertionError("应返回 400") }
        catch (e: ApiException) { assertEquals(400, e.status); assertTrue(e.message!!.contains("更新")) }
        // 邀请码大小写、空格不敏感；上面 400 时没有用掉
        val la = logicA.register(anon, url, user, pass, "it-mac", fp("it-mac"), inviteCode = " " + invite.lowercase() + " ", withKeys = true)
        assertTrue(la.upgraded); assertTrue(flagsA.isUpgraded(url, user))
        val keyA = la.keys.single()
        val a = Api(url, la.result.token)
        val stA = E2EState.parse(a.e2eState())
        assertTrue(stA.enabled); assertEquals(keyA.pub, stA.activeKey!!.pub); assertEquals(keyA.kid, stA.activeKey!!.kid)
        assertEquals("注册时不强制恢复码", "", stA.recoveryWrap); assertFalse(stA.needsNewPassword)
        assertEquals(E2EStatus.UNLOCKED, logicA.status(stA, listOf(keyA), keyA.pub))
        assertTrue("服务器代加密始终开启", stA.serverSeal)
        val pre = anon.prelogin(user)
        assertEquals("argon2id", pre.optString("kdf")); assertEquals(3, pre.optInt("time")); assertEquals(65536, pre.optInt("memory_kib"))
        // 注册后不能再开启（409）：客户端不再走自动开启
        try { logicA.setup(a, url, user, pass, null, mode = SetupMode.AUTO, pre = la.pre); throw AssertionError("应返回 409") }
        catch (e: E2EError) { assertEquals(E2EError.Kind.CONFLICT, e.kind) }
        // 单次邀请码已经用掉：403（前面几次失败的注册已经让同一 IP 触发限速时是 429，两种都带说明）
        try { logicA.register(anon, url, user + "x", pass, "it-x", fp("it-x"), inviteCode = invite, withKeys = true); throw AssertionError("应被拒绝") }
        catch (e: ApiException) { assertTrue("应返回 403 / 429，实际 ${e.status}", e.status == 403 || e.status == 429); assertTrue(e.message!!.isNotBlank()) }
        // 新协议账号：旧客户端发 password 原文返回 426
        try { anon.login(user, pass, "old", fp("old")); throw AssertionError("应返回 426") } catch (e: ApiException) { assertEquals(426, e.status) }
        val newPass = pass

        // 3. 发一条加密消息（带附件）和一条内容相同的明文消息，解密后应与服务端解析的明文一致
        val pk = a.createKey("it-e2e").key
        val sendKey = "$pk.e2e.${keyA.pub}"
        val dir = File(System.getProperty("java.io.tmpdir"), "hj-e2e-" + System.nanoTime()).apply { mkdirs() }
        // 一张真 PNG（噪点，约 270 KB，跨好几个 64 KB 的加密块）
        val att = File(dir, "报告 loss.png").apply { writeBytes(noisePng(300, 300)) }
        val desp = "## 结果\n\nval_loss **0.198**\n\n- [x] 训练\n- [ ] 评估\n\n![](<attachment:报告 loss.png>)\n\n> [!NOTE]\n> 单换行\n即换行"
        push(sendKey, "-p", "4", "-topic", "it", "-d", desp, "-f", att.path, "exp42 完成")
        push(pk, "-p", "4", "-topic", "it", "-d", desp, "-f", att.path, "exp42 完成")
        val msgs = a.messages(since = null, limit = 10).messages.takeLast(2)
        val enc = msgs[0]; val sealedPlain = msgs[1]
        assertNotNull(enc.e2e); assertTrue(enc.sealed); assertFalse(enc.serverSealed)
        // 用普通 pushkey 发的明文：服务器收到后立即代加密（sealed: "server"），解开后就是服务端解析的明文
        assertTrue(sealedPlain.serverSealed); assertNotNull(sealedPlain.e2e)
        val plain = E2EMessages.open(sealedPlain, listOf(keyA.sk), CoreCrypto)
        assertEquals(E2EMessages.OK, plain.e2eStatus)
        assertEquals("encrypted-1.bin", enc.attachments.single().name)
        // 锁定时：T60
        val locked = E2EMessages.open(enc, emptyList(), CoreCrypto)
        assertEquals(E2EText.T60, locked.title); assertEquals("", locked.desp)
        // 解锁后重新解密
        val opened = E2EMessages.open(locked, listOf(keyA.sk), CoreCrypto)
        assertEquals(plain.text, opened.title); assertEquals(plain.desp, opened.desp); assertEquals(plain.type, opened.type)
        assertEquals(plain.preview, opened.preview)
        // doc 和服务端解析的一样（附件 id 不同，换掉再比较）
        val encAtt = opened.attachments.single(); val plainAtt = plain.attachments.single()
        assertEquals(plainAtt.name, encAtt.name); assertEquals(plainAtt.mime, encAtt.mime); assertEquals(plainAtt.size, encAtt.size)
        val docPlain = JSONObject(plain.doc!!.replace(plainAtt.id, "ATT")); val docEnc = JSONObject(opened.doc!!.replace(encAtt.id, "ATT"))
        assertEquals(canon(docPlain), canon(docEnc))
        // 附件：下载密文（校验密文 sha256），解密到真实文件名
        val ct = File(dir, "ct.enc"); a.download(encAtt, ct)
        val out = File(dir, encAtt.name); CoreCrypto.decryptFile(encAtt.key, ct, out)
        assertArrayEquals(att.readBytes(), out.readBytes())
        // 密文被改过：解密失败，不留半成品
        val bad = File(dir, "bad.enc").apply { writeBytes(ct.readBytes().also { it[it.size / 2] = (it[it.size / 2] + 1).toByte() }) }
        val badOut = File(dir, "bad.png")
        try { CoreCrypto.decryptFile(encAtt.key, bad, badOut); throw AssertionError("应解密失败") } catch (e: Core.Failure) { assertFalse(badOut.exists()) }

        // 4. 另一台设备用密码登录：登录时顺带解开私钥
        val flagsC = MemFlags()
        val lc = E2ELogic(CoreCrypto, flagsC).login(anon, url, user.uppercase(), newPass, "it-phone", fp("it-phone")) { Api(url, it) }
        assertEquals(listOf(keyA), lc.keys)

        // 5. 配对码登录的设备：已锁定 → 请已解锁的设备批准（核对码一致）
        val code = a.createPairCode().code
        val pb = anon.pair(code, "it-pad", fp("it-pad"))
        val b = Api(url, pb.token)
        val logicB = E2ELogic(CoreCrypto, MemFlags())
        assertEquals(E2EStatus.LOCKED, logicB.status(E2EState.parse(b.e2eState()), emptyList()))
        val req = DeviceRequest(CoreCrypto, logicB, CoreCrypto.keypair(), null)
        req.start(b)
        assertEquals(DeviceRequest.Step.Waiting, req.step(b).first)
        val r = E2EState.parse(a.e2eState()).requests.single()
        assertEquals("it-pad", r.name)
        val ap = Approval(CoreCrypto, r.deviceId, r.name, keyA.pub)
        ap.begin(a)
        // 别的设备再接手同一个请求：409 → T51
        try { Approval(CoreCrypto, r.deviceId, r.name, keyA.pub).begin(Api(url, lc.result.token)); throw AssertionError() } catch (e: E2EError) { assertEquals(E2EText.T51, e.message) }
        val codeB = (req.step(b).first as DeviceRequest.Step.Code).code
        val codeA = (ap.step(a).first as Approval.Stage.Code).code
        assertEquals(codeA, codeB)
        assertTrue(codeA.matches(Regex("\\d{6}")))
        ap.approve(a, keyA.sk)
        val un = req.step(b).first as DeviceRequest.Step.Unlocked
        assertEquals(keyA, un.key)
        // 核对码协议和核心库测试向量一致：两端算出的承诺对得上服务端的核对（揭晓成功就说明服务端认可）
        // 钉住了公钥的设备再请求一次：acc 用钉住的公钥
        val reqPinned = DeviceRequest(CoreCrypto, logicB, CoreCrypto.keypair(), keyA.pub)
        reqPinned.start(b)
        // 钉住的不是服务器启用中的钥匙：直接 T46（§11.4）
        try { DeviceRequest(CoreCrypto, logicB, CoreCrypto.keypair(), CoreCrypto.keypair().pub).start(b); throw AssertionError() }
        catch (e: E2EError) { assertEquals(E2EText.T46, e.message) }
        reqPinned.cancel(b)

        // 6. 再来一台：被拒绝
        val pd = anon.pair(a.createPairCode().code, "it-tv", fp("it-tv"))
        val d = Api(url, pd.token)
        val req2 = DeviceRequest(CoreCrypto, logicB, CoreCrypto.keypair(), null)
        req2.start(d)
        a.e2eDeny(pd.deviceId)
        assertEquals(DeviceRequest.Step.Denied, req2.step(d).first)

        // 7. 用密码解锁（配对码登录的设备）
        try { logicB.unlockWithPassword(d, url, user, "wrong-password-x"); throw AssertionError() } catch (e: E2EError) { assertEquals(E2EText.T3, e.message) }
        assertEquals(keyA, logicB.unlockWithPassword(d, url, user, newPass))

        // 8. 恢复码：先换一个，旧的失效、新的能解锁
        val rec2 = logicA.rotateRecovery(a, url, user, newPass, keyA.sk)
        try { logicB.unlockWithRecovery(d, "00000-00000-00000-00000-000000"); throw AssertionError() } catch (e: E2EError) { assertEquals(E2EText.T41, e.message) }
        assertEquals(keyA, logicB.unlockWithRecovery(d, rec2.lowercase().replace("-", " ")).first)

        // 9. 改密码：已开启加密时同时上传用新密码锁住的私钥；旧密码失效
        val newPass2 = "it-Another-pass-2027"
        logicA.setPassword(a, url, user, newPass, newPass2, enabled = true, sk = keyA.sk)
        assertEquals(keyA, E2ELogic(CoreCrypto, MemFlags()).login(anon, url, user, newPass2, "it-phone", fp("it-phone")) { Api(url, it) }.keys.single())

        // 10–11. 0.9.0 起没有「只接受加密消息」和「删除服务器上的明文消息」（§7 第 2、4 项）：
        // 普通 pushkey 发来的一律由服务器代加密，服务器上的消息全是加密的
        val left = a.messages(since = null, limit = 50).messages
        assertTrue(left.all { it.e2e != null })

        // 12. 更换加密钥匙（§11.3）：新钥匙启用、旧钥匙停用，服务器上的恢复码作废；上传带旧 kid → T46
        val reset = logicA.setup(a, url, user, newPass2, null, mode = SetupMode.RESET)
        assertEquals("", reset.recoveryCode)
        val stR = E2EState.parse(a.e2eState())
        assertEquals(reset.key.pub, stR.activeKey!!.pub)
        assertTrue(stR.keys.any { it.pub == keyA.pub && !it.active })
        assertEquals("", stR.recoveryWrap)
        assertTrue(logicA.pinStale(stR, keyA.pub))
        try { logicA.rotateRecovery(a, url, user, newPass2, keyA.sk); throw AssertionError() }
        catch (e: E2EError) { assertEquals(E2EText.T46, e.message); assertEquals(E2EError.Kind.STALE_KEY, e.kind) }
        try { logicA.setPassword(a, url, user, newPass2, "it-Third-pass-2028", enabled = true, sk = keyA.sk); throw AssertionError() }
        catch (e: E2EError) { assertEquals(E2EText.T46, e.message) }
        // 设置恢复码（§11.2，和更换同一个接口），带新 kid
        val rec3 = logicA.rotateRecovery(a, url, user, newPass2, reset.key.sk)
        assertEquals(reset.key, logicB.unlockWithRecovery(d, rec3).first)
        // 别的设备：密码解锁拿到新钥匙（可以替换钉住的）；钉住旧公钥时请求批准是 T46
        assertEquals(reset.key, logicB.unlockWithPassword(d, url, user, newPass2))
        try { DeviceRequest(CoreCrypto, logicB, CoreCrypto.keypair(), keyA.pub).start(d); throw AssertionError() }
        catch (e: E2EError) { assertEquals(E2EText.T46, e.message) }
        // 重复提交同一把公钥：照样成功（结果不明时重试）
        val again = logicA.setup(a, url, user, newPass2, null, reset, mode = SetupMode.RESET)
        assertEquals(reset, again)
        // 用旧钥匙加密的旧消息，本机留着旧私钥照样能解
        assertEquals(E2EMessages.OK, E2EMessages.open(enc, listOf(reset.key.sk, keyA.sk), CoreCrypto).e2eStatus)
        dir.deleteRecursively()

        // 13. 命令行注册（huijian register，本机生成钥匙）的账号：安卓用密码登录时解开同一把钥匙，私钥格式和核心库互通
        if (user2.isNotBlank()) {
            val l2 = E2ELogic(CoreCrypto, MemFlags()).login(anon, url, user2, pass2, "it-auto", fp("it-auto")) { Api(url, it) }
            val k2 = l2.keys.single()
            val st2 = E2EState.parse(Api(url, l2.result.token).e2eState())
            assertTrue(st2.enabled); assertEquals(k2.pub, st2.activeKey!!.pub)
            if (key2.isNotBlank()) assertEquals(k2.pub, CoreCrypto.publicKey(File(key2).readText().trim()).first)
        }
    }
}
