package main

import (
	"fmt"
	"os"
	"time"
	_ "time/tzdata" // 容器镜像没有 tzdata，内嵌一份，保证 TZ 生效
)

// 发布时可用 -ldflags "-X main.version=…" 覆盖
var version = "0.10.0"

func usage() {
	fmt.Fprint(os.Stderr, `huijian（回笺）`+version+`

用法:
  huijian hub                      启动服务端（读取 HUIJIAN_* 环境变量和配置文件 huijian.conf）
  huijian config                   查看生效的配置、数据 / 附件 / 备份目录
  huijian config init [文件]        生成带注释的配置文件模板
  huijian backup                   立即备份（数据库快照 + 附件镜像）到备份目录
  huijian restore [选项] <备份目录>  从备份恢复（需先停止服务端），换服务器时用
  huijian push [选项] 文本          发送消息（选项必须写在文本前面）
  huijian flush                    重发 outbox 中积压的消息
  huijian admin-link               生成 5 分钟有效的一次性管理登录链接（管理后台只能在服务器上进入，
                                  docker：docker exec huijian huijian admin-link）
  huijian invite new [-n 数量] [-uses 次数] [-days 天数] [-note 备注]
                                  生成注册邀请码（每行一个）
  huijian invite list              列出邀请码和使用情况
  huijian register -u 地址 [-invite 邀请码] -token-out 文件 <用户名>
                                  注册账号（本机生成钥匙，注册即开启加密；密码从标准输入读或交互输入）
  huijian release-key <私钥文件>     生成客户端更新的 Ed25519 签名私钥，打印公钥
  huijian release-pubkey <私钥文件>  打印公钥
  huijian release [选项] 包.zip      签名并上传客户端更新包（见 mac/release.sh）
  huijian server-push -manifest update-server.json [-dir 目录]
                                  把签名的服务端程序推送到自己的服务器并平滑重启
                                  （读 HUIJIAN_ADMIN_URL、HUIJIAN_ADMIN_TOKEN；对方已是这个版本或更新时直接退出）
  huijian version

push 选项:
  -k  接收方 pushkey，多个用逗号分隔（默认读 HUIJIAN_PUSHKEY）
  -u  服务器地址，多个用逗号分隔，按顺序尝试（默认读 HUIJIAN_URL）
  -d  正文（Markdown）
  -p  优先级 0-5
  -topic / -thread / -type
  -f  附件，可重复，例如 -f a.png -f b.pdf
  文本写 "-" 时从标准输入读取
`)
}

// extraCommands：只在特殊构建里注册的命令（例如 -tags e2etool 的测试辅助命令，见 e2etool.go），正式版本里为空
var extraCommands = map[string]func([]string) int{}

// devCommands：在开发机上运行的发布端命令（以及 hub 自己），不切换到数据目录里已更新的版本
var devCommands = map[string]bool{"hub": true, "release-key": true, "release-pubkey": true, "release": true, "server-push": true}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	migrateLegacyEnv()
	if err := loadConfigFile(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	// 命令行子命令也用一键更新下载的新版本执行（hub 自己在 runHub 里切换，并记录启动次数）。
	// 发布端命令在开发机上用刚编译的程序运行，不切换：数据目录里即使有 staged.json（例如本机测试留下的），也不该换成别的版本
	if !devCommands[os.Args[1]] {
		if p := cliTarget(dataDir()); p != "" {
			if err := execSelf(p); err != nil {
				fmt.Fprintln(os.Stderr, "切换到已更新的版本失败：", err)
			}
		}
	}
	switch os.Args[1] {
	case "config":
		os.Exit(runConfig(os.Args[2:]))
	case "backup":
		os.Exit(runBackupCLI(os.Args[2:]))
	case "restore":
		os.Exit(runRestore(os.Args[2:]))
	case "hub":
		runHub()
	case "push":
		os.Exit(runPush(os.Args[2:]))
	case "flush":
		os.Exit(runFlush())
	case "admin-link":
		os.Exit(runAdminLink())
	case "invite":
		os.Exit(runInviteCLI(os.Args[2:]))
	case "register":
		os.Exit(runRegisterCLI(os.Args[2:]))
	case "release-key":
		os.Exit(runReleaseKey(os.Args[2:]))
	case "release-pubkey":
		os.Exit(runReleasePubkey(os.Args[2:]))
	case "release":
		os.Exit(runRelease(os.Args[2:]))
	case "server-push":
		os.Exit(runServerPush(os.Args[2:]))
	case "version", "-v", "--version":
		fmt.Println(version)
	default:
		if f := extraCommands[os.Args[1]]; f != nil {
			os.Exit(f(os.Args[2:]))
		}
		usage()
		os.Exit(2)
	}
}

func runAdminLink() int {
	st, err := OpenStore(dbPath(dataDir()))
	if err != nil {
		fmt.Fprintln(os.Stderr, "打开数据库失败:", err)
		return 1
	}
	raw, err := st.CreateAdminLink("", 5*time.Minute)
	if err != nil {
		fmt.Fprintln(os.Stderr, "生成失败:", err)
		return 1
	}
	fmt.Println("一次性登录链接（5 分钟内有效，只能用一次）：")
	if base := adminURL(nil); base != "" {
		fmt.Println(base + "/auth/link?t=" + raw)
	} else {
		fmt.Println("http://<服务器IP>:" + externalPort("HUIJIAN_ADMIN_PORT", "HUIJIAN_ADMIN_ADDR", "8791") + "/auth/link?t=" + raw)
		fmt.Println("（把 <服务器IP> 换成你的服务器地址；在 .env 里设置 HUIJIAN_PUBLIC_URL 后会自动填好）")
	}
	return 0
}
