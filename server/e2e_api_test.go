package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// e2eEnv：只挂公网接口的最小服务端
type e2eEnv struct {
	t   *testing.T
	h   *Hub
	srv *httptest.Server
}

func newE2EEnv(t *testing.T) *e2eEnv {
	data := t.TempDir()
	st, err := OpenStore(filepath.Join(data, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	h := &Hub{st: st, dataDir: data, tmpDir: t.TempDir(), maxUpload: 8 << 20, br: NewBroker(),
		pushLimit: NewLimiter(1e6, 1e6), pairLimit: NewLimiter(1e6, 1e6), loginLimit: NewLimiter(1e6, 1e6), acctLimit: NewLimiter(1e6, 1e6),
		paths: storePaths{files: filepath.Join(data, "files")}}
	st.notify = h.br.Notify
	h.files = newFileStore(h, h.paths.files)
	e := &e2eEnv{t: t, h: h, srv: httptest.NewServer(h.publicMux())}
	t.Cleanup(e.srv.Close)
	return e
}

// call：发 JSON 请求，返回状态码和解析后的响应
func (e *e2eEnv) call(method, path, tok string, body any) (int, map[string]any) {
	e.t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, e.srv.URL+path, rd)
	req.Header.Set("Content-Type", "application/json")
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func (e *e2eEnv) must(code int, method, path, tok string, body any) map[string]any {
	e.t.Helper()
	got, out := e.call(method, path, tok, body)
	if got != code {
		e.t.Fatalf("%s %s：状态 %d（期望 %d），响应 %v", method, path, got, code, out)
	}
	return out
}

// push：multipart 发送（可带附件），返回状态码和响应
func (e *e2eEnv) push(fields map[string]string, files ...[]byte) (int, map[string]any) {
	e.t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for k, v := range fields {
		mw.WriteField(k, v)
	}
	for i, f := range files {
		fw, _ := mw.CreateFormFile("file", "real-name-"+string(rune('a'+i))+".txt")
		fw.Write(f)
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

func (e *e2eEnv) messages(tok string) []map[string]any {
	e.t.Helper()
	out := e.must(200, "GET", "/v1/messages?since=0", tok, nil)
	var ms []map[string]any
	for _, m := range out["messages"].([]any) {
		ms = append(ms, m.(map[string]any))
	}
	return ms
}

func b64of(b []byte) string { return b64.EncodeToString(b) }

func newSalt(t *testing.T) ([]byte, string) {
	s := make([]byte, 16)
	rand.Read(s)
	return s, hex.EncodeToString(s)
}

// 完整流程：旧账号 → 开启加密（升级登录协议）→ 凭证登录自动解锁 → 加密发送 / 只收加密 → 设备批准 → 改密码 → 管理员重设 → 删除明文
func TestE2EFlow(t *testing.T) {
	e := newE2EEnv(t)
	const pw = "alice-old-pass-1"
	alice, err := e.h.st.CreateAccount("alice", pw)
	if err != nil {
		t.Fatal(err)
	}
	pk, _ := e.h.st.CreatePushkey(alice.ID, "a")

	// prelogin：旧账号返回 PBKDF2 参数（新客户端在本机算好再发，不发密码原文）；不存在的账号返回固定的假盐
	pre := e.must(200, "GET", "/v1/prelogin?username=alice", "", nil)
	if pre["kdf"] != "pbkdf2-sha256" || pre["iterations"].(float64) != pbkdfIter {
		t.Fatalf("旧账号 prelogin = %v", pre)
	}
	psalt, _ := hex.DecodeString(pre["salt"].(string))
	pwKey, _ := pbkdf2.Key(sha256.New, pw, psalt, pbkdfIter, 32)
	f1 := e.must(200, "GET", "/v1/prelogin?username=nobody", "", nil)
	f2 := e.must(200, "GET", "/v1/prelogin?username=NoBody", "", nil)
	f3 := e.must(200, "GET", "/v1/prelogin?username=other", "", nil)
	if f1["kdf"] != "argon2id" || f1["salt"] != f2["salt"] || f1["salt"] == f3["salt"] || len(f1["salt"].(string)) != 32 {
		t.Fatalf("假盐不对：%v %v %v", f1, f2, f3)
	}

	login := func(code int, body map[string]any) map[string]any {
		t.Helper()
		b := map[string]any{"username": "alice", "name": "dev", "platform": "macos"}
		for k, v := range body {
			b[k] = v
		}
		return e.must(code, "POST", "/v1/login", "", b)
	}
	login(403, map[string]any{"password_key": b64of(make([]byte, 32))})
	login(400, map[string]any{"password_key": "short"})
	tokA := login(200, map[string]any{"password_key": b64of(pwKey), "fingerprint": "fp-a-000001"})["token"].(string)
	login(200, map[string]any{"password": pw, "fingerprint": "fp-a-000001"}) // 旧客户端照常
	tokA = login(200, map[string]any{"password_key": b64of(pwKey), "fingerprint": "fp-a-000001"})["token"].(string)
	if c, out := e.push(map[string]string{"pushkey": pk.Key, "text": "plain-1"}); c != 200 {
		t.Fatalf("明文发送失败：%d %v", c, out)
	}

	// 开启加密
	sk, _ := ecdh.X25519().GenerateKey(rand.Reader)
	pub := sk.PublicKey().Bytes()
	salt, saltHex := newSalt(t)
	auth, unlock := e2ePasswordKeys(pw, salt)
	pwWrap, _ := e2eWrap("hjp1", unlock, sk.Bytes())
	code := make([]byte, 16)
	rand.Read(code)
	recWrap, _ := e2eWrap("hjr1", e2eRecoveryKey(code), sk.Bytes())
	setup := map[string]any{"pub": b64of(pub), "auth_salt": saltHex, "auth_key": b64of(auth),
		"password_wrap": pwWrap, "recovery_wrap": recWrap, "current_password": "wrong-password"}
	e.must(403, "POST", "/v1/e2e/setup", tokA, setup)
	delete(setup, "current_password")
	e.must(403, "POST", "/v1/e2e/setup", tokA, setup)
	setup["current_password_key"] = b64of(pwKey)
	setup["recovery_wrap"] = "hjr1.bad"
	e.must(400, "POST", "/v1/e2e/setup", tokA, setup)
	setup["recovery_wrap"] = recWrap
	kid := e.must(200, "POST", "/v1/e2e/setup", tokA, setup)["kid"].(string)
	if kid != e2eKID(pub) {
		t.Fatalf("kid = %s", kid)
	}
	e.must(409, "POST", "/v1/e2e/setup", tokA, setup)

	// 升级后：prelogin 给真盐；密码原文登录 426；凭证登录拿到密码副本，本机解开
	if out := e.must(200, "GET", "/v1/prelogin?username=alice", "", nil); out["salt"] != saltHex || out["kdf"] != "argon2id" {
		t.Fatalf("升级后 prelogin = %v", out)
	}
	login(426, map[string]any{"password": pw})
	login(426, map[string]any{"password_key": b64of(pwKey)})
	login(403, map[string]any{"auth_key": b64of(make([]byte, 32))})
	out := login(200, map[string]any{"auth_key": b64of(auth), "fingerprint": "fp-b-000001"})
	tokB := out["token"].(string)
	info := out["e2e"].(map[string]any)
	if got, err := e2eUnwrap("hjp1", unlock, info["password_wrap"].(string)); err != nil || !bytes.Equal(got, sk.Bytes()) {
		t.Fatalf("登录后解不开私钥：%v", err)
	}
	if info["enabled"] != true {
		t.Fatalf("e2e = %v", info)
	}
	// 用原文改密码 → 426；只改用户名要核对凭证
	e.must(426, "POST", "/v1/account/credentials", tokB, map[string]any{"username": "alice", "password": "new-pass-0001", "current_password": pw})
	e.must(426, "POST", "/v1/account/credentials", tokB, map[string]any{"username": "alice2", "current_password": pw})
	e.must(200, "POST", "/v1/account/credentials", tokB, map[string]any{"username": "alice", "current_auth_key": b64of(auth)})
	// 恢复码副本可以解开
	st := e.must(200, "GET", "/v1/e2e", tokB, nil)
	if got, err := e2eUnwrap("hjr1", e2eRecoveryKey(code), st["recovery_wrap"].(string)); err != nil || !bytes.Equal(got, sk.Bytes()) {
		t.Fatalf("恢复码解不开：%v", err)
	}

	// 加密发送：加密发送密钥里的公钥部分被忽略，信封原样存下，标题、正文、附件名都不落库
	sendKey := pk.Key + e2eSendKeySep + b64of(pub)
	gotPK, gotPub, err := e2eSplitSendKey(sendKey)
	if err != nil || gotPK != pk.Key || !bytes.Equal(gotPub.Bytes(), pub) {
		t.Fatalf("拆分发送密钥：%v", err)
	}
	env, _ := e2eSealMessage(gotPub, []byte(`{"title":"秘密标题","body":"秘密正文"}`))
	if c, out := e.push(map[string]string{"pushkey": sendKey, "e2e": env, "text": "leak?", "desp": "leak!", "priority": "4", "topic": "t1"}, []byte("ciphertext")); c != 200 {
		t.Fatalf("加密发送失败：%d %v", c, out)
	}
	ms := e.messages(tokA)
	m := ms[len(ms)-1]
	if m["type"] != "e2e" || m["text"] != e2ePlaceholder || m["desp"] != nil && m["desp"] != "" || m["e2e"] != env {
		t.Fatalf("加密消息存储不对：%v", m)
	}
	att := m["attachments"].([]any)[0].(map[string]any)
	if att["name"] != "encrypted-1.bin" || att["mime"] != "application/octet-stream" {
		t.Fatalf("附件名泄露：%v", att)
	}
	if pt, err := e2eOpenMessage(sk, m["e2e"].(string)); err != nil || !strings.Contains(string(pt), "秘密正文") {
		t.Fatalf("解不开：%v", err)
	}
	// 数据库里不出现明文
	var leaks int
	e.h.st.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE text LIKE '%leak%' OR desp LIKE '%leak%'`).Scan(&leaks)
	if leaks != 0 {
		t.Fatal("占位文字以外的明文被存下来了")
	}
	// 信封坏了 / 用了别的公钥
	other, _ := ecdh.X25519().GenerateKey(rand.Reader)
	envOther, _ := e2eSealMessage(other.PublicKey(), []byte("x"))
	for _, bad := range []string{"hje1.zz", "hje1.0011223344556677.!!!", "hye2" + env[4:], envOther} {
		if c, _ := e.push(map[string]string{"pushkey": pk.Key, "e2e": bad}); c != 400 {
			t.Fatalf("坏信封 %q…：状态 %d", bad[:12], c)
		}
	}

	// 只接受加密消息
	e.must(200, "PATCH", "/v1/e2e", tokA, map[string]any{"e2e_only": true})
	if c, _ := e.push(map[string]string{"pushkey": pk.Key, "text": "plain-2"}); c != 403 {
		t.Fatalf("只收加密时明文没被拒：%d", c)
	}
	if c, _ := e.push(map[string]string{"pushkey": pk.Key, "e2e": env}); c != 200 {
		t.Fatalf("只收加密时加密消息被拒：%d", c)
	}
	// 一次发给多个账号：任何一个开了只收加密都要拒收
	bob, _ := e.h.st.CreateAccount("bob", "bob-pass-1234")
	pkBob, _ := e.h.st.CreatePushkey(bob.ID, "b")
	if c, _ := e.push(map[string]string{"pushkey": pkBob.Key + "," + pk.Key, "text": "plain-3"}); c != 403 {
		t.Fatalf("多个 pushkey 绕过了只收加密：%d", c)
	}
	e.must(200, "PATCH", "/v1/e2e", tokA, map[string]any{"e2e_only": false})
	// 加密发送密钥没带信封（旧命令行 / curl）：拒收，不让人以为发出去的是加密的
	if c, _ := e.push(map[string]string{"pushkey": sendKey, "text": "plain-4"}); c != 400 {
		t.Fatalf("加密发送密钥发明文：%d", c)
	}
	// 停用的钥匙不再接收新消息
	e.h.st.db.Exec(`UPDATE e2e_keys SET active=0 WHERE user_id=?`, alice.ID)
	if c, _ := e.push(map[string]string{"pushkey": pk.Key, "e2e": env}); c != 400 {
		t.Fatalf("停用的钥匙还能收：%d", c)
	}
	e.h.st.db.Exec(`UPDATE e2e_keys SET active=1 WHERE user_id=?`, alice.ID)

	// 设备批准：配对码登录的新设备 C 请求，A 核对后转交
	dC, tokC, _, _ := e.h.st.LoginDevice(pairReq{UserID: alice.ID, Name: "phone", Platform: "android", Fingerprint: "fp-c-000001"})
	skC, _ := ecdh.X25519().GenerateKey(rand.Reader)
	pubC := b64of(skC.PublicKey().Bytes())
	nb, na := make([]byte, 32), make([]byte, 32)
	rand.Read(nb)
	rand.Read(na)
	acc := sk.PublicKey().Bytes()
	{ // 承诺用了假的账号公钥（被冒充的服务器给新设备看了自己的公钥）：揭晓被拒
		bad := b64of(e2eCommit(skC.PublicKey().Bytes(), skC.PublicKey().Bytes(), nb))
		e.must(200, "PUT", "/v1/e2e/device", tokC, map[string]any{"pub": pubC, "request": true, "commit": bad})
		e.must(200, "POST", "/v1/e2e/challenge", tokA, map[string]any{"device_id": dC.ID, "nonce": b64of(na)})
		e.must(409, "POST", "/v1/e2e/reveal", tokC, map[string]any{"nonce": b64of(nb)})
		e.must(200, "POST", "/v1/e2e/deny", tokA, map[string]any{"device_id": dC.ID})
	}
	commit := b64of(e2eCommit(skC.PublicKey().Bytes(), acc, nb))
	e.must(400, "PUT", "/v1/e2e/device", tokC, map[string]any{"pub": pubC, "request": true})
	e.must(200, "PUT", "/v1/e2e/device", tokC, map[string]any{"pub": pubC, "request": true, "commit": commit})
	reqs := e.must(200, "GET", "/v1/e2e", tokA, nil)["requests"].([]any)
	if len(reqs) != 1 || reqs[0].(map[string]any)["device_id"] != dC.ID || reqs[0].(map[string]any)["pub"] != pubC || reqs[0].(map[string]any)["commit"] != commit {
		t.Fatalf("待批准列表：%v", reqs)
	}
	// 核对码：先承诺、后揭晓
	e.must(409, "POST", "/v1/e2e/reveal", tokC, map[string]any{"nonce": b64of(nb)}) // 还没有设备接手
	e.must(400, "POST", "/v1/e2e/challenge", tokC, map[string]any{"device_id": dC.ID, "nonce": b64of(na)})
	e.must(200, "POST", "/v1/e2e/challenge", tokA, map[string]any{"device_id": dC.ID, "nonce": b64of(na)})
	e.must(409, "POST", "/v1/e2e/challenge", tokA, map[string]any{"device_id": dC.ID, "nonce": b64of(nb)}) // 只能接手一次
	if dev := e.must(200, "GET", "/v1/e2e", tokC, nil)["device"].(map[string]any); dev["challenge"] != b64of(na) || dev["revealed"] != false {
		t.Fatalf("C 看不到 na：%v", dev)
	}
	e.must(409, "POST", "/v1/e2e/reveal", tokC, map[string]any{"nonce": b64of(na)}) // 和承诺对不上
	e.must(200, "POST", "/v1/e2e/reveal", tokC, map[string]any{"nonce": b64of(nb)})
	e.must(409, "POST", "/v1/e2e/reveal", tokC, map[string]any{"nonce": b64of(nb)}) // 只能揭晓一次
	r0 := e.must(200, "GET", "/v1/e2e", tokA, nil)["requests"].([]any)[0].(map[string]any)
	gotNB, _ := b64.DecodeString(r0["reveal"].(string))
	if b64of(e2eCommit(skC.PublicKey().Bytes(), acc, gotNB)) != commit || e2eSAS(skC.PublicKey().Bytes(), acc, na, gotNB) != e2eSAS(skC.PublicKey().Bytes(), acc, na, nb) {
		t.Fatal("两边核对码不一致")
	}
	if own := e.must(200, "GET", "/v1/e2e", tokC, nil)["requests"].([]any); len(own) != 0 {
		t.Fatalf("自己的请求不该出现在自己的列表里：%v", own)
	}
	encG, ctG, _ := hpkeSeal(skC.PublicKey(), []byte(e2eInfoGrant), []byte("hjg1"), sk.Bytes(), nil)
	grant := "hjg1." + b64of(append(encG, ctG...))
	e.must(409, "POST", "/v1/e2e/grant", tokA, map[string]any{"device_id": dC.ID, "pub": b64of(pub), "grant": grant})
	{ // 核对码流程没走完不能转交
		_, tokX, _, _ := e.h.st.LoginDevice(pairReq{UserID: alice.ID, Name: "x", Platform: "ios", Fingerprint: "fp-x-000001"})
		dX, _ := e.h.st.DeviceByToken(tokX)
		e.must(200, "PUT", "/v1/e2e/device", tokX, map[string]any{"pub": pubC, "request": true, "commit": commit})
		e.must(409, "POST", "/v1/e2e/grant", tokA, map[string]any{"device_id": dX.ID, "pub": pubC, "grant": grant})
		e.must(200, "POST", "/v1/e2e/deny", tokA, map[string]any{"device_id": dX.ID})
	}
	e.must(400, "POST", "/v1/e2e/grant", tokA, map[string]any{"device_id": dC.ID, "pub": pubC, "grant": "hjg1.short"})
	e.must(200, "POST", "/v1/e2e/grant", tokA, map[string]any{"device_id": dC.ID, "pub": pubC, "grant": grant})
	dev := e.must(200, "GET", "/v1/e2e", tokC, nil)["device"].(map[string]any)
	if dev["grant"] != grant || dev["requested"] != false {
		t.Fatalf("C 没拿到转交副本：%v", dev)
	}
	raw, _ := b64.DecodeString(strings.TrimPrefix(dev["grant"].(string), "hjg1."))
	if got, err := hpkeOpen(skC, raw[:32], []byte(e2eInfoGrant), []byte("hjg1"), raw[32:]); err != nil || !bytes.Equal(got, sk.Bytes()) {
		t.Fatalf("C 解不开转交副本：%v", err)
	}
	// C 换了公钥：旧副本作废
	skC2, _ := ecdh.X25519().GenerateKey(rand.Reader)
	e.must(200, "PUT", "/v1/e2e/device", tokC, map[string]any{"pub": b64of(skC2.PublicKey().Bytes())})
	if dev := e.must(200, "GET", "/v1/e2e", tokC, nil)["device"].(map[string]any); dev["grant"] != "" {
		t.Fatalf("换公钥后旧副本还在：%v", dev)
	}
	// 拒绝请求；吊销设备后副本删除
	e.must(200, "PUT", "/v1/e2e/device", tokC, map[string]any{"pub": b64of(skC2.PublicKey().Bytes()), "request": true, "commit": commit})
	if dev := e.must(200, "GET", "/v1/e2e", tokC, nil)["device"].(map[string]any); dev["challenge"] != "" || dev["requested"] != true {
		t.Fatalf("重新请求后旧的核对过程应作废：%v", dev)
	}
	e.must(200, "POST", "/v1/e2e/deny", tokA, map[string]any{"device_id": dC.ID})
	if reqs := e.must(200, "GET", "/v1/e2e", tokA, nil)["requests"].([]any); len(reqs) != 0 {
		t.Fatalf("拒绝后还在列表里：%v", reqs)
	}
	e.h.st.db.Exec(`INSERT INTO e2e_wraps(user_id,kind,device_id,blob,created_at) VALUES(?,?,?,?,1)`, alice.ID, wrapDevice, dC.ID, grant)
	if e.h.st.Wrap(alice.ID, wrapDevice, dC.ID) == "" {
		t.Fatal("测试准备失败")
	}
	e.must(200, "POST", "/v1/devices/"+dC.ID+"/revoke", tokA, nil)
	if e.h.st.Wrap(alice.ID, wrapDevice, dC.ID) != "" {
		t.Fatal("吊销设备后转交副本还在")
	}

	// 换恢复码
	code2 := make([]byte, 16)
	rand.Read(code2)
	recWrap2, _ := e2eWrap("hjr1", e2eRecoveryKey(code2), sk.Bytes())
	e.must(403, "PUT", "/v1/e2e/recovery", tokA, map[string]any{"recovery_wrap": recWrap2, "current_auth_key": b64of(make([]byte, 32))})
	e.must(200, "PUT", "/v1/e2e/recovery", tokA, map[string]any{"recovery_wrap": recWrap2, "current_auth_key": b64of(auth)})

	// 改密码：新盐、新凭证、新的密码副本；旧凭证失效
	salt2, salt2Hex := newSalt(t)
	auth2, unlock2 := e2ePasswordKeys("alice-new-pass-2", salt2)
	pwWrap2, _ := e2eWrap("hjp1", unlock2, sk.Bytes())
	chg := map[string]any{"current_auth_key": b64of(auth), "auth_salt": salt2Hex, "auth_key": b64of(auth2)}
	e.must(400, "PUT", "/v1/account/auth", tokA, chg) // 已开启加密，缺密码副本
	chg["password_wrap"] = pwWrap2
	e.must(200, "PUT", "/v1/account/auth", tokA, chg)
	login(403, map[string]any{"auth_key": b64of(auth)})
	out = login(200, map[string]any{"auth_key": b64of(auth2)})
	if got, err := e2eUnwrap("hjp1", unlock2, out["e2e"].(map[string]any)["password_wrap"].(string)); err != nil || !bytes.Equal(got, sk.Bytes()) {
		t.Fatalf("改密码后解不开：%v", err)
	}
	// 配对码登录的设备输入密码解锁
	_, tokD, _, _ := e.h.st.LoginDevice(pairReq{UserID: alice.ID, Name: "pad", Platform: "ios", Fingerprint: "fp-d-000001"})
	e.must(403, "POST", "/v1/e2e/unlock", tokD, map[string]any{"auth_key": b64of(auth)})
	if w := e.must(200, "POST", "/v1/e2e/unlock", tokD, map[string]any{"auth_key": b64of(auth2)})["password_wrap"]; w != pwWrap2 {
		t.Fatalf("unlock = %v", w)
	}

	// 删除服务器上的明文消息：只删明文，加密消息保留
	e.must(400, "POST", "/v1/e2e/delete-plain", tokA, map[string]any{})
	del := e.must(200, "POST", "/v1/e2e/delete-plain", tokA, map[string]any{"confirm": true})
	if del["deleted"].(float64) != 1 {
		t.Fatalf("删除明文：%v", del)
	}
	for _, m := range e.messages(tokA) {
		if m["e2e"] == nil {
			t.Fatalf("明文消息还在：%v", m)
		}
	}
	// 记的是 purge（其他设备保留本地副本），不是普通 delete
	var kinds []string
	rows, _ := e.h.st.db.Query(`SELECT kind FROM msg_changes WHERE user_id=? AND msg_id>0 AND kind IN ('delete','purge')`, alice.ID)
	for rows.Next() {
		var k string
		rows.Scan(&k)
		kinds = append(kinds, k)
	}
	rows.Close()
	if len(kinds) != 1 || kinds[0] != "purge" {
		t.Fatalf("删除明文应记 purge 变更：%v", kinds)
	}
	// 数据库文件（含 WAL）里也找不到删掉的明文
	for _, f := range []string{"t.db", "t.db-wal"} {
		if b, err := os.ReadFile(filepath.Join(e.h.dataDir, f)); err == nil && bytes.Contains(b, []byte("plain-1")) {
			t.Fatalf("%s 里还残留删掉的明文", f)
		}
	}

	// 管理员用原文重设密码：凭证和密码副本作废，回到旧协议；恢复码副本和钥匙保留
	if err := e.h.st.SetCredentials(alice.ID, "alice", "admin-reset-pass-3"); err != nil {
		t.Fatal(err)
	}
	if out := e.must(200, "GET", "/v1/prelogin?username=alice", "", nil); out["kdf"] != "pbkdf2-sha256" {
		t.Fatalf("重设后 prelogin = %v", out)
	}
	login(403, map[string]any{"auth_key": b64of(auth2)})
	login(200, map[string]any{"password": "admin-reset-pass-3"})
	st = e.must(200, "GET", "/v1/e2e", tokA, nil)
	if st["has_password_wrap"] != false || st["recovery_wrap"] != recWrap2 || st["enabled"] != true {
		t.Fatalf("重设后状态：%v", st)
	}
	if out := e.must(409, "POST", "/v1/e2e/unlock", tokD, map[string]any{"auth_key": b64of(auth2)}); !strings.Contains(out["error"].(string), "恢复码") {
		t.Fatalf("重设后解锁的提示：%v", out)
	}
	// 已开启加密：升级登录协议必须同时给出新的密码副本
	salt3x, salt3xHex := newSalt(t)
	auth3x, _ := e2ePasswordKeys("admin-reset-pass-3", salt3x)
	e.must(400, "PUT", "/v1/account/auth", tokA, map[string]any{"current_password": "admin-reset-pass-3", "auth_salt": salt3xHex, "auth_key": b64of(auth3x)})
	if err := e.h.st.SetPasswordAuth(alice.ID, salt3xHex, auth3x, ""); !errors.Is(err, errNeedPasswordWrap) {
		t.Fatalf("存储层也要拦住：%v", err)
	}
	// 重新升级（用恢复码解开私钥后，用新密码再锁一份）
	salt3, salt3Hex := newSalt(t)
	auth3, unlock3 := e2ePasswordKeys("admin-reset-pass-3", salt3)
	pwWrap3, _ := e2eWrap("hjp1", unlock3, sk.Bytes())
	e.must(200, "PUT", "/v1/account/auth", tokA, map[string]any{"current_password": "admin-reset-pass-3", "auth_salt": salt3Hex, "auth_key": b64of(auth3), "password_wrap": pwWrap3})
	login(200, map[string]any{"auth_key": b64of(auth3)})
}

// 新协议注册：服务端从头到尾拿不到密码
func TestE2ERegisterAuth(t *testing.T) {
	e := newE2EEnv(t)
	body := map[string]any{"username": "bob", "auth_key": b64of(make([]byte, 32)), "auth_salt": "zz", "name": "d"}
	e.must(403, "POST", "/v1/register", "", body)
	e.h.st.SetKV("register_open", "1")
	e.must(400, "POST", "/v1/register", "", body)
	salt, saltHex := newSalt(t)
	auth, _ := e2ePasswordKeys("bob-password-1", salt)
	body["auth_salt"], body["auth_key"] = saltHex, b64of(auth)
	out := e.must(200, "POST", "/v1/register", "", body)
	if out["e2e"].(map[string]any)["enabled"] != false {
		t.Fatalf("注册响应：%v", out)
	}
	if out := e.must(200, "GET", "/v1/prelogin?username=bob", "", nil); out["salt"] != saltHex {
		t.Fatalf("prelogin = %v", out)
	}
	e.must(426, "POST", "/v1/login", "", map[string]any{"username": "bob", "password": "bob-password-1"})
	e.must(200, "POST", "/v1/login", "", map[string]any{"username": "bob", "auth_key": b64of(auth)})
	var ph string
	e.h.st.db.QueryRow(`SELECT pass_hash FROM users WHERE username='bob'`).Scan(&ph)
	if ph != "" {
		t.Fatal("新协议注册不该有密码哈希")
	}
}

// huijian push 用加密发送密钥：服务器上只有信封和密文附件，接收端解开后和原文一致
func TestE2EPushCLI(t *testing.T) {
	e := newE2EEnv(t)
	u, _ := e.h.st.CreateAccount("carol", "carol-pass-123")
	pk, _ := e.h.st.CreatePushkey(u.ID, "a")
	_, tok, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "m", Platform: "macos", Fingerprint: "fp-e-000001"})
	sk, _ := ecdh.X25519().GenerateKey(rand.Reader)
	e.h.st.db.Exec(`INSERT INTO e2e_keys(user_id,kid,pub,created_at,active) VALUES(?,?,?,?,1)`, u.ID, e2eKID(sk.PublicKey().Bytes()), b64of(sk.PublicKey().Bytes()), 1)

	dir := t.TempDir()
	big := make([]byte, 200<<10+7) // 多块，末块不满
	rand.Read(big)
	paths := []string{filepath.Join(dir, "曲线.png"), filepath.Join(dir, "empty.log")}
	os.WriteFile(paths[0], big, 0o600)
	os.WriteFile(paths[1], nil, 0o600)

	job := Job{URLs: []string{e.srv.URL}, Pushkey: pk.Key + e2eSendKeySep + b64of(sk.PublicKey().Bytes()),
		Text: "exp42 完成", Desp: "val_loss **0.198**\n![曲线](attachment:1)", Priority: 4, Topic: "train", Files: paths, Idem: "cli_test"}
	if _, _, err := sendJob(job); err != nil {
		t.Fatal(err)
	}
	if _, _, err := sendJob(job); err != nil { // 重试：重新加密，但幂等键相同，只有一条
		t.Fatal(err)
	}
	ms := e.messages(tok)
	if len(ms) != 1 {
		t.Fatalf("消息数 %d", len(ms))
	}
	m := ms[0]
	if m["text"] != e2ePlaceholder || m["priority"].(float64) != 4 || m["topic"] != "train" {
		t.Fatalf("消息：%v", m)
	}
	pt, err := e2eOpenMessage(sk, m["e2e"].(string))
	if err != nil {
		t.Fatal(err)
	}
	var p e2ePayload
	if err := json.Unmarshal(pt, &p); err != nil || p.V != 1 || p.Text != job.Text || p.Desp != job.Desp || len(p.Atts) != 2 {
		t.Fatalf("载荷：%s", pt)
	}
	if p.Atts[0].Name != "曲线.png" || p.Atts[0].Mime != "image/png" || p.Atts[0].Size != int64(len(big)) || p.Atts[1].Size != 0 {
		t.Fatalf("附件信息：%+v", p.Atts)
	}
	atts := m["attachments"].([]any)
	for i, want := range [][]byte{big, nil} {
		a := atts[i].(map[string]any)
		if a["size"].(float64) != float64(e2eCipherSize(int64(len(want)))) || strings.Contains(a["name"].(string), "曲线") {
			t.Fatalf("服务器上的附件 %d：%v", i, a)
		}
		req, _ := http.NewRequest("GET", e.srv.URL+"/v1/att/"+a["id"].(string), nil)
		req.Header.Set("Authorization", "Bearer "+tok)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		ct, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		key, _ := b64.DecodeString(p.Atts[i].Key)
		var out bytes.Buffer
		if err := e2eDecryptFile(key, bytes.NewReader(ct), &out); err != nil || !bytes.Equal(out.Bytes(), want) {
			t.Fatalf("附件 %d 解密：%v", i, err)
		}
	}

	// 正文全是需要转义的字符、又接近 64 KB：截短后照样发出，不整条丢掉
	job.Idem, job.Files = "cli_test_2", nil
	job.Desp = strings.Repeat(`<"`, 32<<10)
	if _, _, err := sendJob(job); err != nil {
		t.Fatalf("长正文发送失败：%v", err)
	}
	ms = e.messages(tok)
	pt, _ = e2eOpenMessage(sk, ms[len(ms)-1]["e2e"].(string))
	var p2 e2ePayload
	json.Unmarshal(pt, &p2)
	if len(p2.Desp) < 20<<10 || !strings.HasPrefix(job.Desp, p2.Desp) {
		t.Fatalf("截断不对：%d 字节", len(p2.Desp))
	}
	// 多个加密发送密钥：同一把公钥可以；不同公钥、和普通 pushkey 混用都拒绝
	pk2, _ := e.h.st.CreatePushkey(u.ID, "b")
	sendKey := pk.Key + e2eSendKeySep + b64of(sk.PublicKey().Bytes())
	job.Idem, job.Desp = "cli_test_3", "x"
	job.Pushkey = sendKey + "," + pk2.Key + e2eSendKeySep + b64of(sk.PublicKey().Bytes())
	if _, _, err := sendJob(job); err != nil {
		t.Fatalf("多个加密发送密钥：%v", err)
	}
	other, _ := ecdh.X25519().GenerateKey(rand.Reader)
	for _, bad := range []string{sendKey + "," + pk2.Key + e2eSendKeySep + b64of(other.PublicKey().Bytes()), sendKey + "," + pk2.Key} {
		job.Pushkey = bad
		if _, retry, err := sendJob(job); err == nil || retry {
			t.Fatalf("应该拒绝 %q：err=%v", bad, err)
		}
	}

	// 发送密钥里的公钥格式不对：本地就拒绝，不重试
	job.Pushkey = pk.Key + e2eSendKeySep + "short"
	if _, retry, err := sendJob(job); err == nil || retry {
		t.Fatalf("坏发送密钥：err=%v retry=%v", err, retry)
	}
}
