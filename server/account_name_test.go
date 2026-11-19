package main

import "testing"

func TestUsernameRules(t *testing.T) {
	ok := []string{"me", "Alex Chen", "  Alex   Chen ", "张三", "张 三", "a.b-c_d", "Mary Jane Watson", "Alex\u3000Chen", "〇号", "第①组"}
	bad := []string{"a", " ", "a/b", "a@b", "x\ty\nz!", "123456789012345678901234567890123", "Alex\u3164Chen", "\u3164\u3164", "a\u200bb"}
	for _, u := range ok {
		if !validUsername(normUsername(u)) {
			t.Errorf("应当允许 %q（规范化后 %q）", u, normUsername(u))
		}
	}
	for _, u := range bad {
		if validUsername(normUsername(u)) {
			t.Errorf("应当拒绝 %q", u)
		}
	}
	if normUsername("  Alex   Chen ") != "Alex Chen" {
		t.Errorf("空格没有合并：%q", normUsername("  Alex   Chen "))
	}
	if usernameKey("ALEX  chen") != usernameKey("alex chen") {
		t.Error("登录时用户名大小写、空格数量不同应当视为同一个")
	}
}
