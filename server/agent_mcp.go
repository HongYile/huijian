package main

// huijian mcp：stdio MCP 服务（JSON-RPC 2.0，每行一条消息），把 agent 命令行的能力暴露成三个工具：
//   notify(title, body?, priority?)                   发消息，不等回复
//   ask(question, body?, choices?, timeout_seconds?)  发出并等回复，返回回复文字或「超时」
//   check_replies()                                   取还没处理的回复
// 先用 huijian agent login 登录（同一个槽位：-s 或 HUIJIAN_AGENT_SESSION）。设计见 docs/agent-mcp.md §7。

import (
	"bufio"
	"encoding/json"
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
	stMu  sync.Mutex // 会话状态文件：同一时间只有一个工具调用读写（ask 等回复期间别的工具调用排队）
}

func runMCP(args []string) int {
	fs := flag.NewFlagSet("mcp", flag.ContinueOnError)
	slot := fs.String("s", defaultSlot(), "会话槽位（先用 huijian agent login 登录）")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	m := &mcpServer{slot: *slot, out: os.Stdout}
	return m.serve(os.Stdin)
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
		if len(r.ID) == 0 { // 通知（notifications/initialized 等）：不回复
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
			wg.Add(1)
			go func(r mcpReq) { // ask 可能等很久：每个调用单独跑，不挡住别的请求
				defer wg.Done()
				m.call(r)
			}(r)
		default:
			m.fail(r.ID, -32601, "不支持的方法："+r.Method)
		}
	}
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
		{"name": "ask", "description": "问用户一个问题并等待回复（用户在回笺里直接回复，可以点快捷选项）。只在确实需要用户决定时用。返回用户回复的文字；超时返回「超时」。",
			"inputSchema": map[string]any{"type": "object", "required": []string{"question"}, "properties": map[string]any{
				"question":        str("要问的问题（标题）"),
				"body":            str("补充说明，回笺 Markdown（可选）"),
				"choices":         map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "maxItems": 4, "description": "快捷回复选项，最多 4 个、每个最长 20 字（可选）"},
				"timeout_seconds": map[string]any{"type": "integer", "minimum": 10, "maximum": 86400, "description": "最多等多久，默认 1800"},
			}}},
		{"name": "check_replies", "description": "取用户发来、还没处理的回复（例如之前 ask 超时后用户才回的）。",
			"inputSchema": map[string]any{"type": "object", "properties": map[string]any{}}},
	}
}

func (m *mcpServer) call(r mcpReq) {
	var p struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(r.Params, &p); err != nil {
		m.fail(r.ID, -32602, "参数格式不对")
		return
	}
	text, isErr := m.tool(p.Name, p.Arguments)
	m.reply(r.ID, map[string]any{"content": []map[string]any{{"type": "text", "text": text}}, "isError": isErr})
}

func (m *mcpServer) tool(name string, raw json.RawMessage) (string, bool) {
	var a struct {
		Title    string   `json:"title"`
		Body     string   `json:"body"`
		Priority *int     `json:"priority"`
		Question string   `json:"question"`
		Choices  []string `json:"choices"`
		Timeout  int      `json:"timeout_seconds"`
	}
	if len(raw) > 0 && json.Unmarshal(raw, &a) != nil {
		return "参数格式不对", true
	}
	// 工具调用一个一个来：会话状态（消息序号、处理过的回复）只有一份，并发写会丢序号（幂等键重复，消息被服务器当成重发吞掉）
	m.stMu.Lock()
	defer m.stMu.Unlock()
	s, err := loadAgentState(m.slot)
	if err != nil {
		return err.Error(), true
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
		id, err := agentSend(s, agentPayload{V: 1, Kind: "message", Text: a.Title, Desp: a.Body}, prio, env("HUIJIAN_TOPIC", "agent"), "")
		if err != nil {
			return "发送失败：" + err.Error(), true
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
		id, err := agentSend(s, agentPayload{V: 1, Kind: "message", Text: a.Question, Desp: a.Body, Ask: true, Choices: a.Choices}, 4,
			env("HUIJIAN_TOPIC", "agent"), "")
		if err != nil {
			return "发送失败：" + err.Error(), true
		}
		got, err := agentWaitReply(s, id, timeout)
		if err != nil {
			if _, ok := err.(*agentTimeout); ok {
				return fmt.Sprintf("超时：等了 %v 用户没有回复（消息 %d）。之后可以用 check_replies 看看用户有没有回。", timeout, id), false
			}
			return "等回复失败：" + err.Error(), true
		}
		return got.Text, false
	case "check_replies":
		all := s.Inbox
		got, err := agentFetch(s, 0)
		if err != nil {
			return "取回复失败：" + err.Error(), true
		}
		all = append(all, got...)
		s.Inbox = nil
		if err := s.save(); err != nil {
			return "保存会话失败：" + err.Error(), true
		}
		if len(all) == 0 {
			return "没有新回复", false
		}
		b, _ := json.Marshal(all)
		return string(b), false
	}
	return "没有这个工具：" + name, true
}
