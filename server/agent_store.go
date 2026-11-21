package main

// agent 双向（docs/agent-mcp.md）的存储：Agent key、会话（登录请求 → 批准 → 令牌）、回复。
// 服务器只存密文和路由信息：会话公钥、承诺和随机数（核对码用）、会话证明 hja1、回复密文 hjq1、回复副本 hje1、回执 hje2。

import (
	"database/sql"
	"errors"
	"strings"
	"time"
)

const agentSchema = `
CREATE TABLE IF NOT EXISTS agent_keys(
  id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, key_hash TEXT NOT NULL UNIQUE, prefix TEXT NOT NULL,
  created_at INTEGER NOT NULL, last_used INTEGER NOT NULL DEFAULT 0, revoked INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS idx_agent_keys_user ON agent_keys(user_id);
CREATE TABLE IF NOT EXISTS agent_sessions(
  id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, key_id INTEGER NOT NULL, name TEXT NOT NULL, pub TEXT NOT NULL,
  cmt TEXT NOT NULL, na TEXT NOT NULL DEFAULT '', na_device TEXT NOT NULL DEFAULT '', nb TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL, attest TEXT NOT NULL DEFAULT '', token_hash TEXT NOT NULL DEFAULT '', token_once TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL, approved_at INTEGER NOT NULL DEFAULT 0, ended_at INTEGER NOT NULL DEFAULT 0, last_seen INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS idx_agent_sess_user ON agent_sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_agent_sess_token ON agent_sessions(token_hash) WHERE token_hash != '';
CREATE TABLE IF NOT EXISTS agent_replies(
  id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, session_id TEXT NOT NULL, msg_id INTEGER NOT NULL,
  e2e TEXT NOT NULL, copy TEXT NOT NULL, device TEXT NOT NULL DEFAULT '', state TEXT NOT NULL,
  receipt TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL, received_at INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS idx_agent_reply_sess ON agent_replies(session_id, state);
CREATE INDEX IF NOT EXISTS idx_agent_reply_msg ON agent_replies(user_id, msg_id);
CREATE TABLE IF NOT EXISTS agent_connect_codes(
  code_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL, created_by TEXT NOT NULL DEFAULT '', expires_at INTEGER NOT NULL,
  used INTEGER NOT NULL DEFAULT 0, used_by TEXT NOT NULL DEFAULT '', used_at INTEGER NOT NULL DEFAULT 0);
`

// 内测额度（docs/agent-mcp.md §3）
const (
	agentKeysPerAccount = 10               // 0.11.0 起每台 agent 电脑一把（连接码兑换时新建），可单独吊销
	agentConnectTTL     = 10 * 60          // 秒：连接码有效期
	agentOnlineMax      = 3                // 同时在线的会话
	agentPendingMax     = 3                // 等待批准的登录请求
	agentPendingTTL     = 10 * 60          // 秒：没批准的登录请求自动作废
	agentReplyKeep      = 3 * 24 * 3600    // 秒：回复密文在服务器保留多久（取走后立即删）
	agentHistoryKeep    = 30 * 24 * 3600   // 秒：回复副本、回执、已结束的会话记录保留多久
	agentOnlineWindow   = 90               // 秒：这么久内长轮询过算在线
	agentReplyMaxBytes  = 32 << 10         // 回复信封（16 KB 文字加密后）
	agentWaitMax        = 60 * time.Second // 长轮询最长等待
)

// 会话状态
const (
	agentPending  = "pending"
	agentApproved = "approved"
	agentDenied   = "denied"
	agentExpired  = "expired"
	agentEnded    = "ended"
)

// 回复状态
const (
	replySent     = "sent"
	replyReceived = "received"
	replyExpired  = "expired"
)

const changeAgent = "agent" // 0.10.0：agent 会话请求、批准、结束、回复、回执（id 0），客户端重新拉取

var (
	errAgentKeyExists = errors.New("每个账号最多 10 把 Agent key，请先在「设置 → Pushkey」里吊销不用的")
	errAgentConnect   = errors.New("连接码无效或已过期：请在回笺「设置 → Pushkey」里重新生成")
	errAgentPending   = errors.New("等待批准的 agent 登录请求太多，请先在设备上处理")
	errAgentState     = errors.New("这个 agent 会话的状态已经变了，请刷新")
	errAgentTaken     = errors.New("这个请求已经由另一台设备处理")
	errAgentRestart   = errors.New("批准中途重新开始了：为了安全，这次登录请求已作废，请让 agent 重新登录")
)

type AgentKey struct {
	ID       int64
	UserID   int64
	Prefix   string
	Name     string // 连接码兑换时 agent 报的名字（手动新建的为空）
	Created  int64
	LastUsed int64
}

type AgentSession struct {
	ID         string
	UserID     int64
	KeyID      int64
	Name       string
	Pub        string
	Commit     string
	NA         string
	NADevice   string
	NB         string
	State      string
	Attest     string
	TokenOnce  string
	CreatedAt  int64
	ApprovedAt int64
	EndedAt    int64
	LastSeen   int64
}

func (s *Store) migrateAgent() error {
	if _, err := s.db.Exec(agentSchema); err != nil {
		return err
	}
	for _, m := range [][3]string{
		{"messages", "agent_session", "TEXT NOT NULL DEFAULT ''"},
		{"messages", "ask", "INTEGER NOT NULL DEFAULT 0"},
		{"agent_keys", "name", "TEXT NOT NULL DEFAULT ''"},
	} {
		if err := s.addColumn(m[0], m[1], m[2]); err != nil {
			return err
		}
	}
	return nil
}

// ---------- Agent key ----------

func (s *Store) CreateAgentKey(userID int64) (*AgentKey, string, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, "", err
	}
	defer tx.Rollback()
	k, key, err := insertAgentKey(tx, userID, "")
	if err != nil {
		return nil, "", err
	}
	if err := tx.Commit(); err != nil {
		return nil, "", err
	}
	s.settingsChanged(userID, changeAgent)
	return k, key, nil
}

// insertAgentKey：在事务里新建一把 key（检查额度）
func insertAgentKey(tx *sql.Tx, userID int64, name string) (*AgentKey, string, error) {
	var n int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM agent_keys WHERE user_id=? AND revoked=0`, userID).Scan(&n); err != nil {
		return nil, "", err
	}
	if n >= agentKeysPerAccount {
		return nil, "", errAgentKeyExists
	}
	key := "AK_" + randHex(16)
	k := &AgentKey{UserID: userID, Prefix: key[:7], Name: name, Created: now()}
	res, err := tx.Exec(`INSERT INTO agent_keys(user_id,key_hash,prefix,name,created_at) VALUES(?,?,?,?,?)`, userID, sha256Hex(key), k.Prefix, name, k.Created)
	if err != nil {
		return nil, "", err
	}
	k.ID, _ = res.LastInsertId()
	return k, key, nil
}

// ---------- 连接码（0.11.0，docs/agent-mcp.md §4.0） ----------
// 设备生成 8 位一次性连接码（XXXX-XXXX，Crockford Base32，40 位随机），agent 用它换一把自己的 Agent key，
// 然后照常登录（设备核对 6 位核对码后批准）。服务器只存连接码的哈希。

// normalizeAgentCode：大写、去掉分隔符，O→0、I/L→1；不是 8 位 Crockford 字符返回空
func normalizeAgentCode(s string) string {
	var b []byte
	for _, c := range strings.ToUpper(s) {
		switch c {
		case '-', ' ', '\t':
			continue
		case 'O':
			c = '0'
		case 'I', 'L':
			c = '1'
		}
		if c > 127 || strings.IndexByte(crockford, byte(c)) < 0 {
			return ""
		}
		b = append(b, byte(c))
	}
	if len(b) != 8 {
		return ""
	}
	return string(b)
}

// CreateAgentConnectCode：同一台设备重新生成时，它之前没用掉的连接码立即作废。账号 key 已满时直接报错（免得兑换时才失败）
func (s *Store) CreateAgentConnectCode(userID int64, deviceID string) (string, int64, error) {
	s.db.Exec(`DELETE FROM agent_connect_codes WHERE expires_at < ?`, now()-3600)
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM agent_keys WHERE user_id=? AND revoked=0`, userID).Scan(&n); err != nil {
		return "", 0, err
	}
	if n >= agentKeysPerAccount {
		return "", 0, errAgentKeyExists
	}
	s.db.Exec(`UPDATE agent_connect_codes SET expires_at=? WHERE user_id=? AND created_by=? AND used=0 AND expires_at>=?`, now()-1, userID, deviceID, now())
	exp := now() + agentConnectTTL
	for i := 0; i < 5; i++ {
		raw := randBytes(5)
		var code []byte
		acc := uint64(raw[0])<<32 | uint64(raw[1])<<24 | uint64(raw[2])<<16 | uint64(raw[3])<<8 | uint64(raw[4])
		for j := 7; j >= 0; j-- {
			code = append(code, crockford[(acc>>(uint(j)*5))&31])
		}
		c := string(code)
		if _, err := s.db.Exec(`INSERT INTO agent_connect_codes(code_hash,user_id,created_by,expires_at) VALUES(?,?,?,?)`, sha256Hex(c), userID, deviceID, exp); err == nil {
			return c[:4] + "-" + c[4:], exp, nil
		}
	}
	return "", 0, errors.New("生成连接码失败")
}

// RedeemAgentConnectCode：消费连接码，给 agent 新建一把带名字的 Agent key（明文只返回这一次）
func (s *Store) RedeemAgentConnectCode(code, name string) (*AgentKey, string, error) {
	c := normalizeAgentCode(code)
	if c == "" {
		return nil, "", errAgentConnect
	}
	tx, err := s.db.Begin()
	if err != nil {
		return nil, "", err
	}
	defer tx.Rollback()
	var userID int64
	if err := tx.QueryRow(`SELECT user_id FROM agent_connect_codes WHERE code_hash=? AND used=0 AND expires_at>=?`, sha256Hex(c), now()).Scan(&userID); err != nil {
		return nil, "", errAgentConnect
	}
	// 账号已删除（用户 id 可能被新账号复用）或停用：一律当作无效码，不区分（免得借此确认码是否有效）
	var dis int
	if err := tx.QueryRow(`SELECT disabled FROM users WHERE id=?`, userID).Scan(&dis); err != nil || dis != 0 {
		return nil, "", errAgentConnect
	}
	res, err := tx.Exec(`UPDATE agent_connect_codes SET used=1, used_by=?, used_at=? WHERE code_hash=? AND used=0`, name, now(), sha256Hex(c))
	if err != nil {
		return nil, "", err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return nil, "", errAgentConnect
	}
	k, key, err := insertAgentKey(tx, userID, name)
	if err != nil {
		return nil, "", err
	}
	if err := tx.Commit(); err != nil {
		return nil, "", err
	}
	s.settingsChanged(userID, changeAgent)
	return k, key, nil
}

func (s *Store) AgentKeys(userID int64) ([]AgentKey, error) {
	rows, err := s.db.Query(`SELECT id,user_id,prefix,name,created_at,last_used FROM agent_keys WHERE user_id=? AND revoked=0 ORDER BY id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AgentKey{}
	for rows.Next() {
		var k AgentKey
		if err := rows.Scan(&k.ID, &k.UserID, &k.Prefix, &k.Name, &k.Created, &k.LastUsed); err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

func (s *Store) AgentKeyByToken(key string) (*AgentKey, error) {
	var k AgentKey
	err := s.db.QueryRow(`SELECT id,user_id,prefix,name,created_at,last_used FROM agent_keys WHERE key_hash=? AND revoked=0`, sha256Hex(key)).
		Scan(&k.ID, &k.UserID, &k.Prefix, &k.Name, &k.Created, &k.LastUsed)
	if err != nil {
		return nil, err
	}
	if now()-k.LastUsed > 60 {
		s.db.Exec(`UPDATE agent_keys SET last_used=? WHERE id=?`, now(), k.ID)
	}
	return &k, nil
}

// RevokeOwnAgentKey：agent 用自己的 key 吊销自己（huijian agent setup -remove）
func (s *Store) RevokeOwnAgentKey(k *AgentKey) error {
	_, err := s.RevokeAgentKey(k.UserID, k.ID)
	return err
}

// RevokeAgentKey：吊销，它登录的会话全部结束
func (s *Store) RevokeAgentKey(userID, id int64) (bool, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	res, err := tx.Exec(`UPDATE agent_keys SET revoked=1 WHERE id=? AND user_id=? AND revoked=0`, id, userID)
	if err != nil {
		return false, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return false, nil
	}
	if err := endAgentSessions(tx, `user_id=? AND key_id=?`, userID, id); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	s.settingsChanged(userID, changeAgent)
	return true, nil
}

// ---------- 会话 ----------

const agentSessCols = `id,user_id,key_id,name,pub,cmt,na,na_device,nb,state,attest,token_once,created_at,approved_at,ended_at,last_seen`

func scanAgentSession(r interface{ Scan(...any) error }) (*AgentSession, error) {
	var a AgentSession
	if err := r.Scan(&a.ID, &a.UserID, &a.KeyID, &a.Name, &a.Pub, &a.Commit, &a.NA, &a.NADevice, &a.NB, &a.State, &a.Attest,
		&a.TokenOnce, &a.CreatedAt, &a.ApprovedAt, &a.EndedAt, &a.LastSeen); err != nil {
		return nil, err
	}
	return &a, nil
}

// expireAgentPending：超过 10 分钟没批准的登录请求作废
func expireAgentPending(x q, userID int64) {
	x.Exec(`UPDATE agent_sessions SET state=?, ended_at=? WHERE user_id=? AND state=? AND created_at<?`,
		agentExpired, now(), userID, agentPending, now()-agentPendingTTL)
}

func (s *Store) CreateAgentSession(k *AgentKey, name, pub, commit string) (string, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	expireAgentPending(tx, k.UserID)
	var n int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM agent_sessions WHERE user_id=? AND state=?`, k.UserID, agentPending).Scan(&n); err != nil {
		return "", err
	}
	if n >= agentPendingMax {
		return "", errAgentPending
	}
	id := "as" + randHex(8)
	if _, err := tx.Exec(`INSERT INTO agent_sessions(id,user_id,key_id,name,pub,cmt,state,created_at) VALUES(?,?,?,?,?,?,?,?)`,
		id, k.UserID, k.ID, name, pub, commit, agentPending, now()); err != nil {
		return "", err
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	s.settingsChanged(k.UserID, changeAgent)
	return id, nil
}

func (s *Store) AgentSession(userID int64, id string) (*AgentSession, error) {
	expireAgentPending(s.db, userID)
	return scanAgentSession(s.db.QueryRow(`SELECT `+agentSessCols+` FROM agent_sessions WHERE id=? AND user_id=?`, id, userID))
}

// AgentSessions：设备看到的会话列表（不含结束超过 3 天的）
func (s *Store) AgentSessions(userID int64) ([]AgentSession, error) {
	expireAgentPending(s.db, userID)
	rows, err := s.db.Query(`SELECT `+agentSessCols+` FROM agent_sessions WHERE user_id=? AND (ended_at=0 OR ended_at>?) ORDER BY created_at DESC`,
		userID, now()-agentReplyKeep)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AgentSession{}
	for rows.Next() {
		a, err := scanAgentSession(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *a)
	}
	return out, rows.Err()
}

// AgentSessionByToken：会话令牌 → 已批准的会话（Agent key 已吊销、会话已结束的都不行）
func (s *Store) AgentSessionByToken(tok string) (*AgentSession, error) {
	return scanAgentSession(s.db.QueryRow(`SELECT `+agentSessCols+` FROM agent_sessions WHERE token_hash=? AND state=?
		AND key_id IN (SELECT id FROM agent_keys WHERE revoked=0)`, sha256Hex(tok), agentApproved))
}

// agentStep：在一个事务里按当前状态改会话（f 返回错误时不改）
func (s *Store) agentStep(userID int64, id string, f func(tx *sql.Tx, a *AgentSession) error) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	expireAgentPending(tx, userID)
	a, err := scanAgentSession(tx.QueryRow(`SELECT `+agentSessCols+` FROM agent_sessions WHERE id=? AND user_id=?`, id, userID))
	if err != nil {
		return err
	}
	if err := f(tx, a); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	s.settingsChanged(userID, changeAgent)
	return nil
}

// AgentChallenge：批准设备出随机数 na（别的设备已经接手时 errAgentTaken）。
// agent 已经揭晓过 nb 之后不能再换 na：否则（被攻破的）服务器知道 nb 后可以挑 na 凑出想要的核对码。
// 同一台设备在揭晓后重新开始 → 这次请求作废（errAgentRestart），agent 重新登录（新钥匙、新 nb）
func (s *Store) AgentChallenge(userID int64, id, deviceID, na string) error {
	restarted := false
	err := s.agentStep(userID, id, func(tx *sql.Tx, a *AgentSession) error {
		if a.State != agentPending {
			return errAgentState
		}
		if a.NADevice != "" && a.NADevice != deviceID {
			return errAgentTaken
		}
		if a.NB != "" {
			restarted = true
			_, err := tx.Exec(`UPDATE agent_sessions SET state=?, ended_at=? WHERE id=?`, agentExpired, now(), id)
			return err
		}
		// 还没揭晓：可以换 na（agent 还没交出 nb，旧的核对码也还没出现）
		_, err := tx.Exec(`UPDATE agent_sessions SET na=?, na_device=? WHERE id=?`, na, deviceID, id)
		return err
	})
	if err == nil && restarted {
		return errAgentRestart
	}
	return err
}

// AgentReveal：agent 揭晓 nb（只能在出了 na 之后、揭晓一次）
func (s *Store) AgentReveal(k *AgentKey, id, nb string) error {
	return s.agentStep(k.UserID, id, func(tx *sql.Tx, a *AgentSession) error {
		if a.KeyID != k.ID || a.State != agentPending || a.NA == "" || a.NB != "" {
			return errAgentState
		}
		_, err := tx.Exec(`UPDATE agent_sessions SET nb=? WHERE id=?`, nb, id)
		return err
	})
}

// AgentApprove：出 na 的那台设备在核对后批准，写入会话证明；生成会话令牌（agent 下次查询时取走一次）
func (s *Store) AgentApprove(userID int64, id, deviceID, attest string) error {
	return s.agentStep(userID, id, func(tx *sql.Tx, a *AgentSession) error {
		if a.State != agentPending || a.NB == "" {
			return errAgentState
		}
		if a.NADevice != deviceID {
			return errAgentTaken
		}
		tok := "ST_" + randHex(16)
		_, err := tx.Exec(`UPDATE agent_sessions SET state=?, attest=?, token_hash=?, token_once=?, approved_at=? WHERE id=?`,
			agentApproved, attest, sha256Hex(tok), tok, now(), id)
		return err
	})
}

func (s *Store) AgentDeny(userID int64, id string) error {
	return s.agentStep(userID, id, func(tx *sql.Tx, a *AgentSession) error {
		if a.State != agentPending {
			return errAgentState
		}
		_, err := tx.Exec(`UPDATE agent_sessions SET state=?, ended_at=?, token_once='' WHERE id=?`, agentDenied, now(), id)
		return err
	})
}

// agentTokenWindow：批准后多久内可以取走令牌（agent 一直不来取，明文令牌不能一直留在数据库里）
const agentTokenWindow = 10 * 60

// AgentTakeToken：agent 第一次查到「已批准」时取走令牌，之后服务器只留哈希。
// 比较后清空（UPDATE … WHERE token_once=?）：两个并发查询只有一个拿得到
func (s *Store) AgentTakeToken(id string) string {
	var tok string
	var at int64
	s.db.QueryRow(`SELECT token_once, approved_at FROM agent_sessions WHERE id=? AND state=?`, id, agentApproved).Scan(&tok, &at)
	if tok == "" {
		return ""
	}
	res, err := s.db.Exec(`UPDATE agent_sessions SET token_once='' WHERE id=? AND token_once=?`, id, tok)
	if err != nil {
		return ""
	}
	if n, _ := res.RowsAffected(); n != 1 || now()-at > agentTokenWindow {
		return ""
	}
	return tok
}

// EndAgentSession：设备结束会话 / agent 自己退出。令牌作废，没取走的回复删掉
func (s *Store) EndAgentSession(userID int64, id string) (bool, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	var st string
	if err := tx.QueryRow(`SELECT state FROM agent_sessions WHERE id=? AND user_id=?`, id, userID).Scan(&st); err != nil {
		return false, err
	}
	if st == agentEnded || st == agentDenied || st == agentExpired {
		return false, nil
	}
	if err := endAgentSessions(tx, `id=? AND user_id=?`, id, userID); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	s.settingsChanged(userID, changeAgent)
	return true, nil
}

// endAgentSessions：把符合条件的会话（等待中的也算）结束，没取走的回复删掉密文、记为过期
func endAgentSessions(x q, where string, args ...any) error {
	if _, err := x.Exec(`UPDATE agent_replies SET state=?, e2e='' WHERE state=? AND session_id IN (SELECT id FROM agent_sessions WHERE `+where+`)`,
		append([]any{replyExpired, replySent}, args...)...); err != nil {
		return err
	}
	_, err := x.Exec(`UPDATE agent_sessions SET state=CASE WHEN state=? THEN ? ELSE ? END, token_hash='', token_once='', ended_at=?
		WHERE (state=? OR state=?) AND `+where, append([]any{agentPending, agentExpired, agentEnded, now(), agentPending, agentApproved}, args...)...)
	return err
}

// EndAllAgentSessions：重置加密后（旧的会话证明用旧钥匙写的，新钥匙验不了）结束这个账号的全部会话
func (s *Store) EndAllAgentSessions(userID int64) {
	if err := endAgentSessions(s.db, `user_id=?`, userID); err != nil {
		return
	}
	s.settingsChanged(userID, changeAgent)
}

func (s *Store) TouchAgentSession(id string) {
	s.db.Exec(`UPDATE agent_sessions SET last_seen=? WHERE id=?`, now(), id)
}

// AgentOnlineOthers：这个账号除 id 以外、90 秒内长轮询过的会话数
func (s *Store) AgentOnlineOthers(userID int64, id string) int {
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM agent_sessions WHERE user_id=? AND state=? AND id!=? AND last_seen>?`,
		userID, agentApproved, id, now()-agentOnlineWindow).Scan(&n)
	return n
}

// ---------- 回复 ----------

type AgentReply struct {
	ID         int64
	SessionID  string
	MsgID      int64
	E2E        string
	Copy       string
	Device     string
	State      string
	Receipt    string
	CreatedAt  int64
	ReceivedAt int64
}

var errAgentEnded = errors.New("这个 agent 会话已经结束，回复送不到了")

// AgentMessageSession：消息是不是 agent 会话发来的（返回会话 id）
func (s *Store) AgentMessageSession(userID, msgID int64) (string, error) {
	var sid string
	err := s.db.QueryRow(`SELECT agent_session FROM messages WHERE id=? AND user_id=?`, msgID, userID).Scan(&sid)
	return sid, err
}

func (s *Store) InsertAgentReply(userID int64, sid string, msgID int64, e2e, copy, device string) (int64, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	var st string
	if err := tx.QueryRow(`SELECT state FROM agent_sessions WHERE id=? AND user_id=?`, sid, userID).Scan(&st); err != nil || st != agentApproved {
		return 0, errAgentEnded
	}
	res, err := tx.Exec(`INSERT INTO agent_replies(user_id,session_id,msg_id,e2e,copy,device,state,created_at) VALUES(?,?,?,?,?,?,?,?)`,
		userID, sid, msgID, e2e, copy, device, replySent, now())
	if err != nil {
		return 0, err
	}
	id, _ := res.LastInsertId()
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	s.settingsChanged(userID, changeAgent)
	return id, nil
}

// ExpireAgent：3 天没取走的回复删掉密文、记为过期；30 天前的记录整条删除；批准后 10 分钟没取走的令牌清掉。
// 由后台每 10 分钟执行一次（backup.go 的 startBackground）
func (s *Store) ExpireAgent() {
	s.db.Exec(`UPDATE agent_replies SET state=?, e2e='' WHERE state=? AND created_at<?`, replyExpired, replySent, now()-agentReplyKeep)
	s.db.Exec(`DELETE FROM agent_replies WHERE created_at<?`, now()-agentHistoryKeep)
	s.db.Exec(`DELETE FROM agent_sessions WHERE ended_at>0 AND ended_at<?`, now()-agentHistoryKeep)
	s.db.Exec(`UPDATE agent_sessions SET token_once='' WHERE token_once!='' AND approved_at<?`, now()-agentTokenWindow)
}

// PendingAgentReplies：会话还没取走的回复
func (s *Store) PendingAgentReplies(sid string) ([]AgentReply, error) {
	rows, err := s.db.Query(`SELECT id,msg_id,e2e,created_at FROM agent_replies WHERE session_id=? AND state=? AND created_at>=? ORDER BY id LIMIT 100`,
		sid, replySent, now()-agentReplyKeep)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AgentReply{}
	for rows.Next() {
		r := AgentReply{SessionID: sid, State: replySent}
		if err := rows.Scan(&r.ID, &r.MsgID, &r.E2E, &r.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// AckAgentReply：agent 取走并解开了回复，附上回执；服务器删掉回复密文。已经确认过的返回 false（重复确认不算错）
func (s *Store) AckAgentReply(a *AgentSession, replyID int64, receipt string) (bool, error) {
	res, err := s.db.Exec(`UPDATE agent_replies SET state=?, e2e='', receipt=?, received_at=? WHERE id=? AND session_id=? AND state=?`,
		replyReceived, receipt, now(), replyID, a.ID, replySent)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// AgentRepliesFor：设备查看某条消息下的回复（副本、状态、回执）
func (s *Store) AgentRepliesFor(userID, msgID int64) ([]AgentReply, error) {
	rows, err := s.db.Query(`SELECT id,session_id,msg_id,copy,device,state,receipt,created_at,received_at FROM agent_replies
		WHERE user_id=? AND msg_id=? ORDER BY id`, userID, msgID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AgentReply{}
	for rows.Next() {
		var r AgentReply
		if err := rows.Scan(&r.ID, &r.SessionID, &r.MsgID, &r.Copy, &r.Device, &r.State, &r.Receipt, &r.CreatedAt, &r.ReceivedAt); err != nil {
			return nil, err
		}
		if r.State == replySent && r.CreatedAt < now()-agentReplyKeep { // 定时清理还没跑到
			r.State = replyExpired
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
