package main

import (
	"os"
	"path/filepath"
)

// 管理网页用的存储大小统计。

func dirSize(p string) int64 {
	var n int64
	filepath.Walk(p, func(_ string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			n += info.Size()
		}
		return nil
	})
	return n
}

func dbSize(dataDir string) int64 {
	var n int64
	db := dbFileName(dataDir)
	for _, f := range []string{db, db + "-wal", db + "-shm"} {
		if fi, err := os.Stat(filepath.Join(dataDir, f)); err == nil {
			n += fi.Size()
		}
	}
	return n
}
