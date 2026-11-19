package main

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"
)

// 删除是软删除：已删除的 key 字符串不能被别的账号认领，id 也不会被新建的 key 复用
func TestDeletePushkeySoft(t *testing.T) {
	st, err := OpenStore(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	alice, err := st.CreateAccount("alice", "alice-pass-1")
	if err != nil {
		t.Fatal(err)
	}
	bob, err := st.CreateAccount("bob", "bob-pass-12")
	if err != nil {
		t.Fatal(err)
	}
	leaked := "PK_" + strings.Repeat("x", 20) // 测试用的假 key（运行时拼出，源码里不出现像真 key 的字符串）
	k, err := st.CreatePushkeyWith(alice.ID, "泄露的", leaked)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.DeletePushkey(alice.ID, k.ID); !errors.Is(err, errKeyNotRevoked) {
		t.Fatalf("未吊销时应拒绝删除，实际 %v", err)
	}
	if err := st.DeletePushkey(bob.ID, k.ID); err == nil {
		t.Fatal("不能删除别的账号的 key")
	}
	st.RevokePushkey(alice.ID, k.ID)
	if err := st.DeletePushkey(alice.ID, k.ID); err != nil {
		t.Fatal(err)
	}
	if keys, _ := st.ListPushkeys(alice.ID); len(keys) != 0 {
		t.Fatalf("删除后列表里不应出现，实际 %v", keys)
	}
	if _, err := st.PushkeyByID(alice.ID, k.ID); err == nil {
		t.Fatal("删除后按 id 应查不到")
	}
	if err := st.DeletePushkey(alice.ID, k.ID); err == nil {
		t.Fatal("重复删除应返回不存在")
	}
	if _, err := st.CreatePushkeyWith(bob.ID, "认领", leaked); err == nil {
		t.Fatal("别的账号不能用自定义 key 认领已删除的 key 字符串")
	}
	if pk, err := st.PushkeyByKey(leaked); err != nil || pk.UserID != alice.ID || !pk.Revoked {
		t.Fatalf("已删除的 key 推送时仍应是 alice 的已吊销 key：%v %v", pk, err)
	}
	n, err := st.CreatePushkey(bob.ID, "新的")
	if err != nil {
		t.Fatal(err)
	}
	if n.ID == k.ID {
		t.Fatal("新建的 key 不应复用已删除 key 的 id")
	}
}
