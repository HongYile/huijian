package main

// 端到端加密的存储（docs/e2ee.md）：服务端只存公钥、各种「锁住的私钥副本」和密文，自己解不开任何一样。

import (
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
)

const e2eSchema = `
CREATE TABLE IF NOT EXISTS e2e_keys(
  user_id INTEGER NOT NULL, kid TEXT NOT NULL, pub TEXT NOT NULL, created_at INTEGER NOT NULL,
  active INTEGER NOT NULL DEFAULT 1, PRIMARY KEY(user_id, kid));
CREATE TABLE IF NOT EXISTS e2e_wraps(
  user_id INTEGER NOT NULL, kind TEXT NOT NULL, device_id TEXT NOT NULL DEFAULT '',
  blob TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY(user_id, kind, device_id));
-- 0.8.0 补加密：换掉的旧附件 id（下载时返回 410「附件已加密，请刷新消息」，不返回密文）
CREATE TABLE IF NOT EXISTS sealed_atts(
  id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, message_id INTEGER NOT NULL, at INTEGER NOT NULL);
-- 0.8.0 补加密：等待删除的旧明文附件文件（和补加密同一个事务登记，删掉才清记录；启动时、定时重试）
CREATE TABLE IF NOT EXISTS pending_unlink(blob TEXT PRIMARY KEY, at INTEGER NOT NULL);
`

// e2ePlaceholder：加密消息存进数据库的标题（旧客户端、管理后台看到的就是它）
const e2ePlaceholder = "🔒 加密消息（请把回笺更新到最新版查看）"

// 锁住的私钥副本种类：password（密码派生的解锁钥匙）、recovery（恢复码）、device（转交给某台设备）
const (
	wrapPassword = "password"
	wrapRecovery = "recovery"
	wrapDevice   = "device"
)

func (s *Store) migrateE2E() error {
	if _, err := s.db.Exec(e2eSchema); err != nil {
		return err
	}
	for _, m := range [][3]string{
		{"messages", "e2e", "TEXT NOT NULL DEFAULT ''"},
		// 新登录协议：客户端用 Argon2id 从密码派生登录凭证，服务端只存凭证的哈希，拿不到密码（见 docs/e2ee.md）
		{"users", "auth_salt", "TEXT NOT NULL DEFAULT ''"},
		{"users", "auth_hash", "TEXT NOT NULL DEFAULT ''"},
		{"users", "e2e_only", "INTEGER NOT NULL DEFAULT 0"}, // 0.9.0 起不再使用（取消「只接受加密消息」）
		// 0.8.0：代加密的消息记 "server"；发送端加密的、明文的为空
		{"messages", "sealed", "TEXT NOT NULL DEFAULT ''"},
		// 设备自己的 X25519 公钥（转交钥匙时加密给它），以及请求批准的时间
		{"devices", "e2e_pub", "TEXT NOT NULL DEFAULT ''"},
		{"devices", "e2e_req", "INTEGER NOT NULL DEFAULT 0"},
		// 批准时的核对码（承诺 + 揭晓，见 e2e.go）：新设备的承诺、批准设备的随机数 na、新设备揭晓的 nb（都是 base64url）
		{"devices", "e2e_commit", "TEXT NOT NULL DEFAULT ''"},
		{"devices", "e2e_na", "TEXT NOT NULL DEFAULT ''"},
		{"devices", "e2e_nb", "TEXT NOT NULL DEFAULT ''"},
	} {
		var has int
		s.db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info(?) WHERE name=?`, m[0], m[1]).Scan(&has)
		if has == 0 {
			if _, err := s.db.Exec(`ALTER TABLE ` + m[0] + ` ADD COLUMN ` + m[1] + ` ` + m[2]); err != nil {
				return err
			}
		}
	}
	return nil
}

// ---------- 登录凭证 ----------

// authHash：登录凭证是 32 字节、等同随机的派生值，用 SHA-256 存就够了（不需要再做慢哈希）
func authHash(authKey []byte) string {
	s := sha256.Sum256(authKey)
	return "sha256$" + hex.EncodeToString(s[:])
}

func authKeyMatches(stored string, authKey []byte) bool {
	return stored != "" && subtle.ConstantTimeCompare([]byte(stored), []byte(authHash(authKey))) == 1
}

// AuthParams：这个账号的 Argon2id 盐（十六进制）；空表示还没升级到新登录协议（客户端照旧发送密码）
func (s *Store) AuthParams(userID int64) (salt, hash string) {
	s.db.QueryRow(`SELECT auth_salt, auth_hash FROM users WHERE id=?`, userID).Scan(&salt, &hash)
	return
}

// fakeAuthSalt：账号不存在时返回的假盐，同一个用户名每次都一样，不暴露账号是否存在
func (s *Store) fakeAuthSalt(username string) string {
	m := hmac.New(sha256.New, []byte(s.serverSecret()))
	m.Write([]byte("huijian prelogin " + usernameKey(username)))
	return hex.EncodeToString(m.Sum(nil)[:16])
}

func (s *Store) serverSecret() string {
	if v := s.GetKV("server_secret"); v != "" {
		return v
	}
	v := randHex(32)
	s.SetKV("server_secret", v)
	return s.GetKV("server_secret")
}

// SetAuthKey：升级 / 修改为新登录协议。清掉旧的密码哈希：之后不再接受密码原文登录
func (s *Store) SetAuthKey(tx *sql.Tx, userID int64, salt string, authKey []byte) error {
	_, err := tx.Exec(`UPDATE users SET auth_salt=?, auth_hash=?, pass_hash='' WHERE id=?`, salt, authHash(authKey), userID)
	return err
}

// ---------- 账号钥匙 ----------

type E2EKey struct {
	KID    string `json:"kid"`
	Pub    string `json:"pub"`
	Active bool   `json:"active"`
}

func (s *Store) E2EKeys(userID int64) []E2EKey {
	rows, err := s.db.Query(`SELECT kid, pub, active FROM e2e_keys WHERE user_id=? ORDER BY created_at, kid`, userID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []E2EKey
	for rows.Next() {
		var k E2EKey
		if rows.Scan(&k.KID, &k.Pub, &k.Active) == nil {
			out = append(out, k)
		}
	}
	return out
}

// E2EEnabled：账号有启用中的钥匙。重置加密（ResetE2E）会停用旧钥匙、同时写入新钥匙，所以开启过的账号始终有一把 active 钥匙
func (s *Store) E2EEnabled(userID int64) bool {
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM e2e_keys WHERE user_id=? AND active=1`, userID).Scan(&n)
	return n > 0
}

// e2eEverEnabled：开启过加密（包括已停用的旧钥匙）。setup 只能在从没开启过时用，之后换钥匙走 reset
func e2eEverEnabled(q interface{ QueryRow(string, ...any) *sql.Row }, userID int64) bool {
	var n int
	q.QueryRow(`SELECT COUNT(*) FROM e2e_keys WHERE user_id=?`, userID).Scan(&n)
	return n > 0
}

// E2EActivePub：账号启用中的公钥（服务器代加密、管理后台的加密发送密钥用）。
// 只有确实没有启用中的钥匙才返回 (nil, nil)；查询出错、公钥损坏都返回错误：调用方不能把它当成「没开启」而存明文
func (s *Store) E2EActivePub(userID int64) (*ecdh.PublicKey, error) {
	var enc string
	err := s.db.QueryRow(`SELECT pub FROM e2e_keys WHERE user_id=? AND active=1 ORDER BY created_at DESC, kid LIMIT 1`, userID).Scan(&enc)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	raw, err := b64.DecodeString(enc)
	if err != nil {
		return nil, fmt.Errorf("账号 #%d 的公钥损坏：%w", userID, err)
	}
	return ecdh.X25519().NewPublicKey(raw)
}

// errKeyChanged：加密用的钥匙在写库前被停用（账号刚刚重置过加密）
var errKeyChanged = errors.New("账号的加密钥匙刚刚更换，请重试")

// kidActive：在事务里确认 kid 是账号启用中的钥匙
func kidActive(tx *sql.Tx, userID int64, kid string) (bool, error) {
	var n int
	err := tx.QueryRow(`SELECT COUNT(*) FROM e2e_keys WHERE user_id=? AND kid=? AND active=1`, userID, kid).Scan(&n)
	return n > 0, err
}

// errStaleKID：上传的 wrap / grant 锁的是已经停用的钥匙（本机还留着重置以前的旧私钥）
var errStaleKID = errors.New("这把钥匙已经停用（账号重置过加密）：请先用密码或恢复码解锁新的钥匙")

// checkWrapKID：上传锁住的私钥副本时带的 kid 必须是启用中的钥匙。kid 为空时不检查（0.7 客户端不带）
func checkWrapKID(tx *sql.Tx, userID int64, kid string) error {
	if kid == "" {
		return nil
	}
	ok, err := kidActive(tx, userID, kid)
	if err != nil {
		return err
	}
	if !ok {
		return errStaleKID
	}
	return nil
}

// PlainCount：服务器上这个账号还剩几条明文消息
func (s *Store) PlainCount(userID int64) int {
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE user_id=? AND e2e=''`, userID).Scan(&n)
	return n
}

// credSnapshot：当前登录凭证的哈希（新协议 + 旧协议）。核对当前密码前取一次，写入时在事务里再比一次：
// 期间密码被改过、或者另一台设备刚重置过加密，就拒绝（防止两边互相覆盖）
func credSnapshot(q interface{ QueryRow(string, ...any) *sql.Row }, userID int64) string {
	var ah, ph string
	q.QueryRow(`SELECT auth_hash, pass_hash FROM users WHERE id=?`, userID).Scan(&ah, &ph)
	return ah + "|" + ph
}

var errCredChanged = errors.New("密码刚刚被修改，或者另一台设备刚重置过加密：请刷新后重试")

// E2EStatus：管理后台「账号」页用：每个账号是否有启用中的钥匙，以及服务器上还剩多少条明文消息
func (s *Store) E2EStatus() (enc map[int64]bool, plain map[int64]int) {
	enc, plain = map[int64]bool{}, map[int64]int{}
	if rows, err := s.db.Query(`SELECT DISTINCT user_id FROM e2e_keys WHERE active=1`); err == nil {
		for rows.Next() {
			var id int64
			if rows.Scan(&id) == nil {
				enc[id] = true
			}
		}
		rows.Close()
	}
	if rows, err := s.db.Query(`SELECT user_id, COUNT(*) FROM messages WHERE e2e='' GROUP BY user_id`); err == nil {
		for rows.Next() {
			var id int64
			var n int
			if rows.Scan(&id, &n) == nil {
				plain[id] = n
			}
		}
		rows.Close()
	}
	return
}

// E2EHasKID：信封里的 kid 是不是这个账号的钥匙（包括更换前的旧钥匙）
func (s *Store) E2EHasKID(userID int64, kid string) bool {
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM e2e_keys WHERE user_id=? AND kid=? AND active=1`, userID, kid).Scan(&n) // 已停用（更换掉）的钥匙不再接收新消息
	return n > 0
}

var errE2EEnabled = errors.New("这个账号已经开启了端到端加密")

// E2ESetupInput：开启加密时由客户端一次性提交（服务端只存，解不开）
type E2ESetupInput struct {
	Salt         string // Argon2id 盐（十六进制，16 字节）
	AuthKey      []byte // 新登录凭证
	Pub          []byte // 账号公钥（32 字节）
	PasswordWrap string // hjp1.…：用密码派生的解锁钥匙锁住的私钥
	RecoveryWrap string // hjr1.…：用恢复码锁住的私钥（0.8.0 起可选）
	DeviceID     string // 开启加密的这台设备
	CredSnap     string // 核对当前密码前的凭证快照（credSnapshot），事务里再比一次；空表示不比
}

func (s *Store) SetupE2E(userID int64, in E2ESetupInput) (string, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	if e2eEverEnabled(tx, userID) { // 开启过（哪怕钥匙都已停用）就只能走 reset，免得两条路径互相覆盖
		return "", errE2EEnabled
	}
	if in.CredSnap != "" && credSnapshot(tx, userID) != in.CredSnap {
		return "", errCredChanged
	}
	kid := e2eKID(in.Pub)
	if _, err := tx.Exec(`INSERT INTO e2e_keys(user_id,kid,pub,created_at,active) VALUES(?,?,?,?,1)`,
		userID, kid, b64.EncodeToString(in.Pub), now()); err != nil {
		return "", err
	}
	if err := s.SetAuthKey(tx, userID, in.Salt, in.AuthKey); err != nil {
		return "", err
	}
	for kind, blob := range map[string]string{wrapPassword: in.PasswordWrap, wrapRecovery: in.RecoveryWrap} {
		if blob == "" {
			continue
		}
		if err := putWrap(tx, userID, kind, "", blob); err != nil {
			return "", err
		}
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	s.settingsChanged(userID, changeE2E)
	return kid, nil
}

var errE2ENotEnabled = errors.New("这个账号还没有开启加密")

// ResetE2E：重置加密（换一把新钥匙）。旧钥匙全部停用但保留（还留着旧私钥的设备靠它们解旧消息），
// 所有锁住的副本（密码、恢复码、转交给设备的）一律删除，进行中的设备批准作废；新钥匙、新登录凭证、新密码副本一起写入
func (s *Store) ResetE2E(userID int64, in E2ESetupInput) (string, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	if !e2eEverEnabled(tx, userID) {
		return "", errE2ENotEnabled
	}
	if in.CredSnap != "" && credSnapshot(tx, userID) != in.CredSnap { // 核对密码和写入之间凭证变了：两台设备同时重置时后到的被拒
		return "", errCredChanged
	}
	kid := e2eKID(in.Pub)
	for _, q := range []string{
		`UPDATE e2e_keys SET active=0 WHERE user_id=?`,
		`DELETE FROM e2e_wraps WHERE user_id=?`,
		`UPDATE devices SET e2e_req=0, e2e_commit='', e2e_na='', e2e_nb='' WHERE user_id=?`,
	} {
		if _, err := tx.Exec(q, userID); err != nil {
			return "", err
		}
	}
	// 同一把公钥重复提交（客户端没收到上次的响应又重试）：重新启用它即可
	if _, err := tx.Exec(`INSERT INTO e2e_keys(user_id,kid,pub,created_at,active) VALUES(?,?,?,?,1)
		ON CONFLICT(user_id,kid) DO UPDATE SET active=1`, userID, kid, b64.EncodeToString(in.Pub), now()); err != nil {
		return "", err
	}
	if err := s.SetAuthKey(tx, userID, in.Salt, in.AuthKey); err != nil {
		return "", err
	}
	for kind, blob := range map[string]string{wrapPassword: in.PasswordWrap, wrapRecovery: in.RecoveryWrap} {
		if blob == "" {
			continue
		}
		if err := putWrap(tx, userID, kind, "", blob); err != nil {
			return "", err
		}
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	s.settingsChanged(userID, changeE2E)
	return kid, nil
}

func putWrap(tx *sql.Tx, userID int64, kind, deviceID, blob string) error {
	_, err := tx.Exec(`INSERT INTO e2e_wraps(user_id,kind,device_id,blob,created_at) VALUES(?,?,?,?,?)
		ON CONFLICT(user_id,kind,device_id) DO UPDATE SET blob=excluded.blob, created_at=excluded.created_at`,
		userID, kind, deviceID, blob, now())
	return err
}

func (s *Store) Wrap(userID int64, kind, deviceID string) string {
	var blob string
	s.db.QueryRow(`SELECT blob FROM e2e_wraps WHERE user_id=? AND kind=? AND device_id=?`, userID, kind, deviceID).Scan(&blob)
	return blob
}

func (s *Store) HasWrap(userID int64, kind string) bool {
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM e2e_wraps WHERE user_id=? AND kind=?`, userID, kind).Scan(&n)
	return n > 0
}

// SetPasswordAuth：在已开启加密的账号上改密码：新盐、新登录凭证、用新密码锁住的私钥一起换
var errNeedPasswordWrap = errors.New("这个账号已开启加密：改密码时要同时提交用新密码锁住的私钥（请更新回笺后重试）")

func (s *Store) SetPasswordAuth(userID int64, salt string, authKey []byte, passwordWrap, kid string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var keys int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM e2e_keys WHERE user_id=? AND active=1`, userID).Scan(&keys); err != nil {
		return err
	}
	if keys > 0 && passwordWrap == "" { // 在事务里判断：和另一台设备同时开启加密时，不会留下旧密码锁住的副本
		return errNeedPasswordWrap
	}
	if passwordWrap != "" {
		if err := checkWrapKID(tx, userID, kid); err != nil {
			return err
		}
	}
	if err := s.SetAuthKey(tx, userID, salt, authKey); err != nil {
		return err
	}
	if passwordWrap != "" {
		if err := putWrap(tx, userID, wrapPassword, "", passwordWrap); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	s.settingsChanged(userID, changeAccount)
	return nil
}

func (s *Store) SetRecoveryWrap(userID int64, blob, kid string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := checkWrapKID(tx, userID, kid); err != nil {
		return err
	}
	if err := putWrap(tx, userID, wrapRecovery, "", blob); err != nil {
		return err
	}
	return tx.Commit()
}

// ResetPasswordE2E：管理员重设密码（服务端设的密码原文哈希）时，用旧密码锁住的私钥副本作废：
// 用户用新密码登录后，要靠恢复码或另一台设备批准来解锁，再重新设置。
func (s *Store) dropPasswordWrap(tx *sql.Tx, userID int64) error {
	if _, err := tx.Exec(`DELETE FROM e2e_wraps WHERE user_id=? AND kind=?`, userID, wrapPassword); err != nil {
		return err
	}
	_, err := tx.Exec(`UPDATE users SET auth_salt='', auth_hash='' WHERE id=?`, userID)
	return err
}

// ---------- 设备批准 ----------

type E2ERequest struct {
	DeviceID    string `json:"device_id"`
	Name        string `json:"name"`
	Platform    string `json:"platform"`
	Pub         string `json:"pub"`
	RequestedAt int64  `json:"requested_at"`
	Commit      string `json:"commit"`    // 新设备的承诺
	Challenge   string `json:"challenge"` // 批准设备给的 na（空 = 还没有设备接手）
	Reveal      string `json:"reveal"`    // 新设备揭晓的 nb（空 = 还没揭晓）
}

// SetDevicePub：设备登记自己的 X25519 公钥；request 为真时同时请求批准（commit 是核对码的承诺），
// 每次调用都让之前的核对过程作废
func (s *Store) SetDevicePub(d *Device, pub []byte, request bool, commit string) error {
	req := int64(0)
	if request {
		req = now()
	} else {
		commit = ""
	}
	enc := b64.EncodeToString(pub)
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var old string
	if err := tx.QueryRow(`SELECT e2e_pub FROM devices WHERE id=? AND user_id=? AND revoked=0`, d.ID, d.UserID).Scan(&old); err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE devices SET e2e_pub=?, e2e_req=?, e2e_commit=?, e2e_na='', e2e_nb='' WHERE id=?`, enc, req, commit, d.ID); err != nil {
		return err
	}
	if old != enc { // 公钥换了：原来转交给这台设备的副本对不上新私钥，作废
		if _, err := tx.Exec(`DELETE FROM e2e_wraps WHERE user_id=? AND kind=? AND device_id=?`, d.UserID, wrapDevice, d.ID); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	if request {
		s.settingsChanged(d.UserID, changeE2E)
	}
	return nil
}

func (s *Store) PendingE2ERequests(userID int64) []E2ERequest {
	rows, err := s.db.Query(`SELECT id, name, platform, e2e_pub, e2e_req, e2e_commit, e2e_na, e2e_nb FROM devices
		WHERE user_id=? AND revoked=0 AND e2e_req>0 AND e2e_pub!='' ORDER BY e2e_req`, userID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []E2ERequest
	for rows.Next() {
		var r E2ERequest
		if rows.Scan(&r.DeviceID, &r.Name, &r.Platform, &r.Pub, &r.RequestedAt, &r.Commit, &r.Challenge, &r.Reveal) == nil {
			out = append(out, r)
		}
	}
	return out
}

var errNoSuchDevice = errors.New("找不到这台设备，或它还没登记加密公钥")

// GrantDevice：已解锁的设备把私钥转交给 deviceID（blob 是加密给对方公钥的 HPKE 密文）。pub 必须和对方登记的一致
func (s *Store) GrantDevice(userID int64, deviceID, pub, blob, kid string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := checkWrapKID(tx, userID, kid); err != nil {
		return err
	}
	var cur string
	var req int64
	var nb string
	if err := tx.QueryRow(`SELECT e2e_pub, e2e_req, e2e_nb FROM devices WHERE id=? AND user_id=? AND revoked=0`, deviceID, userID).Scan(&cur, &req, &nb); err != nil || cur == "" {
		return errNoSuchDevice
	}
	if req == 0 || nb == "" {
		return errors.New("这台设备没有在等待批准，或还没完成核对码（请让它重新请求）")
	}
	if cur != pub {
		return errors.New("这台设备的加密公钥已经变了，请让它重新请求")
	}
	if err := putWrap(tx, userID, wrapDevice, deviceID, blob); err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE devices SET e2e_req=0, e2e_commit='', e2e_na='', e2e_nb='' WHERE id=?`, deviceID); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	s.settingsChanged(userID, changeE2E)
	return nil
}

var errChallengeTaken = errors.New("这台设备的请求已经在另一台设备上处理，或已经取消")

// SetChallenge：批准设备接手请求，交出随机数 na（每个请求只能接手一次）
func (s *Store) SetChallenge(userID int64, deviceID, na string) error {
	res, err := s.db.Exec(`UPDATE devices SET e2e_na=? WHERE id=? AND user_id=? AND revoked=0 AND e2e_req>0 AND e2e_commit!='' AND e2e_na=''`,
		na, deviceID, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return errChallengeTaken
	}
	s.settingsChanged(userID, changeE2E)
	return nil
}

// RevealNonce：新设备揭晓 nb（必须和承诺一致；每个请求只能揭晓一次）
func (s *Store) RevealNonce(d *Device, nb []byte) error {
	var pub, commit, na, cur string
	var req int64
	if err := s.db.QueryRow(`SELECT e2e_pub, e2e_req, e2e_commit, e2e_na, e2e_nb FROM devices WHERE id=? AND user_id=? AND revoked=0`,
		d.ID, d.UserID).Scan(&pub, &req, &commit, &na, &cur); err != nil {
		return err
	}
	if req == 0 || na == "" || cur != "" {
		return errors.New("现在不能揭晓：请求不存在、还没有设备接手，或已经揭晓过（请重新请求）")
	}
	raw, err := b64.DecodeString(pub)
	if err != nil {
		return errors.New("随机数和承诺对不上")
	}
	match := false // 承诺里含新设备看到的账号公钥：必须是账号现在启用的某把钥匙
	for _, k := range s.E2EKeys(d.UserID) {
		if acc, err := b64.DecodeString(k.Pub); err == nil && k.Active && b64.EncodeToString(e2eCommit(raw, acc, nb)) == commit {
			match = true
		}
	}
	if !match {
		return errors.New("随机数和承诺对不上（或者新设备看到的账号公钥不对）")
	}
	res, err := s.db.Exec(`UPDATE devices SET e2e_nb=? WHERE id=? AND e2e_na=? AND e2e_nb=''`, b64.EncodeToString(nb), d.ID, na)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return errChallengeTaken
	}
	s.settingsChanged(d.UserID, changeE2E)
	return nil
}

func (s *Store) DenyE2ERequest(userID int64, deviceID string) error {
	res, err := s.db.Exec(`UPDATE devices SET e2e_req=0, e2e_commit='', e2e_na='', e2e_nb='' WHERE id=? AND user_id=? AND e2e_req>0`, deviceID, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n > 0 {
		s.settingsChanged(userID, changeE2E)
	}
	return nil
}

// dropDeviceWrap：设备被移除时删掉转交给它的副本
func (s *Store) dropDeviceWrap(userID int64, deviceID string) {
	s.db.Exec(`DELETE FROM e2e_wraps WHERE user_id=? AND kind=? AND device_id=?`, userID, wrapDevice, deviceID)
}

// PlainMessageIDs：这个账号服务器上的明文消息（开启加密以前的、或明文发送的），「删除旧明文消息」用
func (s *Store) PlainMessageIDs(userID int64) []int64 {
	rows, err := s.db.Query(`SELECT id FROM messages WHERE user_id=? AND e2e=''`, userID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	return ids
}

// e2eValidWrap：格式检查（前缀 + base64url），不解密
func e2eValidWrap(prefix, s string, maxLen int) bool {
	data, ok := strings.CutPrefix(s, prefix+".")
	if !ok || len(s) > maxLen {
		return false
	}
	raw, err := b64.DecodeString(data)
	return err == nil && len(raw) >= 12+16
}

func randSalt() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
