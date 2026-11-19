package main

// 管理后台的账号管理。
//
// 管理后台是服务器级的（管理员看得到所有账号）。页面上方可以切换「当前账号」，
// 概览、消息、Pushkey、设备页显示的都是当前账号的数据；切换记在 cookie 里。
// 设备页按名称或设备 ID 搜索时跨所有账号查找（客户报设备 ID 时不用先知道是哪个账号）。

import (
	"net/http"
	"strconv"
	"strings"
)

const acctCookie = "huijian_acct"

// acct：管理后台当前查看的账号（默认第一个账号）
func (h *Hub) acct(r *http.Request) int64 {
	if c, err := r.Cookie(acctCookie); err == nil {
		if id, err := strconv.ParseInt(c.Value, 10, 64); err == nil {
			if _, err := h.st.AccountByID(id); err == nil {
				return id
			}
		}
	}
	return h.st.OwnerID()
}

// writeAcct：写操作的目标账号。表单里带着页面显示时的账号 id（隐藏字段 u），
// 和当前 cookie 不一致说明在另一个标签页切换过账号，拒绝，避免把配对码 / key 建到别的账号里
func (h *Hub) writeAcct(w http.ResponseWriter, r *http.Request) (int64, bool) {
	cur := h.acct(r)
	if u := r.FormValue("u"); u != "" && u != strconv.FormatInt(cur, 10) {
		back := r.Header.Get("Referer")
		if i := strings.Index(back, "://"); i >= 0 {
			if j := strings.Index(back[i+3:], "/"); j >= 0 {
				back = back[i+3+j:]
			} else {
				back = "/"
			}
		}
		if !strings.HasPrefix(back, "/") || strings.HasPrefix(back, "//") {
			back = "/"
		}
		if k := strings.Index(back, "?"); k >= 0 {
			back = back[:k]
		}
		redirectFlash(w, r, back, "当前账号已在另一个标签页切换，页面已刷新，请确认账号后再操作")
		return 0, false
	}
	return cur, true
}

func setAcctCookie(w http.ResponseWriter, id int64) {
	http.SetCookie(w, &http.Cookie{Name: acctCookie, Value: strconv.FormatInt(id, 10), Path: "/", HttpOnly: true,
		SameSite: http.SameSiteStrictMode, MaxAge: 365 * 24 * 3600})
}

// GET /switch?u=<id>&back=<路径>：切换当前账号
func (h *Hub) adminSwitch(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.URL.Query().Get("u"), 10, 64)
	a, err := h.st.AccountByID(id)
	if err != nil {
		redirectFlash(w, r, "/accounts", "账号不存在")
		return
	}
	setAcctCookie(w, id)
	back := r.URL.Query().Get("back")
	if !strings.HasPrefix(back, "/") || strings.HasPrefix(back, "//") {
		back = "/"
	}
	redirectFlash(w, r, back, "当前账号："+a.Label())
}

func (h *Hub) pageAccounts(w http.ResponseWriter, r *http.Request) {
	d := h.base(r, "accounts", "账号")
	d["Accounts"], _ = h.st.ListAccounts()
	d["RegisterOpen"] = h.registerOpen()
	d["Owner"] = h.st.OwnerID()
	render(w, "accounts", d)
}

// POST /accounts：新建账号（不预置 pushkey）
func (h *Hub) adminCreateAccount(w http.ResponseWriter, r *http.Request) {
	a, err := h.st.CreateAccount(r.FormValue("username"), r.FormValue("password"))
	if err != nil {
		redirectFlash(w, r, "/accounts", err.Error())
		return
	}
	redirectFlash(w, r, "/accounts", "已创建账号「"+a.Username+"」")
}

// POST /accounts/{id}/credentials：设置用户名 / 重设密码（密码留空表示只改用户名）
func (h *Hub) adminSetCredentials(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	a, err := h.st.AccountByID(id)
	if err != nil {
		redirectFlash(w, r, "/accounts", "账号不存在")
		return
	}
	pw := r.FormValue("password")
	if !a.HasPassword && pw == "" {
		redirectFlash(w, r, "/accounts", "这个账号还没有密码，请同时设置密码（"+passwordRule+"）")
		return
	}
	if err := h.st.SetCredentials(id, r.FormValue("username"), pw); err != nil {
		redirectFlash(w, r, "/accounts", err.Error())
		return
	}
	msg := "已保存"
	if pw != "" {
		msg = "已保存，新密码立即生效（已登录的设备不受影响）"
	}
	redirectFlash(w, r, "/accounts", msg)
}

// POST /accounts/{id}/disable  on=1 停用 / on=0 启用
func (h *Hub) adminDisableAccount(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	on := r.FormValue("on") == "1"
	if on && id == h.st.OwnerID() {
		redirectFlash(w, r, "/accounts", "第一个账号接收服务器自己的通知（备份失败等），不能停用")
		return
	}
	if err := h.st.SetAccountDisabled(id, on); err != nil {
		redirectFlash(w, r, "/accounts", "操作失败")
		return
	}
	if on {
		redirectFlash(w, r, "/accounts", "已停用：它的设备无法再接收消息，pushkey 无法再发送")
		return
	}
	redirectFlash(w, r, "/accounts", "已启用")
}

// POST /accounts/register  on=1 开放注册 / on=0 关闭
func (h *Hub) adminRegisterToggle(w http.ResponseWriter, r *http.Request) {
	on := r.FormValue("on") == "1"
	h.st.SetKV("register_open", b2i(on))
	if on {
		redirectFlash(w, r, "/accounts", "已开放注册：任何知道服务器地址的人都可以在客户端注册账号")
		return
	}
	redirectFlash(w, r, "/accounts", "已关闭注册")
}

// accountLabels：id → 显示名（设备搜索结果里标出所属账号）
func (h *Hub) accountLabels() map[int64]string {
	out := map[int64]string{}
	accts, _ := h.st.ListAccounts()
	for _, a := range accts {
		out[a.ID] = a.Label()
	}
	return out
}

const adminAccountTemplates = `
{{define "acctbar"}}{{if gt (len .AcctList) 1}}<form method="get" action="/switch" class="acctbar"><input type="hidden" name="back" value="{{.Path}}">
<span class="muted small">当前账号</span><select name="u" class="in sm" onchange="this.form.submit()">{{range .AcctList}}<option value="{{.ID}}"{{if eq .ID $.Acct.ID}} selected{{end}}>{{.Label}}{{if .Disabled}}（已停用）{{end}}</option>{{end}}</select></form>{{end}}{{end}}

{{define "accounts"}}{{template "top" .}}
<div class="head"><div><h1>账号</h1><div class="sub">一个账号 = 一个人，有自己的 pushkey、设备和消息历史。设备用账号配对码或用户名密码加入账号。</div></div></div>

<div class="card"><div class="card-h"><h2>所有账号</h2></div>
<table class="tbl"><tr><th>账号</th><th>设备</th><th>Pushkey</th><th>消息</th><th>创建时间</th><th>状态</th><th class="r"></th></tr>
{{range .Accounts}}<tr class="{{if .Disabled}}rev{{end}}">
<td><b>{{.Label}}</b>{{if eq .ID $.Owner}} <span class="chip acc" title="服务器自己的通知（备份失败、附件目录不可用）发给这个账号">第一个账号</span>{{end}}
{{if not .HasPassword}}<div class="small muted">还没有密码：设置后可以在其他设备上用密码登录</div>{{end}}
<details class="edit"><summary class="muted small">{{if .HasPassword}}改用户名 / 重设密码{{else}}设置用户名和密码{{end}}</summary>
<form method="post" action="/accounts/{{.ID}}/credentials" class="row"><input class="in" name="username" value="{{.Username}}" placeholder="用户名" required maxlength="64" style="width:140px">
<input class="in" type="password" name="password" placeholder="{{if .HasPassword}}新密码（留空不改）{{else}}密码，至少 8 位{{end}}" minlength="8" autocomplete="new-password" style="width:180px"{{if not .HasPassword}} required{{end}}><button class="btn sm">保存</button></form></details></td>
<td>{{.Devices}}</td><td>{{.Keys}}</td><td>{{.Messages}}</td>
<td class="muted" title="{{full .Created}}">{{rel .Created}}</td>
<td>{{if .Disabled}}<span class="chip bad">已停用</span>{{else}}<span class="chip ok">正常</span>{{end}}</td>
<td class="r"><a class="btn sm" href="/switch?u={{.ID}}&back=/devices">查看</a>
{{if ne .ID $.Owner}}<form class="inline" method="post" action="/accounts/{{.ID}}/disable"{{if not .Disabled}} data-confirm="停用「{{.Label}}」？它的设备将无法接收消息，pushkey 无法发送。"{{end}}><input type="hidden" name="on" value="{{if .Disabled}}0{{else}}1{{end}}"><button class="btn sm{{if not .Disabled}} danger{{end}}">{{if .Disabled}}启用{{else}}停用{{end}}</button></form>{{end}}</td></tr>{{end}}
</table></div>

<div class="card"><div class="card-h"><h2>新建账号</h2><span class="aside">不预置 pushkey，由账号自己新建</span></div><div class="card-b">
<form method="post" action="/accounts" class="row"><input class="in" name="username" placeholder="用户名，例如 Alex Chen" required maxlength="64" style="width:180px">
<input class="in" type="password" name="password" placeholder="初始密码，至少 8 位" required minlength="8" autocomplete="new-password" style="width:200px">
<button class="btn primary">{{template "i-plus"}}创建</button></form>
<p class="muted small" style="margin:10px 0 0">把服务器地址、用户名和密码告诉对方，在回笺客户端里选「账号登录」即可；也可以切换到该账号后在「设备」页生成配对码。</p>
</div></div>

<div class="card"><div class="card-h"><h2>开放注册</h2></div><div class="card-b row" style="justify-content:space-between">
<div class="small">{{if .RegisterOpen}}<b>已开放</b>：任何知道服务器地址的人都可以在客户端注册账号。{{else}}<b>已关闭</b>（推荐）：只有管理员能创建账号。{{end}}</div>
<form method="post" action="/accounts/register"><input type="hidden" name="on" value="{{if .RegisterOpen}}0{{else}}1{{end}}"><button class="btn sm{{if not .RegisterOpen}} danger{{end}}">{{if .RegisterOpen}}关闭注册{{else}}开放注册{{end}}</button></form>
</div></div>
{{template "bottom" .}}{{end}}
`
