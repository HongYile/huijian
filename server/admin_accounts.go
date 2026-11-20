package main

// 管理后台的账号管理（0.9.0：管理后台只管账号）。
//
// 管理后台是服务器级的，但只能管理账号本身：停用 / 启用、注销全部登录、删除，以及注册模式。
// 不能建账号（账号只能注册产生），也不能改任何账号的用户名和密码（改了密码就能登录进别人的账号）。
// 任何账号（包括第一个账号）都不能从客户端进入管理后台：后台只能在服务器上用 huijian admin-link 或管理令牌进入。
// 看不到任何账号的消息内容、pushkey、设备名和 IP，也不能切换到某个账号去操作——
// pushkey 和设备只能由用户在自己的客户端里管理（/v1/keys、/v1/pair 等自助接口）。

import (
	"net/http"
	"strconv"
	"strings"
)

func (h *Hub) pageAccounts(w http.ResponseWriter, r *http.Request) {
	d := h.base(r, "accounts", "账号")
	d["Accounts"], _ = h.st.ListAccounts()
	d["Mode"] = h.st.RegisterMode()
	d["Owner"] = h.st.OwnerID()
	render(w, "accounts", d)
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

// POST /accounts/{id}/logout：注销全部登录（吊销这个账号所有设备的 token）
func (h *Hub) adminLogoutAccount(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	a, err := h.st.AccountByID(id)
	if err != nil {
		redirectFlash(w, r, "/accounts", "账号不存在")
		return
	}
	n, err := h.st.LogoutAccount(id)
	if err != nil {
		redirectFlash(w, r, "/accounts", "操作失败")
		return
	}
	h.br.Notify(id) // 正在长轮询的设备立刻醒来，下一次请求就是 401
	redirectFlash(w, r, "/accounts", "已注销「"+a.Label()+"」的全部登录（"+strconv.Itoa(n)+" 台设备），用户用密码重新登录即可")
}

// POST /accounts/register  mode=closed / invite / open（兼容旧表单 on=1 开放 / on=0 关闭）
func (h *Hub) adminRegisterToggle(w http.ResponseWriter, r *http.Request) {
	mode := r.FormValue("mode")
	if mode == "" {
		mode = map[bool]string{true: regOpen, false: regClosed}[r.FormValue("on") == "1"]
	}
	back := "/accounts"
	if strings.HasSuffix(r.Referer(), "/invites") || strings.Contains(r.Referer(), "/invites?") {
		back = "/invites"
	}
	if err := h.st.SetRegisterMode(mode); err != nil {
		redirectFlash(w, r, back, err.Error())
		return
	}
	msg := map[string]string{
		regOpen:   "已开放注册：任何知道服务器地址的人都可以在客户端注册账号",
		regInvite: "已改为需要邀请码：在「邀请码」页生成后发给要注册的人",
		regClosed: "已关闭注册：不再产生新账号",
	}[mode]
	redirectFlash(w, r, back, msg)
}

const adminAccountTemplates = `
{{define "accounts"}}{{template "top" .}}
<div class="head"><div><h1>账号</h1><div class="sub">一个账号 = 一个人，只能由用户在回笺客户端里注册产生（注册时就开启加密）。这里只能停用、注销登录和删除账号，不能改用户名和密码（改了密码就能登录进别人的账号）；pushkey、设备和消息由用户在自己的回笺客户端里管理，服务器上的消息只有密文。</div></div></div>

<div class="card"><div class="card-h"><h2>所有账号</h2><span class="aside">{{len .Accounts}} 个</span></div>
<div class="tblwrap"><table class="tbl accts"><tr><th>用户名</th><th>创建时间</th><th>最后活跃</th><th class="num">设备</th><th class="num">消息</th><th class="num">占用空间</th><th>加密</th><th>状态</th><th class="r"></th></tr>
{{range .Accounts}}<tr class="{{if .Disabled}}rev{{end}}">
<td><b>{{.Label}}</b>{{if eq .ID $.Owner}} <span class="chip acc" title="服务器自己的通知（备份失败、附件目录不可用）发给这个账号">第一个账号</span>{{end}}
{{if ne .ID $.Owner}}<details class="edit"><summary class="small" style="color:var(--p5)">删除账号</summary>
<form method="post" action="/accounts/{{.ID}}/delete" class="row" data-confirm="彻底删除「{{.Label}}」？消息、附件、pushkey、设备和加密钥匙全部删除，无法恢复。"><input class="in" name="confirm" placeholder="输入「{{.Label}}」确认" required autocomplete="off" style="width:180px"><button class="btn sm danger">删除</button></form></details>{{end}}</td>
<td class="muted" title="{{full .Created}}">{{rel .Created}}</td>
<td class="muted">{{if .LastActive}}<span title="{{full .LastActive}}">{{rel .LastActive}}</span>{{else}}从未{{end}}</td>
<td class="num">{{.Devices}}</td><td class="num">{{.Messages}}</td><td class="num">{{size .Bytes}}</td>
<td>{{if .Encrypted}}<span class="chip ok" title="服务器上只保存密文">已加密</span>{{if .Plain}} <span class="chip warn" title="开启加密以前的明文消息，服务器正在补加密">补加密中 {{.Plain}} 条</span>{{end}}{{else}}<span class="chip warn" title="0.9 以前建的旧账号还没有加密钥匙：用户用密码登录新版客户端时自动开启。在那之前发给这个账号的消息会被拒收（服务器不保存明文）">未加密（旧账号，登录后自动开启）</span>{{end}}</td>
<td>{{if .Disabled}}<span class="chip bad">已停用</span>{{else}}<span class="chip ok">正常</span>{{end}}</td>
<td class="r nowrap">{{if .Devices}}<form class="inline" method="post" action="/accounts/{{.ID}}/logout" data-confirm="注销「{{.Label}}」的全部登录？它的 {{.Devices}} 台设备都要用密码重新登录（消息和 pushkey 保留）。"><button class="btn sm">注销全部登录</button></form>{{end}}
{{if ne .ID $.Owner}}<form class="inline" method="post" action="/accounts/{{.ID}}/disable"{{if not .Disabled}} data-confirm="停用「{{.Label}}」？它的设备将无法接收消息，pushkey 无法发送。"{{end}}><input type="hidden" name="on" value="{{if .Disabled}}0{{else}}1{{end}}"><button class="btn sm{{if not .Disabled}} danger{{end}}">{{if .Disabled}}启用{{else}}停用{{end}}</button></form>{{end}}</td></tr>{{end}}
</table></div></div>

<div class="card"><div class="card-h"><h2>注册</h2><a class="small" href="/invites">邀请码 →</a></div><div class="card-b">{{template "regmode" .}}</div></div>
{{template "bottom" .}}{{end}}
`
