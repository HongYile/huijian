package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

type Store struct {
	db *sql.DB
	// notify：账号的设置（key、设备、账户）变了以后调用，唤醒这个账号在线设备的长轮询；由 Hub 设置
	notify func(userID int64)
	active activeMemo // 今天已记过活跃的账号（stats.go）
}

const schema = `
CREATE TABLE IF NOT EXISTS users(
  id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS pushkeys(
  id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id),
  key TEXT NOT NULL UNIQUE, name TEXT NOT NULL, created_at INTEGER NOT NULL,
  revoked INTEGER NOT NULL DEFAULT 0, last_used INTEGER);
CREATE TABLE IF NOT EXISTS devices(
  id TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id),
  name TEXT NOT NULL, platform TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL, last_seen INTEGER, revoked INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS pair_codes(
  code TEXT PRIMARY KEY, user_id INTEGER NOT NULL, expires_at INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS messages(
  id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, pushkey_id INTEGER,
  topic TEXT NOT NULL, thread TEXT NOT NULL DEFAULT '', priority INTEGER NOT NULL,
  type TEXT NOT NULL, text TEXT NOT NULL, desp TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT '', src_ip TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS idx_msg_user ON messages(user_id, id);
CREATE TABLE IF NOT EXISTS attachments(
  id TEXT PRIMARY KEY, message_id INTEGER NOT NULL REFERENCES messages(id),
  blob TEXT NOT NULL, name TEXT NOT NULL, mime TEXT NOT NULL, size INTEGER NOT NULL, sha256 TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS idx_att_msg ON attachments(message_id);
`

func OpenStore(path string) (*Store, error) {
	dsn := "file:" + path + "?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)&_pragma=synchronous(NORMAL)&_pragma=secure_delete(1)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1) // 个人规模，单连接避免 SQLITE_BUSY
	if _, err := db.Exec(schema); err != nil {
		return nil, fmt.Errorf("初始化数据库: %w", err)
	}
	// 迁移：幂等键（发送端生成，重试/重复补发时用于去重）
	var has int
	db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('messages') WHERE name='idem'`).Scan(&has)
	if has == 0 {
		if _, err := db.Exec(`ALTER TABLE messages ADD COLUMN idem TEXT NOT NULL DEFAULT ''`); err != nil {
			return nil, fmt.Errorf("迁移 idem 列: %w", err)
		}
	}
	if _, err := db.Exec(`CREATE UNIQUE INDEX IF NOT EXISTS idx_msg_idem ON messages(user_id, idem) WHERE idem != ''`); err != nil {
		return nil, err
	}
	st := &Store{db: db}
	for _, m := range [][3]string{
		{"devices", "can_admin", "INTEGER NOT NULL DEFAULT 0"},
		{"pair_codes", "can_admin", "INTEGER NOT NULL DEFAULT 0"},
		{"devices", "client", "TEXT NOT NULL DEFAULT ''"},
		{"pair_codes", "created_by", "TEXT NOT NULL DEFAULT ''"},
		{"pair_codes", "used_by", "TEXT NOT NULL DEFAULT ''"},
		{"pair_codes", "used_at", "INTEGER NOT NULL DEFAULT 0"},
	} {
		if err := st.addColumn(m[0], m[1], m[2]); err != nil {
			return nil, err
		}
	}
	if _, err := db.Exec(`
CREATE TABLE IF NOT EXISTS admin_sessions(
  id_hash TEXT PRIMARY KEY, label TEXT NOT NULL, created_at INTEGER NOT NULL,
  last_seen INTEGER NOT NULL, expires_at INTEGER NOT NULL, sliding INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS admin_links(
  token_hash TEXT PRIMARY KEY, device_id TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS idx_msg_pk ON messages(pushkey_id);
CREATE INDEX IF NOT EXISTS idx_att_sha ON attachments(sha256);` + releaseSchema); err != nil {
		return nil, err
	}
	if err := st.migrateBark(); err != nil {
		return nil, err
	}
	if err := st.migrateChannels(); err != nil {
		return nil, err
	}
	if err := st.migrateMessages(); err != nil {
		return nil, err
	}
	if err := st.migrateAccounts(); err != nil {
		return nil, fmt.Errorf("迁移账号结构: %w", err)
	}
	if err := st.migrateE2E(); err != nil {
		return nil, fmt.Errorf("迁移加密结构: %w", err)
	}
	if err := st.migrateStats(); err != nil {
		return nil, fmt.Errorf("迁移统计: %w", err)
	}
	if err := st.migrateRetired(); err != nil {
		return nil, err
	}
	if err := st.migrateInvites(); err != nil {
		return nil, fmt.Errorf("迁移邀请码: %w", err)
	}
	return st, nil
}

func now() int64 { return time.Now().Unix() }

// EnsureLegacyOwner：0.5.0 以前的数据（消息、pushkey、设备）没有账号，归到第一个账号「me」名下。
// 0.9.0 起全新的数据库不再预建账号：账号只能注册产生，第一个注册的人就是第一个账号（接收系统通知）
func (s *Store) EnsureLegacyOwner() error {
	var users, data int
	s.db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&users)
	if users > 0 {
		return nil
	}
	s.db.QueryRow(`SELECT (SELECT COUNT(*) FROM messages)+(SELECT COUNT(*) FROM pushkeys)+(SELECT COUNT(*) FROM devices)`).Scan(&data)
	if data == 0 {
		return nil
	}
	_, err := s.EnsureUser("me")
	return err
}

// EnsureUser 保证默认用户存在，返回其 id。
func (s *Store) EnsureUser(name string) (int64, error) {
	if _, err := s.db.Exec(`INSERT OR IGNORE INTO users(name, created_at) VALUES(?,?)`, name, now()); err != nil {
		return 0, err
	}
	var id int64
	err := s.db.QueryRow(`SELECT id FROM users WHERE name=?`, name).Scan(&id)
	return id, err
}

// ---------- pushkey ----------

type Pushkey struct {
	ID       int64
	UserID   int64
	Key      string
	Name     string
	Created  int64
	Revoked  bool
	LastUsed sql.NullInt64
}

func (s *Store) CreatePushkey(userID int64, name string) (*Pushkey, error) {
	k := "PK_" + randToken(18)
	res, err := s.db.Exec(`INSERT INTO pushkeys(user_id,key,name,created_at) VALUES(?,?,?,?)`, userID, k, name, now())
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	s.settingsChanged(userID, changeKeys)
	return &Pushkey{ID: id, UserID: userID, Key: k, Name: name, Created: now()}, nil
}

func (s *Store) PushkeyByKey(k string) (*Pushkey, error) {
	p := &Pushkey{}
	var rev int
	err := s.db.QueryRow(`SELECT id,user_id,key,name,created_at,revoked,last_used FROM pushkeys WHERE key=?`, k).
		Scan(&p.ID, &p.UserID, &p.Key, &p.Name, &p.Created, &rev, &p.LastUsed)
	if err != nil {
		return nil, err
	}
	p.Revoked = rev != 0
	return p, nil
}

func (s *Store) ListPushkeys(userID int64) ([]Pushkey, error) {
	rows, err := s.db.Query(`SELECT id,user_id,key,name,created_at,revoked,last_used FROM pushkeys WHERE user_id=? AND deleted=0 ORDER BY revoked, id DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Pushkey
	for rows.Next() {
		var p Pushkey
		var rev int
		if err := rows.Scan(&p.ID, &p.UserID, &p.Key, &p.Name, &p.Created, &rev, &p.LastUsed); err != nil {
			return nil, err
		}
		p.Revoked = rev != 0
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Store) RevokePushkey(userID, id int64) error {
	res, err := s.db.Exec(`UPDATE pushkeys SET revoked=1 WHERE id=? AND user_id=? AND deleted=0 AND revoked=0`, id, userID)
	if err == nil {
		if n, _ := res.RowsAffected(); n > 0 {
			s.settingsChanged(userID, changeKeys)
		}
	}
	return err
}

func (s *Store) TouchPushkey(id int64) {
	s.db.Exec(`UPDATE pushkeys SET last_used=? WHERE id=?`, now(), id)
}

func (s *Store) addColumn(table, col, def string) error {
	var has int
	s.db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info(?) WHERE name=?`, table, col).Scan(&has)
	if has > 0 {
		return nil
	}
	_, err := s.db.Exec(`ALTER TABLE ` + table + ` ADD COLUMN ` + col + ` ` + def)
	return err
}

// ---------- 设备 ----------

type Device struct {
	ID       string
	UserID   int64
	Name     string
	Platform string
	Created  int64
	LastSeen sql.NullInt64
	Revoked  bool
	Client   string // 客户端上报的版本，例如 "macos 0.4.0 (37)"
	// 0.5.0 起
	AwaySilent bool  // 其他设备在用时本机静默
	PairCount  int   // 配对 / 登录次数
	LastPaired int64 // 最近一次配对 / 登录
}

// 0.9.0 起没有任何账号或设备能进入管理后台：devices.can_admin、pair_codes.can_admin、users.is_admin 是旧数据，不再读取
const deviceCols = `id,user_id,name,platform,created_at,last_seen,revoked,client,away_silent,pair_count,last_paired`

func scanDevice(sc interface{ Scan(...any) error }) (*Device, error) {
	d := &Device{}
	var rev, away int
	if err := sc.Scan(&d.ID, &d.UserID, &d.Name, &d.Platform, &d.Created, &d.LastSeen, &rev, &d.Client, &away, &d.PairCount, &d.LastPaired); err != nil {
		return nil, err
	}
	d.Revoked, d.AwaySilent = rev != 0, away != 0
	return d, nil
}

// CreatePairCode 生成一次性配对码。createdBy 为生成它的设备 ID（管理后台生成时为空）：
// 同一台设备「重新生成」时，它之前没用掉的配对码立即作废，同一时间只有最新的一个有效。
// 已用 / 过期的配对码保留一小时，供生成它的设备查询「已被哪台设备使用」。
func (s *Store) CreatePairCode(userID int64, ttl time.Duration, createdBy string) (string, error) {
	s.db.Exec(`DELETE FROM pair_codes WHERE expires_at < ?`, now()-3600)
	if createdBy != "" {
		s.db.Exec(`UPDATE pair_codes SET expires_at=? WHERE user_id=? AND created_by=? AND used=0 AND expires_at>=?`, now()-1, userID, createdBy, now())
	}
	for i := 0; i < 5; i++ {
		code := randDigits(6)
		_, err := s.db.Exec(`INSERT INTO pair_codes(code,user_id,expires_at,created_by) VALUES(?,?,?,?)`, code, userID, time.Now().Add(ttl).Unix(), createdBy)
		if err == nil {
			return code, nil
		}
	}
	return "", errors.New("生成配对码失败")
}

// Pair 消费一次性配对码，把设备加入配对码所属的账号（同一台设备按指纹复用原记录），返回明文 token（只返回这一次）。
func (s *Store) Pair(code string, p pairReq) (*Device, string, bool, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, "", false, err
	}
	defer tx.Rollback()
	err = tx.QueryRow(`SELECT user_id FROM pair_codes WHERE code=? AND used=0 AND expires_at>=?`, code, now()).Scan(&p.UserID)
	if err != nil {
		return nil, "", false, errors.New("配对码无效或已过期")
	}
	var dis int
	tx.QueryRow(`SELECT disabled FROM users WHERE id=?`, p.UserID).Scan(&dis)
	if dis != 0 {
		return nil, "", false, errDisabled
	}
	if _, err := tx.Exec(`UPDATE pair_codes SET used=1 WHERE code=?`, code); err != nil {
		return nil, "", false, err
	}
	p.Method = "code"
	d, token, reused, err := attachDevice(tx, p)
	if err != nil {
		return nil, "", false, err
	}
	if _, err := tx.Exec(`UPDATE pair_codes SET used_by=?, used_at=? WHERE code=?`, d.Name, now(), code); err != nil {
		return nil, "", false, err
	}
	if err := tx.Commit(); err != nil {
		return nil, "", false, err
	}
	s.settingsChanged(p.UserID, changeDevices)
	s.markActive(p.UserID) // 登录 / 配对也算当天活跃
	return d, token, reused, nil
}

// PairCodeStatus 配对码状态（只查本账号的）：waiting 等待使用 / used 已使用 / expired 已过期或已作废
func (s *Store) PairCodeStatus(userID int64, code string) (state string, expiresIn int64, usedBy string, usedAt int64, err error) {
	var exp, used int64
	err = s.db.QueryRow(`SELECT expires_at, used, used_by, used_at FROM pair_codes WHERE code=? AND user_id=?`, code, userID).Scan(&exp, &used, &usedBy, &usedAt)
	if err != nil {
		return "", 0, "", 0, err
	}
	switch {
	case used != 0:
		state = "used"
	case exp < now():
		state = "expired"
	default:
		state, expiresIn = "waiting", exp-now()
	}
	return
}

func (s *Store) DeviceByToken(token string) (*Device, error) {
	return scanDevice(s.db.QueryRow(`SELECT `+deviceCols+` FROM devices WHERE token_hash=?`, sha256Hex(token)))
}

func (s *Store) TouchDevice(id string) {
	s.db.Exec(`UPDATE devices SET last_seen=? WHERE id=?`, now(), id)
}

func (s *Store) ListDevices(userID int64) ([]Device, error) {
	return s.queryDevices(`SELECT `+deviceCols+` FROM devices WHERE user_id=? ORDER BY revoked, last_paired DESC`, userID)
}

// SearchDevices 跨账号按名称或设备 ID 搜索（管理后台用：客户报设备 ID 时不用先知道是哪个账号）
func (s *Store) SearchDevices(q string) ([]Device, error) {
	like := "%" + strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(strings.ToLower(q)) + "%"
	return s.queryDevices(`SELECT `+deviceCols+` FROM devices WHERE lower(name) LIKE ? ESCAPE '\' OR lower(id) LIKE ? ESCAPE '\'
		ORDER BY revoked, last_paired DESC LIMIT 200`, like, like)
}

func (s *Store) queryDevices(q string, args ...any) ([]Device, error) {
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Device
	for rows.Next() {
		d, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *d)
	}
	return out, rows.Err()
}

func (s *Store) RevokeDevice(userID int64, id string) error {
	res, err := s.db.Exec(`UPDATE devices SET revoked=1 WHERE id=? AND user_id=? AND revoked=0`, id, userID)
	if err == nil {
		if n, _ := res.RowsAffected(); n > 0 {
			s.dropDeviceWrap(userID, id) // 转交给它的私钥副本一并删除
			s.settingsChanged(userID, changeDevices)
		}
	}
	return err
}

// ---------- 消息 ----------

type Attachment struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Mime   string `json:"mime"`
	Size   int64  `json:"size"`
	Sha256 string `json:"sha256"`
	blob   string
	msgID  int64
}

type Message struct {
	ID          int64        `json:"id"`
	Topic       string       `json:"topic"`
	Thread      string       `json:"thread"`
	Priority    int          `json:"priority"`
	Type        string       `json:"type"`
	Text        string       `json:"text"`
	Desp        string       `json:"desp"`
	Source      string       `json:"source"`
	CreatedAt   time.Time    `json:"created_at"`
	Attachments []Attachment `json:"attachments"`
	// 0.5.0 起：发送这条消息的 pushkey（系统消息为 0）；按本设备的接收规则 / 在用设备，是否静默
	PushkeyID    int64  `json:"pushkey_id,omitempty"`
	Silent       bool   `json:"silent,omitempty"`
	SilentReason string `json:"silent_reason,omitempty"`
	// 0.5.4 起：归档状态（0 自动、1 已归档、2 保留在收件箱），见 msgmanage.go
	Archive int `json:"archive,omitempty"`
	// 0.6.0 起：服务端解析好的回笺 Markdown 结构（见 md.go、docs/markdown.md）和纯文本预览；type 为 text 或正文为空时没有
	Doc     json.RawMessage `json:"doc,omitempty"`
	Preview string          `json:"preview,omitempty"`
	// 0.7.0 起：端到端加密的信封（hje1.…，见 docs/e2ee.md）。有它时标题、正文、附件名都在信封里，
	// text 只是给旧客户端看的占位文字，type 为 e2e，附件是密文（名字也是占位的）
	E2E string `json:"e2e,omitempty"`
	// 0.8.0 起：服务器代加密的消息为 "server"（发送端用明文发来，服务器收到后立即加密保存）；发送端加密的没有这个字段
	Sealed string `json:"sealed,omitempty"`
	userID int64
}

// Owner 消息所属账号（管理后台表单用）
func (m Message) Owner() int64 { return m.userID }

type NewMessage struct {
	UserID    int64
	PushkeyID int64
	Topic     string
	Thread    string
	Priority  int
	Type      string
	Text      string
	Desp      string
	Source    string
	SrcIP     string
	Idem      string
	E2E       string       // 端到端加密的信封（hje1.…）；有它时 Text 是给旧客户端看的占位文字，Desp 为空
	Sealed    string       // "server"：服务器代加密
	SealKID   string       // 代加密用的钥匙：写库的事务里核对它仍然启用，否则返回 errKeyChanged
	Files     []Attachment // blob/name/mime/size/sha256 已填好
}

// InsertMessage 写入消息；若 idem 已存在则返回原消息 id 且 dup=true。
// errAccountGone：账号在推送处理途中被删除（messages 没有外键，要自己核对，否则会留下孤儿消息和附件）
var errAccountGone = errors.New("pushkey 所属账号已删除")

func (s *Store) InsertMessage(m NewMessage) (id int64, dup bool, err error) {
	tx, err := s.db.Begin()
	if err != nil {
		return 0, false, err
	}
	defer tx.Rollback()
	var n int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM users WHERE id=?`, m.UserID).Scan(&n); err != nil {
		return 0, false, err
	}
	if n == 0 {
		return 0, false, errAccountGone
	}
	if m.Idem != "" {
		if err := tx.QueryRow(`SELECT id FROM messages WHERE user_id=? AND idem=?`, m.UserID, m.Idem).Scan(&id); err == nil {
			return id, true, nil
		}
	}
	if m.SealKID != "" {
		if ok, err := kidActive(tx, m.UserID, m.SealKID); err != nil {
			return 0, false, err
		} else if !ok {
			return 0, false, errKeyChanged
		}
	}
	res, err := tx.Exec(`INSERT INTO messages(user_id,pushkey_id,topic,thread,priority,type,text,desp,source,src_ip,created_at,idem,e2e,sealed)
		VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)`, m.UserID, m.PushkeyID, m.Topic, m.Thread, m.Priority, m.Type, m.Text, m.Desp, m.Source, m.SrcIP, now(), m.Idem, m.E2E, m.Sealed)
	if err != nil {
		return 0, false, err
	}
	id, _ = res.LastInsertId()
	var size int64
	for _, f := range m.Files {
		if _, err := tx.Exec(`INSERT INTO attachments(id,message_id,blob,name,mime,size,sha256) VALUES(?,?,?,?,?,?,?)`,
			"a_"+randHex(16), id, f.blob, f.Name, f.Mime, f.Size, f.Sha256); err != nil {
			return 0, false, err
		}
		size += f.Size
	}
	if err := bumpStats(tx, 1, size, 0); err != nil { // 全服务器每天的消息数、附件大小（只记数字）
		return 0, false, err
	}
	return id, false, tx.Commit()
}

// MessageIDByIdem：这个账号用这个幂等键记过的消息（没有时为 0）
func (s *Store) MessageIDByIdem(userID int64, idem string) int64 {
	var id int64
	s.db.QueryRow(`SELECT id FROM messages WHERE user_id=? AND idem=?`, userID, idem).Scan(&id)
	return id
}

// Messages 返回 id > since 的消息（升序）。since<0 表示取最新 limit 条。
// deviceID 非空时，跳过这台设备设为「不接收」的 pushkey 发来的消息。
func (s *Store) Messages(userID int64, deviceID string, since int64, limit int) ([]Message, error) {
	var rows *sql.Rows
	var err error
	cols := `id,user_id,topic,thread,priority,type,text,desp,source,created_at,COALESCE(pushkey_id,0),archive,e2e,sealed`
	where := `user_id=? AND NOT EXISTS (SELECT 1 FROM device_keys dk WHERE dk.device_id=? AND dk.pushkey_id=messages.pushkey_id AND dk.mode='off')`
	if since < 0 {
		rows, err = s.db.Query(`SELECT * FROM (SELECT `+cols+` FROM messages WHERE `+where+` ORDER BY id DESC LIMIT ?) ORDER BY id`, userID, deviceID, limit)
	} else {
		rows, err = s.db.Query(`SELECT `+cols+` FROM messages WHERE `+where+` AND id>? ORDER BY id LIMIT ?`, userID, deviceID, since, limit)
	}
	if err != nil {
		return nil, err
	}
	out := []Message{} // 没有消息时返回 [] 而不是 null
	idx := map[int64]int{}
	for rows.Next() {
		var m Message
		var ts int64
		if err := rows.Scan(&m.ID, &m.userID, &m.Topic, &m.Thread, &m.Priority, &m.Type, &m.Text, &m.Desp, &m.Source, &ts, &m.PushkeyID, &m.Archive, &m.E2E, &m.Sealed); err != nil {
			rows.Close()
			return nil, err
		}
		m.CreatedAt = time.Unix(ts, 0).UTC()
		m.Attachments = []Attachment{}
		idx[m.ID] = len(out)
		out = append(out, m)
	}
	rows.Close()
	if len(out) == 0 {
		return out, nil
	}
	ph := strings.TrimSuffix(strings.Repeat("?,", len(out)), ",")
	args := make([]any, len(out))
	for i, m := range out {
		args[i] = m.ID
	}
	arows, err := s.db.Query(`SELECT id,message_id,name,mime,size,sha256 FROM attachments WHERE message_id IN (`+ph+`) ORDER BY rowid`, args...)
	if err != nil {
		return nil, err
	}
	defer arows.Close()
	for arows.Next() {
		var a Attachment
		if err := arows.Scan(&a.ID, &a.msgID, &a.Name, &a.Mime, &a.Size, &a.Sha256); err != nil {
			return nil, err
		}
		i := idx[a.msgID]
		out[i].Attachments = append(out[i].Attachments, a)
	}
	return out, arows.Err()
}

// AttachmentFor 返回属于该用户的附件。
func (s *Store) AttachmentFor(userID int64, attID string) (*Attachment, error) {
	a := &Attachment{}
	err := s.db.QueryRow(`SELECT a.id,a.message_id,a.blob,a.name,a.mime,a.size,a.sha256 FROM attachments a
		JOIN messages m ON m.id=a.message_id WHERE a.id=? AND m.user_id=?`, attID, userID).
		Scan(&a.ID, &a.msgID, &a.blob, &a.Name, &a.Mime, &a.Size, &a.Sha256)
	if err != nil {
		return nil, err
	}
	return a, nil
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

// ---------- 管理会话（持久化，容器重启不丢） ----------

type AdminSession struct {
	IDHash   string
	Label    string
	Created  int64
	LastSeen int64
	Expires  int64
	Sliding  bool
}

const rememberTTL = 365 * 24 * time.Hour

// CreateSession 返回 cookie 明文；库里只存哈希。sliding=true 表示"记住此浏览器"，每次访问顺延一年。
func (s *Store) CreateSession(label string, ttl time.Duration, sliding bool) (string, error) {
	raw := randToken(32)
	_, err := s.db.Exec(`INSERT INTO admin_sessions(id_hash,label,created_at,last_seen,expires_at,sliding) VALUES(?,?,?,?,?,?)`,
		sha256Hex(raw), label, now(), now(), time.Now().Add(ttl).Unix(), b2i(sliding))
	return raw, err
}

func (s *Store) SessionValid(raw string) bool {
	h := sha256Hex(raw)
	var exp, last int64
	var sliding int
	if err := s.db.QueryRow(`SELECT expires_at,last_seen,sliding FROM admin_sessions WHERE id_hash=?`, h).Scan(&exp, &last, &sliding); err != nil {
		return false
	}
	if now() > exp {
		s.db.Exec(`DELETE FROM admin_sessions WHERE id_hash=?`, h)
		return false
	}
	if now()-last > 600 { // 每 10 分钟最多写一次
		if sliding != 0 {
			exp = time.Now().Add(rememberTTL).Unix()
		}
		s.db.Exec(`UPDATE admin_sessions SET last_seen=?, expires_at=? WHERE id_hash=?`, now(), exp, h)
	}
	return true
}

func (s *Store) ListSessions() ([]AdminSession, error) {
	s.db.Exec(`DELETE FROM admin_sessions WHERE expires_at < ?`, now())
	rows, err := s.db.Query(`SELECT id_hash,label,created_at,last_seen,expires_at,sliding FROM admin_sessions ORDER BY last_seen DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AdminSession
	for rows.Next() {
		var a AdminSession
		var sl int
		if err := rows.Scan(&a.IDHash, &a.Label, &a.Created, &a.LastSeen, &a.Expires, &sl); err != nil {
			return nil, err
		}
		a.Sliding = sl != 0
		out = append(out, a)
	}
	return out, rows.Err()
}

func (s *Store) DeleteSessionByHash(h string) {
	s.db.Exec(`DELETE FROM admin_sessions WHERE id_hash=?`, h)
}
func (s *Store) DeleteSession(raw string) { s.DeleteSessionByHash(sha256Hex(raw)) }

// ---------- 一次性登录链接 ----------

func (s *Store) CreateAdminLink(deviceID string, ttl time.Duration) (string, error) {
	s.db.Exec(`DELETE FROM admin_links WHERE expires_at < ? OR used=1`, now())
	raw := "L_" + randToken(24)
	_, err := s.db.Exec(`INSERT INTO admin_links(token_hash,device_id,created_at,expires_at) VALUES(?,?,?,?)`,
		sha256Hex(raw), deviceID, now(), time.Now().Add(ttl).Unix())
	return raw, err
}

// ConsumeAdminLink 校验并作废链接，返回签发它的设备 id（命令行签发为空）。
func (s *Store) ConsumeAdminLink(raw string) (string, bool) {
	h := sha256Hex(raw)
	res, err := s.db.Exec(`UPDATE admin_links SET used=1 WHERE token_hash=? AND used=0 AND expires_at>=?`, h, now())
	if err != nil {
		return "", false
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return "", false
	}
	var dev string
	s.db.QueryRow(`SELECT device_id FROM admin_links WHERE token_hash=?`, h).Scan(&dev)
	return dev, true
}

func (s *Store) DeviceName(id string) string {
	var n string
	s.db.QueryRow(`SELECT name FROM devices WHERE id=?`, id).Scan(&n)
	return n
}

// dbPath 返回数据库路径：沿用已有的 huijian.db 或改名前的 hongyan.db（hongyan.db 不改名：
// 一键更新回退到旧程序、或者旧程序和新命令行同时在用这个目录时，旧程序仍然只认 hongyan.db）；
// 更早的 beacon.db 改名为 huijian.db（连同 -wal/-shm）。
func dbPath(dataDir string) string {
	p := filepath.Join(dataDir, dbFileName(dataDir))
	if old := filepath.Join(dataDir, "beacon.db"); !fileExists(p) && fileExists(old) {
		for _, suf := range []string{"", "-wal", "-shm"} {
			os.Rename(old+suf, p+suf)
		}
	}
	return p
}

// ---------- 键值（服务端内部状态：目录标记、备份结果等） ----------

func (s *Store) GetKV(k string) string {
	var v string
	s.db.QueryRow(`SELECT v FROM kv WHERE k=?`, k).Scan(&v)
	return v
}

func (s *Store) SetKV(k string, v any) {
	s.db.Exec(`INSERT INTO kv(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v`, k, fmt.Sprint(v))
}

// BlobBySha 找已有的同内容附件（用于去重）
func (s *Store) BlobBySha(sha string) string {
	var b string
	s.db.QueryRow(`SELECT blob FROM attachments WHERE sha256=? ORDER BY rowid DESC LIMIT 1`, sha).Scan(&b)
	return b
}
