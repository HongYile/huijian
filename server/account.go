package main

// 账号、设备身份、按设备接收规则、在用设备优先。
//
// 账号：一个账号 = 一个人，拥有自己的 pushkey、设备和消息历史。
//   - 0.9.0 起账号只能由用户在客户端注册产生（POST /v1/register）：注册即登录、注册即开启加密，
//     注册模式 closed / invite（默认）/ open，见 invites.go。管理后台和命令行都不能建账号，
//     也不能改任何账号的用户名和密码（改了密码运营方就能登录进别人的账号）。
//   - 第一个账号（id 最小）接收服务器自己的通知；新部署里就是第一个注册的人。账号 id 不复用（account_delete.go）。
//   - 0.5.0 以前的数据属于第一个账号，它最初没有用户名和密码，由这个账号已登录的设备在客户端里设置。
//   - 新账号不预置 pushkey，由用户自己新建（客户端新建第一把时名称默认填 default）。
//
// 设备加入账号的两种方式：
//   - 用户名 + 密码登录（POST /v1/login，主要方式；新协议用 auth_key）；
//   - 配对码：该账号已登录的设备生成，新设备输入后直接进入这个账号。
//
// 设备身份：客户端上报硬件指纹（本机硬件 UUID 加盐后的哈希）。同一账号下指纹相同的设备
// 重新配对 / 登录时复用原来的设备记录（ID、名称、接收规则不变），旧 token 作废，并记一条配对记录。
//
// 按设备接收：每台设备对每把 pushkey 可选 提醒（默认）/ 静默（进列表、不弹不响）/ 不接收。
// 在用设备优先：设备打开「我在用其他设备时本机不响」后，同账号的另一台设备 90 秒内有人在用时，
// 本机收到的非紧急消息标记为静默。紧急（P5）消息始终提醒。

import (
	"crypto/pbkdf2"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const accountSchema = `
CREATE TABLE IF NOT EXISTS device_pairings(
  id INTEGER PRIMARY KEY AUTOINCREMENT, device_id TEXT NOT NULL, user_id INTEGER NOT NULL,
  at INTEGER NOT NULL, ip TEXT NOT NULL DEFAULT '', method TEXT NOT NULL, client TEXT NOT NULL DEFAULT '');
CREATE INDEX IF NOT EXISTS idx_pairings_dev ON device_pairings(device_id, id);
CREATE TABLE IF NOT EXISTS device_keys(
  device_id TEXT NOT NULL, pushkey_id INTEGER NOT NULL, mode TEXT NOT NULL,
  PRIMARY KEY(device_id, pushkey_id));
`

func (s *Store) migrateAccounts() error {
	for _, m := range [][3]string{
		{"users", "username", "TEXT NOT NULL DEFAULT ''"},
		{"users", "username_key", "TEXT NOT NULL DEFAULT ''"},
		{"users", "pass_hash", "TEXT NOT NULL DEFAULT ''"},
		{"users", "disabled", "INTEGER NOT NULL DEFAULT 0"},
		{"devices", "fingerprint", "TEXT NOT NULL DEFAULT ''"},
		{"devices", "away_silent", "INTEGER NOT NULL DEFAULT 1"},
		{"devices", "pair_count", "INTEGER NOT NULL DEFAULT 1"},
		{"devices", "last_paired", "INTEGER NOT NULL DEFAULT 0"},
		// 删除 pushkey 是软删除：行保留（继续占着 key 字符串和 id，不会被别的账号认领或复用），只是不再显示
		{"pushkeys", "deleted", "INTEGER NOT NULL DEFAULT 0"},
	} {
		if err := s.addColumn(m[0], m[1], m[2]); err != nil {
			return err
		}
	}
	_, err := s.db.Exec(accountSchema + `
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_username ON users(username_key) WHERE username_key != '';
CREATE INDEX IF NOT EXISTS idx_devices_fp ON devices(user_id, fingerprint) WHERE fingerprint != '';
UPDATE devices SET last_paired=created_at WHERE last_paired=0;`)
	return err
}

// ---------- 账号 ----------

type Account struct {
	ID          int64
	Username    string
	HasPassword bool
	// AuthKey：已升级到新登录协议（客户端用 Argon2id 派生登录凭证，服务端不再保存、也不再接受密码原文）
	AuthKey  bool
	Disabled bool
	Created  int64
	// 管理后台账号列表用的统计（只有数字，不含 key、设备名、IP、消息内容）
	Devices, Messages int64
	LastActive        int64 // 设备最后一次访问接口或登录的时间，0 = 从未
	Bytes             int64 // 占用空间：消息（密文 / 明文）加附件
	Encrypted         bool  // 有 active 加密钥匙
	Plain             int64 // 服务器上还没补加密的明文消息
}

// Label 用于显示：有用户名显示用户名，否则「第一个账号」/「账号 #id」
func (a Account) Label() string {
	if a.Username != "" {
		return a.Username
	}
	return "账号 #" + strconv.FormatInt(a.ID, 10) + "（未设置用户名）"
}

// 用户名：中文、字母、数字、下划线、点、短横线，中间可以有空格（例如 Alex Chen），2–32 个字
var reUsername = regexp.MustCompile(`^[\p{L}\p{N}_.-]+( [\p{L}\p{N}_.-]+)*$`)

// normUsername：去掉首尾空白，中间连续的空白合并成一个空格
func normUsername(u string) string { return strings.Join(strings.Fields(u), " ") }

// 显示为空白的「字母」（韩文填充符），用它们可以做出和真名几乎看不出区别的用户名
var blankLetters = map[rune]bool{0x115F: true, 0x1160: true, 0x3164: true, 0xFFA0: true}

func validUsername(u string) bool {
	n := len([]rune(u))
	if n < 2 || n > 32 || !reUsername.MatchString(u) {
		return false
	}
	for _, r := range u {
		if blankLetters[r] {
			return false
		}
	}
	return true
}

const usernameRule = "用户名 2–32 个字，可以用中文、字母、数字、空格、下划线、点和短横线"
const passwordRule = "密码至少 8 位"

var (
	errBadUsername   = errors.New(usernameRule)
	errBadPassword   = errors.New(passwordRule)
	errUsernameTaken = errors.New("这个用户名已被使用")
	errBadLogin      = errors.New("用户名或密码不对")
	errDisabled      = errors.New("账号已停用，请联系管理员")
)

func usernameKey(u string) string { return strings.ToLower(normUsername(u)) }

func checkCredentials(username, password string) error {
	if !validUsername(normUsername(username)) {
		return errBadUsername
	}
	if len([]rune(password)) < 8 || len(password) > 256 {
		return errBadPassword
	}
	return nil
}

// 密码：PBKDF2-SHA256，60 万轮，16 字节盐
const pbkdfIter = 600000

// 同时最多算 2 个 PBKDF2：从很多 IP 狂刷登录也只能占两个核
var pbkdfSem = make(chan struct{}, 2)

func hashPassword(pw string) string {
	pbkdfSem <- struct{}{}
	defer func() { <-pbkdfSem }()
	salt := randBytes(16)
	k, _ := pbkdf2.Key(sha256.New, pw, salt, pbkdfIter, 32)
	return fmt.Sprintf("pbkdf2-sha256$%d$%s$%s", pbkdfIter, base64.RawStdEncoding.EncodeToString(salt), base64.RawStdEncoding.EncodeToString(k))
}

func verifyPassword(stored, pw string) bool {
	p := strings.Split(stored, "$")
	if len(p) != 4 || p[0] != "pbkdf2-sha256" {
		return false
	}
	iter, err := strconv.Atoi(p[1])
	salt, err2 := base64.RawStdEncoding.DecodeString(p[2])
	want, err3 := base64.RawStdEncoding.DecodeString(p[3])
	if err != nil || err2 != nil || err3 != nil || iter < 1000 {
		return false
	}
	pbkdfSem <- struct{}{}
	k, err := pbkdf2.Key(sha256.New, pw, salt, iter, len(want))
	<-pbkdfSem
	return err == nil && subtle.ConstantTimeCompare(k, want) == 1
}

// pbkdfParams：拆出已存密码哈希的盐和轮数（给 /v1/prelogin 用：新客户端在本机算出 PBKDF2 结果再发，不发密码原文）
func pbkdfParams(stored string) (salt []byte, iter int, ok bool) {
	p := strings.Split(stored, "$")
	if len(p) != 4 || p[0] != "pbkdf2-sha256" {
		return nil, 0, false
	}
	iter, err := strconv.Atoi(p[1])
	salt, err2 := base64.RawStdEncoding.DecodeString(p[2])
	return salt, iter, err == nil && err2 == nil && iter >= 1000
}

// verifyPasswordKey：核对客户端算好的 PBKDF2 结果（32 字节）
func verifyPasswordKey(stored string, key []byte) bool {
	p := strings.Split(stored, "$")
	if len(p) != 4 || p[0] != "pbkdf2-sha256" {
		return false
	}
	want, err := base64.RawStdEncoding.DecodeString(p[3])
	return err == nil && subtle.ConstantTimeCompare(key, want) == 1
}

// 用一个固定的假哈希做比较，让「用户名不存在」和「密码错误」耗时一样
var dummyHash = hashPassword("huijian-dummy-password")

func (s *Store) OwnerID() int64 {
	var id int64
	s.db.QueryRow(`SELECT MIN(id) FROM users`).Scan(&id)
	return id
}

func (s *Store) AccountByID(id int64) (*Account, error) {
	a := &Account{}
	var ph, ah string
	var dis int
	err := s.db.QueryRow(`SELECT id,username,pass_hash,auth_hash,disabled,created_at FROM users WHERE id=?`, id).Scan(&a.ID, &a.Username, &ph, &ah, &dis, &a.Created)
	a.HasPassword, a.AuthKey, a.Disabled = ph != "" || ah != "", ah != "", dis != 0
	return a, err
}

func (s *Store) ListAccounts() ([]Account, error) {
	rows, err := s.db.Query(`SELECT u.id,u.username,(u.pass_hash!='' OR u.auth_hash!=''),u.disabled,u.created_at,
		(SELECT COUNT(*) FROM devices d WHERE d.user_id=u.id AND d.revoked=0),
		(SELECT COUNT(*) FROM messages m WHERE m.user_id=u.id),
		(SELECT COALESCE(MAX(max(COALESCE(d.last_seen,0),COALESCE(d.last_paired,0))),0) FROM devices d WHERE d.user_id=u.id),
		(SELECT COALESCE(SUM(length(CAST(m.text AS BLOB))+length(CAST(m.desp AS BLOB))+length(CAST(m.e2e AS BLOB))),0) FROM messages m WHERE m.user_id=u.id)
		 + (SELECT COALESCE(SUM(a.size),0) FROM attachments a JOIN messages m ON m.id=a.message_id WHERE m.user_id=u.id),
		EXISTS(SELECT 1 FROM e2e_keys k WHERE k.user_id=u.id AND k.active=1),
		(SELECT COUNT(*) FROM messages m WHERE m.user_id=u.id AND m.e2e='')
		FROM users u ORDER BY u.id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Account
	for rows.Next() {
		var a Account
		var hp, dis, enc int
		if err := rows.Scan(&a.ID, &a.Username, &hp, &dis, &a.Created, &a.Devices, &a.Messages,
			&a.LastActive, &a.Bytes, &enc, &a.Plain); err != nil {
			return nil, err
		}
		a.HasPassword, a.Disabled, a.Encrypted = hp != 0, dis != 0, enc != 0
		out = append(out, a)
	}
	return out, rows.Err()
}

// LogoutAccount：注销账号的全部登录——吊销所有设备 token（转交给设备的私钥副本一并删除），
// 没用过的配对码作废。返回吊销的设备数。账号、pushkey 和消息保留，用户用密码重新登录即可
func (s *Store) LogoutAccount(userID int64) (int, error) {
	rows, err := s.db.Query(`SELECT id FROM devices WHERE user_id=? AND revoked=0`, userID)
	if err != nil {
		return 0, err
	}
	var ids []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	n := 0
	for _, id := range ids {
		res, err := s.db.Exec(`UPDATE devices SET revoked=1 WHERE id=? AND user_id=? AND revoked=0`, id, userID)
		if err != nil {
			return n, err
		}
		if k, _ := res.RowsAffected(); k > 0 {
			s.dropDeviceWrap(userID, id)
			n++
		}
	}
	s.db.Exec(`DELETE FROM pair_codes WHERE user_id=? AND used=0`, userID)
	if n > 0 {
		s.settingsChanged(userID, changeDevices)
	}
	return n, nil
}

// RegisterInput：注册（0.9.0）——账号、加密钥匙、第一台设备一次建好
type RegisterInput struct {
	Username string
	Invite   string // 规范化后的邀请码；空表示不用（开放注册）
	E2E      E2ESetupInput
	Device   pairReq
}

// Register：一个事务里用掉邀请码、建账号（新登录协议）、写入账号公钥和锁住的私钥、把设备加入账号
func (s *Store) Register(in RegisterInput) (*Account, *Device, string, error) {
	username := normUsername(in.Username)
	tx, err := s.db.Begin()
	if err != nil {
		return nil, nil, "", err
	}
	defer tx.Rollback()
	// 检查顺序：邀请码 → 用户名格式 → 用户名占用（拿不到有效邀请码的人探不到用户名规则和占用情况）
	if in.Invite != "" {
		if err := consumeInvite(tx, in.Invite); err != nil {
			return nil, nil, "", err
		}
	}
	if !validUsername(username) {
		return nil, nil, "", errBadUsername
	}
	id, err := nextUserID(tx) // 删除过的账号 id 不复用
	if err != nil {
		return nil, nil, "", err
	}
	_, err = tx.Exec(`INSERT INTO users(id,name,created_at,username,username_key,pass_hash,auth_salt,auth_hash) VALUES(?,?,?,?,?,'',?,?)`,
		id, "u_"+randHex(8), now(), username, usernameKey(username), in.E2E.Salt, authHash(in.E2E.AuthKey))
	if isUniqueErr(err) {
		return nil, nil, "", errUsernameTaken
	}
	if err != nil {
		return nil, nil, "", err
	}
	if err := bumpUserHighWater(tx, id); err != nil {
		return nil, nil, "", err
	}
	if in.Invite != "" {
		if err := recordInvite(tx, in.Invite, id, username); err != nil {
			return nil, nil, "", err
		}
	}
	if _, err := tx.Exec(`INSERT INTO e2e_keys(user_id,kid,pub,created_at,active) VALUES(?,?,?,?,1)`,
		id, e2eKID(in.E2E.Pub), b64.EncodeToString(in.E2E.Pub), now()); err != nil {
		return nil, nil, "", err
	}
	for kind, blob := range map[string]string{wrapPassword: in.E2E.PasswordWrap, wrapRecovery: in.E2E.RecoveryWrap} {
		if blob == "" {
			continue
		}
		if err := putWrap(tx, id, kind, "", blob); err != nil {
			return nil, nil, "", err
		}
	}
	if err := bumpStats(tx, 0, 0, 1); err != nil {
		return nil, nil, "", err
	}
	dev := in.Device
	dev.UserID = id
	d, tok, _, err := attachDevice(tx, dev)
	if err != nil {
		return nil, nil, "", err
	}
	if err := tx.Commit(); err != nil {
		return nil, nil, "", err
	}
	s.markActive(id)
	a, err := s.AccountByID(id)
	return a, d, tok, err
}

// SetCredentials 设置 / 修改用户名和密码（password 为空表示只改用户名）
func (s *Store) SetCredentials(userID int64, username, password string) error {
	username = normUsername(username)
	if !validUsername(username) {
		return errBadUsername
	}
	if password != "" {
		if err := checkCredentials(username, password); err != nil {
			return err
		}
	}
	var err error
	if password != "" {
		// 用密码原文设置（管理后台重设、旧客户端）：新登录协议的凭证和用旧密码锁住的私钥副本作废，
		// 用户用新密码登录后靠恢复码或另一台设备解锁加密消息，客户端再重新升级
		var tx *sql.Tx
		if tx, err = s.db.Begin(); err == nil {
			defer tx.Rollback()
			if _, err = tx.Exec(`UPDATE users SET username=?, username_key=?, pass_hash=? WHERE id=?`, username, usernameKey(username), hashPassword(password), userID); err == nil {
				if err = s.dropPasswordWrap(tx, userID); err == nil {
					err = tx.Commit()
				}
			}
		}
	} else {
		_, err = s.db.Exec(`UPDATE users SET username=?, username_key=? WHERE id=?`, username, usernameKey(username), userID)
	}
	if isUniqueErr(err) {
		return errUsernameTaken
	}
	if err == nil {
		s.settingsChanged(userID, changeAccount)
	}
	return err
}

func (s *Store) SetAccountDisabled(userID int64, on bool) error {
	_, err := s.db.Exec(`UPDATE users SET disabled=? WHERE id=?`, b2i(on), userID)
	if err == nil {
		s.settingsChanged(userID, changeAccount)
	}
	return err
}

var errNeedNewClient = errors.New("这个账号已升级到新的登录方式（密码不再发给服务器），请把回笺更新到最新版")

// CheckLogin 校验用户名密码，返回账号 id
func (s *Store) CheckLogin(username, password string) (int64, error) {
	return s.CheckLoginAuth(username, loginCred{Password: password})
}

// loginCred：登录或核对当前密码时客户端给出的凭据，三选一
//   - AuthKey：新登录协议的凭证（Argon2id 派生，已升级的账号）
//   - PasswordKey：旧账号的 PBKDF2 结果（新客户端在本机按 /v1/prelogin 给的盐算好，不发密码原文）
//   - Password：密码原文（旧客户端）
type loginCred struct {
	Password    string
	AuthKey     []byte
	PasswordKey []byte
}

func (c loginCred) empty() bool { return c.Password == "" && c.AuthKey == nil && c.PasswordKey == nil }

// parseCred：解析请求里的凭据（base64url 32 字节）
func parseCred(password, authKey, passwordKey string) (loginCred, error) {
	ak, err := authKeyOf(authKey)
	if err != nil {
		return loginCred{}, err
	}
	pk, err := authKeyOf(passwordKey)
	if err != nil {
		return loginCred{}, errors.New("password_key 格式不对")
	}
	return loginCred{Password: password, AuthKey: ak, PasswordKey: pk}, nil
}

// CheckLoginAuth：按凭据种类校验。已升级的账号只接受登录凭证：服务端只存凭证的哈希，也不该再看到密码或它的 PBKDF2 结果
func (s *Store) CheckLoginAuth(username string, c loginCred) (int64, error) {
	var id int64
	var ph, ah string
	var dis int
	err := s.db.QueryRow(`SELECT id,pass_hash,auth_hash,disabled FROM users WHERE username_key=?`, usernameKey(username)).Scan(&id, &ph, &ah, &dis)
	switch {
	case err != nil || (ph == "" && ah == ""):
		if c.AuthKey == nil && c.PasswordKey == nil {
			verifyPassword(dummyHash, c.Password) // 和「密码错误」耗时一样
		}
		return 0, errBadLogin
	case c.AuthKey != nil:
		if !authKeyMatches(ah, c.AuthKey) {
			return 0, errBadLogin
		}
	case ah != "":
		return 0, errNeedNewClient
	case c.PasswordKey != nil:
		if !verifyPasswordKey(ph, c.PasswordKey) {
			return 0, errBadLogin
		}
	case !verifyPassword(ph, c.Password):
		return 0, errBadLogin
	}
	if dis != 0 {
		return 0, errDisabled
	}
	return id, nil
}

func (s *Store) AccountDisabled(userID int64) bool {
	var dis int
	s.db.QueryRow(`SELECT disabled FROM users WHERE id=?`, userID).Scan(&dis)
	return dis != 0
}

// ---------- 设备身份与配对记录 ----------

type pairReq struct {
	UserID      int64
	Name        string
	Platform    string
	Fingerprint string
	Method      string // code / password / register
	IP, Client  string
}

var reFingerprint = regexp.MustCompile(`^[0-9a-f]{32,128}$`)

// attachDevice：在事务里为账号创建设备，或按指纹复用原来的设备（换新 token），并记配对记录
func attachDevice(tx *sql.Tx, p pairReq) (*Device, string, bool, error) {
	token := "DT_" + randToken(32)
	at := now()
	if !reFingerprint.MatchString(p.Fingerprint) {
		p.Fingerprint = ""
	}
	d := &Device{UserID: p.UserID, Platform: p.Platform}
	reused := false
	if p.Fingerprint != "" {
		err := tx.QueryRow(`SELECT id,name,created_at FROM devices WHERE user_id=? AND fingerprint=? ORDER BY created_at DESC LIMIT 1`,
			p.UserID, p.Fingerprint).Scan(&d.ID, &d.Name, &d.Created)
		if err == nil {
			reused = true
			// can_admin 是 0.9.0 以前的设备级管理权限：复用旧记录时清掉（0.9.0 起没有设备能进入管理后台）
			if _, err := tx.Exec(`UPDATE devices SET token_hash=?, revoked=0, platform=?, can_admin=0, pair_count=pair_count+1, last_paired=?, client=? WHERE id=?`,
				sha256Hex(token), p.Platform, at, p.Client, d.ID); err != nil {
				return nil, "", false, err
			}
		} else if !errors.Is(err, sql.ErrNoRows) {
			return nil, "", false, err
		}
	}
	if !reused {
		d.Name, d.Created = p.Name, at
		for i := 0; ; i++ { // ID 由时间戳 + 随机后缀组成，同一秒内撞上的概率极低，撞上就重试
			d.ID = newDeviceID()
			_, err := tx.Exec(`INSERT INTO devices(id,user_id,name,platform,token_hash,created_at,fingerprint,last_paired,client) VALUES(?,?,?,?,?,?,?,?,?)`,
				d.ID, d.UserID, d.Name, d.Platform, sha256Hex(token), d.Created, p.Fingerprint, at, p.Client)
			if err == nil {
				break
			}
			if !isUniqueErr(err) || i >= 4 {
				return nil, "", false, err
			}
		}
	}
	if _, err := tx.Exec(`INSERT INTO device_pairings(device_id,user_id,at,ip,method,client) VALUES(?,?,?,?,?,?)`,
		d.ID, p.UserID, at, p.IP, p.Method, p.Client); err != nil {
		return nil, "", false, err
	}
	return d, token, reused, nil
}

// LoginDevice：密码登录 / 注册后把设备加入账号
func (s *Store) LoginDevice(p pairReq) (*Device, string, bool, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, "", false, err
	}
	defer tx.Rollback()
	d, tok, reused, err := attachDevice(tx, p)
	if err != nil {
		return nil, "", false, err
	}
	if err := tx.Commit(); err != nil {
		return nil, "", false, err
	}
	s.settingsChanged(p.UserID, changeDevices)
	s.markActive(p.UserID) // 登录 / 配对也算当天活跃
	return d, tok, reused, nil
}

type Pairing struct {
	At     int64
	IP     string
	Method string
	Client string
}

func (p Pairing) MethodLabel() string {
	return map[string]string{"code": "配对码", "password": "密码登录", "register": "注册"}[p.Method]
}

func (s *Store) Pairings(deviceID string, limit int) []Pairing {
	rows, err := s.db.Query(`SELECT at,ip,method,client FROM device_pairings WHERE device_id=? ORDER BY id DESC LIMIT ?`, deviceID, limit)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []Pairing
	for rows.Next() {
		var p Pairing
		if rows.Scan(&p.At, &p.IP, &p.Method, &p.Client) == nil {
			out = append(out, p)
		}
	}
	return out
}

// ---------- 按设备接收规则 ----------

const (
	modeNotify = "notify"
	modeSilent = "silent"
	modeOff    = "off"
)

func (s *Store) DeviceKeyModes(deviceID string) map[int64]string {
	out := map[int64]string{}
	rows, err := s.db.Query(`SELECT pushkey_id,mode FROM device_keys WHERE device_id=?`, deviceID)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var m string
		if rows.Scan(&id, &m) == nil {
			out[id] = m
		}
	}
	return out
}

func (s *Store) SetDeviceKeyMode(deviceID string, keyID int64, mode string) error {
	var err error
	if mode == modeNotify {
		_, err = s.db.Exec(`DELETE FROM device_keys WHERE device_id=? AND pushkey_id=?`, deviceID, keyID)
	} else {
		_, err = s.db.Exec(`INSERT INTO device_keys(device_id,pushkey_id,mode) VALUES(?,?,?)
		ON CONFLICT(device_id,pushkey_id) DO UPDATE SET mode=excluded.mode`, deviceID, keyID, mode)
	}
	return err
}

func (s *Store) SetAwaySilent(deviceID string, on bool) error {
	_, err := s.db.Exec(`UPDATE devices SET away_silent=? WHERE id=?`, b2i(on), deviceID)
	return err
}

// ---------- 在用设备 ----------

type presence struct {
	mu   sync.Mutex
	last map[string]presenceMark // device_id → 最近一次「有人在用」
}

type presenceMark struct {
	user int64
	at   time.Time
}

const presenceWindow = 90 * time.Second

func (p *presence) mark(userID int64, deviceID string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.last == nil {
		p.last = map[string]presenceMark{}
	}
	p.last[deviceID] = presenceMark{userID, time.Now()}
	for k, v := range p.last { // 顺手清理过期的
		if time.Since(v.at) > 10*time.Minute {
			delete(p.last, k)
		}
	}
}

// activeElsewhere：同账号除 deviceID 以外，是否有设备最近有人在用
func (p *presence) activeElsewhere(userID int64, deviceID string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	for k, v := range p.last {
		if k != deviceID && v.user == userID && time.Since(v.at) < presenceWindow {
			return true
		}
	}
	return false
}

// activeHere：这台设备自己最近是否有人在用
func (p *presence) activeHere(deviceID string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	v, ok := p.last[deviceID]
	return ok && time.Since(v.at) < presenceWindow
}

// decorate：按设备的接收规则和在用设备，给消息标上 silent
func (h *Hub) decorate(d *Device, msgs []Message) {
	if len(msgs) == 0 {
		return
	}
	modes := h.st.DeviceKeyModes(d.ID)
	// 本机自己也有人在用时不静默（例如两台 Mac 同时在用，不能两边都不响）
	away := d.AwaySilent && !h.presence.activeHere(d.ID) && h.presence.activeElsewhere(d.UserID, d.ID)
	hidden, muted := h.st.channelFlags(d.UserID)
	for i := range msgs {
		m := &msgs[i]
		switch {
		case hidden[m.Topic]: // 隐藏的频道：紧急消息也不提醒
			m.Silent, m.SilentReason = true, "channel_hidden"
		case m.Priority >= 5:
		case muted[m.Topic]:
			m.Silent, m.SilentReason = true, "channel_muted"
		case modes[m.PushkeyID] == modeSilent:
			m.Silent, m.SilentReason = true, "key"
		case away:
			m.Silent, m.SilentReason = true, "active_elsewhere"
		}
	}
}

// ---------- 设备端接口 ----------

// registerOpen：开放注册（旧字段 register_open；需要邀请码时为 false，客户端看 /v1/info 的 register）
func (h *Hub) registerOpen() bool { return h.st.RegisterMode() == regOpen }

type loginBody struct {
	Username, Password, Name, Platform, Fingerprint string
	// 新登录协议（0.7.0 起）：auth_key 是客户端用 Argon2id 从密码派生的登录凭证（base64url，32 字节）；
	// 注册时还要带 auth_salt（客户端随机生成的盐，十六进制）
	AuthKey  string `json:"auth_key"`
	AuthSalt string `json:"auth_salt"`
	// 注册时的邀请码（0.9.0，注册模式为 invite 时必填）
	InviteCode string `json:"invite_code"`
	// 注册时一起开启端到端加密（0.9.0 起必填，格式同 /v1/e2e/setup）：账号公钥、用密码锁住的私钥、可选的恢复码副本
	Pub          string `json:"pub"`
	PasswordWrap string `json:"password_wrap"`
	RecoveryWrap string `json:"recovery_wrap"`
	// 旧账号用新客户端登录：PBKDF2(密码, prelogin 给的盐, 轮数) 的 32 字节结果（base64url），代替密码原文
	PasswordKey string `json:"password_key"`
}

// authKeyOf：解析请求里的登录凭证；没带时返回 nil
func authKeyOf(s string) ([]byte, error) {
	if s == "" {
		return nil, nil
	}
	b, err := b64.DecodeString(s)
	if err != nil || len(b) != 32 {
		return nil, errors.New("登录凭证格式不对")
	}
	return b, nil
}

func validSalt(s string) bool {
	b, err := hex.DecodeString(s)
	return err == nil && len(b) == 16
}

func (h *Hub) readLogin(w http.ResponseWriter, r *http.Request) (*loginBody, bool) {
	if !h.acctLimit.Allow("ip:" + h.realIP(r)) {
		apiErr(w, 429, "尝试太频繁，请稍后再试")
		return nil, false
	}
	var in loginBody
	if !readJSON(w, r, &in) {
		return nil, false
	}
	in.Name = cleanLabel(in.Name, 64)
	if in.Name == "" {
		in.Name = "未命名设备"
	}
	in.Platform = cleanLabel(in.Platform, 16)
	if in.Platform == "" {
		in.Platform = "unknown"
	}
	return &in, true
}

func (h *Hub) finishLogin(w http.ResponseWriter, r *http.Request, in *loginBody, userID int64, method string) {
	d, tok, reused, err := h.st.LoginDevice(pairReq{UserID: userID, Name: in.Name, Platform: in.Platform, Fingerprint: in.Fingerprint,
		Method: method, IP: h.realIP(r), Client: clientLabel(clientHeader(r.Header, "Client"))})
	if err != nil {
		apiErr(w, 500, "登录失败")
		return
	}
	log.Printf("设备%s: %s (%s) 账号 #%d，方式 %s", map[bool]string{true: "重新登录", false: "登录"}[reused], d.ID, d.Name, userID, method)
	resp := map[string]any{"device_id": d.ID, "name": d.Name, "token": tok, "reused": reused}
	if in.AuthKey != "" { // 用登录凭证登录（已核对）：一并返回加密钥匙的状态和用密码锁住的私钥，客户端马上解锁
		resp["e2e"] = h.e2eLoginInfo(userID)
	}
	writeJSON(w, 200, resp)
}

// POST /v1/login {username, password, name, platform, fingerprint}
func (h *Hub) handleLogin(w http.ResponseWriter, r *http.Request) {
	in, ok := h.readLogin(w, r)
	if !ok {
		return
	}
	// 按「用户名 + 来源 IP」限速：别人在另一个 IP 上猜密码，锁不住主人自己的登录
	if !h.acctLimit.Allow("user:" + usernameKey(in.Username) + "|" + h.realIP(r)) {
		apiErr(w, 429, "这个账号尝试太频繁，请稍后再试")
		return
	}
	cred, err := parseCred(in.Password, in.AuthKey, in.PasswordKey)
	if err != nil {
		apiErr(w, 400, err.Error())
		return
	}
	uid, err := h.st.CheckLoginAuth(in.Username, cred)
	if err != nil {
		time.Sleep(300 * time.Millisecond)
		code := 403
		if errors.Is(err, errNeedNewClient) {
			code = 426
		}
		apiErr(w, code, err.Error())
		return
	}
	h.finishLogin(w, r, in, uid, "password")
}

var errRegisterOldClient = errors.New("请更新回笺客户端后注册（新版注册时同时开启端到端加密）")

// POST /v1/register（0.9.0 起，功能 id register.e2e）：注册即登录、注册即开启加密。
// 请求体同 /v1/login 的新协议（auth_key + auth_salt），另外必带 pub、password_wrap（recovery_wrap 可选），
// 在一个事务里：用掉邀请码、建账号、存账号公钥和锁住的私钥、把这台设备加入账号。账号从诞生起就有钥匙，服务器从头到尾拿不到密码。
// 旧客户端（发密码原文、或不带加密字段）返回 400「请更新回笺客户端后注册」，什么都不建
func (h *Hub) handleRegister(w http.ResponseWriter, r *http.Request) {
	in, ok := h.readLogin(w, r)
	if !ok {
		return
	}
	invite := ""
	switch h.st.RegisterMode() {
	case regOpen:
	case regInvite:
		// 邀请码按来源 IP 限速，防止穷举（和配对码共用一个限速器，每个 IP 每分钟 10 次）
		if !h.pairLimit.Allow("invite:" + h.realIP(r)) {
			apiErr(w, 429, "尝试太频繁，请稍后再试")
			return
		}
		if invite = normInvite(in.InviteCode); invite == "" {
			apiErr(w, 403, errInviteMissing.Error())
			return
		}
	default:
		apiErr(w, 403, "这个服务器没有开放注册，请联系管理员")
		return
	}
	if in.AuthKey == "" || in.Pub == "" || in.PasswordWrap == "" {
		apiErr(w, 400, errRegisterOldClient.Error())
		return
	}
	ak, err := authKeyOf(in.AuthKey)
	if err != nil {
		apiErr(w, 400, err.Error())
		return
	}
	if !validSalt(in.AuthSalt) {
		apiErr(w, 400, "auth_salt 格式不对（16 字节十六进制）")
		return
	}
	pub, err := b64.DecodeString(in.Pub)
	if err != nil || len(pub) != 32 {
		apiErr(w, 400, "公钥格式不对")
		return
	}
	if !e2eValidWrap("hjp1", in.PasswordWrap, 4096) {
		apiErr(w, 400, "password_wrap 格式不对（hjp1.…）")
		return
	}
	if in.RecoveryWrap != "" && !e2eValidWrap("hjr1", in.RecoveryWrap, 4096) {
		apiErr(w, 400, "recovery_wrap 格式不对（hjr1.…）")
		return
	}
	a, d, tok, err := h.st.Register(RegisterInput{Username: in.Username, Invite: invite,
		E2E: E2ESetupInput{Salt: in.AuthSalt, AuthKey: ak, Pub: pub, PasswordWrap: in.PasswordWrap, RecoveryWrap: in.RecoveryWrap},
		Device: pairReq{Name: in.Name, Platform: in.Platform, Fingerprint: in.Fingerprint, Method: "register",
			IP: h.realIP(r), Client: clientLabel(clientHeader(r.Header, "Client"))}})
	if err != nil {
		code := 400
		if isInviteErr(err) {
			time.Sleep(300 * time.Millisecond)
			code = 403
		} else if errors.Is(err, errUsernameTaken) {
			code = 409
		} else if !errors.Is(err, errBadUsername) {
			code = 500
			log.Printf("注册失败：%v", err)
		}
		msg := err.Error()
		if code == 500 {
			msg = "注册失败"
		}
		apiErr(w, code, msg)
		return
	}
	log.Printf("新账号注册: #%d %s（设备 %s，已开启加密）", a.ID, a.Username, d.ID)
	writeJSON(w, 200, map[string]any{"device_id": d.ID, "name": d.Name, "token": tok, "reused": false,
		"e2e": h.e2eLoginInfo(a.ID)})
}

// POST /v1/logout：注销本机（token 立即失效；设备记录保留，下次登录按指纹复用）
func (h *Hub) handleLogout(w http.ResponseWriter, r *http.Request, d *Device) {
	h.st.RevokeDevice(d.UserID, d.ID)
	writeJSON(w, 200, map[string]any{"ok": true})
}

type deviceJSON struct {
	ID         string        `json:"id"`
	Name       string        `json:"name"`
	Platform   string        `json:"platform"`
	Client     string        `json:"client"`
	Created    int64         `json:"created_at"`
	LastSeen   *int64        `json:"last_seen"`
	LastPaired int64         `json:"last_paired"`
	PairCount  int           `json:"pair_count"`
	Revoked    bool          `json:"revoked"`
	Current    bool          `json:"current"`
	Online     bool          `json:"online"`
	Pairings   []pairingJSON `json:"pairings"`
}

type pairingJSON struct {
	At     int64  `json:"at"`
	IP     string `json:"ip"`
	Method string `json:"method"`
	Client string `json:"client"`
}

func (h *Hub) accountJSON(d *Device) map[string]any {
	a, _ := h.st.AccountByID(d.UserID)
	return map[string]any{"id": a.ID, "username": a.Username, "has_password": a.HasPassword}
}

// GET /v1/account：账号信息 + 本账号的设备和配对记录
func (h *Hub) handleAccount(w http.ResponseWriter, r *http.Request, d *Device) {
	devs, err := h.st.ListDevices(d.UserID)
	if err != nil {
		// 不能返回空列表：客户端会以为本机已被移除
		apiErr(w, 500, "查询设备失败")
		return
	}
	online := h.br.Online(d.UserID)
	out := []deviceJSON{}
	for _, x := range devs {
		j := deviceJSON{ID: x.ID, Name: x.Name, Platform: x.Platform, Client: x.Client, Created: x.Created,
			LastPaired: x.LastPaired, PairCount: x.PairCount, Revoked: x.Revoked, Current: x.ID == d.ID, Online: online[x.ID] > 0,
			Pairings: []pairingJSON{}}
		if x.LastSeen.Valid {
			v := x.LastSeen.Int64
			j.LastSeen = &v
		}
		for _, p := range h.st.Pairings(x.ID, 20) {
			j.Pairings = append(j.Pairings, pairingJSON{p.At, p.IP, p.Method, p.Client})
		}
		out = append(out, j)
	}
	writeJSON(w, 200, map[string]any{"account": h.accountJSON(d), "devices": out, "register_open": h.registerOpen()})
}

// POST /v1/account/credentials {username, password, current_password}
// 账号还没有密码时，本账号的任何设备都可以设置；已有密码时修改需要提供当前密码。
func (h *Hub) handleCredentials(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct {
		Username, Password, Current_Password string
		CurrentAuthKey                       string `json:"current_auth_key"`     // 已升级到新登录协议的账号用它核对
		CurrentPasswordKey                   string `json:"current_password_key"` // 旧账号、新客户端：PBKDF2 结果代替密码原文
	}
	if !readJSON(w, r, &in) {
		return
	}
	a, err := h.st.AccountByID(d.UserID)
	if err != nil {
		apiErr(w, 500, "查询失败")
		return
	}
	if a.AuthKey && in.Password != "" {
		// 已升级的账号改密码要走 PUT /v1/account/auth（客户端派生新凭证、重新锁私钥）；这里用原文改会让加密钥匙失去密码副本
		apiErr(w, 426, errNeedNewClient.Error())
		return
	}
	// 还没有密码（升级前的第一个账号）：本账号的任何设备都可以设置初始密码；已有密码时一律要核对当前密码
	if a.HasPassword && !h.checkCurrent(w, a, in.Current_Password, in.CurrentAuthKey, in.CurrentPasswordKey) {
		return
	}
	if !a.HasPassword && in.Password == "" {
		apiErr(w, 400, "请设置密码（"+passwordRule+"）")
		return
	}
	if err := h.st.SetCredentials(d.UserID, in.Username, in.Password); err != nil {
		code := 400
		if errors.Is(err, errUsernameTaken) {
			code = 409
		}
		apiErr(w, code, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"account": h.accountJSON(d)})
}

// pairCodeTTL 配对码有效期（只能用一次）。短一些更安全：配对码是在旁边的设备上马上输入的
const pairCodeTTL = 3 * time.Minute

// POST /v1/pair-codes：为本账号生成配对码（新设备输入后直接进入本账号，不带管理权限）
func (h *Hub) handleCreatePairCode(w http.ResponseWriter, r *http.Request, d *Device) {
	// 限速 + 每个账号同时最多 5 个有效配对码（6 位码空间有限，不能让人刷满）
	if !h.acctLimit.Allow("pc:" + strconv.FormatInt(d.UserID, 10)) {
		apiErr(w, 429, "生成太频繁，请稍后再试")
		return
	}
	if h.st.ActivePairCodes(d.UserID) >= 5 {
		apiErr(w, 429, "这个账号已有 5 个未使用的配对码，请先用掉或等它们过期（3 分钟）")
		return
	}
	// 0.10.0：可带 key_wrap（e2ee-client.md §12）；旧客户端不带请求体
	var in struct {
		KeyWrap string `json:"key_wrap"`
	}
	if body, _ := io.ReadAll(io.LimitReader(r.Body, 2048)); len(strings.TrimSpace(string(body))) > 0 {
		if err := json.Unmarshal(body, &in); err != nil {
			apiErr(w, 400, "JSON 解析失败")
			return
		}
	}
	if in.KeyWrap != "" && !validPairKeyWrap(in.KeyWrap) {
		apiErr(w, 400, "key_wrap 格式不对")
		return
	}
	code, err := h.st.CreatePairCode(d.UserID, pairCodeTTL, d.ID, in.KeyWrap)
	if err != nil {
		apiErr(w, 500, "生成失败")
		return
	}
	writeJSON(w, 200, map[string]any{"code": code, "expires_in": int(pairCodeTTL.Seconds())})
}

// validPairKeyWrap：hjc1.<base64url>，解开后是 12 字节 nonce + 32 字节私钥 + 16 字节标签
func validPairKeyWrap(s string) bool {
	rest, ok := strings.CutPrefix(s, "hjc1.")
	if !ok || len(s) > 256 {
		return false
	}
	raw, err := b64.DecodeString(rest)
	return err == nil && len(raw) == 12+32+16
}

// GET /v1/pair-codes/{code}：配对码状态，生成它的客户端用来显示倒计时和「已被某台设备使用」（0.5.6 起）
func (h *Hub) handlePairCodeStatus(w http.ResponseWriter, r *http.Request, d *Device) {
	state, left, usedBy, usedAt, err := h.st.PairCodeStatus(d.UserID, r.PathValue("code"))
	if err != nil {
		apiErr(w, 404, "配对码不存在")
		return
	}
	out := map[string]any{"state": state, "expires_in": left}
	if state == "used" {
		out["used_by"], out["used_at"] = usedBy, time.Unix(usedAt, 0).UTC().Format(time.RFC3339)
	}
	writeJSON(w, 200, out)
}

// POST /v1/devices/{id}/revoke：移除本账号的另一台设备
func (h *Hub) handleRevokeOwnDevice(w http.ResponseWriter, r *http.Request, d *Device) {
	id := r.PathValue("id")
	// 0.9.0 起管理权限按账号，同一账号的设备权限相同，不再区分
	res, err := h.st.db.Exec(`UPDATE devices SET revoked=1 WHERE id=? AND user_id=? AND revoked=0`, id, d.UserID)
	if err != nil {
		apiErr(w, 500, "操作失败")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		var revoked int
		if err := h.st.db.QueryRow(`SELECT revoked FROM devices WHERE id=? AND user_id=?`, id, d.UserID).Scan(&revoked); err != nil {
			apiErr(w, 404, "设备不存在")
		} else { // 已经移除过：幂等返回成功，不再记变更
			writeJSON(w, 200, map[string]any{"ok": true})
		}
		return
	}
	h.st.dropDeviceWrap(d.UserID, id) // 转交给它的私钥副本一并删除
	h.st.expireDevicePairCodes(d.UserID, id)
	h.st.settingsChanged(d.UserID, changeDevices)
	writeJSON(w, 200, map[string]any{"ok": true})
}

// GET /v1/subscriptions：本机对每把 pushkey 的接收方式
func (h *Hub) handleSubscriptions(w http.ResponseWriter, r *http.Request, d *Device) {
	keys, _ := h.st.ListPushkeys(d.UserID)
	modes := h.st.DeviceKeyModes(d.ID)
	out := []map[string]any{}
	for _, k := range keys {
		if k.Revoked {
			continue
		}
		m := modes[k.ID]
		if m == "" {
			m = modeNotify
		}
		out = append(out, map[string]any{"pushkey_id": k.ID, "name": k.Name, "mode": m})
	}
	writeJSON(w, 200, map[string]any{"subscriptions": out, "away_silent": d.AwaySilent})
}

// PUT /v1/subscriptions/{id} {"mode": "notify"|"silent"|"off"}
func (h *Hub) handleSetSubscription(w http.ResponseWriter, r *http.Request, d *Device) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	var in struct{ Mode string }
	if !readJSON(w, r, &in) {
		return
	}
	if in.Mode != modeNotify && in.Mode != modeSilent && in.Mode != modeOff {
		apiErr(w, 400, "mode 只能是 notify / silent / off")
		return
	}
	if _, err := h.st.PushkeyByID(d.UserID, id); err != nil {
		apiErr(w, 404, "pushkey 不存在")
		return
	}
	if err := h.st.SetDeviceKeyMode(d.ID, id, in.Mode); err != nil {
		apiErr(w, 500, "保存失败")
		return
	}
	writeJSON(w, 200, map[string]any{"pushkey_id": id, "mode": in.Mode})
}

// POST /v1/presence：客户端在有人使用时每 30 秒上报一次
func (h *Hub) handlePresence(w http.ResponseWriter, r *http.Request, d *Device) {
	h.presence.mark(d.UserID, d.ID)
	w.WriteHeader(http.StatusNoContent)
}

// ActivePairCodes 账号当前未使用、未过期的配对码数量
func (s *Store) ActivePairCodes(userID int64) int {
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM pair_codes WHERE user_id=? AND used=0 AND expires_at>=?`, userID, now()).Scan(&n)
	return n
}

// BackfillFingerprint：0.4.x 配对的设备没有指纹，客户端升级后在请求头里带上，补写进去，
// 之后退出再登录就能沿用这条记录（同账号已有记录用了这个指纹时不补，避免冲突）
func (s *Store) BackfillFingerprint(d *Device, fp string) {
	if !reFingerprint.MatchString(fp) {
		return
	}
	s.db.Exec(`UPDATE devices SET fingerprint=? WHERE id=? AND fingerprint=''
		AND NOT EXISTS (SELECT 1 FROM devices x WHERE x.user_id=? AND x.fingerprint=?)`, fp, d.ID, d.UserID, fp)
}

// DeviceActive：设备没被吊销、账号没被停用（SSE 长连接每次推送前复查）
func (s *Store) DeviceActive(id string) bool {
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM devices d JOIN users u ON u.id=d.user_id WHERE d.id=? AND d.revoked=0 AND u.disabled=0`, id).Scan(&n)
	return n > 0
}

// MaxMessageID 账号当前最大的消息 id（长轮询推进游标用：设为「不接收」的消息也算扫过）
func (s *Store) MaxMessageID(userID int64) int64 {
	var id sql.NullInt64
	s.db.QueryRow(`SELECT MAX(id) FROM messages WHERE user_id=?`, userID).Scan(&id)
	return id.Int64
}
