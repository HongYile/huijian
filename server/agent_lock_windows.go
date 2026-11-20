//go:build windows

package main

import "os"

// lockAgentSlot：Windows 上不加锁（服务端程序在 Windows 上只作为发送端使用；同一槽位请不要同时运行多个进程）
func lockAgentSlot(dir string) (func(), error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	return func() {}, nil
}
