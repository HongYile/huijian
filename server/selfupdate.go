package main

// 服务端一键更新。
//
// 来源：GitHub Releases（默认 HongYile/huijian，HUIJIAN_SERVER_UPDATE_REPO 可改成自己的 fork）。
// 服务端版本发布在 tag 为 server-v<版本> 的 release 里（不标为 latest，免得影响 Mac 客户端的更新检查），附带：
//
//	huijian-<版本>-linux-amd64、huijian-<版本>-linux-arm64   可执行文件
//	update-server.json                                     签名清单
//
// 信任模型和客户端更新一样：清单里每个平台的 sha256 用发布方的 Ed25519 私钥签名，服务端内置公钥校验
// （HUIJIAN_SERVER_UPDATE_PUBKEY 可改）。GitHub 或网络被劫持也无法让服务器运行伪造的程序。
//
// 应用更新：下载 → 校验大小、sha256、签名 → 试运行 `新程序 version` → 备份数据库 → 放到数据目录的 bin/
// → 平滑关闭后原地 exec 新程序（进程号不变，Docker 和 systemd 都不需要额外配置）。
// 以后容器重建、机器重启时，镜像里的旧程序启动后发现 bin/ 里有更新的版本，会自动切过去（bootStaged）。
// 新版本连续 3 次没能正常运行满 1 分钟就自动回退到镜像里的版本，并记下这个版本不再自动切换。
//
// 程序也可以不从 GitHub 来：管理后台手动上传、开发机用 `huijian server-push` 推送（见 selfupdate_upload.go）。
// 不论从哪里来，都走同一个 installVerified：重新验签、核对 sha256 和大小，版本必须比当前新。
//
// HUIJIAN_SERVER_UPDATE=0 关闭检查、一键更新、手动上传和推送（例如由运维统一升级镜像）。
// HUIJIAN_SERVER_UPDATE_API 可以换 GitHub API 地址（镜像或 GitHub Enterprise）。
// 代理、镜像、断点续传见 selfupdate_net.go。

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// 公开渠道公钥：和 Mac 公开版 mac/build.sh 里的 UPDATE_PUBKEY 是同一把
const officialUpdatePubKey = "XySRu/CNn8ODqgnD5ZLZWGo3VbVryLv1RTjVETHekZw="

const (
	serverTagPrefix  = "server-v"
	serverManifest   = "update-server.json"
	maxServerBinary  = 200 << 20
	bootMaxAttempts  = 3
	bootHealthyAfter = time.Minute
)

// selfUpdateEnabled：是否检查和允许一键更新。Windows 上不支持原地替换进程，一律关闭
func selfUpdateEnabled() bool {
	return runtime.GOOS != "windows" && env("HUIJIAN_SERVER_UPDATE", "1") != "0"
}
func updateRepo() string     { return env("HUIJIAN_SERVER_UPDATE_REPO", "HongYile/huijian") }
func updatePubKey() string   { return env("HUIJIAN_SERVER_UPDATE_PUBKEY", officialUpdatePubKey) }
func serverPlatform() string { return runtime.GOOS + "-" + runtime.GOARCH }

var githubAPI = "" // 测试时直接替换

// ghAPI：GitHub API 地址，可用 HUIJIAN_SERVER_UPDATE_API 换成镜像或测试服务器（读环境变量放在调用时，配置文件已加载）
func ghAPI() string {
	if githubAPI != "" {
		return githubAPI
	}
	return strings.TrimRight(env("HUIJIAN_SERVER_UPDATE_API", "https://api.github.com"), "/")
}

// ---------- 版本比较 ----------

var verNum = regexp.MustCompile(`^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?`)

// versionLess：a < b（只比较数字部分，0.6.0 < 0.6.1 < 0.10.0）
func versionLess(a, b string) bool {
	pa, pb := verParts(a), verParts(b)
	for i := range pa {
		if pa[i] != pb[i] {
			return pa[i] < pb[i]
		}
	}
	return false
}

func verParts(s string) [3]int {
	var out [3]int
	m := verNum.FindStringSubmatch(strings.TrimSpace(s))
	for i := 1; m != nil && i <= 3; i++ {
		out[i-1], _ = strconv.Atoi(m[i])
	}
	return out
}

// ---------- 清单 ----------

type serverManifestFile struct {
	Version   string                          `json:"version"`
	Build     int64                           `json:"build"`
	Notes     string                          `json:"notes"`
	Platforms map[string]serverManifestBinary `json:"platforms"`
}

type serverManifestBinary struct {
	File      string `json:"file"`
	Size      int64  `json:"size"`
	Sha256    string `json:"sha256"`
	Signature string `json:"signature"`
}

// verifyServerBinary 校验清单里本平台条目的签名
func verifyServerBinary(m *serverManifestFile, platform, pubB64 string) (*serverManifestBinary, error) {
	b, ok := m.Platforms[platform]
	if !ok {
		return nil, fmt.Errorf("这个版本没有提供 %s 平台的程序", platform)
	}
	if !reSha256.MatchString(b.Sha256) || b.Size <= 0 || b.Size > maxServerBinary || !reVersion.MatchString(m.Version) {
		return nil, errors.New("更新清单格式不对")
	}
	key, err := base64.StdEncoding.DecodeString(pubB64)
	if err != nil || len(key) != ed25519.PublicKeySize {
		return nil, errors.New("服务端更新公钥（HUIJIAN_SERVER_UPDATE_PUBKEY）格式不对")
	}
	sig, err := base64.StdEncoding.DecodeString(b.Signature)
	if err != nil || len(sig) != ed25519.SignatureSize ||
		!ed25519.Verify(key, releaseMessage("server-"+platform, m.Build, m.Version, b.Sha256, strings.TrimSpace(m.Notes)), sig) {
		return nil, errors.New("更新签名校验失败，已拒绝（可能被篡改，或者不是用公开渠道私钥签名的）")
	}
	return &b, nil
}

// ---------- 检查 ----------

type serverUpdate struct {
	Version  string `json:"version"`
	Build    int64  `json:"build"`
	Notes    string `json:"notes"`
	Tag      string `json:"tag"`
	Page     string `json:"page"`
	Size     int64  `json:"size"`
	Newer    bool   `json:"newer"`
	binURL   string
	manifest *serverManifestFile
}

type updaterState struct {
	mu       sync.Mutex
	checked  time.Time
	latest   *serverUpdate
	checkErr string
	applying bool
	stage    string // 正在进行的步骤，给页面显示
	applyErr string
	notified string // 已经发过系统通知的版本
}

// ghGet：isAPI 为 true 表示 GitHub API 请求（会带令牌、被限流时改用直连）；清单等下载地址传 false
func ghGet(ctx context.Context, url string, isAPI bool, v any) error {
	newReq := func() *http.Request {
		req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
		req.Header.Set("Accept", "application/vnd.github+json")
		req.Header.Set("User-Agent", "huijian/"+version)
		// 令牌只发给官方 GitHub API：HUIJIAN_SERVER_UPDATE_API 换成镜像时不带，清单和程序下载也不带
		if tok := ghToken(); tok != "" && isAPI && req.URL.Hostname() == ghTokenHost {
			req.Header.Set("Authorization", "Bearer "+tok)
		}
		return req
	}
	resp, err := updHTTP.Do(newReq())
	if err != nil {
		return fmt.Errorf("连不上 GitHub（%s）：%v", proxyHint(), err)
	}
	// 代理（尤其是机场节点）的出口 IP 很多人共用，未登录的 GitHub API 按 IP 每小时只给 60 次，常常已经用光。
	// API 响应很小，直连再慢也够用：被限流时改用直连重试一次（程序下载仍然走代理）
	if isAPI && ghRateLimited(resp) && currentUpdateProxy().URL != nil {
		resp.Body.Close()
		log.Printf("GitHub API 经代理被限流，改用直连重试")
		if resp, err = updDirectHTTP.Do(newReq()); err != nil {
			return fmt.Errorf("GitHub API 经代理被限流，直连也失败：%v", err)
		}
	}
	defer resp.Body.Close()
	if isAPI && ghRateLimited(resp) {
		return errors.New("GitHub API 请求次数超限（未登录时同一出口 IP 每小时 60 次），稍后再试，或设置 HUIJIAN_SERVER_UPDATE_GITHUB_TOKEN")
	}
	if resp.StatusCode != 200 {
		return fmt.Errorf("GitHub 返回 HTTP %d", resp.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(v)
}

// ghTokenHost：只有发往这个主机的 API 请求才带令牌（测试时替换）
var ghTokenHost = "api.github.com"

// ghToken：可选的 GitHub 令牌（不需要任何权限的只读令牌即可），把 API 额度从每小时 60 次提到 5000 次
func ghToken() string { return strings.TrimSpace(env("HUIJIAN_SERVER_UPDATE_GITHUB_TOKEN", "")) }

// ghRateLimited：GitHub API 的限流响应（403 且剩余次数为 0，或 429）
func ghRateLimited(resp *http.Response) bool {
	return resp.StatusCode == http.StatusTooManyRequests ||
		(resp.StatusCode == http.StatusForbidden && resp.Header.Get("X-RateLimit-Remaining") == "0")
}

type ghRelease struct {
	Tag        string `json:"tag_name"`
	Draft      bool   `json:"draft"`
	Prerelease bool   `json:"prerelease"`
	Page       string `json:"html_url"`
	Assets     []struct {
		Name string `json:"name"`
		URL  string `json:"browser_download_url"`
		Size int64  `json:"size"`
	} `json:"assets"`
}

// checkServerUpdate 找最新的服务端 release，下载并校验清单（不下载程序本身）
func checkServerUpdate(ctx context.Context) (*serverUpdate, error) {
	var rels []ghRelease
	if err := ghGet(ctx, ghAPI()+"/repos/"+updateRepo()+"/releases?per_page=30", true, &rels); err != nil {
		return nil, err
	}
	// 取版本号最大的服务端 release（不一定是列表里的第一个，例如给旧分支补发过版本）
	var best *ghRelease
	var urls map[string]string
	for i := range rels {
		r := &rels[i]
		if r.Draft || r.Prerelease || !strings.HasPrefix(r.Tag, serverTagPrefix) {
			continue
		}
		u := map[string]string{}
		for _, a := range r.Assets {
			u[a.Name] = a.URL
		}
		if u[serverManifest] == "" {
			continue
		}
		if best == nil || versionLess(strings.TrimPrefix(best.Tag, serverTagPrefix), strings.TrimPrefix(r.Tag, serverTagPrefix)) {
			best, urls = r, u
		}
	}
	if r := best; r != nil {
		var m serverManifestFile
		if err := ghGet(ctx, withMirror(urls[serverManifest]), false, &m); err != nil {
			return nil, fmt.Errorf("下载更新清单失败：%v", err)
		}
		bin, err := verifyServerBinary(&m, serverPlatform(), updatePubKey())
		if err != nil {
			return nil, err
		}
		if urls[bin.File] == "" {
			return nil, fmt.Errorf("release 里缺少 %s", bin.File)
		}
		// 发布说明链接用仓库名和 tag 拼（API 返回的地址没有签名）
		page := "https://github.com/" + updateRepo() + "/releases/tag/" + url.PathEscape(r.Tag)
		return &serverUpdate{Version: m.Version, Build: m.Build, Notes: strings.TrimSpace(m.Notes), Tag: r.Tag, Page: page,
			Size: bin.Size, Newer: versionLess(version, m.Version), binURL: withMirror(urls[bin.File]), manifest: &m}, nil
	}
	return nil, errors.New("还没有发布过服务端版本")
}

func (h *Hub) checkUpdateNow(ctx context.Context) (*serverUpdate, error) {
	u, err := checkServerUpdate(ctx)
	h.upd.mu.Lock()
	h.upd.checked = time.Now()
	if err != nil {
		h.upd.checkErr = err.Error()
	} else {
		h.upd.latest, h.upd.checkErr = u, ""
	}
	notify := err == nil && u.Newer && h.upd.notified != u.Version && h.st.GetKV("update:notified") != u.Version
	if notify {
		h.upd.notified = u.Version
	}
	h.upd.mu.Unlock()
	if notify {
		h.st.SetKV("update:notified", u.Version)
		h.notice("server-update", 2, "回笺服务端有新版本 "+u.Version,
			fmt.Sprintf("当前 %s。打开管理后台「设置 → 服务端更新」一键更新（会先自动备份数据库）。\n\n%s", version, u.Notes))
	}
	return u, err
}

// updateLoop：启动 1 分钟后检查一次，之后每 12 小时一次
func (h *Hub) updateLoop(stop <-chan struct{}) {
	if !selfUpdateEnabled() {
		return
	}
	t := time.NewTimer(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
			if _, err := h.checkUpdateNow(ctx); err != nil {
				log.Printf("检查服务端更新：%v", err)
			}
			cancel()
			t.Reset(12 * time.Hour)
		}
	}
}

// ---------- 应用 ----------

func binDir(data string) string { return filepath.Join(data, "bin") }

// stagedState：数据目录 bin/staged.json。保存签名清单里的字段，每次启动切换前都用内置公钥重新验签，
// 所以能写数据目录的人也无法让服务端执行别的程序；程序文件固定是 bin/huijian-<版本>。
type stagedState struct {
	Version   string   `json:"version"`
	Build     int64    `json:"build"`
	Notes     string   `json:"notes"`
	Sha256    string   `json:"sha256"`
	Signature string   `json:"signature"`
	Attempts  int      `json:"attempts"`
	Bad       []string `json:"bad,omitempty"` // 启动失败过、不再自动切换的版本
}

// stagedFile：下载的程序路径；版本号不合法时返回空
func stagedFile(data, ver string) string {
	if !reVersion.MatchString(ver) {
		return ""
	}
	return preferExisting(filepath.Join(binDir(data), "huijian-"+ver))
}

// verifyStaged：重新验签并核对文件，返回可以执行的路径
func verifyStaged(data string, s *stagedState) (string, error) {
	p := stagedFile(data, s.Version)
	if p == "" {
		return "", errors.New("版本号不合法")
	}
	m := &serverManifestFile{Version: s.Version, Build: s.Build, Notes: s.Notes, Platforms: map[string]serverManifestBinary{
		serverPlatform(): {File: filepath.Base(p), Size: 1, Sha256: s.Sha256, Signature: s.Signature}}}
	if _, err := verifyServerBinary(m, serverPlatform(), updatePubKey()); err != nil {
		return "", err
	}
	if sum, err := fileSha256(p); err != nil || sum != s.Sha256 {
		return "", errors.New("文件不完整或被改动")
	}
	return p, nil
}

// pruneBad：只保留比当前版本新的失败记录（升级到更新的版本后，旧的回退提示不再显示）
func pruneBad(s *stagedState) {
	var keep []string
	for _, b := range s.Bad {
		if versionLess(version, b) {
			keep = append(keep, b)
		}
	}
	s.Bad = keep
}

func stagedPath(data string) string { return filepath.Join(binDir(data), "staged.json") }

func readStaged(data string) *stagedState {
	b, err := os.ReadFile(stagedPath(data))
	if err != nil {
		return nil
	}
	var s stagedState
	if json.Unmarshal(b, &s) != nil {
		return nil
	}
	return &s
}

func writeStaged(data string, s *stagedState) error {
	b, _ := json.MarshalIndent(s, "", "  ")
	tmp := stagedPath(data) + ".tmp"
	if err := os.WriteFile(tmp, b, 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, stagedPath(data))
}

func fileSha256(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	hs := sha256.New()
	if _, err := io.Copy(hs, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(hs.Sum(nil)), nil
}

func (h *Hub) setStage(s string) {
	h.upd.mu.Lock()
	h.upd.stage = s
	h.upd.mu.Unlock()
	if s != "" {
		log.Printf("服务端更新：%s", s)
	}
}

// setProgress：下载进度，每秒更新一次，不写日志
func (h *Hub) setProgress(s string) {
	h.upd.mu.Lock()
	h.upd.stage = s
	h.upd.mu.Unlock()
}

// beginApply：一键更新、手动上传、推送互斥，同一时间只有一个在进行
func (h *Hub) beginApply() error {
	if !selfUpdateEnabled() {
		return errors.New("服务端更新已关闭（HUIJIAN_SERVER_UPDATE=0）")
	}
	h.upd.mu.Lock()
	defer h.upd.mu.Unlock()
	if h.upd.applying {
		return errors.New("正在更新，请等当前的更新完成")
	}
	h.upd.applying, h.upd.applyErr = true, ""
	return nil
}

// abortApply：还没开始安装就失败了（例如上传的文件没通过校验），只解除占用，错误直接返回给调用方
func (h *Hub) abortApply() {
	h.upd.mu.Lock()
	h.upd.applying, h.upd.stage = false, ""
	h.upd.mu.Unlock()
}

// finishApply：安装结束。成功就请求平滑重启（保持「正在更新」直到进程被替换，避免重复操作）
func (h *Hub) finishApply(path string, err error) {
	if err != nil {
		h.upd.mu.Lock()
		h.upd.applying, h.upd.applyErr, h.upd.stage = false, err.Error(), ""
		h.upd.mu.Unlock()
		log.Printf("服务端更新失败：%v", err)
		return
	}
	h.restartTo(path)
}

// startApply 后台执行一键更新；成功后请求平滑重启到新程序
func (h *Hub) startApply() error {
	h.upd.mu.Lock()
	u := h.upd.latest
	h.upd.mu.Unlock()
	if u == nil || !u.Newer {
		if !selfUpdateEnabled() {
			return errors.New("一键更新已关闭（HUIJIAN_SERVER_UPDATE=0）")
		}
		return errors.New("没有可用的新版本，先点「检查更新」")
	}
	if err := h.beginApply(); err != nil {
		return err
	}
	go func() { h.finishApply(h.applyUpdate(u)) }()
	return nil
}

// applyUpdate：一键更新 = 从 GitHub（或镜像）获取文件 + 安装已校验文件
func (h *Hub) applyUpdate(u *serverUpdate) (string, error) {
	tmp, err := h.fetchUpdate(u)
	if err != nil {
		return "", err
	}
	return h.installVerified(u.manifest, tmp, true)
}

// fetchUpdate：下载到 bin/.download（支持断点续传），返回完整且 sha256 正确的文件路径。
// 下载中断时部分文件保留，下次续传；下载完成但后面的步骤失败时完整文件也保留，下次直接用。
func (h *Hub) fetchUpdate(u *serverUpdate) (string, error) {
	dir := binDir(h.dataDir)
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return "", fmt.Errorf("创建 %s 失败：%v", dir, err)
	}
	bin, err := verifyServerBinary(u.manifest, serverPlatform(), updatePubKey())
	if err != nil {
		return "", err
	}
	log.Printf("服务端更新：下载 %s（%s，%s）", u.Version, humanBytes(bin.Size), proxyHint())
	h.setProgress(progressStage(u.Version, 0, bin.Size, 0))
	tmp := filepath.Join(dir, ".download")
	err = downloadResumable(context.Background(), u.binURL, tmp, bin.Size, bin.Sha256, func(done, total int64, speed float64) {
		h.setProgress(progressStage(u.Version, done, total, speed))
	})
	if err != nil {
		return "", err
	}
	return tmp, nil
}

// installVerified：安装一个程序文件（一键更新、手动上传、推送共用）。
// 不信任调用方：这里重新校验清单里本平台条目的签名、文件的大小和 sha256，版本必须比当前新；
// 然后试运行 `新程序 version` → 备份数据库 → 移到 bin/huijian-<版本> → 写 staged.json。
// tmp 必须和 bin/ 在同一个文件系统（放在 bin/ 里）。成功时返回新程序路径。
//
// 失败时：上传的临时文件一律删除；一键更新下载的文件（downloaded=true）只有文件本身和清单不一致时才删除，
// 因为备份失败、试运行超时这类和文件无关的原因，下次重试时可以直接用，不用在慢网络上重新下载。
func (h *Hub) installVerified(m *serverManifestFile, tmp string, downloaded bool) (path string, err error) {
	badFile := false
	defer func() {
		switch {
		case err == nil && downloaded:
			os.Remove(tmp + ".json") // 下载记录不再需要
		case err != nil && !downloaded:
			os.Remove(tmp)
		case err != nil && badFile:
			discardDownload(tmp)
		}
	}()
	bin, err := verifyServerBinary(m, serverPlatform(), updatePubKey())
	if err != nil {
		return "", err
	}
	if !versionLess(version, m.Version) {
		return "", fmt.Errorf("v%s 不比当前的 v%s 新，不需要更新", m.Version, version)
	}
	final := stagedFile(h.dataDir, m.Version)
	if final != "" {
		final = filepath.Join(binDir(h.dataDir), "huijian-"+m.Version) // 写入总用新名，旧名另做硬链接
	}
	if final == "" || filepath.Dir(tmp) != binDir(h.dataDir) {
		return "", errors.New("内部错误：安装文件位置不对")
	}
	h.setStage("校验 " + m.Version)
	fi, err := os.Lstat(tmp)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() != bin.Size {
		badFile = true
		return "", errors.New("程序文件和签名清单不一致（大小不符），已拒绝")
	}
	if sum, err := fileSha256(tmp); err != nil || sum != bin.Sha256 {
		badFile = true
		return "", errors.New("程序文件和签名清单不一致（sha256 不符），已拒绝")
	}
	if err := os.Chmod(tmp, 0o750); err != nil {
		return "", err
	}
	h.setStage("试运行新程序")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	out, err := exec.CommandContext(ctx, tmp, "version").Output()
	cancel()
	if err != nil || strings.TrimSpace(string(out)) != m.Version {
		return "", fmt.Errorf("新程序无法在这台服务器上运行（%v %q）", err, strings.TrimSpace(string(out)))
	}
	if h.backup != nil && h.backup.enabled() {
		h.setStage("更新前备份数据库")
		if st := h.backup.RunNow("更新到 " + m.Version + " 前"); st.Error != "" {
			return "", fmt.Errorf("更新前备份失败，已取消更新：%s", st.Error)
		}
	}
	if err := os.Rename(tmp, final); err != nil {
		return "", err
	}
	linkLegacyStaged(h.dataDir, m.Version)
	old := readStaged(h.dataDir)
	st := &stagedState{Version: m.Version, Build: m.Build, Notes: strings.TrimSpace(m.Notes),
		Sha256: bin.Sha256, Signature: bin.Signature}
	if old != nil {
		for _, b := range old.Bad {
			if b != m.Version { // 手动再次更新到失败过的版本：给它一次机会
				st.Bad = append(st.Bad, b)
			}
		}
		if old.Version != m.Version {
			defer removeStaged(h.dataDir, old.Version) // 上一个下载的版本不再需要
		}
	}
	pruneBad(st)
	if err := writeStaged(h.dataDir, st); err != nil {
		removeStaged(h.dataDir, m.Version)
		return "", err
	}
	h.setStage("重启到 " + m.Version)
	return final, nil
}

func humanBytes(n int64) string { return fmt.Sprintf("%.1f MB", float64(n)/(1<<20)) }

// restartTo 请求主循环平滑关闭后 exec 新程序
func (h *Hub) restartTo(path string) {
	select {
	case h.restart <- path:
	default:
	}
}

// execSelf 用新程序替换当前进程（参数、环境变量不变）
func execSelf(path string) error {
	return syscall.Exec(path, append([]string{path}, os.Args[1:]...), os.Environ())
}

// ---------- 启动时切换 ----------

// bootStaged：hub 启动的第一步。bin/ 里有比自己新、没被标记为失败的版本就切过去
func bootStaged(data string) {
	if p := bootTarget(data); p != "" {
		if err := execSelf(p); err != nil {
			log.Printf("⚠️ 启动 %s 失败：%v，继续用 %s", p, err, version)
		}
	}
}

// bootTarget 决定要不要切换（并记录尝试次数），返回要 exec 的程序路径，空表示不切换。
// HUIJIAN_SERVER_UPDATE=0 时也照样切到已下载的版本：数据库可能已经被新版本迁移过，悄悄退回旧程序更危险。
func bootTarget(data string) string {
	if runtime.GOOS == "windows" {
		return ""
	}
	s := readStaged(data)
	if s == nil || s.Version == "" {
		return ""
	}
	clear := func(why string) string {
		log.Print(why)
		if p := stagedFile(data, s.Version); p != "" {
			os.Remove(p)
		}
		s.Version, s.Build, s.Notes, s.Sha256, s.Signature, s.Attempts = "", 0, "", "", "", 0
		pruneBad(s)
		writeStaged(data, s)
		return ""
	}
	switch {
	case s.Version == version:
		if self, err := os.Executable(); err == nil && filepath.Clean(self) != stagedFile(data, s.Version) {
			return clear(fmt.Sprintf("镜像里的程序已经是 %s，删除下载的同版本程序", version))
		}
		return "" // 运行的就是下载的版本
	case versionLess(s.Version, version):
		return clear(fmt.Sprintf("当前程序 %s 比已下载的 %s 新，删除下载的版本", version, s.Version))
	}
	for _, b := range s.Bad {
		if b == s.Version {
			return ""
		}
	}
	if s.Attempts >= bootMaxAttempts {
		log.Printf("⚠️ 已更新的版本 %s 连续 %d 次没能正常运行，回退到 %s（数据库不会回退）", s.Version, s.Attempts, version)
		s.Bad = append(s.Bad, s.Version)
		writeStaged(data, s)
		return ""
	}
	p, err := verifyStaged(data, s)
	if err != nil {
		log.Printf("⚠️ 已下载的 %s 校验失败（%v），不切换", s.Version, err)
		return ""
	}
	s.Attempts++
	if err := writeStaged(data, s); err != nil {
		log.Printf("⚠️ 无法记录启动次数（%v），为安全起见不切换到 %s", err, s.Version)
		return ""
	}
	log.Printf("切换到已更新的版本 %s（第 %d 次尝试）", s.Version, s.Attempts)
	return p
}

// cliTarget：命令行子命令（admin-link、backup、version……）也用已下载的新版本执行，不计启动次数
func cliTarget(data string) string {
	if runtime.GOOS == "windows" {
		return ""
	}
	s := readStaged(data)
	if s == nil || s.Version == "" || !versionLess(version, s.Version) {
		return ""
	}
	for _, b := range s.Bad {
		if b == s.Version {
			return ""
		}
	}
	p, err := verifyStaged(data, s)
	if err != nil {
		return ""
	}
	return p
}

// markBootHealthy：新版本正常运行满 1 分钟后清零启动计数
func markBootHealthy(data string, stop <-chan struct{}) {
	select {
	case <-stop:
		return
	case <-time.After(bootHealthyAfter):
	}
	if resetBootAttempts(data) {
		log.Printf("版本 %s 运行正常", version)
	}
}

// resetBootAttempts：当前运行的就是下载的版本时清零启动计数（正常运行满 1 分钟，或收到停止信号平滑退出）
func resetBootAttempts(data string) bool {
	s := readStaged(data)
	if s == nil || s.Version != version || s.Attempts == 0 {
		return false
	}
	s.Attempts = 0
	return writeStaged(data, s) == nil
}

// ---------- 管理网页 ----------

func (h *Hub) updateView() map[string]any {
	h.upd.mu.Lock()
	defer h.upd.mu.Unlock()
	v := map[string]any{"Enabled": selfUpdateEnabled(), "Current": version, "Platform": serverPlatform(), "Repo": updateRepo(),
		"Latest": h.upd.latest, "CheckErr": h.upd.checkErr, "Applying": h.upd.applying, "Stage": h.upd.stage, "ApplyErr": h.upd.applyErr}
	if !h.upd.checked.IsZero() {
		v["Checked"] = h.upd.checked.Unix()
	}
	if s := readStaged(h.dataDir); s != nil {
		v["Bad"] = s.Bad
	}
	p := currentUpdateProxy()
	v["ProxySource"], v["PageProxy"] = proxySourceLabel[p.Source], pageProxy() != ""
	switch {
	case p.Err != nil:
		v["ProxyErr"], v["Proxy"] = p.Err.Error(), p.Masked
	case p.URL != nil:
		v["Proxy"] = maskURL(p.URL)
	}
	if m := updateMirror(); m != "" {
		v["Mirror"] = maskRawURL(m)
	}
	return v
}

func (h *Hub) adminCheckUpdate(w http.ResponseWriter, r *http.Request) {
	if !selfUpdateEnabled() {
		redirectFlash(w, r, "/settings#update", "服务端一键更新已关闭（HUIJIAN_SERVER_UPDATE=0）")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	u, err := h.checkUpdateNow(ctx)
	switch {
	case err != nil:
		redirectFlash(w, r, "/settings#update", "检查更新失败："+err.Error())
	case u.Newer:
		redirectFlash(w, r, "/settings#update", "有新版本 "+u.Version)
	default:
		redirectFlash(w, r, "/settings#update", "已是最新版本（"+version+"）")
	}
}

func (h *Hub) adminApplyUpdate(w http.ResponseWriter, r *http.Request) {
	if err := h.startApply(); err != nil {
		redirectFlash(w, r, "/settings#update", err.Error())
		return
	}
	redirectFlash(w, r, "/settings#update", "开始更新，进度显示在下面；完成后服务自动重启（约半分钟）")
}
