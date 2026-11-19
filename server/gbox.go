package main

// iPhone 客户端的安装与更新：不上架 App Store，用户用 GBox 等自签工具安装。
// GBox 支持「软件源」（JSON，格式见 https://github.com/GBoxApp/GBoxSource）：在 GBox 里添加一次
// <服务器>/ios/gbox.appsrc，以后发布新版本（huijian release，平台 ios），GBox 里就能看到并一键重签安装。
//
//	GET /ios/gbox.appsrc             软件源，列出最新的 iOS 版本
//	GET /ios/Huijian-<版本>-<构建号>.ipa  安装包（支持 Range）
//	GET /icon.png                    App 图标（软件源和 Bark 通知用）
//
// 这几个地址不需要登录（GBox 拉取时不会带 token）。安装包是公开构建，不含任何账号信息；
// 设置 HUIJIAN_IOS_SOURCE=0 可以关闭。

import (
	"fmt"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"time"
)

func iosSourceEnabled() bool { return env("HUIJIAN_IOS_SOURCE", "1") != "0" }

func (h *Hub) handleGBoxSource(w http.ResponseWriter, r *http.Request) {
	if !iosSourceEnabled() {
		http.NotFound(w, r)
		return
	}
	rel, err := h.st.LatestRelease("ios")
	if err != nil || rel == nil {
		apiErr(w, 404, "还没有发布 iOS 版本")
		return
	}
	base := publicURL(r)
	ts := func(t int64) string { return time.Unix(t, 0).In(time.FixedZone("", 8*3600)).Format("2006-01-02T15:04:05-0700") }
	w.Header().Set("Cache-Control", "no-cache")
	writeJSON(w, 200, map[string]any{
		"version":           "1.1.2",
		"sourceName":        "回笺",
		"sourceAuthor":      "Huijian",
		"sourceLinkTitle":   "主页",
		"sourceLinkUrl":     "https://github.com/HongYile/huijian",
		"sourceImage":       base + "/icon.png",
		"sourceUpdateTime":  ts(rel.Created), // GBox 只在这个时间变化时重新解析列表
		"sourceDescription": "回笺 iPhone 客户端：自托管的分级推送",
		"appCategories":     []string{"工具"},
		"appRepositories": []map[string]any{{
			"appType":        "SELF_SIGN",
			"appCateIndex":   0,
			"appUpdateTime":  ts(rel.Created),
			"appName":        "回笺",
			"appVersion":     rel.Version,
			"appImage":       base + "/icon.png",
			"appPackage":     fmt.Sprintf("%s/ios/Huijian-%s-%d.ipa", base, rel.Version, rel.Build),
			"appDescription": fmt.Sprintf("%s（build %d）\n%s", rel.Version, rel.Build, rel.Notes),
		}},
	})
}

var ipaName = regexp.MustCompile(`^(?:Huijian|Hongyan)-[0-9A-Za-z.\-]+-([0-9]+)\.ipa$`) // 旧名：GBox 缓存的改名前地址

func (h *Hub) handleIPA(w http.ResponseWriter, r *http.Request) {
	m := ipaName.FindStringSubmatch(r.PathValue("file"))
	if !iosSourceEnabled() || m == nil {
		http.NotFound(w, r)
		return
	}
	build, _ := strconv.ParseInt(m[1], 10, 64)
	rels, _ := h.st.ListReleases()
	for _, rel := range rels {
		if rel.Platform != "ios" || rel.Build != build {
			continue
		}
		f, err := os.Open(h.releasePath(rel.Sha256))
		if err != nil {
			apiErr(w, 410, "安装包文件已丢失")
			return
		}
		defer f.Close()
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, r.PathValue("file")))
		http.ServeContent(w, r, r.PathValue("file"), time.Unix(rel.Created, 0), f)
		return
	}
	http.NotFound(w, r)
}
