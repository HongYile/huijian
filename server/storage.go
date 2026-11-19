package main

// 附件存储。
//
// 附件目录（HUIJIAN_FILES）可以放在 NAS 上，目录结构按日期组织，直接打开就能浏览：
//
//	<附件目录>/2026/11/17/143015_exp42 完成/loss.png
//
// 数据库里记录相对路径；读取时依次在 附件目录、数据目录/files（NAS 不可用时的本地暂存）、
// 数据目录/blobs（0.5.0 以前按 sha256 存放的旧附件）里查找，所以旧数据不用迁移。
//
// 外部目录（不在数据目录里的，例如 NAS）第一次使用时会写入标记文件 .huijian。之后如果标记不见了，
// 多半是 NAS 没挂载上（挂载点变成了本地空目录），这时不往里写，新附件先存本地，等 NAS 恢复后自动搬过去，
// 并给你推一条通知。

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

const markerName = ".huijian"

// partSuffix：复制中的临时文件（用少见的后缀，避免和用户自己的 xxx.part 附件混淆）
const partSuffix = ".huijian-part"

type storePaths struct {
	files  string // 附件目录
	backup string // 备份目录；空 = 关闭
}

func resolvePaths(data string) storePaths {
	p := storePaths{files: env("HUIJIAN_FILES", ""), backup: env("HUIJIAN_BACKUP_DIR", "")}
	if p.files == "" {
		p.files = filepath.Join(data, "files")
	}
	switch strings.ToLower(p.backup) {
	case "":
		p.backup = filepath.Join(data, "backups")
	case "off", "0", "false", "none":
		p.backup = ""
	}
	return p
}

// checkPaths：数据、附件、备份三个目录的关系是否合理（否则可能把备份复制进自己、或把数据库当附件）
func checkPaths(data string, p storePaths) error {
	if absPath(p.files) == absPath(data) {
		return fmt.Errorf("附件目录不能就是数据目录（%s），请设成单独的目录，例如 %s", data, filepath.Join(data, "files"))
	}
	if p.backup != "" {
		if within(p.backup, p.files) {
			return fmt.Errorf("备份目录 %s 不能放在附件目录 %s 里面", p.backup, p.files)
		}
		if within(p.files, p.backup) {
			return fmt.Errorf("附件目录 %s 不能放在备份目录 %s 里面", p.files, p.backup)
		}
		if absPath(p.backup) == absPath(data) {
			return fmt.Errorf("备份目录不能就是数据目录（%s）", data)
		}
	}
	return nil
}

// within：p 是否在 dir 里（含相等）
func within(p, dir string) bool {
	rel, err := filepath.Rel(absPath(dir), absPath(p))
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// dirGuard 判断一个目录现在能不能写
type dirGuard struct {
	dir   string
	kind  string // files / backup
	local bool   // 在数据目录里：直接创建，不需要标记
	st    *Store
}

var errNotMounted = errors.New("not mounted")

func (g *dirGuard) ready() error {
	if g.local {
		return os.MkdirAll(g.dir, 0o750)
	}
	fi, err := os.Stat(g.dir)
	if err != nil {
		return fmt.Errorf("目录 %s 不存在或无法访问（NAS 没有挂载？）：%w", g.dir, err)
	}
	if !fi.IsDir() {
		return fmt.Errorf("%s 不是目录", g.dir)
	}
	key := "marker:" + g.kind + ":" + absPath(g.dir)
	mk := filepath.Join(g.dir, markerName)
	if _, err := os.Stat(mk); err != nil {
		if old := legacyMarkerIn(g.dir); old != "" {
			os.WriteFile(mk, []byte("回笺（Huijian）"+g.kind+" 目录标记，请勿删除。\n"), 0o640) // 写不进也没关系，旧标记仍有效
			mk = old
		}
	}
	if _, err := os.Stat(mk); err == nil {
		if g.st.GetKV(key) == "" {
			g.st.SetKV(key, now())
		}
		return nil
	}
	if g.st.GetKV(key) != "" {
		return fmt.Errorf("%w：目录 %s 里的标记文件 %s 不见了，可能 NAS 没有挂载上。如果确实换成了新的空目录，在里面新建一个名为 %s 的空文件即可",
			errNotMounted, g.dir, markerName, markerName)
	}
	// 第一次使用：写入标记
	if err := os.WriteFile(mk, []byte("回笺（Huijian）"+g.kind+" 目录标记，请勿删除。\n"), 0o640); err != nil {
		return fmt.Errorf("目录 %s 无法写入：%w", g.dir, err)
	}
	g.st.SetKV(key, now())
	return nil
}

// ---------- 附件 ----------

type fileStore struct {
	h        *Hub
	files    *dirGuard
	local    string // 数据目录/files：附件目录不可用时的暂存
	legacy   string // 数据目录/blobs：旧版本附件
	mu       sync.Mutex
	degraded bool // 正在使用本地暂存
}

func newFileStore(h *Hub, filesDir string) *fileStore {
	return &fileStore{
		h:      h,
		files:  &dirGuard{dir: filesDir, kind: "files", local: within(filesDir, h.dataDir), st: h.st},
		local:  filepath.Join(h.dataDir, "files"),
		legacy: filepath.Join(h.dataDir, "blobs"),
	}
}

// roots：按查找顺序排列、去重后的根目录
func (fst *fileStore) roots() []string {
	out := []string{fst.files.dir}
	for _, d := range []string{fst.local, fst.legacy} {
		if absPath(d) != absPath(fst.files.dir) {
			out = append(out, d)
		}
	}
	return out
}

// find 根据数据库里的相对路径找到文件
func (fst *fileStore) find(rel string) (string, bool) {
	if !safeRel(rel) {
		return "", false
	}
	for _, root := range fst.roots() {
		p := filepath.Join(root, filepath.FromSlash(strings.ReplaceAll(rel, `\`, "/")))
		if fi, err := os.Stat(p); err == nil && fi.Mode().IsRegular() {
			return p, true
		}
	}
	return "", false
}

func safeRel(rel string) bool {
	rel = strings.ReplaceAll(rel, `\`, "/") // 旧版本在 Windows 上存的 blob 路径是 ab\abcd…
	return rel != "" && !strings.HasPrefix(rel, "/") && !filepath.IsAbs(rel) && !strings.HasPrefix(filepath.Clean(rel), "..") &&
		!strings.Contains(rel, "/../")
}

// writeRoot 返回新附件写到哪里；附件目录不可用时回落到本地暂存，并通知一次
func (fst *fileStore) writeRoot() string {
	err := fst.files.ready()
	fst.mu.Lock()
	defer fst.mu.Unlock()
	if err == nil {
		if fst.degraded {
			fst.degraded = false
			log.Printf("附件目录已恢复：%s", fst.files.dir)
		}
		return fst.files.dir
	}
	if !fst.degraded {
		fst.degraded = true
		log.Printf("附件目录不可用，新附件暂存到 %s：%v", fst.local, err)
		fst.h.notice("files-unavailable", 4, "回笺：附件目录不可用，已暂存到本地",
			"附件目录：`"+fst.files.dir+"`\n\n原因："+err.Error()+
				"\n\n新收到的附件先保存在服务器本地，目录恢复后会自动搬回去。docker 部署时，如果 NAS 是在容器启动之后才挂载上的，需要重启容器（docker compose restart）。")
	}
	os.MkdirAll(fst.local, 0o750)
	return fst.local
}

// claimAttDir 为一条消息的附件占用一个新目录：年/月/日/时分秒_标题。
// 用 os.Mkdir 原子创建（已存在就换编号），并发的同名请求不会分到同一个目录。
func claimAttDir(root string, t time.Time, title string) (string, error) {
	day := t.Format("2006/01/02")
	if err := os.MkdirAll(filepath.Join(root, filepath.FromSlash(day)), 0o750); err != nil {
		return "", err
	}
	base := day + "/" + t.Format("150405")
	if s := pathSegment(title, 60); s != "" {
		base += "_" + s
	}
	rel := base
	for i := 2; i < 1000; i++ {
		err := os.Mkdir(filepath.Join(root, filepath.FromSlash(rel)), 0o750)
		if err == nil {
			return rel, nil
		}
		if !os.IsExist(err) {
			return "", err
		}
		rel = fmt.Sprintf("%s_%d", base, i)
	}
	return "", errors.New("同一秒内同名目录太多")
}

var reReserved = regexp.MustCompile(`(?i)^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$`)

// pathSegment：可以安全用作目录 / 文件名的一段（兼容 Windows 和 SMB 共享）。
// maxBytes 按 UTF-8 字节限制长度（多数文件系统的文件名上限是 255 字节，中文一个字 3 字节）。
func pathSegment(s string, maxBytes int) string {
	s = strings.Map(func(r rune) rune {
		switch {
		case unicode.IsControl(r), strings.ContainsRune(`/\:*?"<>|`, r):
			return '_'
		}
		return r
	}, s)
	s = strings.Join(strings.Fields(s), " ")
	s = truncBytes(s, maxBytes)
	s = strings.Trim(s, " .")
	if reReserved.MatchString(s) {
		s = "_" + s
	}
	return s
}

func truncBytes(s string, max int) string {
	if len(s) <= max {
		return s
	}
	s = s[:max]
	for !utf8.ValidString(s) {
		s = s[:len(s)-1]
	}
	return s
}

// fileName：附件的文件名，保留扩展名，总长不超过 200 字节；n>1 时加「 (n)」
func fileName(orig string, n int) string {
	ext := ""
	if e := pathSegment(strings.TrimPrefix(filepath.Ext(orig), "."), 24); e != "" {
		ext = "." + e
	}
	stem := pathSegment(strings.TrimSuffix(orig, filepath.Ext(orig)), 200-len(ext)-8)
	if stem == "" {
		stem = "file"
	}
	if n > 1 {
		stem += fmt.Sprintf(" (%d)", n)
	}
	return stem + ext
}

// save 保存一条消息的附件，每条消息一个目录。内容和已有附件相同时，尽量用硬链接（不占额外空间），
// 这样每条消息的附件都能在自己的日期目录里看到，删掉旧日期目录也不会影响新消息。
func (fst *fileStore) save(files []*upFile, title string, t time.Time) ([]string, error) {
	rels := make([]string, len(files))
	root := fst.writeRoot()
	dir, err := claimAttDir(root, t, title)
	if err != nil && root != fst.local {
		// 附件目录刚通过检查又出错（例如 NAS 掉线）：改存本地暂存
		root = fst.local
		os.MkdirAll(root, 0o750)
		dir, err = claimAttDir(root, t, title)
	}
	if err != nil {
		return nil, err
	}
	used := map[string]bool{} // 按小写记录，避免在不区分大小写的文件系统上 A.png 和 a.png 互相覆盖
	for i, f := range files {
		var name string
		for n := 1; ; n++ {
			name = fileName(f.name, n)
			if !used[strings.ToLower(name)] {
				break
			}
		}
		used[strings.ToLower(name)] = true
		rel := dir + "/" + name
		dst := filepath.Join(root, filepath.FromSlash(rel))
		linked := false
		if old := fst.h.st.BlobBySha(f.sha256); old != "" {
			if p, ok := fst.find(old); ok && os.Link(p, dst) == nil {
				linked = true
				os.Remove(f.tmp)
			}
		}
		if !linked {
			if err := moveFile(f.tmp, dst); err != nil {
				return nil, err
			}
		}
		f.tmp = ""
		rels[i] = rel
	}
	return rels, nil
}

// relocate：附件目录恢复后，把暂存在本地的附件搬回去（附件目录本身就在本地时什么都不做）。
// 目标位置已有同名文件（暂存期间附件目录里出现了同名目录）时换一个目录，并更新数据库里的路径。
func (fst *fileStore) relocate() (int, error) {
	if absPath(fst.files.dir) == absPath(fst.local) || fst.files.ready() != nil {
		return 0, nil
	}
	n := 0
	err := filepath.WalkDir(fst.local, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || hasPartSuffix(d.Name()) {
			return nil
		}
		relOS, _ := filepath.Rel(fst.local, p)
		rel := filepath.ToSlash(relOS)
		dst := filepath.Join(fst.files.dir, relOS)
		if _, err := os.Stat(dst); err == nil {
			// 冲突：放到 <目录>_r<n>/ 下，并改数据库
			dirRel, name := filepath.ToSlash(filepath.Dir(relOS)), filepath.Base(relOS)
			for k := 2; ; k++ {
				alt := fmt.Sprintf("%s_r%d/%s", dirRel, k, name)
				if _, err := os.Stat(filepath.Join(fst.files.dir, filepath.FromSlash(alt))); os.IsNotExist(err) {
					if err := moveFile(p, filepath.Join(fst.files.dir, filepath.FromSlash(alt))); err != nil {
						return err
					}
					fst.h.st.db.Exec(`UPDATE attachments SET blob=? WHERE blob=?`, alt, rel)
					n++
					return nil
				} else if err != nil && !os.IsNotExist(err) {
					return err
				}
				if k > 1000 {
					return nil
				}
			}
		}
		if err := moveFile(p, dst); err != nil {
			return err
		}
		n++
		return nil
	})
	if n > 0 {
		log.Printf("已把 %d 个暂存附件搬回 %s", n, fst.files.dir)
		removeEmptyDirs(fst.local)
	}
	return n, err
}

func removeEmptyDirs(root string) {
	var dirs []string
	filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err == nil && d.IsDir() && p != root {
			dirs = append(dirs, p)
		}
		return nil
	})
	for i := len(dirs) - 1; i >= 0; i-- {
		os.Remove(dirs[i]) // 非空时会失败，正好
	}
}

// moveFile：同一文件系统直接改名，跨文件系统（例如本地 → NAS）则复制后删除
func moveFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o750); err != nil {
		return err
	}
	if err := os.Rename(src, dst); err == nil {
		return nil
	}
	if err := copyFileSync(src, dst); err != nil {
		return err
	}
	return os.Remove(src)
}

// copyFileSync 先写临时文件、落盘后再改名，避免留下写了一半的文件
func copyFileSync(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o750); err != nil {
		return err
	}
	tmp := dst + partSuffix
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o640)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Sync(); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}

// dirUsage 统计目录下文件数和总大小
func dirUsage(root string) (n int, size int64) {
	filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && !isMarkerName(d.Name()) {
			if fi, err := d.Info(); err == nil {
				n++
				size += fi.Size()
			}
		}
		return nil
	})
	return
}

// ---------- 系统通知：用回笺自己给用户发消息 ----------

var noticeMu sync.Mutex
var noticeLast = map[string]time.Time{}

// notice 同一类通知 6 小时内只发一次
func (h *Hub) notice(kind string, prio int, title, body string) {
	noticeMu.Lock()
	if t, ok := noticeLast[kind]; ok && time.Since(t) < 6*time.Hour {
		noticeMu.Unlock()
		return
	}
	noticeLast[kind] = time.Now()
	noticeMu.Unlock()
	if _, _, err := h.st.InsertMessage(NewMessage{UserID: h.userID, Topic: "huijian", Priority: prio, Type: "markdown",
		Text: title, Desp: body, Source: "回笺服务端"}); err != nil {
		log.Printf("发送系统通知失败: %v", err)
		return
	}
	if h.br != nil {
		h.br.Notify(h.userID)
	}
}
