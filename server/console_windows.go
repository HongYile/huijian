//go:build windows

package main

import "syscall"

// Windows 控制台默认是 GBK（代码页 936），程序输出的是 UTF-8：启动时把控制台的输入输出代码页切到 UTF-8（65001），
// 否则双击 huijian.exe 或在 cmd / PowerShell 5 里运行时中文是乱码。不在控制台里运行（输出被重定向）时调用会失败，忽略即可。
func init() {
	k := syscall.NewLazyDLL("kernel32.dll")
	k.NewProc("SetConsoleOutputCP").Call(65001)
	k.NewProc("SetConsoleCP").Call(65001)
}
