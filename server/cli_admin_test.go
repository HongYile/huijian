package main

import (
	"crypto/ecdh"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

// captureStdout：运行 f，返回它写到标准输出的内容
func captureStdout(t *testing.T, f func()) string {
	t.Helper()
	r, w, _ := os.Pipe()
	old := os.Stdout
	os.Stdout = w
	f()
	w.Close()
	os.Stdout = old
	b, _ := io.ReadAll(r)
	return string(b)
}

func withStdin(t *testing.T, s string) {
	t.Helper()
	r, w, _ := os.Pipe()
	w.WriteString(s)
	w.Close()
	old := os.Stdin
	os.Stdin = r
	t.Cleanup(func() { os.Stdin = old })
}

// 运营方命令行：走管理端口 + 管理令牌，不经过任何账号（0.9.0 起没有建号命令，账号只能注册产生）
func TestAdminCLI(t *testing.T) {
	e := newE2EEnv(t)
	e.h.admin = &adminState{tokenHash: sha256Hex("AT_cli_test_token_0001"), started: time.Now()}
	srv := httptest.NewServer(e.h.adminMux())
	defer srv.Close()
	t.Setenv("HUIJIAN_ADMIN_ADDR", "")
	t.Setenv("HUIJIAN_ADMIN_URL", srv.URL)
	t.Setenv("HUIJIAN_ADMIN_TOKEN", "AT_cli_test_token_0001")

	// 令牌接口也不能建账号
	req, _ := http.NewRequest("POST", srv.URL+"/api/accounts", strings.NewReader(`{"username":"x1","password":"cli-pass-0001"}`))
	req.Header.Set("Authorization", "Bearer AT_cli_test_token_0001")
	if resp, err := http.DefaultClient.Do(req); err != nil || resp.StatusCode != 404 {
		t.Fatalf("/api/accounts 应 404：%v %v", resp, err)
	}
	out := captureStdout(t, func() {
		if c := runInviteCLI([]string{"new", "-n", "3", "-uses", "2", "-days", "10", "-note", "脚本"}); c != 0 {
			t.Fatalf("invite new 返回 %d", c)
		}
	})
	codes := strings.Fields(out)
	if len(codes) != 3 || len(codes[0]) != inviteLen {
		t.Fatalf("invite new 输出：%q", out)
	}
	e.must(200, "POST", "/v1/register", "", regBody("用码注册", codes[0]))
	list := captureStdout(t, func() {
		if c := runInviteCLI([]string{"list"}); c != 0 {
			t.Fatalf("invite list 返回 %d", c)
		}
	})
	if !strings.Contains(list, "注册模式：invite") || !strings.Contains(list, codes[0]+"  ok") || !strings.Contains(list, "1/2") || !strings.Contains(list, "用码注册") {
		t.Fatalf("invite list：\n%s", list)
	}

	// 令牌不对：拒绝
	t.Setenv("HUIJIAN_ADMIN_TOKEN", "AT_wrong")
	if c := runInviteCLI([]string{"list"}); c != 1 {
		t.Fatalf("错误令牌应失败：%d", c)
	}
	// 没有令牌、也读不到 admin.token
	t.Setenv("HUIJIAN_ADMIN_TOKEN", "")
	t.Setenv("HUIJIAN_DATA", t.TempDir())
	if c := runInviteCLI([]string{"list"}); c != 1 {
		t.Fatalf("没有令牌应失败：%d", c)
	}
	if c := runInviteCLI(nil); c != 2 {
		t.Fatal("没有子命令应打印用法")
	}
}

func TestLocalAdminAddr(t *testing.T) {
	t.Setenv("HUIJIAN_ADMIN_URL", "http://admin.example.com:8791") // 设了 HUIJIAN_ADMIN_ADDR 时以本机监听地址为准
	t.Setenv("HUIJIAN_ADMIN_TOKEN", "x")
	for addr, want := range map[string]string{"0.0.0.0:8791": "http://127.0.0.1:8791", "127.0.0.1:18791": "http://127.0.0.1:18791",
		":9000": "http://127.0.0.1:9000", "10.0.0.2:8791": "http://10.0.0.2:8791", "[::]:8791": "http://127.0.0.1:8791"} {
		t.Setenv("HUIJIAN_ADMIN_ADDR", addr)
		if base, _, err := localAdmin(""); err != nil || base != want {
			t.Fatalf("%s → %s %v（应 %s）", addr, base, err, want)
		}
	}
}

// huijian register：本机生成钥匙、注册即开启加密；token / 私钥写文件，不打印
func TestRegisterCLI(t *testing.T) {
	e := newE2EEnv(t)
	codes, _ := e.h.st.CreateInvites(1, 1, 24*time.Hour, "")
	dir := t.TempDir()
	tokF, keyF := dir+"/token.txt", dir+"/key.txt"
	withStdin(t, "cli-reg-pass-01\n")
	out := captureStdout(t, func() {
		if c := runRegisterCLI([]string{"-u", e.srv.URL, "-invite", codes[0], "-token-out", tokF, "-key-out", keyF, "-name", "ci", "命令行注册"}); c != 0 {
			t.Fatalf("register 返回 %d", c)
		}
	})
	tb, _ := os.ReadFile(tokF)
	kb, _ := os.ReadFile(keyF)
	tok, key := strings.TrimSpace(string(tb)), strings.TrimSpace(string(kb))
	if !strings.HasPrefix(tok, "DT_") || strings.Contains(out, tok) || strings.Contains(out, key) {
		t.Fatalf("token 应只写进文件：%q", out)
	}
	if fi, _ := os.Stat(tokF); fi.Mode().Perm() != 0o600 {
		t.Fatalf("token 文件权限 %v", fi.Mode().Perm())
	}
	st := e.must(200, "GET", "/v1/e2e", tok, nil)
	skb, _ := b64.DecodeString(key)
	sk, err := ecdh.X25519().NewPrivateKey(skb)
	if err != nil || st["enabled"] != true || st["keys"].([]any)[0].(map[string]any)["pub"] != b64.EncodeToString(sk.PublicKey().Bytes()) {
		t.Fatalf("钥匙对不上：%v %v", st, err)
	}
	// 码已用完；密码太短；缺 -token-out
	withStdin(t, "cli-reg-pass-01\n")
	if c := runRegisterCLI([]string{"-u", e.srv.URL, "-invite", codes[0], "-token-out", dir + "/t2", "另一个"}); c != 1 {
		t.Fatalf("用完的码应失败：%d", c)
	}
	withStdin(t, "short\n")
	if c := runRegisterCLI([]string{"-u", e.srv.URL, "-token-out", dir + "/t3", "x"}); c != 1 {
		t.Fatalf("密码太短应失败：%d", c)
	}
	if c := runRegisterCLI([]string{"-u", e.srv.URL, "x"}); c != 2 {
		t.Fatalf("缺 -token-out 应打印用法：%d", c)
	}
}
