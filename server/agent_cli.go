package main

// huijian agent：agent 一侧的命令行（docs/agent-mcp.md §7）。
//
//	huijian agent login  [-name 显示名] [-s 槽位]   发起登录，打印核对码，等设备批准
//	huijian agent send   [-p 3] [-d 正文] [-choice 选项]... [-ask] 标题
//	huijian agent ask    [-timeout 30m] [-choice 选项]... 问题   发出并等回复，回复打印到标准输出
//	huijian agent replies [-wait 60]                 取回复（每行一条 JSON），自动回执
//	huijian agent status / logout
//
// 地址和 Agent key：-u / -k，或环境变量 HUIJIAN_URL、HUIJIAN_AGENT_KEY。会话状态（会话私钥、令牌、钉住的账号公钥、
// 处理过的回复）存在 ~/.huijian/agent/<槽位>/session.json（目录 700、文件 600）；槽位默认 HUIJIAN_AGENT_SESSION 或 default。

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// agentState：一个会话在本机的全部状态
type agentState struct {
	Server     string           `json:"server"`
	Name       string           `json:"name"`
	SessionID  string           `json:"session_id"`
	SK         string           `json:"sk"`          // 会话私钥（base64url）
	Token      string           `json:"token"`       // 会话令牌 ST_
	AccountPub string           `json:"account_pub"` // 登录时钉住的账号公钥
	Seq        int64            `json:"seq"`
	Seen       map[string]int64 `json:"seen,omitempty"`  // 处理过的回复随机数 n → 时间（保留 3 天，重放的丢弃）
	Inbox      []agentGot       `json:"inbox,omitempty"` // ask 等待期间收到的、别的消息的回复（下次 replies 时交出）
	path       string
}

// agentGot：解开、核对过的一条回复
type agentGot struct {
	ReplyID int64  `json:"reply_id"`
	MsgID   int64  `json:"msg_id"`
	Text    string `json:"text"`
	SentAt  int64  `json:"sent_at"`
	Device  string `json:"device,omitempty"`
}

var reSlot = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,64}$`)

func agentDir(slot string) (string, error) {
	if !reSlot.MatchString(slot) || slot == "." || slot == ".." {
		return "", fmt.Errorf("会话槽位名只能用字母、数字、_ . -：%q", slot)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".huijian", "agent", slot), nil
}

func loadAgentState(slot string) (*agentState, error) {
	dir, err := agentDir(slot)
	if err != nil {
		return nil, err
	}
	p := filepath.Join(dir, "session.json")
	b, err := os.ReadFile(p)
	if errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("还没有登录：先运行 huijian agent login（槽位 %s）", slot)
	}
	if err != nil {
		return nil, err
	}
	var s agentState
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, fmt.Errorf("会话文件损坏（%s）：%v", p, err)
	}
	s.path = p
	if s.Seen == nil {
		s.Seen = map[string]int64{}
	}
	return &s, nil
}

func (s *agentState) save() error {
	cut := now() - agentReplyKeep
	for n, at := range s.Seen {
		if at < cut {
			delete(s.Seen, n)
		}
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	os.Chmod(filepath.Dir(s.path), 0o700)
	b, _ := json.MarshalIndent(s, "", "  ")
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

func (s *agentState) keys() (*ecdh.PrivateKey, *ecdh.PublicKey, error) {
	skb, err := b64.DecodeString(s.SK)
	if err != nil {
		return nil, nil, errors.New("会话文件里的私钥格式不对")
	}
	sk, err := ecdh.X25519().NewPrivateKey(skb)
	if err != nil {
		return nil, nil, errors.New("会话文件里的私钥格式不对")
	}
	pb, err := b64.DecodeString(s.AccountPub)
	if err != nil {
		return nil, nil, errors.New("会话文件里的账号公钥格式不对")
	}
	pub, err := ecdh.X25519().NewPublicKey(pb)
	if err != nil {
		return nil, nil, errors.New("会话文件里的账号公钥格式不对")
	}
	return sk, pub, nil
}

// ---------- HTTP ----------

type agentHTTPError struct {
	Status int
	Msg    string
}

func (e *agentHTTPError) Error() string { return fmt.Sprintf("%d %s", e.Status, e.Msg) }

func agentReq(method, server, path, tok string, body any, timeout time.Duration) (map[string]any, error) {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, strings.TrimRight(server, "/")+path, rd)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("User-Agent", "huijian-agent/"+version)
	c := *pushClient
	c.Timeout = timeout
	resp, err := c.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	var out map[string]any
	json.Unmarshal(raw, &out)
	if resp.StatusCode != 200 {
		msg, _ := out["error"].(string)
		if msg == "" {
			msg = strings.TrimSpace(string(raw))
			if resp.StatusCode == 404 && !strings.HasPrefix(msg, "{") {
				msg = "服务器不支持 agent（需要回笺服务端 0.10.0 以上）"
			}
		}
		return out, &agentHTTPError{resp.StatusCode, msg}
	}
	return out, nil
}

// ---------- 子命令 ----------

func runAgentCLI(args []string) int {
	if len(args) == 0 {
		agentUsage()
		return 2
	}
	var err error
	switch args[0] {
	case "login":
		err = agentLoginCmd(args[1:])
	case "send":
		err = agentSendCmd(args[1:], false)
	case "ask":
		err = agentSendCmd(args[1:], true)
	case "replies":
		err = agentRepliesCmd(args[1:])
	case "status":
		err = agentStatusCmd(args[1:])
	case "logout":
		err = agentLogoutCmd(args[1:])
	case "-h", "--help", "help":
		agentUsage()
		return 0
	default:
		agentUsage()
		return 2
	}
	if err != nil {
		var te *agentTimeout
		if errors.As(err, &te) {
			fmt.Fprintln(os.Stderr, err)
			return 3
		}
		fmt.Fprintln(os.Stderr, "失败：", err)
		return 1
	}
	return 0
}

func agentUsage() {
	fmt.Fprint(os.Stderr, `用法：
  huijian agent login  [-name 显示名] [-s 槽位]      登录：打印 6 位核对码，在回笺设备上核对后批准
  huijian agent send   [-p 3] [-d 正文] [-topic agent] [-thread 线程] [-choice 选项]... [-ask] 标题
  huijian agent ask    [-timeout 30m] [-choice 选项]... [-d 正文] 问题   发出并等回复，回复打印到标准输出
  huijian agent replies [-wait 60]                   取回复（每行一条 JSON），自动发送回执
  huijian agent status                               查看当前会话
  huijian agent logout                               结束会话
通用选项：-s 槽位（默认 HUIJIAN_AGENT_SESSION 或 default，多个 agent 同时用时区分）
登录需要 -u 地址（或 HUIJIAN_URL）和 -k Agent key（或 HUIJIAN_AGENT_KEY，在回笺「设置 → Agent」里新建）。
退出码：0 成功，1 失败，3 等回复超时。
`)
}

func defaultSlot() string { return env("HUIJIAN_AGENT_SESSION", "default") }

func agentLoginCmd(args []string) error {
	fs := flag.NewFlagSet("agent login", flag.ContinueOnError)
	server := fs.String("u", defaultURLs(), "服务器地址")
	key := fs.String("k", env("HUIJIAN_AGENT_KEY", ""), "Agent key（AK_…）")
	host, _ := os.Hostname()
	name := fs.String("name", env("HUIJIAN_AGENT_NAME", strings.TrimSuffix(host, ".local")+" agent"), "在回笺里显示的名字")
	slot := fs.String("s", defaultSlot(), "会话槽位")
	wait := fs.Duration("timeout", 10*time.Minute, "最多等多久批准")
	if err := fs.Parse(args); err != nil {
		return err
	}
	srv := strings.TrimRight(strings.Split(*server, ",")[0], "/")
	if srv == "" {
		return errors.New("缺少服务器地址：用 -u 或环境变量 HUIJIAN_URL")
	}
	if !strings.HasPrefix(*key, "AK_") {
		return errors.New("缺少 Agent key：用 -k 或环境变量 HUIJIAN_AGENT_KEY（在回笺「设置 → Agent」里新建）")
	}
	dir, err := agentDir(*slot)
	if err != nil {
		return err
	}
	info, err := agentReq("GET", srv, "/v1/agent/info", *key, nil, 20*time.Second)
	if err != nil {
		return err
	}
	acct, _ := info["account_pub"].(string)
	acctRaw, err := b64.DecodeString(acct)
	if err != nil || len(acctRaw) != 32 {
		return errors.New("服务器返回的账号公钥格式不对")
	}
	// 以前登录过：钉住的账号公钥必须一致（不一致说明账号重置过加密，或者有人冒充服务器）
	if old, err := loadAgentState(*slot); err == nil && old.Server == srv && old.AccountPub != "" && old.AccountPub != acct {
		fmt.Fprintln(os.Stderr, "注意：账号的加密公钥和上次登录时不同（可能在设备上重置过加密）。这次登录的核对码会核对新公钥。")
	}
	sk, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	nb := randBytes(32)
	pub := sk.PublicKey().Bytes()
	out, err := agentReq("POST", srv, "/v1/agent/sessions", *key,
		map[string]any{"name": *name, "pub": b64.EncodeToString(pub), "commit": b64.EncodeToString(agentCommit(pub, acctRaw, nb))}, 20*time.Second)
	if err != nil {
		return err
	}
	sid, _ := out["session_id"].(string)
	fmt.Fprintf(os.Stderr, "已发起登录「%s」：在回笺（设置 → Agent）里会看到这个请求。\n", *name)
	deadline := time.Now().Add(*wait)
	revealed := ""
	for time.Now().Before(deadline) {
		st, err := agentReq("GET", srv, "/v1/agent/sessions/"+sid, *key, nil, 20*time.Second)
		if err != nil {
			var he *agentHTTPError
			if errors.As(err, &he) && he.Status < 500 && he.Status != 429 {
				return err
			}
			time.Sleep(3 * time.Second)
			continue
		}
		switch st["state"] {
		case agentDenied:
			return errors.New("设备拒绝了这次登录")
		case agentExpired, agentEnded:
			return errors.New("登录请求已经作废，请重新执行 huijian agent login")
		case agentApproved:
			tok, _ := st["token"].(string)
			if tok == "" {
				return errors.New("登录已批准，但没有拿到会话令牌（可能被别的进程取走了），请重新登录")
			}
			if revealed == "" {
				return errors.New("没核对核对码就被批准了，不安全，已放弃：请重新登录")
			}
			s := &agentState{Server: srv, Name: *name, SessionID: sid, SK: b64.EncodeToString(sk.Bytes()), Token: tok, AccountPub: acct,
				Seen: map[string]int64{}, path: filepath.Join(dir, "session.json")}
			if err := s.save(); err != nil {
				return fmt.Errorf("保存会话失败：%v", err)
			}
			fmt.Fprintf(os.Stderr, "✅ 登录成功：「%s」（会话 %s，槽位 %s）\n", *name, sid, *slot)
			return nil
		}
		if ch, _ := st["challenge"].(string); ch != "" && ch != revealed {
			na, err := b64.DecodeString(ch)
			if err != nil || len(na) != 32 {
				return errors.New("服务器返回的随机数格式不对")
			}
			if revealed != "" {
				fmt.Fprintln(os.Stderr, "批准设备重新开始了，核对码已更新：")
			}
			// 先算出核对码，再揭晓 nb（顺序同设备批准：服务器在看到 nb 之前就得定下 na）
			code := agentSAS(pub, acctRaw, na, nb)
			if _, err := agentReq("POST", srv, "/v1/agent/sessions/"+sid+"/reveal", *key, map[string]any{"nonce": b64.EncodeToString(nb)}, 20*time.Second); err != nil {
				var he *agentHTTPError
				if !(errors.As(err, &he) && he.Status == 409) {
					return err
				}
			}
			revealed = ch
			fmt.Fprintf(os.Stderr, "核对码：%s %s —— 和回笺设备上显示的一致，再在设备上点「一致，批准」。\n", code[:3], code[3:])
		}
		time.Sleep(2 * time.Second)
	}
	return errors.New("等待批准超时")
}

func agentSendCmd(args []string, ask bool) error {
	fs := flag.NewFlagSet("agent send", flag.ContinueOnError)
	prio := fs.Int("p", -1, "优先级 0-5（send 默认 3，ask 默认 4）")
	desp := fs.String("d", "", "正文（回笺 Markdown）")
	topic := fs.String("topic", env("HUIJIAN_TOPIC", "agent"), "频道")
	thread := fs.String("thread", "", "线程")
	slot := fs.String("s", defaultSlot(), "会话槽位")
	askFlag := fs.Bool("ask", ask, "标成「等你回复」")
	timeout := fs.Duration("timeout", 30*time.Minute, "ask：最多等多久回复")
	var choices multiFlag
	fs.Var(&choices, "choice", "快捷回复选项，可多个（最多 4 个，每个最长 20 字）")
	if err := fs.Parse(args); err != nil {
		return err
	}
	title := strings.TrimSpace(strings.Join(fs.Args(), " "))
	if title == "-" {
		b, _ := io.ReadAll(io.LimitReader(os.Stdin, 64<<10))
		title = strings.TrimSpace(string(b))
	}
	if title == "" {
		return errors.New("缺少标题")
	}
	if len(choices) > 4 {
		return errors.New("快捷回复选项最多 4 个")
	}
	for _, c := range choices {
		if n := len([]rune(c)); n == 0 || n > 20 {
			return fmt.Errorf("快捷回复选项每个 1–20 字：%q", c)
		}
	}
	p := *prio
	if p < 0 {
		p = 3
		if *askFlag {
			p = 4
		}
	}
	s, err := loadAgentState(*slot)
	if err != nil {
		return err
	}
	id, err := agentSend(s, agentPayload{V: 1, Kind: "message", Text: title, Desp: *desp, Ask: *askFlag, Choices: choices}, p, *topic, *thread)
	if err != nil {
		return err
	}
	if !ask {
		fmt.Println(id)
		return nil
	}
	fmt.Fprintf(os.Stderr, "已发出（消息 %d），等回复…\n", id)
	got, err := agentWaitReply(s, id, *timeout)
	if err != nil {
		return err
	}
	fmt.Println(got.Text)
	return nil
}

// agentSend：加密并发送一条会话消息，返回消息 id
func agentSend(s *agentState, p agentPayload, prio int, topic, thread string) (int64, error) {
	sk, acct, err := s.keys()
	if err != nil {
		return 0, err
	}
	s.Seq++
	p.Seq, p.SentAt = s.Seq, now()
	b, _ := json.Marshal(p)
	env, err := agentSeal(acct, sk, s.SessionID, b, nil)
	if err != nil {
		return 0, err
	}
	if err := s.save(); err != nil {
		return 0, err
	}
	out, err := agentReq("POST", s.Server, "/v1/agent/push", s.Token, map[string]any{"e2e": env, "priority": prio, "topic": topic,
		"thread": thread, "ask": p.Ask, "idem": fmt.Sprintf("%s-%d", s.SessionID, s.Seq)}, 30*time.Second)
	if err != nil {
		return 0, err
	}
	id, _ := out["id"].(float64)
	return int64(id), nil
}

type agentTimeout struct{ d time.Duration }

func (e *agentTimeout) Error() string { return fmt.Sprintf("等了 %v 没有收到回复", e.d) }

// agentFetch：取一次回复（最多等 wait），解开、核对、去重，并给每条发回执。核对不过的回复丢弃（不发回执）
func agentFetch(s *agentState, wait time.Duration) ([]agentGot, error) {
	sk, acct, err := s.keys()
	if err != nil {
		return nil, err
	}
	out, err := agentReq("GET", s.Server, "/v1/agent/replies?wait="+strconv.Itoa(int(wait.Seconds())), s.Token, nil, wait+30*time.Second)
	if err != nil {
		return nil, err
	}
	raw, _ := out["replies"].([]any)
	var got []agentGot
	var receipts []map[string]any
	for _, x := range raw {
		m, _ := x.(map[string]any)
		rid, _ := m["reply_id"].(float64)
		mid, _ := m["msg_id"].(float64)
		env, _ := m["e2e"].(string)
		r, err := agentReplyOpen(sk, acct, env, int64(mid))
		if err != nil {
			fmt.Fprintf(os.Stderr, "回复 %d 核对失败（不是你的设备发的，或者被改过），已忽略\n", int64(rid))
			continue
		}
		b, _ := json.Marshal(agentPayload{V: 1, Kind: "receipt", ReplyID: int64(rid), N: r.N, ReceivedAt: now()})
		rc, err := agentSeal(acct, sk, s.SessionID, b, nil)
		if err != nil {
			return nil, err
		}
		receipts = append(receipts, map[string]any{"reply_id": int64(rid), "e2e": rc})
		if _, dup := s.Seen[r.N]; dup {
			continue // 重放：回执照发（让服务器不再给），内容不再交出
		}
		s.Seen[r.N] = now()
		got = append(got, agentGot{ReplyID: int64(rid), MsgID: int64(mid), Text: r.Text, SentAt: r.SentAt, Device: r.Device})
	}
	if len(receipts) > 0 {
		if err := s.save(); err != nil {
			return nil, err
		}
		if _, err := agentReq("POST", s.Server, "/v1/agent/replies/ack", s.Token, map[string]any{"receipts": receipts}, 30*time.Second); err != nil {
			return nil, err
		}
	} else if len(raw) > 0 {
		time.Sleep(min(wait, 5*time.Second)) // 只剩核对不过的：别空转
	}
	return got, nil
}

// agentWaitReply：等某条消息的回复；期间收到的别的回复放进 inbox
func agentWaitReply(s *agentState, msgID int64, timeout time.Duration) (agentGot, error) {
	deadline := time.Now().Add(timeout)
	for {
		left := time.Until(deadline)
		if left <= 0 {
			return agentGot{}, &agentTimeout{timeout}
		}
		got, err := agentFetch(s, min(left, agentWaitMax))
		if err != nil {
			var he *agentHTTPError
			if errors.As(err, &he) && (he.Status == 401 || he.Status == 403 || he.Status == 429) {
				return agentGot{}, err
			}
			fmt.Fprintln(os.Stderr, "取回复出错，稍后重试：", err)
			time.Sleep(5 * time.Second)
			continue
		}
		var mine *agentGot
		for i := range got {
			if got[i].MsgID == msgID && mine == nil {
				mine = &got[i]
			} else {
				s.Inbox = append(s.Inbox, got[i])
			}
		}
		if err := s.save(); err != nil {
			return agentGot{}, err
		}
		if mine != nil {
			return *mine, nil
		}
	}
}

func agentRepliesCmd(args []string) error {
	fs := flag.NewFlagSet("agent replies", flag.ContinueOnError)
	wait := fs.Int("wait", 0, "没有回复时最多等几秒（最长 60）")
	slot := fs.String("s", defaultSlot(), "会话槽位")
	if err := fs.Parse(args); err != nil {
		return err
	}
	s, err := loadAgentState(*slot)
	if err != nil {
		return err
	}
	all := s.Inbox
	if len(all) == 0 || *wait > 0 {
		got, err := agentFetch(s, time.Duration(max(0, *wait))*time.Second)
		if err != nil {
			return err
		}
		all = append(all, got...)
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	for _, g := range all {
		enc.Encode(g)
	}
	s.Inbox = nil
	return s.save()
}

func agentStatusCmd(args []string) error {
	fs := flag.NewFlagSet("agent status", flag.ContinueOnError)
	slot := fs.String("s", defaultSlot(), "会话槽位")
	if err := fs.Parse(args); err != nil {
		return err
	}
	s, err := loadAgentState(*slot)
	if err != nil {
		return err
	}
	pb, _ := b64.DecodeString(s.AccountPub)
	fmt.Printf("会话：%s（%s）\n服务器：%s\n账号钥匙：%s\n已发消息：%d 条；待交出的回复：%d 条\n", s.Name, s.SessionID, s.Server, e2eKID(pb), s.Seq, len(s.Inbox))
	return nil
}

func agentLogoutCmd(args []string) error {
	fs := flag.NewFlagSet("agent logout", flag.ContinueOnError)
	slot := fs.String("s", defaultSlot(), "会话槽位")
	if err := fs.Parse(args); err != nil {
		return err
	}
	s, err := loadAgentState(*slot)
	if err != nil {
		return err
	}
	if _, err := agentReq("DELETE", s.Server, "/v1/agent/session", s.Token, nil, 20*time.Second); err != nil {
		var he *agentHTTPError
		if !(errors.As(err, &he) && he.Status == 401) {
			return err
		}
	}
	if err := os.Remove(s.path); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "已结束会话")
	return nil
}
