package main

// agent 双向的接口（docs/agent-mcp.md §11.3）。认证三种：
//   - 设备 token（DT_）：管理 Agent key、批准 / 结束会话、回复、查看回复状态
//   - Agent key（AK_）：取账号公钥、发起登录请求、揭晓随机数、查询批准结果（批准后取走一次会话令牌）
//   - 会话令牌（ST_）：发消息、长轮询取回复、确认收到（附回执）、自己退出

import (
	"database/sql"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

func (h *Hub) registerAgentRoutes(m *http.ServeMux) {
	m.HandleFunc("POST /v1/agent/keys", h.deviceAuth(h.handleAgentKeyCreate))
	m.HandleFunc("POST /v1/agent/connect-codes", h.deviceAuth(h.handleAgentConnectCode)) // 0.11.0：设备生成连接码
	m.HandleFunc("POST /v1/agent/connect", h.handleAgentConnect)                           // 0.11.0：agent 用连接码换 Agent key（不需要登录，限速）
	m.HandleFunc("GET /v1/agent/keys", h.deviceAuth(h.handleAgentKeys))
	m.HandleFunc("DELETE /v1/agent/keys/{id}", h.deviceAuth(h.handleAgentKeyRevoke))
	m.HandleFunc("GET /v1/agent/sessions", h.deviceAuth(h.handleAgentSessions))
	m.HandleFunc("POST /v1/agent/sessions/{id}/challenge", h.deviceAuth(h.handleAgentChallenge))
	m.HandleFunc("POST /v1/agent/sessions/{id}/approve", h.deviceAuth(h.handleAgentApprove))
	m.HandleFunc("POST /v1/agent/sessions/{id}/deny", h.deviceAuth(h.handleAgentDeny))
	m.HandleFunc("DELETE /v1/agent/sessions/{id}", h.deviceAuth(h.handleAgentEnd))
	m.HandleFunc("POST /v1/agent/replies", h.deviceAuth(h.handleAgentReply))
	m.HandleFunc("GET /v1/agent/replies/status", h.deviceAuth(h.handleAgentReplyStatus))

	m.HandleFunc("GET /v1/agent/info", h.agentKeyAuth(h.handleAgentInfo))
	m.HandleFunc("POST /v1/agent/sessions", h.agentKeyAuth(h.handleAgentLogin))
	m.HandleFunc("GET /v1/agent/sessions/{id}", h.agentKeyAuth(h.handleAgentLoginState))
	m.HandleFunc("POST /v1/agent/sessions/{id}/reveal", h.agentKeyAuth(h.handleAgentReveal))

	m.HandleFunc("POST /v1/agent/push", h.sessionAuth(h.handleAgentPush))
	m.HandleFunc("GET /v1/agent/replies", h.sessionAuth(h.handleAgentFetch))
	m.HandleFunc("POST /v1/agent/replies/ack", h.sessionAuth(h.handleAgentAck))
	m.HandleFunc("DELETE /v1/agent/session", h.sessionAuth(h.handleAgentLogout))
}

// ---------- 认证 ----------

func bearer(r *http.Request, prefix string) (string, bool) {
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	return tok, ok && strings.HasPrefix(tok, prefix)
}

func (h *Hub) agentKeyAuth(next func(http.ResponseWriter, *http.Request, *AgentKey)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok, ok := bearer(r, "AK_")
		if !ok {
			apiErr(w, 401, "缺少 Agent key")
			return
		}
		if !h.pushLimit.Allow("ak:" + h.realIP(r)) {
			apiErr(w, 429, "请求太频繁")
			return
		}
		k, err := h.st.AgentKeyByToken(tok)
		if err != nil {
			if !errors.Is(err, sql.ErrNoRows) {
				log.Printf("查询 Agent key 失败：%v", err)
				apiErr(w, 500, "服务器暂时无法验证，请稍后重试")
				return
			}
			apiErr(w, 401, "Agent key 无效或已吊销")
			return
		}
		if h.st.AccountDisabled(k.UserID) {
			apiErr(w, 403, errDisabled.Error())
			return
		}
		next(w, r, k)
	}
}

func (h *Hub) sessionAuth(next func(http.ResponseWriter, *http.Request, *AgentSession)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok, ok := bearer(r, "ST_")
		if !ok {
			apiErr(w, 401, "缺少会话令牌")
			return
		}
		a, err := h.st.AgentSessionByToken(tok)
		if err != nil {
			if !errors.Is(err, sql.ErrNoRows) {
				log.Printf("查询 agent 会话失败：%v", err)
				apiErr(w, 500, "服务器暂时无法验证，请稍后重试")
				return
			}
			apiErr(w, 401, "会话已结束：请重新执行 huijian agent login")
			return
		}
		if h.st.AccountDisabled(a.UserID) {
			apiErr(w, 403, errDisabled.Error())
			return
		}
		next(w, r, a)
	}
}

// ---------- 等回复的长轮询 ----------

type agentWaiters struct {
	mu sync.Mutex
	m  map[string]map[chan struct{}]bool
}

func (b *agentWaiters) sub(sid string) chan struct{} {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.m == nil {
		b.m = map[string]map[chan struct{}]bool{}
	}
	if b.m[sid] == nil {
		b.m[sid] = map[chan struct{}]bool{}
	}
	ch := make(chan struct{}, 1)
	b.m[sid][ch] = true
	return ch
}

func (b *agentWaiters) unsub(sid string, ch chan struct{}) {
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.m[sid], ch)
	if len(b.m[sid]) == 0 {
		delete(b.m, sid)
	}
}

// notifyAll：吊销 key、重置加密、删除账号后叫醒所有长轮询，让它们重新核对令牌（不用等满 60 秒）
func (b *agentWaiters) notifyAll() {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, chs := range b.m {
		for ch := range chs {
			select {
			case ch <- struct{}{}:
			default:
			}
		}
	}
}

func (b *agentWaiters) notify(sid string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for ch := range b.m[sid] {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

// ---------- 设备：Agent key ----------

func (h *Hub) handleAgentKeyCreate(w http.ResponseWriter, r *http.Request, d *Device) {
	k, key, err := h.st.CreateAgentKey(d.UserID)
	if errors.Is(err, errAgentKeyExists) {
		apiErr(w, 409, err.Error())
		return
	}
	if err != nil {
		apiErr(w, 500, "新建失败")
		return
	}
	writeJSON(w, 200, map[string]any{"id": k.ID, "key": key, "prefix": k.Prefix, "created_at": unixRFC(k.Created)})
}

// handleAgentConnectCode：已登录的设备生成连接码。账号还没有加密钥匙时 agent 登录不了，先拦下
func (h *Hub) handleAgentConnectCode(w http.ResponseWriter, r *http.Request, d *Device) {
	pub, err := h.st.E2EActivePub(d.UserID)
	if err != nil {
		apiErr(w, 500, "读取失败")
		return
	}
	if pub == nil {
		apiErr(w, 409, "这个账号还没有加密钥匙：请先在本机解锁加密")
		return
	}
	code, exp, err := h.st.CreateAgentConnectCode(d.UserID, d.ID)
	if errors.Is(err, errAgentKeyExists) {
		apiErr(w, 409, err.Error())
		return
	}
	if err != nil {
		apiErr(w, 500, "生成失败")
		return
	}
	writeJSON(w, 200, map[string]any{"code": code, "expires_at": unixRFC(exp), "expires_in": agentConnectTTL})
}

// handleAgentConnect：agent 用连接码换一把自己的 Agent key。按 IP 限速（和配对码同一个限速器），失败统一 403 并延迟
func (h *Hub) handleAgentConnect(w http.ResponseWriter, r *http.Request) {
	if !h.pairLimit.Allow("ip:" + h.realIP(r)) {
		apiErr(w, 429, "尝试太频繁")
		return
	}
	var in struct{ Code, Name string }
	if !readJSON(w, r, &in) {
		return
	}
	name := cleanLabel(in.Name, 64)
	if name == "" {
		name = "agent"
	}
	k, key, err := h.st.RedeemAgentConnectCode(in.Code, name)
	switch {
	case errors.Is(err, errAgentKeyExists):
		apiErr(w, 409, err.Error())
		return
	case errors.Is(err, errDisabled):
		time.Sleep(500 * time.Millisecond)
		apiErr(w, 403, "账号已停用")
		return
	case err != nil:
		if !errors.Is(err, errAgentConnect) {
			log.Printf("兑换连接码失败：%v", err)
		}
		time.Sleep(500 * time.Millisecond)
		apiErr(w, 403, errAgentConnect.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"id": k.ID, "key": key, "prefix": k.Prefix, "name": k.Name})
}

func (h *Hub) handleAgentKeys(w http.ResponseWriter, r *http.Request, d *Device) {
	ks, err := h.st.AgentKeys(d.UserID)
	if err != nil {
		apiErr(w, 500, "读取失败")
		return
	}
	out := []map[string]any{}
	for _, k := range ks {
		out = append(out, map[string]any{"id": k.ID, "prefix": k.Prefix, "name": k.Name, "created_at": unixRFC(k.Created), "last_used": unixRFC(k.LastUsed)})
	}
	writeJSON(w, 200, map[string]any{"keys": out})
}

func (h *Hub) handleAgentKeyRevoke(w http.ResponseWriter, r *http.Request, d *Device) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	ok, err := h.st.RevokeAgentKey(d.UserID, id)
	if err != nil {
		apiErr(w, 500, "吊销失败")
		return
	}
	if !ok {
		apiErr(w, 404, "Agent key 不存在")
		return
	}
	h.agentWait.notifyAll()
	writeJSON(w, 200, map[string]any{"ok": true})
}

// ---------- 设备：会话 ----------

func unixRFC(t int64) any {
	if t <= 0 {
		return nil
	}
	return time.Unix(t, 0).UTC().Format(time.RFC3339)
}

func (h *Hub) agentSessionJSON(a AgentSession) map[string]any {
	online := a.State == agentApproved && now()-a.LastSeen <= agentOnlineWindow
	return map[string]any{"id": a.ID, "name": a.Name, "pub": a.Pub, "state": a.State, "commit": a.Commit,
		"challenge": a.NA, "reveal": a.NB, "attest": a.Attest, "created_at": unixRFC(a.CreatedAt),
		"approved_at": unixRFC(a.ApprovedAt), "ended_at": unixRFC(a.EndedAt), "last_seen": unixRFC(a.LastSeen), "online": online}
}

func (h *Hub) handleAgentSessions(w http.ResponseWriter, r *http.Request, d *Device) {
	ss, err := h.st.AgentSessions(d.UserID)
	if err != nil {
		apiErr(w, 500, "读取失败")
		return
	}
	out := []map[string]any{}
	for _, a := range ss {
		out = append(out, h.agentSessionJSON(a))
	}
	writeJSON(w, 200, map[string]any{"sessions": out})
}

// agentStepErr：会话状态类错误 → HTTP 状态
func agentStepErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, sql.ErrNoRows):
		apiErr(w, 404, "agent 会话不存在")
	case errors.Is(err, errAgentTaken), errors.Is(err, errAgentState), errors.Is(err, errAgentRestart):
		apiErr(w, 409, err.Error())
	default:
		apiErr(w, 500, "操作失败")
	}
}

// validB64Key：32 字节的 base64url（随机数、公钥、承诺）
func validB64Key(s string) bool {
	b, err := b64.DecodeString(s)
	return err == nil && len(b) == 32
}

func (h *Hub) handleAgentChallenge(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct{ Nonce string }
	if !readJSON(w, r, &in) {
		return
	}
	if !validB64Key(in.Nonce) {
		apiErr(w, 400, "nonce 应为 32 字节 base64url")
		return
	}
	if err := h.st.AgentChallenge(d.UserID, r.PathValue("id"), d.ID, in.Nonce); err != nil {
		agentStepErr(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (h *Hub) handleAgentApprove(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct{ Attest string }
	if !readJSON(w, r, &in) {
		return
	}
	if raw, ok := strings.CutPrefix(in.Attest, agentAttestPfx+"."); !ok || len(in.Attest) > 2048 || !validB64(raw) {
		apiErr(w, 400, "attest 格式不对")
		return
	}
	if err := h.st.AgentApprove(d.UserID, r.PathValue("id"), d.ID, in.Attest); err != nil {
		agentStepErr(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}

func validB64(s string) bool {
	_, err := b64.DecodeString(s)
	return err == nil && s != ""
}

func (h *Hub) handleAgentDeny(w http.ResponseWriter, r *http.Request, d *Device) {
	if err := h.st.AgentDeny(d.UserID, r.PathValue("id")); err != nil {
		agentStepErr(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (h *Hub) handleAgentEnd(w http.ResponseWriter, r *http.Request, d *Device) {
	id := r.PathValue("id")
	if _, err := h.st.EndAgentSession(d.UserID, id); err != nil {
		agentStepErr(w, err)
		return
	}
	h.agentWait.notify(id) // 正在长轮询的 agent 马上返回，下一次请求就是 401
	writeJSON(w, 200, map[string]any{"ok": true})
}

// ---------- 设备：回复 ----------

func (h *Hub) handleAgentReply(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct {
		MsgID int64 `json:"msg_id"`
		E2E   string
		Copy  string
	}
	r.Body = http.MaxBytesReader(w, r.Body, 3*agentReplyMaxBytes)
	if !readJSON(w, r, &in) {
		return
	}
	if !h.pushLimit.Allow("ar:" + d.ID) {
		apiErr(w, 429, "回复太频繁，请稍后再试")
		return
	}
	sid, err := h.st.AgentMessageSession(d.UserID, in.MsgID)
	if err != nil {
		apiErr(w, 404, "消息不存在")
		return
	}
	if sid == "" {
		apiErr(w, 400, "这条消息不是 agent 发来的，不能回复")
		return
	}
	if got, ok := agentReplySession(in.E2E); !ok || got != sid || len(in.E2E) > agentReplyMaxBytes {
		apiErr(w, 400, "e2e 格式不对（应为发给这个会话的 hjq1 信封）")
		return
	}
	if !strings.HasPrefix(in.Copy, e2eMsgPrefix) || len(in.Copy) > agentReplyMaxBytes {
		apiErr(w, 400, "copy 格式不对（应为 hje1 信封）")
		return
	}
	id, err := h.st.InsertAgentReply(d.UserID, sid, in.MsgID, in.E2E, in.Copy, d.Name)
	if errors.Is(err, errAgentEnded) {
		apiErr(w, 409, err.Error())
		return
	}
	if err != nil {
		apiErr(w, 500, "保存失败")
		return
	}
	h.agentWait.notify(sid)
	writeJSON(w, 200, map[string]any{"reply_id": id})
}

func (h *Hub) handleAgentReplyStatus(w http.ResponseWriter, r *http.Request, d *Device) {
	msgID, _ := strconv.ParseInt(r.URL.Query().Get("msg_id"), 10, 64)
	rs, err := h.st.AgentRepliesFor(d.UserID, msgID)
	if err != nil {
		apiErr(w, 500, "读取失败")
		return
	}
	out := []map[string]any{}
	for _, x := range rs {
		out = append(out, map[string]any{"reply_id": x.ID, "session_id": x.SessionID, "state": x.State, "created_at": unixRFC(x.CreatedAt),
			"received_at": unixRFC(x.ReceivedAt), "copy": x.Copy, "receipt": x.Receipt, "device": x.Device})
	}
	writeJSON(w, 200, map[string]any{"replies": out})
}

// ---------- Agent key：登录 ----------

func (h *Hub) handleAgentInfo(w http.ResponseWriter, r *http.Request, k *AgentKey) {
	pub, err := h.st.E2EActivePub(k.UserID)
	if err != nil {
		apiErr(w, 500, "读取失败")
		return
	}
	if pub == nil {
		apiErr(w, 409, "这个账号还没有加密钥匙：请先在任一设备上用密码登录回笺")
		return
	}
	writeJSON(w, 200, map[string]any{"account_pub": b64.EncodeToString(pub.Bytes()), "kid": e2eKID(pub.Bytes()),
		"limits": map[string]any{"online_sessions": agentOnlineMax, "pending_requests": agentPendingMax,
			"reply_keep_seconds": agentReplyKeep, "reply_max_bytes": 16 << 10, "wait_max_seconds": int(agentWaitMax.Seconds())}})
}

func (h *Hub) handleAgentLogin(w http.ResponseWriter, r *http.Request, k *AgentKey) {
	var in struct{ Name, Pub, Commit string }
	if !readJSON(w, r, &in) {
		return
	}
	in.Name = cleanLabel(in.Name, 64)
	if in.Name == "" {
		in.Name = "agent"
	}
	if !validB64Key(in.Pub) || !validB64Key(in.Commit) {
		apiErr(w, 400, "pub、commit 应为 32 字节 base64url")
		return
	}
	id, err := h.st.CreateAgentSession(k, in.Name, in.Pub, in.Commit)
	if errors.Is(err, errAgentPending) {
		apiErr(w, 429, err.Error())
		return
	}
	if err != nil {
		apiErr(w, 500, "创建失败")
		return
	}
	writeJSON(w, 200, map[string]any{"session_id": id})
}

func (h *Hub) handleAgentLoginState(w http.ResponseWriter, r *http.Request, k *AgentKey) {
	a, err := h.st.AgentSession(k.UserID, r.PathValue("id"))
	if err != nil || a.KeyID != k.ID {
		apiErr(w, 404, "登录请求不存在")
		return
	}
	out := map[string]any{"state": a.State, "challenge": a.NA}
	if a.State == agentApproved {
		if tok := h.st.AgentTakeToken(a.ID); tok != "" {
			out["token"] = tok
		}
	}
	writeJSON(w, 200, out)
}

func (h *Hub) handleAgentReveal(w http.ResponseWriter, r *http.Request, k *AgentKey) {
	var in struct{ Nonce string }
	if !readJSON(w, r, &in) {
		return
	}
	if !validB64Key(in.Nonce) {
		apiErr(w, 400, "nonce 应为 32 字节 base64url")
		return
	}
	if err := h.st.AgentReveal(k, r.PathValue("id"), in.Nonce); err != nil {
		agentStepErr(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}

// ---------- 会话令牌：发消息、取回复 ----------

func (h *Hub) handleAgentPush(w http.ResponseWriter, r *http.Request, a *AgentSession) {
	var in struct {
		E2E      string
		Priority *int
		Topic    string
		Thread   string
		Ask      bool
		Idem     string
	}
	r.Body = http.MaxBytesReader(w, r.Body, 256<<10)
	if !readJSON(w, r, &in) {
		return
	}
	if !h.pushLimit.Allow("as:" + a.ID) {
		apiErr(w, 429, "发送太频繁，请稍后再试")
		return
	}
	kid, sid, ok := agentEnvelopeParts(in.E2E)
	if !ok || sid != a.ID {
		apiErr(w, 400, "e2e 格式不对（应为这个会话的 hje2 信封）")
		return
	}
	pub, err := h.st.E2EActivePub(a.UserID)
	if err != nil {
		apiErr(w, 503, "服务器暂时无法处理，请稍后重试")
		return
	}
	if pub == nil || e2eKID(pub.Bytes()) != kid {
		apiErr(w, 409, "账号的加密钥匙已经更换：请重新执行 huijian agent login")
		return
	}
	prio := 3
	if in.Priority != nil {
		if *in.Priority < 0 || *in.Priority > 5 {
			apiErr(w, 400, "priority 取值 0-5")
			return
		}
		prio = *in.Priority
	}
	topic := strings.TrimSpace(in.Topic)
	if topic == "" {
		topic = "agent"
	}
	thread, idem := strings.TrimSpace(in.Thread), strings.TrimSpace(in.Idem)
	if len(topic) > 64 || len(thread) > 128 || len(idem) > 64 {
		apiErr(w, 400, "topic 最长 64 字节，thread 最长 128 字节，idem 最长 64 字节")
		return
	}
	text := "🔒 来自 agent 的消息"
	if in.Ask {
		text = "🔒 agent 在等你回复"
	}
	id, dup, err := h.st.InsertMessage(NewMessage{UserID: a.UserID, Topic: topic, Thread: thread, Priority: prio, Type: "e2e",
		Text: text, Source: a.Name, SrcIP: h.realIP(r), Idem: idem, E2E: in.E2E, AgentSession: a.ID, Ask: in.Ask})
	if errors.Is(err, errAccountGone) {
		apiErr(w, 403, err.Error())
		return
	}
	if errors.Is(err, errIdemConflict) {
		apiErr(w, 409, err.Error())
		return
	}
	if err != nil {
		log.Printf("写入 agent 消息失败: %v", err)
		apiErr(w, 500, "写入消息失败")
		return
	}
	if !dup {
		h.br.Notify(a.UserID)
		go h.forwardBark(a.UserID, id, nil)
	}
	writeJSON(w, 200, map[string]any{"id": id})
}

func (h *Hub) handleAgentFetch(w http.ResponseWriter, r *http.Request, a *AgentSession) {
	if h.st.AgentOnlineOthers(a.UserID, a.ID) >= agentOnlineMax {
		apiErr(w, 429, "同时在线的 agent 会话已达上限（内测 3 个）：请在回笺设备上结束不用的会话")
		return
	}
	wait := 0 * time.Second
	if s := r.URL.Query().Get("wait"); s != "" {
		v, err := strconv.Atoi(s)
		if err != nil || v < 0 {
			apiErr(w, 400, "wait 应为秒数")
			return
		}
		wait = min(time.Duration(v)*time.Second, agentWaitMax)
	}
	h.st.TouchAgentSession(a.ID)
	ch := h.agentWait.sub(a.ID)
	defer h.agentWait.unsub(a.ID, ch)
	deadline := time.NewTimer(wait)
	defer deadline.Stop()
	for {
		rs, err := h.st.PendingAgentReplies(a.ID)
		if err != nil {
			apiErr(w, 500, "读取失败")
			return
		}
		if len(rs) > 0 || wait == 0 {
			out := []map[string]any{}
			for _, x := range rs {
				out = append(out, map[string]any{"reply_id": x.ID, "msg_id": x.MsgID, "e2e": x.E2E, "created_at": unixRFC(x.CreatedAt)})
			}
			h.st.TouchAgentSession(a.ID)
			writeJSON(w, 200, map[string]any{"replies": out})
			return
		}
		select {
		case <-ch:
			// 会话被结束：令牌已作废，返回 401
			if _, err := h.st.AgentSessionByToken(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")); err != nil {
				apiErr(w, 401, "会话已结束：请重新执行 huijian agent login")
				return
			}
		case <-deadline.C:
			wait = 0
		case <-r.Context().Done():
			return
		}
	}
}

func (h *Hub) handleAgentAck(w http.ResponseWriter, r *http.Request, a *AgentSession) {
	var in struct {
		Receipts []struct {
			ReplyID int64 `json:"reply_id"`
			E2E     string
		}
	}
	r.Body = http.MaxBytesReader(w, r.Body, 256<<10)
	if !readJSON(w, r, &in) {
		return
	}
	if len(in.Receipts) == 0 || len(in.Receipts) > 100 {
		apiErr(w, 400, "receipts 应有 1–100 条")
		return
	}
	for _, x := range in.Receipts {
		if _, sid, ok := agentEnvelopeParts(x.E2E); !ok || sid != a.ID || len(x.E2E) > 4096 {
			apiErr(w, 400, "回执格式不对（应为这个会话的 hje2 信封）")
			return
		}
	}
	n := 0
	for _, x := range in.Receipts {
		ok, err := h.st.AckAgentReply(a, x.ReplyID, x.E2E)
		if err != nil {
			apiErr(w, 500, "保存失败")
			return
		}
		if ok {
			n++
		}
	}
	if n > 0 {
		h.st.settingsChanged(a.UserID, changeAgent)
	}
	writeJSON(w, 200, map[string]any{"acked": n})
}

func (h *Hub) handleAgentLogout(w http.ResponseWriter, r *http.Request, a *AgentSession) {
	if _, err := h.st.EndAgentSession(a.UserID, a.ID); err != nil {
		apiErr(w, 500, "操作失败")
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}
