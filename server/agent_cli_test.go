package main

// huijian agent 命令行和 huijian mcp：对本地服务端走一遍登录（设备批准 + 核对码）、发消息、回复、回执、MCP 工具调用

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// approveNext：设备一侧，等到有新的登录请求就出 na、等揭晓、核对承诺后写证明批准
func (f *agentFixture) approveNext(t *testing.T) string {
	t.Helper()
	e := f.e
	deadline := time.Now().Add(10 * time.Second)
	var sid string
	na := randBytes(32)
	for time.Now().Before(deadline) {
		for _, x := range e.agentMust(200, "GET", "/v1/agent/sessions", f.tokA, nil)["sessions"].([]any) {
			s := x.(map[string]any)
			if s["state"] != agentPending {
				continue
			}
			if sid == "" {
				sid = s["id"].(string)
				e.agentMust(200, "POST", "/v1/agent/sessions/"+sid+"/challenge", f.tokA, map[string]any{"nonce": b64of(na)})
				continue
			}
			if s["id"] == sid && s["reveal"] != "" {
				pub, _ := b64.DecodeString(s["pub"].(string))
				rev, _ := b64.DecodeString(s["reveal"].(string))
				cm, _ := b64.DecodeString(s["commit"].(string))
				if !bytes.Equal(agentCommit(pub, f.acctSK.PublicKey().Bytes(), rev), cm) {
					t.Fatal("承诺核对失败")
				}
				att, _ := agentAttestSeal(f.acctSK.Bytes(), agentAttest{SessionID: sid, Pub: s["pub"].(string), Name: s["name"].(string), ApprovedAt: now()})
				e.agentMust(200, "POST", "/v1/agent/sessions/"+sid+"/approve", f.tokA, map[string]any{"attest": att})
				return sid
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("没等到登录请求")
	return ""
}

func TestAgentCLIAndMCP(t *testing.T) {
	f := newAgentFixture(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("HUIJIAN_URL", f.e.srv.URL)
	t.Setenv("HUIJIAN_AGENT_KEY", f.ak)
	t.Setenv("HUIJIAN_AGENT_SESSION", "")
	t.Setenv("HUIJIAN_TOPIC", "")

	// 登录：命令行打印核对码、等批准；设备批准后保存会话（目录 700、文件 600）
	done := make(chan error, 1)
	go func() { done <- agentLoginCmd([]string{"-name", "CLI 测试", "-s", "t1"}) }()
	sid := f.approveNext(t)
	if err := <-done; err != nil {
		t.Fatalf("登录失败：%v", err)
	}
	p := filepath.Join(home, ".huijian", "agent", "t1", "session.json")
	fi, err := os.Stat(p)
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("会话文件权限：%v %v", fi, err)
	}
	if di, _ := os.Stat(filepath.Dir(p)); di.Mode().Perm() != 0o700 {
		t.Fatalf("会话目录权限：%v", di.Mode())
	}
	s, err := loadAgentState("t1")
	if err != nil || s.SessionID != sid || !strings.HasPrefix(s.Token, "ST_") || s.AccountPub != b64of(f.acctSK.PublicKey().Bytes()) {
		t.Fatalf("会话状态不对：%+v %v", s, err)
	}
	if _, err := loadAgentState("../x"); err == nil {
		t.Fatal("槽位名不能带路径")
	}

	// 发消息：设备能解开，载荷带 choices、seq
	id, err := agentSend(s, agentPayload{V: 1, Kind: "message", Text: "选一个", Ask: true, Choices: []string{"A", "B"}}, 4, "agent", "")
	if err != nil {
		t.Fatal(err)
	}
	sessSK, _, _ := s.keys()
	pk := sessSK.PublicKey()
	var env string
	f.e.h.st.db.QueryRow(`SELECT e2e FROM messages WHERE id=?`, id).Scan(&env)
	pt, err := agentOpen(f.acctSK, pk, env)
	var pl agentPayload
	json.Unmarshal(pt, &pl)
	if err != nil || pl.Text != "选一个" || len(pl.Choices) != 2 || pl.Seq != 1 || !pl.Ask {
		t.Fatalf("设备解开的消息不对：%+v %v", pl, err)
	}

	// 等回复：期间先来一条别的消息的回复（进 inbox），再来这条的
	other, _ := agentSend(s, agentPayload{V: 1, Kind: "message", Text: "进度"}, 3, "agent", "")
	go func() {
		time.Sleep(300 * time.Millisecond)
		f.reply(t, f.tokB, sid, pk, other, "收到")
		time.Sleep(300 * time.Millisecond)
		f.reply(t, f.tokB, sid, pk, id, "B")
	}()
	got, err := agentWaitReply(s, id, 10*time.Second)
	if err != nil || got.Text != "B" || got.MsgID != id {
		t.Fatalf("等回复：%+v %v", got, err)
	}
	if len(s.Inbox) != 1 || s.Inbox[0].Text != "收到" {
		t.Fatalf("别的回复应进 inbox：%+v", s.Inbox)
	}
	// 回执：两条都确认了
	var n int
	f.e.h.st.db.QueryRow(`SELECT COUNT(*) FROM agent_replies WHERE session_id=? AND state=? AND receipt!=''`, sid, replyReceived).Scan(&n)
	if n != 2 {
		t.Fatalf("应有 2 条带回执的回复：%d", n)
	}
	// 超时
	if _, err := agentWaitReply(s, id, 1*time.Second); err == nil {
		t.Fatal("应超时")
	} else if _, ok := err.(*agentTimeout); !ok {
		t.Fatalf("应返回超时：%v", err)
	}

	// MCP：initialize、tools/list、notify、ask（设备回复）、check_replies（交出 inbox）
	pr, pw := io.Pipe()
	var out bytes.Buffer
	m := &mcpServer{slot: "t1", out: &syncWriter{w: &out}}
	finished := make(chan int, 1)
	go func() { finished <- m.serve(pr) }()
	write := func(v any) { b, _ := json.Marshal(v); pw.Write(append(b, '\n')) }
	write(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": map[string]any{"protocolVersion": "2025-06-18"}})
	write(map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})
	write(map[string]any{"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
	write(map[string]any{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": map[string]any{"name": "notify", "arguments": map[string]any{"title": "MCP 进度", "priority": 2}}})
	write(map[string]any{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": map[string]any{"name": "ask", "arguments": map[string]any{"question": "继续吗？", "choices": []string{"继续", "停"}, "timeout_seconds": 20}}})
	// 设备回复 ask 那条（等它出现在消息列表里）
	go func() {
		for i := 0; i < 100; i++ {
			var mid int64
			f.e.h.st.db.QueryRow(`SELECT id FROM messages WHERE agent_session=? AND ask=1 ORDER BY id DESC LIMIT 1`, sid).Scan(&mid)
			if mid > id {
				f.reply(t, f.tokB, sid, pk, mid, "继续")
				return
			}
			time.Sleep(100 * time.Millisecond)
		}
	}()
	write(map[string]any{"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": map[string]any{"name": "check_replies", "arguments": map[string]any{}}})
	write(map[string]any{"jsonrpc": "2.0", "id": 6, "method": "nope"})
	time.Sleep(3 * time.Second)
	pw.Close()
	<-finished
	res := map[float64]map[string]any{}
	for _, line := range strings.Split(strings.TrimSpace(out.String()), "\n") {
		var r map[string]any
		if json.Unmarshal([]byte(line), &r) != nil {
			t.Fatalf("输出不是 JSON：%s", line)
		}
		res[r["id"].(float64)] = r
	}
	if len(res) != 6 {
		t.Fatalf("应有 6 个响应（通知不回复）：%s", out.String())
	}
	text := func(id float64) string {
		c := res[id]["result"].(map[string]any)["content"].([]any)[0].(map[string]any)
		return c["text"].(string)
	}
	if res[1]["result"].(map[string]any)["protocolVersion"] != "2025-06-18" ||
		len(res[2]["result"].(map[string]any)["tools"].([]any)) != 3 ||
		!strings.HasPrefix(text(3), "已发出") || text(4) != "继续" ||
		!strings.Contains(text(5), "收到") || res[6]["error"] == nil {
		t.Fatalf("MCP 响应不对：%s", out.String())
	}

	// 退出：服务器上会话结束，本地文件删掉
	if err := agentLogoutCmd([]string{"-s", "t1"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Fatal("退出后会话文件应删除")
	}
	f.e.agentMust(401, "GET", "/v1/agent/replies", s.Token, nil)
}

type syncWriter struct{ w io.Writer }

func (s *syncWriter) Write(b []byte) (int, error) { return s.w.Write(b) }
