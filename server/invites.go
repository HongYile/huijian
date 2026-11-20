package main

// 注册模式和邀请码（0.9.0，内测）。
//
//   - 注册模式三档：closed 关闭（不产生新账号；0.9.0 起账号只能注册产生）/ invite 需要邀请码（新部署默认）/ open 开放。
//     存在 kv 的 register_mode；从旧版本升级时按原来的「开放注册」开关迁移：开放 → open，关闭 → closed。
//   - 邀请码：管理后台「邀请码」页批量生成，每个码可用次数（默认 1）、有效期（默认 7 天）、备注；可以作废。
//     码用 10 位易读字符（去掉 0/O/1/I/L），输入时不区分大小写，空格和短横线忽略。
//   - POST /v1/register 带 invite_code。模式为 invite 时缺失或无效返回 403（无效 / 已用完 / 已过期 / 已作废各有文案），
//     按来源 IP 限速；注册成功时在建号的同一个事务里扣次数、记下使用者。
//   - 使用记录（invite_uses）记用户名快照；账号删除时用户名清空、user_id 置 0，只留次数和时间，显示「已删除账号」。

import (
	"crypto/rand"
	"database/sql"
	"errors"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	regClosed = "closed"
	regInvite = "invite"
	regOpen   = "open"
)

const invitesSchema = `
CREATE TABLE IF NOT EXISTS invites(code TEXT PRIMARY KEY, note TEXT NOT NULL DEFAULT '', max_uses INTEGER NOT NULL DEFAULT 1,
  used INTEGER NOT NULL DEFAULT 0, expires_at INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS invite_uses(code TEXT NOT NULL, user_id INTEGER NOT NULL, username TEXT NOT NULL, at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS idx_invite_uses ON invite_uses(code);
`

// 易读字符：去掉 0 O 1 I L
const inviteAlphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
const inviteLen = 10

var (
	errInviteMissing = errors.New("这个服务器注册需要邀请码，请向管理员索取")
	errInviteInvalid = errors.New("邀请码无效，请检查是否输错")
	errInviteUsedUp  = errors.New("邀请码已用完")
	errInviteExpired = errors.New("邀请码已过期")
	errInviteRevoked = errors.New("邀请码已作废")
)

func isInviteErr(err error) bool {
	for _, e := range []error{errInviteMissing, errInviteInvalid, errInviteUsedUp, errInviteExpired, errInviteRevoked} {
		if errors.Is(err, e) {
			return true
		}
	}
	return false
}

func (s *Store) migrateInvites() error {
	if _, err := s.db.Exec(invitesSchema); err != nil {
		return err
	}
	if s.GetKV("register_mode") == "" {
		var users int
		s.db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&users)
		mode := regInvite // 新部署默认需要邀请码
		switch {
		case s.GetKV("register_open") == "1":
			mode = regOpen
		case users > 0: // 升级：原来没开放注册
			mode = regClosed
		}
		s.SetKV("register_mode", mode)
	}
	return nil
}

func (s *Store) RegisterMode() string {
	switch m := s.GetKV("register_mode"); m {
	case regClosed, regInvite, regOpen:
		return m
	}
	return regClosed
}

func (s *Store) SetRegisterMode(m string) error {
	switch m {
	case regClosed, regInvite, regOpen:
	default:
		return errors.New("注册模式只能是 closed / invite / open")
	}
	s.SetKV("register_mode", m)
	s.SetKV("register_open", b2i(m == regOpen)) // 旧字段：降级到旧版本时保持一致
	return nil
}

// normInvite：去掉空格和短横线、转大写
func normInvite(c string) string {
	return strings.ToUpper(strings.NewReplacer(" ", "", "-", "", "\t", "").Replace(strings.TrimSpace(c)))
}

func newInviteCode() string {
	b := make([]byte, inviteLen)
	n := big.NewInt(int64(len(inviteAlphabet)))
	for i := range b {
		x, err := rand.Int(rand.Reader, n)
		if err != nil {
			panic(err)
		}
		b[i] = inviteAlphabet[x.Int64()]
	}
	return string(b)
}

// CreateInvites：批量生成邀请码
func (s *Store) CreateInvites(count, maxUses int, ttl time.Duration, note string) ([]string, error) {
	if count < 1 || count > 100 {
		return nil, errors.New("一次生成 1–100 个")
	}
	if maxUses < 1 || maxUses > 1000 {
		return nil, errors.New("每个码可用次数 1–1000")
	}
	if ttl < time.Hour || ttl > 366*24*time.Hour {
		return nil, errors.New("有效期 1–365 天")
	}
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var codes []string
	exp := time.Now().Add(ttl).Unix()
	for len(codes) < count {
		c := newInviteCode()
		_, err := tx.Exec(`INSERT INTO invites(code,note,max_uses,expires_at,created_at) VALUES(?,?,?,?,?)`, c, note, maxUses, exp, now())
		if isUniqueErr(err) {
			continue
		}
		if err != nil {
			return nil, err
		}
		codes = append(codes, c)
	}
	return codes, tx.Commit()
}

func (s *Store) RevokeInvite(code string) error {
	res, err := s.db.Exec(`UPDATE invites SET revoked=1 WHERE code=?`, normInvite(code))
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// consumeInvite：在建号的事务里先扣一次（在写入账号之前，邀请码不对时不会暴露用户名是否被占用）；
// 不能用时返回对应的错误，事务回滚
func consumeInvite(tx *sql.Tx, code string) error {
	code = normInvite(code)
	if code == "" {
		return errInviteMissing
	}
	res, err := tx.Exec(`UPDATE invites SET used=used+1 WHERE code=? AND revoked=0 AND used<max_uses AND expires_at>?`, code, now())
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		var used, maxUses, revoked int
		var exp int64
		switch err := tx.QueryRow(`SELECT used,max_uses,revoked,expires_at FROM invites WHERE code=?`, code).Scan(&used, &maxUses, &revoked, &exp); {
		case errors.Is(err, sql.ErrNoRows):
			return errInviteInvalid
		case err != nil:
			return err
		case revoked != 0:
			return errInviteRevoked
		case exp <= now():
			return errInviteExpired
		default:
			return errInviteUsedUp
		}
	}
	return nil
}

// recordInvite：同一个事务里记下使用者
func recordInvite(tx *sql.Tx, code string, userID int64, username string) error {
	_, err := tx.Exec(`INSERT INTO invite_uses(code,user_id,username,at) VALUES(?,?,?,?)`, normInvite(code), userID, username, now())
	return err
}

type inviteUse struct {
	UserID   int64
	Username string
	At       int64
	Deleted  bool // 账号已删除
}

type Invite struct {
	Code, Note          string
	MaxUses, Used       int
	Expires, Created    int64
	Revoked             bool
	Uses                []inviteUse
	Status, StatusClass string
}

func (s *Store) ListInvites() ([]Invite, error) {
	rows, err := s.db.Query(`SELECT code,note,max_uses,used,expires_at,revoked,created_at FROM invites ORDER BY created_at DESC, code`)
	if err != nil {
		return nil, err
	}
	var out []Invite
	idx := map[string]int{}
	for rows.Next() {
		var v Invite
		var rev int
		if rows.Scan(&v.Code, &v.Note, &v.MaxUses, &v.Used, &v.Expires, &rev, &v.Created) == nil {
			v.Revoked = rev != 0
			switch {
			case v.Revoked:
				v.Status, v.StatusClass = "已作废", "bad"
			case v.Used >= v.MaxUses:
				v.Status, v.StatusClass = "已用完", ""
			case v.Expires <= now():
				v.Status, v.StatusClass = "已过期", "warn"
			default:
				v.Status, v.StatusClass = "可用", "ok"
			}
			idx[v.Code] = len(out)
			out = append(out, v)
		}
	}
	rows.Close()
	ur, err := s.db.Query(`SELECT i.code,i.user_id,i.username,i.at,u.id IS NULL FROM invite_uses i LEFT JOIN users u ON u.id=i.user_id ORDER BY i.at`)
	if err != nil {
		return out, err
	}
	defer ur.Close()
	for ur.Next() {
		var c string
		var u inviteUse
		if ur.Scan(&c, &u.UserID, &u.Username, &u.At, &u.Deleted) == nil {
			if i, ok := idx[c]; ok {
				out[i].Uses = append(out[i].Uses, u)
			}
		}
	}
	return out, ur.Err()
}

// InviteTotals：已发（码的个数）、已用（注册成功的次数）
func (s *Store) InviteTotals() (issued, used int64) {
	s.db.QueryRow(`SELECT COUNT(*), COALESCE(SUM(used),0) FROM invites`).Scan(&issued, &used)
	return
}

// ---------- 管理后台 ----------

func (h *Hub) pageInvites(w http.ResponseWriter, r *http.Request) {
	d := h.base(r, "invites", "邀请码")
	d["Invites"], _ = h.st.ListInvites()
	d["Mode"] = h.st.RegisterMode()
	d["New"] = strings.Split(r.URL.Query().Get("new"), ",")
	if r.URL.Query().Get("new") == "" {
		d["New"] = nil
	}
	render(w, "invites", d)
}

// POST /invites：批量生成（count、uses、days、note）
func (h *Hub) adminCreateInvites(w http.ResponseWriter, r *http.Request) {
	atoi := func(k string, def int) int {
		if v, err := strconv.Atoi(strings.TrimSpace(r.FormValue(k))); err == nil {
			return v
		}
		return def
	}
	codes, err := h.st.CreateInvites(atoi("count", 1), atoi("uses", 1), time.Duration(atoi("days", 7))*24*time.Hour, cleanLabel(r.FormValue("note"), 60))
	if err != nil {
		redirectFlash(w, r, "/invites", err.Error())
		return
	}
	redirectFlash(w, r, "/invites?new="+strings.Join(codes, ","), "已生成 "+strconv.Itoa(len(codes))+" 个邀请码")
}

// POST /invites/{code}/revoke
func (h *Hub) adminRevokeInvite(w http.ResponseWriter, r *http.Request) {
	if err := h.st.RevokeInvite(r.PathValue("code")); err != nil {
		redirectFlash(w, r, "/invites", "邀请码不存在")
		return
	}
	redirectFlash(w, r, "/invites", "已作废，之后不能再用它注册（已注册的账号不受影响）")
}

const adminInviteTemplates = `
{{define "invites"}}{{template "top" .}}
<div class="head"><div><h1>邀请码</h1><div class="sub">内测期间新用户凭邀请码在回笺客户端注册。码可以随时复制分享；作废后不能再用，已注册的账号不受影响。</div></div></div>

<div class="card"><div class="card-h"><h2>注册模式</h2><span class="aside">当前：{{if eq .Mode "invite"}}需要邀请码{{else if eq .Mode "open"}}开放注册{{else}}关闭注册{{end}}</span></div><div class="card-b">{{template "regmode" .}}</div></div>

<div class="card"><div class="card-h"><h2>生成邀请码</h2></div><div class="card-b">
<form method="post" action="/invites" class="row">
<label class="small muted">数量 <input class="in" type="number" name="count" value="1" min="1" max="100" style="width:72px"></label>
<label class="small muted">每个可用 <input class="in" type="number" name="uses" value="1" min="1" max="1000" style="width:72px"> 次</label>
<label class="small muted">有效期 <input class="in" type="number" name="days" value="7" min="1" max="365" style="width:72px"> 天</label>
<input class="in" name="note" placeholder="备注，例如：实验室同学" maxlength="60" style="width:200px">
<button class="btn primary">{{template "i-plus"}}生成</button></form>
{{if .New}}<div class="newcodes"><div class="small muted">刚生成的邀请码：</div>{{range .New}}<span class="keyline"><code class="mono">{{.}}</code><button class="btn sm" data-copy="{{.}}">复制</button></span>{{end}}</div>{{end}}
</div></div>

<div class="card"><div class="card-h"><h2>全部邀请码</h2><span class="aside">{{len .Invites}} 个</span></div>
<div class="tblwrap"><table class="tbl"><tr><th>邀请码</th><th>备注</th><th class="num">已用 / 可用</th><th>过期时间</th><th>使用者</th><th>状态</th><th class="r"></th></tr>
{{range .Invites}}<tr class="{{if .Revoked}}rev{{end}}">
<td class="nowrap"><code class="mono">{{.Code}}</code> <button class="btn sm" data-copy="{{.Code}}">复制</button></td>
<td class="muted small">{{.Note}}</td><td class="num">{{.Used}} / {{.MaxUses}}</td>
<td class="muted" title="{{full .Expires}}">{{full .Expires}}</td>
<td class="small">{{range .Uses}}<div>{{if .Deleted}}<span class="muted">已删除账号</span>{{else}}{{.Username}}{{end}} <span class="muted" title="{{full .At}}">{{rel .At}}</span></div>{{else}}<span class="muted">—</span>{{end}}</td>
<td><span class="chip {{.StatusClass}}">{{.Status}}</span></td>
<td class="r">{{if not .Revoked}}<form class="inline" method="post" action="/invites/{{.Code}}/revoke" data-confirm="作废邀请码 {{.Code}}？之后不能再用它注册。"><button class="btn sm danger">作废</button></form>{{end}}</td></tr>
{{else}}<tr><td colspan="7"><div class="empty"><div class="big">还没有邀请码</div>在上面生成，发给要内测的人。</div></td></tr>{{end}}
</table></div></div>
{{template "bottom" .}}{{end}}

{{define "regmode"}}<form method="post" action="/accounts/register" class="row seg-form">
{{range $m := (regmodes)}}<label class="check"><input type="radio" name="mode" value="{{$m.ID}}"{{if eq $m.ID $.Mode}} checked{{end}}> <b>{{$m.Label}}</b> <span class="muted small">{{$m.Desc}}</span></label>{{end}}
<button class="btn sm">保存</button></form>{{end}}
`

type regModeOpt struct{ ID, Label, Desc string }

var regModeOpts = []regModeOpt{
	{regInvite, "需要邀请码", "（推荐，内测）凭邀请码在客户端注册"},
	{regOpen, "开放", "任何知道服务器地址的人都能注册"},
	{regClosed, "关闭", "不再产生新账号"},
}
