package main

// 服务端更新的网络部分：代理、镜像、耐心的下载（空闲超时、断点续传、进度）。
//
// 代理只用于更新相关的请求（GitHub API、清单、程序下载），不影响 Bark 等其他出站请求。优先级：
//
//	管理后台「服务端更新」里设置的代理（存在 KV update:proxy）
//	> 环境变量 HUIJIAN_SERVER_UPDATE_PROXY
//	> 标准的 HTTPS_PROXY / HTTP_PROXY / NO_PROXY
//	> 直连
//
// 镜像 HUIJIAN_SERVER_UPDATE_MIRROR 作为前缀加在清单和程序的下载地址前面（例如 https://ghproxy.example/），
// 不用于 API。镜像、代理都不需要可信：程序和清单都要通过内置公钥的签名校验和 sha256 校验才会安装。

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const updProxyKey = "update:proxy" // KV：管理后台设置的更新代理

var (
	updIdleTimeout   = 60 * time.Second // 连续这么久收不到数据才算失败（测试时调短）
	updMaxDuration   = 2 * time.Hour    // 一次下载的总时长上限
	updProgressEvery = time.Second      // 进度刷新间隔
)

// 管理后台设置的代理。checkServerUpdate 等是普通函数，拿不到 Hub，所以放在包级变量里，启动时从 KV 读入
var updPageProxy struct {
	sync.RWMutex
	v string
}

func setPageProxy(v string) {
	updPageProxy.Lock()
	updPageProxy.v = strings.TrimSpace(v)
	updPageProxy.Unlock()
}

func pageProxy() string {
	updPageProxy.RLock()
	defer updPageProxy.RUnlock()
	return updPageProxy.v
}

var errProxyFormat = errors.New("代理地址格式不对，例如 http://127.0.0.1:7890 或 socks5://127.0.0.1:1080")

// parseUpdateProxy 校验代理地址：只接受 http://、https://、socks5://、socks5h://，必须有主机名，不能带路径和参数
func parseUpdateProxy(s string) (*url.URL, error) {
	u, err := url.Parse(strings.TrimSpace(s))
	if err != nil || u.Opaque != "" || u.Hostname() == "" {
		return nil, errProxyFormat
	}
	u.Scheme = strings.ToLower(u.Scheme)
	switch u.Scheme {
	case "http", "https", "socks5", "socks5h":
	default:
		return nil, errors.New("只支持 http://、https://、socks5://、socks5h:// 代理")
	}
	if (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
		return nil, errProxyFormat
	}
	if p := u.Port(); p != "" {
		if n, err := strconv.Atoi(p); err != nil || n < 1 || n > 65535 {
			return nil, errProxyFormat
		}
	}
	u.Path = ""
	return u, nil
}

// maskURL：显示用，遮住地址里的用户名和密码
func maskURL(u *url.URL) string {
	if u == nil {
		return ""
	}
	c := *u
	c.User = nil
	s := c.String()
	if u.User != nil {
		s = strings.Replace(s, "://", "://***@", 1)
	}
	return s
}

// maskRawURL：解析不了时只显示协议部分，避免把可能含密码的原文显示出来
func maskRawURL(s string) string {
	u, err := url.Parse(strings.TrimSpace(s))
	if err != nil || u.Host == "" {
		if i := strings.Index(s, "://"); i > 0 && !strings.ContainsAny(s[:i], "@:/") {
			return s[:i] + "://…"
		}
		return "（无法解析）"
	}
	return maskURL(u)
}

type updProxyInfo struct {
	URL    *url.URL
	Source string // page / env / system / direct
	Err    error  // 已经是不含原文的说明，可以直接显示
	Masked string // 出错时用来显示的地址（密码已遮住）
}

var proxySourceLabel = map[string]string{
	"page":   "管理页设置",
	"env":    "环境变量 HUIJIAN_SERVER_UPDATE_PROXY",
	"system": "系统代理（HTTPS_PROXY / HTTP_PROXY）",
	"direct": "直连",
}

// sysProxyFunc：标准代理变量（测试时替换）
var sysProxyFunc = http.ProxyFromEnvironment

// sysProxyEnv：请求这个协议时标准库会读哪个变量（大写优先，和 net/http 一致）
func sysProxyEnv(scheme string) (name, val string) {
	names := []string{"HTTPS_PROXY", "https_proxy"}
	if scheme == "http" {
		names = []string{"HTTP_PROXY", "http_proxy"}
	}
	for _, n := range names {
		if v := os.Getenv(n); v != "" {
			return n, v
		}
	}
	return names[0], ""
}

// sysProxyBad：标准库遇到格式不对的代理变量会悄悄改成直连，或者补上 http:// 后拿一个奇怪的地址去连
// （以后的版本也可能报错并带出原文、包括密码）。这里用和页面设置相同的规则先检查一遍
// （另外接受标准库也认的、不写协议的 host:port），不对就用固定文案报错，不走直连
func sysProxyBad(scheme string) error {
	name, v := sysProxyEnv(scheme)
	if v == "" {
		return nil
	}
	if _, err := parseUpdateProxy(v); err == nil {
		return nil
	}
	if !strings.Contains(v, "://") {
		if _, err := parseUpdateProxy("http://" + v); err == nil {
			return nil
		}
	}
	return sysProxyErr(scheme, name)
}

func sysProxyErr(scheme, name string) error {
	_, v := sysProxyEnv(scheme)
	if v == "" {
		return fmt.Errorf("系统代理 %s 格式不对", name)
	}
	return fmt.Errorf("系统代理 %s 格式不对（%s）", name, maskRawURL(v))
}

// currentUpdateProxy：当前生效的更新代理（系统代理按 GitHub API 地址判断 NO_PROXY）
func currentUpdateProxy() updProxyInfo {
	if v := pageProxy(); v != "" {
		u, err := parseUpdateProxy(v)
		return updProxyInfo{u, "page", err, maskRawURL(v)}
	}
	if v := strings.TrimSpace(env("HUIJIAN_SERVER_UPDATE_PROXY", "")); v != "" {
		u, err := parseUpdateProxy(v)
		return updProxyInfo{u, "env", err, maskRawURL(v)}
	}
	req, _ := http.NewRequest("GET", ghAPI()+"/", nil)
	name, raw := sysProxyEnv(req.URL.Scheme)
	if err := sysProxyBad(req.URL.Scheme); err != nil {
		return updProxyInfo{nil, "system", err, maskRawURL(raw)}
	}
	u, err := sysProxyFunc(req)
	if err != nil {
		return updProxyInfo{nil, "system", sysProxyErr(req.URL.Scheme, name), maskRawURL(raw)}
	}
	if u != nil {
		return updProxyInfo{u, "system", nil, ""}
	}
	return updProxyInfo{nil, "direct", nil, ""}
}

// proxyHint：日志和错误信息里说明走的是哪条路（密码已遮住）
func proxyHint() string {
	p := currentUpdateProxy()
	switch {
	case p.Err != nil:
		return "代理设置有误：" + p.Err.Error()
	case p.URL == nil:
		return "直连"
	}
	return "代理 " + maskURL(p.URL) + "，来自" + proxySourceLabel[p.Source]
}

// updProxyFunc：更新用 Transport 的 Proxy，每个请求都按当前设置决定（页面上改了立即生效）
func updProxyFunc(req *http.Request) (*url.URL, error) {
	p := currentUpdateProxy()
	switch p.Source {
	case "direct":
		return nil, nil
	case "system":
		if err := sysProxyBad(req.URL.Scheme); err != nil {
			return nil, err
		}
		u, err := sysProxyFunc(req)
		if err != nil { // 不把标准库的原始报错（可能带密码）传出去
			name, _ := sysProxyEnv(req.URL.Scheme)
			return nil, sysProxyErr(req.URL.Scheme, name)
		}
		return u, nil
	}
	if p.Err != nil {
		return nil, fmt.Errorf("更新代理（%s）%v", proxySourceLabel[p.Source], p.Err)
	}
	return p.URL, nil
}

// updHTTP：只给更新用。没有总超时：API 请求由调用方的 context 限时，下载由 downloadResumable 控制空闲超时和总时长
var updHTTP = func() *http.Client {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.Proxy = updProxyFunc
	return &http.Client{Transport: t}
}()

// updDirectHTTP：不走任何代理，只用于 GitHub API 经代理被限流时的退路
var updDirectHTTP = func() *http.Client {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.Proxy = nil
	return &http.Client{Transport: t}
}()

// updateMirror：下载镜像前缀（不用于 API）
func updateMirror() string { return strings.TrimSpace(env("HUIJIAN_SERVER_UPDATE_MIRROR", "")) }

func withMirror(u string) string {
	if m := updateMirror(); m != "" && u != "" {
		return m + u
	}
	return u
}

// ---------- 下载 ----------

// downloadMeta：部分下载的文件对应哪个版本（dst.json），sha 和大小都一致才续传
type downloadMeta struct {
	Sha256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

var (
	errIdle    = errors.New("idle")
	errTooLong = errors.New("too long")
	errRestart = errors.New("restart")
)

// downloadResumable 把 rawURL 下载到 dst，最终整体校验大小和 sha256。
//   - 连续 updIdleTimeout 收不到数据才算失败，总时长不超过 updMaxDuration；
//   - 中断时保留部分文件，并在 dst.json 里记下对应的 sha256 和大小；下次下载同一个 sha 时发 Range 请求续传，
//     对方回 200 就从头下载；
//   - 校验不通过、磁盘写满时删掉文件和记录，返回错误；
//   - 成功时 dst 是完整文件，dst.json 保留：后面的步骤（试运行、备份）失败时，下次直接用这个文件，不用重新下载。
//     安装成功后由 installVerified 删除记录（见 discardDownload）。
//
// dst 只接受普通文件：是符号链接或别的东西就删掉重新下载。
// progress 大约每 updProgressEvery 调用一次（已下载、总大小、速度 字节/秒）。
func downloadResumable(ctx context.Context, rawURL, dst string, size int64, sha string, progress func(done, total int64, speed float64)) error {
	metaPath := dst + ".json"
	discard := func() { discardDownload(dst) }

	var off int64
	var old downloadMeta
	if b, err := os.ReadFile(metaPath); err == nil && json.Unmarshal(b, &old) == nil && old.Sha256 == sha && old.Size == size {
		if fi, err := os.Lstat(dst); err == nil && fi.Mode().IsRegular() && fi.Size() <= size {
			off = fi.Size()
		}
	}
	if off == 0 {
		discard()
	}
	mb, _ := json.Marshal(downloadMeta{Sha256: sha, Size: size})
	if err := os.WriteFile(metaPath, mb, 0o640); err != nil {
		return err
	}
	if off == size { // 上次已经下完（例如下载后备份失败），校验一下就直接用
		if sum, err := fileSha256(dst); err == nil && sum == sha {
			if progress != nil {
				progress(size, size, 0)
			}
			return nil
		}
		discard()
		os.WriteFile(metaPath, mb, 0o640)
		off = 0
	}

	ctx, cancelAll := context.WithTimeoutCause(ctx, updMaxDuration, errTooLong)
	defer cancelAll()
	for attempt := 0; ; attempt++ {
		err := downloadOnce(ctx, rawURL, dst, off, size, sha, progress)
		if errors.Is(err, errRestart) && attempt == 0 { // 续传不成（范围不对 / 416 / 部分文件不对）：丢掉，从头下载一次
			discard()
			os.WriteFile(metaPath, mb, 0o640)
			off = 0
			continue
		}
		return err
	}
}

// discardDownload：删除下载的文件和它的记录
func discardDownload(dst string) {
	os.Remove(dst)
	os.Remove(dst + ".json")
}

// writeChunk：写盘（测试时替换，模拟磁盘写满）
var writeChunk = func(f *os.File, b []byte) (int, error) { return f.Write(b) }

// openDownload：续传时以追加方式打开已有的普通文件（打开后再核对一次，不跟随符号链接）；
// 从头下载时先删除再独占创建，路径上即使出现符号链接也不会写到别处
func openDownload(dst string, off int64) (*os.File, error) {
	if off == 0 {
		os.Remove(dst)
		return os.OpenFile(dst, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o750)
	}
	lfi, err := os.Lstat(dst)
	if err != nil || !lfi.Mode().IsRegular() || lfi.Size() != off {
		return nil, errRestart
	}
	f, err := os.OpenFile(dst, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		return nil, errRestart
	}
	if ffi, err := f.Stat(); err != nil || !os.SameFile(lfi, ffi) {
		f.Close()
		return nil, errRestart
	}
	return f, nil
}

func downloadOnce(parent context.Context, rawURL, dst string, off, size int64, sha string, progress func(done, total int64, speed float64)) error {
	ctx, cancel := context.WithCancelCause(parent)
	defer cancel(nil)
	idle := time.AfterFunc(updIdleTimeout, func() { cancel(errIdle) })
	defer idle.Stop()

	req, err := http.NewRequestWithContext(ctx, "GET", rawURL, nil)
	if err != nil {
		return fmt.Errorf("下载地址不对：%v", err)
	}
	req.Header.Set("User-Agent", "huijian/"+version)
	if off > 0 {
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-", off))
	}
	resp, err := updHTTP.Do(req)
	if err != nil {
		return dlErr(ctx, err, off, size)
	}
	defer resp.Body.Close()

	hs := sha256.New()
	switch {
	case off > 0 && resp.StatusCode == http.StatusPartialContent:
		if !rangeStartsAt(resp.Header.Get("Content-Range"), off, size) {
			return errRestart
		}
		if fi, err := os.Lstat(dst); err != nil || !fi.Mode().IsRegular() {
			return errRestart
		}
		if err := hashPrefix(dst, off, hs); err != nil {
			return errRestart
		}
	case resp.StatusCode == http.StatusOK:
		off = 0 // 对方不支持续传：从头下载
	case off > 0 && resp.StatusCode == http.StatusRequestedRangeNotSatisfiable:
		return errRestart
	default:
		return fmt.Errorf("下载失败：HTTP %d", resp.StatusCode)
	}

	f, err := openDownload(dst, off)
	if err == errRestart {
		return err
	}
	if err != nil {
		return fmt.Errorf("创建下载文件失败：%v", err)
	}
	done := off
	lastT, lastN := time.Now(), done
	if progress != nil {
		progress(done, size, 0)
	}
	buf := make([]byte, 64<<10)
	body := io.LimitReader(resp.Body, size-off+1)
	var rerr error
	for {
		n, err := body.Read(buf)
		if n > 0 {
			idle.Reset(updIdleTimeout)
			if _, werr := writeChunk(f, buf[:n]); werr != nil {
				f.Close()
				if errors.Is(werr, syscall.ENOSPC) { // 磁盘满了：留着部分文件也没用，删掉腾出空间
					discardDownload(dst)
					return errors.New("磁盘空间不足，下载的部分已删除；清理磁盘后再试")
				}
				return fmt.Errorf("写入下载文件失败：%v", werr)
			}
			hs.Write(buf[:n])
			done += int64(n)
			if now := time.Now(); progress != nil && now.Sub(lastT) >= updProgressEvery {
				progress(done, size, float64(done-lastN)/now.Sub(lastT).Seconds())
				lastT, lastN = now, done
			}
		}
		if err != nil {
			if err != io.EOF {
				rerr = err
			}
			break
		}
	}
	if err := f.Close(); err != nil && rerr == nil {
		if errors.Is(err, syscall.ENOSPC) {
			discardDownload(dst)
			return errors.New("磁盘空间不足，下载的部分已删除；清理磁盘后再试")
		}
		rerr = err
	}
	if rerr != nil {
		return dlErr(ctx, rerr, done, size)
	}
	if done < size {
		return fmt.Errorf("下载中断（已下载 %s / %s，下次从断点继续）", mbStr(done), humanBytes(size))
	}
	if done != size || hex.EncodeToString(hs.Sum(nil)) != sha {
		discardDownload(dst)
		return errors.New("下载的文件和签名清单不一致，已丢弃")
	}
	return nil
}

// dlErr：把超时原因翻译成人能看懂的话；部分文件保留，下次续传
func dlErr(ctx context.Context, err error, done, size int64) error {
	where := fmt.Sprintf("已下载 %s / %s，下次从断点继续", mbStr(done), humanBytes(size))
	switch context.Cause(ctx) {
	case errIdle:
		return fmt.Errorf("连续 %s 没有收到数据（%s）；网络慢可以在下面设置下载代理", updIdleTimeout, where)
	case errTooLong:
		return fmt.Errorf("下载超过 %s 仍未完成（%s）", updMaxDuration, where)
	}
	return fmt.Errorf("下载中断：%v（%s）", err, where)
}

// rangeStartsAt：Content-Range 必须是 bytes off-(size-1)/size（总大小未知时写 *）
func rangeStartsAt(cr string, off, size int64) bool {
	rest, ok := strings.CutPrefix(strings.TrimSpace(cr), "bytes ")
	if !ok {
		return false
	}
	rng, total, ok := strings.Cut(rest, "/")
	if !ok || (total != "*" && total != strconv.FormatInt(size, 10)) {
		return false
	}
	a, b, ok := strings.Cut(rng, "-")
	start, err1 := strconv.ParseInt(a, 10, 64)
	end, err2 := strconv.ParseInt(b, 10, 64)
	return ok && err1 == nil && err2 == nil && start == off && end == size-1
}

// hashPrefix：续传前把已有的部分算进 sha256
func hashPrefix(p string, n int64, hs hash.Hash) error {
	f, err := os.Open(p)
	if err != nil {
		return err
	}
	defer f.Close()
	c, err := io.Copy(hs, io.LimitReader(f, n))
	if err == nil && c != n {
		err = io.ErrUnexpectedEOF
	}
	return err
}

func mbStr(n int64) string { return fmt.Sprintf("%.1f", float64(n)/(1<<20)) }

// speedStr：120 KB/s、5.2 MB/s
func speedStr(bps float64) string {
	if bps >= 1<<20 {
		return fmt.Sprintf("%.1f MB/s", bps/(1<<20))
	}
	return fmt.Sprintf("%.0f KB/s", bps/1024)
}

// progressStage：「下载 0.6.2：3.1 / 13.4 MB · 120 KB/s」
func progressStage(ver string, done, total int64, speed float64) string {
	s := fmt.Sprintf("下载 %s：%s / %s", ver, mbStr(done), humanBytes(total))
	if speed > 0 {
		s += " · " + speedStr(speed)
	}
	return s
}
