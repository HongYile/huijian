package main

// 0.8.0「默认自动加密」：恢复码可选、重置加密、服务器代加密（docs/e2ee-client.md §11）

import (
	"bytes"
	"crypto/ecdh"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// keyBody：setup / reset 的请求体（新钥匙对 sk、用 password 派生的新凭证和密码副本；不带恢复码）
func keyBody(t *testing.T, sk *ecdh.PrivateKey, password string) (map[string]any, []byte, []byte) {
	t.Helper()
	salt, saltHex := newSalt(t)
	auth, unlock := e2ePasswordKeys(password, salt)
	wrap, err := e2eWrap("hjp1", unlock, sk.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	return map[string]any{"pub": b64of(sk.PublicKey().Bytes()), "auth_salt": saltHex, "auth_key": b64of(auth), "password_wrap": wrap}, auth, unlock
}

func newKey(t *testing.T) *ecdh.PrivateKey {
	sk, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return sk
}

func (e *e2eEnv) changes(userID int64, kind string) int {
	var n int
	e.h.st.db.QueryRow(`SELECT COUNT(*) FROM msg_changes WHERE user_id=? AND msg_id=0 AND kind=?`, userID, kind).Scan(&n)
	return n
}

func TestE2EResetAndOptionalRecovery(t *testing.T) {
	e := newE2EEnv(t)
	const pw = "dora-pass-0001"
	u, _ := e.h.st.CreateAccount("dora", pw)
	pk, _ := e.h.st.CreatePushkey(u.ID, "a")
	_, tokA, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "mac", Platform: "macos", Fingerprint: "fp-r-000001"})
	dB, tokB, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "phone", Platform: "android", Fingerprint: "fp-r-000002"})

	sk1 := newKey(t)
	body, auth1, unlock1 := keyBody(t, sk1, pw)
	body["current_password"] = pw
	// 没开启过：reset 被拒，要先 setup
	e.must(409, "POST", "/v1/e2e/reset", tokA, body)

	// setup 不带恢复码
	if kid := e.must(200, "POST", "/v1/e2e/setup", tokA, body)["kid"]; kid != e2eKID(sk1.PublicKey().Bytes()) {
		t.Fatalf("kid = %v", kid)
	}
	st := e.must(200, "GET", "/v1/e2e", tokA, nil)
	if st["enabled"] != true || st["recovery_wrap"] != "" || st["has_password_wrap"] != true || st["server_seal"] != true || len(st["keys"].([]any)) != 1 {
		t.Fatalf("不带恢复码开启后的状态：%v", st)
	}
	// 之后再补恢复码；B 拿到转交副本、又有一个进行中的批准请求
	code := make([]byte, 16)
	rand.Read(code)
	recWrap, _ := e2eWrap("hjr1", e2eRecoveryKey(code), sk1.Bytes())
	e.must(200, "PUT", "/v1/e2e/recovery", tokA, map[string]any{"recovery_wrap": recWrap, "current_auth_key": b64of(auth1)})
	skB := newKey(t)
	e.h.st.db.Exec(`INSERT INTO e2e_wraps(user_id,kind,device_id,blob,created_at) VALUES(?,?,?,?,1)`, u.ID, wrapDevice, dB.ID, "hjg1.old-grant")
	nb := make([]byte, 32)
	rand.Read(nb)
	commit := b64of(e2eCommit(skB.PublicKey().Bytes(), sk1.PublicKey().Bytes(), nb))
	e.must(200, "PUT", "/v1/e2e/device", tokB, map[string]any{"pub": b64of(skB.PublicKey().Bytes()), "request": true, "commit": commit})
	e.must(200, "POST", "/v1/e2e/challenge", tokA, map[string]any{"device_id": dB.ID, "nonce": b64of(nb)})
	oldEnv, _ := e2eSealMessage(sk1.PublicKey(), []byte(`{"v":1,"text":"旧钥匙"}`))
	if c, out := e.push(map[string]string{"pushkey": pk.Key, "e2e": oldEnv}); c != 200 {
		t.Fatalf("旧钥匙发送：%d %v", c, out)
	}

	// 重置：当前密码不对 / 缺少新密码副本 / 公钥格式不对都拒绝
	sk2 := newKey(t)
	reset, auth2, unlock2 := keyBody(t, sk2, pw)
	reset["current_auth_key"] = b64of(make([]byte, 32))
	e.must(403, "POST", "/v1/e2e/reset", tokA, reset)
	reset["current_auth_key"] = b64of(auth1)
	for k, bad := range map[string]any{"password_wrap": "", "pub": "short", "recovery_wrap": "hjr1.bad"} {
		b := map[string]any{}
		for kk, v := range reset {
			b[kk] = v
		}
		b[k] = bad
		e.must(400, "POST", "/v1/e2e/reset", tokA, b)
	}
	before := e.changes(u.ID, changeE2E)
	if kid := e.must(200, "POST", "/v1/e2e/reset", tokA, reset)["kid"]; kid != e2eKID(sk2.PublicKey().Bytes()) {
		t.Fatalf("reset kid = %v", kid)
	}
	if e.changes(u.ID, changeE2E) <= before {
		t.Fatal("重置加密没有记 e2e 变更")
	}

	// 旧钥匙停用但保留；所有 wrap 删掉后只剩新的密码副本；进行中的批准作废
	st = e.must(200, "GET", "/v1/e2e", tokA, nil)
	keys := st["keys"].([]any)
	if len(keys) != 2 || st["enabled"] != true {
		t.Fatalf("重置后的钥匙：%v", st)
	}
	for _, k := range keys {
		k := k.(map[string]any)
		wantActive := k["pub"] == b64of(sk2.PublicKey().Bytes())
		if k["active"] != wantActive {
			t.Fatalf("钥匙状态不对：%v", keys)
		}
	}
	if st["recovery_wrap"] != "" || st["has_password_wrap"] != true || len(st["requests"].([]any)) != 0 {
		t.Fatalf("重置后恢复码 / 请求还在：%v", st)
	}
	var wraps int
	e.h.st.db.QueryRow(`SELECT COUNT(*) FROM e2e_wraps WHERE user_id=?`, u.ID).Scan(&wraps)
	if wraps != 1 {
		t.Fatalf("重置后应只剩新的密码副本，实际 %d 个 wrap", wraps)
	}
	if dev := e.must(200, "GET", "/v1/e2e", tokB, nil)["device"].(map[string]any); dev["grant"] != "" || dev["requested"] != false || dev["challenge"] != "" {
		t.Fatalf("B 的转交副本 / 请求没清掉：%v", dev)
	}
	// setup 不能再用；用旧钥匙加密的新消息被拒，新钥匙可以
	e.must(409, "POST", "/v1/e2e/setup", tokA, reset)
	if c, _ := e.push(map[string]string{"pushkey": pk.Key, "e2e": oldEnv}); c != 400 {
		t.Fatalf("停用的旧钥匙还能收：%d", c)
	}
	newEnv, _ := e2eSealMessage(sk2.PublicKey(), []byte(`{"v":1,"text":"新钥匙"}`))
	if c, _ := e.push(map[string]string{"pushkey": pk.Key, "e2e": newEnv}); c != 200 {
		t.Fatalf("新钥匙发送：%d", c)
	}
	// 新凭证登录，密码副本解开的是新私钥；旧凭证失效
	e.must(403, "POST", "/v1/login", "", map[string]any{"username": "dora", "auth_key": b64of(auth1)})
	out := e.must(200, "POST", "/v1/login", "", map[string]any{"username": "dora", "auth_key": b64of(auth2), "name": "x"})
	if got, err := e2eUnwrap("hjp1", unlock2, out["e2e"].(map[string]any)["password_wrap"].(string)); err != nil || !bytes.Equal(got, sk2.Bytes()) {
		t.Fatalf("重置后密码副本解不开：%v", err)
	}
	if _, err := e2eUnwrap("hjp1", unlock1, out["e2e"].(map[string]any)["password_wrap"].(string)); err == nil {
		t.Fatal("旧密码副本不该还能用")
	}
	// 同一把公钥重试（没收到上次响应）：照样成功，仍然只有它一把启用
	e.must(200, "POST", "/v1/e2e/reset", tokA, map[string]any{"pub": reset["pub"], "auth_salt": reset["auth_salt"], "auth_key": reset["auth_key"],
		"password_wrap": reset["password_wrap"], "current_auth_key": b64of(auth2)})
	var active int
	e.h.st.db.QueryRow(`SELECT COUNT(*) FROM e2e_keys WHERE user_id=? AND active=1`, u.ID).Scan(&active)
	if active != 1 {
		t.Fatalf("启用中的钥匙 %d 把", active)
	}

	// 管理员重设密码后账号回到旧登录方式：reset 接受 current_password_key（PBKDF2）
	if err := e.h.st.SetCredentials(u.ID, "dora", "admin-set-pass-9"); err != nil {
		t.Fatal(err)
	}
	pre := e.must(200, "GET", "/v1/prelogin?username=dora", "", nil)
	if pre["kdf"] != "pbkdf2-sha256" {
		t.Fatalf("重设后 prelogin = %v", pre)
	}
	psalt, _ := hex.DecodeString(pre["salt"].(string))
	pwKey, _ := pbkdf2.Key(sha256.New, "admin-set-pass-9", psalt, pbkdfIter, 32)
	sk3 := newKey(t)
	reset3, auth3, _ := keyBody(t, sk3, "admin-set-pass-9")
	reset3["current_auth_key"] = b64of(auth2) // 旧凭证已经作废
	e.must(403, "POST", "/v1/e2e/reset", tokA, reset3)
	delete(reset3, "current_auth_key")
	reset3["current_password_key"] = b64of(pwKey)
	e.must(200, "POST", "/v1/e2e/reset", tokA, reset3)
	if out := e.must(200, "GET", "/v1/prelogin?username=dora", "", nil); out["kdf"] != "argon2id" {
		t.Fatalf("legacy 重置后应升级到新登录协议：%v", out)
	}
	e.must(200, "POST", "/v1/login", "", map[string]any{"username": "dora", "auth_key": b64of(auth3), "name": "y"})
	if pub, _ := e.h.st.E2EActivePub(u.ID); pub == nil || !bytes.Equal(pub.Bytes(), sk3.PublicKey().Bytes()) {
		t.Fatal("active 公钥不是最新重置的那把")
	}
	if n := len(e.h.st.E2EKeys(u.ID)); n != 3 {
		t.Fatalf("旧钥匙应全部保留，实际 %d 把", n)
	}
}

// pushFiles：multipart 发送，附件名自定
func (e *e2eEnv) pushFiles(fields map[string]string, files map[string][]byte, order []string) (int, map[string]any) {
	e.t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for k, v := range fields {
		mw.WriteField(k, v)
	}
	for _, name := range order {
		fw, _ := mw.CreateFormFile("file", name)
		fw.Write(files[name])
	}
	mw.Close()
	resp, err := http.Post(e.srv.URL+"/message/push", mw.FormDataContentType(), &buf)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func (e *e2eEnv) download(tok, attID string) []byte {
	e.t.Helper()
	req, _ := http.NewRequest("GET", e.srv.URL+"/v1/att/"+attID, nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return b
}

// scanLeaks：数据库文件（含 WAL）、附件目录（文件内容和路径）、临时目录里都不能出现 markers
func scanLeaks(t *testing.T, e *e2eEnv, markers ...string) {
	t.Helper()
	e.h.st.db.Exec(`PRAGMA wal_checkpoint(PASSIVE)`)
	check := func(where string, b []byte) {
		for _, m := range markers {
			if bytes.Contains(b, []byte(m)) {
				t.Fatalf("%s 里出现了明文 %q", where, m)
			}
		}
	}
	for _, f := range []string{"t.db", "t.db-wal"} {
		if b, err := os.ReadFile(filepath.Join(e.h.dataDir, f)); err == nil {
			check(f, b)
		}
	}
	filepath.WalkDir(e.h.paths.files, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		check("附件路径 "+p, []byte(p))
		if !d.IsDir() {
			b, _ := os.ReadFile(p)
			check("附件 "+p, b)
		}
		return nil
	})
	if ents, _ := os.ReadDir(e.h.tmpDir); len(ents) != 0 {
		t.Fatalf("临时目录里还有 %d 个文件（明文临时文件没删）", len(ents))
	}
}

func openPayload(t *testing.T, sk *ecdh.PrivateKey, env string) e2ePayload {
	t.Helper()
	pt, err := e2eOpenMessage(sk, env)
	if err != nil {
		t.Fatalf("解不开信封：%v", err)
	}
	var p e2ePayload
	if err := json.Unmarshal(pt, &p); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestE2EServerSeal(t *testing.T) {
	e := newE2EEnv(t)
	fb := &fakeBark{}
	bark := httptest.NewServer(fb)
	defer bark.Close()

	u, _ := e.h.st.CreateAccount("erin", "erin-pass-0001")
	pk, _ := e.h.st.CreatePushkey(u.ID, "train")
	dev, tok, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "phone", Platform: "ios", Fingerprint: "fp-s-000001"})
	e.h.st.SetBarkConfig(dev.ID, barkConfig{URL: bark.URL + "/KEY"})
	sk := newKey(t)
	body, _, _ := keyBody(t, sk, "erin-pass-0001")
	body["current_password"] = "erin-pass-0001"
	e.must(200, "POST", "/v1/e2e/setup", tok, body)

	big := bytes.Repeat([]byte("SEAL-FILE-MARKER "), 9000) // 约 150 KB：多块
	files := map[string][]byte{"SEAL-NAME 报告.txt": big, "empty.log": nil}
	order := []string{"SEAL-NAME 报告.txt", "empty.log"}
	c, out := e.pushFiles(map[string]string{"pushkey": pk.Key, "text": "SEAL-TITLE 训练完成", "desp": "SEAL-BODY **val_loss 0.198**",
		"priority": "4", "topic": "train", "idem": "seal-1"}, files, order)
	if c != 200 {
		t.Fatalf("代加密发送失败：%d %v", c, out)
	}
	ms := e.messages(tok)
	m := ms[len(ms)-1]
	if m["sealed"] != "server" || m["type"] != "e2e" || m["text"] != e2ePlaceholder || (m["desp"] != nil && m["desp"] != "") ||
		m["doc"] != nil || m["preview"] != nil || m["priority"].(float64) != 4 || m["topic"] != "train" {
		t.Fatalf("代加密消息的字段：%v", m)
	}
	env := m["e2e"].(string)
	if !strings.HasPrefix(env, e2eMsgPrefix+e2eKID(sk.PublicKey().Bytes())+".") {
		t.Fatalf("信封 kid 不对：%.30s", env)
	}
	p := openPayload(t, sk, env)
	if p.V != 1 || p.Text != "SEAL-TITLE 训练完成" || p.Desp != "SEAL-BODY **val_loss 0.198**" || p.Type != "markdown" || len(p.Atts) != 2 {
		t.Fatalf("载荷：%+v", p)
	}
	atts := m["attachments"].([]any)
	for i, name := range order {
		a := atts[i].(map[string]any)
		want := files[name]
		if a["name"] != "encrypted-"+string(rune('1'+i))+".bin" || a["mime"] != "application/octet-stream" || a["size"].(float64) != float64(e2eCipherSize(int64(len(want)))) {
			t.Fatalf("服务器上的附件 %d：%v", i, a)
		}
		if p.Atts[i].Name != name || p.Atts[i].Size != int64(len(want)) || !strings.HasPrefix(p.Atts[i].Mime, "text/plain") && name != "empty.log" {
			t.Fatalf("信封里的附件 %d：%+v", i, p.Atts[i])
		}
		ct := e.download(tok, a["id"].(string))
		if !bytes.HasPrefix(ct, []byte(e2eFileMagic)) {
			t.Fatalf("附件 %d 不是 HJF1 密文", i)
		}
		key, _ := b64.DecodeString(p.Atts[i].Key)
		var pt bytes.Buffer
		if err := e2eDecryptFile(key, bytes.NewReader(ct), &pt); err != nil || !bytes.Equal(pt.Bytes(), want) {
			t.Fatalf("附件 %d 解密：%v", i, err)
		}
	}
	// Bark 照旧转发明文（服务器本来就转发明文给 Bark）
	deadline := time.Now().Add(3 * time.Second)
	var got []url.Values
	for len(got) == 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
		got = fb.take()
	}
	if len(got) != 1 || got[0].Get("title") != "SEAL-TITLE 训练完成" || !strings.Contains(got[0].Get("body"), "val_loss 0.198") {
		t.Fatalf("Bark 转发：%v", got)
	}
	// 数据库、附件目录、临时目录里没有任何明文；SSE / 长轮询和列表接口共用 Messages，已在上面核对
	scanLeaks(t, e, "SEAL-TITLE", "SEAL-BODY", "SEAL-FILE-MARKER", "SEAL-NAME", "val_loss")

	// 幂等键重复：不再加密、不多存附件，返回原来那条
	var nAtt int
	e.h.st.db.QueryRow(`SELECT COUNT(*) FROM attachments`).Scan(&nAtt)
	c, out2 := e.pushFiles(map[string]string{"pushkey": pk.Key, "text": "SEAL-TITLE 训练完成", "idem": "seal-1"}, files, order)
	var nAtt2 int
	e.h.st.db.QueryRow(`SELECT COUNT(*) FROM attachments`).Scan(&nAtt2)
	if c != 200 || out2["content"].(map[string]any)["result"].([]any)[0] != out["content"].(map[string]any)["result"].([]any)[0] || nAtt2 != nAtt {
		t.Fatalf("幂等重试：%d %v，附件 %d → %d", c, out2, nAtt, nAtt2)
	}
	scanLeaks(t, e, "SEAL-FILE-MARKER", "SEAL-NAME")

	// 一次发给两个账号：开了加密的那个代加密，另一个照旧明文（附件各存各的）
	bob, _ := e.h.st.CreateAccount("bob", "bob-pass-1234")
	pkBob, _ := e.h.st.CreatePushkey(bob.ID, "b")
	_, tokBob, _, _ := e.h.st.LoginDevice(pairReq{UserID: bob.ID, Name: "b", Platform: "macos", Fingerprint: "fp-s-000002"})
	if c, out := e.pushFiles(map[string]string{"pushkey": pk.Key + "," + pkBob.Key, "text": "MIX-TITLE"}, map[string][]byte{"mix.txt": []byte("MIX-FILE")}, []string{"mix.txt"}); c != 200 {
		t.Fatalf("混合发送：%d %v", c, out)
	}
	mb := e.messages(tokBob)
	if mb[0]["text"] != "MIX-TITLE" || mb[0]["sealed"] != nil || string(e.download(tokBob, mb[0]["attachments"].([]any)[0].(map[string]any)["id"].(string))) != "MIX-FILE" {
		t.Fatalf("没开加密的账号应收到明文：%v", mb[0])
	}
	ms = e.messages(tok)
	m = ms[len(ms)-1]
	if m["sealed"] != "server" || openPayload(t, sk, m["e2e"].(string)).Text != "MIX-TITLE" {
		t.Fatalf("混合发送时开了加密的账号：%v", m)
	}
	if ct := e.download(tok, m["attachments"].([]any)[0].(map[string]any)["id"].(string)); bytes.Contains(ct, []byte("MIX-FILE")) {
		t.Fatal("开了加密的账号拿到了明文附件")
	}

	// 发送端加密的消息没有 sealed 字段
	senderEnv, _ := e2eSealMessage(sk.PublicKey(), []byte(`{"v":1,"text":"x"}`))
	e.push(map[string]string{"pushkey": pk.Key, "e2e": senderEnv})
	ms = e.messages(tok)
	if m := ms[len(ms)-1]; m["e2e"] != senderEnv || m["sealed"] != nil {
		t.Fatalf("发送端加密的消息：%v", m)
	}

	// 管理后台测试消息、系统通知同样代加密；管理后台页面只显示占位文字
	adm := httptest.NewServer(e.h.adminMux())
	defer adm.Close()
	sess, _ := e.h.st.CreateSession("test", time.Hour, false)
	admReq := func(method, path string, form url.Values) string {
		req, _ := http.NewRequest(method, adm.URL+path, strings.NewReader(form.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.AddCookie(&http.Cookie{Name: cookieName, Value: sess})
		req.AddCookie(&http.Cookie{Name: acctCookie, Value: strconv.FormatInt(u.ID, 10)})
		resp, err := noRedirect.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return string(b)
	}
	admReq("POST", "/test", url.Values{"text": {"ADMIN-TEST-TITLE"}, "desp": {"ADMIN-TEST-BODY"}, "u": {strconv.FormatInt(u.ID, 10)}})
	e.h.userID = u.ID
	e.h.notice("seal-test", 4, "NOTICE-TITLE", "NOTICE-BODY")
	ms = e.messages(tok)
	for _, m := range ms[len(ms)-2:] {
		if m["sealed"] != "server" {
			t.Fatalf("服务端生成的消息没有代加密：%v", m)
		}
	}
	if p := openPayload(t, sk, ms[len(ms)-2]["e2e"].(string)); p.Text != "ADMIN-TEST-TITLE" || p.Desp != "ADMIN-TEST-BODY" || p.Type != "markdown" {
		t.Fatalf("管理后台测试消息载荷：%+v", p)
	}
	if p := openPayload(t, sk, ms[len(ms)-1]["e2e"].(string)); p.Text != "NOTICE-TITLE" {
		t.Fatalf("系统通知载荷：%+v", p)
	}
	page := admReq("GET", "/messages", nil)
	if !strings.Contains(page, "服务器加密") || !strings.Contains(page, "端到端加密") {
		t.Fatal("管理后台消息页应标出加密消息")
	}
	for _, leak := range []string{"SEAL-", "ADMIN-TEST", "NOTICE-", "MIX-TITLE"} {
		if strings.Contains(page, leak) {
			t.Fatalf("管理后台消息页出现了明文 %q", leak)
		}
	}
	// Pushkey 页同时显示普通 key 和加密发送密钥（用数据库里的 active 公钥）
	keysPage := admReq("GET", "/keys", nil)
	if !strings.Contains(keysPage, pk.Key+e2eSendKeySep+b64of(sk.PublicKey().Bytes())) || !strings.Contains(keysPage, "普通 pushkey") {
		t.Fatal("Pushkey 页没有加密发送密钥")
	}
	scanLeaks(t, e, "SEAL-TITLE", "SEAL-BODY", "SEAL-FILE-MARKER", "SEAL-NAME", "ADMIN-TEST", "NOTICE-TITLE", "NOTICE-BODY")

	// 设置：GET 返回 server_seal；PATCH 至少要一项
	if st := e.must(200, "GET", "/v1/e2e", tok, nil); st["server_seal"] != true {
		t.Fatalf("server_seal 默认应为开：%v", st)
	}
	e.must(400, "PATCH", "/v1/e2e", tok, map[string]any{})

	// 只接受加密消息：明文直接拒收，不走代加密
	e.must(200, "PATCH", "/v1/e2e", tok, map[string]any{"e2e_only": true})
	if c, _ := e.push(map[string]string{"pushkey": pk.Key, "text": "ONLY-PLAIN"}); c != 403 {
		t.Fatalf("只收加密时明文应被拒：%d", c)
	}
	e.must(200, "PATCH", "/v1/e2e", tok, map[string]any{"e2e_only": false})

	// 代加密始终开启：server_seal 不能关，传 true 不改任何东西
	e.must(400, "PATCH", "/v1/e2e", tok, map[string]any{"server_seal": false})
	if out := e.must(200, "PATCH", "/v1/e2e", tok, map[string]any{"server_seal": true}); out["server_seal"] != true || out["e2e_only"] != false {
		t.Fatalf("PATCH 响应：%v", out)
	}
	e.push(map[string]string{"pushkey": pk.Key, "text": "STILL-SEALED"})
	ms = e.messages(tok)
	if m := ms[len(ms)-1]; m["sealed"] != "server" {
		t.Fatalf("代加密应始终开启：%v", m)
	}
	// 账号页标出是否加密：erin 已加密，bob 没有钥匙
	acc := admReq("GET", "/accounts", nil)
	if !strings.Contains(acc, "已加密") || !strings.Contains(acc, "尚未加密（等待首次登录）") {
		t.Fatal("账号页没有标出加密状态")
	}
}

// 代加密的信封格式和发送端加密完全一致：用跨平台测试向量里的钥匙核对
func TestE2EServerSealVectors(t *testing.T) {
	raw, err := os.ReadFile("testdata/e2e_vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var vec struct {
		RecipientSK string `json:"recipient_sk"`
		RecipientPK string `json:"recipient_pk_b64url"`
		KID         string `json:"kid"`
		Payload     string `json:"payload"`
		FileCtLen   int    `json:"file_ct_len"`
	}
	if err := json.Unmarshal(raw, &vec); err != nil {
		t.Fatal(err)
	}
	skRaw, _ := hex.DecodeString(vec.RecipientSK)
	sk, err := ecdh.X25519().NewPrivateKey(skRaw)
	if err != nil || b64of(sk.PublicKey().Bytes()) != vec.RecipientPK {
		t.Fatal("向量钥匙对不上")
	}
	// 1. 共用的载荷加密：同样的内容封出来的明文 JSON 和向量里的 payload 逐字节相同
	var want e2ePayload
	json.Unmarshal([]byte(vec.Payload), &want)
	env, err := e2eSealPayload(sk.PublicKey(), want.Text, want.Desp, want.Type, want.Atts)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(env, e2eMsgPrefix+vec.KID+".") {
		t.Fatalf("信封前缀：%.30s", env)
	}
	if pt, err := e2eOpenMessage(sk, env); err != nil || string(pt) != vec.Payload {
		t.Fatalf("载荷和向量不一致：%s", pt)
	}

	// 2. 服务器代加密：账号钥匙就是向量里的 recipient，附件按向量的规则生成
	e := newE2EEnv(t)
	u, _ := e.h.st.CreateAccount("vec", "vec-pass-0001")
	pk, _ := e.h.st.CreatePushkey(u.ID, "a")
	_, tok, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "m", Platform: "macos", Fingerprint: "fp-v-000001"})
	e.h.st.db.Exec(`INSERT INTO e2e_keys(user_id,kid,pub,created_at,active) VALUES(?,?,?,?,1)`, u.ID, vec.KID, vec.RecipientPK, 1)
	file := make([]byte, e2eChunk+100)
	for i := range file {
		file[i] = byte(i % 251)
	}
	if c, out := e.pushFiles(map[string]string{"pushkey": pk.Key, "text": want.Text, "desp": want.Desp}, map[string][]byte{"loss.png": file}, []string{"loss.png"}); c != 200 {
		t.Fatalf("%d %v", c, out)
	}
	m := e.messages(tok)[0]
	env = m["e2e"].(string)
	kid, body, err := e2eParseEnvelope(env)
	if err != nil || kid != vec.KID || len(body) < 32+16 {
		t.Fatalf("信封格式：kid=%s err=%v", kid, err)
	}
	p := openPayload(t, sk, env)
	if p.Text != want.Text || p.Desp != want.Desp || len(p.Atts) != 1 || p.Atts[0].Name != "loss.png" || p.Atts[0].Mime != "image/png" || p.Atts[0].Size != int64(len(file)) {
		t.Fatalf("载荷：%+v", p)
	}
	ct := e.download(tok, m["attachments"].([]any)[0].(map[string]any)["id"].(string))
	if len(ct) != vec.FileCtLen {
		t.Fatalf("附件密文长度 %d，向量 %d", len(ct), vec.FileCtLen)
	}
	key, _ := b64.DecodeString(p.Atts[0].Key)
	var pt bytes.Buffer
	if err := e2eDecryptFile(key, bytes.NewReader(ct), &pt); err != nil || !bytes.Equal(pt.Bytes(), file) {
		t.Fatalf("附件解密：%v", err)
	}
}

func TestInfoE2EAuto(t *testing.T) {
	e := newE2EEnv(t)
	out := e.must(200, "GET", "/v1/info", "", nil)
	if out["version"] != version || version != "0.8.0" {
		t.Fatalf("版本：%v", out["version"])
	}
	found := false
	for _, f := range out["features"].([]any) {
		f := f.(map[string]any)
		if f["id"] == "e2e.auto" {
			found = f["since"] == "0.8.0" && strings.Contains(f["title"].(string), "服务器代加密")
		}
	}
	if !found {
		t.Fatal("/v1/info 缺少 e2e.auto（since 0.8.0）")
	}
}

// 开启加密以前存下的明文消息：开启后由服务器补加密（附件读不到的先跳过，下次再试）
func TestE2ESealBacklog(t *testing.T) {
	e := newE2EEnv(t)
	u, _ := e.h.st.CreateAccount("frank", "frank-pass-001")
	pk, _ := e.h.st.CreatePushkey(u.ID, "a")
	_, tok, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "m", Platform: "macos", Fingerprint: "fp-b-000001"})
	bob, _ := e.h.st.CreateAccount("bob", "bob-pass-1234")
	pkBob, _ := e.h.st.CreatePushkey(bob.ID, "b")
	_, tokBob, _, _ := e.h.st.LoginDevice(pairReq{UserID: bob.ID, Name: "b", Platform: "macos", Fingerprint: "fp-b-000002"})

	shared := bytes.Repeat([]byte("SHARED-CONTENT "), 6000) // 两个账号都发过：服务器按内容去重（硬链接）
	own := bytes.Repeat([]byte("OLD-FILE-MARKER "), 5000)
	send := func(key string, fields map[string]string, files map[string][]byte, order ...string) {
		t.Helper()
		fields["pushkey"] = key
		if c, out := e.pushFiles(fields, files, order); c != 200 {
			t.Fatalf("%d %v", c, out)
		}
	}
	send(pkBob.Key, map[string]string{"text": "bob 的消息"}, map[string][]byte{"shared.bin": shared}, "shared.bin")
	send(pk.Key, map[string]string{"text": "OLD-TITLE-1", "desp": "OLD-BODY **粗体**", "priority": "4"},
		map[string][]byte{"OLD-NAME 报告.txt": own, "shared.bin": shared}, "OLD-NAME 报告.txt", "shared.bin")
	send(pk.Key, map[string]string{"type": "text"}, map[string][]byte{"OLD-ONLY-FILE.txt": []byte("OLD-SMALL")}, "OLD-ONLY-FILE.txt") // 没有标题：存的是「📎 文件名」
	send(pk.Key, map[string]string{"text": "OLD-TITLE-3", "desp": "OLD-MISSING"}, map[string][]byte{"gone.txt": []byte("OLD-GONE")}, "gone.txt")
	// 第 3 条的附件文件被手动删掉：补加密要跳过它，不能半途而废
	var goneBlob string
	e.h.st.db.QueryRow(`SELECT a.blob FROM attachments a JOIN messages m ON m.id=a.message_id WHERE m.text='OLD-TITLE-3'`).Scan(&goneBlob)
	gonePath, _ := e.h.files.find(goneBlob)
	goneData, _ := os.ReadFile(gonePath)
	os.Remove(gonePath)

	// 还没有钥匙：GET /v1/e2e 能看出来（enabled 为假、明文条数）
	if st := e.must(200, "GET", "/v1/e2e", tok, nil); st["enabled"] != false || st["plain_messages"].(float64) != 3 || st["server_seal"] != true {
		t.Fatalf("开启前的状态：%v", st)
	}
	sk := newKey(t)
	body, _, _ := keyBody(t, sk, "frank-pass-001")
	body["current_password"] = "frank-pass-001"
	e.must(200, "POST", "/v1/e2e/setup", tok, body)
	e.h.sealBacklog(u.ID) // setup 已在后台启动补加密；这里等它结束（同一账号串行），再跑一遍也没有可做的
	if n, _ := e.h.sealBacklog(u.ID); n != 0 {
		t.Fatalf("重复补加密了 %d 条", n)
	}

	ms := e.messages(tok)
	if len(ms) != 3 {
		t.Fatalf("消息数 %d", len(ms))
	}
	p1 := openPayload(t, sk, ms[0]["e2e"].(string))
	if ms[0]["sealed"] != "server" || ms[0]["type"] != "e2e" || ms[0]["text"] != e2ePlaceholder || ms[0]["priority"].(float64) != 4 ||
		p1.Text != "OLD-TITLE-1" || p1.Desp != "OLD-BODY **粗体**" || p1.Type != "markdown" || len(p1.Atts) != 2 {
		t.Fatalf("第 1 条：%v %+v", ms[0], p1)
	}
	for i, want := range [][]byte{own, shared} {
		a := ms[0]["attachments"].([]any)[i].(map[string]any)
		if a["name"] != fmt.Sprintf("encrypted-%d.bin", i+1) || a["size"].(float64) != float64(e2eCipherSize(int64(len(want)))) || p1.Atts[i].Size != int64(len(want)) {
			t.Fatalf("附件 %d：%v %+v", i, a, p1.Atts[i])
		}
		key, _ := b64.DecodeString(p1.Atts[i].Key)
		var pt bytes.Buffer
		if err := e2eDecryptFile(key, bytes.NewReader(e.download(tok, a["id"].(string))), &pt); err != nil || !bytes.Equal(pt.Bytes(), want) {
			t.Fatalf("附件 %d 解密：%v", i, err)
		}
	}
	if p1.Atts[0].Name != "OLD-NAME 报告.txt" || p1.Atts[1].Name != "shared.bin" {
		t.Fatalf("附件名：%+v", p1.Atts)
	}
	if p2 := openPayload(t, sk, ms[1]["e2e"].(string)); p2.Text != "📎 OLD-ONLY-FILE.txt" || p2.Type != "text" || len(p2.Atts) != 1 {
		t.Fatalf("第 2 条：%+v", p2)
	}
	// 附件读不到的那条跳过，保持明文
	if ms[2]["e2e"] != nil || ms[2]["text"] != "OLD-TITLE-3" {
		t.Fatalf("附件读不到的消息应保持原样：%v", ms[2])
	}
	if st := e.must(200, "GET", "/v1/e2e", tok, nil); st["enabled"] != true || st["plain_messages"].(float64) != 1 {
		t.Fatalf("补加密后的状态：%v", st)
	}
	if !strings.Contains(func() string {
		adm := httptest.NewServer(e.h.adminMux())
		defer adm.Close()
		sess, _ := e.h.st.CreateSession("t", time.Hour, false)
		req, _ := http.NewRequest("GET", adm.URL+"/accounts", nil)
		req.AddCookie(&http.Cookie{Name: cookieName, Value: sess})
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return string(b)
	}(), "明文 1 条") {
		t.Fatal("账号页应显示还剩 1 条明文")
	}
	// bob 共用同一份内容的附件不受影响
	mb := e.messages(tokBob)
	if !bytes.Equal(e.download(tokBob, mb[0]["attachments"].([]any)[0].(map[string]any)["id"].(string)), shared) {
		t.Fatal("别的账号去重共用的附件被删了")
	}
	// 文件找回来以后再跑一次：补上
	os.WriteFile(gonePath, goneData, 0o640)
	if n, skipped := e.h.sealBacklog(u.ID); n != 1 || skipped != 0 {
		t.Fatalf("第二次补加密：%d 条，跳过 %d", n, skipped)
	}
	ms = e.messages(tok)
	if p3 := openPayload(t, sk, ms[2]["e2e"].(string)); p3.Text != "OLD-TITLE-3" || p3.Desp != "OLD-MISSING" {
		t.Fatalf("第 3 条：%+v", p3)
	}
	// 数据库（含 WAL）、附件目录（内容和目录名）里都不再有这个账号的明文
	scanLeaks(t, e, "OLD-TITLE", "OLD-BODY", "OLD-FILE-MARKER", "OLD-NAME", "OLD-ONLY-FILE", "OLD-SMALL", "OLD-MISSING", "OLD-GONE")
}
