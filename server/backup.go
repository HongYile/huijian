package main

// 备份与恢复。
//
// 备份目录结构（可以直接放在 NAS 上）：
//
//	<备份目录>/
//	  .huijian                       目录标记（用来判断 NAS 是否挂载）
//	  说明.txt                        恢复方法
//	  db/huijian-20261117-033000.db  数据库快照，保留最近 N 份（HUIJIAN_BACKUP_KEEP）
//	  files/2026/11/17/...           附件镜像（只增不删，和附件目录结构一致）
//	  releases/                      客户端更新包
//	  admin.token  huijian.conf      管理令牌、配置文件
//
// 每天 HUIJIAN_BACKUP_AT 自动执行；管理后台和客户端可以「立即备份」；命令行 huijian backup。
// 备份失败会用回笺自己推一条 P4 通知。
// 换服务器：新机器上 huijian restore <备份目录>（先停止服务端），再按备份里的 huijian.conf 配置启动。

import (
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type backupStatus struct {
	At       int64   `json:"at"`        // 开始时间（unix 秒）
	OK       bool    `json:"ok"`        // 是否成功
	Error    string  `json:"error"`     // 失败原因
	Warning  string  `json:"warning"`   // 成功但有需要注意的地方
	Reason   string  `json:"reason"`    // 定时 / 管理网页 / 客户端 / 命令行
	DB       string  `json:"db"`        // 快照文件名
	DBSize   int64   `json:"db_size"`   //
	Files    bool    `json:"files"`     // 是否镜像了附件
	Copied   int     `json:"copied"`    // 本次新复制的附件数
	Total    int     `json:"total"`     // 附件总数
	Seconds  float64 `json:"seconds"`   //
	Snapshot int     `json:"snapshots"` // 现有快照份数
}

type backupper struct {
	h       *Hub
	guard   *dirGuard
	keep    int
	at      string // HH:MM
	files   string // auto / 1 / 0
	mu      sync.Mutex
	running bool
}

func newBackupper(h *Hub) *backupper {
	b := &backupper{h: h, keep: int(envInt("HUIJIAN_BACKUP_KEEP", 14)), at: env("HUIJIAN_BACKUP_AT", "03:30"),
		files: strings.ToLower(env("HUIJIAN_BACKUP_FILES", "auto"))}
	if b.keep < 1 {
		b.keep = 1
	}
	if _, _, ok := parseHHMM(b.at); !ok {
		log.Printf("HUIJIAN_BACKUP_AT=%q 格式不对（应为 HH:MM），改用 03:30", b.at)
		b.at = "03:30"
	}
	if h.paths.backup != "" {
		b.guard = &dirGuard{dir: h.paths.backup, kind: "backup", local: within(h.paths.backup, h.dataDir), st: h.st}
	}
	return b
}

func (b *backupper) enabled() bool { return b.guard != nil }

func parseHHMM(s string) (int, int, bool) {
	hs, ms, ok := strings.Cut(s, ":")
	h, e1 := strconv.Atoi(hs)
	m, e2 := strconv.Atoi(ms)
	return h, m, ok && e1 == nil && e2 == nil && h >= 0 && h < 24 && m >= 0 && m < 60
}

func (b *backupper) next(from time.Time) time.Time {
	hh, mm, _ := parseHHMM(b.at)
	t := time.Date(from.Year(), from.Month(), from.Day(), hh, mm, 0, 0, time.Local)
	if !t.After(from) {
		t = t.AddDate(0, 0, 1)
	}
	return t
}

// mirrorFiles：是否镜像附件。0 = 不镜像；auto（默认）= 镜像，和附件在同一块磁盘时用硬链接（不占额外空间，
// 防误删但不防磁盘损坏）；1 = 总是复制一份
func (b *backupper) mirrorFiles() bool {
	switch b.files {
	case "0", "false", "no", "off":
		return false
	}
	return true
}

func (b *backupper) linkFiles() bool {
	switch b.files {
	case "1", "true", "yes", "on", "copy":
		return false
	}
	return true
}

// instanceID：这个数据目录的标识，写在快照文件名里。多台服务器共用一个备份目录时，
// 各自只清理自己的旧快照。存在数据目录的文件里（不在数据库里，恢复到新服务器后不会沿用旧的）。
func instanceID(data string) (string, error) {
	p := filepath.Join(data, "instance.id")
	if b, err := os.ReadFile(p); err == nil {
		if id := strings.TrimSpace(string(b)); len(id) >= 4 {
			return id, nil
		}
	}
	id := randHex(3)
	// 写不进去就报错：每次换一个随机 id 的话，旧快照都会被当成「别的服务器的」，永远不会被清理
	if err := os.WriteFile(p, []byte(id+"\n"), 0o640); err != nil {
		return "", fmt.Errorf("写入实例标识 %s: %w", p, err)
	}
	return id, nil
}

func (b *backupper) Last() *backupStatus {
	var st backupStatus
	if json.Unmarshal([]byte(b.h.st.GetKV("backup:last")), &st) != nil || st.At == 0 {
		return nil
	}
	return &st
}

func (b *backupper) Running() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.running
}

var errBackupRunning = errors.New("已有备份正在进行")

// Start 后台开始一次备份（管理网页 / 客户端调用）
func (b *backupper) Start(reason string) error {
	if !b.enabled() {
		return errors.New("备份已关闭（HUIJIAN_BACKUP_DIR=off）")
	}
	b.mu.Lock()
	if b.running {
		b.mu.Unlock()
		return errBackupRunning
	}
	b.running = true
	b.mu.Unlock()
	go func() {
		defer func() { b.mu.Lock(); b.running = false; b.mu.Unlock() }()
		b.run(reason)
	}()
	return nil
}

// RunNow 同步执行（定时任务和命令行用）
func (b *backupper) RunNow(reason string) *backupStatus {
	b.mu.Lock()
	if b.running {
		b.mu.Unlock()
		return &backupStatus{At: now(), Error: errBackupRunning.Error()}
	}
	b.running = true
	b.mu.Unlock()
	defer func() { b.mu.Lock(); b.running = false; b.mu.Unlock() }()
	return b.run(reason)
}

func (b *backupper) run(reason string) *backupStatus {
	start := time.Now()
	st := &backupStatus{At: start.Unix(), Reason: reason}
	err := b.do(st)
	st.Seconds = time.Since(start).Seconds()
	if err != nil {
		st.OK, st.Error = false, err.Error()
		log.Printf("备份失败（%s）：%v", reason, err)
		b.h.notice("backup-failed", 4, "回笺：备份失败", "备份目录：`"+b.h.paths.backup+"`\n\n原因："+err.Error())
	} else {
		st.OK = true
		log.Printf("备份完成（%s）：%s，新增附件 %d 个，用时 %.1fs", reason, st.DB, st.Copied, st.Seconds)
	}
	if js, err := json.Marshal(st); err == nil {
		b.h.st.SetKV("backup:last", string(js))
	}
	return st
}

func (b *backupper) do(st *backupStatus) error {
	if err := b.guard.ready(); err != nil {
		return err
	}
	root := b.guard.dir
	h := b.h
	for _, d := range []string{"db", "files", "releases"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o750); err != nil {
			return fmt.Errorf("创建备份子目录: %w", err)
		}
	}

	// 1. 数据库快照：先在本地生成一致的副本，再复制过去（SQLite 不适合直接写在网络盘上）
	inst, err := instanceID(h.dataDir)
	if err != nil {
		return err
	}
	name := "huijian-" + time.Now().Format("20060102-150405") + "-" + inst + ".db"
	tmp := filepath.Join(h.tmpDir, "backup-"+randHex(4)+".db")
	os.MkdirAll(h.tmpDir, 0o750)
	if _, err := h.st.db.Exec(`VACUUM INTO ?`, tmp); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("生成数据库快照: %w", err)
	}
	err = copyFileSync(tmp, filepath.Join(root, "db", name))
	os.Remove(tmp)
	if err != nil {
		return fmt.Errorf("写入数据库快照: %w", err)
	}
	st.DB = name
	if fi, err := os.Stat(filepath.Join(root, "db", name)); err == nil {
		st.DBSize = fi.Size()
	}
	var own []string // 只清理本服务器的快照（旧版本没有实例标识的也算）
	for _, n := range listSnapshots(root) {
		if strings.HasSuffix(n, "-"+inst+".db") || len(strings.Split(strings.TrimSuffix(n, ".db"), "-")) == 3 {
			own = append(own, n)
		}
	}
	for len(own) > b.keep {
		os.Remove(filepath.Join(root, "db", own[0]))
		own = own[1:]
	}
	st.Snapshot = len(own)

	// 2. 管理令牌、配置文件、更新包
	if err := copyIfChanged(filepath.Join(h.dataDir, "admin.token"), filepath.Join(root, "admin.token"), 0o600); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("备份管理令牌: %w", err)
	}
	if fileConfPath != "" {
		if err := copyIfChanged(fileConfPath, filepath.Join(root, "huijian.conf"), 0o640); err != nil {
			return fmt.Errorf("备份配置文件: %w", err)
		}
	}
	if _, err := mirrorTree(h.releaseDir, filepath.Join(root, "releases"), true, false); err != nil {
		return fmt.Errorf("备份更新包: %w", err)
	}

	// 3. 附件镜像
	if b.mirrorFiles() {
		st.Files = true
		if err := h.files.files.ready(); err != nil {
			st.Warning = "附件目录不可用，本次只镜像了本地的附件：" + err.Error()
		}
		for _, src := range h.files.roots() {
			n, err := mirrorTree(src, filepath.Join(root, "files"), false, b.linkFiles())
			if err != nil {
				return fmt.Errorf("镜像附件: %w", err)
			}
			st.Copied += n
		}
		st.Total, _ = dirUsage(filepath.Join(root, "files"))
	}
	writeBackupReadme(root)
	return nil
}

func listSnapshots(root string) []string {
	ents, _ := os.ReadDir(filepath.Join(root, "db"))
	var out []string
	for _, e := range ents {
		if n := e.Name(); snapshotStamp(n) != "" {
			out = append(out, n)
		}
	}
	// 文件名里是时间戳：去掉前缀（改名前的快照是 hongyan-）后按字典序 = 时间顺序
	sort.SliceStable(out, func(i, j int) bool { return snapshotStamp(out[i]) < snapshotStamp(out[j]) })
	return out
}

func copyIfChanged(src, dst string, perm os.FileMode) error {
	a, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if b, err := os.ReadFile(dst); err == nil && string(a) == string(b) {
		return nil
	}
	if err := copyFileSync(src, dst); err != nil {
		return err
	}
	return os.Chmod(dst, perm)
}

// mirrorTree 把 src 下的文件复制到 dst（不存在或大小不同才复制）；exact=true 时删除 dst 里多出来的文件；
// link=true 时先尝试硬链接（同一文件系统上不占额外空间），不行再复制
func mirrorTree(src, dst string, exact, link bool) (int, error) {
	n := 0
	seen := map[string]bool{}
	if _, err := os.Stat(src); err != nil {
		return 0, nil // 源目录不存在：什么都不做（exact 模式下也不能把备份里的东西删掉）
	}
	err := filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if os.IsNotExist(err) && p == src {
				return filepath.SkipDir
			}
			return err
		}
		if d.IsDir() || isMarkerName(d.Name()) || hasPartSuffix(d.Name()) {
			return nil
		}
		rel, _ := filepath.Rel(src, p)
		seen[rel] = true
		fi, err := d.Info()
		if err != nil {
			return err
		}
		to := filepath.Join(dst, rel)
		if ti, err := os.Stat(to); err == nil && ti.Size() == fi.Size() {
			return nil
		}
		if link {
			os.MkdirAll(filepath.Dir(to), 0o750)
			os.Remove(to)
			if os.Link(p, to) == nil {
				n++
				return nil
			}
		}
		if err := copyFileSync(p, to); err != nil {
			return err
		}
		n++
		return nil
	})
	if err != nil || !exact {
		return n, err
	}
	filepath.WalkDir(dst, func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			if rel, _ := filepath.Rel(dst, p); !seen[rel] {
				os.Remove(p)
			}
		}
		return nil
	})
	return n, nil
}

func writeBackupReadme(root string) {
	p := filepath.Join(root, "说明.txt")
	if _, err := os.Stat(p); err == nil {
		return
	}
	os.WriteFile(p, []byte(`回笺（Huijian）服务端备份

db/        数据库快照（按时间命名，保留最近若干份）
files/     附件，按 年/月/日/时间_标题/文件名 存放，可以直接浏览
releases/  客户端更新包
admin.token、huijian.conf  管理令牌和配置文件（注意保管）

恢复 / 迁移到新服务器（先停止服务端）：
  huijian restore <本目录>
docker 部署（备份目录在容器里的路径：默认 /data/backups，映射了 HUIJIAN_BACKUP_HOST_DIR 时是 /backup）：
  docker compose stop
  docker compose run --rm --entrypoint huijian huijian restore /backup
  docker compose up -d
如果附件和备份在同一块磁盘上，files/ 里是硬链接：不额外占空间，能防误删，但不能防磁盘损坏。
`), 0o640)
}

// ---------- 后台任务 ----------

// startBackground：定时备份、附件回迁、运行心跳；返回停止函数
func (h *Hub) startBackground() func() {
	done := make(chan struct{})
	alive := filepath.Join(h.dataDir, ".hub-alive")
	beat := func() { os.WriteFile(alive, []byte(strconv.FormatInt(now(), 10)), 0o640) }
	beat()
	go func() {
		tick := time.NewTicker(beatInterval)
		defer tick.Stop()
		reqTick := time.NewTicker(2 * time.Second)
		defer reqTick.Stop()
		relocateEvery := time.NewTicker(10 * time.Minute)
		defer relocateEvery.Stop()
		for {
			select {
			case <-done:
				return
			case <-tick.C:
				beat()
			case <-reqTick.C:
				// 命令行 huijian backup 在服务运行时不自己备份，而是放一个请求文件交给这里执行
				if req := filepath.Join(h.dataDir, ".backup-request"); fileExists(req) {
					os.Remove(req)
					if err := h.backup.Start("命令行"); err != nil {
						log.Printf("命令行请求的备份没有开始：%v", err)
					}
				}
			case <-relocateEvery.C:
				if _, err := h.files.relocate(); err != nil {
					log.Printf("搬回暂存附件失败: %v", err)
				}
			}
		}
	}()
	if h.backup.enabled() {
		log.Printf("自动备份：每天 %s → %s（保留 %d 份快照，附件镜像：%v）", h.backup.at, absPath(h.paths.backup), h.backup.keep, h.backup.mirrorFiles())
		go func() {
			for {
				t := time.NewTimer(time.Until(h.backup.next(time.Now())))
				select {
				case <-done:
					t.Stop()
					return
				case <-t.C:
					h.files.relocate()
					h.backup.RunNow("定时")
				}
			}
		}()
	} else {
		log.Printf("自动备份已关闭")
	}
	return func() { close(done); os.Remove(alive) }
}

var beatInterval = 30 * time.Second

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

// hubAlive：服务端是否正在使用这个数据目录（心跳 90 秒内更新过）
func hubAlive(data string) bool {
	b, err := os.ReadFile(filepath.Join(data, ".hub-alive"))
	if err != nil {
		return false
	}
	t, _ := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	return now()-t < 90
}

// ---------- 命令行 ----------

// openCore：命令行用，打开数据库但不监听端口
func openCore() (*Hub, error) {
	data := dataDir()
	if !fileExists(dbPath(data)) {
		return nil, fmt.Errorf("数据目录 %s 里没有数据库（检查 HUIJIAN_DATA 或配置文件是否和服务端一致）", absPath(data))
	}
	st, err := OpenStore(dbPath(data))
	if err != nil {
		return nil, err
	}
	h := &Hub{dataDir: data, paths: resolvePaths(data), st: st,
		tmpDir: filepath.Join(data, "tmp"), releaseDir: filepath.Join(data, "releases")}
	if h.userID, err = st.EnsureUser("me"); err != nil {
		return nil, err
	}
	h.files = newFileStore(h, h.paths.files)
	h.backup = newBackupper(h)
	return h, nil
}

func runBackupCLI(args []string) int {
	h, err := openCore()
	if err != nil {
		fmt.Fprintln(os.Stderr, "❌", err)
		return 1
	}
	defer h.st.db.Close()
	if !h.backup.enabled() {
		fmt.Fprintln(os.Stderr, "备份已关闭（HUIJIAN_BACKUP_DIR=off）")
		return 1
	}
	fmt.Println("数据目录", absPath(h.dataDir), "→ 备份到", absPath(h.paths.backup))
	var st *backupStatus
	if hubAlive(h.dataDir) {
		// 服务端正在运行：交给它执行，避免两个进程同时写备份目录
		before := h.st.GetKV("backup:last")
		if err := os.WriteFile(filepath.Join(h.dataDir, ".backup-request"), nil, 0o640); err != nil {
			fmt.Fprintln(os.Stderr, "❌ 无法提交备份请求：", err)
			return 1
		}
		fmt.Println("服务端正在运行，已请求它执行备份，等待完成…")
		for i := 0; ; i++ {
			time.Sleep(time.Second)
			if cur := h.st.GetKV("backup:last"); cur != before { // 结果在备份结束时写入
				st = h.backup.Last()
				break
			}
			if i > 3600 {
				fmt.Fprintln(os.Stderr, "❌ 等了一小时还没完成，请在管理后台查看")
				return 1
			}
		}
	} else {
		h.files.relocate()
		st = h.backup.RunNow("命令行")
	}
	if st == nil || !st.OK {
		msg := "未知错误"
		if st != nil {
			msg = st.Error
		}
		fmt.Fprintln(os.Stderr, "❌ 备份失败：", msg)
		return 1
	}
	fmt.Printf("✅ 完成：数据库快照 %s（%s，共 %d 份）", st.DB, humanSize(st.DBSize), st.Snapshot)
	if st.Files {
		fmt.Printf("，附件新增 %d 个 / 共 %d 个", st.Copied, st.Total)
	} else {
		fmt.Print("，附件未镜像（HUIJIAN_BACKUP_FILES=0）")
	}
	fmt.Printf("，用时 %.1fs\n", st.Seconds)
	if st.Warning != "" {
		fmt.Println("⚠️", st.Warning)
	}
	return 0
}

type snapInfo struct {
	name     string
	messages int
	err      error
}

func runRestore(args []string) int {
	fset := flag.NewFlagSet("restore", flag.ExitOnError)
	snap := fset.String("db", "", "使用哪份数据库快照（文件名或路径，默认最新的、有消息的一份）")
	yes := fset.Bool("y", false, "不再确认，直接替换现有数据库")
	fset.Usage = func() {
		fmt.Fprintln(os.Stderr, "用法：huijian restore [-db 快照] [-y] <备份目录>\n先停止服务端。现有数据库会改名保留，不会删除；附件只补缺失的，不会覆盖。")
		fset.PrintDefaults()
	}
	fset.Parse(args)
	if fset.NArg() != 1 {
		fset.Usage()
		return 2
	}
	root := fset.Arg(0)
	data := dataDir()
	if hubAlive(data) || portBusy(env("HUIJIAN_PUBLIC_ADDR", "127.0.0.1:8790")) {
		fmt.Fprintln(os.Stderr, "服务端正在运行，请先停止（docker compose stop 或停止 huijian hub）再恢复")
		return 1
	}
	// 列出快照和各自的消息数，默认选最新的非空快照（避免选中新服务器刚启动时备份的空库）
	var infos []snapInfo
	for _, n := range listSnapshots(root) {
		c, err := snapshotMessages(filepath.Join(root, "db", n))
		infos = append(infos, snapInfo{n, c, err})
	}
	src := *snap
	if src == "" {
		for i := len(infos) - 1; i >= 0; i-- {
			if infos[i].err == nil && infos[i].messages > 0 {
				src = filepath.Join(root, "db", infos[i].name)
				break
			}
		}
		if src == "" && len(infos) > 0 && infos[len(infos)-1].err == nil {
			src = filepath.Join(root, "db", infos[len(infos)-1].name)
		}
	} else if !strings.ContainsAny(src, `/\`) {
		src = filepath.Join(root, "db", src)
	}
	if src == "" {
		fmt.Fprintln(os.Stderr, "备份目录里没有可用的数据库快照：", filepath.Join(root, "db"))
		return 1
	}
	fmt.Println("备份里的快照：")
	for _, x := range infos {
		mark := "  "
		if filepath.Base(src) == x.name {
			mark = "→ "
		}
		if x.err != nil {
			fmt.Printf("  %s%s（不可用：%v）\n", mark, x.name, x.err)
		} else {
			fmt.Printf("  %s%s（%d 条消息）\n", mark, x.name, x.messages)
		}
	}
	if err := checkSnapshot(src); err != nil {
		fmt.Fprintln(os.Stderr, "快照不可用：", err)
		return 1
	}
	dst := dbPath(data)
	fmt.Println("恢复到数据目录：", absPath(data))
	if fileExists(dst) && !*yes {
		fmt.Print("这个数据目录里已经有数据库，恢复后它会改名保留。继续吗？[y/N] ")
		var ans string
		fmt.Scanln(&ans)
		if strings.ToLower(strings.TrimSpace(ans)) != "y" {
			fmt.Println("已取消（非交互运行时加 -y）")
			return 1
		}
	}
	if err := os.MkdirAll(data, 0o750); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	// 先把快照复制到旁边，成功后再替换，中途失败不会让数据目录里没有数据库
	staging := dst + ".restoring"
	if err := copyFileSync(src, staging); err != nil {
		os.Remove(staging)
		fmt.Fprintln(os.Stderr, "复制快照失败：", err)
		return 1
	}
	if fileExists(dst) {
		old := dst + ".before-restore-" + time.Now().Format("20060102-150405")
		if err := os.Rename(dst, old); err != nil {
			os.Remove(staging)
			fmt.Fprintln(os.Stderr, "无法保留原数据库：", err)
			return 1
		}
		for _, suf := range []string{"-wal", "-shm"} {
			os.Rename(dst+suf, old+suf)
		}
		fmt.Println("原数据库已改名保留：", old)
	}
	// 恢复后换一个变更纪元：客户端的删除 / 归档游标对应的是原来的数据，需要重新对账
	if db, err := sql.Open("sqlite", "file:"+staging); err == nil {
		db.Exec(`DELETE FROM kv WHERE k=?`, kvChangesEpoch)
		db.Close()
	}
	if err := os.Rename(staging, dst); err != nil {
		fmt.Fprintln(os.Stderr, "替换数据库失败：", err)
		return 1
	}
	fmt.Println("✅ 数据库 ←", filepath.Base(src))
	if !fileExists(filepath.Join(data, "admin.token")) {
		if copyIfChanged(filepath.Join(root, "admin.token"), filepath.Join(data, "admin.token"), 0o600) == nil {
			fmt.Println("✅ 管理令牌")
		}
	}
	if n, err := mirrorTree(filepath.Join(root, "releases"), filepath.Join(data, "releases"), false, false); err == nil {
		fmt.Printf("✅ 更新包 %d 个\n", n)
	}
	h, err := openCore()
	if err != nil {
		fmt.Fprintln(os.Stderr, "打开数据库失败：", err)
		return 1
	}
	defer h.st.db.Close()
	// 目录标记是每台机器自己的状态，旧机器的记录会让新机器误判「NAS 没挂载」
	h.st.db.Exec(`DELETE FROM kv WHERE k LIKE 'marker:%'`)
	if h.files.files.local {
		os.MkdirAll(h.paths.files, 0o750)
	}
	target := h.files.writeRoot()
	// 只补缺失的附件（附件目录已经是原来的 NAS 时，基本不用复制）
	n, err := mirrorTree(filepath.Join(root, "files"), target, false, false)
	if err != nil {
		fmt.Fprintln(os.Stderr, "恢复附件失败：", err)
		return 1
	}
	fmt.Printf("✅ 附件补齐 %d 个 → %s\n", n, absPath(target))
	if target != h.paths.files {
		fmt.Println("⚠️ 附件目录", h.paths.files, "现在不可用，附件先放在本地暂存，服务端启动后目录可用时会自动搬过去")
	}
	chownLike(data, dst, filepath.Join(data, "admin.token"))
	for _, c := range []string{"huijian.conf", "hongyan.conf"} {
		if fileExists(filepath.Join(root, c)) && fileConfPath == "" {
			fmt.Println("备份里有配置文件 "+c+"，可以复制到", defaultConfigFile(), "后再启动")
			break
		}
	}
	fmt.Println("完成。现在可以启动服务端。")
	return 0
}

func snapshotMessages(p string) (int, error) {
	db, err := sql.Open("sqlite", "file:"+p+"?mode=ro")
	if err != nil {
		return 0, err
	}
	defer db.Close()
	var n int
	err = db.QueryRow(`SELECT COUNT(*) FROM messages`).Scan(&n)
	return n, err
}

func checkSnapshot(p string) error {
	db, err := sql.Open("sqlite", "file:"+p+"?mode=ro")
	if err != nil {
		return err
	}
	defer db.Close()
	var res string
	if err := db.QueryRow(`PRAGMA integrity_check`).Scan(&res); err != nil {
		return err
	}
	if res != "ok" {
		return errors.New("完整性检查未通过：" + res)
	}
	var n int
	return db.QueryRow(`SELECT COUNT(*) FROM messages`).Scan(&n)
}

func portBusy(addr string) bool {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	c := http.Client{Timeout: time.Second}
	resp, err := c.Get("http://" + net.JoinHostPort(host, port) + "/healthz")
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode == 200
}
