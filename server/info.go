package main

// 版本与功能协商：客户端和服务端各自独立升级，靠功能清单而不是版本号判断能用什么。
//
//	GET /v1/info   （无需鉴权）{"name":"huijian","version":"0.5.0","api":1,"features":[{"id":"keys","title":"…","since":"0.4.2"}]}
//
// 所有 /v1 响应都带 X-Huijian-Server: <版本>，客户端发现版本变化时重新拉取 /v1/info。
//
// 兼容约定（见 docs/api.md「版本兼容」一节）：
//   - 服务端只新增接口和字段，不删除、不改含义；旧客户端照常工作。
//   - 客户端按 features 决定功能是否可用：服务端缺少的功能显示「更新服务端后可用」；
//     服务端有、客户端不认识的功能显示「更新客户端后可用」（用 title 展示）。
//   - 更旧的服务端没有 /v1/info：客户端把 404（非 JSON）/ 405 视为「接口不存在」。

import (
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const apiLevel = 1

type feature struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	Since string `json:"since"`
}

var serverFeatures = []feature{
	{"push", "发送消息与附件", "0.1.0"},
	{"stream", "实时接收（长轮询）", "0.1.0"},
	{"update", "客户端应用内更新", "0.4.0"},
	{"me.rename", "在客户端修改设备名称", "0.4.2"},
	{"keys", "在客户端管理 pushkey", "0.4.2"},
	{"info", "版本与功能协商", "0.5.0"},
	{"account", "账号：密码登录、换设备找回 pushkey 和历史", "0.5.0"},
	{"devices", "设备身份：重新配对不重复，查看配对记录", "0.5.0"},
	{"subscriptions", "按设备设置每把 pushkey 提醒 / 静默 / 不接收", "0.5.0"},
	{"presence", "在用设备优先：正在用别的设备时本机不响", "0.5.0"},
	{"keys.delete", "删除已吊销的 pushkey", "0.5.2"},
	{"messages.manage", "删除和归档消息，多设备同步", "0.5.4"},
	{"channels", "频道改名、隐藏、静音、置顶和排序，删除频道", "0.5.5"},
	{"pair.status", "配对码 3 分钟有效、重新生成即作废旧码，可查询是否已被使用", "0.5.6"},
	{"bark", "iPhone 锁屏通知：按设备转发到 Bark，可端到端加密", "0.5.7"},
	{"ios.source", "iPhone 客户端的 GBox 软件源与安装包", "0.5.7"},
	{"server.update", "服务端一键更新：从 GitHub Releases 下载、验签后原地重启，失败自动回退", "0.6.0"},
	{"markdown.doc", "回笺 Markdown：消息带服务端解析好的 doc 结构和 preview 纯文本（表格、提示框、附件内嵌图片、进度条等）", "0.6.0"},
	{"sync.settings", "设置实时同步：key、设备、账户变了以后，变更里出现 keys / devices / account（id 0），客户端重新拉取", "0.6.1"},
	{"poll.long", "长轮询可以挂起超过 55 秒（上限见 /v1/info 的 long_poll_max），客户端按网络自适应等待时长，更省电", "0.6.4"},
	{"e2e", "端到端加密（docs/e2ee.md）：/v1/prelogin + auth_key 登录、/v1/e2e 钥匙管理和设备批准；消息带 e2e 信封时 type=e2e、text 是占位文字、附件是密文", "0.7.0"},
	{"e2e.auto", "默认自动加密：开启加密时恢复码可选、POST /v1/e2e/reset 重置加密、服务器代加密明文消息并补加密开启以前的历史（sealed: \"server\"，始终开启；补加密的消息记 kind \"sealed\" 变更、附件换新 id，用 GET /v1/messages/{id} 重新拉取）；上传 wrap / grant 带 kid", "0.8.0"},
	{"admin.accounts", "管理后台只管账号：不显示消息、pushkey 和设备，只有统计数字；任何账号都不能从客户端进入管理后台（/v1/admin/link、/v1/storage 已删除，/v1/me 的 can_admin 恒为 false）", "0.9.0"},
	{"register.invite", "注册模式和邀请码：/v1/info 的 register 为 closed / invite / open；invite 时 POST /v1/register 要带 invite_code", "0.9.0"},
	{"register.e2e", "注册即开启加密：POST /v1/register 必须带 pub、password_wrap、auth_salt、auth_key（格式同 /v1/e2e/setup），返回设备 token 和 e2e；不带的旧客户端注册返回 400「请更新回笺客户端后注册」", "0.9.0"},
	{"push.e2e", "服务器不保存明文：账号还没有加密钥匙时，明文推送返回 403（先在回笺客户端用密码登录一次），服务端系统通知直接丢弃", "0.9.0"},
}

func (h *Hub) handleInfo(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{"name": "huijian", "version": version, "api": apiLevel, "features": serverFeatures,
		"register_open": h.registerOpen(), "register": h.st.RegisterMode(), "long_poll_max": longPollMax()})
}

// withServerHeader 给所有响应加上服务端版本
func withServerHeader(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		setServerHeader(w.Header(), "Server", version)
		next.ServeHTTP(w, r)
	})
}

// ---------- 版本比较（管理后台标出较旧的客户端） ----------

// parseVer "0.4.2" → [0 4 2]；不认识返回 nil
func parseVer(s string) []int {
	var out []int
	for _, p := range strings.Split(s, ".") {
		n, err := strconv.Atoi(p)
		if err != nil {
			return nil
		}
		out = append(out, n)
	}
	return out
}

func verLess(a, b string) bool {
	x, y := parseVer(a), parseVer(b)
	if x == nil || y == nil {
		return false
	}
	for i := 0; i < len(x) || i < len(y); i++ {
		var p, q int
		if i < len(x) {
			p = x[i]
		}
		if i < len(y) {
			q = y[i]
		}
		if p != q {
			return p < q
		}
	}
	return false
}

// clientVersion 从客户端标签（例如 "macos 0.4.2 (7)"）取出版本号
func clientVersion(label string) string {
	f := strings.Fields(label)
	if len(f) >= 2 && parseVer(f[1]) != nil {
		return f[1]
	}
	return ""
}

// clientOutdated：客户端版本低于这个平台已发布的最新版本。没上报版本号的旧客户端算较旧。
// 这个平台在本服务器上没有发布记录时不标较旧：各端版本线独立（Mac 0.7、手机 0.4），和服务端版本号比没有意义
func (h *Hub) clientOutdated(label string) bool {
	v := clientVersion(label)
	if v == "" {
		return true
	}
	if latest := h.st.LatestReleaseVersion(strings.Fields(label)[0]); latest != "" {
		return verLess(v, latest)
	}
	return false
}

// ---------- 存储状态（管理后台和客户端共用） ----------

type storageInfo struct {
	DataDir      string        `json:"data_dir"`
	DBSize       int64         `json:"db_size"`
	FilesDir     string        `json:"files_dir"`
	FilesOK      bool          `json:"files_ok"`
	FilesError   string        `json:"files_error,omitempty"`
	FilesCount   int           `json:"files_count"`
	FilesSize    int64         `json:"files_size"`
	FilesFree    int64         `json:"files_free"`
	Pending      int           `json:"pending"` // 暂存在本地、等待搬回附件目录的
	Legacy       int           `json:"legacy"`  // 旧版本 blobs 目录里的
	BackupDir    string        `json:"backup_dir"`
	BackupOn     bool          `json:"backup_enabled"`
	BackupOK     bool          `json:"backup_ok"`
	BackupError  string        `json:"backup_error,omitempty"`
	BackupFree   int64         `json:"backup_free"`
	BackupAt     string        `json:"backup_at"`
	BackupKeep   int           `json:"backup_keep"`
	BackupFiles  bool          `json:"backup_files"`
	Next         int64         `json:"next"`
	Running      bool          `json:"running"`
	Last         *backupStatus `json:"last"`
	CountedAt    int64         `json:"counted_at"` // 文件统计的时间（有缓存）
	ConfigFile   string        `json:"config_file"`
	ServerTZ     string        `json:"tz"`
	ServerVer    string        `json:"version"`
	FilesIsLocal bool          `json:"files_local"`
}

var usageCache struct {
	sync.Mutex
	at                     time.Time
	count, pending, legacy int
	size                   int64
}

func (h *Hub) storageInfo(fresh bool) storageInfo {
	in := storageInfo{
		DataDir: absPath(h.dataDir), DBSize: dbSize(h.dataDir), FilesDir: absPath(h.paths.files),
		FilesIsLocal: h.files.files.local, ConfigFile: fileConfPath, ServerTZ: time.Local.String(), ServerVer: version,
	}
	if err := h.files.files.ready(); err != nil {
		in.FilesError = err.Error()
	} else {
		in.FilesOK = true
		in.FilesFree = diskFree(h.paths.files)
	}
	usageCache.Lock()
	stale := fresh || time.Since(usageCache.at) > 5*time.Minute
	usageCache.Unlock()
	if stale { // 遍历目录（可能在 NAS 上）时不持有锁，其他请求不用排队
		var count, pending, legacy int
		var size int64
		if in.FilesOK {
			count, size = dirUsage(h.paths.files)
		}
		if absPath(h.files.local) != absPath(h.paths.files) {
			pending, _ = dirUsage(h.files.local)
		}
		legacy, _ = dirUsage(h.files.legacy)
		usageCache.Lock()
		usageCache.count, usageCache.size, usageCache.pending, usageCache.legacy, usageCache.at = count, size, pending, legacy, time.Now()
		usageCache.Unlock()
	}
	usageCache.Lock()
	in.FilesCount, in.FilesSize, in.Pending, in.Legacy, in.CountedAt =
		usageCache.count, usageCache.size, usageCache.pending, usageCache.legacy, usageCache.at.Unix()
	usageCache.Unlock()

	b := h.backup
	in.BackupOn = b.enabled()
	if in.BackupOn {
		in.BackupDir = absPath(h.paths.backup)
		in.BackupAt, in.BackupKeep, in.BackupFiles = b.at, b.keep, b.mirrorFiles()
		in.Next = b.next(time.Now()).Unix()
		if err := b.guard.ready(); err != nil {
			in.BackupError = err.Error()
		} else {
			in.BackupOK = true
			in.BackupFree = diskFree(h.paths.backup)
		}
	}
	in.Running = b.Running()
	in.Last = b.Last()
	return in
}

// POST /backup/run（管理后台）
func (h *Hub) adminRunBackup(w http.ResponseWriter, r *http.Request) {
	if err := h.backup.Start("管理网页"); err != nil {
		redirectFlash(w, r, "/settings", err.Error())
		return
	}
	redirectFlash(w, r, "/settings", "已开始备份，稍后刷新页面查看结果")
}
