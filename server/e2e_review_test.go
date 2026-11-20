package main

// server-review（2026-11-19）指出的问题的回归测试：R1–R4 来自审查报告的验证测试，改成了断言

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func mustB64(s string) []byte {
	b, err := b64.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

// captureLog：测试期间把日志收进缓冲区（检查日志里有没有明文）
func captureLog(t *testing.T) *bytes.Buffer {
	var buf bytes.Buffer
	var mu sync.Mutex
	log.SetOutput(writerFunc(func(p []byte) (int, error) { mu.Lock(); defer mu.Unlock(); return buf.Write(p) }))
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	return &buf
}

type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(p []byte) (int, error) { return f(p) }

// enableE2E：用 API 开启加密（会在后台启动补加密），等补加密跑完
func enableE2E(t *testing.T, e *e2eEnv, uid int64, tok, password string) {
	t.Helper()
	sk := newKey(t)
	body, _, _ := keyBody(t, sk, password)
	body["current_password"] = password
	e.must(200, "POST", "/v1/e2e/setup", tok, body)
	e.h.sealBacklog(uid)
}

// R1 / H1：补加密后旧附件 id 返回 410（不返回密文），记 kind "sealed" 的变更，按 id 能取到新的消息
func TestReviewSealedAttachmentID(t *testing.T) {
	e := newE2EEnv(t)
	u, _ := e.h.st.CreateAccount("rv1", "rv1-pass-0001")
	pk, _ := e.h.st.CreatePushkey(u.ID, "a")
	_, tok, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "old-phone", Platform: "ios", Fingerprint: "fp-rv-00001"})
	plain := bytes.Repeat([]byte("PDF-PLAINTEXT "), 1000)
	e.legacyPlain(pk.Key, map[string]string{"text": "报告"}, map[string][]byte{"report.pdf": plain}, "report.pdf") // 0.9.0 以前的明文历史
	before := e.messages(tok)[0]
	msgID := int64(before["id"].(float64))
	oldAtt := before["attachments"].([]any)[0].(map[string]any)["id"].(string)
	st := e.must(200, "GET", "/v1/messages/state", tok, nil)
	cursor := int64(st["changes_next"].(float64))

	sk := newKey(t)
	body, _, _ := keyBody(t, sk, "rv1-pass-0001")
	body["current_password"] = "rv1-pass-0001"
	e.must(200, "POST", "/v1/e2e/setup", tok, body)
	e.h.sealBacklog(u.ID)

	// 旧 id：410 + 明确提示，不返回密文
	req, _ := http.NewRequest("GET", e.srv.URL+"/v1/att/"+oldAtt, nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var body2 bytes.Buffer
	body2.ReadFrom(resp.Body)
	resp.Body.Close()
	var gone map[string]any
	json.Unmarshal(body2.Bytes(), &gone)
	if resp.StatusCode != 410 || gone["error"] != "附件已加密，请刷新消息" || gone["reason"] != "sealed" || int64(gone["message_id"].(float64)) != msgID {
		t.Fatalf("旧附件 id：%d %s", resp.StatusCode, body2.String())
	}
	// 变更里有 sealed#消息 id
	ch := e.must(200, "GET", fmt.Sprintf("/v1/messages?since=%d&changes_since=%d", msgID, cursor), tok, nil)
	found := false
	for _, c := range ch["changes"].([]any) {
		c := c.(map[string]any)
		found = found || (c["kind"] == "sealed" && int64(c["id"].(float64)) == msgID)
	}
	if !found {
		t.Fatalf("没有 sealed 变更：%v", ch["changes"])
	}
	// 按 id 重新拉取：新的附件 id，密文能用信封里的钥匙解开
	m := e.must(200, "GET", fmt.Sprintf("/v1/messages/%d", msgID), tok, nil)["message"].(map[string]any)
	a := m["attachments"].([]any)[0].(map[string]any)
	if m["sealed"] != "server" || a["id"] == oldAtt {
		t.Fatalf("重新拉取的消息：%v", m)
	}
	p := openPayload(t, sk, m["e2e"].(string))
	key, _ := b64.DecodeString(p.Atts[0].Key)
	var pt bytes.Buffer
	if err := e2eDecryptFile(key, bytes.NewReader(e.download(tok, a["id"].(string))), &pt); err != nil || !bytes.Equal(pt.Bytes(), plain) {
		t.Fatalf("新附件解密：%v", err)
	}
	e.must(404, "GET", "/v1/messages/999999", tok, nil)
	e.must(400, "GET", "/v1/messages/abc", tok, nil)

	// 附件文件丢失：同样是 410，reason 为 missing
	if c, out := e.pushFiles(map[string]string{"pushkey": pk.Key, "text": "x"}, map[string][]byte{"lost.bin": []byte("x")}, []string{"lost.bin"}); c != 200 {
		t.Fatal(c, out)
	}
	ms := e.messages(tok)
	lost := ms[len(ms)-1]["attachments"].([]any)[0].(map[string]any)["id"].(string)
	var lostBlob string
	e.h.st.db.QueryRow(`SELECT blob FROM attachments WHERE id=?`, lost).Scan(&lostBlob)
	lp, _ := e.h.files.find(lostBlob)
	os.Remove(lp)
	if c, out := e.call("GET", "/v1/att/"+lost, tok, nil); c != 410 || out["reason"] != "missing" {
		t.Fatalf("文件丢失：%d %v", c, out)
	}

	// 删掉消息后，旧附件 id 返回 404（sealed_atts 一起删掉）
	e.must(200, "POST", "/v1/messages/delete", tok, map[string]any{"ids": []int64{msgID}})
	if c, out := e.call("GET", "/v1/att/"+oldAtt, tok, nil); c != 404 {
		t.Fatalf("删掉消息后旧附件 id：%d %v", c, out)
	}
	var n int
	e.h.st.db.QueryRow(`SELECT COUNT(*) FROM sealed_atts WHERE message_id=?`, msgID).Scan(&n)
	if n != 0 {
		t.Fatal("sealed_atts 没清掉")
	}
}

// 从备份恢复：只补这份数据库还引用着的附件，镜像里补加密以前的明文附件、删掉的消息的附件不带回来
func TestRestoreOnlyReferencedFiles(t *testing.T) {
	src := t.TempDir()
	st, err := OpenStore(filepath.Join(src, "huijian.db"))
	if err != nil {
		t.Fatal(err)
	}
	u, _ := st.CreateAccount("alice", "alice-pass-1")
	st.InsertMessage(NewMessage{UserID: u.ID, Topic: "t", Priority: 3, Type: "e2e", Text: e2ePlaceholder, E2E: "hje1.x", Sealed: sealedServer,
		Files: []Attachment{{Name: "encrypted-1.bin", Mime: "application/octet-stream", Size: 4, Sha256: "x", blob: "2026/11/19/120000_🔒 加密消息/encrypted-1.bin"}}})
	backup := t.TempDir()
	os.MkdirAll(filepath.Join(backup, "db"), 0o750)
	if _, err := st.db.Exec(`VACUUM INTO ?`, filepath.Join(backup, "db", "huijian-20260101-000000.db")); err != nil {
		t.Fatal(err)
	}
	st.db.Close()
	for rel, body := range map[string]string{
		"2026/11/19/120000_🔒 加密消息/encrypted-1.bin":     "HJF1",
		"2026/11/18/090000_PLAIN-TITLE/PLAIN-NAME.txt": "PLAIN-CONTENT", // 补加密以前的明文，镜像只增不删
	} {
		p := filepath.Join(backup, "files", filepath.FromSlash(rel))
		os.MkdirAll(filepath.Dir(p), 0o750)
		os.WriteFile(p, []byte(body), 0o640)
	}
	data := t.TempDir()
	t.Setenv("HUIJIAN_DATA", data)
	t.Setenv("HUIJIAN_FILES", "")
	t.Setenv("HUIJIAN_PUBLIC_ADDR", "127.0.0.1:1")
	if rc := runRestore([]string{"-y", backup}); rc != 0 {
		t.Fatalf("恢复失败 rc=%d", rc)
	}
	var found []string
	filepath.WalkDir(data, func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && !strings.HasPrefix(d.Name(), ".") && strings.Contains(p, string(filepath.Separator)+"files"+string(filepath.Separator)) {
			found = append(found, d.Name())
		}
		return nil
	})
	if len(found) != 1 || found[0] != "encrypted-1.bin" {
		t.Fatalf("恢复的附件：%v（应只有数据库引用的 encrypted-1.bin）", found)
	}
}

// R2 / M1 / L2：提交后删旧明文文件失败：登记在 pending_unlink，之后重试删掉；日志里不出现明文标题和文件名
func TestReviewPendingUnlink(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root 下 chmod 不生效")
	}
	logs := captureLog(t)
	e := newE2EEnv(t)
	u, _ := e.h.st.CreateAccount("rv2", "rv2-pass-0001")
	pk, _ := e.h.st.CreatePushkey(u.ID, "a")
	_, tok, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "m", Platform: "macos", Fingerprint: "fp-rv-00002"})
	e.legacyPlain(pk.Key, map[string]string{"text": "ORPHAN-TITLE"}, map[string][]byte{"ORPHAN-NAME.txt": []byte("ORPHAN-CONTENT")}, "ORPHAN-NAME.txt")
	var blob string
	e.h.st.db.QueryRow(`SELECT blob FROM attachments`).Scan(&blob)
	p, _ := e.h.files.find(blob)
	dir := filepath.Dir(p)
	os.Chmod(dir, 0o555) // 模拟删除失败（NAS 掉线、文件被占用）
	defer os.Chmod(dir, 0o755)

	sk := newKey(t)
	body, _, _ := keyBody(t, sk, "rv2-pass-0001")
	body["current_password"] = "rv2-pass-0001"
	e.must(200, "POST", "/v1/e2e/setup", tok, body)
	e.h.sealBacklog(u.ID)
	var pending int
	e.h.st.db.QueryRow(`SELECT COUNT(*) FROM pending_unlink WHERE blob=?`, blob).Scan(&pending)
	if _, err := os.Stat(p); err != nil || pending != 1 {
		t.Fatalf("删除失败时应登记待删：文件还在=%v，记录 %d 条", err == nil, pending)
	}
	os.Chmod(dir, 0o755)
	e.h.unlinkPending(nil) // 启动时、定时任务里调用
	e.h.st.db.QueryRow(`SELECT COUNT(*) FROM pending_unlink`).Scan(&pending)
	if _, err := os.Stat(p); !os.IsNotExist(err) || pending != 0 {
		t.Fatalf("重试后应删掉：%v，记录 %d 条", err, pending)
	}
	scanLeaks(t, e, "ORPHAN")
	if strings.Contains(logs.String(), "ORPHAN") {
		t.Fatalf("日志里有明文：\n%s", logs.String())
	}
}

// R3 / L1：同一幂等键并发发送：只留一份密文附件
func TestReviewIdemRaceOrphans(t *testing.T) {
	e := newE2EEnv(t)
	u, _ := e.h.st.CreateAccount("rv3", "rv3-pass-0001")
	pk, _ := e.h.st.CreatePushkey(u.ID, "a")
	_, tok, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "m", Platform: "macos", Fingerprint: "fp-rv-00003"})
	enableE2E(t, e, u.ID, tok, "rv3-pass-0001")
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			e.pushFiles(map[string]string{"pushkey": pk.Key, "text": "x", "idem": "same-idem"}, map[string][]byte{"a.bin": bytes.Repeat([]byte("A"), 50000)}, []string{"a.bin"})
		}()
	}
	wg.Wait()
	var rows, msgs int
	e.h.st.db.QueryRow(`SELECT COUNT(*) FROM attachments`).Scan(&rows)
	e.h.st.db.QueryRow(`SELECT COUNT(*) FROM messages`).Scan(&msgs)
	files := 0
	filepath.WalkDir(e.h.paths.files, func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && !strings.HasPrefix(d.Name(), ".") {
			files++
		}
		return nil
	})
	if msgs != 1 || rows != 1 || files != 1 {
		t.Fatalf("消息 %d 条，附件记录 %d 条，附件文件 %d 个（应各 1）", msgs, rows, files)
	}
	// 发送端加密（附件共用落盘的那条路径）：全是重复时落盘的附件也删掉
	bob, _ := e.h.st.CreateAccount("bob", "bob-pass-1234")
	pkBob, _ := e.h.st.CreatePushkey(bob.ID, "b")
	_, tokBob, _, _ := e.h.st.LoginDevice(pairReq{UserID: bob.ID, Name: "b", Platform: "macos", Fingerprint: "fp-rv-00013"})
	enableE2E(t, e, bob.ID, tokBob, "bob-pass-1234")
	bobPub, _ := e.h.st.E2EActivePub(bob.ID)
	env, _ := e2eSealMessage(bobPub, []byte(`{"v":1,"text":"y"}`))
	for i := 0; i < 2; i++ {
		if c, out := e.pushFiles(map[string]string{"pushkey": pkBob.Key, "e2e": env, "idem": "bob-idem"}, map[string][]byte{"b.bin": []byte(fmt.Sprintf("B%d", i))}, []string{"b.bin"}); c != 200 {
			t.Fatal(c, out)
		}
	}
	files = 0
	filepath.WalkDir(e.h.paths.files, func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && !strings.HasPrefix(d.Name(), ".") {
			files++
		}
		return nil
	})
	if files != 2 {
		t.Fatalf("发送端加密重复发送后附件文件 %d 个（应 2：rv3 一个、bob 一个）", files)
	}
}

// R4 / M4：补加密、代加密途中账号被重置：换新公钥重新加密，不会用已停用的旧钥匙
func TestReviewKeyChangedMidway(t *testing.T) {
	e := newE2EEnv(t)
	u, _ := e.h.st.CreateAccount("rv4", "rv4-pass-0001")
	pk, _ := e.h.st.CreatePushkey(u.ID, "a")
	_, tok, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "m", Platform: "macos", Fingerprint: "fp-rv-00004"})
	for i := 0; i < 3; i++ {
		e.legacyPlain(pk.Key, map[string]string{"text": fmt.Sprintf("OLD-%d", i)}, nil)
	}
	sk1 := newKey(t)
	body, _, _ := keyBody(t, sk1, "rv4-pass-0001")
	// 直接写库开启（不触发后台补加密），模拟「补加密进行到一半」
	if _, err := e.h.st.SetupE2E(u.ID, E2ESetupInput{Salt: body["auth_salt"].(string), AuthKey: mustB64(body["auth_key"].(string)), Pub: sk1.PublicKey().Bytes(), PasswordWrap: body["password_wrap"].(string), DeviceID: "x"}); err != nil {
		t.Fatal(err)
	}
	pub1, _ := e.h.st.E2EActivePub(u.ID)
	var ids []int64
	r, _ := e.h.st.db.Query(`SELECT id FROM messages WHERE user_id=? ORDER BY id`, u.ID)
	for r.Next() {
		var id int64
		r.Scan(&id)
		ids = append(ids, id)
	}
	r.Close()
	if ok, err := e.h.sealStored(u.ID, ids[0], pub1); !ok || err != nil {
		t.Fatal(ok, err)
	}
	sk2 := newKey(t)
	if _, err := e.h.st.ResetE2E(u.ID, E2ESetupInput{Salt: body["auth_salt"].(string), AuthKey: mustB64(body["auth_key"].(string)), Pub: sk2.PublicKey().Bytes(), PasswordWrap: body["password_wrap"].(string), DeviceID: "x"}); err != nil {
		t.Fatal(err)
	}
	// 拿旧公钥补加密：事务里发现钥匙已停用，拒绝
	if ok, err := e.h.sealStored(u.ID, ids[1], pub1); ok || !errors.Is(err, errKeyChanged) {
		t.Fatalf("用停用的钥匙补加密：ok=%v err=%v", ok, err)
	}
	e.h.sealBacklog(u.ID)
	ms := e.messages(tok)
	for _, m := range ms[1:] {
		if p := openPayload(t, sk2, m["e2e"].(string)); !strings.HasPrefix(p.Text, "OLD-") {
			t.Fatalf("载荷：%+v", p)
		}
	}
	// 代加密：拿着旧公钥写库被拒，重读公钥重新加密
	id, dup, err := e.h.pushSealed(pub1, NewMessage{UserID: u.ID, PushkeyID: pk.ID, Topic: "default", Priority: 3, Type: "markdown", Text: "NEW"}, "NEW", nil)
	if err != nil || dup {
		t.Fatal(err, dup)
	}
	m := e.must(200, "GET", fmt.Sprintf("/v1/messages/%d", id), tok, nil)["message"].(map[string]any)
	if p := openPayload(t, sk2, m["e2e"].(string)); p.Text != "NEW" {
		t.Fatalf("代加密载荷：%+v", p)
	}
	if _, _, err := e.h.st.InsertMessage(NewMessage{UserID: u.ID, Topic: "x", Type: "e2e", Text: "x", E2E: "hje1.x", SealKID: e2eKID(pub1.Bytes())}); !errors.Is(err, errKeyChanged) {
		t.Fatalf("写库时应核对钥匙：%v", err)
	}
}

// M3：读公钥出错时不能退回明文存储
func TestReviewPubErrorFailsClosed(t *testing.T) {
	e := newE2EEnv(t)
	u, _ := e.h.st.CreateAccount("rv5", "rv5-pass-0001")
	pk, _ := e.h.st.CreatePushkey(u.ID, "a")
	_, tok, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "m", Platform: "macos", Fingerprint: "fp-rv-00005"})
	enableE2E(t, e, u.ID, tok, "rv5-pass-0001")
	e.h.st.db.Exec(`UPDATE e2e_keys SET pub='!!!坏的' WHERE user_id=?`, u.ID)
	if c, _ := e.push(map[string]string{"pushkey": pk.Key, "text": "FAIL-CLOSED"}); c != 503 {
		t.Fatalf("公钥读不出来时应返回 503：%d", c)
	}
	if _, _, err := e.h.insertServerMessage(NewMessage{UserID: u.ID, Topic: "x", Type: "markdown", Text: "FAIL-CLOSED"}); err == nil {
		t.Fatal("服务端消息也不能存明文")
	}
	var n int
	e.h.st.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE text LIKE '%FAIL-CLOSED%'`).Scan(&n)
	if n != 0 {
		t.Fatal("退回了明文存储")
	}
}

// L4 / L5：上传锁住的副本时带的 kid 必须是启用中的钥匙；核对密码和写入之间凭证变了就拒绝
func TestReviewStaleKIDAndCredSnapshot(t *testing.T) {
	e := newE2EEnv(t)
	const pw = "rv6-pass-0001"
	u, _ := e.h.st.CreateAccount("rv6", pw)
	_, tok, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "m", Platform: "macos", Fingerprint: "fp-rv-00006"})
	dB, tokB, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "p", Platform: "ios", Fingerprint: "fp-rv-00007"})
	sk1 := newKey(t)
	body, auth1, _ := keyBody(t, sk1, pw)
	body["current_password"] = pw
	e.must(200, "POST", "/v1/e2e/setup", tok, body)
	oldKID := e2eKID(sk1.PublicKey().Bytes())
	sk2 := newKey(t)
	reset, auth2, _ := keyBody(t, sk2, pw)
	reset["current_auth_key"] = b64of(auth1)
	e.must(200, "POST", "/v1/e2e/reset", tok, reset)
	newKID := e2eKID(sk2.PublicKey().Bytes())

	// 还留着旧私钥的设备换恢复码 / 改密码：带旧 kid 被拒，带新 kid 或不带（0.7 客户端）照常
	rec, _ := e2eWrap("hjr1", bytes.Repeat([]byte{1}, 32), sk1.Bytes())
	e.must(409, "PUT", "/v1/e2e/recovery", tok, map[string]any{"recovery_wrap": rec, "kid": oldKID, "current_auth_key": b64of(auth2)})
	if e.h.st.Wrap(u.ID, wrapRecovery, "") != "" {
		t.Fatal("旧钥匙的恢复码副本被存下来了")
	}
	rec2, _ := e2eWrap("hjr1", bytes.Repeat([]byte{2}, 32), sk2.Bytes())
	e.must(200, "PUT", "/v1/e2e/recovery", tok, map[string]any{"recovery_wrap": rec2, "kid": newKID, "current_auth_key": b64of(auth2)})
	chg, auth3, _ := keyBody(t, sk1, "rv6-new-pass-02")
	chg["current_auth_key"], chg["kid"] = b64of(auth2), oldKID
	e.must(409, "PUT", "/v1/account/auth", tok, chg)
	e.must(200, "POST", "/v1/login", "", map[string]any{"username": "rv6", "auth_key": b64of(auth2), "name": "x"}) // 没被改掉
	_ = auth3
	// 转交：带旧 kid 被拒
	skB := newKey(t)
	nb, na := make([]byte, 32), make([]byte, 32)
	nb[0], na[0] = 1, 2
	e.must(200, "PUT", "/v1/e2e/device", tokB, map[string]any{"pub": b64of(skB.PublicKey().Bytes()), "request": true, "commit": b64of(e2eCommit(skB.PublicKey().Bytes(), sk2.PublicKey().Bytes(), nb))})
	e.must(200, "POST", "/v1/e2e/challenge", tok, map[string]any{"device_id": dB.ID, "nonce": b64of(na)})
	e.must(200, "POST", "/v1/e2e/reveal", tokB, map[string]any{"nonce": b64of(nb)})
	encG, ctG, _ := hpkeSeal(skB.PublicKey(), []byte(e2eInfoGrant), []byte("hjg1"), sk1.Bytes(), nil)
	grant := "hjg1." + b64of(append(encG, ctG...))
	e.must(409, "POST", "/v1/e2e/grant", tok, map[string]any{"device_id": dB.ID, "pub": b64of(skB.PublicKey().Bytes()), "grant": grant, "kid": oldKID})
	e.must(400, "PUT", "/v1/e2e/recovery", tok, map[string]any{"recovery_wrap": "hjr1.bad", "kid": newKID, "current_auth_key": b64of(auth2)})

	// 核对密码之后、写入之前凭证变了（另一台设备抢先重置 / 改了密码）：事务里发现，拒绝
	sk3 := newKey(t)
	r3, _, _ := keyBody(t, sk3, pw)
	snap := credSnapshot(e.h.st.db, u.ID)
	e.h.st.db.Exec(`UPDATE users SET auth_hash='sha256$changed' WHERE id=?`, u.ID)
	if _, err := e.h.st.ResetE2E(u.ID, E2ESetupInput{Salt: r3["auth_salt"].(string), AuthKey: mustB64(r3["auth_key"].(string)), Pub: sk3.PublicKey().Bytes(), PasswordWrap: r3["password_wrap"].(string), CredSnap: snap}); !errors.Is(err, errCredChanged) {
		t.Fatalf("凭证变了还能重置：%v", err)
	}
}
