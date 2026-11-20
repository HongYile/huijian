package main

import (
	"path/filepath"
	"testing"
)

// 设置实时同步：key / 设备 / 账户的修改都要在变更流里留下 keys / devices / account（id 0），并唤醒同账号的长轮询
func TestSettingsChangesRecorded(t *testing.T) {
	st, err := OpenStore(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	woke := map[int64]int{}
	st.notify = func(uid int64) { woke[uid]++ }
	alice, _ := st.CreateAccount("alice", "alice-pass-1")
	bob, _ := st.CreateAccount("bob", "bob-pass-12")
	_, cur, _, _ := st.Changes(alice.ID, -1, 100)

	// expect：执行 f 之后，alice 的变更流里新增且只新增这些 kind（id 都是 0），并唤醒过 alice
	expect := func(name string, f func(), kinds ...string) {
		t.Helper()
		before := woke[alice.ID]
		f()
		ch, next, _, err := st.Changes(alice.ID, cur, 100)
		if err != nil {
			t.Fatal(err)
		}
		if len(ch) != len(kinds) {
			t.Fatalf("%s：变更 %+v，期望 %v", name, ch, kinds)
		}
		for i, c := range ch {
			if c.Kind != kinds[i] || c.ID != 0 {
				t.Fatalf("%s：第 %d 条变更 %+v，期望 kind=%s id=0", name, i, c, kinds[i])
			}
		}
		if len(kinds) > 0 && woke[alice.ID] == before {
			t.Fatalf("%s：没有唤醒长轮询", name)
		}
		cur = next
	}

	var pk *Pushkey
	expect("新建 key", func() { pk, _ = st.CreatePushkey(alice.ID, "a") }, "keys")
	expect("新建自定义 key", func() { st.CreatePushkeyWith(alice.ID, "b", "PK_custom_key_123") }, "keys")
	expect("改名", func() {
		if err := st.UpdatePushkey(alice.ID, pk.ID, "a2", ""); err != nil {
			t.Fatal(err)
		}
	}, "keys")
	expect("吊销", func() { st.RevokePushkey(alice.ID, pk.ID) }, "keys")
	expect("重复吊销不记变更", func() { st.RevokePushkey(alice.ID, pk.ID) })
	expect("吊销别人的 key 不记变更", func() { st.RevokePushkey(bob.ID, pk.ID) })
	expect("删除", func() {
		if err := st.DeletePushkey(alice.ID, pk.ID); err != nil {
			t.Fatal(err)
		}
	}, "keys")
	expect("改已吊销的 key 失败时不记变更", func() { st.UpdatePushkey(alice.ID, pk.ID, "x", "") })

	var dev *Device
	expect("登录新设备", func() {
		d, _, _, err := st.LoginDevice(pairReq{UserID: alice.ID, Name: "Mac", Platform: "macos", Fingerprint: "fp-mac-0001"})
		if err != nil {
			t.Fatal(err)
		}
		dev = d
	}, "devices")
	expect("改设备名", func() { st.RenameDevice(alice.ID, dev.ID, "我的 Mac") }, "devices")
	// 只有本机能改、也只在本机显示的设置不广播
	expect("接收规则不广播", func() { st.SetDeviceKeyMode(dev.ID, 1, "silent") })
	expect("离开静音不广播", func() { st.SetAwaySilent(dev.ID, true) })
	expect("Bark 设置不广播", func() { st.SetBarkConfig(dev.ID, barkConfig{URL: "https://api.day.app/x/"}) })
	expect("配对码配对", func() {
		code, err := st.CreatePairCode(alice.ID, 60e9, "")
		if err != nil {
			t.Fatal(err)
		}
		if _, _, _, err := st.Pair(code, pairReq{Name: "手机", Platform: "ios", Fingerprint: "fp-ios-0001"}); err != nil {
			t.Fatal(err)
		}
	}, "devices")
	expect("移除设备", func() { st.RevokeDevice(alice.ID, dev.ID) }, "devices")
	expect("重复移除不记变更", func() { st.RevokeDevice(alice.ID, dev.ID) })
	expect("注销全部登录", func() {
		if n, err := st.LogoutAccount(alice.ID); err != nil || n != 1 { // 还剩配对上的手机
			t.Fatalf("注销全部登录：%d %v", n, err)
		}
	}, "devices")
	expect("没有设备时注销不记变更", func() { st.LogoutAccount(alice.ID) })
	expect("改密码", func() {
		if err := st.SetCredentials(alice.ID, "alice", "alice-pass-2"); err != nil {
			t.Fatal(err)
		}
	}, "account")
	expect("用户名被占用时不记变更", func() { st.SetCredentials(alice.ID, "bob", "") })
	expect("停用账号", func() { st.SetAccountDisabled(alice.ID, true) }, "account")

	if bc, _, _, _ := st.Changes(bob.ID, 0, 100); len(bc) != 0 {
		t.Fatalf("bob 不应看到 alice 的设置变更：%+v", bc)
	}
	if woke[bob.ID] != 0 {
		t.Fatal("不应唤醒 bob 的长轮询")
	}
}
