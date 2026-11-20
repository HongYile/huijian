package main

import (
	"path/filepath"
	"testing"
)

// 管理后台的「较旧」标记：只和这个平台在本服务器上发布过的最新版本比；没有发布记录时不标（各端版本线独立）
func TestClientOutdated(t *testing.T) {
	st, err := OpenStore(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	h := &Hub{st: st}
	if err := st.InsertRelease(&Release{Platform: "macos", Version: "0.7.1", Build: 130, Sha256: "x", Size: 1, Signature: "s"}); err != nil {
		t.Fatal(err)
	}
	for label, want := range map[string]bool{
		"android 0.4.0 (114)": false, // 安卓从没在这台服务器发布过：不能和服务端 0.8 比
		"ios 0.4.0 (120)":     false,
		"macos 0.7.0 (125)":   true, // 低于已发布的 0.7.1
		"macos 0.7.1 (130)":   false,
		"macos 0.8.0 (140)":   false,
		"android":             true, // 没上报版本号的旧客户端
		"":                    true,
	} {
		if got := h.clientOutdated(label); got != want {
			t.Errorf("clientOutdated(%q) = %v，应为 %v", label, got, want)
		}
	}
}
