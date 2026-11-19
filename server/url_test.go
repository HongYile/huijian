package main

import (
	"net/http/httptest"
	"testing"
)

// 管理后台登录链接 / 公网地址在各种部署方式下的推导
func TestAdminURL(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
		host string // 请求的 Host；空表示命令行（r == nil）
		want string
	}{
		{"显式 ADMIN_URL 优先", map[string]string{"HUIJIAN_ADMIN_URL": "https://adm.example.com/", "HUIJIAN_ADMIN_ADDR": "10.0.0.2:8791"}, "1.2.3.4:8790", "https://adm.example.com"},
		{"中转部署：只监听内网地址", map[string]string{"HUIJIAN_ADMIN_ADDR": "10.0.0.2:8791", "HUIJIAN_PUBLIC_URL": "https://push.example.com"}, "push.example.com", "http://10.0.0.2:8791"},
		{"本机监听（SSH 隧道）", map[string]string{"HUIJIAN_ADMIN_ADDR": "127.0.0.1:8791"}, "1.2.3.4:8790", "http://127.0.0.1:8791"},
		{"docker：宿主机只绑本机", map[string]string{"HUIJIAN_ADMIN_ADDR": "0.0.0.0:8791", "HUIJIAN_ADMIN_BIND": "127.0.0.1", "HUIJIAN_PUBLIC_URL": "https://push.example.com"}, "push.example.com", "http://127.0.0.1:8791"},
		{"docker：公网 IP 直连，跟随请求主机", map[string]string{"HUIJIAN_ADMIN_ADDR": "0.0.0.0:8791", "HUIJIAN_ADMIN_BIND": "0.0.0.0"}, "1.2.3.4:8790", "http://1.2.3.4:8791"},
		{"docker：端口映射后的对外端口", map[string]string{"HUIJIAN_ADMIN_ADDR": "0.0.0.0:8791", "HUIJIAN_ADMIN_PORT": "18791"}, "1.2.3.4:18790", "http://1.2.3.4:18791"},
		{"docker：用 PUBLIC_URL 的主机名", map[string]string{"HUIJIAN_ADMIN_ADDR": "0.0.0.0:8791", "HUIJIAN_PUBLIC_URL": "http://5.6.7.8:8790"}, "", "http://5.6.7.8:8791"},
		{"命令行无法推导", map[string]string{"HUIJIAN_ADMIN_ADDR": "0.0.0.0:8791"}, "", ""},
		{"未设置 ADMIN_ADDR 时按默认的本机监听", map[string]string{"HUIJIAN_PUBLIC_URL": "https://push.example.com"}, "push.example.com", "http://127.0.0.1:8791"},
		{"异常 Host 不拼出无效地址", map[string]string{"HUIJIAN_ADMIN_ADDR": "0.0.0.0:8791"}, "evil.com/x", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			for _, k := range []string{"HUIJIAN_ADMIN_URL", "HUIJIAN_ADMIN_ADDR", "HUIJIAN_ADMIN_BIND", "HUIJIAN_ADMIN_PORT", "HUIJIAN_PUBLIC_URL"} {
				t.Setenv(k, c.env[k])
			}
			var got string
			if c.host == "" {
				got = adminURL(nil)
			} else {
				r := httptest.NewRequest("GET", "/", nil)
				r.Host = c.host
				got = adminURL(r)
			}
			if got != c.want {
				t.Fatalf("得到 %q，期望 %q", got, c.want)
			}
		})
	}
}

func TestPublicURL(t *testing.T) {
	t.Setenv("HUIJIAN_PUBLIC_URL", "")
	t.Setenv("HUIJIAN_PUBLIC_ADDR", "0.0.0.0:8790")
	t.Setenv("HUIJIAN_PUBLIC_PORT", "")
	r := httptest.NewRequest("GET", "/", nil)
	r.Host = "1.2.3.4:8791"
	if got := publicURL(r); got != "http://1.2.3.4:8790" {
		t.Fatalf("跟随管理页主机：%q", got)
	}
	t.Setenv("HUIJIAN_PUBLIC_ADDR", "10.0.0.2:8790")
	if got := publicURL(r); got != "http://10.0.0.2:8790" {
		t.Fatalf("明确的监听地址优先于请求主机：%q", got)
	}
	t.Setenv("HUIJIAN_PUBLIC_ADDR", "0.0.0.0:8790")
	r.Host = ""
	if got := publicURL(r); got != "http://127.0.0.1:8790" {
		t.Fatalf("Host 为空时不应拼出 http://:8790：%q", got)
	}
	t.Setenv("HUIJIAN_PUBLIC_URL", "https://push.example.com/")
	if got := publicURL(r); got != "https://push.example.com" {
		t.Fatalf("显式 PUBLIC_URL：%q", got)
	}
}
