package main

// 0.9.0「管理后台只管账号」：删掉的页面 404、统计（含跨天）、账号级管理员和迁移、无钥匙账号的系统通知丢弃

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// adminClient：带会话 cookie 的管理后台请求，返回状态码和正文
func adminClient(t *testing.T, h *Hub) func(method, path string, form url.Values) (int, string) {
	t.Helper()
	srv := httptest.NewServer(h.adminMux())
	t.Cleanup(srv.Close)
	sess, err := h.st.CreateSession("test", time.Hour, false)
	if err != nil {
		t.Fatal(err)
	}
	return func(method, path string, form url.Values) (int, string) {
		t.Helper()
		req, _ := http.NewRequest(method, srv.URL+path, strings.NewReader(form.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.AddCookie(&http.Cookie{Name: cookieName, Value: sess})
		req.AddCookie(&http.Cookie{Name: "huijian_acct", Value: "1"}) // 旧版的「当前账号」cookie：不再有任何作用
		resp, err := noRedirect.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}
}

func withStatsNow(t *testing.T, at time.Time) {
	t.Helper()
	old := statsNow
	statsNow = func() time.Time { return at }
	t.Cleanup(func() { statsNow = old })
}

func TestAdminRemovedPages404(t *testing.T) {
	e := newE2EEnv(t)
	e.h.backup = newBackupper(e.h)
	e.h.admin = &adminState{started: time.Now()}
	u, _ := e.h.st.CreateAccount("alice", "alice-pass-01")
	pk, _ := e.h.st.CreatePushkey(u.ID, "PK-NAME-SECRET")
	d, tok, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "DEVICE-NAME-SECRET", Platform: "macos", Fingerprint: "fp-a9-000001", IP: "203.0.113.77", Client: "macos 0.8.0 (1)"})
	e.must(200, "GET", "/v1/me", tok, nil)
	e.h.st.InsertMessage(NewMessage{UserID: u.ID, PushkeyID: pk.ID, Topic: "TOPIC-SECRET", Priority: 3, Type: "markdown", Text: "MSG-TEXT-SECRET", Desp: "MSG-BODY-SECRET"})
	adm := adminClient(t, e.h)

	for _, r := range []struct{ m, p string }{
		{"GET", "/messages"}, {"POST", "/messages/1/delete"}, {"GET", "/att/a_x"}, {"POST", "/test"},
		{"GET", "/keys"}, {"POST", "/keys"}, {"POST", "/keys/1/revoke"}, {"POST", "/keys/1/update"}, {"POST", "/keys/1/delete"},
		{"POST", "/pushkeys"}, {"POST", "/pushkeys/1/revoke"},
		{"GET", "/devices"}, {"POST", "/pair"}, {"POST", "/devices/" + d.ID + "/revoke"}, {"POST", "/devices/" + d.ID + "/admin"},
		{"POST", "/devices/" + d.ID + "/rename"}, {"GET", "/switch?u=1"},
	} {
		if c, _ := adm(r.m, r.p, url.Values{"on": {"1"}, "name": {"x"}, "text": {"x"}}); c != 404 {
			t.Errorf("%s %s：%d（应 404）", r.m, r.p, c)
		}
	}
	// 0.9.0：后台不能建账号（账号只能由用户注册产生）。GET /accounts 还在，所以 POST 是 405
	if c, _ := adm("POST", "/accounts", url.Values{"username": {"后台建的"}, "password": {"admin-made-01"}}); c != 405 {
		t.Errorf("POST /accounts：%d（应 405）", c)
	}
	if _, err := e.h.st.CheckLogin("后台建的", "admin-made-01"); err == nil {
		t.Fatal("后台不应能建账号")
	}
	// 删掉的操作真的没有生效
	if dd, _ := e.h.st.DeviceByToken(tok); dd == nil || dd.Revoked || dd.Name != "DEVICE-NAME-SECRET" {
		t.Fatalf("设备被改了：%+v", dd)
	}

	// 留下的页面：概览、账号、设置；都不出现消息内容、pushkey、设备名、IP，也没有账号切换
	for _, p := range []string{"/", "/accounts", "/settings"} {
		c, body := adm("GET", p, nil)
		if c != 200 {
			t.Fatalf("GET %s：%d", p, c)
		}
		for _, leak := range []string{"MSG-TEXT-SECRET", "MSG-BODY-SECRET", "TOPIC-SECRET", "PK-NAME-SECRET", pk.Key, "DEVICE-NAME-SECRET", d.ID, "203.0.113.77", "/switch", `href="/messages"`, `href="/keys"`, `href="/devices"`} {
			if strings.Contains(body, leak) {
				t.Fatalf("GET %s 出现了 %q", p, leak)
			}
		}
	}
	_, ov := adm("GET", "/", nil)
	for _, want := range []string{"近 30 天每日活跃账号", "每日新消息", "每日新账号", "设备平台与版本", "存储与备份", "macos"} {
		if !strings.Contains(ov, want) {
			t.Fatalf("概览缺少 %q", want)
		}
	}
	_, acc := adm("GET", "/accounts", nil)
	for _, want := range []string{"最后活跃", "占用空间", "未加密（旧账号，登录后自动开启）", "注销全部登录", "/accounts/" + strconv.FormatInt(u.ID, 10) + "/logout"} {
		if !strings.Contains(acc, want) {
			t.Fatalf("账号页缺少 %q", want)
		}
	}
	// 公开接口里的同名路径不受影响：用户自己的 key / 设备照常管理
	e.must(200, "GET", "/v1/keys", tok, nil)
}

func TestAdminAccountActions(t *testing.T) {
	e := newE2EEnv(t)
	e.h.backup = newBackupper(e.h)
	owner, _ := e.h.st.CreateAccount("owner", "owner-pass-01")
	u, _ := e.h.st.CreateAccount("carol", "carol-pass-01")
	_, tok1, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "a", Platform: "macos", Fingerprint: "fp-a9-000011"})
	_, tok2, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "b", Platform: "ios", Fingerprint: "fp-a9-000012"})
	_, tokO, _, _ := e.h.st.LoginDevice(pairReq{UserID: owner.ID, Name: "o", Platform: "macos", Fingerprint: "fp-a9-000013"})
	adm := adminClient(t, e.h)
	id := strconv.FormatInt(u.ID, 10)

	// 0.9.0：任何账号都不能从客户端进入管理后台；服务器级接口已删除，can_admin 恒为假（旧库里 can_admin / is_admin 为 1 也不算）
	st := e.h.st
	st.db.Exec(`UPDATE devices SET can_admin=1`)
	st.db.Exec(`UPDATE users SET is_admin=1`)
	for _, tok := range []string{tok1, tok2, tokO} {
		for _, r := range []struct{ m, p string }{{"POST", "/v1/admin/link"}, {"GET", "/v1/storage"}, {"POST", "/v1/storage/backup"}} {
			if c, _ := e.call(r.m, r.p, tok, nil); c != 404 {
				t.Fatalf("%s %s：%d（应 404）", r.m, r.p, c)
			}
		}
		if me := e.must(200, "GET", "/v1/me", tok, nil); me["can_admin"] != false || me["admin_url"] != "" {
			t.Fatalf("/v1/me：can_admin=%v admin_url=%v", me["can_admin"], me["admin_url"])
		}
	}
	// 后台没有设管理员的入口
	if c, _ := adm("POST", "/accounts/"+id+"/admin", url.Values{"on": {"1"}}); c != 404 {
		t.Fatalf("设管理员的路由应已删除：%d", c)
	}
	// 同账号设备之间可以互相移除
	d3, _, _, _ := st.LoginDevice(pairReq{UserID: u.ID, Name: "c", Platform: "android", Fingerprint: "fp-a9-000014"})
	e.must(200, "POST", "/v1/devices/"+d3.ID+"/revoke", tok1, nil)
	// 注销全部登录：所有设备 token 失效，账号和 pushkey 保留，可以用密码重新登录
	code, _ := e.h.st.CreatePairCode(u.ID, pairCodeTTL, "")
	if c, _ := adm("POST", "/accounts/"+id+"/logout", nil); c != 303 {
		t.Fatalf("注销全部登录：%d", c)
	}
	for _, tok := range []string{tok1, tok2} {
		e.must(401, "GET", "/v1/me", tok, nil)
	}
	e.must(200, "GET", "/v1/me", tokO, nil)
	if _, _, _, err := e.h.st.Pair(code, pairReq{Name: "x", Platform: "ios"}); err == nil {
		t.Fatal("注销全部登录后旧配对码应作废")
	}
	if _, err := e.h.st.CheckLogin("carol", "carol-pass-01"); err != nil {
		t.Fatal("注销登录不应影响密码登录：", err)
	}
	// 停用 / 启用照旧
	adm("POST", "/accounts/"+id+"/disable", url.Values{"on": {"1"}})
	if !e.h.st.AccountDisabled(u.ID) {
		t.Fatal("停用没有生效")
	}
	adm("POST", "/accounts/"+id+"/disable", url.Values{"on": {"0"}})
	// 0.9.0：后台不能改任何账号的用户名和密码（改了密码就能登录进别人的账号）
	if c, _ := adm("POST", "/accounts/"+id+"/credentials", url.Values{"username": {"mallory"}, "password": {"admin-set-pass-1"}}); c != 404 {
		t.Fatalf("POST /accounts/{id}/credentials 应 404：%d", c)
	}
	if _, err := e.h.st.CheckLogin("carol", "admin-set-pass-1"); err == nil {
		t.Fatal("后台改了密码")
	}
	if a, _ := e.h.st.AccountByID(u.ID); a.Username != "carol" {
		t.Fatalf("后台改了用户名：%s", a.Username)
	}
}

// 统计：活跃账号按天去重（跨天重新计）、每日消息 / 附件 / 新账号累加、400 天以前的活跃记录清掉
func TestStatsDaily(t *testing.T) {
	day1 := time.Date(2026, 3, 1, 23, 59, 0, 0, time.Local)
	day2 := day1.Add(2 * time.Minute) // 跨过午夜
	withStatsNow(t, day1)
	e := newE2EEnv(t)
	st := e.h.st
	u1, _ := st.CreateAccount("s1", "stat-pass-01")
	u2, _ := st.CreateAccount("s2", "stat-pass-02")
	pk1, _ := st.CreatePushkey(u1.ID, "a")
	_, tok1, _, _ := st.LoginDevice(pairReq{UserID: u1.ID, Name: "a", Platform: "macos", Fingerprint: "fp-st-000001", Client: "macos 0.9.0 (1)"})
	_, tok2, _, _ := st.LoginDevice(pairReq{UserID: u2.ID, Name: "b", Platform: "ios", Fingerprint: "fp-st-000002", Client: "ios 0.3.0 (1)"})
	st.LoginDevice(pairReq{UserID: u2.ID, Name: "c", Platform: "ios", Fingerprint: "fp-st-000003"})

	// 设备鉴权成功时记活跃：同一账号一天只一行
	for i := 0; i < 3; i++ {
		e.must(200, "GET", "/v1/me", tok1, nil)
	}
	e.must(200, "GET", "/v1/me", tok2, nil)
	e.call("GET", "/v1/me", "DT_wrong", nil) // 鉴权失败不算
	count := func(q string, args ...any) int64 {
		var n int64
		st.db.QueryRow(q, args...).Scan(&n)
		return n
	}
	if n := count(`SELECT COUNT(*) FROM daily_active WHERE day=?`, "2026-03-01"); n != 2 {
		t.Fatalf("第一天活跃记录 %d 行（应 2）", n)
	}
	// 消息和附件：写库时累加；幂等重复不算
	id1, _, _ := st.InsertMessage(NewMessage{UserID: u1.ID, PushkeyID: pk1.ID, Topic: "t", Priority: 3, Type: "e2e", Text: "x", E2E: "hje1.x",
		Files: []Attachment{{Name: "a", Mime: "x", Size: 1000, Sha256: "x", blob: "b1"}, {Name: "b", Mime: "x", Size: 234, Sha256: "y", blob: "b2"}}})
	st.InsertMessage(NewMessage{UserID: u1.ID, Topic: "t", Priority: 3, Type: "e2e", Text: "x", E2E: "hje1.y", Idem: "k1"})
	if _, dup, _ := st.InsertMessage(NewMessage{UserID: u1.ID, Topic: "t", Priority: 3, Type: "e2e", Text: "x", E2E: "hje1.y", Idem: "k1"}); !dup {
		t.Fatal("应是幂等重复")
	}
	_ = id1

	// 跨天：内存去重按天重置，同一账号第二天再记一行
	withStatsNow(t, day2)
	e.must(200, "GET", "/v1/me", tok1, nil)
	e.must(200, "GET", "/v1/me", tok1, nil)
	st.InsertMessage(NewMessage{UserID: u2.ID, Topic: "t", Priority: 3, Type: "e2e", Text: "x", E2E: "hje1.z"})
	st.CreateAccount("s3", "stat-pass-03")

	days := st.DailyStats(30)
	if len(days) != 30 || days[29].Day != "2026-03-02" || days[0].Day != "2026-02-01" {
		t.Fatalf("日期：%v … %v", days[0].Day, days[29].Day)
	}
	d1, d2 := days[28], days[29]
	if d1.Day != "2026-03-01" || d1.Active != 2 || d1.Messages != 2 || d1.AttBytes != 1234 || d1.NewAccounts != 2 {
		t.Fatalf("第一天：%+v", d1)
	}
	if d2.Active != 1 || d2.Messages != 1 || d2.AttBytes != 0 || d2.NewAccounts != 1 || !d2.Tick {
		t.Fatalf("第二天：%+v", d2)
	}
	if d1.PctActive != barMax || d2.PctActive != barMax/2 || days[0].Active != 0 || days[0].PctActive != 0 {
		t.Fatalf("柱子高度：%v %v %v", d1.PctActive, d2.PctActive, days[0].PctActive)
	}
	if a1, a7, a30 := st.ActiveAccounts(1), st.ActiveAccounts(7), st.ActiveAccounts(30); a1 != 1 || a7 != 2 || a30 != 2 {
		t.Fatalf("活跃账号 今天 %d / 7 天 %d / 30 天 %d", a1, a7, a30)
	}
	if m, n := sumStats(days); m != 3 || n != 3 {
		t.Fatalf("30 天合计：消息 %d，新账号 %d", m, n)
	}
	// 账号数：都还没有钥匙
	c := st.AccountCounts()
	if c.Total != 3 || c.Encrypted != 0 || c.Waiting != 3 || c.Disabled != 0 {
		t.Fatalf("账号数：%+v", c)
	}
	st.SetAccountDisabled(u2.ID, true)
	st.db.Exec(`INSERT INTO e2e_keys(user_id,kid,pub,active,created_at) VALUES(?,?,?,1,0)`, u1.ID, "k", "p")
	if c := st.AccountCounts(); c.Encrypted != 1 || c.Waiting != 2 || c.Disabled != 1 {
		t.Fatalf("账号数：%+v", c)
	}
	// 设备分布：ios 两台（一台没报版本，算较旧），macos 一台
	plats := e.h.DevicePlatforms()
	if len(plats) != 2 || plats[0].Platform != "ios" || plats[0].Total != 2 || plats[0].Outdated != 1 || plats[1].Platform != "macos" || plats[1].Outdated != 0 {
		t.Fatalf("平台分布：%+v", plats)
	}
	// 账号列表：最后活跃、占用空间（消息 + 附件）
	accts, _ := st.ListAccounts()
	if accts[0].LastActive == 0 || accts[0].Messages != 2 || accts[0].Bytes < 1234 || accts[2].LastActive != 0 || accts[0].Devices != 1 {
		t.Fatalf("账号列表：%+v", accts[0])
	}

	// 400 天以后：换天时清掉 400 天以前的活跃记录
	withStatsNow(t, day2.AddDate(0, 0, activeKeepDays+1))
	st.markActive(u2.ID)
	deadline := time.Now().Add(3 * time.Second)
	for count(`SELECT COUNT(*) FROM daily_active WHERE day<='2026-03-02'`) != 0 {
		if time.Now().After(deadline) {
			t.Fatal("400 天以前的活跃记录没有清掉")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if count(`SELECT COUNT(*) FROM daily_active`) != 1 {
		t.Fatal("今天的活跃记录应保留")
	}
}

// 升级时从现有消息和账号补出以前每天的计数（活跃账号没法补）
func TestStatsBackfill(t *testing.T) {
	now := time.Date(2026, 5, 10, 12, 0, 0, 0, time.Local)
	withStatsNow(t, now)
	path := filepath.Join(t.TempDir(), "b.db")
	st, _ := OpenStore(path)
	u, _ := st.CreateAccount("bf", "bf-pass-0001")
	st.InsertMessage(NewMessage{UserID: u.ID, Topic: "t", Priority: 3, Type: "e2e", Text: "x", E2E: "hje1.a",
		Files: []Attachment{{Name: "a", Mime: "x", Size: 500, Sha256: "x", blob: "b1"}}})
	st.InsertMessage(NewMessage{UserID: u.ID, Topic: "t", Priority: 3, Type: "e2e", Text: "x", E2E: "hje1.b"})
	old := now.AddDate(0, 0, -3).Unix()
	st.db.Exec(`UPDATE messages SET created_at=? WHERE e2e='hje1.a'`, now.Unix())
	st.db.Exec(`UPDATE messages SET created_at=? WHERE e2e='hje1.b'`, old)
	st.db.Exec(`UPDATE users SET created_at=?`, old)
	// 模拟 0.8 的库：没有统计表
	st.db.Exec(`DROP TABLE stats_daily`)
	st.db.Exec(`DROP TABLE daily_active`)
	st.db.Exec(`DELETE FROM kv WHERE k='stats:backfilled'`)
	st.db.Close()
	st, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer st.db.Close()
	days := st.DailyStats(30)
	today, d3 := days[29], days[26]
	if today.Messages != 1 || today.AttBytes != 500 || today.NewAccounts != 0 || d3.Messages != 1 || d3.NewAccounts != 1 || d3.Day != statsDay(now.AddDate(0, 0, -3)) {
		t.Fatalf("补出的计数：今天 %+v，3 天前 %+v", today, d3)
	}
	// 补过一次就不再补（不会重复计数）
	st.db.Close()
	st, _ = OpenStore(path)
	if days := st.DailyStats(30); days[29].Messages != 1 {
		t.Fatalf("重复补了：%+v", days[29])
	}
}

// 无钥匙账号：服务端系统通知直接丢弃，不存明文
func TestNoticeDroppedWithoutKey(t *testing.T) {
	e := newE2EEnv(t)
	u, _ := e.h.st.CreateAccount("nokey", "nokey-pass-01")
	e.h.userID = u.ID
	e.h.notice("drop-test", 4, "DROP-TITLE", "DROP-BODY")
	var n int
	e.h.st.db.QueryRow(`SELECT COUNT(*) FROM messages`).Scan(&n)
	if n != 0 {
		t.Fatal("没有钥匙的账号收到了明文系统通知")
	}
	if _, _, err := e.h.insertServerMessage(NewMessage{UserID: u.ID, Topic: "x", Type: "markdown", Text: "DROP"}); err != errNoE2E {
		t.Fatalf("应返回 errNoE2E：%v", err)
	}
	scanLeaks(t, e, "DROP-TITLE", "DROP-BODY")
}

// 0.9.0：新部署不预建账号；第一个注册的人就是第一个账号，接收系统通知。0.5 以前的无主数据仍归到「me」
func TestFirstAccountIsFirstRegistered(t *testing.T) {
	e := newE2EEnv(t)
	if err := e.h.st.EnsureLegacyOwner(); err != nil {
		t.Fatal(err)
	}
	if id := e.h.st.OwnerID(); id != 0 {
		t.Fatalf("全新的库不该有账号：%d", id)
	}
	e.h.notice("no-user", 4, "NO-USER", "x") // 没有账号：丢弃，不报错
	codes, _ := e.h.st.CreateInvites(2, 1, time.Hour, "")
	out := e.must(200, "POST", "/v1/register", "", regBody("first-user", codes[0]))
	e.must(200, "POST", "/v1/register", "", regBody("second-user", codes[1]))
	first, _ := e.h.st.AccountByID(e.h.st.OwnerID())
	if first.Username != "first-user" {
		t.Fatalf("第一个账号：%s", first.Username)
	}
	e.h.notice("to-first", 4, "备份失败", "x")
	ms := e.must(200, "GET", "/v1/messages?since=0", out["token"].(string), nil)["messages"].([]any)
	if len(ms) != 1 || ms[0].(map[string]any)["sealed"] != "server" {
		t.Fatalf("第一个账号没收到加密的系统通知：%v", ms)
	}
	// 旧库：有数据没账号 → 建「me」
	path := filepath.Join(t.TempDir(), "old.db")
	st, _ := OpenStore(path)
	st.db.Exec(`PRAGMA foreign_keys=OFF`) // 模拟很旧的库：数据在、账号表空
	st.db.Exec(`INSERT INTO pushkeys(user_id,key,name,created_at) VALUES(1,'PK_old','old',1)`)
	if err := st.EnsureLegacyOwner(); err != nil || st.OwnerID() != 1 {
		t.Fatalf("旧数据应归到第一个账号：%v %d", err, st.OwnerID())
	}
}

func TestInfo09Features(t *testing.T) {
	e := newE2EEnv(t)
	out := e.must(200, "GET", "/v1/info", "", nil)
	got := map[string]string{}
	for _, f := range out["features"].([]any) {
		f := f.(map[string]any)
		got[f["id"].(string)] = f["since"].(string)
	}
	if _, ok := got["admin.link"]; ok {
		t.Fatal("/v1/info 不该再声明 admin.link")
	}
	if _, ok := got["storage"]; ok {
		t.Fatal("/v1/info 不该再声明 storage")
	}
	if got["register.e2e"] != "0.9.0" {
		t.Fatalf("缺少 register.e2e：%v", got)
	}
	if got["admin.accounts"] != "0.9.0" || got["push.e2e"] != "0.9.0" {
		t.Fatalf("/v1/info 缺少 0.9.0 的功能：%v", got)
	}
}

// 0.9.0：没有密码的账号，本账号任何设备都能设置初始密码；已有密码时一律要核对当前密码（不再有管理员免核对）
func TestCredentialsWithoutAdmin(t *testing.T) {
	e := newE2EEnv(t)
	uid, _ := e.h.st.EnsureUser("me")
	_, tok, _, _ := e.h.st.LoginDevice(pairReq{UserID: uid, Name: "phone", Platform: "ios", Fingerprint: "fp-cr-000001"})
	e.h.st.db.Exec(`UPDATE devices SET can_admin=0`)
	e.must(200, "POST", "/v1/account/credentials", tok, map[string]any{"username": "主人", "password": "first-pass-01"})
	if _, err := e.h.st.CheckLogin("主人", "first-pass-01"); err != nil {
		t.Fatal("初始密码没生效：", err)
	}
	// 已有密码：旧库里 can_admin=1 的设备也要当前密码
	e.h.st.db.Exec(`UPDATE devices SET can_admin=1`)
	e.must(403, "POST", "/v1/account/credentials", tok, map[string]any{"username": "主人", "password": "second-pass-02"})
	e.must(403, "POST", "/v1/account/credentials", tok, map[string]any{"username": "主人", "password": "second-pass-02", "current_password": "wrong-pass-00"})
	e.must(200, "POST", "/v1/account/credentials", tok, map[string]any{"username": "主人", "password": "second-pass-02", "current_password": "first-pass-01"})
	if _, err := e.h.st.CheckLogin("主人", "second-pass-02"); err != nil {
		t.Fatal("改密码没生效：", err)
	}
}
