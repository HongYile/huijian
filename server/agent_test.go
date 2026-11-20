package main

// agent 双向（docs/agent-mcp.md §11）：Agent key、登录批准（承诺 + 揭晓 + 核对码）、hje2 消息、hjq1 回复、长轮询、回执、各种拒绝

import (
	"bytes"
	"crypto/ecdh"
	"encoding/json"
	"flag"
	"os"
	"strconv"
	"testing"
	"time"
)

var updateAgentVectors = flag.Bool("update-agent-vectors", false, "重新生成 testdata/agent_vectors.json（Rust 核心用它核对）")

func (e *e2eEnv) agentMust(code int, method, path, tok string, body any) map[string]any {
	e.t.Helper()
	got, out := e.call(method, path, tok, body)
	if got != code {
		e.t.Fatalf("%s %s：状态 %d（期望 %d），响应 %v", method, path, got, code, out)
	}
	return out
}

// agentFixture：一个开启了加密的账号、两台设备、一把 Agent key
type agentFixture struct {
	e          *e2eEnv
	uid        int64
	tokA, tokB string
	devA       string
	acctSK     *ecdh.PrivateKey
	ak         string
	pw         string
	auth1      []byte
}

func newAgentFixture(t *testing.T) *agentFixture {
	e := newE2EEnv(t)
	const pw = "agent-pass-0001"
	e.h.st.CreateAccount("owner", "owner-pass-0001") // 第一个账号接收服务器通知、不能删除：测试用第二个账号
	u, _ := e.h.st.CreateAccount("agentuser", pw)
	dA, tokA, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "mac", Platform: "macos", Fingerprint: "fp-ag-000001"})
	_, tokB, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "phone", Platform: "ios", Fingerprint: "fp-ag-000002"})
	sk := newKey(t)
	body, auth1, _ := keyBody(t, sk, pw)
	body["current_password"] = pw
	e.must(200, "POST", "/v1/e2e/setup", tokA, body)
	ak := e.agentMust(200, "POST", "/v1/agent/keys", tokA, nil)["key"].(string)
	return &agentFixture{e: e, uid: u.ID, tokA: tokA, tokB: tokB, devA: dA.ID, acctSK: sk, ak: ak, pw: pw, auth1: auth1}
}

// login：agent 发起登录 → 设备 A 出 na → agent 揭晓 → 设备核对承诺、两边核对码一致 → 设备写证明并批准 → agent 取走令牌
func (f *agentFixture) login(t *testing.T, name string) (sid, token string, sessSK *ecdh.PrivateKey) {
	e := f.e
	info := e.agentMust(200, "GET", "/v1/agent/info", f.ak, nil)
	acct, _ := b64.DecodeString(info["account_pub"].(string))
	if !bytes.Equal(acct, f.acctSK.PublicKey().Bytes()) {
		t.Fatal("agent/info 的账号公钥不对")
	}
	sessSK = newKey(t)
	nb := randBytes(32)
	pub := sessSK.PublicKey().Bytes()
	sid = e.agentMust(200, "POST", "/v1/agent/sessions", f.ak, map[string]any{"name": name, "pub": b64of(pub),
		"commit": b64of(agentCommit(pub, acct, nb))})["session_id"].(string)
	// 设备：看到请求，出 na
	na := randBytes(32)
	e.agentMust(200, "POST", "/v1/agent/sessions/"+sid+"/challenge", f.tokA, map[string]any{"nonce": b64of(na)})
	st := e.agentMust(200, "GET", "/v1/agent/sessions/"+sid, f.ak, nil)
	if st["state"] != agentPending || st["challenge"] != b64of(na) || st["token"] != nil {
		t.Fatalf("揭晓前的状态不对：%v", st)
	}
	agentCode := agentSAS(pub, acct, na, nb)
	e.agentMust(200, "POST", "/v1/agent/sessions/"+sid+"/reveal", f.ak, map[string]any{"nonce": b64of(nb)})
	// 设备：用自己私钥算出的账号公钥核对承诺，算核对码
	var req map[string]any
	for _, s := range e.agentMust(200, "GET", "/v1/agent/sessions", f.tokA, nil)["sessions"].([]any) {
		if s.(map[string]any)["id"] == sid {
			req = s.(map[string]any)
		}
	}
	rev, _ := b64.DecodeString(req["reveal"].(string))
	cm, _ := b64.DecodeString(req["commit"].(string))
	if !bytes.Equal(agentCommit(pub, f.acctSK.PublicKey().Bytes(), rev), cm) {
		t.Fatal("承诺核对失败")
	}
	if agentSAS(pub, f.acctSK.PublicKey().Bytes(), na, rev) != agentCode {
		t.Fatal("两边核对码不一致")
	}
	att, err := agentAttestSeal(f.acctSK.Bytes(), agentAttest{SessionID: sid, Pub: b64of(pub), Name: name, ApprovedAt: now()})
	if err != nil {
		t.Fatal(err)
	}
	e.agentMust(200, "POST", "/v1/agent/sessions/"+sid+"/approve", f.tokA, map[string]any{"attest": att})
	st = e.agentMust(200, "GET", "/v1/agent/sessions/"+sid, f.ak, nil)
	token, _ = st["token"].(string)
	if st["state"] != agentApproved || len(token) != 35 {
		t.Fatalf("批准后应拿到令牌：%v", st)
	}
	if again := e.agentMust(200, "GET", "/v1/agent/sessions/"+sid, f.ak, nil); again["token"] != nil {
		t.Fatal("令牌只能取一次")
	}
	return sid, token, sessSK
}

func (f *agentFixture) push(t *testing.T, sid, token string, sessSK *ecdh.PrivateKey, p agentPayload, ask bool) int64 {
	b, _ := json.Marshal(p)
	env, err := agentSeal(f.acctSK.PublicKey(), sessSK, sid, b, nil)
	if err != nil {
		t.Fatal(err)
	}
	out := f.e.agentMust(200, "POST", "/v1/agent/push", token, map[string]any{"e2e": env, "priority": 4, "ask": ask, "thread": "t1"})
	return int64(out["id"].(float64))
}

// reply：设备用账号私钥加密给会话公钥（取自证明），附上给账号自己的副本
func (f *agentFixture) reply(t *testing.T, tok, sid string, sessPub *ecdh.PublicKey, msgID int64, text string) (int, map[string]any, string) {
	n := b64of(randBytes(16))
	b, _ := json.Marshal(agentReply{V: 1, Text: text, N: n, SentAt: now(), Device: "mac"})
	env, err := agentReplySeal(sessPub, f.acctSK, sid, msgID, b, nil)
	if err != nil {
		t.Fatal(err)
	}
	cp, _ := e2eSealMessage(f.acctSK.PublicKey(), b)
	code, out := f.e.call("POST", "/v1/agent/replies", tok, map[string]any{"msg_id": msgID, "e2e": env, "copy": cp})
	return code, out, n
}

func TestAgentFlow(t *testing.T) {
	f := newAgentFixture(t)
	e := f.e
	if !hasFeature("agent") {
		t.Fatal("功能清单里应有 agent")
	}
	// Agent key：每账号 1 把；列表只有前缀；明文不再出现
	e.agentMust(409, "POST", "/v1/agent/keys", f.tokB, nil)
	ks := e.agentMust(200, "GET", "/v1/agent/keys", f.tokB, nil)["keys"].([]any)
	if len(ks) != 1 || ks[0].(map[string]any)["prefix"] != f.ak[:7] || bytes.Contains(mustJSON(ks), []byte(f.ak)) {
		t.Fatalf("Agent key 列表不对：%v", ks)
	}
	e.agentMust(401, "GET", "/v1/agent/info", "AK_0000", nil)
	e.agentMust(401, "GET", "/v1/agent/info", f.tokA, nil) // 设备 token 不能当 Agent key

	sid, token, sessSK := f.login(t, "家里 Claude Code")
	sessPub := sessSK.PublicKey()

	// 会话证明：设备能解开、内容对得上
	var sess map[string]any
	for _, s := range e.agentMust(200, "GET", "/v1/agent/sessions", f.tokB, nil)["sessions"].([]any) {
		sess = s.(map[string]any)
	}
	att, err := agentAttestOpen(f.acctSK.Bytes(), sess["attest"].(string))
	if err != nil || att.SessionID != sid || att.Pub != b64of(sessPub.Bytes()) || sess["state"] != agentApproved {
		t.Fatalf("会话证明不对：%v %v", att, err)
	}

	// agent 发消息：列表里带 agent_session、ask；设备用证明里的公钥解开
	msgID := f.push(t, sid, token, sessSK, agentPayload{V: 1, Kind: "message", Text: "要不要删掉 3 个异常样本？", Ask: true, Choices: []string{"删", "保留"}, Seq: 1, SentAt: now()}, true)
	var m map[string]any
	for _, x := range e.messages(f.tokB) {
		if int64(x["id"].(float64)) == msgID {
			m = x
		}
	}
	if m["agent_session"] != sid || m["ask"] != true || m["source"] != "家里 Claude Code" || m["topic"] != "agent" || m["type"] != "e2e" {
		t.Fatalf("agent 消息字段不对：%v", m)
	}
	pt, err := agentOpen(f.acctSK, sessPub, m["e2e"].(string))
	if err != nil || !bytes.Contains(pt, []byte("异常样本")) {
		t.Fatalf("设备解不开 agent 消息：%v", err)
	}
	if _, err := agentOpen(f.acctSK, newKey(t).PublicKey(), m["e2e"].(string)); err == nil {
		t.Fatal("发送方公钥不对也解开了")
	}
	// 推送的各种拒绝：别的会话的信封、不是 hje2、用旧钥匙
	b, _ := json.Marshal(agentPayload{V: 1, Kind: "message", Text: "x"})
	other, _ := agentSeal(f.acctSK.PublicKey(), sessSK, "asffffffffffffffff", b, nil)
	e.agentMust(400, "POST", "/v1/agent/push", token, map[string]any{"e2e": other})
	plain, _ := e2eSealMessage(f.acctSK.PublicKey(), b)
	e.agentMust(400, "POST", "/v1/agent/push", token, map[string]any{"e2e": plain})
	stale, _ := agentSeal(newKey(t).PublicKey(), sessSK, sid, b, nil)
	e.agentMust(409, "POST", "/v1/agent/push", token, map[string]any{"e2e": stale})
	e.agentMust(401, "POST", "/v1/agent/push", f.ak, map[string]any{"e2e": plain})

	// 设备回复；agent 取走、解开；服务器说错 msg_id 就解不开
	code, out, n1 := f.reply(t, f.tokB, sid, sessPub, msgID, "删")
	if code != 200 {
		t.Fatalf("回复失败：%d %v", code, out)
	}
	rid := int64(out["reply_id"].(float64))
	rs := e.agentMust(200, "GET", "/v1/agent/replies", token, nil)["replies"].([]any)
	if len(rs) != 1 {
		t.Fatalf("应取到 1 条回复：%v", rs)
	}
	r0 := rs[0].(map[string]any)
	got, err := agentReplyOpen(sessSK, f.acctSK.PublicKey(), r0["e2e"].(string), int64(r0["msg_id"].(float64)))
	if err != nil || got.Text != "删" || got.N != n1 {
		t.Fatalf("agent 解不开回复：%v %v", got, err)
	}
	if _, err := agentReplyOpen(sessSK, f.acctSK.PublicKey(), r0["e2e"].(string), msgID+1); err == nil {
		t.Fatal("msg_id 被改了也解开了")
	}
	if _, err := agentReplyOpen(sessSK, newKey(t).PublicKey(), r0["e2e"].(string), msgID); err == nil {
		t.Fatal("冒充的账号公钥也解开了")
	}
	// 回复不是 agent 消息：400；信封会话不对：400
	pkey, _ := e.h.st.CreatePushkey(f.uid, "p")
	normal, _, _ := e.h.st.InsertMessage(NewMessage{UserID: f.uid, PushkeyID: pkey.ID, Topic: "x", Priority: 3, Type: "e2e", Text: "t", E2E: plain})
	if c, _, _ := f.reply(t, f.tokB, sid, sessPub, normal, "x"); c != 400 {
		t.Fatalf("回复普通消息应 400：%d", c)
	}
	if c, _, _ := f.reply(t, f.tokB, "asffffffffffffffff", sessPub, msgID, "x"); c != 400 {
		t.Fatalf("信封会话不对应 400：%d", c)
	}

	// 回执：服务器删掉回复密文、保存回执；设备核对回执来自这个会话
	rb, _ := json.Marshal(agentPayload{V: 1, Kind: "receipt", ReplyID: rid, N: n1, ReceivedAt: now()})
	rc, _ := agentSeal(f.acctSK.PublicKey(), sessSK, sid, rb, nil)
	e.agentMust(400, "POST", "/v1/agent/replies/ack", token, map[string]any{"receipts": []any{map[string]any{"reply_id": rid, "e2e": plain}}})
	if a := e.agentMust(200, "POST", "/v1/agent/replies/ack", token, map[string]any{"receipts": []any{map[string]any{"reply_id": rid, "e2e": rc}}}); a["acked"] != float64(1) {
		t.Fatalf("确认收到：%v", a)
	}
	if a := e.agentMust(200, "POST", "/v1/agent/replies/ack", token, map[string]any{"receipts": []any{map[string]any{"reply_id": rid, "e2e": rc}}}); a["acked"] != float64(0) {
		t.Fatal("重复确认不应再算")
	}
	if rs := e.agentMust(200, "GET", "/v1/agent/replies", token, nil)["replies"].([]any); len(rs) != 0 {
		t.Fatal("确认后不应再取到")
	}
	var leftover string
	e.h.st.db.QueryRow(`SELECT e2e FROM agent_replies WHERE id=?`, rid).Scan(&leftover)
	if leftover != "" {
		t.Fatal("确认后服务器应删掉回复密文")
	}
	stl := e.agentMust(200, "GET", "/v1/agent/replies/status?msg_id="+strconv.FormatInt(msgID, 10), f.tokA, nil)["replies"].([]any)
	s0 := stl[0].(map[string]any)
	if s0["state"] != replyReceived || s0["device"] != "phone" || s0["received_at"] == nil {
		t.Fatalf("回复状态不对：%v", s0)
	}
	rpt, err := agentOpen(f.acctSK, sessPub, s0["receipt"].(string))
	var rp agentPayload
	json.Unmarshal(rpt, &rp)
	if err != nil || rp.Kind != "receipt" || rp.ReplyID != rid || rp.N != n1 {
		t.Fatalf("回执核对失败：%v %v", rp, err)
	}
	cpt, err := e2eOpenMessage(f.acctSK, s0["copy"].(string))
	if err != nil || !bytes.Contains(cpt, []byte(`"text":"删"`)) {
		t.Fatalf("回复副本解不开：%v", err)
	}

	// 长轮询：等待期间设备回复，agent 立即拿到
	done := make(chan []any, 1)
	go func() {
		_, o := e.call("GET", "/v1/agent/replies?wait=10", token, nil)
		rs, _ := o["replies"].([]any)
		done <- rs
	}()
	time.Sleep(200 * time.Millisecond)
	start := time.Now()
	f.reply(t, f.tokA, sid, sessPub, msgID, "保留")
	select {
	case rs := <-done:
		if len(rs) != 1 || time.Since(start) > 3*time.Second {
			t.Fatalf("长轮询没有及时返回：%v", rs)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("长轮询没有醒来")
	}

	// 结束会话：令牌作废，正在等的长轮询返回 401，没取走的回复删掉，再回复 409
	go func() {
		c, _ := e.call("GET", "/v1/agent/replies?wait=10", token, nil)
		done <- []any{c}
	}()
	time.Sleep(200 * time.Millisecond)
	e.agentMust(200, "DELETE", "/v1/agent/sessions/"+sid, f.tokB, nil)
	select {
	case r := <-done:
		if r[0] != 401 && r[0] != float64(401) {
			// 长轮询要么返回 401，要么在结束前已经拿到上一条（取决于时序）；再请求一次一定是 401
			e.agentMust(401, "GET", "/v1/agent/replies", token, nil)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("结束会话后长轮询没有醒来")
	}
	e.agentMust(401, "GET", "/v1/agent/replies", token, nil)
	if c, _, _ := f.reply(t, f.tokB, sid, sessPub, msgID, "晚了"); c != 409 {
		t.Fatalf("会话结束后回复应 409：%d", c)
	}
	var pending int
	e.h.st.db.QueryRow(`SELECT COUNT(*) FROM agent_replies WHERE session_id=? AND e2e!=''`, sid).Scan(&pending)
	if pending != 0 {
		t.Fatal("结束会话后不应留回复密文")
	}
}

func TestAgentLoginRules(t *testing.T) {
	f := newAgentFixture(t)
	e := f.e
	acctPub := f.acctSK.PublicKey().Bytes()
	newReq := func() (string, []byte, []byte) {
		sk := newKey(t)
		nb := randBytes(32)
		pub := sk.PublicKey().Bytes()
		sid := e.agentMust(200, "POST", "/v1/agent/sessions", f.ak, map[string]any{"name": "x", "pub": b64of(pub),
			"commit": b64of(agentCommit(pub, acctPub, nb))})["session_id"].(string)
		return sid, pub, nb
	}
	e.agentMust(400, "POST", "/v1/agent/sessions", f.ak, map[string]any{"name": "x", "pub": "abc", "commit": b64of(randBytes(32))})
	s1, _, nb1 := newReq()
	// 还没出 na 就揭晓：409；不是这把 key 的请求查不到
	e.agentMust(409, "POST", "/v1/agent/sessions/"+s1+"/reveal", f.ak, map[string]any{"nonce": b64of(nb1)})
	// 设备 A 接手后，设备 B 不能再出 na、也不能批准
	e.agentMust(200, "POST", "/v1/agent/sessions/"+s1+"/challenge", f.tokA, map[string]any{"nonce": b64of(randBytes(32))})
	e.agentMust(409, "POST", "/v1/agent/sessions/"+s1+"/challenge", f.tokB, map[string]any{"nonce": b64of(randBytes(32))})
	// 还没揭晓就批准：409
	att, _ := agentAttestSeal(f.acctSK.Bytes(), agentAttest{SessionID: s1})
	e.agentMust(409, "POST", "/v1/agent/sessions/"+s1+"/approve", f.tokA, map[string]any{"attest": att})
	e.agentMust(200, "POST", "/v1/agent/sessions/"+s1+"/reveal", f.ak, map[string]any{"nonce": b64of(nb1)})
	e.agentMust(409, "POST", "/v1/agent/sessions/"+s1+"/reveal", f.ak, map[string]any{"nonce": b64of(nb1)}) // 只能揭晓一次
	e.agentMust(409, "POST", "/v1/agent/sessions/"+s1+"/approve", f.tokB, map[string]any{"attest": att})
	e.agentMust(400, "POST", "/v1/agent/sessions/"+s1+"/approve", f.tokA, map[string]any{"attest": "hjp1.xx"})
	// 拒绝：agent 看到 denied、没有令牌
	e.agentMust(200, "POST", "/v1/agent/sessions/"+s1+"/deny", f.tokB, nil)
	if st := e.agentMust(200, "GET", "/v1/agent/sessions/"+s1, f.ak, nil); st["state"] != agentDenied || st["token"] != nil {
		t.Fatalf("拒绝后的状态：%v", st)
	}
	// 等待批准的请求最多 3 个；10 分钟没批准自动作废
	newReq()
	newReq()
	s4, _, _ := newReq()
	e.agentMust(429, "POST", "/v1/agent/sessions", f.ak, map[string]any{"name": "x", "pub": b64of(randBytes(32)), "commit": b64of(randBytes(32))})
	e.h.st.db.Exec(`UPDATE agent_sessions SET created_at=? WHERE id=?`, now()-agentPendingTTL-1, s4)
	if st := e.agentMust(200, "GET", "/v1/agent/sessions/"+s4, f.ak, nil); st["state"] != agentExpired {
		t.Fatalf("过期的请求：%v", st)
	}
	newReq()

	// 同时在线最多 3 个会话
	f2 := newAgentFixture(t)
	var toks []string
	for i := 0; i < 4; i++ {
		_, tok, _ := f2.login(t, "agent"+strconv.Itoa(i))
		toks = append(toks, tok)
	}
	for _, tok := range toks[:3] {
		f2.e.agentMust(200, "GET", "/v1/agent/replies", tok, nil)
	}
	f2.e.agentMust(429, "GET", "/v1/agent/replies", toks[3], nil)
	f2.e.agentMust(200, "DELETE", "/v1/agent/session", toks[0], nil) // agent 自己退出
	f2.e.agentMust(401, "GET", "/v1/agent/replies", toks[0], nil)
	f2.e.agentMust(200, "GET", "/v1/agent/replies", toks[3], nil)

	// 吊销 Agent key：它登录的会话全部结束，key 本身也不能再用
	id := int64(f2.e.agentMust(200, "GET", "/v1/agent/keys", f2.tokA, nil)["keys"].([]any)[0].(map[string]any)["id"].(float64))
	f2.e.agentMust(200, "DELETE", "/v1/agent/keys/"+strconv.FormatInt(id, 10), f2.tokB, nil)
	f2.e.agentMust(401, "GET", "/v1/agent/replies", toks[3], nil)
	f2.e.agentMust(401, "GET", "/v1/agent/info", f2.ak, nil)
	f2.e.agentMust(200, "POST", "/v1/agent/keys", f2.tokB, nil) // 吊销后可以再建一把

	// 重置加密：会话全部结束（证明和钉住的公钥都是旧钥匙的）
	f3 := newAgentFixture(t)
	_, tok3, _ := f3.login(t, "r")
	reset, _, _ := keyBody(t, newKey(t), f3.pw)
	reset["current_auth_key"] = b64of(f3.auth1)
	f3.e.must(200, "POST", "/v1/e2e/reset", f3.tokA, reset)
	f3.e.agentMust(401, "GET", "/v1/agent/replies", tok3, nil)

	// 删除账号：agent 的表一起清空
	if _, err := f3.e.h.st.DeleteAccount(f3.uid); err != nil {
		t.Fatal(err)
	}
	var left int
	f3.e.h.st.db.QueryRow(`SELECT (SELECT COUNT(*) FROM agent_keys WHERE user_id=?)+(SELECT COUNT(*) FROM agent_sessions WHERE user_id=?)+(SELECT COUNT(*) FROM agent_replies WHERE user_id=?)`,
		f3.uid, f3.uid, f3.uid).Scan(&left)
	if left != 0 {
		t.Fatalf("删号后 agent 表还剩 %d 行", left)
	}
}

func mustJSON(v any) []byte { b, _ := json.Marshal(v); return b }

// 跨平台向量：固定钥匙和一次性密钥，Go 生成，Rust 核心（core/tests/agent.rs）逐字节核对
func TestAgentVectors(t *testing.T) {
	acct, _ := e2eDeriveKeyPair([]byte("huijian agent vector account"))
	sess, _ := e2eDeriveKeyPair([]byte("huijian agent vector session"))
	eph1, _ := e2eDeriveKeyPair([]byte("huijian agent vector eph 1"))
	eph2, _ := e2eDeriveKeyPair([]byte("huijian agent vector eph 2"))
	na, nb := bytes.Repeat([]byte{0xa1}, 32), bytes.Repeat([]byte{0xb2}, 32)
	sid := "as0123456789abcdef"
	msg := []byte(`{"v":1,"kind":"message","text":"要不要删掉 3 个异常样本？","ask":true,"choices":["删","保留"],"seq":1,"sent_at":1763600000}`)
	reply := []byte(`{"v":1,"text":"删","n":"AAECAwQFBgcICQoLDA0ODw","sent_at":1763600100,"device":"mac"}`)
	env, err := agentSeal(acct.PublicKey(), sess, sid, msg, eph1)
	if err != nil {
		t.Fatal(err)
	}
	rep, err := agentReplySeal(sess.PublicKey(), acct, sid, 42, reply, eph2)
	if err != nil {
		t.Fatal(err)
	}
	attKey := agentAttestKey(acct.Bytes())
	attPT, _ := json.Marshal(agentAttest{SessionID: sid, Pub: b64of(sess.PublicKey().Bytes()), Name: "家里 Claude Code", ApprovedAt: 1763600000})
	att, _ := e2eWrapNonce(agentAttestPfx, attKey, attPT, bytes.Repeat([]byte{0x0c}, 12))
	v := map[string]any{
		"account_sk": b64of(acct.Bytes()), "account_pub": b64of(acct.PublicKey().Bytes()),
		"session_sk": b64of(sess.Bytes()), "session_pub": b64of(sess.PublicKey().Bytes()),
		"na": b64of(na), "nb": b64of(nb),
		"commit":     b64of(agentCommit(sess.PublicKey().Bytes(), acct.PublicKey().Bytes(), nb)),
		"sas":        agentSAS(sess.PublicKey().Bytes(), acct.PublicKey().Bytes(), na, nb),
		"session_id": sid, "message": string(msg), "message_envelope": env,
		"msg_id": 42, "reply": string(reply), "reply_envelope": rep,
		"attest_plain": string(attPT), "attest": att,
	}
	// 自己先核对一遍
	if pt, err := agentOpen(acct, sess.PublicKey(), env); err != nil || !bytes.Equal(pt, msg) {
		t.Fatal("hje2 自检失败")
	}
	if r, err := agentReplyOpen(sess, acct.PublicKey(), rep, 42); err != nil || r.Text != "删" {
		t.Fatal("hjq1 自检失败")
	}
	if a, err := agentAttestOpen(acct.Bytes(), att); err != nil || a.SessionID != sid {
		t.Fatal("hja1 自检失败")
	}
	const file = "testdata/agent_vectors.json"
	if *updateAgentVectors {
		b, _ := json.MarshalIndent(v, "", "  ")
		if err := os.WriteFile(file, append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	raw, err := os.ReadFile(file)
	if err != nil {
		t.Fatalf("缺少 %s：用 -update-agent-vectors 生成", file)
	}
	var old map[string]any
	json.Unmarshal(raw, &old)
	for k, want := range v {
		if w, _ := json.Marshal(want); !bytes.Equal(w, mustJSON(old[k])) {
			t.Fatalf("向量 %s 变了：%s ≠ %s", k, w, mustJSON(old[k]))
		}
	}
}
