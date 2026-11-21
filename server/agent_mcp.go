package main

// huijian mcp：stdio MCP 服务（JSON-RPC 2.0，每行一条消息），把 agent 命令行的能力暴露成三个工具：
//   notify(title, body?, priority?)                   发消息，不等回复
//   ask(question, body?, choices?, timeout_seconds?)  发出并等回复，返回回复文字或「超时」
//   check_replies()                                   取还没处理的回复
// 先用 huijian agent login 登录（同一个槽位：-s 或 HUIJIAN_AGENT_SESSION）。设计见 docs/agent-mcp.md §7。

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"time"
)

type mcpReq struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type mcpServer struct {
	slot  string
	out   io.Writer
	outMu sync.Mutex

	// mu 保护下面这些：会话状态在内存里只有一份（槽位文件锁保证没有别的进程同时改它）。
	// 只在读写状态时持有；ask 等回复（长轮询）期间不持有，notify / check_replies 不用排队
	mu      sync.Mutex
	st      *agentState
	unlock  func()
	waiting map[int64]int                 // 正在 ask 等回复的消息 id（check_replies 不交出这些消息的回复）
	cancels map[string]context.CancelFunc // 进行中的工具调用（按请求 id），收到 notifications/cancelled 时取消
}

func runMCP(args []string) int {
	fs := flag.NewFlagSet("mcp", flag.ContinueOnError)
	slot := fs.String("s", defaultSlot(), "会话槽位（先用 huijian agent login 登录）")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	m := &mcpServer{slot: *slot, out: os.Stdout}
	defer m.release()
	return m.serve(os.Stdin)
}

// state：取会话状态（第一次用时锁住槽位并读入）。调用方持有 m.mu
func (m *mcpServer) state() (*agentState, error) {
	if m.st != nil {
		return m.st, nil
	}
	s, unlock, err := openAgentSlot(m.slot)
	if err != nil {
		return nil, err
	}
	m.st, m.unlock = s, unlock
	return s, nil
}

// release：放开槽位（会话失效后放开，让 huijian agent login 能重新登录；下次工具调用再读）。调用方持有 m.mu，或进程退出时
func (m *mcpServer) release() {
	if m.unlock != nil {
		m.unlock()
	}
	m.st, m.unlock = nil, nil
}

// failed：会话失效（结束、key 吊销）时放开槽位，并给出提示
func (m *mcpServer) failed(prefix string, err error) (string, bool) {
	var he *agentHTTPError
	if errors.As(err, &he) && (he.Status == 401 || he.Status == 403) {
		m.mu.Lock()
		m.release()
		m.mu.Unlock()
		return prefix + err.Error() + "（会话已结束或 Agent key 已吊销：请用户在终端运行 huijian agent login 重新登录）", true
	}
	return prefix + err.Error(), true
}

func (m *mcpServer) send(v any) {
	b, _ := json.Marshal(v)
	m.outMu.Lock()
	defer m.outMu.Unlock()
	m.out.Write(append(b, '\n'))
}

func (m *mcpServer) reply(id json.RawMessage, result any) {
	m.send(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
}

func (m *mcpServer) fail(id json.RawMessage, code int, msg string) {
	m.send(map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": code, "message": msg}})
}

func (m *mcpServer) serve(in io.Reader) int {
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 1<<20), 8<<20)
	var wg sync.WaitGroup
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var r mcpReq
		if err := json.Unmarshal([]byte(line), &r); err != nil {
			m.fail(json.RawMessage("null"), -32700, "JSON 解析失败")
			continue
		}
		if len(r.ID) == 0 { // 通知：不回复。notifications/cancelled 取消进行中的调用（例如用户中断了 ask）
			if r.Method == "notifications/cancelled" {
				var p struct {
					RequestID json.RawMessage `json:"requestId"`
				}
				json.Unmarshal(r.Params, &p)
				m.mu.Lock()
				if c := m.cancels[string(p.RequestID)]; c != nil {
					c()
				}
				m.mu.Unlock()
			}
			continue
		}
		switch r.Method {
		case "initialize":
			var p struct {
				ProtocolVersion string `json:"protocolVersion"`
			}
			json.Unmarshal(r.Params, &p)
			ver := p.ProtocolVersion
			if ver == "" {
				ver = "2025-06-18"
			}
			m.reply(r.ID, map[string]any{"protocolVersion": ver, "capabilities": map[string]any{"tools": map[string]any{}},
				"serverInfo":   map[string]any{"name": "huijian", "version": version},
				"instructions": "用回笺把消息发到用户的手机和电脑。只有确实需要用户做决定时才用 ask；普通进度用 notify。"})
		case "ping":
			m.reply(r.ID, map[string]any{})
		case "tools/list":
			m.reply(r.ID, map[string]any{"tools": mcpTools()})
		case "tools/call":
			ctx, cancel := context.WithCancel(context.Background())
			m.mu.Lock()
			if m.cancels == nil {
				m.cancels = map[string]context.CancelFunc{}
			}
			m.cancels[string(r.ID)] = cancel
			m.mu.Unlock()
			wg.Add(1)
			go func(r mcpReq) { // ask 可能等很久：每个调用单独跑，不挡住别的请求
				defer wg.Done()
				defer func() {
					m.mu.Lock()
					delete(m.cancels, string(r.ID))
					m.mu.Unlock()
					cancel()
				}()
				m.call(ctx, r)
			}(r)
		default:
			m.fail(r.ID, -32601, "不支持的方法："+r.Method)
		}
	}
	// 输入结束（客户端退出）：取消进行中的调用
	m.mu.Lock()
	for _, c := range m.cancels {
		c()
	}
	m.mu.Unlock()
	wg.Wait()
	return 0
}

func mcpTools() []map[string]any {
	str := func(d string) map[string]any { return map[string]any{"type": "string", "description": d} }
	return []map[string]any{
		{"name": "notify", "description": "给用户发一条回笺消息（加密，手机和电脑都会收到），不等回复。用于进度、结果、告警。",
			"inputSchema": map[string]any{"type": "object", "required": []string{"title"}, "properties": map[string]any{
				"title":    str("标题：一句话说清发生了什么"),
				"body":     str("正文，回笺 Markdown（可选）"),
				"priority": map[string]any{"type": "integer", "minimum": 0, "maximum": 5, "description": "0–5，默认 3；4 = 重要（响铃），5 = 紧急"},
			}}},
		{"name": "ask", "description": "问用户一个问题并等待回复（用户在回笺里选快捷选项、写补充，一起发送；选了选项又写了补充时，回复第一行是选项、后面是补充）。只在确实需要用户决定时用。返回用户回复的文字；超时返回「超时」。用户之后还可能补充，用 check_replies 取。",
			"inputSchema": map[string]any{"type": "object", "required": []string{"question"}, "properties": map[string]any{
				"question":        str("要问的问题（标题）"),
				"body":            str("补充说明，回笺 Markdown（可选）"),
				"choices":         map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "maxItems": 4, "description": "快捷回复选项，最多 4 个、每个最长 20 字（可选）"},
				"timeout_seconds": map[string]any{"type": "integer", "minimum": 10, "maximum": 86400, "description": "最多等多久，默认 1800"},
			}}},
		{"name": "check_replies", "description": "取用户发来、还没处理的回复：ask 超时后用户才回的，或者 ask 拿到回复之后用户又补充的。继续做之前、结束任务之前调用一次。工具调用有 60 秒上限时（例如 Cursor 命令行）：ask 用 timeout_seconds=50，超时后反复调用 check_replies(wait_seconds=50) 分段等。",
			"inputSchema": map[string]any{"type": "object", "properties": map[string]any{
				"wait_seconds": map[string]any{"type": "integer", "minimum": 0, "maximum": 50, "description": "没有回复时最多等几秒（默认 0 = 不等）"},
			}}},
	}
}

func (m *mcpServer) call(ctx context.Context, r mcpReq) {
	var p struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(r.Params, &p); err != nil {
		m.fail(r.ID, -32602, "参数格式不对")
		return
	}
	text, isErr := m.tool(ctx, p.Name, p.Arguments)
	m.reply(r.ID, map[string]any{"content": []map[string]any{{"type": "text", "text": text}}, "isError": isErr})
}

func (m *mcpServer) tool(ctx context.Context, name string, raw json.RawMessage) (string, bool) {
	var a struct {
		Title    string   `json:"title"`
		Body     string   `json:"body"`
		Priority *int     `json:"priority"`
		Question string   `json:"question"`
		Choices  []string `json:"choices"`
		Timeout  int      `json:"timeout_seconds"`
		Wait     int      `json:"wait_seconds"`
	}
	if len(raw) > 0 && json.Unmarshal(raw, &a) != nil {
		return "参数格式不对", true
	}
	switch name {
	case "notify":
		if strings.TrimSpace(a.Title) == "" {
			return "缺少 title", true
		}
		prio := 3
		if a.Priority != nil {
			if *a.Priority < 0 || *a.Priority > 5 {
				return "priority 取值 0–5", true
			}
			prio = *a.Priority
		}
		id, _, err := m.push(ctx, agentPayload{V: 1, Kind: "message", Text: a.Title, Desp: a.Body}, prio)
		if err != nil {
			return m.failed("发送失败：", err)
		}
		return fmt.Sprintf("已发出（消息 %d）", id), false
	case "ask":
		if strings.TrimSpace(a.Question) == "" {
			return "缺少 question", true
		}
		if len(a.Choices) > 4 {
			return "choices 最多 4 个", true
		}
		for _, c := range a.Choices {
			if n := len([]rune(c)); n == 0 || n > 20 {
				return "choices 每个 1–20 字", true
			}
		}
		timeout := 30 * time.Minute
		if a.Timeout > 0 {
			timeout = time.Duration(min(max(a.Timeout, 10), 86400)) * time.Second
		}
		id, seq, err := m.push(ctx, agentPayload{V: 1, Kind: "message", Text: a.Question, Desp: a.Body, Ask: true, Choices: a.Choices}, 4)
		if err != nil {
			return m.failed("发送失败：", err)
		}
		got, err := m.wait(ctx, id, seq, timeout)
		if err != nil {
			if _, ok := err.(*agentTimeout); ok {
				return fmt.Sprintf("超时：等了 %v 用户没有回复（消息 %d）。之后可以用 check_replies 看看用户有没有回。", timeout, id), false
			}
			if ctx.Err() != nil {
				return fmt.Sprintf("已取消等待（消息 %d）。用户之后的回复可以用 check_replies 取。", id), true
			}
			return m.failed("等回复失败：", err)
		}
		// 拿到回复 ask 就结束了，之后用户再补充的话 agent 不会自动知道：提醒它适时 check_replies（2026-11-21 实测：用户回了「继续」又补了一句，agent 没看到）
		return "用户回复：\n" + got.Text + "\n\n（用户之后可能还会补充：继续做之前、结束任务之前，用 check_replies 看看有没有新回复。）", false
	case "check_replies":
		// wait_seconds：没有现成的回复时最多等这么久（≤50 秒，给工具调用有 60 秒上限的客户端分段等，例如 Cursor 命令行）
		wait := time.Duration(min(max(a.Wait, 0), 50)) * time.Second
		if wait > 0 {
			m.mu.Lock()
			if s, err := m.state(); err == nil {
				for _, g := range s.Inbox {
					if m.waiting[g.MsgID] == 0 {
						wait = 0
						break
					}
				}
			}
			m.mu.Unlock()
		}
		if err := m.fetch(ctx, wait); err != nil {
			return m.failed("取回复失败：", err)
		}
		m.mu.Lock()
		defer m.mu.Unlock()
		s, err := m.state()
		if err != nil {
			return err.Error(), true
		}
		// 正在 ask 等着的回复留给那次调用
		var out, keep []agentGot
		for _, g := range s.Inbox {
			if m.waiting[g.MsgID] > 0 {
				keep = append(keep, g)
			} else {
				out = append(out, g)
			}
		}
		s.Inbox = keep
		if err := s.save(); err != nil {
			return "保存会话失败：" + err.Error(), true
		}
		if len(out) == 0 {
			return "没有新回复", false
		}
		b, _ := json.Marshal(out)
		return string(b), false
	}
	return "没有这个工具：" + name, true
}

// push：持锁加密、记序号、发出
func (m *mcpServer) push(ctx context.Context, p agentPayload, prio int) (int64, int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, err := m.state()
	if err != nil {
		return 0, 0, err
	}
	return agentSend(ctx, s, p, prio, env("HUIJIAN_TOPIC", "agent"), "")
}

// fetch：取一次回复。网络请求不持锁；解开、存盘持锁；回执在存盘之后发
func (m *mcpServer) fetch(ctx context.Context, wait time.Duration) error {
	m.mu.Lock()
	s, err := m.state()
	m.mu.Unlock()
	if err != nil {
		return err
	}
	raw, err := agentPoll(ctx, s, wait)
	if err != nil {
		return err
	}
	m.mu.Lock()
	receipts, bad := agentAccept(s, raw)
	if len(receipts) > 0 {
		err = s.save()
	}
	m.mu.Unlock()
	if err != nil {
		return err
	}
	if len(receipts) > 0 {
		return agentAck(ctx, s, receipts)
	}
	if bad > 0 {
		sleepCtx(ctx, min(wait, 5*time.Second))
	}
	return nil
}

// wait：等某条消息（id、seq）的回复
func (m *mcpServer) wait(ctx context.Context, id, seq int64, timeout time.Duration) (agentGot, error) {
	m.mu.Lock()
	if m.waiting == nil {
		m.waiting = map[int64]int{}
	}
	m.waiting[id]++
	m.mu.Unlock()
	defer func() {
		m.mu.Lock()
		if m.waiting[id]--; m.waiting[id] <= 0 {
			delete(m.waiting, id)
		}
		m.mu.Unlock()
	}()
	deadline := time.Now().Add(timeout)
	for {
		m.mu.Lock()
		var got agentGot
		ok := false
		if m.st != nil {
			if got, ok = m.st.take(id, seq); ok {
				m.st.save()
			}
		}
		m.mu.Unlock()
		if ok {
			return got, nil
		}
		left := time.Until(deadline)
		if left <= 0 {
			return agentGot{}, &agentTimeout{timeout}
		}
		if err := ctx.Err(); err != nil {
			return agentGot{}, err
		}
		if err := m.fetch(ctx, min(left, agentWaitMax)); err != nil {
			if agentFatal(err) || ctx.Err() != nil {
				return agentGot{}, err
			}
			fmt.Fprintln(os.Stderr, "取回复出错，稍后重试：", err)
			sleepCtx(ctx, 5*time.Second)
		}
	}
}
