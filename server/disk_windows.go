//go:build windows

package main

import (
	"path/filepath"
	"strings"
)

// sameDevice：Windows 上按盘符判断
func sameDevice(a, b string) bool {
	va, vb := filepath.VolumeName(absPath(a)), filepath.VolumeName(absPath(b))
	return va != "" && strings.EqualFold(va, vb)
}

func diskFree(p string) int64 { return -1 }

func chownLike(dir string, files ...string) {}
