package main

// 运营方在服务器上用的命令行（0.9.0）：不经过任何账号，走本机管理端口 + 管理令牌。
//
//	huijian invite new [-n 数量] [-uses 次数] [-days 天数] [-note 备注]
//	huijian invite list
//
// 管理端口地址：-admin 参数 > 本机的 HUIJIAN_ADMIN_ADDR（监听 0.0.0.0 时连 127.0.0.1）> HUIJIAN_ADMIN_URL > 127.0.0.1:8791。
// 管理令牌：HUIJIAN_ADMIN_TOKEN > 数据目录里的 admin.token。
// docker：docker exec huijian huijian invite new
// 0.9.0 起账号只能由用户在客户端注册产生（注册即开启加密），没有建号命令

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// ---------- 服务端：管理令牌（Bearer）接口 ----------

// POST /api/invites {"count","uses","days","note"}（都可省略：1 个、1 次、7 天）
func (h *Hub) apiCreateInvites(w http.ResponseWriter, r *http.Request) {
	in := struct {
		Count, Uses, Days int
		Note              string
	}{Count: 1, Uses: 1, Days: 7}
	if !readJSON(w, r, &in) {
		return
	}
	ttl := time.Duration(in.Days) * 24 * time.Hour
	codes, err := h.st.CreateInvites(in.Count, in.Uses, ttl, cleanLabel(in.Note, 60))
	if err != nil {
		apiErr(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"codes": codes, "uses": in.Uses, "expires_at": time.Now().Add(ttl).Unix(), "register": h.st.RegisterMode()})
}

type inviteJSON struct {
	Code      string          `json:"code"`
	Note      string          `json:"note"`
	MaxUses   int             `json:"max_uses"`
	Used      int             `json:"used"`
	ExpiresAt int64           `json:"expires_at"`
	Status    string          `json:"status"` // ok / used_up / expired / revoked
	Uses      []inviteUseJSON `json:"uses"`
}

type inviteUseJSON struct {
	Username string `json:"username"` // 账号已删除时为空
	At       int64  `json:"at"`
	Deleted  bool   `json:"deleted"`
}

// GET /api/invites
func (h *Hub) apiListInvites(w http.ResponseWriter, r *http.Request) {
	list, err := h.st.ListInvites()
	if err != nil {
		apiErr(w, 500, "查询失败")
		return
	}
	out := []inviteJSON{}
	for _, v := range list {
		j := inviteJSON{Code: v.Code, Note: v.Note, MaxUses: v.MaxUses, Used: v.Used, ExpiresAt: v.Expires, Uses: []inviteUseJSON{},
			Status: map[string]string{"可用": "ok", "已用完": "used_up", "已过期": "expired", "已作废": "revoked"}[v.Status]}
		for _, u := range v.Uses {
			name := u.Username
			if u.Deleted {
				name = ""
			}
			j.Uses = append(j.Uses, inviteUseJSON{name, u.At, u.Deleted})
		}
		out = append(out, j)
	}
	writeJSON(w, 200, map[string]any{"invites": out, "register": h.st.RegisterMode()})
}

// ---------- 命令行 ----------

// localAdmin：本机管理端口地址和管理令牌
func localAdmin(override string) (string, string, error) {
	base := strings.TrimRight(override, "/")
	// 先用本机监听地址：docker 里 HUIJIAN_ADMIN_URL 是给浏览器用的外部地址，容器里不一定连得上
	if base == "" && env("HUIJIAN_ADMIN_ADDR", "") == "" {
		base = strings.TrimRight(env("HUIJIAN_ADMIN_URL", ""), "/")
	}
	if base == "" {
		addr := env("HUIJIAN_ADMIN_ADDR", "127.0.0.1:8791")
		host, port, err := net.SplitHostPort(addr)
		if err != nil {
			return "", "", fmt.Errorf("HUIJIAN_ADMIN_ADDR 格式不对：%s", addr)
		}
		if ip := net.ParseIP(host); host == "" || ip != nil && ip.IsUnspecified() {
			host = "127.0.0.1"
		}
		base = "http://" + net.JoinHostPort(host, port)
	}
	tok := strings.TrimSpace(env("HUIJIAN_ADMIN_TOKEN", ""))
	if tok == "" {
		b, err := os.ReadFile(filepath.Join(dataDir(), "admin.token"))
		if err != nil {
			return "", "", fmt.Errorf("读不到管理令牌（%s/admin.token）：请在服务器上执行，或设置 HUIJIAN_ADMIN_TOKEN", dataDir())
		}
		tok = strings.TrimSpace(string(b))
	}
	return base, tok, nil
}

func adminCall(base, tok, method, path string, body any, out any) error {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, base+path, rd)
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return fmt.Errorf("连不上管理端口 %s（服务端在运行吗？）：%v", base, err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode != 200 {
		var e struct{ Error string }
		if json.Unmarshal(b, &e) == nil && e.Error != "" {
			return errors.New(e.Error)
		}
		return fmt.Errorf("HTTP %d：%s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return json.Unmarshal(b, out)
}

func runInviteCLI(args []string) int {
	use := func() int {
		fmt.Fprintln(os.Stderr, "用法: huijian invite new [-n 数量] [-uses 每个可用次数] [-days 有效天数] [-note 备注]\n      huijian invite list")
		return 2
	}
	if len(args) < 1 {
		return use()
	}
	fs := flag.NewFlagSet("invite", flag.ContinueOnError)
	admin := fs.String("admin", "", "管理端口地址（默认本机 HUIJIAN_ADMIN_ADDR）")
	n := fs.Int("n", 1, "数量（1–100）")
	uses := fs.Int("uses", 1, "每个码可用次数")
	days := fs.Int("days", 7, "有效天数")
	note := fs.String("note", "", "备注")
	if fs.Parse(args[1:]) != nil || fs.NArg() != 0 {
		return use()
	}
	base, tok, err := localAdmin(*admin)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	switch args[0] {
	case "new":
		var out struct {
			Codes     []string
			ExpiresAt int64 `json:"expires_at"`
			Register  string
		}
		if err := adminCall(base, tok, "POST", "/api/invites", map[string]any{"count": *n, "uses": *uses, "days": *days, "note": *note}, &out); err != nil {
			fmt.Fprintln(os.Stderr, "生成失败：", err)
			return 1
		}
		for _, c := range out.Codes {
			fmt.Println(c)
		}
		fmt.Fprintf(os.Stderr, "已生成 %d 个，每个可用 %d 次，%s 过期\n", len(out.Codes), *uses, time.Unix(out.ExpiresAt, 0).Format("2006-01-02 15:04"))
		if out.Register != regInvite {
			fmt.Fprintf(os.Stderr, "注意：当前注册模式是 %s，不是 invite（需要邀请码），在管理后台「邀请码」页修改\n", out.Register)
		}
		return 0
	case "list":
		var out struct {
			Invites  []inviteJSON
			Register string
		}
		if err := adminCall(base, tok, "GET", "/api/invites", nil, &out); err != nil {
			fmt.Fprintln(os.Stderr, "查询失败：", err)
			return 1
		}
		fmt.Printf("注册模式：%s\n", out.Register)
		for _, v := range out.Invites {
			var users []string
			for _, u := range v.Uses {
				if u.Deleted {
					users = append(users, "已删除账号")
				} else {
					users = append(users, u.Username)
				}
			}
			fmt.Printf("%s  %-8s  %d/%d  %s 过期  %s  %s\n", v.Code, v.Status, v.Used, v.MaxUses,
				time.Unix(v.ExpiresAt, 0).Format("2006-01-02"), strings.Join(users, ","), v.Note)
		}
		return 0
	}
	return use()
}
