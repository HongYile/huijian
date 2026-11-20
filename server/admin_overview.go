package main

// 管理后台概览（0.9.0）：全服务器的统计数字，不含任何账号的消息内容、key、设备名或 IP。

import "net/http"

func (h *Hub) pageOverview(w http.ResponseWriter, r *http.Request) {
	d := h.base(r, "overview", "概览")
	d["Accounts"] = h.st.AccountCounts()
	d["Active1"], d["Active7"], d["Active30"] = h.st.ActiveAccounts(1), h.st.ActiveAccounts(7), h.st.ActiveAccounts(30)
	days := h.st.DailyStats(30)
	d["Days"] = days
	d["Msgs30"], d["New30"] = sumStats(days)
	plats := h.DevicePlatforms()
	var devices, outdated int
	for _, p := range plats {
		devices += p.Total
		outdated += p.Outdated
	}
	d["Platforms"], d["Devices"], d["Outdated"] = plats, devices, outdated
	d["Online"] = h.br.OnlineCount()
	d["AttCount"], d["AttBytes"] = h.st.AttachmentTotals()
	d["Storage"] = h.storageInfo(false)
	d["InvIssued"], d["InvUsed"] = h.st.InviteTotals()
	d["Mode"] = h.st.RegisterMode()
	render(w, "overview", d)
}
