package main

import (
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// regBody：注册请求体（0.9.0 起注册时一起开启加密，密码 reg-pass-0001）
func regBody(user, code string) map[string]any {
	b, _, err := registerBody(user, "reg-pass-0001", code, "d", "macos", "")
	if err != nil {
		panic(err)
	}
	return b
}

func TestRegisterModes(t *testing.T) {
	e := newE2EEnv(t)
	// 新部署默认需要邀请码
	if m := e.h.st.RegisterMode(); m != regInvite {
		t.Fatalf("新部署默认模式：%s", m)
	}
	info := e.must(200, "GET", "/v1/info", "", nil)
	if info["register"] != "invite" || info["register_open"] != false {
		t.Fatalf("/v1/info：register=%v register_open=%v", info["register"], info["register_open"])
	}
	// 需要邀请码：没带 → 403
	if c, out := e.call("POST", "/v1/register", "", regBody("u1", "")); c != 403 || out["error"] != errInviteMissing.Error() {
		t.Fatalf("没带邀请码：%d %v", c, out)
	}
	codes, err := e.h.st.CreateInvites(1, 1, 7*24*time.Hour, "测试")
	if err != nil || len(codes) != 1 || len(codes[0]) != inviteLen || strings.ContainsAny(codes[0], "0O1IL") {
		t.Fatalf("生成：%v %v", codes, err)
	}
	// 输入不区分大小写，空格和短横线忽略
	typed := strings.ToLower(codes[0][:5]) + "-" + codes[0][5:] + " "
	if c, out := e.call("POST", "/v1/register", "", regBody("u1", typed)); c != 200 || out["token"] == nil {
		t.Fatalf("用邀请码注册：%d %v", c, out)
	}
	// 开放：不用邀请码；带了也不扣
	e.h.st.SetRegisterMode(regOpen)
	if info := e.must(200, "GET", "/v1/info", "", nil); info["register"] != "open" || info["register_open"] != true {
		t.Fatalf("开放模式 info：%v", info["register"])
	}
	e.must(200, "POST", "/v1/register", "", regBody("u2", ""))
	// 关闭：一律 403
	e.h.st.SetRegisterMode(regClosed)
	codes2, _ := e.h.st.CreateInvites(1, 5, time.Hour*24, "")
	if c, out := e.call("POST", "/v1/register", "", regBody("u3", codes2[0])); c != 403 || !strings.Contains(out["error"].(string), "没有开放注册") {
		t.Fatalf("关闭模式：%d %v", c, out)
	}
	if err := e.h.st.SetRegisterMode("weird"); err == nil {
		t.Fatal("不认识的模式应报错")
	}
	invs, _ := e.h.st.ListInvites()
	for _, v := range invs {
		if v.Code == codes2[0] && v.Used != 0 {
			t.Fatal("关闭模式下不应扣次数")
		}
	}
	// 后台切换模式（新表单 mode=，旧表单 on=1/0 兼容）
	adm := adminClient(t, e.h)
	adm("POST", "/accounts/register", url.Values{"mode": {"invite"}})
	if e.h.st.RegisterMode() != regInvite {
		t.Fatal("后台切换到 invite 没生效")
	}
	adm("POST", "/accounts/register", url.Values{"on": {"1"}})
	if e.h.st.RegisterMode() != regOpen || e.h.st.GetKV("register_open") != "1" {
		t.Fatal("旧表单 on=1 应是开放")
	}
}

func TestInviteErrors(t *testing.T) {
	e := newE2EEnv(t)
	st := e.h.st
	used, _ := st.CreateInvites(1, 1, 24*time.Hour, "")
	expired, _ := st.CreateInvites(1, 1, 24*time.Hour, "")
	revoked, _ := st.CreateInvites(1, 1, 24*time.Hour, "")
	multi, _ := st.CreateInvites(1, 2, 24*time.Hour, "两次")
	st.db.Exec(`UPDATE invites SET expires_at=? WHERE code=?`, now()-1, expired[0])
	if err := st.RevokeInvite(strings.ToLower(revoked[0])); err != nil {
		t.Fatal(err)
	}
	e.must(200, "POST", "/v1/register", "", regBody("first", used[0]))
	for _, c := range []struct{ code, want string }{
		{"ZZZZZZZZZZ", errInviteInvalid.Error()},
		{used[0], errInviteUsedUp.Error()},
		{expired[0], errInviteExpired.Error()},
		{revoked[0], errInviteRevoked.Error()},
	} {
		if code, out := e.call("POST", "/v1/register", "", regBody("x-"+c.code[:4], c.code)); code != 403 || out["error"] != c.want {
			t.Fatalf("邀请码 %s：%d %v（应 403 %s）", c.code, code, out, c.want)
		}
	}
	// 失败的注册不建账号
	var n int
	st.db.QueryRow(`SELECT COUNT(*) FROM users WHERE username LIKE 'x-%'`).Scan(&n)
	if n != 0 {
		t.Fatal("邀请码无效时建出了账号")
	}
	// 用户名被占用时邀请码不扣次数（事务回滚）
	if c, _ := e.call("POST", "/v1/register", "", regBody("first", multi[0])); c != 409 {
		t.Fatalf("用户名被占用：%d", c)
	}
	e.must(200, "POST", "/v1/register", "", regBody("m1", multi[0]))
	e.must(200, "POST", "/v1/register", "", regBody("m2", multi[0]))
	if c, out := e.call("POST", "/v1/register", "", regBody("m3", multi[0])); c != 403 || out["error"] != errInviteUsedUp.Error() {
		t.Fatalf("两次用完后：%d %v", c, out)
	}
	invs, _ := st.ListInvites()
	for _, v := range invs {
		if v.Code == multi[0] && (v.Used != 2 || len(v.Uses) != 2 || v.Uses[0].Username != "m1" || v.Status != "已用完") {
			t.Fatalf("使用记录：%+v", v)
		}
	}
	// 按 IP 限速：穷举邀请码被挡住
	e.h.pairLimit = NewLimiter(1, 3)
	got429 := false
	for i := 0; i < 6; i++ {
		if c, _ := e.call("POST", "/v1/register", "", regBody("brute", "AAAAAAAAA"+string(rune('A'+i)))); c == 429 {
			got429 = true
			break
		}
	}
	if !got429 {
		t.Fatal("连续试邀请码应被限速")
	}
}

// 两个人同时用同一个单次邀请码：只有一个成功
func TestInviteConcurrentSingleUse(t *testing.T) {
	e := newE2EEnv(t)
	for round := 0; round < 5; round++ {
		codes, _ := e.h.st.CreateInvites(1, 1, 24*time.Hour, "")
		var wg sync.WaitGroup
		results := make([]int, 2)
		for i := range results {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				c, _ := e.call("POST", "/v1/register", "", regBody("c"+string(rune('a'+round))+string(rune('0'+i)), codes[0]))
				results[i] = c
			}(i)
		}
		wg.Wait()
		ok := 0
		for _, c := range results {
			if c == 200 {
				ok++
			} else if c != 403 {
				t.Fatalf("第 %d 轮：意外的状态 %v", round, results)
			}
		}
		if ok != 1 {
			t.Fatalf("第 %d 轮：成功 %d 个（应 1）：%v", round, ok, results)
		}
		var uses int
		e.h.st.db.QueryRow(`SELECT COUNT(*) FROM invite_uses WHERE code=?`, codes[0]).Scan(&uses)
		if uses != 1 {
			t.Fatalf("第 %d 轮：使用记录 %d 条", round, uses)
		}
	}
}

func TestInviteAdminPage(t *testing.T) {
	e := newE2EEnv(t)
	e.h.backup = newBackupper(e.h)
	adm := adminClient(t, e.h)
	c, _ := adm("POST", "/invites", url.Values{"count": {"3"}, "uses": {"2"}, "days": {"7"}, "note": {"实验室同学"}})
	if c != 303 {
		t.Fatalf("生成：%d", c)
	}
	invs, _ := e.h.st.ListInvites()
	if len(invs) != 3 || invs[0].MaxUses != 2 || invs[0].Note != "实验室同学" || invs[0].Status != "可用" {
		t.Fatalf("生成结果：%+v", invs)
	}
	if d := time.Until(time.Unix(invs[0].Expires, 0)); d < 6*24*time.Hour || d > 7*24*time.Hour+time.Minute {
		t.Fatalf("有效期：%v", d)
	}
	if c, _ := adm("POST", "/invites", url.Values{"count": {"500"}}); c != 303 {
		t.Fatal(c)
	}
	if invs2, _ := e.h.st.ListInvites(); len(invs2) != 3 {
		t.Fatal("超出数量上限不应生成")
	}
	e.must(200, "POST", "/v1/register", "", regBody("lab1", invs[0].Code))
	adm("POST", "/invites/"+invs[1].Code+"/revoke", nil)
	_, page := adm("GET", "/invites", nil)
	for _, want := range []string{invs[0].Code, invs[2].Code, "实验室同学", "lab1", "已作废", "1 / 2", "需要邀请码"} {
		if !strings.Contains(page, want) {
			t.Fatalf("邀请码页缺少 %q", want)
		}
	}
	_, ov := adm("GET", "/", nil)
	if !strings.Contains(ov, "已发 3 · 已用 1") {
		t.Fatal("概览缺少邀请码统计")
	}
}

// 升级迁移：原来开放 → open，原来关闭 → closed；新部署 → invite
func TestRegisterModeMigration(t *testing.T) {
	for _, c := range []struct {
		open  string
		users bool
		want  string
	}{{"1", true, regOpen}, {"0", true, regClosed}, {"", true, regClosed}, {"", false, regInvite}} {
		path := filepath.Join(t.TempDir(), "r.db")
		st, _ := OpenStore(path)
		if c.users {
			st.CreateAccount("someone", "some-pass-01")
		}
		st.db.Exec(`DELETE FROM kv WHERE k IN ('register_mode','register_open')`)
		if c.open != "" {
			st.SetKV("register_open", c.open)
		}
		st.db.Close()
		st, _ = OpenStore(path)
		if m := st.RegisterMode(); m != c.want {
			t.Fatalf("register_open=%q 有账号=%v：迁移成 %s（应 %s）", c.open, c.users, m, c.want)
		}
		st.db.Close()
	}
}
