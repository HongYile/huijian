package main

import (
	"crypto/subtle"
	"database/sql"
	"errors"
	"fmt"
	"html/template"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// ======================= 认证 =======================
//
// 三种进入方式：
//  1. 管理令牌登录（勾选"记住此浏览器"则一年有效、访问即顺延，会话存在 SQLite，重启不丢）
//  2. 一次性登录链接：Mac App 用设备凭证换取（需设备开启"可进入管理后台"），或在服务器上
//     `docker exec huijian huijian admin-link` 生成
//  3. 会话随时可在「设置」里注销

type adminState struct {
	tokenHash string
	started   time.Time
}

func newAdminState(dataDir string) *adminState {
	tok := env("HUIJIAN_ADMIN_TOKEN", "")
	if tok == "" {
		p := filepath.Join(dataDir, "admin.token")
		b, err := os.ReadFile(p)
		if err == nil && len(strings.TrimSpace(string(b))) >= 16 {
			tok = strings.TrimSpace(string(b))
		} else {
			tok = "AT_" + randToken(24)
			if err := os.WriteFile(p, []byte(tok+"\n"), 0o600); err != nil {
				log.Fatalf("写入管理令牌失败: %v", err)
			}
			log.Printf("已生成管理令牌，保存在 %s（不会打印到日志）", p)
		}
	}
	return &adminState{tokenHash: sha256Hex(tok), started: time.Now()}
}

const (
	cookieName = "huijian_admin"
	shortTTL   = 12 * time.Hour
)

func (h *Hub) setSession(w http.ResponseWriter, label string, remember bool) error {
	ttl := shortTTL
	if remember {
		ttl = rememberTTL
	}
	raw, err := h.st.CreateSession(label, ttl, remember)
	if err != nil {
		return err
	}
	c := &http.Cookie{Name: cookieName, Value: raw, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode}
	if remember {
		c.MaxAge = int(rememberTTL.Seconds())
	}
	http.SetCookie(w, c)
	return nil
}

func uaLabel(r *http.Request) string {
	ua := r.UserAgent()
	b := "浏览器"
	switch {
	case strings.Contains(ua, "Edg/"):
		b = "Edge"
	case strings.Contains(ua, "Chrome/"):
		b = "Chrome"
	case strings.Contains(ua, "Firefox/"):
		b = "Firefox"
	case strings.Contains(ua, "Safari/"):
		b = "Safari"
	case strings.HasPrefix(ua, "curl/"):
		b = "curl"
	}
	o := ""
	switch {
	case strings.Contains(ua, "iPhone"):
		o = "iPhone"
	case strings.Contains(ua, "iPad"):
		o = "iPad"
	case strings.Contains(ua, "Mac OS X"):
		o = "macOS"
	case strings.Contains(ua, "Windows"):
		o = "Windows"
	case strings.Contains(ua, "Android"):
		o = "Android"
	case strings.Contains(ua, "Linux"):
		o = "Linux"
	}
	if o != "" {
		b += " · " + o
	}
	return b + " · " + hostOf(r.RemoteAddr)
}

func (h *Hub) adminMux() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /login", h.adminLoginPage)
	m.HandleFunc("GET /favicon.png", serveIcon(faviconPNG))
	m.HandleFunc("GET /favicon.ico", serveIcon(faviconPNG))
	m.HandleFunc("GET /apple-touch-icon.png", serveIcon(appleTouchIconPNG))
	m.HandleFunc("POST /login", h.adminLogin)
	m.HandleFunc("GET /auth/link", h.adminLinkLogin)
	m.HandleFunc("POST /logout", h.adminAuth(h.adminLogout))

	m.HandleFunc("GET /{$}", h.adminAuth(h.pageOverview))
	m.HandleFunc("GET /messages", h.adminAuth(h.pageMessages))
	m.HandleFunc("POST /messages/{id}/delete", h.adminAuth(h.adminDeleteMessage))
	m.HandleFunc("GET /att/{id}", h.adminAuth(h.adminAtt))
	m.HandleFunc("POST /test", h.adminAuth(h.adminTest))

	m.HandleFunc("GET /keys", h.adminAuth(h.pageKeys))
	m.HandleFunc("POST /keys", h.adminAuth(h.adminCreateKey))
	m.HandleFunc("POST /keys/{id}/revoke", h.adminAuth(h.adminRevokeKey))
	m.HandleFunc("POST /pushkeys", h.adminAuth(h.adminCreateKey)) // 兼容旧路径
	m.HandleFunc("POST /pushkeys/{id}/revoke", h.adminAuth(h.adminRevokeKey))

	m.HandleFunc("GET /devices", h.adminAuth(h.pageDevices))
	m.HandleFunc("POST /pair", h.adminAuth(h.adminPair))
	m.HandleFunc("POST /devices/{id}/revoke", h.adminAuth(h.adminRevokeDevice))
	m.HandleFunc("POST /devices/{id}/admin", h.adminAuth(h.adminDeviceAdmin))
	m.HandleFunc("POST /devices/{id}/rename", h.adminAuth(h.adminRenameDevice))
	m.HandleFunc("POST /keys/{id}/update", h.adminAuth(h.adminUpdateKey))
	m.HandleFunc("POST /keys/{id}/delete", h.adminAuth(h.adminDeleteKey))

	m.HandleFunc("GET /settings", h.adminAuth(h.pageSettings))
	m.HandleFunc("POST /sessions/{id}/revoke", h.adminAuth(h.adminRevokeSession))
	m.HandleFunc("POST /releases/{id}/delete", h.adminAuth(h.adminDeleteRelease))
	m.HandleFunc("POST /backup/run", h.adminAuth(h.adminRunBackup))
	m.HandleFunc("POST /update/check", h.adminAuth(h.adminCheckUpdate))
	m.HandleFunc("POST /update/apply", h.adminAuth(h.adminApplyUpdate))
	m.HandleFunc("POST /update/upload", h.adminAuth(h.adminUploadUpdate))
	m.HandleFunc("POST /update/proxy", h.adminAuth(h.adminSetUpdateProxy))
	m.HandleFunc("GET /update/status", h.adminAuth(h.adminUpdateStatus))
	m.HandleFunc("GET /accounts", h.adminAuth(h.pageAccounts))
	m.HandleFunc("POST /accounts", h.adminAuth(h.adminCreateAccount))
	m.HandleFunc("POST /accounts/register", h.adminAuth(h.adminRegisterToggle))
	m.HandleFunc("POST /accounts/{id}/credentials", h.adminAuth(h.adminSetCredentials))
	m.HandleFunc("POST /accounts/{id}/disable", h.adminAuth(h.adminDisableAccount))
	m.HandleFunc("GET /switch", h.adminAuth(h.adminSwitch))

	// 给脚本用的 API：Bearer 管理令牌
	m.HandleFunc("POST /api/releases", h.adminBearer(h.apiPublishRelease))
	m.HandleFunc("GET /api/server-update", h.adminBearer(h.apiServerUpdateInfo))  // server-push：对方的平台和版本
	m.HandleFunc("POST /api/server-update", h.adminBearer(h.apiServerUpdatePush)) // server-push：上传签名的程序
	return h.adminGuard(m)
}

// adminGuard：拒绝来自 HUIJIAN_ADMIN_DENY 中地址（通常是公网反向代理）的连接，
// 保证管理后台无法经公网入口访问；POST 校验 Origin 防 CSRF。
func (h *Hub) adminGuard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if h.adminDeny.has(hostOf(r.RemoteAddr)) {
			http.Error(w, "forbidden", 403)
			return
		}
		if r.Method == http.MethodPost {
			if o := r.Header.Get("Origin"); o != "" {
				u, err := url.Parse(o)
				if err != nil || u.Host != r.Host {
					http.Error(w, "bad origin", 403)
					return
				}
			}
		}
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self' data:")
		w.Header().Set("Referrer-Policy", "same-origin") // no-referrer 会让浏览器表单 POST 带 Origin: null
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

func (h *Hub) adminAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, err := r.Cookie(cookieName)
		if err != nil || !h.st.SessionValid(c.Value) {
			http.Redirect(w, r, "/login", http.StatusSeeOther)
			return
		}
		next(w, r)
	}
}

func (h *Hub) adminLoginPage(w http.ResponseWriter, r *http.Request) {
	render(w, "login", map[string]any{"Err": r.URL.Query().Get("e"), "Version": version})
}

// loginAllowed：按真实来源 IP 限速（管理后台在反向代理后面时，只有 HUIJIAN_TRUSTED_PROXY 里的代理传来的
// X-Real-IP 才被采信），避免所有人共用一个额度、被别人一直锁住。
func (h *Hub) loginAllowed(w http.ResponseWriter, r *http.Request) bool {
	ip := h.realIP(r)
	if h.loginLimit.Allow(ip) {
		return true
	}
	log.Printf("管理后台登录尝试过于频繁：%s", ip)
	http.Redirect(w, r, "/login?e=rate", http.StatusSeeOther)
	return false
}

func (h *Hub) adminLogin(w http.ResponseWriter, r *http.Request) {
	if !h.loginAllowed(w, r) {
		return
	}
	tok := strings.TrimSpace(r.FormValue("token"))
	if subtle.ConstantTimeCompare([]byte(sha256Hex(tok)), []byte(h.admin.tokenHash)) != 1 {
		time.Sleep(time.Second)
		http.Redirect(w, r, "/login?e=1", http.StatusSeeOther)
		return
	}
	if err := h.setSession(w, uaLabel(r), r.FormValue("remember") != ""); err != nil {
		http.Error(w, "创建会话失败", 500)
		return
	}
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (h *Hub) adminLinkLogin(w http.ResponseWriter, r *http.Request) {
	// 一次性链接是 192 位随机数、60 秒~5 分钟有效，猜不到；只对无效链接计入限速，
	// 这样有效链接（例如 Mac 一键登录）永远不会被别人的错误尝试挡住
	dev, ok := h.st.ConsumeAdminLink(r.URL.Query().Get("t"))
	if !ok {
		if !h.loginAllowed(w, r) {
			return
		}
		time.Sleep(500 * time.Millisecond)
		http.Redirect(w, r, "/login?e=link", http.StatusSeeOther)
		return
	}
	label := uaLabel(r)
	if dev != "" {
		label += " · 来自设备「" + h.st.DeviceName(dev) + "」"
	} else {
		label += " · 恢复链接"
	}
	if err := h.setSession(w, label, true); err != nil {
		http.Error(w, "创建会话失败", 500)
		return
	}
	log.Printf("一次性链接登录成功（设备 %q）", dev)
	next := r.URL.Query().Get("next")
	if !strings.HasPrefix(next, "/") || strings.HasPrefix(next, "//") || strings.ContainsAny(next, "\\\r\n") {
		next = "/"
	}
	redirectFlash(w, r, next, "已登录，此浏览器会被记住一年")
}

func (h *Hub) adminLogout(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(cookieName); err == nil {
		h.st.DeleteSession(c.Value)
	}
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/", MaxAge: -1})
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

// ======================= 页面 =======================

// publicURL：发送方和设备使用的地址（展示在管理页的示例和配对提示里）。优先 HUIJIAN_PUBLIC_URL；
// 其次是 HUIJIAN_PUBLIC_ADDR 里明确写的监听地址；监听 0.0.0.0（docker）时用本次请求的主机名加对外端口——
// 直接用「公网 IP:端口」访问的部署不需要任何配置。
// 消息 API 本身只说 http；经 HTTPS 反向代理对外时应当设置 HUIJIAN_PUBLIC_URL。
func publicURL(r *http.Request) string {
	if u := env("HUIJIAN_PUBLIC_URL", ""); u != "" {
		return strings.TrimRight(u, "/")
	}
	host := specificHost(env("HUIJIAN_PUBLIC_ADDR", "127.0.0.1:8790")) // 明确的监听地址优先（与 adminURL 一致）
	if host == "" {
		host = requestHost(r)
	}
	if host == "" {
		host = "127.0.0.1"
	}
	return "http://" + net.JoinHostPort(host, externalPort("HUIJIAN_PUBLIC_PORT", "HUIJIAN_PUBLIC_ADDR", "8790"))
}

func (h *Hub) base(r *http.Request, nav, title string) map[string]any {
	uid := h.acct(r)
	cur, _ := h.st.AccountByID(uid)
	list, _ := h.st.ListAccounts()
	return map[string]any{
		"Nav": nav, "Title": title, "Version": version,
		"Flash":    r.URL.Query().Get("f"),
		"Online":   len(h.br.Online(uid)),
		"Path":     r.URL.Path,
		"Acct":     cur,
		"AcctList": list,
	}
}

func redirectFlash(w http.ResponseWriter, r *http.Request, path, msg string) {
	frag := ""
	if i := strings.IndexByte(path, '#'); i >= 0 { // 锚点要放在查询参数后面：/settings?f=…#update
		path, frag = path[:i], path[i:]
	}
	sep := "?"
	if strings.Contains(path, "?") {
		sep = "&"
	}
	http.Redirect(w, r, path+sep+"f="+url.QueryEscape(msg)+frag, http.StatusSeeOther)
}

type prioSeg struct {
	P     int
	Count int64
	Pct   float64
}

func (h *Hub) pageOverview(w http.ResponseWriter, r *http.Request) {
	d := h.base(r, "overview", "概览")
	t := time.Now()
	midnight := time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.Local).Unix()
	pc := h.st.PriorityCounts(h.acct(r), t.Add(-24*time.Hour).Unix())
	var total int64
	for _, c := range pc {
		total += c
	}
	var segs []prioSeg
	for p := 5; p >= 0; p-- {
		if pc[p] > 0 {
			segs = append(segs, prioSeg{P: p, Count: pc[p], Pct: float64(pc[p]) * 100 / float64(total)})
		}
	}
	var today int64
	for _, c := range h.st.PriorityCounts(h.acct(r), midnight) {
		today += c
	}
	devs, _ := h.st.ListDevices(h.acct(r))
	active := 0
	for _, dv := range devs {
		if !dv.Revoked {
			active++
		}
	}
	recent, _ := h.st.AdminMessages(h.acct(r), MsgFilter{Priority: -1}, 8)
	d["Today"] = today
	d["Total24"] = total
	d["Segs"] = segs
	d["Days"] = h.st.DailyCounts(h.acct(r), 14)
	d["Stats"] = h.st.Stats(h.acct(r))
	d["ActiveDevices"] = active
	d["Recent"] = recent
	d["LastMsg"] = h.st.LatestMessageTime(h.acct(r))
	d["PublicURL"] = publicURL(r)
	render(w, "overview", d)
}

func (h *Hub) pageMessages(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	f := MsgFilter{Priority: -1, Topic: q.Get("topic"), Q: strings.TrimSpace(q.Get("q")), HasAtt: q.Get("att") == "1"}
	if p, err := strconv.Atoi(q.Get("p")); err == nil && p >= 0 && p <= 5 {
		f.Priority = p
	}
	f.Before, _ = strconv.ParseInt(q.Get("before"), 10, 64)
	const pageSize = 50
	msgs, _ := h.st.AdminMessages(h.acct(r), f, pageSize)
	for i := range msgs {
		msgs[i].userID = h.acct(r)
	}
	d := h.base(r, "messages", "消息")
	d["Msgs"] = msgs
	d["F"] = f
	d["Topics"] = h.st.Topics(h.acct(r))
	d["Paged"] = f.Before > 0
	if len(msgs) == pageSize {
		next := url.Values{}
		for k, v := range q {
			next[k] = v
		}
		next.Set("before", strconv.FormatInt(msgs[len(msgs)-1].ID, 10))
		next.Del("f")
		d["Next"] = "/messages?" + next.Encode()
	}
	// 优先级筛选链接（保留其他条件）
	type opt struct {
		Label, Href string
		On          bool
		P           int
	}
	var opts []opt
	for _, p := range []int{-1, 5, 4, 3} {
		v := url.Values{}
		if f.Topic != "" {
			v.Set("topic", f.Topic)
		}
		if f.Q != "" {
			v.Set("q", f.Q)
		}
		if f.HasAtt {
			v.Set("att", "1")
		}
		label := "全部"
		if p >= 0 {
			v.Set("p", strconv.Itoa(p))
			label = map[int]string{5: "仅紧急", 4: "重要及以上", 3: "普通及以上"}[p]
		}
		opts = append(opts, opt{Label: label, Href: "/messages?" + v.Encode(), On: f.Priority == p, P: p})
	}
	d["PrioOpts"] = opts
	render(w, "messages", d)
}

func (h *Hub) adminAtt(w http.ResponseWriter, r *http.Request) {
	h.serveAttachment(w, r, h.acct(r), r.PathValue("id"))
}

func (h *Hub) adminTest(w http.ResponseWriter, r *http.Request) {
	prio, err := strconv.Atoi(r.FormValue("priority"))
	if err != nil || prio < 0 || prio > 5 {
		prio = 3
	}
	text := strings.TrimSpace(r.FormValue("text"))
	if text == "" {
		text = "来自管理网页的测试消息"
	}
	uid, ok := h.writeAcct(w, r)
	if !ok {
		return
	}
	h.st.InsertMessage(NewMessage{Idem: "adm_" + randHex(8), UserID: uid, Topic: "admin", Priority: prio, Type: "markdown",
		Text: text, Desp: r.FormValue("desp"), Source: "管理网页", SrcIP: hostOf(r.RemoteAddr)})
	h.br.Notify(uid)
	back := r.FormValue("back")
	if back != "/messages" {
		back = "/"
	}
	redirectFlash(w, r, back, "测试消息已发送")
}

func (h *Hub) pageKeys(w http.ResponseWriter, r *http.Request) {
	keys, _ := h.st.ListPushkeys(h.acct(r))
	d := h.base(r, "keys", "Pushkey")
	d["Keys"] = keys
	active := false
	for _, k := range keys {
		if !k.Revoked {
			active = true
			break
		}
	}
	d["HasActiveKey"] = active // 还没有有效的 key 时，新建表单的名称默认填 default
	d["NewKey"] = r.URL.Query().Get("key")
	d["PublicURL"] = publicURL(r)
	render(w, "keys", d)
}

func (h *Hub) adminCreateKey(w http.ResponseWriter, r *http.Request) {
	name := cleanLabel(r.FormValue("name"), 40)
	if name == "" {
		name = "未命名"
	}
	key := strings.TrimSpace(r.FormValue("key"))
	if key != "" && !reCustomKey.MatchString(key) {
		redirectFlash(w, r, "/keys", keyRule)
		return
	}
	uid, ok := h.writeAcct(w, r)
	if !ok {
		return
	}
	pk, err := h.st.CreatePushkeyWith(uid, name, key)
	if errors.Is(err, errKeyTaken) {
		redirectFlash(w, r, "/keys", err.Error())
		return
	}
	if err != nil {
		http.Error(w, "创建失败", 500)
		return
	}
	http.Redirect(w, r, "/keys?key="+url.QueryEscape(pk.Key)+"&f="+url.QueryEscape("已创建 pushkey「"+name+"」"), http.StatusSeeOther)
}

func (h *Hub) adminRevokeKey(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	uid, ok := h.writeAcct(w, r)
	if !ok {
		return
	}
	h.st.RevokePushkey(uid, id)
	redirectFlash(w, r, "/keys", "已吊销，使用该 key 的发送方将无法再发送")
}

// POST /messages/{id}/delete：删除当前账号的一条消息（所有设备同步消失，附件一起删除）
func (h *Hub) adminDeleteMessage(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	uid, ok := h.writeAcct(w, r)
	if !ok {
		return
	}
	back := "/messages"
	if ref, err := url.Parse(r.Header.Get("Referer")); err == nil && ref.Path == "/messages" {
		q := ref.Query()
		q.Del("f")
		if e := q.Encode(); e != "" {
			back += "?" + e // 保留筛选条件
		}
	}
	n, err := h.deleteMessages(uid, []int64{id})
	switch {
	case err != nil:
		redirectFlash(w, r, back, "删除失败")
	case n == 0:
		redirectFlash(w, r, back, "消息不存在（可能已被删除）")
	default:
		redirectFlash(w, r, back, "已删除")
	}
}

func (h *Hub) adminDeleteKey(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	uid, ok := h.writeAcct(w, r)
	if !ok {
		return
	}
	if err := h.st.DeletePushkey(uid, id); err != nil {
		msg := "删除失败"
		if errors.Is(err, errKeyNotRevoked) {
			msg = err.Error()
		}
		redirectFlash(w, r, "/keys", msg)
		return
	}
	redirectFlash(w, r, "/keys", "已删除（历史消息保留）")
}

func (h *Hub) pageDevices(w http.ResponseWriter, r *http.Request) {
	uid := h.acct(r)
	devs, _ := h.st.ListDevices(uid)
	d := h.base(r, "devices", "设备")
	online := map[string]int{}
	for k, v := range h.br.Online(uid) {
		online[k] = v
	}
	// 按名称或设备 ID 搜索：跨所有账号（名称可以重名，ID 唯一）
	if q := strings.TrimSpace(r.URL.Query().Get("q")); q != "" {
		devs, _ = h.st.SearchDevices(q)
		d["Q"] = q
		d["AcctLabels"] = h.accountLabels()
		for _, x := range devs {
			if x.UserID != uid {
				for k, v := range h.br.Online(x.UserID) {
					online[k] = v
				}
			}
		}
	}
	pairs := map[string][]Pairing{}
	for _, x := range devs {
		if x.PairCount > 1 {
			pairs[x.ID] = h.st.Pairings(x.ID, 10)
		}
	}
	outdated := map[string]bool{}
	for _, x := range devs {
		outdated[x.ID] = h.clientOutdated(x.Client)
	}
	d["Devices"] = devs
	d["Pairings"] = pairs
	d["Outdated"] = outdated
	d["OnlineMap"] = online
	q := r.URL.Query()
	if c := q.Get("code"); len(c) == 6 {
		d["Code"] = c
		d["CodeExp"] = q.Get("exp")
		d["CodeAdmin"] = q.Get("adm") == "1"
	}
	d["PublicURL"] = publicURL(r)
	d["InternalURL"] = env("HUIJIAN_INTERNAL_URL", "")
	render(w, "devices", d)
}

func (h *Hub) adminPair(w http.ResponseWriter, r *http.Request) {
	canAdmin := r.FormValue("can_admin") != ""
	ttl := pairCodeTTL
	uid, ok := h.writeAcct(w, r)
	if !ok {
		return
	}
	code, err := h.st.CreatePairCode(uid, ttl, canAdmin, "")
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	adm := "0"
	if canAdmin {
		adm = "1"
	}
	http.Redirect(w, r, fmt.Sprintf("/devices?code=%s&exp=%d&adm=%s", code, time.Now().Add(ttl).Unix(), adm), http.StatusSeeOther)
}

func (h *Hub) adminRevokeDevice(w http.ResponseWriter, r *http.Request) {
	h.st.RevokeDevice(h.st.DeviceOwner(r.PathValue("id")), r.PathValue("id"))
	redirectFlash(w, r, "/devices", "设备已吊销")
}

func (h *Hub) adminDeviceAdmin(w http.ResponseWriter, r *http.Request) {
	on := r.FormValue("on") == "1"
	h.st.SetDeviceAdmin(h.st.DeviceOwner(r.PathValue("id")), r.PathValue("id"), on)
	msg := "已关闭该设备的管理权限"
	if on {
		msg = "已允许该设备管理：在 App 里管理 Pushkey、一键进入管理后台"
	}
	redirectFlash(w, r, "/devices", msg)
}

func (h *Hub) pageSettings(w http.ResponseWriter, r *http.Request) {
	sess, _ := h.st.ListSessions()
	cur := ""
	if c, err := r.Cookie(cookieName); err == nil {
		cur = sha256Hex(c.Value)
	}
	d := h.base(r, "settings", "设置")
	d["Sessions"] = sess
	d["Releases"], _ = h.st.ListReleases()
	d["Current"] = cur
	d["Started"] = h.admin.started
	d["Uptime"] = time.Since(h.admin.started).Round(time.Minute).String()
	d["DBSize"] = dbSize(h.dataDir)
	d["Storage"] = h.storageInfo(r.URL.Query().Get("fresh") == "1")
	d["PublicURL"] = publicURL(r)
	d["AdminURL"] = adminURL(r)
	d["PubAddr"] = env("HUIJIAN_PUBLIC_ADDR", "127.0.0.1:8790")
	d["Update"] = h.updateView()
	render(w, "settings", d)
}

func (h *Hub) adminRevokeSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	h.st.DeleteSessionByHash(id)
	if c, err := r.Cookie(cookieName); err == nil && sha256Hex(c.Value) == id {
		http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/", MaxAge: -1})
		http.Redirect(w, r, "/login", http.StatusSeeOther)
		return
	}
	redirectFlash(w, r, "/settings", "已注销该浏览器")
}

// ======================= 模板函数 =======================

func toTime(v any) (time.Time, bool) {
	switch x := v.(type) {
	case int64:
		if x == 0 {
			return time.Time{}, false
		}
		return time.Unix(x, 0), true
	case time.Time:
		return x, !x.IsZero()
	}
	return time.Time{}, false
}

func relTime(v any) string {
	t, ok := toTime(v)
	if !ok {
		return "—"
	}
	t = t.In(time.Local)
	n := time.Now()
	d := n.Sub(t)
	y := n.AddDate(0, 0, -1)
	switch {
	case d < 0:
		return t.Format("01-02 15:04")
	case d < time.Minute:
		return "刚刚"
	case d < time.Hour:
		return fmt.Sprintf("%d 分钟前", int(d.Minutes()))
	case t.YearDay() == n.YearDay() && t.Year() == n.Year():
		return t.Format("15:04")
	case t.YearDay() == y.YearDay() && t.Year() == y.Year():
		return "昨天 " + t.Format("15:04")
	case t.Year() == n.Year():
		return t.Format("01-02 15:04")
	}
	return t.Format("2006-01-02")
}

func fullTime(v any) string {
	t, ok := toTime(v)
	if !ok {
		return ""
	}
	return t.In(time.Local).Format("2006-01-02 15:04:05")
}

func humanSize(n int64) string {
	switch {
	case n >= 1<<30:
		return strconv.FormatFloat(float64(n)/(1<<30), 'f', 2, 64) + " GB"
	case n >= 1<<20:
		return strconv.FormatFloat(float64(n)/(1<<20), 'f', 1, 64) + " MB"
	case n >= 1<<10:
		return strconv.FormatFloat(float64(n)/(1<<10), 'f', 0, 64) + " KB"
	}
	return strconv.FormatInt(n, 10) + " B"
}

var prioNames = map[int]string{5: "紧急", 4: "重要", 3: "普通", 2: "低", 1: "日志", 0: "调试"}

type kindInfo struct{ Class, Label string }

func fileKind(mime, name string) kindInfo {
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(name), "."))
	switch {
	case strings.HasPrefix(mime, "image/"):
		return kindInfo{"img", "IMG"}
	case mime == "application/pdf" || ext == "pdf":
		return kindInfo{"pdf", "PDF"}
	case ext == "doc" || ext == "docx":
		return kindInfo{"doc", "DOC"}
	case ext == "xls" || ext == "xlsx" || ext == "csv":
		return kindInfo{"xls", strings.ToUpper(ext)}
	case ext == "ppt" || ext == "pptx":
		return kindInfo{"ppt", "PPT"}
	case ext == "zip" || ext == "tar" || ext == "gz" || ext == "tgz" || ext == "7z" || ext == "rar":
		return kindInfo{"zip", "ZIP"}
	case strings.HasPrefix(mime, "text/") || ext == "log" || ext == "json" || ext == "py" || ext == "md" || ext == "txt" || ext == "yaml" || ext == "yml":
		return kindInfo{"txt", strings.ToUpper(firstN(ext, 4))}
	}
	if ext == "" {
		return kindInfo{"oth", "FILE"}
	}
	return kindInfo{"oth", strings.ToUpper(firstN(ext, 4))}
}

func firstN(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	if s == "" {
		return "TXT"
	}
	return s
}

func maskKey(k string) string {
	if len(k) <= 12 {
		return k
	}
	return k[:7] + "••••••••" + k[len(k)-4:]
}

var funcs = template.FuncMap{
	"rel":  relTime,
	"full": fullTime,
	"size": humanSize,
	"pname": func(p int) string {
		return prioNames[p]
	},
	"kind": fileKind,

	"mask": maskKey,
	"snip": func(s string, n int) string {
		r := []rune(strings.TrimSpace(s))
		if len(r) > n {
			return string(r[:n]) + "…"
		}
		return string(r)
	},
	"long":     func(s string) bool { return len([]rune(s)) > 280 || strings.Count(s, "\n") > 6 },
	"md":       mdToHTML,
	"msgmd":    msgHTML,
	"msgplain": msgPlain,
	"plain":    mdPlain,
	"pct":      func(f float64) string { return strconv.FormatFloat(f, 'f', 1, 64) },
	"first": func(s string) string {
		r := []rune(s)
		if len(r) == 0 {
			return "?"
		}
		return string(r[0])
	},
}

func render(w http.ResponseWriter, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := tpl.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("模板渲染失败 %s: %v", name, err)
	}
}

var tpl = template.Must(template.New("").Funcs(funcs).Parse(adminCSS + adminIcons + adminTemplates + adminAccountTemplates))

func (h *Hub) adminRenameDevice(w http.ResponseWriter, r *http.Request) {
	name := cleanLabel(r.FormValue("name"), 64)
	if name == "" {
		redirectFlash(w, r, "/devices", "名称不能为空")
		return
	}
	if err := h.st.RenameDevice(h.st.DeviceOwner(r.PathValue("id")), r.PathValue("id"), name); err != nil {
		redirectFlash(w, r, "/devices", "设备不存在或已吊销")
		return
	}
	redirectFlash(w, r, "/devices", "已改名为「"+name+"」")
}

func (h *Hub) adminUpdateKey(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	name, key := cleanLabel(r.FormValue("name"), 40), strings.TrimSpace(r.FormValue("key"))
	if key != "" && !reCustomKey.MatchString(key) {
		redirectFlash(w, r, "/keys", keyRule)
		return
	}
	uid, ok := h.writeAcct(w, r)
	if !ok {
		return
	}
	if err := h.st.UpdatePushkey(uid, id, name, key); err != nil {
		msg := err.Error()
		if errors.Is(err, sql.ErrNoRows) {
			msg = "pushkey 不存在"
		}
		redirectFlash(w, r, "/keys", msg)
		return
	}
	if key != "" {
		redirectFlash(w, r, "/keys", "已更新，旧 key 立即失效")
		return
	}
	redirectFlash(w, r, "/keys", "已更新")
}
