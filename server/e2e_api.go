package main

// 端到端加密的接口（docs/e2ee.md、docs/api.md「端到端加密」）。服务端只转存公钥、锁住的私钥副本和密文。

import (
	"encoding/hex"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
)

func (h *Hub) registerE2ERoutes(m *http.ServeMux) {
	m.HandleFunc("GET /v1/prelogin", h.handlePrelogin)
	m.HandleFunc("GET /v1/e2e", h.deviceAuth(h.handleE2EState))
	m.HandleFunc("POST /v1/e2e/setup", h.deviceAuth(h.handleE2ESetup))
	m.HandleFunc("POST /v1/e2e/unlock", h.deviceAuth(h.handleE2EUnlock))
	m.HandleFunc("PUT /v1/e2e/device", h.deviceAuth(h.handleE2EDevice))
	m.HandleFunc("POST /v1/e2e/challenge", h.deviceAuth(h.handleE2EChallenge))
	m.HandleFunc("POST /v1/e2e/reveal", h.deviceAuth(h.handleE2EReveal))
	m.HandleFunc("POST /v1/e2e/grant", h.deviceAuth(h.handleE2EGrant))
	m.HandleFunc("POST /v1/e2e/deny", h.deviceAuth(h.handleE2EDeny))
	m.HandleFunc("PUT /v1/e2e/recovery", h.deviceAuth(h.handleE2ERecovery))
	m.HandleFunc("PATCH /v1/e2e", h.deviceAuth(h.handleE2EUpdate))
	m.HandleFunc("POST /v1/e2e/delete-plain", h.deviceAuth(h.handleE2EDeletePlain))
	m.HandleFunc("PUT /v1/account/auth", h.deviceAuth(h.handleAccountAuth))
}

// GET /v1/prelogin?username=… → 登录前取密码派生参数。
// kdf=argon2id：按新协议派生登录凭证；kdf=pbkdf2-sha256：还没升级的旧账号，客户端在本机算 PBKDF2，发 password_key（不发密码原文），
// 登录后客户端再升级。账号不存在时返回由用户名算出的固定假盐（注册时「用户名已被占用」本来就会暴露账号是否存在，这里只是不额外给出答案）。
// 客户端必须固定参数下限（Argon2id 3 轮 / 64 MiB；PBKDF2 不少于 600000 轮），并且记住某账号已经升级过，之后不再接受 pbkdf2：
// 防止被攻破的服务器用弱参数或「降级」骗出可以快速破解的派生值
func (h *Hub) handlePrelogin(w http.ResponseWriter, r *http.Request) {
	if !h.acctLimit.Allow("pre:" + h.realIP(r)) {
		apiErr(w, 429, "尝试太频繁，请稍后再试")
		return
	}
	u := r.URL.Query().Get("username")
	var id int64
	var ph, salt string
	err := h.st.db.QueryRow(`SELECT id, pass_hash, auth_salt FROM users WHERE username_key=?`, usernameKey(u)).Scan(&id, &ph, &salt)
	if err == nil && salt == "" && ph != "" {
		if ps, iter, ok := pbkdfParams(ph); ok {
			writeJSON(w, 200, map[string]any{"kdf": "pbkdf2-sha256", "salt": hex.EncodeToString(ps), "iterations": iter})
			return
		}
	}
	if err != nil || salt == "" {
		salt = h.st.fakeAuthSalt(u)
	}
	writeJSON(w, 200, map[string]any{"kdf": "argon2id", "salt": salt,
		"time": e2eArgonTime, "memory_kib": e2eArgonMemKiB, "lanes": e2eArgonLanes})
}

// e2eLoginInfo：用登录凭证登录成功后一并返回，客户端马上就能解锁私钥（不用再请求一次）
func (h *Hub) e2eLoginInfo(userID int64) map[string]any {
	return map[string]any{"enabled": h.st.E2EEnabled(userID), "keys": h.st.E2EKeys(userID),
		"password_wrap": h.st.Wrap(userID, wrapPassword, "")}
}

type e2eDeviceInfo struct {
	Pub       string `json:"pub"`
	Grant     string `json:"grant"`
	Requested bool   `json:"requested"`
	Challenge string `json:"challenge"` // 批准设备给的 na：看到后揭晓 nb，再显示核对码
	Revealed  bool   `json:"revealed"`
}

func (h *Hub) deviceE2E(d *Device) e2eDeviceInfo {
	var x e2eDeviceInfo
	var req int64
	var nb string
	h.st.db.QueryRow(`SELECT e2e_pub, e2e_req, e2e_na, e2e_nb FROM devices WHERE id=?`, d.ID).Scan(&x.Pub, &req, &x.Challenge, &nb)
	x.Revealed = nb != ""
	x.Requested = req > 0
	x.Grant = h.st.Wrap(d.UserID, wrapDevice, d.ID)
	return x
}

// GET /v1/e2e：本账号的加密状态（公钥、本机的转交副本、恢复码副本、等待批准的设备）
func (h *Hub) handleE2EState(w http.ResponseWriter, r *http.Request, d *Device) {
	a, err := h.st.AccountByID(d.UserID)
	if err != nil {
		apiErr(w, 500, "查询失败")
		return
	}
	var reqs []E2ERequest
	for _, q := range h.st.PendingE2ERequests(d.UserID) {
		if q.DeviceID != d.ID {
			reqs = append(reqs, q)
		}
	}
	keys := h.st.E2EKeys(d.UserID)
	if keys == nil {
		keys = []E2EKey{}
	}
	if reqs == nil {
		reqs = []E2ERequest{}
	}
	writeJSON(w, 200, map[string]any{
		"enabled":           len(keys) > 0,
		"keys":              keys,
		"e2e_only":          h.st.E2EOnly(d.UserID),
		"auth_key":          a.AuthKey,
		"has_password_wrap": h.st.HasWrap(d.UserID, wrapPassword),
		"recovery_wrap":     h.st.Wrap(d.UserID, wrapRecovery, ""),
		"device":            h.deviceE2E(d),
		"requests":          reqs,
	})
}

// checkCurrent：敏感操作前核对当前密码（旧账号：PBKDF2 结果或密码原文；已升级：登录凭证）。失败时已写好响应
func (h *Hub) checkCurrent(w http.ResponseWriter, a *Account, password, authKey, passwordKey string) bool {
	if !h.acctLimit.Allow("cred:" + strconv.FormatInt(a.ID, 10)) {
		apiErr(w, 429, "尝试太频繁，请稍后再试")
		return false
	}
	cred, err := parseCred(password, authKey, passwordKey)
	if err != nil {
		apiErr(w, 400, err.Error())
		return false
	}
	if a.AuthKey && cred.AuthKey == nil {
		apiErr(w, 426, errNeedNewClient.Error())
		return false
	}
	if cred.empty() {
		apiErr(w, 403, "请输入当前密码")
		return false
	}
	if _, err := h.st.CheckLoginAuth(a.Username, cred); err != nil {
		time.Sleep(300 * time.Millisecond)
		apiErr(w, 403, "当前密码不对")
		return false
	}
	return true
}

type authChange struct {
	CurrentPassword    string `json:"current_password"`
	CurrentAuthKey     string `json:"current_auth_key"`
	CurrentPasswordKey string `json:"current_password_key"`
	AuthSalt           string `json:"auth_salt"`
	AuthKey            string `json:"auth_key"`
	PasswordWrap       string `json:"password_wrap"`
}

// readAuthChange：解析新的盐、登录凭证和（可选的）密码副本
func readAuthChange(w http.ResponseWriter, in *authChange, needWrap bool) ([]byte, bool) {
	ak, err := authKeyOf(in.AuthKey)
	if err != nil || ak == nil {
		apiErr(w, 400, "缺少新的登录凭证 auth_key")
		return nil, false
	}
	if !validSalt(in.AuthSalt) {
		apiErr(w, 400, "auth_salt 格式不对（16 字节十六进制）")
		return nil, false
	}
	if needWrap && !e2eValidWrap("hjp1", in.PasswordWrap, 4096) {
		apiErr(w, 400, "缺少用新密码锁住的私钥 password_wrap（hjp1.…）")
		return nil, false
	}
	if !needWrap && in.PasswordWrap != "" && !e2eValidWrap("hjp1", in.PasswordWrap, 4096) {
		apiErr(w, 400, "password_wrap 格式不对")
		return nil, false
	}
	return ak, true
}

// POST /v1/e2e/setup：开启端到端加密（同时升级到新登录协议）
func (h *Hub) handleE2ESetup(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct {
		authChange
		Pub          string `json:"pub"`
		RecoveryWrap string `json:"recovery_wrap"`
	}
	if !readJSON(w, r, &in) {
		return
	}
	a, err := h.st.AccountByID(d.UserID)
	if err != nil {
		apiErr(w, 500, "查询失败")
		return
	}
	if !a.HasPassword {
		apiErr(w, 400, "请先设置用户名和密码，再开启加密")
		return
	}
	if h.st.E2EEnabled(d.UserID) {
		apiErr(w, 409, errE2EEnabled.Error())
		return
	}
	pub, err := b64.DecodeString(in.Pub)
	if err != nil || len(pub) != 32 {
		apiErr(w, 400, "公钥格式不对")
		return
	}
	ak, ok := readAuthChange(w, &in.authChange, true)
	if !ok {
		return
	}
	if !e2eValidWrap("hjr1", in.RecoveryWrap, 4096) {
		apiErr(w, 400, "缺少用恢复码锁住的私钥 recovery_wrap（hjr1.…）")
		return
	}
	if !h.checkCurrent(w, a, in.CurrentPassword, in.CurrentAuthKey, in.CurrentPasswordKey) {
		return
	}
	kid, err := h.st.SetupE2E(d.UserID, E2ESetupInput{Salt: in.AuthSalt, AuthKey: ak, Pub: pub,
		PasswordWrap: in.PasswordWrap, RecoveryWrap: in.RecoveryWrap, DeviceID: d.ID})
	if errors.Is(err, errE2EEnabled) {
		apiErr(w, 409, err.Error())
		return
	}
	if err != nil {
		log.Printf("开启加密失败（账号 #%d）：%v", d.UserID, err)
		apiErr(w, 500, "开启加密失败")
		return
	}
	log.Printf("账号 #%d 开启端到端加密（钥匙 %s，设备 %s）", d.UserID, kid, d.ID)
	writeJSON(w, 200, map[string]any{"kid": kid})
}

// PUT /v1/account/auth：升级到新登录协议 / 修改密码。已开启加密时必须同时提交用新密码锁住的私钥
func (h *Hub) handleAccountAuth(w http.ResponseWriter, r *http.Request, d *Device) {
	var in authChange
	if !readJSON(w, r, &in) {
		return
	}
	a, err := h.st.AccountByID(d.UserID)
	if err != nil {
		apiErr(w, 500, "查询失败")
		return
	}
	if !a.HasPassword {
		apiErr(w, 400, "这个账号还没有密码")
		return
	}
	ak, ok := readAuthChange(w, &in, h.st.E2EEnabled(d.UserID))
	if !ok {
		return
	}
	if !h.checkCurrent(w, a, in.CurrentPassword, in.CurrentAuthKey, in.CurrentPasswordKey) {
		return
	}
	if err := h.st.SetPasswordAuth(d.UserID, in.AuthSalt, ak, in.PasswordWrap); errors.Is(err, errNeedPasswordWrap) {
		apiErr(w, 409, err.Error())
		return
	} else if err != nil {
		apiErr(w, 500, "保存失败")
		return
	}
	writeJSON(w, 200, map[string]any{"account": h.accountJSON(d)})
}

// POST /v1/e2e/unlock {auth_key}：没输过密码的设备（配对码登录）输入密码解锁：核对登录凭证后返回用密码锁住的私钥
func (h *Hub) handleE2EUnlock(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct {
		AuthKey string `json:"auth_key"`
	}
	if !readJSON(w, r, &in) {
		return
	}
	a, err := h.st.AccountByID(d.UserID)
	if err != nil {
		apiErr(w, 500, "查询失败")
		return
	}
	if !h.st.E2EEnabled(d.UserID) {
		apiErr(w, 409, "这个账号还没有开启加密")
		return
	}
	if !a.AuthKey || !h.st.HasWrap(d.UserID, wrapPassword) {
		apiErr(w, 409, "用密码锁住的私钥已失效（管理员重设过密码）：请用恢复码或另一台设备解锁，再重新设置密码")
		return
	}
	if !h.checkCurrent(w, a, "", in.AuthKey, "") {
		return
	}
	writeJSON(w, 200, map[string]any{"password_wrap": h.st.Wrap(d.UserID, wrapPassword, "")})
}

// b64Bytes32：base64url 编码的 32 字节
func b64Bytes32(s string) ([]byte, bool) {
	b, err := b64.DecodeString(s)
	return b, err == nil && len(b) == 32
}

// PUT /v1/e2e/device {pub, request, commit}：登记本机的 X25519 公钥；request 为真时请求已解锁的设备批准（commit 是核对码的承诺）
func (h *Hub) handleE2EDevice(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct {
		Pub     string `json:"pub"`
		Request bool   `json:"request"`
		Commit  string `json:"commit"`
	}
	if !readJSON(w, r, &in) {
		return
	}
	pub, err := b64.DecodeString(in.Pub)
	if err != nil || len(pub) != 32 {
		apiErr(w, 400, "公钥格式不对")
		return
	}
	if in.Request && !h.st.E2EEnabled(d.UserID) {
		apiErr(w, 409, "这个账号还没有开启加密")
		return
	}
	if _, ok := b64Bytes32(in.Commit); in.Request && !ok {
		apiErr(w, 400, "请求批准时要带核对码的承诺 commit（base64url，32 字节）")
		return
	}
	if err := h.st.SetDevicePub(d, pub, in.Request, in.Commit); err != nil {
		apiErr(w, 500, "保存失败")
		return
	}
	writeJSON(w, 200, map[string]any{"device": h.deviceE2E(d)})
}

// POST /v1/e2e/challenge {device_id, nonce}：批准设备接手请求，交出自己的随机数 na
func (h *Hub) handleE2EChallenge(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct {
		DeviceID string `json:"device_id"`
		Nonce    string `json:"nonce"`
	}
	if !readJSON(w, r, &in) {
		return
	}
	if _, ok := b64Bytes32(in.Nonce); !ok {
		apiErr(w, 400, "nonce 格式不对（base64url，32 字节）")
		return
	}
	if in.DeviceID == d.ID {
		apiErr(w, 400, "不能批准本机")
		return
	}
	if err := h.st.SetChallenge(d.UserID, in.DeviceID, in.Nonce); err != nil {
		apiErr(w, 409, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}

// POST /v1/e2e/reveal {nonce}：新设备揭晓 nb，之后两台设备都能算出核对码
func (h *Hub) handleE2EReveal(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct {
		Nonce string `json:"nonce"`
	}
	if !readJSON(w, r, &in) {
		return
	}
	nb, ok := b64Bytes32(in.Nonce)
	if !ok {
		apiErr(w, 400, "nonce 格式不对（base64url，32 字节）")
		return
	}
	if err := h.st.RevealNonce(d, nb); err != nil {
		apiErr(w, 409, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}

// POST /v1/e2e/grant {device_id, pub, grant}：把私钥转交给另一台设备（grant 是加密给它公钥的 HPKE 密文 hjg1.…）
func (h *Hub) handleE2EGrant(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct {
		DeviceID string `json:"device_id"`
		Pub      string `json:"pub"`
		Grant    string `json:"grant"`
	}
	if !readJSON(w, r, &in) {
		return
	}
	if in.DeviceID == d.ID {
		apiErr(w, 400, "不能批准本机")
		return
	}
	if raw, err := b64.DecodeString(strings.TrimPrefix(in.Grant, "hjg1.")); !strings.HasPrefix(in.Grant, "hjg1.") || err != nil || len(raw) < 32+16 || len(in.Grant) > 8192 {
		apiErr(w, 400, "grant 格式不对（hjg1.…）")
		return
	}
	if err := h.st.GrantDevice(d.UserID, in.DeviceID, in.Pub, in.Grant); err != nil {
		apiErr(w, 409, err.Error())
		return
	}
	log.Printf("设备 %s 批准设备 %s 解锁加密消息（账号 #%d）", d.ID, in.DeviceID, d.UserID)
	writeJSON(w, 200, map[string]any{"ok": true})
}

// POST /v1/e2e/deny {device_id}：拒绝另一台设备的请求
func (h *Hub) handleE2EDeny(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct {
		DeviceID string `json:"device_id"`
	}
	if !readJSON(w, r, &in) {
		return
	}
	if err := h.st.DenyE2ERequest(d.UserID, in.DeviceID); err != nil {
		apiErr(w, 500, "保存失败")
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}

// PUT /v1/e2e/recovery {recovery_wrap, current_password | current_auth_key}：换一个新的恢复码（旧的立即失效）
func (h *Hub) handleE2ERecovery(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct {
		RecoveryWrap       string `json:"recovery_wrap"`
		CurrentPassword    string `json:"current_password"`
		CurrentAuthKey     string `json:"current_auth_key"`
		CurrentPasswordKey string `json:"current_password_key"`
	}
	if !readJSON(w, r, &in) {
		return
	}
	if !e2eValidWrap("hjr1", in.RecoveryWrap, 4096) {
		apiErr(w, 400, "recovery_wrap 格式不对（hjr1.…）")
		return
	}
	if !h.st.E2EEnabled(d.UserID) {
		apiErr(w, 409, "这个账号还没有开启加密")
		return
	}
	a, err := h.st.AccountByID(d.UserID)
	if err != nil {
		apiErr(w, 500, "查询失败")
		return
	}
	if !h.checkCurrent(w, a, in.CurrentPassword, in.CurrentAuthKey, in.CurrentPasswordKey) {
		return
	}
	if err := h.st.SetRecoveryWrap(d.UserID, in.RecoveryWrap); err != nil {
		apiErr(w, 500, "保存失败")
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}

// PATCH /v1/e2e {e2e_only}：只接受加密消息（打开后明文发送会被拒收）
func (h *Hub) handleE2EUpdate(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct {
		E2EOnly *bool `json:"e2e_only"`
	}
	if !readJSON(w, r, &in) {
		return
	}
	if in.E2EOnly == nil {
		apiErr(w, 400, "缺少 e2e_only")
		return
	}
	if *in.E2EOnly && !h.st.E2EEnabled(d.UserID) {
		apiErr(w, 409, "请先开启加密")
		return
	}
	if err := h.st.SetE2EOnly(d.UserID, *in.E2EOnly); err != nil {
		apiErr(w, 500, "保存失败")
		return
	}
	writeJSON(w, 200, map[string]any{"e2e_only": *in.E2EOnly})
}

// POST /v1/e2e/delete-plain {confirm:true}：删除服务器上这个账号的全部明文消息（加密消息不动；各设备本地已同步的照常保留）
func (h *Hub) handleE2EDeletePlain(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct {
		Confirm bool `json:"confirm"`
	}
	if !readJSON(w, r, &in) {
		return
	}
	if !in.Confirm {
		apiErr(w, 400, "需要 confirm: true")
		return
	}
	ids := h.st.PlainMessageIDs(d.UserID)
	total := 0
	for len(ids) > 0 {
		n := min(len(ids), 500)
		k, err := h.deleteMessages(d.UserID, ids[:n])
		if err != nil {
			apiErr(w, 500, "删除失败")
			return
		}
		total += k
		ids = ids[n:]
	}
	// secure_delete 已把删掉的内容在数据库页里清零；再把 WAL 里的旧页写回并截断，磁盘上不留明文（历史备份不受影响）
	h.st.db.Exec(`PRAGMA wal_checkpoint(TRUNCATE)`)
	log.Printf("账号 #%d 删除服务器上的明文消息 %d 条", d.UserID, total)
	writeJSON(w, 200, map[string]any{"deleted": total})
}
