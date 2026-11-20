package main

import (
	"crypto/subtle"
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
// 只能在服务器上进入（0.9.0 起任何账号、设备都不能从客户端进入）：
//  1. 管理令牌登录（数据目录里的 admin.token；勾选"记住此浏览器"则一年有效、访问即顺延，会话存在 SQLite，重启不丢）
//  2. 一次性登录链接：在服务器上执行 `huijian admin-link`（docker：`docker exec huijian huijian admin-link`）
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

	// 0.9.0：管理后台只管账号——不看消息、不管某个账号的 pushkey 和设备（这些只能由用户在自己的客户端管理）
	m.HandleFunc("GET /{$}", h.adminAuth(h.pageOverview))

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
	m.HandleFunc("POST /accounts/register", h.adminAuth(h.adminRegisterToggle))
	m.HandleFunc("POST /accounts/{id}/disable", h.adminAuth(h.adminDisableAccount))
	m.HandleFunc("POST /accounts/{id}/logout", h.adminAuth(h.adminLogoutAccount))
	m.HandleFunc("POST /accounts/{id}/delete", h.adminAuth(h.adminDeleteAccount))
	m.HandleFunc("GET /invites", h.adminAuth(h.pageInvites))
	m.HandleFunc("POST /invites", h.adminAuth(h.adminCreateInvites))
	m.HandleFunc("POST /invites/{code}/revoke", h.adminAuth(h.adminRevokeInvite))

	// 给脚本用的 API：Bearer 管理令牌
	m.HandleFunc("POST /api/releases", h.adminBearer(h.apiPublishRelease))
	m.HandleFunc("GET /api/server-update", h.adminBearer(h.apiServerUpdateInfo))  // server-push：对方的平台和版本
	m.HandleFunc("POST /api/server-update", h.adminBearer(h.apiServerUpdatePush)) // server-push：上传签名的程序
	m.HandleFunc("POST /api/invites", h.adminBearer(h.apiCreateInvites))          // huijian invite new
	m.HandleFunc("GET /api/invites", h.adminBearer(h.apiListInvites))             // huijian invite list
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
	return map[string]any{
		"Nav": nav, "Title": title, "Version": version,
		"Flash": r.URL.Query().Get("f"),
		"Path":  r.URL.Path,
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

var funcs = template.FuncMap{
	"rel":      relTime,
	"full":     fullTime,
	"size":     humanSize,
	"pct":      func(f float64) string { return strconv.FormatFloat(f, 'f', 1, 64) },
	"regmodes": func() []regModeOpt { return regModeOpts },
}

func render(w http.ResponseWriter, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := tpl.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("模板渲染失败 %s: %v", name, err)
	}
}

var tpl = template.Must(template.New("").Funcs(funcs).Parse(adminCSS + adminIcons + adminTemplates + adminAccountTemplates + adminInviteTemplates))
