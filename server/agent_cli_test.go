package main

// huijian agent 命令行和 huijian mcp：对本地服务端走一遍登录（设备批准 + 核对码）、发消息、回复、回执、MCP 工具调用

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"runtime"
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
				if !bytes.Equal(agentCommit(pub, f.acctSK.PublicKey().Bytes(), rev, s["name"].(string)), cm) {
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

	// 槽位上锁：同一槽位第二个进程拿不到锁
	unlock, err := lockAgentSlot(filepath.Dir(p))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lockAgentSlot(filepath.Dir(p)); runtime.GOOS != "windows" && err == nil {
		t.Fatal("同一槽位不能同时被两处锁住")
	}
	if err := agentLogoutCmd([]string{"-s", "t1"}); err == nil || !strings.Contains(err.Error(), "正被另一个进程使用") {
		t.Fatalf("槽位被占用时命令应失败：%v", err)
	}
	unlock()
	ctx := context.Background()

	// 发消息：设备能解开，载荷带 choices、seq
	id, seq1, err := agentSend(ctx, s, agentPayload{V: 1, Kind: "message", Text: "选一个", Ask: true, Choices: []string{"A", "B"}}, 4, "agent", "")
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
	if err != nil || pl.Text != "选一个" || len(pl.Choices) != 2 || pl.Seq != 1 || seq1 != 1 || !pl.Ask {
		t.Fatalf("设备解开的消息不对：%+v %v", pl, err)
	}

	// 服务器把回复挪到别的消息下（回复里的 re_seq 对不上记下的序号）：不收、不发回执
	other, seq2, _ := agentSend(ctx, s, agentPayload{V: 1, Kind: "message", Text: "进度"}, 3, "agent", "")
	moved, _ := json.Marshal(agentReply{V: 1, ReSeq: seq1, Text: "挪过来的", N: b64of(randBytes(16)), SentAt: now()})
	menv, _ := agentReplySeal(pk, f.acctSK, sid, other, moved, nil)
	if rc, bad := agentAccept(s, []agentRaw{{ReplyID: 99, MsgID: other, E2E: menv}}); len(rc) != 0 || bad != 1 || len(s.Inbox) != 0 {
		t.Fatalf("挪了位置的回复应拒绝：%d %d %v", len(rc), bad, s.Inbox)
	}
	// 太旧的回复（超过处理记录的保留期）：拒绝
	old, _ := json.Marshal(agentReply{V: 1, ReSeq: seq2, Text: "旧", N: b64of(randBytes(16)), SentAt: now() - agentReplyKeep - 10})
	oenv, _ := agentReplySeal(pk, f.acctSK, sid, other, old, nil)
	if _, bad := agentAccept(s, []agentRaw{{ReplyID: 98, MsgID: other, E2E: oenv}}); bad != 1 {
		t.Fatal("太旧的回复应拒绝")
	}

	// 等回复：期间先来一条别的消息的回复（进 inbox），再来这条的
	go func() {
		time.Sleep(300 * time.Millisecond)
		f.reply(t, f.tokB, sid, pk, other, "收到")
		time.Sleep(300 * time.Millisecond)
		f.reply(t, f.tokB, sid, pk, id, "B")
	}()
	got, err := agentWaitReply(ctx, s, id, seq1, 10*time.Second)
	if err != nil || got.Text != "B" || got.MsgID != id || got.ReSeq != seq1 {
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
	if _, err := agentWaitReply(ctx, s, id, seq1, 1*time.Second); err == nil {
		t.Fatal("应超时")
	} else if _, ok := err.(*agentTimeout); !ok {
		t.Fatalf("应返回超时：%v", err)
	}

	// 回执没送到（ack 失败）：回复已经存进 Inbox，重新读出来还在；再取到同一条时不重复交出
	third, seq3, _ := agentSend(ctx, s, agentPayload{V: 1, Kind: "message", Text: "第三条", Ask: true}, 4, "agent", "")
	f.reply(t, f.tokB, sid, pk, third, "三")
	raw, _ := agentPoll(ctx, s, 0)
	if rc, _ := agentAccept(s, raw); len(rc) != 1 || s.save() != nil {
		t.Fatal("应解开一条回复")
	}
	s2, _ := loadAgentState("t1")
	if g, ok := s2.take(third, seq3); !ok || g.Text != "三" {
		t.Fatalf("没发回执的回复应留在 Inbox：%+v", s2.Inbox)
	}
	raw, _ = agentPoll(ctx, s2, 0)
	if rc, _ := agentAccept(s2, raw); len(rc) != 1 || len(s2.Inbox) != 1 || s2.Inbox[0].Text != "收到" {
		t.Fatalf("再取到同一条：照发回执、不重复交出：%d %v", len(rc), s2.Inbox)
	}
	agentAck(ctx, s2, func() []map[string]any { rc, _ := agentAccept(s2, raw); return rc }())
	s2.save()

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
			if mid > third {
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
	m.release()
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
		!strings.HasPrefix(text(3), "已发出") || !strings.HasPrefix(text(4), "用户回复：\n继续\n") ||
		!strings.Contains(text(5), "收到") || res[6]["error"] == nil {
		t.Fatalf("MCP 响应不对：%s", out.String())
	}

	// check_replies(wait_seconds)：没有回复时等到期限；等的中途用户补充了，立刻返回
	m2 := &mcpServer{slot: "t1", out: &syncWriter{w: io.Discard}}
	t0 := time.Now()
	if txt, bad := m2.tool(context.Background(), "check_replies", json.RawMessage(`{"wait_seconds":2}`)); bad || txt != "没有新回复" || time.Since(t0) < 1500*time.Millisecond {
		t.Fatalf("check_replies 等待不对：%q %v %v", txt, bad, time.Since(t0))
	}
	var askID int64
	f.e.h.st.db.QueryRow(`SELECT id FROM messages WHERE agent_session=? AND ask=1 ORDER BY id DESC LIMIT 1`, sid).Scan(&askID)
	go func() { time.Sleep(time.Second); f.reply(t, f.tokB, sid, pk, askID, "再补一句") }()
	t0 = time.Now()
	if txt, bad := m2.tool(context.Background(), "check_replies", json.RawMessage(`{"wait_seconds":20}`)); bad || !strings.Contains(txt, "再补一句") || time.Since(t0) > 10*time.Second {
		t.Fatalf("check_replies 等到补充应立刻返回：%q %v %v", txt, bad, time.Since(t0))
	}
	m2.mu.Lock()
	m2.release()
	m2.mu.Unlock()

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
