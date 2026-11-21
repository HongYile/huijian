package io.github.hongyile.huijian

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Instant

/**
 * agent 双向（docs/agent-mcp.md §5.1、§8、§11）的设备一侧逻辑：核实会话证明、批准状态机、解开 agent 消息、回复、回执核对。
 * 密码学换成可预测的假实现（FakeAgentCrypto），服务端换成内存里的模拟（FakeAgentNet），只看客户端有没有按规格核对、拒绝。
 * 真实密码学和 Go 服务端逐字节一致由 core/tests/agent.rs 的跨平台向量保证
 */
class AgentTest {

    // ---------- 假实现 ----------

    /**
     * 私钥 skN ↔ 公钥 pubN。格式：
     * 证明 hja1|<写证明的私钥>|<会话 id>|<会话公钥>|<名称>|<时间>；
     * agent 消息 / 回执 hje2|<收件的账号公钥>|<发送方会话公钥>|<会话 id>|<载荷>；
     * 副本 env|<账号公钥>|<载荷>（同 E2ETest.FakeCrypto）
     */
    class FakeAgentCrypto : AgentCrypto {
        private var n = 0
        override fun publicKey(sk: String) = "pub" + sk.removePrefix("sk") to "kid" + sk.removePrefix("sk")
        override fun random32() = "na${++n}"
        override fun openMessage(keys: List<String>, envelope: String): JSONObject {
            val p = envelope.split("|", limit = 3)
            if (p.size != 3 || p[0] != "env") throw Core.Failure("format", "格式不对")
            if (keys.none { publicKey(it).first == p[1] }) throw Core.Failure("wrong_key", "钥匙不对")
            return JSONObject(p[2])
        }
        override fun mdBuild(text: String, desp: String, atts: List<Map<String, Any?>>) = """{"v":1}""" to "预览：$desp"
        override fun agentCommit(pub: String, account: String, nonce: String, name: String) = "acommit:$pub:$account:$nonce:$name"
        override fun agentSas(pub: String, account: String, na: String, nb: String) =
            "%06d".format(Math.floorMod("agent|$pub|$account|$na|$nb".hashCode(), 1_000_000))
        override fun agentAttestSeal(sk: String, sessionId: String, pub: String, name: String, approvedAt: Long) =
            "hja1|$sk|$sessionId|$pub|$name|$approvedAt"
        override fun agentAttestOpen(sk: String, attest: String, sessionId: String, pub: String): String {
            val p = attest.split("|")
            if (p.size != 6 || p[0] != "hja1") throw Core.Failure("format", "格式不对")
            if (p[1] != sk) throw Core.Failure("format", "解不开")
            if (p[2] != sessionId || p[3] != pub) throw Core.Failure("format", "会话证明和会话对不上")
            return p[4]
        }
        override fun agentOpen(keys: List<String>, sessionPub: String, sessionId: String, envelope: String): JSONObject {
            val p = envelope.split("|", limit = 5)
            if (p.size != 5 || p[0] != "hje2") throw Core.Failure("format", "格式不对")
            if (keys.none { publicKey(it).first == p[1] }) throw Core.Failure("wrong_key", "钥匙不对")
            if (p[2] != sessionPub) throw Core.Failure("format", "发送方不是这个会话")       // auth 模式核对发送方
            if (p[3] != sessionId) throw Core.Failure("format", "消息不是这个会话发的")
            return JSONObject(p[4])
        }
        override fun agentReplySeal(sk: String, sessionPub: String, sessionId: String, msgId: Long, payload: String) =
            "hjq1|$sessionPub|$sessionId|$msgId|$payload" to "env|${publicKey(sk).first}|$payload"

        /** agent 一侧：会话（公钥 sessionPub）发给账号（公钥 account） */
        fun seal(account: String, sessionPub: String, sessionId: String, payload: JSONObject) = "hje2|$account|$sessionPub|$sessionId|$payload"
    }

    /** 内存里的服务端（规则照 server/agent.go） */
    class FakeAgentNet : AgentNet {
        val sessions = LinkedHashMap<String, AgentSession>()
        val challenges = mutableListOf<Pair<String, String>>()
        val denied = mutableListOf<String>()
        val approved = mutableListOf<Pair<String, String>>()
        val replies = mutableListOf<JSONObject>()
        var replyStatus = JSONObject().put("replies", JSONArray())
        var conflictReply = false
        var conflictChallenge = false
        var conflictApprove = false

        private fun json(s: AgentSession) = JSONObject().put("id", s.id).put("name", s.name).put("pub", s.pub).put("state", s.state)
            .put("commit", s.commit).put("challenge", s.challenge).put("reveal", s.reveal).put("attest", s.attest)
            .put("created_at", JSONObject.NULL).put("online", s.online)

        override fun agentKeys() = JSONObject().put("keys", JSONArray())
        override fun agentCreateKey() = JSONObject().put("id", 1).put("key", "AK_" + "0".repeat(32)).put("prefix", "AK_0000")
        override fun agentConnectCode() = JSONObject().put("code", "K7Q2-9XMD").put("expires_at", "2026-11-21T03:20:00Z").put("expires_in", 600)
        override fun agentRevokeKey(id: Long) {}
        override fun agentSessions() = JSONObject().put("sessions", JSONArray(sessions.values.map(::json)))
        override fun agentEnd(id: String) { sessions[id]?.let { sessions[id] = it.copy(state = "ended") } }
        override fun agentChallenge(id: String, nonce: String) {
            val s = sessions[id] ?: throw ApiException(404, "请求不存在")
            if (conflictChallenge || s.challenge.isNotEmpty()) throw ApiException(409, "已被别的设备接手")
            challenges += id to nonce
            sessions[id] = s.copy(challenge = nonce)
        }
        override fun agentApprove(id: String, attest: String) {
            if (conflictApprove) throw ApiException(409, "请求已经作废")
            val s = sessions[id] ?: throw ApiException(404, "请求不存在")
            approved += id to attest
            sessions[id] = s.copy(state = "approved", attest = attest)
        }
        override fun agentDeny(id: String) { denied += id; sessions[id]?.let { sessions[id] = it.copy(state = "denied") } }
        override fun agentReply(msgId: Long, envelope: String, copy: String): JSONObject {
            if (conflictReply) throw ApiException(409, "会话已结束")
            replies += JSONObject().put("msg_id", msgId).put("e2e", envelope).put("copy", copy)
            return JSONObject().put("reply_id", 40 + replies.size)
        }
        override fun agentReplyStatus(msgId: Long) = replyStatus

        /** agent 揭晓 nb */
        fun reveal(id: String, nb: String) { sessions[id] = sessions[id]!!.copy(reveal = nb) }
    }

    private val c = FakeAgentCrypto()
    private val sk = "sk1"
    private val account = "pub1"

    private fun msg(e2e: String?, sid: String?, atts: List<Attachment> = emptyList()) = Message(
        9, "agent", "", 4, "markdown", "", "", "家里 Claude Code", Instant.EPOCH, atts, e2e = e2e, agentSession = sid, ask = true,
    )

    // ---------- 核实会话证明 ----------

    @Test fun verifyKeepsOnlySessionsWithMatchingAttest() {
        val good = AgentSession("as1", name = "服务器给的名字", pub = "pubA", state = "approved", attest = c.agentAttestSeal(sk, "as1", "pubA", "家里 Claude Code", 1))
        // 服务器把会话公钥换成自己的：证明里写的公钥对不上
        val swapped = AgentSession("as2", pub = "pubEvil", state = "approved", attest = c.agentAttestSeal(sk, "as2", "pubB", "x", 1))
        // 证明挪到别的会话上
        val moved = AgentSession("as3", pub = "pubA", state = "approved", attest = good.attest)
        // 不是本账号私钥写的（服务器自己写的）
        val forged = AgentSession("as4", pub = "pubC", state = "approved", attest = c.agentAttestSeal("sk666", "as4", "pubC", "冒充", 1))
        val none = AgentSession("as5", pub = "pubD", state = "pending")
        val v = Agent.verify(listOf(good, swapped, moved, forged, none), listOf(sk), sk, c)
        assertEquals(mapOf("as1" to AgentVerified("家里 Claude Code", "pubA")), v)
    }

    @Test fun verifyTriesOlderKeys() {
        // 重置加密前批准的会话：证明是旧钥匙写的
        val s = AgentSession("as1", pub = "pubA", state = "approved", attest = c.agentAttestSeal("sk0", "as1", "pubA", "旧会话", 1))
        // 旧钥匙写的证明：能核实（显示历史消息），但不是当前钥匙写的（不能回复）
        assertEquals(AgentVerified("旧会话", "pubA", current = false), Agent.verify(listOf(s), listOf(sk, "sk0"), sk, c)["as1"])
        assertEquals(AgentVerified("旧会话", "pubA", current = true), Agent.verify(listOf(s), listOf(sk, "sk0"), "sk0", c)["as1"])
        // 不知道当前钥匙（本机锁定等）：一律不算当前
        assertFalse(Agent.verify(listOf(s), listOf("sk0"), null, c).getValue("as1").current)
        assertTrue(Agent.verify(listOf(s), listOf(sk), sk, c).isEmpty())
    }

    // ---------- 批准状态机 ----------

    private fun pending(net: FakeAgentNet, id: String = "as1", name: String = "家里 Claude Code", acct: String = account, nb: String = "nb1"): AgentSession {
        val s = AgentSession(id, name = name, pub = "pubS", state = "pending", commit = c.agentCommit("pubS", acct, nb, name))
        net.sessions[id] = s
        return s
    }

    private fun list(net: FakeAgentNet) = Agent.parseSessions(net.agentSessions())

    @Test fun approvalWaitsForRevealThenShowsCodeAndWritesAttest() {
        val net = FakeAgentNet()
        val s = pending(net)
        val a = AgentApproval.begin(net, c, s, sk)
        val na = net.challenges.single().second
        assertEquals("as1" to na, net.challenges.single())
        assertEquals(AgentPhase.Challenged, a.handle(list(net), net))
        // 还没批准时不能写证明
        a.approve(net, sk, 100)
        assertTrue(net.approved.isEmpty())
        net.reveal("as1", "nb1")
        val ph = a.handle(list(net), net)
        assertEquals(AgentPhase.Code(c.agentSas("pubS", account, na, "nb1")), ph)
        a.approve(net, sk, 100)
        assertEquals(AgentPhase.Approved, a.phase)
        val (id, attest) = net.approved.single()
        assertEquals("as1", id)
        // 证明是本账号私钥写的、写的就是这个会话和公钥
        assertEquals("家里 Claude Code", c.agentAttestOpen(sk, attest, "as1", "pubS"))
        assertTrue(net.denied.isEmpty())
    }

    @Test fun approvalCommitMismatchDeniesAndFails() {
        val net = FakeAgentNet()
        // agent 看到的是服务器伪造的账号公钥：它的承诺按假公钥算
        val s = pending(net, acct = "pubFake")
        val a = AgentApproval.begin(net, c, s, sk)
        net.reveal("as1", "nb1")
        assertEquals(AgentPhase.Failed(AgentText.COMMIT_MISMATCH), a.handle(list(net), net))
        assertEquals(listOf("as1"), net.denied)
        // 失败之后不会再显示核对码，也不能批准
        net.sessions["as1"] = net.sessions["as1"]!!.copy(state = "pending", commit = c.agentCommit("pubS", account, "nb1", "家里 Claude Code"))
        assertEquals(AgentPhase.Failed(AgentText.COMMIT_MISMATCH), a.handle(list(net), net))
        a.approve(net, sk)
        assertTrue(net.approved.isEmpty())
    }

    @Test fun approvalRevealWithWrongNonceFails() {
        val net = FakeAgentNet()
        val s = pending(net)
        val a = AgentApproval.begin(net, c, s, sk)
        net.reveal("as1", "nb-other")       // 揭晓的 nb 和承诺对不上
        assertEquals(AgentPhase.Failed(AgentText.COMMIT_MISMATCH), a.handle(list(net), net))
        assertEquals(listOf("as1"), net.denied)
    }

    @Test fun approvalDetectsRestartAndGone() {
        val net = FakeAgentNet()
        val a = AgentApproval.begin(net, c, pending(net), sk)
        // 请求被换成了别的公钥 / 承诺（agent 重新发起，或服务器偷换）
        net.sessions["as1"] = net.sessions["as1"]!!.copy(pub = "pubX")
        assertEquals(AgentPhase.Failed(AgentText.RESTARTED), a.handle(list(net), net))

        val net2 = FakeAgentNet()
        val b = AgentApproval.begin(net2, c, pending(net2), sk)
        net2.sessions["as1"] = net2.sessions["as1"]!!.copy(challenge = "na-of-other-device")
        assertEquals(AgentPhase.Failed(AgentText.RESTARTED), b.handle(list(net2), net2))

        val net3 = FakeAgentNet()
        val d = AgentApproval.begin(net3, c, pending(net3), sk)
        net3.sessions.clear()
        assertEquals(AgentPhase.Failed(AgentText.GONE), d.handle(list(net3), net3))
    }

    @Test fun approvalTakenByOtherDevice() {
        val net = FakeAgentNet()
        net.conflictChallenge = true
        try { AgentApproval.begin(net, c, pending(net), sk); fail() } catch (e: E2EError) { assertEquals(AgentText.TAKEN, e.message) }
    }

    @Test fun approvalConflictOnApproveFails() {
        val net = FakeAgentNet()
        val a = AgentApproval.begin(net, c, pending(net), sk)
        net.reveal("as1", "nb1")
        a.handle(list(net), net)
        net.conflictApprove = true
        try { a.approve(net, sk); fail() } catch (e: E2EError) { assertEquals("请求已经作废", e.message) }
        assertEquals(AgentPhase.Failed("请求已经作废"), a.phase)
    }

    @Test fun rejectAndStop() {
        val net = FakeAgentNet()
        val a = AgentApproval.begin(net, c, pending(net), sk)
        a.stop()
        a.reject(net)
        assertEquals(AgentPhase.Rejected, a.phase)
        net.reveal("as1", "nb1")
        assertEquals(AgentPhase.Rejected, a.handle(list(net), net))
    }

    // ---------- 收消息 ----------

    private val verified = mapOf("as1" to AgentVerified("家里 Claude Code", "pubS"))

    private fun payload(choices: List<String> = emptyList(), kind: String = "message") = JSONObject().put("v", 1).put("kind", kind)
        .put("text", "  要不要删掉 3 个异常样本？ ").put("desp", "**3** 个样本").put("ask", true).put("choices", JSONArray(choices))
        .put("seq", 1).put("sent_at", 1)

    @Test fun openUnverifiedWhenSessionNotVerified() {
        val m = msg(c.seal(account, "pubS", "as1", payload()), "as1")
        val o = Agent.open(m, listOf(sk), emptyMap(), c)
        assertEquals(E2EMessages.UNVERIFIED, o.e2eStatus)
        assertEquals(AgentText.UNVERIFIED, o.text)
        assertTrue(o.sealed)
        assertNull(o.agentName)
        assertEquals(E2EMessages.LOCKED, Agent.open(m, emptyList(), verified, c).e2eStatus)
    }

    @Test fun openOkFiltersChoices() {
        val long = "这一项超过二十个字的选项应该被丢掉才对啊啊"
        assertTrue(long.length > 20)
        val m = msg(c.seal(account, "pubS", "as1", payload(listOf("删", " 保留 ", "", long, "再看看", "问别人", "第六个"))), "as1")
        val o = Agent.open(m, listOf("sk0", sk), verified, c)
        assertEquals(E2EMessages.OK, o.e2eStatus)
        assertFalse(o.sealed)
        assertEquals("要不要删掉 3 个异常样本？", o.text)
        assertEquals("**3** 个样本", o.desp)
        assertEquals("家里 Claude Code", o.agentName)
        // 空的、超过 20 字的丢掉，最多 4 个
        assertEquals(listOf("删", "保留", "再看看", "问别人"), o.choices)
        assertEquals(1L, o.agentSeq)
        assertEquals("预览：**3** 个样本", o.preview)
        // 恰好 20 字的保留
        val twenty = "一二三四五六七八九十一二三四五六七八九十"
        assertEquals(listOf(twenty), Agent.open(msg(c.seal(account, "pubS", "as1", payload(listOf(twenty))), "as1"), listOf(sk), verified, c).choices)
    }

    @Test fun openRejectsWrongSenderKindAndAttachments() {
        // 发送方不是证明里的会话公钥（服务器伪造）
        val forged = msg(c.seal(account, "pubEvil", "as1", payload()), "as1")
        assertEquals(E2EMessages.FORMAT, Agent.open(forged, listOf(sk), verified, c).e2eStatus)
        // 消息头的会话 id 被改到另一个已核实的会话上
        val moved = msg(c.seal(account, "pubS", "as1", payload()), "as2")
        assertEquals(E2EMessages.FORMAT, Agent.open(moved, listOf(sk), verified + ("as2" to AgentVerified("别的", "pubS")), c).e2eStatus)
        // 回执冒充消息
        val receipt = msg(c.seal(account, "pubS", "as1", payload(kind = "receipt")), "as1")
        assertEquals(E2EMessages.FORMAT, Agent.open(receipt, listOf(sk), verified, c).e2eStatus)
        // 第一版 agent 消息不带附件
        val withAtt = msg(c.seal(account, "pubS", "as1", payload()), "as1", listOf(Attachment("a1", "x.png", "image/png", 1, "00")))
        assertEquals(E2EMessages.FORMAT, Agent.open(withAtt, listOf(sk), verified, c).e2eStatus)
        // 不是本账号的钥匙
        val other = msg(c.seal("pub7", "pubS", "as1", payload()), "as1")
        assertEquals(E2EMessages.WRONG_KEY, Agent.open(other, listOf(sk), verified, c).e2eStatus)
    }

    @Test fun serverCannotInjectLocalFields() {
        val o = JSONObject().put("id", 9).put("e2e", "hje2.x").put("agent_session", "as1").put("ask", true)
            .put("agent_name", "服务器写的").put("choices", JSONArray(listOf("同意"))).put("e2e_status", "ok").put("created_at", "2026-11-20T00:00:00Z")
        val m = Message.fromServer(o)
        assertEquals("as1", m.agentSession)
        assertTrue(m.ask)
        assertNull(m.agentName)
        assertTrue(m.choices.isEmpty())
        assertEquals("", m.e2eStatus)
        // 本机缓存原样保存、读回
        val opened = Agent.open(msg(c.seal(account, "pubS", "as1", payload(listOf("删"))), "as1"), listOf(sk), verified, c)
        val back = Message.from(opened.toJson())
        assertEquals(opened.agentName, back.agentName)
        assertEquals(opened.choices, back.choices)
        assertEquals(opened.agentSession, back.agentSession)
        assertTrue(back.ask)
        assertNull(Message.from(JSONObject().put("id", 1)).agentSession)
    }

    // ---------- 回复 ----------

    @Test fun replyBlockReasons() {
        val ok = Agent.open(msg(c.seal(account, "pubS", "as1", payload()), "as1"), listOf(sk), verified, c)
        val active = listOf(AgentSession("as1", state = "approved"))
        assertNull(Agent.replyBlock(ok, true, verified, active))
        assertEquals(AgentText.NO_REPLY_LOCKED, Agent.replyBlock(ok, false, verified, active))
        assertEquals(AgentText.ENDED, Agent.replyBlock(ok, true, verified, listOf(AgentSession("as1", state = "ended"))))
        assertEquals(AgentText.ENDED, Agent.replyBlock(ok, true, verified, emptyList()))
        assertEquals(AgentText.NO_REPLY_LOADING, Agent.replyBlock(ok, true, verified, emptyList(), loaded = false))
        // 重置加密前（旧钥匙）批准的会话：历史消息照常显示，但不能回复
        assertEquals(AgentText.NO_REPLY_OLD_KEY, Agent.replyBlock(ok, true, mapOf("as1" to AgentVerified("x", "pubS", current = false)), active))
        // 载荷里没有 seq：不能回复
        assertEquals(AgentText.NO_REPLY_NO_SEQ, Agent.replyBlock(ok.copy(agentSeq = 0), true, verified, active))
        // 证明后来核实不了了（会话证明被换掉）：不能回复
        assertEquals(AgentText.NO_REPLY_UNVERIFIED, Agent.replyBlock(ok, true, emptyMap(), active))
        val unverified = Agent.open(msg(c.seal(account, "pubS", "as1", payload()), "as1"), listOf(sk), emptyMap(), c)
        assertEquals(AgentText.NO_REPLY_UNVERIFIED, Agent.replyBlock(unverified, true, verified, active))
        val locked = Agent.open(msg(c.seal(account, "pubS", "as1", payload()), "as1"), emptyList(), verified, c)
        assertEquals(AgentText.NO_REPLY_SEALED, Agent.replyBlock(locked, true, verified, active))
    }

    @Test fun replySealsForVerifiedSessionAndCopy() {
        val net = FakeAgentNet()
        val id = Agent.reply(net, c, 9, 5, "as1", verified.getValue("as1"), sk, "  删  ", "我的手机", nowSec = 77, nonce = { "N1" })
        assertEquals(41L, id)
        val r = net.replies.single()
        assertEquals(9L, r.getLong("msg_id"))
        // 给会话的用证明里的会话公钥，附加数据里带消息 id
        assertTrue(r.getString("e2e").startsWith("hjq1|pubS|as1|9|"))
        val p = c.openMessage(listOf(sk), r.getString("copy"))
        assertEquals("删", p.getString("text"))
        assertEquals("N1", p.getString("n"))
        assertEquals(77L, p.getLong("sent_at"))
        assertEquals("我的手机", p.getString("device"))
        assertEquals(1, p.getInt("v"))
        // re_seq：被回复消息载荷里的 seq（agent 靠它核对回的是哪个问题）
        assertEquals(5L, p.getLong("re_seq"))
        assertTrue(r.getString("e2e").contains("\"re_seq\":5"))
    }

    @Test fun replyRejectsEmptyTooLongAndEnded() {
        val net = FakeAgentNet()
        val v = verified.getValue("as1")
        try { Agent.reply(net, c, 9, 1, "as1", v, sk, "   ", "d"); fail() } catch (e: E2EError) { assertEquals(AgentText.EMPTY, e.message) }
        try { Agent.reply(net, c, 9, 1, "as1", v, sk, "字".repeat(6000), "d"); fail() } catch (e: E2EError) { assertEquals(AgentText.TOO_LONG, e.message) }
        // 文字不到 16 KB，但转义后（引号、控制字符）序列化超过 20 KB
        try { Agent.reply(net, c, 9, 1, "as1", v, sk, "\"\u0001".repeat(3000), "d"); fail() } catch (e: E2EError) { assertEquals(AgentText.TOO_LONG, e.message) }
        // 没有 seq、会话证明不是当前钥匙写的：不发
        try { Agent.reply(net, c, 9, 0, "as1", v, sk, "删", "d"); fail() } catch (e: E2EError) { assertEquals(AgentText.NO_REPLY_NO_SEQ, e.message) }
        try { Agent.reply(net, c, 9, 1, "as1", v.copy(current = false), sk, "删", "d"); fail() } catch (e: E2EError) { assertEquals(AgentText.NO_REPLY_OLD_KEY, e.message) }
        assertTrue(net.replies.isEmpty())
        Agent.reply(net, c, 9, 1, "as1", v, sk, "a".repeat(Agent.MAX_REPLY_BYTES), "d")       // 恰好 16 KB 可以
        net.conflictReply = true
        try { Agent.reply(net, c, 9, 1, "as1", v, sk, "再回", "d"); fail() } catch (e: E2EError) { assertEquals(AgentText.ENDED, e.message) }
        assertTrue(Agent.newNonce().length >= 21 && !Agent.newNonce().contains('='))
    }

    // ---------- 回复状态与回执 ----------

    private fun copyOf(text: String, n: String) = "env|$account|" + Agent.replyPayload(1, text, n, 50, "我的手机")
    private fun receipt(replyId: Long, n: String, sender: String = "pubS", kind: String = "receipt") =
        c.seal(account, sender, "as1", JSONObject().put("v", 1).put("kind", kind).put("reply_id", replyId).put("n", n).put("received_at", 60))

    @Test fun replyViewsCheckReceipts() {
        val list = listOf(
            AgentReplyStatus(1, "as1", "received", copy = copyOf("对得上", "N1"), receipt = receipt(1, "N1")),
            // 回执的 reply_id 对不上（服务器拿别的回执冒充）
            AgentReplyStatus(2, "as1", "received", copy = copyOf("id 不对", "N2"), receipt = receipt(1, "N2")),
            // 回执里的 n 对不上
            AgentReplyStatus(3, "as1", "received", copy = copyOf("n 不对", "N3"), receipt = receipt(3, "N1")),
            // 回执不是会话私钥写的
            AgentReplyStatus(4, "as1", "received", copy = copyOf("发送方不对", "N4"), receipt = receipt(4, "N4", sender = "pubEvil")),
            // kind 不是 receipt
            AgentReplyStatus(5, "as1", "received", copy = copyOf("kind 不对", "N5"), receipt = receipt(5, "N5", kind = "message")),
            AgentReplyStatus(6, "as1", "expired", copy = copyOf("过期", "N6")),
            AgentReplyStatus(7, "as1", "sent", copy = copyOf("已发出", "N7")),
            // 副本解不开、别的会话的、没有 n 的：不显示
            AgentReplyStatus(8, "as1", "sent", copy = "env|pub9|" + Agent.replyPayload(1, "别人的", "N8", 1, "")),
            AgentReplyStatus(9, "as2", "sent", copy = copyOf("别的会话", "N9")),
            AgentReplyStatus(10, "as1", "sent", copy = "env|$account|" + JSONObject().put("text", "没有 n")),
        )
        val views = Agent.replyViews(list, "as1", listOf(sk), verified.getValue("as1"), c)
        assertEquals(listOf(1L, 2, 3, 4, 5, 6, 7), views.map { it.id })
        val st = views.associate { it.id to it.state }
        assertEquals(AgentReplyView.State.RECEIVED, st[1])
        assertEquals(AgentReplyView.State.SENT, st[2])
        assertEquals(AgentReplyView.State.SENT, st[3])
        assertEquals(AgentReplyView.State.SENT, st[4])
        assertEquals(AgentReplyView.State.SENT, st[5])
        assertEquals(AgentReplyView.State.EXPIRED, st[6])
        assertEquals(AgentReplyView.State.SENT, st[7])
        val v1 = views.first()
        assertEquals("对得上", v1.text)
        assertEquals("我的手机", v1.device)
        assertEquals(50L, v1.sentAt)
        assertEquals(60L, v1.receivedAt)
        assertEquals("✓✓ agent 已收到", v1.label)
        assertNull(views[1].receivedAt)
        assertEquals("已过期（agent 没有取走）", views[5].label)
        // 会话核实不了：回执一律不算
        assertTrue(Agent.replyViews(list.take(1), "as1", listOf(sk), null, c).all { it.state == AgentReplyView.State.SENT })
    }

    @Test fun repliesParsesServerStatus() {
        val net = FakeAgentNet()
        net.replyStatus = JSONObject().put("replies", JSONArray().put(JSONObject().put("reply_id", 1).put("session_id", "as1").put("state", "received")
            .put("created_at", "2026-11-20T00:00:00Z").put("received_at", JSONObject.NULL).put("copy", copyOf("好", "N1"))
            .put("receipt", receipt(1, "N1")).put("device", "服务器记的")))
        val views = Agent.replies(net, c, 9, "as1", listOf(sk), verified.getValue("as1"))
        assertEquals(AgentReplyView.State.RECEIVED, views.single().state)
        assertEquals("我的手机", views.single().device)
    }

    // ---------- 解析、变更 ----------

    @Test fun parseSessionsHandlesNulls() {
        val o = JSONObject().put("sessions", JSONArray().put(JSONObject().put("id", "as1").put("name", "x").put("state", "approved")
            .put("created_at", "2026-11-20T01:02:03Z").put("approved_at", JSONObject.NULL).put("last_seen", JSONObject.NULL).put("online", true))
            .put(JSONObject().put("name", "没有 id")))
        val s = Agent.parseSessions(o).single()
        assertEquals("2026-11-20T01:02:03Z", s.createdAt)
        assertNull(s.approvedAt)
        assertNull(s.lastSeen)
        assertEquals("", s.attest)
        assertTrue(s.active && s.online && !s.pending)
        val k = Agent.parseKeys(JSONObject().put("keys", JSONArray().put(JSONObject().put("id", 3).put("prefix", "AK_ab12").put("last_used", JSONObject.NULL))))
        assertEquals(AgentKeyInfo(3, "AK_ab12", null, null), k.single())
        assertEquals(AgentNewKey(1, "AK_" + "0".repeat(32), "AK_0000"), Agent.parseNewKey(FakeAgentNet().agentCreateKey()))
    }

    @Test fun agentChangeRefreshesAgent() {
        val p = Changes.plan(listOf(MsgChange(1, 0, "agent", null), MsgChange(2, 0, "agent", null), MsgChange(3, 0, "e2e", null)))
        assertEquals(setOf(SettingKind.AGENT, SettingKind.E2E), p.refresh)
    }

    @Test fun sealedUnverifiedTitle() {
        val m = E2EMessages.sealed(msg("hje2.x", "as1").copy(agentName = "x", choices = listOf("a")), E2EMessages.UNVERIFIED)
        assertEquals(AgentText.UNVERIFIED, m.text)
        assertNull(m.agentName)
        assertTrue(m.choices.isEmpty())
    }

    @Test fun approvalNameChangedOrNotInCommitFails() {
        // 服务器在接手之后改了显示的名称：按对方重新发起处理
        val net = FakeAgentNet()
        val a = AgentApproval.begin(net, c, pending(net), sk)
        net.sessions["as1"] = net.sessions["as1"]!!.copy(name = "冒充的名字")
        assertEquals(AgentPhase.Failed(AgentText.RESTARTED), a.handle(list(net), net))
        // 服务器一开始就给了和 agent 承诺里不同的名称：承诺对不上，自动拒绝
        val net2 = FakeAgentNet()
        val s = pending(net2).let { it.copy(name = "服务器改的名字").also { x -> net2.sessions["as1"] = x } }
        val b = AgentApproval.begin(net2, c, s, sk)
        net2.reveal("as1", "nb1")
        assertEquals(AgentPhase.Failed(AgentText.COMMIT_MISMATCH), b.handle(list(net2), net2))
        assertEquals(listOf("as1"), net2.denied)
    }

    @Test fun askComesFromPayload() {
        // 服务器说在等回复，载荷里没有：以载荷为准
        val m = msg(c.seal(account, "pubS", "as1", payload().put("ask", false)), "as1")
        assertTrue(m.ask)
        val o = Agent.open(m, listOf(sk), verified, c)
        assertFalse(o.ask)
        // 反过来：服务器没标、载荷里是 true
        assertTrue(Agent.open(m.copy(ask = false, e2e = c.seal(account, "pubS", "as1", payload())), listOf(sk), verified, c).ask)
        // 解开前（来源无法核实）保留服务器给的，只用来显示占位
        assertTrue(Agent.open(m, listOf(sk), emptyMap(), c).ask)
        // seq 存进本地缓存，服务器下发时清空
        val back = Message.from(Agent.open(m, listOf(sk), verified, c).toJson())
        assertEquals(1L, back.agentSeq)
        assertEquals(0L, Message.fromServer(JSONObject().put("id", 9).put("agent_seq", 7).put("agent_session", "as1")).agentSeq)
    }

    @Test fun composeReplyJoinsChoiceAndText() {
        assertEquals("继续", AgentText.composeReply("继续", ""))
        assertEquals("继续", AgentText.composeReply("继续", "  \n "))
        assertEquals("你好", AgentText.composeReply(null, " 你好 "))
        assertEquals("继续\n先别删文件", AgentText.composeReply("继续", "先别删文件"))
        assertEquals("", AgentText.composeReply(null, " "))
    }

    // ---------- 连接 agent（连接码，服务端 0.11.0） ----------

    @Test fun keyLabelWithAndWithoutName() {
        val keys = Agent.parseKeys(JSONObject("""{"keys":[
            {"id":1,"prefix":"AK_ab12","name":"家里 Claude Code","created_at":"2026-11-20T01:00:00Z","last_used":null},
            {"id":2,"prefix":"AK_cd34","name":""},
            {"id":3,"prefix":"AK_ef56"},
            {"id":4,"prefix":"AK_gh78","name":null}]}"""))
        assertEquals(listOf("家里 Claude Code", null, null, null), keys.map { it.name })
        assertEquals("家里 Claude Code · AK_ab12…", keys[0].label)
        assertEquals("AK_cd34…", keys[1].label)
        assertEquals("AK_ef56…", keys[2].label)
        assertEquals("AK_gh78…", keys[3].label)
        assertNull(keys[0].lastUsed)
    }

    @Test fun parseConnectCode() {
        val c = Agent.parseConnectCode(FakeAgentNet().agentConnectCode())
        assertEquals(AgentConnectCode("K7Q2-9XMD", 600, "2026-11-21T03:20:00Z"), c)
        // 有效期缺失或不合理：按 10 分钟算；expires_at 可以没有
        assertEquals(AgentConnectCode("ABCD-EFGH", 600, null), Agent.parseConnectCode(JSONObject("""{"code":"ABCD-EFGH","expires_at":null}""")))
        assertEquals(600L, Agent.parseConnectCode(JSONObject("""{"code":"ABCD-EFGH","expires_in":0}""")).expiresIn)
        assertEquals(300L, Agent.parseConnectCode(JSONObject("""{"code":"ABCD-EFGH","expires_in":300}""")).expiresIn)
        for (bad in listOf("""{}""", """{"code":""}""", """{"code":null,"expires_in":600}""")) {
            try { Agent.parseConnectCode(JSONObject(bad)); fail(bad) } catch (_: E2EError) {}
        }
    }

    @Test fun setupCommand() {
        assertEquals("huijian agent setup -u https://push.example.com K7Q2-9XMD", AgentText.setupCommand("https://push.example.com", "K7Q2-9XMD"))
        assertEquals(AgentText.CLI_DOWNLOAD, "https://github.com/HongYile/huijian/releases/latest")
        assertTrue(AgentText.CONNECT_STEPS.startsWith("1. 在 agent 所在的电脑上安装 huijian 命令行"))
    }
}
