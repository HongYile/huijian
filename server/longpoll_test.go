package main

import (
	"encoding/json"
	"net/http/httptest"
	"path/filepath"
	"testing"
)

// 0.6.4：长轮询上限可配置（默认 600 秒，限制在 55–3600），并在 /v1/info 里公布给客户端
func TestLongPollMax(t *testing.T) {
	for _, c := range []struct {
		env  string
		want int
	}{{"", 600}, {"abc", 600}, {"30", 55}, {"55", 55}, {" 900 ", 900}, {"99999", 3600}} {
		t.Setenv("HUIJIAN_LONGPOLL_MAX", c.env)
		if got := longPollMax(); got != c.want {
			t.Fatalf("HUIJIAN_LONGPOLL_MAX=%q：得到 %d，期望 %d", c.env, got, c.want)
		}
	}

	t.Setenv("HUIJIAN_LONGPOLL_MAX", "300")
	st, err := OpenStore(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	h := &Hub{st: st}
	rec := httptest.NewRecorder()
	h.handleInfo(rec, httptest.NewRequest("GET", "/v1/info", nil))
	var info struct {
		LongPollMax int `json:"long_poll_max"`
		Features    []feature
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	if info.LongPollMax != 300 {
		t.Fatalf("long_poll_max = %d，期望 300", info.LongPollMax)
	}
	found := false
	for _, f := range info.Features {
		found = found || f.ID == "poll.long"
	}
	if !found {
		t.Fatal("features 里缺少 poll.long")
	}
}
