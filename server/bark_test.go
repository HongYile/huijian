package main

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestParseBarkURL(t *testing.T) {
	for in, want := range map[string]string{
		"https://api.day.app/AbCd123/这里改成你自己的推送内容": "https://api.day.app/AbCd123",
		" https://api.day.app/AbCd123/ ":           "https://api.day.app/AbCd123",
		"http://10.0.0.2:8080/k_ey-1":              "http://10.0.0.2:8080/k_ey-1",
		"":                                         "",
	} {
		got, err := parseBarkURL(in)
		if err != nil || got != want {
			t.Errorf("%q → %q %v，应为 %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"api.day.app/abc", "ftp://api.day.app/abcd", "https://api.day.app/", "https://api.day.app/a%20b"} {
		if _, err := parseBarkURL(bad); err == nil {
			t.Errorf("%q 应报错", bad)
		}
	}
}

func TestPlainText(t *testing.T) {
	got := plainText("## 结果\n- best **val_loss 0.198**\n\n```python\nprint(1)\n```\n[链接](https://x.y) `code`")
	want := "结果\n· best val_loss 0.198\nprint(1)\n链接 code"
	if got != want {
		t.Fatalf("得到 %q\n应为 %q", got, want)
	}
}

type fakeBark struct {
	mu   sync.Mutex
	got  []url.Values
	fail bool
}

func (f *fakeBark) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	r.ParseForm()
	f.mu.Lock()
	f.got = append(f.got, r.PostForm)
	fail := f.fail
	f.mu.Unlock()
	if fail {
		w.WriteHeader(400)
		w.Write([]byte(`{"code":400,"message":"failed to get device token"}`))
		return
	}
	w.Write([]byte(`{"code":200,"message":"success"}`))
}

func (f *fakeBark) take() []url.Values {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := f.got
	f.got = nil
	return out
}

func TestForwardBark(t *testing.T) {
	st, err := OpenStore(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	h := &Hub{st: st, br: NewBroker(), pushLimit: NewLimiter(60, 30)}
	fb := &fakeBark{}
	srv := httptest.NewServer(fb)
	defer srv.Close()

	alice, _ := st.CreateAccount("alice", "alice-pass-1")
	phone, _, _, err := st.LoginDevice(pairReq{UserID: alice.ID, Name: "iPhone", Platform: "ios", Method: "password"})
	if err != nil {
		t.Fatal(err)
	}
	mac, _, _, _ := st.LoginDevice(pairReq{UserID: alice.ID, Name: "Mac", Platform: "macos", Method: "password", Fingerprint: "mac"})
	pk, _ := st.CreatePushkey(alice.ID, "训练脚本")
	quiet, _ := st.CreatePushkey(alice.ID, "爬虫")
	st.SetDeviceKeyMode(phone.ID, quiet.ID, modeOff)
	alias := "训练"
	st.UpdateChannel(alice.ID, channelPatch{Topic: "train", Alias: &alias})

	if err := st.SetBarkConfig(phone.ID, barkConfig{URL: srv.URL + "/KEY123"}); err != nil {
		t.Fatal(err)
	}
	send := func(key *Pushkey, prio int, topic, text, desp string) int64 {
		id, _, err := st.InsertMessage(NewMessage{UserID: alice.ID, PushkeyID: key.ID, Topic: topic, Priority: prio,
			Type: "markdown", Text: text, Desp: desp, Source: key.Name})
		if err != nil {
			t.Fatal(err)
		}
		h.forwardBark(alice.ID, id)
		return id
	}

	id := send(pk, 4, "train", "exp42 完成", "**val_loss 0.198**")
	got := fb.take()
	if len(got) != 1 {
		t.Fatalf("P4 应转发 1 条，得到 %d", len(got))
	}
	g := got[0]
	if g.Get("title") != "exp42 完成" || g.Get("body") != "val_loss 0.198" || g.Get("level") != "timeSensitive" ||
		g.Get("group") != "训练" || g.Get("url") != "huijian://message/"+itoa(id) || g.Get("isArchive") != "0" {
		t.Fatalf("转发内容不对：%v", g)
	}
	send(pk, 5, "infra", "磁盘 95%", "")
	if g := fb.take(); len(g) != 1 || g[0].Get("level") != "critical" || g[0].Get("volume") == "" || g[0].Get("body") != "来自 训练脚本" {
		t.Fatalf("P5 应为 critical 并带音量、正文为空时用来源：%v", g)
	}
	send(pk, 2, "infra", "备份完成", "")
	send(quiet, 4, "crawler", "采集完成", "")
	if g := fb.take(); len(g) != 0 {
		t.Fatalf("P2 和设为不接收的 key 都不应转发：%v", g)
	}
	// 静音频道：P4 不转发，P5 照常
	yes := true
	st.UpdateChannel(alice.ID, channelPatch{Topic: "infra", Muted: &yes})
	send(pk, 4, "infra", "普通告警", "")
	send(pk, 5, "infra", "紧急告警", "")
	if g := fb.take(); len(g) != 1 || g[0].Get("title") != "紧急告警" {
		t.Fatalf("静音频道只应转发 P5：%v", g)
	}
	// 正在 Mac 上使用：iPhone 静默（默认开启「其他设备在用时本机静默」）
	h.presence.mark(alice.ID, mac.ID)
	send(pk, 4, "train", "用 Mac 时", "")
	if g := fb.take(); len(g) != 0 {
		t.Fatalf("在用别的设备时不应转发：%v", g)
	}
	h.presence = presence{}

	// 端到端加密：标题正文只在 ciphertext 里，能用同样的 key / iv 解开
	key, iv := "0123456789abcdef0123456789abcdef", "abcdef9876543210"
	st.SetBarkConfig(phone.ID, barkConfig{URL: srv.URL + "/KEY123", Key: key, IV: iv})
	send(pk, 3, "train", "加密消息", "内容")
	g = fb.take()[0]
	if len(g) != 2 || g.Get("iv") != iv || g.Get("ciphertext") == "" {
		t.Fatalf("加密时外面只应有 ciphertext 和 iv：%v", g)
	}
	ct, _ := base64.StdEncoding.DecodeString(g.Get("ciphertext"))
	block, _ := aes.NewCipher([]byte(key))
	plain := make([]byte, len(ct))
	cipher.NewCBCDecrypter(block, []byte(iv)).CryptBlocks(plain, ct)
	plain = plain[:len(plain)-int(plain[len(plain)-1])]
	var dec map[string]string
	if err := json.Unmarshal(plain, &dec); err != nil || dec["title"] != "加密消息" || dec["body"] != "内容" ||
		dec["level"] != "active" || dec["group"] != "训练" || !strings.HasPrefix(dec["url"], "huijian://message/") || dec["isArchive"] != "0" {
		t.Fatalf("解密结果不对：%s %v", plain, err)
	}

	// 加密 P5：紧急级别、音量、铃声都在密文里；长标题截断
	send(pk, 5, "infra", strings.Repeat("长", 150), "")
	g = fb.take()[0]
	if len(g) != 2 {
		t.Fatalf("加密时外面只应有 ciphertext 和 iv：%v", g)
	}
	if d := barkDecrypt(t, g, key, iv); d["level"] != "critical" || d["volume"] != "8" || d["sound"] != "alarm" ||
		d["title"] != strings.Repeat("长", 100)+"…" {
		t.Fatalf("加密 P5 内容不对：%v", d)
	}
	// 图标：不加密时在表单里，加密时在密文里
	sendBark(barkConfig{URL: srv.URL + "/KEY123"}, barkNote{Title: "x", Body: "y", Priority: 3}, "https://x/icon.png")
	if g := fb.take(); g[0].Get("icon") != "https://x/icon.png" {
		t.Fatalf("不加密时应带 icon：%v", g)
	}
	sendBark(barkConfig{URL: srv.URL + "/KEY123", Key: key, IV: iv}, barkNote{Title: "x", Body: "y", Priority: 3}, "https://x/icon.png")
	if d := barkDecrypt(t, fb.take()[0], key, iv); d["icon"] != "https://x/icon.png" {
		t.Fatalf("加密时 icon 应在密文里：%v", d)
	}

	// Bark 返回错误：发送函数报错且错误里没有 key
	fb.fail = true
	err = sendBark(barkConfig{URL: srv.URL + "/KEY123"}, barkNote{Title: "x", Body: "y", Priority: 4}, "")
	if err == nil || strings.Contains(err.Error(), "KEY123") || !strings.Contains(err.Error(), "failed to get device token") {
		t.Fatalf("错误信息不对：%v", err)
	}
	if n := len(fb.take()); n != 1 {
		t.Fatalf("4xx 不应重试，请求了 %d 次", n)
	}
	// 连不上时错误里也不带 key
	err = sendBark(barkConfig{URL: "http://127.0.0.1:1/KEY123"}, barkNote{Title: "x", Body: "y"}, "")
	if err == nil || strings.Contains(err.Error(), "KEY123") {
		t.Fatalf("连接错误不应带 key：%v", err)
	}
	_ = time.Second
}

func barkDecrypt(t *testing.T, g url.Values, key, iv string) map[string]string {
	t.Helper()
	ct, _ := base64.StdEncoding.DecodeString(g.Get("ciphertext"))
	block, _ := aes.NewCipher([]byte(key))
	plain := make([]byte, len(ct))
	cipher.NewCBCDecrypter(block, []byte(iv)).CryptBlocks(plain, ct)
	plain = plain[:len(plain)-int(plain[len(plain)-1])]
	var d map[string]string
	if err := json.Unmarshal(plain, &d); err != nil {
		t.Fatalf("解密失败：%v", err)
	}
	return d
}

func itoa(n int64) string { b, _ := json.Marshal(n); return string(b) }
