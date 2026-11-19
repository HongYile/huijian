package main

import (
	"path/filepath"
	"testing"
	"time"
)

func TestPairCodeLifecycle(t *testing.T) {
	st, err := OpenStore(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	alice, _ := st.CreateAccount("alice", "alice-pass-1")
	bob, _ := st.CreateAccount("bob", "bob-pass-12")
	fp := func(s string) string { return sha256Hex(s) }

	if pairCodeTTL != 3*time.Minute {
		t.Fatalf("配对码有效期应为 3 分钟，现在是 %v", pairCodeTTL)
	}
	c1, err := st.CreatePairCode(alice.ID, pairCodeTTL, false, "d_mac")
	if err != nil {
		t.Fatal(err)
	}
	if s, left, _, _, _ := st.PairCodeStatus(alice.ID, c1); s != "waiting" || left < 170 || left > 180 {
		t.Fatalf("新配对码应为 waiting、约 180 秒：%s %d", s, left)
	}
	if _, _, _, _, err := st.PairCodeStatus(bob.ID, c1); err == nil {
		t.Fatal("别的账号不应查到这个配对码")
	}

	// 同一台设备重新生成：旧码立即作废，新码有效
	c2, _ := st.CreatePairCode(alice.ID, pairCodeTTL, false, "d_mac")
	if s, _, _, _, _ := st.PairCodeStatus(alice.ID, c1); s != "expired" {
		t.Fatalf("重新生成后旧码应作废：%s", s)
	}
	if _, _, _, err := st.Pair(c1, pairReq{Name: "旧码手机", Platform: "android", Fingerprint: fp("x1")}); err == nil {
		t.Fatal("作废的配对码不应能配对")
	}
	// 另一台设备生成的码不受影响
	c3, _ := st.CreatePairCode(alice.ID, pairCodeTTL, false, "d_other")
	if s, _, _, _, _ := st.PairCodeStatus(alice.ID, c2); s != "waiting" {
		t.Fatalf("别的设备生成新码不应作废这台设备的码：%s", s)
	}

	// 使用后显示被哪台设备使用；只能用一次
	d, _, _, err := st.Pair(c2, pairReq{Name: "Redmi K70", Platform: "android", Fingerprint: fp("k70")})
	if err != nil || d.UserID != alice.ID {
		t.Fatalf("配对失败：%v", err)
	}
	if s, _, by, at, _ := st.PairCodeStatus(alice.ID, c2); s != "used" || by != "Redmi K70" || at == 0 {
		t.Fatalf("使用后状态不对：%s %q %d", s, by, at)
	}
	if _, _, _, err := st.Pair(c2, pairReq{Name: "第二台", Platform: "android", Fingerprint: fp("k71")}); err == nil {
		t.Fatal("配对码不能重复使用")
	}

	// 过期
	st.db.Exec(`UPDATE pair_codes SET expires_at=? WHERE code=?`, now()-5, c3)
	if s, _, _, _, _ := st.PairCodeStatus(alice.ID, c3); s != "expired" {
		t.Fatalf("过期后应为 expired：%s", s)
	}
	// 过期超过一小时的记录被清理（生成新码时顺带清理）
	st.db.Exec(`UPDATE pair_codes SET expires_at=? WHERE code=?`, now()-4000, c3)
	st.CreatePairCode(alice.ID, pairCodeTTL, false, "")
	if _, _, _, _, err := st.PairCodeStatus(alice.ID, c3); err == nil {
		t.Fatal("过期一小时以上的配对码应被清理")
	}
}
