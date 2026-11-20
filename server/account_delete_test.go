package main

import (
	"bytes"
	"net/url"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestDeleteAccount(t *testing.T) {
	e := newE2EEnv(t)
	e.h.backup = newBackupper(e.h)
	st := e.h.st
	owner, _ := st.CreateAccount("owner", "owner-pass-01")
	codes, _ := st.CreateInvites(1, 1, 24*time.Hour, "")
	e.must(200, "POST", "/v1/register", "", regBody("gone", codes[0]))
	var gone *Account
	accts, _ := st.ListAccounts()
	for i := range accts {
		if accts[i].Username == "gone" {
			gone = &accts[i]
		}
	}
	keep, _ := st.CreateAccount("keep", "keep-pass-01")
	pkG, _ := st.CreatePushkey(gone.ID, "g")
	pkK, _ := st.CreatePushkey(keep.ID, "k")
	_, tokG, _, _ := st.LoginDevice(pairReq{UserID: gone.ID, Name: "g", Platform: "ios", Fingerprint: "fp-del-00001"})
	_, tokK, _, _ := st.LoginDevice(pairReq{UserID: keep.ID, Name: "k", Platform: "ios", Fingerprint: "fp-del-00002"})
	e.must(200, "GET", "/v1/me", tokG, nil) // 记一条活跃
	for _, u := range []int64{gone.ID, keep.ID} {
		st.db.Exec(`INSERT INTO e2e_keys(user_id,kid,pub,created_at,active) VALUES(?,?,?,?,1)`, u, "k"+strconv.FormatInt(u, 10), "p", 1)
		st.db.Exec(`INSERT INTO e2e_wraps(user_id,kind,device_id,blob,created_at) VALUES(?,?,?,?,1)`, u, "password", "", "hjp1.x")
		st.db.Exec(`INSERT INTO channels(user_id,topic,alias) VALUES(?,?,?)`, u, "train", "训练")
	}
	shared := bytes.Repeat([]byte("SHARED-DEDUP "), 3000) // 两个账号都发过：服务器按内容共用一个文件
	e.legacyPlain(pkK.Key, map[string]string{"text": "keep 的消息"}, map[string][]byte{"shared.bin": shared}, "shared.bin")
	e.legacyPlain(pkG.Key, map[string]string{"text": "GONE-TITLE"}, map[string][]byte{"shared.bin": shared, "own.txt": []byte("GONE-OWN-FILE")}, "shared.bin", "own.txt")
	var ownBlob string
	st.db.QueryRow(`SELECT a.blob FROM attachments a JOIN messages m ON m.id=a.message_id WHERE m.user_id=? AND a.name='own.txt'`, gone.ID).Scan(&ownBlob)
	ownPath, _ := e.h.files.find(ownBlob)
	if _, err := os.Stat(ownPath); err != nil {
		t.Fatal("准备数据：自己的附件文件不存在")
	}

	adm := adminClient(t, e.h)
	id := strconv.FormatInt(gone.ID, 10)
	// 二次确认：用户名不一致不删
	adm("POST", "/accounts/"+id+"/delete", url.Values{"confirm": {"gon"}})
	if _, err := st.AccountByID(gone.ID); err != nil {
		t.Fatal("用户名不一致时不应删除")
	}
	// 第一个账号不能删
	adm("POST", "/accounts/"+strconv.FormatInt(owner.ID, 10)+"/delete", url.Values{"confirm": {"owner"}})
	if _, err := st.AccountByID(owner.ID); err != nil {
		t.Fatal("第一个账号不应被删")
	}

	if c, _ := adm("POST", "/accounts/"+id+"/delete", url.Values{"confirm": {"gone"}}); c != 303 {
		t.Fatalf("删除：%d", c)
	}
	if _, err := st.AccountByID(gone.ID); err == nil {
		t.Fatal("账号还在")
	}
	// 这个账号的数据全部删掉
	for _, q := range []string{
		`SELECT COUNT(*) FROM messages WHERE user_id=?`, `SELECT COUNT(*) FROM pushkeys WHERE user_id=?`,
		`SELECT COUNT(*) FROM devices WHERE user_id=?`, `SELECT COUNT(*) FROM device_pairings WHERE user_id=?`,
		`SELECT COUNT(*) FROM e2e_keys WHERE user_id=?`, `SELECT COUNT(*) FROM e2e_wraps WHERE user_id=?`,
		`SELECT COUNT(*) FROM channels WHERE user_id=?`, `SELECT COUNT(*) FROM msg_changes WHERE user_id=?`,
		`SELECT COUNT(*) FROM daily_active WHERE user_id=?`, `SELECT COUNT(*) FROM invite_uses WHERE user_id=?`,
	} {
		var n int
		st.db.QueryRow(q, gone.ID).Scan(&n)
		if n != 0 {
			t.Fatalf("%s：还剩 %d 行", q, n)
		}
	}
	var atts, pending int
	st.db.QueryRow(`SELECT COUNT(*) FROM attachments`).Scan(&atts)
	st.db.QueryRow(`SELECT COUNT(*) FROM pending_unlink`).Scan(&pending)
	if atts != 1 || pending != 0 {
		t.Fatalf("附件记录 %d（应只剩 keep 的 1 条），待删 %d", atts, pending)
	}
	// 自己的附件文件删掉；和别的账号共用的文件保留，keep 照常下载
	if _, err := os.Stat(ownPath); !os.IsNotExist(err) {
		t.Fatal("被删账号自己的附件文件还在")
	}
	mk := e.messages(tokK)
	if !bytes.Equal(e.download(tokK, mk[0]["attachments"].([]any)[0].(map[string]any)["id"].(string)), shared) {
		t.Fatal("共用的附件文件被删了")
	}
	e.must(200, "GET", "/v1/me", tokK, nil)
	// 被删账号的设备立刻失效
	e.must(401, "GET", "/v1/me", tokG, nil)
	if c, _ := e.call("POST", "/message/push?pushkey="+pkG.Key+"&text=x", "", nil); c == 200 {
		t.Fatal("被删账号的 pushkey 还能发")
	}
	// 邀请码使用记录保留，显示「已删除账号」；历史活跃统计不变
	invs, _ := st.ListInvites()
	if len(invs[0].Uses) != 1 || !invs[0].Uses[0].Deleted || invs[0].Used != 1 {
		t.Fatalf("邀请码使用记录：%+v", invs[0])
	}
	_, page := adm("GET", "/invites", nil)
	if !strings.Contains(page, "已删除账号") {
		t.Fatal("邀请码页应显示「已删除账号」")
	}
	if n := st.ActiveAccounts(1); n != 2 { // gone（负 id 保留）+ keep
		t.Fatalf("今天活跃 %d（删账号不应改历史统计）", n)
	}
	// 账号页不再列出；用户名可以重新注册
	_, acc := adm("GET", "/accounts", nil)
	if strings.Contains(acc, ">gone<") {
		t.Fatal("账号页还列着被删的账号")
	}
	st.SetRegisterMode(regOpen)
	e.must(200, "POST", "/v1/register", "", regBody("gone", ""))
	scanLeaks(t, e, "GONE-OWN-FILE")
}

// 附件目录暂时不可用：文件删不掉的登记在 pending_unlink，之后重试删掉
func TestDeleteAccountPendingUnlink(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root 下 chmod 不生效")
	}
	e := newE2EEnv(t)
	st := e.h.st
	st.CreateAccount("owner", "owner-pass-01")
	u, _ := st.CreateAccount("gone2", "gone-pass-01")
	pk, _ := st.CreatePushkey(u.ID, "g")
	e.legacyPlain(pk.Key, map[string]string{"text": "x"}, map[string][]byte{"a.txt": []byte("PENDING-FILE")}, "a.txt")
	var blob string
	st.db.QueryRow(`SELECT blob FROM attachments`).Scan(&blob)
	p, _ := e.h.files.find(blob)
	dir := p[:strings.LastIndex(p, "/")]
	os.Chmod(dir, 0o555)
	defer os.Chmod(dir, 0o755)
	orphans, err := st.DeleteAccount(u.ID)
	if err != nil || len(orphans) != 1 {
		t.Fatal(orphans, err)
	}
	e.h.unlinkPending(orphans)
	var n int
	st.db.QueryRow(`SELECT COUNT(*) FROM pending_unlink`).Scan(&n)
	if n != 1 {
		t.Fatalf("删不掉时应保留待删记录：%d", n)
	}
	os.Chmod(dir, 0o755)
	e.h.unlinkPending(nil)
	st.db.QueryRow(`SELECT COUNT(*) FROM pending_unlink`).Scan(&n)
	if _, err := os.Stat(p); n != 0 || !os.IsNotExist(err) {
		t.Fatalf("重试后：待删 %d，文件 %v", n, err)
	}
}
