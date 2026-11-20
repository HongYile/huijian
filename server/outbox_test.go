package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 带附件的任务进了 outbox 以后补发：补发时任务目录被改名认领（.claim-<pid>），
// job.json 里记的附件路径要跟着换到认领后的目录，否则一直报 no such file
func TestOutboxFlushWithAttachments(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	e := newE2EEnv(t)
	u, _ := e.h.st.CreateAccount("ob", "outbox-pass-01")
	pk, _ := e.h.st.CreatePushkey(u.ID, "cli")
	_, tok, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "m", Platform: "macos", Fingerprint: "fp-ob-000001"})
	sk := newKey(t)
	e.h.st.db.Exec(`INSERT INTO e2e_keys(user_id,kid,pub,created_at,active) VALUES(?,?,?,?,1)`, u.ID, e2eKID(sk.PublicKey().Bytes()), b64of(sk.PublicKey().Bytes()), 1)

	src := t.TempDir()
	old := filepath.Join(src, "att-old.txt")
	os.WriteFile(old, []byte("OUTBOX-FILE-1"), 0o600)
	png := filepath.Join(src, "曲线.png")
	os.WriteFile(png, []byte("OUTBOX-FILE-2"), 0o600)

	for _, c := range []struct {
		name, key string
	}{
		{"普通 pushkey（服务器代加密）", pk.Key},
		{"加密发送密钥（本机加密）", pk.Key + e2eSendKeySep + b64of(sk.PublicKey().Bytes())},
	} {
		// 服务器不可达时存进 outbox（原文件之后被删也不影响）
		job := Job{URLs: []string{"http://127.0.0.1:1"}, Pushkey: c.key, Text: "OB " + c.name, Priority: 3,
			Files: []string{old, png}, Idem: "cli_" + randHex(6)}
		if _, retry, err := sendJob(job); err == nil || !retry {
			t.Fatalf("%s：应发送失败且可重试：%v %v", c.name, retry, err)
		}
		dir, err := saveOutbox(job)
		if err != nil {
			t.Fatal(err)
		}
		// 服务器恢复：改 job.json 里的地址（相当于原地址恢复）
		b, _ := os.ReadFile(filepath.Join(dir, "job.json"))
		var saved Job
		json.Unmarshal(b, &saved)
		saved.URLs = []string{e.srv.URL}
		b, _ = json.Marshal(saved)
		os.WriteFile(filepath.Join(dir, "job.json"), b, 0o600)

		before := len(e.messages(tok))
		if ok, left := flushOutbox(true); ok != 1 || left != 0 {
			ents, _ := os.ReadDir(filepath.Join(outboxDir(), "failed"))
			t.Fatalf("%s：补发成功 %d，剩余 %d，failed/ 里 %d 个", c.name, ok, left, len(ents))
		}
		ms := e.messages(tok)
		if len(ms) != before+1 {
			t.Fatalf("%s：消息数 %d → %d", c.name, before, len(ms))
		}
		m := ms[len(ms)-1]
		p := openPayload(t, sk, m["e2e"].(string))
		if p.Text != "OB "+c.name || len(p.Atts) != 2 || p.Atts[0].Name != "att-old.txt" || p.Atts[1].Name != "曲线.png" {
			t.Fatalf("%s：载荷 %+v", c.name, p)
		}
		atts := m["attachments"].([]any)
		for i, want := range []string{"OUTBOX-FILE-1", "OUTBOX-FILE-2"} {
			key, _ := b64.DecodeString(p.Atts[i].Key)
			var out bytes.Buffer
			if err := e2eDecryptFile(key, bytes.NewReader(e.download(tok, atts[i].(map[string]any)["id"].(string))), &out); err != nil || out.String() != want {
				t.Fatalf("%s：附件 %d 解密 %v %q", c.name, i, err, out.String())
			}
		}
		// outbox 清空，没有残留的认领目录
		ents, _ := os.ReadDir(outboxDir())
		for _, en := range ents {
			if en.Name() != "failed" {
				t.Fatalf("%s：outbox 里还剩 %s", c.name, en.Name())
			}
		}
		if ents, _ := os.ReadDir(filepath.Join(outboxDir(), "failed")); len(ents) != 0 {
			t.Fatalf("%s：进了 failed/", c.name)
		}
	}
	// 旧版本存的任务（没有 names，路径指向认领前的目录）：照样能补发，显示名去掉序号前缀
	legacy := filepath.Join(outboxDir(), "1000")
	os.MkdirAll(legacy, 0o700)
	os.WriteFile(filepath.Join(legacy, "00_att-old.txt"), []byte("OUTBOX-LEGACY"), 0o600)
	lj, _ := json.Marshal(map[string]any{"urls": []string{e.srv.URL}, "pushkey": pk.Key, "text": "OB legacy", "priority": 3,
		"files": []string{filepath.Join(legacy, "00_att-old.txt")}, "idem": "cli_legacy"})
	os.WriteFile(filepath.Join(legacy, "job.json"), lj, 0o600)
	if ok, left := flushOutbox(true); ok != 1 || left != 0 {
		t.Fatalf("旧格式任务：补发成功 %d，剩余 %d", ok, left)
	}
	ms := e.messages(tok)
	if p := openPayload(t, sk, ms[len(ms)-1]["e2e"].(string)); p.Text != "OB legacy" || p.Atts[0].Name != "att-old.txt" {
		t.Fatalf("旧格式任务：%+v", p)
	}

	// 附件显示名：outbox 里复制出来的 00_ 前缀不出现在收到的文件名里
	p := openPayload(t, sk, ms[len(ms)-2]["e2e"].(string))
	if strings.HasPrefix(p.Atts[0].Name, "00_") {
		t.Fatalf("附件名带上了 outbox 的序号前缀：%s", p.Atts[0].Name)
	}
}
