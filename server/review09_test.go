package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

// 0.9.0 审查修复（REVIEW-0.9.0.md）的回归测试

// regUser：开放注册模式下注册一个账号，返回账号 id 和设备 token
func regUser(t *testing.T, e *e2eEnv, user string) (int64, string) {
	t.Helper()
	out := e.must(200, "POST", "/v1/register", "", regBody(user, ""))
	var uid int64
	e.h.st.db.QueryRow(`SELECT user_id FROM devices WHERE id=?`, out["device_id"]).Scan(&uid)
	return uid, out["token"].(string)
}

// H1：删除账号后，它的 pushkey 字符串不能被别的账号认领，被删用户的脚本继续推送返回 403
func TestDeletedAccountPushkeyRetired(t *testing.T) {
	e := newE2EEnv(t)
	e.h.st.SetRegisterMode(regOpen)
	regUser(t, e, "owner")
	alice, tokA := regUser(t, e, "alice")
	e.must(200, "POST", "/v1/keys", tokA, map[string]any{"name": "train", "key": "alice_train_server_01"})
	revoked := e.must(200, "POST", "/v1/keys", tokA, map[string]any{"name": "old", "key": "alice_old_key_0001"})
	e.must(200, "POST", "/v1/keys/"+jsonNum(revoked["id"])+"/revoke", tokA, nil)
	if _, err := e.h.st.DeleteAccount(alice); err != nil {
		t.Fatal(err)
	}
	_, tokM := regUser(t, e, "mallory")
	for _, k := range []string{"alice_train_server_01", "alice_old_key_0001"} {
		if c, out := e.call("POST", "/v1/keys", tokM, map[string]any{"name": "x", "key": k}); c != 409 {
			t.Fatalf("认领已删除账号的 key %s：%d %v（应 409）", k, c, out)
		}
	}
	// 改名换 key 也不能换成它
	mine := e.must(200, "POST", "/v1/keys", tokM, map[string]any{"name": "m"})
	if c, _ := e.call("PATCH", "/v1/keys/"+jsonNum(mine["id"]), tokM, map[string]any{"key": "alice_train_server_01"}); c != 409 {
		t.Fatalf("换成已删除账号的 key：%d（应 409）", c)
	}
	c, out := e.push(map[string]string{"pushkey": "alice_train_server_01", "text": "alice 的脚本还在发"})
	if c != 403 || !strings.Contains(out["error"].(string), "已删除") {
		t.Fatalf("推送已删除账号的 key：%d %v", c, out)
	}
	if n := len(e.messages(tokM)); n != 0 {
		t.Fatalf("mallory 收到了 %d 条", n)
	}
	// 自己换 key：旧字符串也留墓碑（旧脚本 403，别人不能认领）
	e.must(200, "PATCH", "/v1/keys/"+jsonNum(mine["id"]), tokM, map[string]any{"key": "mallory_new_key_01"})
	oldKey := mine["key"].(string)
	if c, _ := e.push(map[string]string{"pushkey": oldKey, "text": "x"}); c != 403 {
		t.Fatalf("换掉的旧 key 推送：%d", c)
	}
	_, tokO := regUser(t, e, "other")
	if c, _ := e.call("POST", "/v1/keys", tokO, map[string]any{"name": "x", "key": oldKey}); c != 409 {
		t.Fatalf("认领换掉的旧 key：%d（应 409）", c)
	}
}

func jsonNum(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// M1：注销全部登录 / 删除账号后，挂着的长轮询被唤醒时返回 401，不带回任何新消息
func TestLongPollEndsAfterLogout(t *testing.T) {
	for _, how := range []string{"logout", "delete"} {
		t.Run(how, func(t *testing.T) {
			e := newE2EEnv(t)
			e.h.st.SetRegisterMode(regOpen)
			regUser(t, e, "owner")
			uid, tok := regUser(t, e, "carol")
			pk, _ := e.h.st.CreatePushkey(uid, "k")
			var wg sync.WaitGroup
			var got map[string]any
			code := 0
			wg.Add(1)
			go func() {
				defer wg.Done()
				req, _ := http.NewRequest("GET", e.srv.URL+"/v1/messages?since=0&wait=20", nil)
				req.Header.Set("Authorization", "Bearer "+tok)
				resp, err := http.DefaultClient.Do(req)
				if err != nil {
					return
				}
				defer resp.Body.Close()
				code = resp.StatusCode
				json.NewDecoder(resp.Body).Decode(&got)
			}()
			time.Sleep(300 * time.Millisecond)
			if how == "logout" {
				e.h.st.LogoutAccount(uid)
				e.push(map[string]string{"pushkey": pk.Key, "text": "注销以后的新消息"})
			} else {
				e.h.st.DeleteAccount(uid)
			}
			e.h.br.Notify(uid)
			wg.Wait()
			if code != 401 || got["messages"] != nil {
				t.Fatalf("挂着的长轮询：%d %v（应 401、不带消息）", code, got)
			}
		})
	}
}

// M2：账号 id 不复用；同一天删两个账号不出错；新账号当天活跃照常记上
func TestUserIDNotReused(t *testing.T) {
	e := newE2EEnv(t)
	e.h.st.SetRegisterMode(regOpen)
	regUser(t, e, "owner")
	a, tokA := regUser(t, e, "alice")
	e.call("GET", "/v1/me", tokA, nil) // 今天活跃（内存去重记下 alice 的 id）
	if _, err := e.h.st.DeleteAccount(a); err != nil {
		t.Fatal(err)
	}
	b, tokB := regUser(t, e, "bob")
	if b == a {
		t.Fatalf("删除的 #%d 被新账号复用了", a)
	}
	e.call("GET", "/v1/me", tokB, nil)
	var n int
	e.h.st.db.QueryRow(`SELECT COUNT(*) FROM daily_active WHERE user_id=? AND day=?`, b, statsDay(statsNow())).Scan(&n)
	if n != 1 {
		t.Fatalf("bob 今天的活跃没记上：%d", n)
	}
	if _, err := e.h.st.DeleteAccount(b); err != nil {
		t.Fatal("同一天删第二个账号失败：", err)
	}
	// 再注册也不会落回已删除的 id（高水位记在库里）
	c, _ := regUser(t, e, "carol")
	if c <= b {
		t.Fatalf("新账号 #%d 不该小于等于已删除的 #%d", c, b)
	}
}

// L1：删除账号后邀请码使用记录里不留用户名
func TestDeleteAccountClearsInviteUsername(t *testing.T) {
	e := newE2EEnv(t)
	codes, _ := e.h.st.CreateInvites(2, 1, time.Hour, "")
	e.must(200, "POST", "/v1/register", "", regBody("owner", codes[0]))
	out := e.must(200, "POST", "/v1/register", "", regBody("真名张三", codes[1]))
	var uid int64
	e.h.st.db.QueryRow(`SELECT user_id FROM devices WHERE id=?`, out["device_id"]).Scan(&uid)
	if _, err := e.h.st.DeleteAccount(uid); err != nil {
		t.Fatal(err)
	}
	var n int
	e.h.st.db.QueryRow(`SELECT COUNT(*) FROM invite_uses WHERE username LIKE '%张三%'`).Scan(&n)
	if n != 0 {
		t.Fatal("邀请码使用记录里还留着已删除账号的用户名")
	}
	list, _ := e.h.st.ListInvites()
	found := false
	for _, v := range list {
		for _, u := range v.Uses {
			found = found || u.Deleted
		}
	}
	if !found {
		t.Fatal("使用记录应显示为已删除账号")
	}
}

// L2：账号被删除后，写消息（包括发送端加密的路径）返回 errAccountGone，不留孤儿消息
func TestInsertMessageAccountGone(t *testing.T) {
	e := newE2EEnv(t)
	e.h.st.SetRegisterMode(regOpen)
	regUser(t, e, "owner")
	uid, _ := regUser(t, e, "gone")
	e.h.st.DeleteAccount(uid)
	if _, _, err := e.h.st.InsertMessage(NewMessage{UserID: uid, Topic: "x", Type: "e2e", Text: "x", E2E: "hje1.x.y"}); err != errAccountGone {
		t.Fatalf("应返回 errAccountGone：%v", err)
	}
	var n int
	e.h.st.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE user_id=?`, uid).Scan(&n)
	if n != 0 {
		t.Fatal("留下了孤儿消息")
	}
}

// L3：邀请码校验在用户名合法性之前
func TestRegisterInviteCheckedBeforeUsername(t *testing.T) {
	e := newE2EEnv(t)
	if c, out := e.call("POST", "/v1/register", "", regBody("a/b", "ZZZZZZZZZZ")); c != 403 || out["error"] != errInviteInvalid.Error() {
		t.Fatalf("无效邀请码 + 不合法用户名：%d %v（应先报邀请码）", c, out)
	}
	codes, _ := e.h.st.CreateInvites(1, 1, time.Hour, "")
	if c, _ := e.call("POST", "/v1/register", "", regBody("a/b", codes[0])); c != 400 {
		t.Fatalf("有效邀请码 + 不合法用户名：%d（应 400）", c)
	}
	var used int
	e.h.st.db.QueryRow(`SELECT used FROM invites WHERE code=?`, codes[0]).Scan(&used)
	if used != 0 {
		t.Fatal("用户名不合法时不该扣邀请码")
	}
}
