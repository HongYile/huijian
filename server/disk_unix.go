//go:build !windows

package main

import (
	"os"
	"path/filepath"
	"syscall"
)

// sameDevice：两个路径是否在同一个文件系统上（路径不存在时按最近的上级目录判断）
func sameDevice(a, b string) bool {
	da, ok1 := devOf(a)
	db, ok2 := devOf(b)
	return ok1 && ok2 && da == db
}

func devOf(p string) (uint64, bool) {
	p = absPath(p)
	for {
		if fi, err := os.Stat(p); err == nil {
			if st, ok := fi.Sys().(*syscall.Stat_t); ok {
				return uint64(st.Dev), true
			}
			return 0, false
		}
		parent := filepath.Dir(p)
		if parent == p {
			return 0, false
		}
		p = parent
	}
}

// diskFree：剩余可用空间（字节），未知时返回 -1
func diskFree(p string) int64 {
	var st syscall.Statfs_t
	if syscall.Statfs(p, &st) != nil {
		return -1
	}
	return int64(uint64(st.Bavail) * uint64(st.Bsize))
}

// chownLike：以 root 运行恢复命令时，把恢复出的文件改成和数据目录同一个属主，
// 否则以普通用户运行的服务端（例如 docker 里的 uid 10001）写不了
func chownLike(dir string, files ...string) {
	if os.Geteuid() != 0 {
		return
	}
	fi, err := os.Stat(dir)
	if err != nil {
		return
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok || st.Uid == 0 {
		return
	}
	for _, f := range files {
		os.Lchown(f, int(st.Uid), int(st.Gid))
	}
}
