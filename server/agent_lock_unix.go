//go:build !windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// lockAgentSlot：独占一个会话槽位（同一槽位同时只能有一个进程：消息序号、处理过的回复只有一份）。
// 拿不到锁时立即返回错误；返回的函数释放锁
func lockAgentSlot(dir string) (func(), error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	os.Chmod(dir, 0o700)
	f, err := os.OpenFile(filepath.Join(dir, "lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("会话槽位 %s 正被另一个进程使用（例如另一个 huijian mcp 或 huijian agent ask）：同时运行多个 agent 时用 -s 或 HUIJIAN_AGENT_SESSION 分开槽位，各自登录", filepath.Base(dir))
	}
	return func() { syscall.Flock(int(f.Fd()), syscall.LOCK_UN); f.Close() }, nil
}
