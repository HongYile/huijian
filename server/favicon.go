package main

import (
	_ "embed"
	"net/http"
)

// 管理后台的标签页图标（回笺应用图标缩小版），编进二进制，不依赖外部文件

//go:embed favicon.png
var faviconPNG []byte

//go:embed apple-touch-icon.png
var appleTouchIconPNG []byte

func serveIcon(b []byte) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Cache-Control", "public, max-age=86400")
		w.Write(b)
	}
}
