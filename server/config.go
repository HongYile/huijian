package main

// 配置：环境变量 > 配置文件 > 默认值。
//
// 配置文件 huijian.conf 与 docker 的 .env 同一种格式（KEY=VALUE，# 开头为注释），
// 换服务器时复制这一个文件（加上数据 / 备份目录）就能原样迁移。查找顺序：
//   1. 环境变量 HUIJIAN_CONFIG 指定的文件
//   2. 当前目录的 huijian.conf
//   3. 系统默认位置（见 defaultConfigFile）
//
// 默认数据目录按各系统惯例（见 defaultDataDir）；旧版本在当前目录 ./data 下的数据会继续沿用。

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
)

var (
	fileConf     = map[string]string{}
	fileConfPath string
)

// loadConfigFile 在启动时调用一次；文件不存在不算错误
func loadConfigFile() error {
	p := os.Getenv("HUIJIAN_CONFIG")
	explicit := p != ""
	if !explicit {
		for _, c := range []string{"huijian.conf", "hongyan.conf", preferExisting(defaultConfigFile())} {
			if c == "" {
				continue
			}
			if _, err := os.Stat(c); err == nil {
				p = c
				break
			}
		}
	}
	if p == "" {
		return nil
	}
	m, err := parseConf(p)
	if err != nil {
		if !explicit && os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("读取配置文件 %s: %w", p, err)
	}
	migrateLegacyConf(m)
	fileConf, fileConfPath = m, absPath(p)
	// 配置文件里的 TZ 决定备份时间和附件目录按哪个时区分日期（环境变量优先）
	if tz := m["TZ"]; tz != "" && os.Getenv("TZ") == "" {
		if loc, err := time.LoadLocation(tz); err == nil {
			time.Local = loc
		}
	}
	return nil
}

func parseConf(p string) (map[string]string, error) {
	f, err := os.Open(p)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	m := map[string]string{}
	sc := bufio.NewScanner(f)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			return nil, fmt.Errorf("第 %d 行不是 KEY=VALUE 格式", n)
		}
		k, v = strings.TrimSpace(k), strings.TrimSpace(v)
		if len(v) >= 2 && (v[0] == '"' && v[len(v)-1] == '"' || v[0] == '\'' && v[len(v)-1] == '\'') {
			v = v[1 : len(v)-1]
		} else if i := strings.Index(v, " #"); i >= 0 { // 行尾注释
			v = strings.TrimSpace(v[:i])
		}
		m[k] = v
	}
	return m, sc.Err()
}

func absPath(p string) string {
	if a, err := filepath.Abs(p); err == nil {
		return a
	}
	return p
}

func isRoot() bool { return runtime.GOOS != "windows" && os.Geteuid() == 0 }

func homeDir() string {
	h, _ := os.UserHomeDir()
	return h
}

func xdg(envName, fallback string) string {
	if v := os.Getenv(envName); v != "" {
		return v
	}
	return filepath.Join(homeDir(), fallback)
}

// defaultConfigFile：各系统放配置文件的惯例位置
func defaultConfigFile() string {
	switch runtime.GOOS {
	case "windows":
		if pd := os.Getenv("ProgramData"); pd != "" {
			return filepath.Join(pd, "Huijian", "huijian.conf")
		}
		return ""
	case "darwin":
		return filepath.Join(homeDir(), "Library", "Application Support", "Huijian Server", "huijian.conf")
	default:
		if isRoot() {
			return "/etc/huijian/huijian.conf"
		}
		return filepath.Join(xdg("XDG_CONFIG_HOME", ".config"), "huijian", "huijian.conf")
	}
}

// defaultDataDir：各系统放应用数据的惯例位置
func defaultDataDir() string {
	switch runtime.GOOS {
	case "windows":
		if pd := os.Getenv("ProgramData"); pd != "" {
			return filepath.Join(pd, "Huijian", "data")
		}
		return "data"
	case "darwin":
		return filepath.Join(homeDir(), "Library", "Application Support", "Huijian Server")
	default:
		if isRoot() {
			return "/var/lib/huijian"
		}
		return filepath.Join(xdg("XDG_DATA_HOME", ".local/share"), "huijian")
	}
}

// dataDir：HUIJIAN_DATA > 旧版本的 ./data（已有数据库时沿用）> 系统默认位置
func dataDir() string {
	if v := env("HUIJIAN_DATA", ""); v != "" {
		return v
	}
	for _, f := range []string{"huijian.db", "hongyan.db", "beacon.db"} {
		if _, err := os.Stat(filepath.Join("data", f)); err == nil {
			return "data"
		}
	}
	return pickDataDir(defaultDataDir())
}

// ---------- huijian config ----------

type confKey struct{ key, def, desc string }

// 所有可配置项（顺序即 huijian config / 模板里的顺序）
var confKeys = []confKey{
	{"HUIJIAN_DATA", "", "数据目录：数据库、管理令牌、更新包。数据库必须在本地磁盘（不要放 NAS / 网络盘）"},
	{"HUIJIAN_FILES", "", "附件目录，可以放 NAS；留空 = 数据目录下的 files"},
	{"HUIJIAN_BACKUP_DIR", "", "备份目录，建议放 NAS 或另一块磁盘；留空 = 数据目录下的 backups；off = 关闭自动备份"},
	{"HUIJIAN_BACKUP_AT", "03:30", "每天几点备份（本地时间，HH:MM）"},
	{"HUIJIAN_BACKUP_KEEP", "14", "保留几份数据库快照"},
	{"HUIJIAN_BACKUP_FILES", "auto", "备份时镜像附件：auto = 同一块磁盘用硬链接（不占空间）、不同磁盘复制；1 = 总是复制；0 = 不镜像"},
	{"HUIJIAN_PUBLIC_ADDR", "127.0.0.1:8790", "消息 API 监听地址"},
	{"HUIJIAN_ADMIN_ADDR", "127.0.0.1:8791", "管理网页监听地址"},
	{"HUIJIAN_PUBLIC_URL", "", "对外地址，例如 http://1.2.3.4:8790 或 https://push.example.com"},
	{"HUIJIAN_ADMIN_URL", "", "管理后台对外地址；留空自动推导"},
	{"HUIJIAN_TRUSTED_PROXY", "", "可信反向代理 IP / 网段，只采信它们传来的 X-Real-IP"},
	{"HUIJIAN_ADMIN_DENY", "", "禁止访问管理后台的来源 IP（例如反向代理），逗号分隔"},
	{"HUIJIAN_MAX_UPLOAD_MB", "512", "单次上传上限（MB）"},
	{"HUIJIAN_PUSH_PER_MIN", "60", "每个 pushkey 每分钟最多发送几条"},
	{"HUIJIAN_UPDATE_PUBKEY", "", "客户端更新签名公钥（可选，设置后发布时校验签名）"},
	{"TZ", "", "时区，例如 Asia/Shanghai；影响备份时间和附件目录的日期"},
}

func runConfig(args []string) int {
	if len(args) > 0 && args[0] == "init" {
		p := defaultConfigFile()
		if len(args) > 1 {
			p = args[1]
		}
		if p == "" {
			fmt.Fprintln(os.Stderr, "请指定路径：huijian config init <文件>")
			return 2
		}
		if _, err := os.Stat(p); err == nil {
			fmt.Fprintln(os.Stderr, "文件已存在，不覆盖：", p)
			return 1
		}
		if err := os.MkdirAll(filepath.Dir(p), 0o750); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		if err := os.WriteFile(p, []byte(configTemplate()), 0o640); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		fmt.Println("已生成配置文件：", absPath(p))
		return 0
	}
	if fileConfPath != "" {
		fmt.Println("配置文件：", fileConfPath)
	} else {
		fmt.Println("配置文件：未使用（可用 huijian config init 生成，默认位置", defaultConfigFile()+"）")
	}
	fmt.Println()
	d := dataDir()
	paths := resolvePaths(d)
	fmt.Printf("%-22s %s\n", "数据目录", absPath(d))
	fmt.Printf("%-22s %s\n", "数据库", absPath(dbPath(d)))
	fmt.Printf("%-22s %s\n", "附件目录", absPath(paths.files))
	if paths.backup == "" {
		fmt.Printf("%-22s %s\n", "备份目录", "已关闭")
	} else {
		fmt.Printf("%-22s %s\n", "备份目录", absPath(paths.backup))
	}
	fmt.Println()
	keys := make([]string, 0, len(confKeys))
	for _, k := range confKeys {
		keys = append(keys, k.key)
	}
	for k := range fileConf {
		if !contains(keys, k) && strings.HasPrefix(k, "HUIJIAN_") {
			keys = append(keys, k)
		}
	}
	sort.SliceStable(keys[len(confKeys):], func(i, j int) bool { return keys[len(confKeys)+i] < keys[len(confKeys)+j] })
	for _, k := range keys {
		v, src := confSource(k)
		if v == "" {
			continue
		}
		if strings.Contains(k, "TOKEN") || strings.Contains(k, "SECRET") || strings.Contains(k, "PASSWORD") {
			v = "（已设置，不显示）"
		}
		fmt.Printf("%-24s %-32s ← %s\n", k, v, src)
	}
	return 0
}

func contains(xs []string, x string) bool {
	for _, s := range xs {
		if s == x {
			return true
		}
	}
	return false
}

// confSource 返回生效值和来源
func confSource(k string) (string, string) {
	if v := os.Getenv(k); v != "" {
		return v, "环境变量"
	}
	if v := fileConf[k]; v != "" {
		return v, "配置文件"
	}
	for _, c := range confKeys {
		if c.key == k && c.def != "" {
			return c.def, "默认"
		}
	}
	return "", ""
}

func configTemplate() string {
	var b strings.Builder
	b.WriteString("# 回笺服务端配置（KEY=VALUE；环境变量优先于这里的值）\n")
	b.WriteString("# 迁移到新服务器：复制本文件 + 数据目录（或备份目录，用 huijian restore 恢复）\n\n")
	for _, k := range confKeys {
		b.WriteString("# " + k.desc + "\n")
		b.WriteString("#" + k.key + "=" + k.def + "\n\n")
	}
	return b.String()
}
