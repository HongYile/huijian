package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func TestVersionLess(t *testing.T) {
	for _, c := range []struct {
		a, b string
		less bool
	}{{"0.5.8", "0.6.0", true}, {"0.6.0", "0.6.0", false}, {"0.10.0", "0.9.9", false}, {"0.9.9", "0.10.0", true}, {"v1.0", "1.0.1", true}, {"1.2.3", "1.2", false}} {
		if got := versionLess(c.a, c.b); got != c.less {
			t.Errorf("versionLess(%s, %s) = %v", c.a, c.b, got)
		}
	}
}

// fakeGitHub：一个 server-v9.9.9 的 release，程序是会打印版本号的 shell 脚本
type fakeGitHub struct {
	srv      *httptest.Server
	bin      []byte
	manifest serverManifestFile
	priv     ed25519.PrivateKey
	binHits  atomic.Int32
}

func newFakeGitHub(t *testing.T, ver string) *fakeGitHub {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	t.Setenv("HUIJIAN_SERVER_UPDATE_PUBKEY", base64.StdEncoding.EncodeToString(pub))
	t.Setenv("HUIJIAN_SERVER_UPDATE_REPO", "me/huijian")
	f := &fakeGitHub{priv: priv, bin: []byte("#!/bin/sh\necho " + ver + "\n")}
	sum := sha256.Sum256(f.bin)
	sha := hex.EncodeToString(sum[:])
	name := "huijian-" + ver + "-" + serverPlatform()
	f.manifest = serverManifestFile{Version: ver, Build: 99, Notes: "回笺 Markdown", Platforms: map[string]serverManifestBinary{
		serverPlatform(): {File: name, Size: int64(len(f.bin)), Sha256: sha,
			Signature: base64.StdEncoding.EncodeToString(ed25519.Sign(priv, releaseMessage("server-"+serverPlatform(), 99, ver, sha, "回笺 Markdown")))},
	}}
	mux := http.NewServeMux()
	mux.HandleFunc("/repos/me/huijian/releases", func(w http.ResponseWriter, r *http.Request) {
		base := f.srv.URL + "/dl/"
		json.NewEncoder(w).Encode([]map[string]any{
			{"tag_name": "v0.5.7", "assets": []map[string]any{{"name": "update-macos.json", "browser_download_url": base + "x"}}}, // Mac 版本，忽略
			{"tag_name": "server-v9.9.10", "prerelease": true, "assets": []map[string]any{{"name": serverManifest, "browser_download_url": base + "x"}}},
			{"tag_name": "server-v" + ver, "html_url": "https://github.com/me/huijian/releases/server-v" + ver, "assets": []map[string]any{
				{"name": serverManifest, "browser_download_url": base + serverManifest},
				{"name": name, "browser_download_url": base + name}}},
		})
	})
	mux.HandleFunc("/dl/"+serverManifest, func(w http.ResponseWriter, r *http.Request) { json.NewEncoder(w).Encode(f.manifest) })
	mux.HandleFunc("/dl/"+name, func(w http.ResponseWriter, r *http.Request) { f.binHits.Add(1); w.Write(f.bin) })
	f.srv = httptest.NewServer(mux)
	old := githubAPI
	githubAPI = f.srv.URL
	t.Cleanup(func() { f.srv.Close(); githubAPI = old })
	return f
}

func TestServerSelfUpdate(t *testing.T) {
	newFakeGitHub(t, "9.9.9")
	u, err := checkServerUpdate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if u.Version != "9.9.9" || !u.Newer || u.Tag != "server-v9.9.9" {
		t.Fatalf("检查结果不对：%+v", u)
	}

	data := t.TempDir()
	st, err := OpenStore(filepath.Join(data, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	h := &Hub{st: st, dataDir: data, restart: make(chan string, 1)}
	path, err := h.applyUpdate(u)
	if err != nil {
		t.Fatal(err)
	}
	if s := readStaged(data); s == nil || s.Version != "9.9.9" || stagedFile(data, s.Version) != path || s.Attempts != 0 || s.Signature == "" {
		t.Fatalf("staged 不对：%+v", s)
	}
	if p := cliTarget(data); p != path {
		t.Fatalf("命令行子命令也应切到新版本：%q", p)
	}

	// 启动切换：前 3 次切过去，第 4 次判定失败并回退，之后不再切
	for i := 1; i <= bootMaxAttempts; i++ {
		if p := bootTarget(data); p != path {
			t.Fatalf("第 %d 次启动应切到新版本，得到 %q", i, p)
		}
	}
	if p := bootTarget(data); p != "" {
		t.Fatalf("连续失败后应回退，得到 %q", p)
	}
	if s := readStaged(data); len(s.Bad) != 1 || s.Bad[0] != "9.9.9" {
		t.Fatalf("应记下失败的版本：%+v", s)
	}
	if p := bootTarget(data); p != "" {
		t.Fatal("标记失败的版本不应再切换")
	}

	// 平滑退出 / 正常运行满 1 分钟时清零（只在运行的就是下载的版本时）
	s := readStaged(data)
	s.Bad, s.Attempts = nil, 2
	writeStaged(data, s)
	if resetBootAttempts(data) {
		t.Fatal("当前程序不是下载的版本，不应清零")
	}
	old := version
	version = "9.9.9"
	if !resetBootAttempts(data) || readStaged(data).Attempts != 0 {
		t.Fatal("运行下载的版本时应清零")
	}
	version = old
	s = readStaged(data)
	s.Bad, s.Attempts = nil, 2
	writeStaged(data, s)
	// 能写数据目录的人改 staged.json：换 sha、换版本号、路径注入，都因为验签失败而不切换
	good, _ := os.ReadFile(stagedPath(data))
	for name, mut := range map[string]func(*stagedState){
		"换 sha": func(x *stagedState) { x.Sha256 = strings.Repeat("0", 64) },
		"换版本号":  func(x *stagedState) { x.Version = "9.9.10" },
		"路径注入":  func(x *stagedState) { x.Version = "../../evil" },
		"改说明":   func(x *stagedState) { x.Notes = "x" },
		"去掉签名":  func(x *stagedState) { x.Signature = "" },
	} {
		x := readStaged(data)
		mut(x)
		writeStaged(data, x)
		if p := bootTarget(data); p != "" {
			t.Fatalf("%s：不应切换，得到 %q", name, p)
		}
		os.WriteFile(stagedPath(data), good, 0o640)
	}
	// 文件被改动：不切换
	os.WriteFile(path, []byte("#!/bin/sh\necho evil\n"), 0o755)
	if p := bootTarget(data); p != "" || cliTarget(data) != "" {
		t.Fatal("文件被改动后不应切换")
	}

	// 镜像里的程序更新（当前版本比下载的新）：删除下载的版本
	old = version
	version = "10.0.0"
	if p := bootTarget(data); p != "" || readStaged(data).Version != "" {
		t.Fatal("镜像更新时应作废下载的旧版本")
	}
	version = old
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("旧版本文件应删除")
	}
}

func TestServerUpdateRejects(t *testing.T) {
	f := newFakeGitHub(t, "9.9.9")
	// 签名不对（用另一把私钥）
	_, other, _ := ed25519.GenerateKey(rand.Reader)
	b := f.manifest.Platforms[serverPlatform()]
	good := b.Signature
	b.Signature = base64.StdEncoding.EncodeToString(ed25519.Sign(other, releaseMessage("server-"+serverPlatform(), 99, "9.9.9", b.Sha256, "回笺 Markdown")))
	f.manifest.Platforms[serverPlatform()] = b
	if _, err := checkServerUpdate(context.Background()); err == nil || !strings.Contains(err.Error(), "签名") {
		t.Fatalf("签名不对应拒绝：%v", err)
	}
	// 说明被改：签名覆盖说明，同样拒绝
	b.Signature = good
	f.manifest.Platforms[serverPlatform()] = b
	f.manifest.Notes = "被改过的说明"
	if _, err := checkServerUpdate(context.Background()); err == nil {
		t.Fatal("说明被改应拒绝")
	}
	f.manifest.Notes = "回笺 Markdown"
	// 程序被替换：清单通过，但下载后 sha256 不符
	u, err := checkServerUpdate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	f.bin = []byte("#!/bin/sh\necho 9.9.9 # evil\n")
	data := t.TempDir()
	h := &Hub{dataDir: data}
	if _, err := h.applyUpdate(u); err == nil || !strings.Contains(err.Error(), "不一致") {
		t.Fatalf("程序被替换应拒绝：%v", err)
	}
	if readStaged(data) != nil {
		t.Fatal("失败时不应留下 staged")
	}
	// 没有本平台
	delete(f.manifest.Platforms, serverPlatform())
	if _, err := checkServerUpdate(context.Background()); err == nil || !strings.Contains(err.Error(), "平台") {
		t.Fatalf("缺少平台应报错：%v", err)
	}
	// 关闭一键更新
	t.Setenv("HUIJIAN_SERVER_UPDATE", "0")
	if err := (&Hub{}).startApply(); err == nil {
		t.Fatal("HUIJIAN_SERVER_UPDATE=0 时不应能更新")
	}
}

// OFFICIAL_MANIFEST=<update-server.json> 时用内置公钥校验发布脚本生成的清单（发布前自查）
func TestOfficialManifest(t *testing.T) {
	p := os.Getenv("OFFICIAL_MANIFEST")
	if p == "" {
		t.Skip()
	}
	b, _ := os.ReadFile(p)
	var m serverManifestFile
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	for plat := range m.Platforms {
		if _, err := verifyServerBinary(&m, plat, officialUpdatePubKey); err != nil {
			t.Errorf("%s：%v", plat, err)
		}
	}
}

// ---------- 0.6.2：代理、镜像、断点续传、手动上传、推送 ----------

// countingProxy：最简单的 HTTP 正向代理（只处理 http:// 目标），统计经过它的请求
func countingProxy(t *testing.T) (*httptest.Server, *atomic.Int32) {
	var n atomic.Int32
	direct := &http.Transport{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !r.URL.IsAbs() {
			http.Error(w, "not a proxy request", 400)
			return
		}
		n.Add(1)
		req, _ := http.NewRequest(r.Method, r.URL.String(), nil)
		req.Header = r.Header.Clone()
		resp, err := direct.RoundTrip(req)
		if err != nil {
			http.Error(w, err.Error(), 502)
			return
		}
		defer resp.Body.Close()
		for k, v := range resp.Header {
			w.Header()[k] = v
		}
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	}))
	t.Cleanup(srv.Close)
	return srv, &n
}

func resetPageProxy(t *testing.T) {
	setPageProxy("")
	t.Cleanup(func() { setPageProxy("") })
}

func TestUpdateProxyUsed(t *testing.T) {
	resetPageProxy(t)
	newFakeGitHub(t, "9.9.9")
	px, n := countingProxy(t)
	t.Setenv("HUIJIAN_SERVER_UPDATE_PROXY", px.URL)
	u, err := checkServerUpdate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got := n.Load(); got != 2 { // releases 列表 + 清单
		t.Fatalf("检查更新应经过代理 2 次，实际 %d", got)
	}
	data := t.TempDir()
	h := &Hub{dataDir: data, restart: make(chan string, 1)}
	if _, err := h.applyUpdate(u); err != nil {
		t.Fatal(err)
	}
	if got := n.Load(); got != 3 { // + 程序下载
		t.Fatalf("下载程序也应经过代理，实际共 %d 次", got)
	}
	if p := currentUpdateProxy(); p.Source != "env" || p.URL.String() != px.URL {
		t.Fatalf("来源应是环境变量：%+v", p)
	}
	// 格式不对的代理：请求直接失败，不会悄悄直连
	t.Setenv("HUIJIAN_SERVER_UPDATE_PROXY", "ftp://127.0.0.1:21")
	if _, err := checkServerUpdate(context.Background()); err == nil || !strings.Contains(err.Error(), "代理") {
		t.Fatalf("代理格式不对时应报错：%v", err)
	}
	// 只用于更新：默认 HTTP 客户端没有被改
	if http.DefaultTransport.(*http.Transport).Proxy == nil || updHTTP.Transport == http.DefaultTransport {
		t.Fatal("不应修改全局默认 Transport")
	}
}

func TestUpdateProxyPagePriority(t *testing.T) {
	resetPageProxy(t)
	newFakeGitHub(t, "9.9.9")
	envPx, envN := countingProxy(t)
	pagePx, pageN := countingProxy(t)
	t.Setenv("HUIJIAN_SERVER_UPDATE_PROXY", envPx.URL)

	data := t.TempDir()
	st, err := OpenStore(filepath.Join(data, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	h := &Hub{st: st, dataDir: data, restart: make(chan string, 1), admin: &adminState{tokenHash: sha256Hex("tok")}}
	srv := httptest.NewServer(h.adminMux())
	defer srv.Close()
	sess, _ := st.CreateSession("test", time.Hour, false)
	post := func(form url.Values) string {
		req, _ := http.NewRequest("POST", srv.URL+"/update/proxy", strings.NewReader(form.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.AddCookie(&http.Cookie{Name: cookieName, Value: sess})
		resp, err := noRedirect.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		loc, _ := url.Parse(resp.Header.Get("Location"))
		return loc.Query().Get("f")
	}
	// 页面设置（带用户名密码）：存进 KV，提示里遮住密码
	pu, _ := url.Parse(pagePx.URL)
	withPass := "http://alice:s3cret@" + pu.Host
	if f := post(url.Values{"proxy": {withPass}}); strings.Contains(f, "s3cret") || strings.Contains(f, "alice") || !strings.Contains(f, "***@") {
		t.Fatalf("提示不应显示用户名密码：%q", f)
	}
	if st.GetKV(updProxyKey) != withPass || pageProxy() != withPass {
		t.Fatal("页面设置的代理应保存到 KV")
	}
	v := h.updateView()
	if s := fmt.Sprint(v["Proxy"]); strings.Contains(s, "s3cret") || strings.Contains(s, "alice") || v["ProxySource"] != "管理页设置" {
		t.Fatalf("页面显示不对：%v %v", v["Proxy"], v["ProxySource"])
	}
	if _, err := checkServerUpdate(context.Background()); err != nil {
		t.Fatal(err)
	}
	if pageN.Load() != 2 || envN.Load() != 0 {
		t.Fatalf("页面设置应优先于环境变量：页面 %d，环境变量 %d", pageN.Load(), envN.Load())
	}
	// 格式不对：拒绝，原设置不变
	if f := post(url.Values{"proxy": {"ftp://1.2.3.4"}}); !strings.Contains(f, "只支持") || pageProxy() != withPass {
		t.Fatalf("应拒绝不支持的协议：%q", f)
	}
	// 清除后回到环境变量
	post(url.Values{"clear": {"1"}})
	if pageProxy() != "" || st.GetKV(updProxyKey) != "" {
		t.Fatal("清除后应没有页面设置")
	}
	if _, err := checkServerUpdate(context.Background()); err != nil {
		t.Fatal(err)
	}
	if envN.Load() != 2 {
		t.Fatalf("清除页面设置后应走环境变量，实际 %d", envN.Load())
	}
}

var noRedirect = &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

func TestParseAndMaskProxy(t *testing.T) {
	for _, ok := range []string{"http://127.0.0.1:7890", "https://p.example:443", "socks5://127.0.0.1:1080", "socks5h://u:p@h:1080", "HTTP://host.docker.internal:7890/"} {
		if _, err := parseUpdateProxy(ok); err != nil {
			t.Errorf("%s 应接受：%v", ok, err)
		}
	}
	for _, bad := range []string{"", "127.0.0.1:7890", "ftp://h:21", "http://", "http://h:99999", "http://h:7890/path", "http://h:7890?x=1", "socks4://h:1080", "javascript:alert(1)"} {
		if _, err := parseUpdateProxy(bad); err == nil {
			t.Errorf("%q 应拒绝", bad)
		}
	}
	for in, want := range map[string]string{
		"http://alice:s3cret@127.0.0.1:7890": "http://***@127.0.0.1:7890",
		"socks5://bob@h:1080":                "socks5://***@h:1080",
		"http://127.0.0.1:7890":              "http://127.0.0.1:7890",
	} {
		u, _ := parseUpdateProxy(in)
		if got := maskURL(u); got != want {
			t.Errorf("maskURL(%s) = %s，期望 %s", in, got, want)
		}
	}
	if got := maskRawURL("http://a:b@[::1"); strings.Contains(got, "a:b") {
		t.Errorf("解析不了的地址也不能显示密码：%s", got)
	}
	resetPageProxy(t)
	t.Setenv("HUIJIAN_SERVER_UPDATE_PROXY", "http://a:pw@h:99999")
	v := (&Hub{dataDir: t.TempDir()}).updateView()
	if strings.Contains(fmt.Sprint(v), "pw") || v["ProxyErr"] == nil {
		t.Fatalf("环境变量格式不对时应提示且不显示密码：%v", v)
	}
	if got := progressStage("0.6.2", 3250586, 14050918, 122880); got != "下载 0.6.2：3.1 / 13.4 MB · 120 KB/s" {
		t.Errorf("进度文字：%s", got)
	}
}

// rangeServer：支持 Range 的文件服务器。cutAt > 0 时第一次请求只发前 cutAt 字节后断开；noRange 时忽略 Range 回 200
type rangeServer struct {
	srv     *httptest.Server
	body    []byte
	cutAt   int
	noRange bool
	mu      sync.Mutex
	ranges  []string
	hits    int
}

func newRangeServer(t *testing.T, body []byte) *rangeServer {
	rs := &rangeServer{body: body}
	rs.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rs.mu.Lock()
		rs.hits++
		hit, cut, noRange := rs.hits, rs.cutAt, rs.noRange
		rs.ranges = append(rs.ranges, r.Header.Get("Range"))
		rs.mu.Unlock()
		var start int
		if rg := r.Header.Get("Range"); rg != "" && !noRange {
			fmt.Sscanf(rg, "bytes=%d-", &start)
			w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, len(body)-1, len(body)))
			w.Header().Set("Content-Length", fmt.Sprint(len(body)-start))
			w.WriteHeader(206)
		} else {
			w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		}
		if hit == 1 && cut > 0 {
			w.Write(body[:cut])
			w.(http.Flusher).Flush()
			panic(http.ErrAbortHandler) // 中途断开连接
		}
		w.Write(body[start:])
	}))
	t.Cleanup(rs.srv.Close)
	return rs
}

func shaHex(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

func TestDownloadResume(t *testing.T) {
	body := bytes.Repeat([]byte("huijian-0.6.2 "), 50000) // 约 700 KB
	sum := shaHex(body)
	for _, noRange := range []bool{false, true} {
		rs := newRangeServer(t, body)
		rs.cutAt, rs.noRange = 300000, noRange
		dst := filepath.Join(t.TempDir(), ".download")
		err := downloadResumable(context.Background(), rs.srv.URL+"/bin", dst, int64(len(body)), sum, nil)
		if err == nil || !strings.Contains(err.Error(), "断点") {
			t.Fatalf("第一次应在中途失败并提示可续传：%v", err)
		}
		fi, err := os.Stat(dst)
		if err != nil || fi.Size() != 300000 {
			t.Fatalf("应保留部分文件：%v %v", fi, err)
		}
		if b, _ := os.ReadFile(dst + ".json"); !strings.Contains(string(b), sum) {
			t.Fatalf("应记下部分文件对应的 sha：%s", b)
		}
		var calls int
		err = downloadResumable(context.Background(), rs.srv.URL+"/bin", dst, int64(len(body)), sum, func(done, total int64, speed float64) { calls++ })
		if err != nil {
			t.Fatalf("第二次应补完（noRange=%v）：%v", noRange, err)
		}
		if rs.ranges[1] != "bytes=300000-" {
			t.Fatalf("第二次应发 Range 请求：%q", rs.ranges)
		}
		if got, _ := os.ReadFile(dst); !bytes.Equal(got, body) {
			t.Fatal("续传后的文件不对")
		}
		if _, err := os.Stat(dst + ".json"); err != nil {
			t.Fatal("下载完成后记录应保留到安装成功（后面的步骤失败时直接用）")
		}
		if calls == 0 {
			t.Fatal("应报告进度")
		}
	}
	// 部分文件属于另一个版本（sha 不同）：不续传，从头下载
	rs := newRangeServer(t, body)
	dst := filepath.Join(t.TempDir(), ".download")
	os.WriteFile(dst, body[:1000], 0o640)
	os.WriteFile(dst+".json", []byte(`{"sha256":"`+strings.Repeat("0", 64)+`","size":1}`), 0o640)
	if err := downloadResumable(context.Background(), rs.srv.URL, dst, int64(len(body)), sum, nil); err != nil || rs.ranges[0] != "" {
		t.Fatalf("sha 不同时应从头下载：%v %q", err, rs.ranges)
	}
	// 续传后整体 sha 不对（部分文件被改过）：丢弃，报错
	rs = newRangeServer(t, body)
	rs.cutAt = 1000
	downloadResumable(context.Background(), rs.srv.URL, dst+"2", int64(len(body)), sum, nil)
	os.WriteFile(dst+"2", bytes.Repeat([]byte("x"), 1000), 0o640)
	if err := downloadResumable(context.Background(), rs.srv.URL, dst+"2", int64(len(body)), sum, nil); err == nil || !strings.Contains(err.Error(), "不一致") {
		t.Fatalf("整体校验不通过应拒绝：%v", err)
	}
	if _, err := os.Stat(dst + "2"); !os.IsNotExist(err) {
		t.Fatal("校验不通过的文件应删除")
	}
}

func TestDownloadIdleTimeout(t *testing.T) {
	old := updIdleTimeout
	updIdleTimeout = 300 * time.Millisecond
	t.Cleanup(func() { updIdleTimeout = old })
	body := bytes.Repeat([]byte("a"), 100000)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		// 慢但一直有数据：每 100ms 发一点，总时长超过空闲超时也不应失败
		for i := 0; i < 8; i++ {
			w.Write(body[i*1000 : (i+1)*1000])
			w.(http.Flusher).Flush()
			time.Sleep(100 * time.Millisecond)
		}
		if r.URL.Query().Get("stall") != "" { // 然后不再发数据
			select {
			case <-r.Context().Done():
			case <-time.After(10 * time.Second):
			}
			return
		}
		w.Write(body[8000:])
	}))
	defer srv.Close()
	dir := t.TempDir()
	start := time.Now()
	if err := downloadResumable(context.Background(), srv.URL, filepath.Join(dir, "ok"), int64(len(body)), shaHex(body), nil); err != nil {
		t.Fatalf("持续有数据时不应超时：%v", err)
	}
	err := downloadResumable(context.Background(), srv.URL+"?stall=1", filepath.Join(dir, "stall"), int64(len(body)), shaHex(body), nil)
	if err == nil || !strings.Contains(err.Error(), "没有收到数据") {
		t.Fatalf("应因空闲超时失败：%v", err)
	}
	if time.Since(start) > 5*time.Second {
		t.Fatal("空闲超时没有及时生效")
	}
	if fi, err := os.Stat(filepath.Join(dir, "stall")); err != nil || fi.Size() != 8000 {
		t.Fatalf("超时后应保留已下载的部分：%v", err)
	}
	// 连接上了但一直不回响应头：同样按空闲超时处理
	hang := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-time.After(10 * time.Second):
		}
	}))
	defer hang.Close()
	if err := downloadResumable(context.Background(), hang.URL, filepath.Join(dir, "hang"), 10, shaHex(body[:10]), nil); err == nil || !strings.Contains(err.Error(), "没有收到数据") {
		t.Fatalf("不回响应头也应超时：%v", err)
	}
}

func TestUpdateMirror(t *testing.T) {
	resetPageProxy(t)
	f := newFakeGitHub(t, "9.9.9")
	var mu sync.Mutex
	var seen []string
	mirror := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		target := strings.TrimPrefix(r.RequestURI, "/gh/")
		mu.Lock()
		seen = append(seen, target)
		mu.Unlock()
		if !strings.HasPrefix(target, f.srv.URL+"/dl/") {
			http.Error(w, "bad", 400)
			return
		}
		resp, err := http.Get(target)
		if err != nil {
			http.Error(w, err.Error(), 502)
			return
		}
		defer resp.Body.Close()
		io.Copy(w, resp.Body)
	}))
	defer mirror.Close()
	t.Setenv("HUIJIAN_SERVER_UPDATE_MIRROR", mirror.URL+"/gh/")
	u, err := checkServerUpdate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(u.binURL, mirror.URL+"/gh/"+f.srv.URL) {
		t.Fatalf("程序地址应加镜像前缀：%s", u.binURL)
	}
	h := &Hub{dataDir: t.TempDir(), restart: make(chan string, 1)}
	if _, err := h.applyUpdate(u); err != nil {
		t.Fatal(err)
	}
	if len(seen) != 2 || !strings.HasSuffix(seen[0], "/dl/"+serverManifest) {
		t.Fatalf("清单和程序应经过镜像，API 不经过：%q", seen)
	}
	// 镜像不可信：返回被改过的程序，校验失败
	f.bin = []byte("#!/bin/sh\necho 9.9.9 # evil\n")
	if _, err := (&Hub{dataDir: t.TempDir()}).applyUpdate(u); err == nil {
		t.Fatal("镜像返回的程序不对时应拒绝")
	}
}

// ---------- 手动上传、推送 ----------

type pushEnv struct {
	f    *fakeGitHub
	h    *Hub
	srv  *httptest.Server
	data string
	tok  string
	sess string
}

func newPushEnv(t *testing.T) *pushEnv {
	resetPageProxy(t)
	e := &pushEnv{f: newFakeGitHub(t, "9.9.9"), data: t.TempDir(), tok: "AT_test_token_123456"}
	st, err := OpenStore(filepath.Join(e.data, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	e.h = &Hub{st: st, dataDir: e.data, restart: make(chan string, 1), admin: &adminState{tokenHash: sha256Hex(e.tok)}}
	e.srv = httptest.NewServer(e.h.adminMux())
	t.Cleanup(e.srv.Close)
	e.sess, _ = st.CreateSession("test", time.Hour, false)
	return e
}

// manifest：用测试私钥给任意版本 / 平台签名
func (f *fakeGitHub) signed(ver string, bin []byte, platform string) []byte {
	sha := shaHex(bin)
	m := serverManifestFile{Version: ver, Build: 100, Notes: "说明", Platforms: map[string]serverManifestBinary{
		platform: {File: "huijian-" + ver + "-" + platform, Size: int64(len(bin)), Sha256: sha,
			Signature: base64.StdEncoding.EncodeToString(ed25519.Sign(f.priv, releaseMessage("server-"+platform, 100, ver, sha, "说明")))}}}
	b, _ := json.Marshal(m)
	return b
}

func multipartBody(manifest, file []byte) (io.Reader, string) {
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	if manifest != nil {
		p, _ := mw.CreateFormFile("manifest", serverManifest)
		p.Write(manifest)
	}
	if file != nil {
		p, _ := mw.CreateFormFile("file", "../../evil") // 文件名应被忽略
		p.Write(file)
	}
	mw.Close()
	return &buf, mw.FormDataContentType()
}

func (e *pushEnv) push(t *testing.T, tok string, manifest, file []byte) (int, string) {
	body, ct := multipartBody(manifest, file)
	req, _ := http.NewRequest("POST", e.srv.URL+"/api/server-update", body)
	req.Header.Set("Content-Type", ct)
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func noUploadLeft(t *testing.T, data string) {
	t.Helper()
	if m, _ := filepath.Glob(filepath.Join(binDir(data), ".upload-*")); len(m) > 0 {
		t.Fatalf("临时文件没清理：%v", m)
	}
}

func TestServerPushAPI(t *testing.T) {
	e := newPushEnv(t)
	bin := []byte("#!/bin/sh\necho 9.9.9\n")
	good := e.f.signed("9.9.9", bin, serverPlatform())

	// 没有令牌 / 令牌不对
	if code, _ := e.push(t, "", good, bin); code != 401 {
		t.Fatalf("没有令牌应 401，得到 %d", code)
	}
	if code, _ := e.push(t, "wrong", good, bin); code != 401 {
		t.Fatalf("令牌不对应 401，得到 %d", code)
	}
	// 登录会话（Cookie）不能代替令牌调用 API
	body, ct := multipartBody(good, bin)
	req, _ := http.NewRequest("POST", e.srv.URL+"/api/server-update", body)
	req.Header.Set("Content-Type", ct)
	req.AddCookie(&http.Cookie{Name: cookieName, Value: e.sess})
	if resp, _ := http.DefaultClient.Do(req); resp.StatusCode != 401 {
		t.Fatalf("API 只认令牌，得到 %d", resp.StatusCode)
	}
	// GET：对方的平台和版本
	req, _ = http.NewRequest("GET", e.srv.URL+"/api/server-update", nil)
	req.Header.Set("Authorization", "Bearer "+e.tok)
	resp, _ := http.DefaultClient.Do(req)
	var info map[string]any
	json.NewDecoder(resp.Body).Decode(&info)
	resp.Body.Close()
	if info["version"] != version || info["platform"] != serverPlatform() {
		t.Fatalf("GET 返回不对：%v", info)
	}

	// 签名不对（另一把私钥）
	_, other, _ := ed25519.GenerateKey(rand.Reader)
	bad := (&fakeGitHub{priv: other}).signed("9.9.9", bin, serverPlatform())
	if code, b := e.push(t, e.tok, bad, bin); code != 400 || !strings.Contains(b, "签名") {
		t.Fatalf("签名不对应拒绝：%d %s", code, b)
	}
	// 旧版本（签名正确）
	oldBin := []byte("#!/bin/sh\necho 0.0.1\n")
	if code, b := e.push(t, e.tok, e.f.signed("0.0.1", oldBin, serverPlatform()), oldBin); code != 400 || !strings.Contains(b, "不比当前") {
		t.Fatalf("旧版本应拒绝：%d %s", code, b)
	}
	// 平台不对：清单里没有本平台
	if code, b := e.push(t, e.tok, e.f.signed("9.9.9", bin, "linux-mips"), bin); code != 400 || !strings.Contains(b, "平台") {
		t.Fatalf("平台不对应拒绝：%d %s", code, b)
	}
	// 文件和清单不一致（例如传了别的平台的程序）
	if code, b := e.push(t, e.tok, good, []byte("#!/bin/sh\necho 9.9.9 # other\n")); code != 400 || !strings.Contains(b, "不一致") {
		t.Fatalf("文件不一致应拒绝：%d %s", code, b)
	}
	// 缺文件 / 清单不是 JSON
	if code, _ := e.push(t, e.tok, good, nil); code != 400 {
		t.Fatal("缺程序文件应拒绝")
	}
	if code, _ := e.push(t, e.tok, []byte("not json"), bin); code != 400 {
		t.Fatal("清单格式不对应拒绝")
	}
	noUploadLeft(t, e.data)
	if readStaged(e.data) != nil {
		t.Fatal("被拒绝时不应写 staged.json")
	}
	// 正在更新时再推送：409
	e.h.upd.applying = true
	if code, _ := e.push(t, e.tok, good, bin); code != 409 {
		t.Fatalf("正在更新时应 409，得到 %d", code)
	}
	e.h.upd.applying = false

	// 合法的包
	code, b := e.push(t, e.tok, good, bin)
	if code != 200 || !strings.Contains(b, `"version":"9.9.9"`) {
		t.Fatalf("合法的包应接受：%d %s", code, b)
	}
	s := readStaged(e.data)
	if s == nil || s.Version != "9.9.9" || s.Sha256 != shaHex(bin) {
		t.Fatalf("应写入 staged.json：%+v", s)
	}
	if p, err := verifyStaged(e.data, s); err != nil || p != stagedFile(e.data, "9.9.9") {
		t.Fatalf("写入的文件应能通过启动时的校验：%v", err)
	}
	select {
	case p := <-e.h.restart:
		if p != stagedFile(e.data, "9.9.9") {
			t.Fatalf("重启目标不对：%s", p)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("成功后应请求平滑重启")
	}
	noUploadLeft(t, e.data)
	// 成功后保持「正在更新」，直到进程被替换：再推送被拒
	if code, _ := e.push(t, e.tok, good, bin); code != 409 {
		t.Fatalf("重启前再次推送应 409，得到 %d", code)
	}

	// 关闭服务端更新时拒绝
	t.Setenv("HUIJIAN_SERVER_UPDATE", "0")
	e.h.upd.applying = false
	if code, _ := e.push(t, e.tok, good, bin); code != 403 {
		t.Fatalf("HUIJIAN_SERVER_UPDATE=0 时应 403，得到 %d", code)
	}
}

func TestServerPushCLI(t *testing.T) {
	e := newPushEnv(t)
	bin := []byte("#!/bin/sh\necho 9.9.9\n")
	dir := t.TempDir()
	// 清单里两个平台都有，CLI 按服务器返回的平台挑文件
	var m serverManifestFile
	json.Unmarshal(e.f.signed("9.9.9", bin, serverPlatform()), &m)
	other := []byte("other platform")
	m.Platforms["linux-mips"] = serverManifestBinary{File: "huijian-9.9.9-linux-mips", Size: int64(len(other)), Sha256: shaHex(other), Signature: "x"}
	mb, _ := json.Marshal(m)
	os.WriteFile(filepath.Join(dir, serverManifest), mb, 0o644)
	os.WriteFile(filepath.Join(dir, m.Platforms[serverPlatform()].File), bin, 0o755)
	os.WriteFile(filepath.Join(dir, "huijian-9.9.9-linux-mips"), other, 0o755)

	t.Setenv("HUIJIAN_ADMIN_URL", e.srv.URL)
	t.Setenv("HUIJIAN_ADMIN_TOKEN", "")
	if rc := runServerPush([]string{"-manifest", filepath.Join(dir, serverManifest)}); rc != 2 {
		t.Fatalf("没有令牌应退出码 2，得到 %d", rc)
	}
	t.Setenv("HUIJIAN_ADMIN_TOKEN", "wrong-token")
	if rc := runServerPush([]string{"-manifest", filepath.Join(dir, serverManifest)}); rc != 1 {
		t.Fatalf("令牌不对应失败，得到 %d", rc)
	}
	t.Setenv("HUIJIAN_ADMIN_TOKEN", e.tok)
	// 本地文件和清单不一致：不上传
	os.WriteFile(filepath.Join(dir, m.Platforms[serverPlatform()].File), []byte("broken"), 0o755)
	if rc := runServerPush([]string{"-manifest", filepath.Join(dir, serverManifest)}); rc != 1 || readStaged(e.data) != nil {
		t.Fatalf("本地文件不一致应失败，得到 %d", rc)
	}
	os.WriteFile(filepath.Join(dir, m.Platforms[serverPlatform()].File), bin, 0o755)
	if rc := runServerPush([]string{"-manifest", filepath.Join(dir, serverManifest)}); rc != 0 {
		t.Fatalf("推送应成功，得到 %d", rc)
	}
	if s := readStaged(e.data); s == nil || s.Version != "9.9.9" {
		t.Fatalf("推送后应写入 staged.json：%+v", s)
	}
	<-e.h.restart
	// 服务器已是这个版本或更新：退出码 0，不上传
	oldBin := []byte("#!/bin/sh\necho 0.0.1\n")
	os.WriteFile(filepath.Join(dir, "old.json"), e.f.signed("0.0.1", oldBin, serverPlatform()), 0o644)
	e.h.upd.applying = false
	os.Remove(stagedPath(e.data))
	if rc := runServerPush([]string{"-manifest", filepath.Join(dir, "old.json")}); rc != 0 || readStaged(e.data) != nil {
		t.Fatalf("对方更新时应直接退出 0，得到 %d", rc)
	}
	// 清单里的文件名带路径：拒绝
	var evil serverManifestFile
	json.Unmarshal(e.f.signed("9.9.10", bin, serverPlatform()), &evil)
	b := evil.Platforms[serverPlatform()]
	b.File = "../" + b.File
	evil.Platforms[serverPlatform()] = b
	eb, _ := json.Marshal(evil)
	os.WriteFile(filepath.Join(dir, "evil.json"), eb, 0o644)
	if rc := runServerPush([]string{"-manifest", filepath.Join(dir, "evil.json")}); rc != 1 {
		t.Fatalf("文件名带路径应拒绝，得到 %d", rc)
	}
}

func TestServerUpdateUploadPage(t *testing.T) {
	e := newPushEnv(t)
	bin := []byte("#!/bin/sh\necho 9.9.9\n")
	upload := func(cookie bool, manifest, file []byte) (int, string) {
		body, ct := multipartBody(manifest, file)
		req, _ := http.NewRequest("POST", e.srv.URL+"/update/upload", body)
		req.Header.Set("Content-Type", ct)
		req.Header.Set("Origin", e.srv.URL)
		if cookie {
			req.AddCookie(&http.Cookie{Name: cookieName, Value: e.sess})
		}
		resp, err := noRedirect.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		loc, _ := url.Parse(resp.Header.Get("Location"))
		if loc.Path == "/login" {
			return resp.StatusCode, "login"
		}
		return resp.StatusCode, loc.Query().Get("f")
	}
	if _, f := upload(false, e.f.signed("9.9.9", bin, serverPlatform()), bin); f != "login" {
		t.Fatalf("没登录应跳到登录页：%q", f)
	}
	// 管理令牌也不能用来调用页面接口之外的东西：这里只验证页面接口要会话
	_, other, _ := ed25519.GenerateKey(rand.Reader)
	if _, f := upload(true, (&fakeGitHub{priv: other}).signed("9.9.9", bin, serverPlatform()), bin); !strings.Contains(f, "签名") {
		t.Fatalf("签名不对应拒绝：%q", f)
	}
	oldBin := []byte("#!/bin/sh\necho 0.0.1\n")
	if _, f := upload(true, e.f.signed("0.0.1", oldBin, serverPlatform()), oldBin); !strings.Contains(f, "不比当前") {
		t.Fatalf("旧版本应拒绝：%q", f)
	}
	if _, f := upload(true, e.f.signed("9.9.9", bin, "linux-mips"), bin); !strings.Contains(f, "平台") {
		t.Fatalf("平台不对应拒绝：%q", f)
	}
	noUploadLeft(t, e.data)
	if e.h.upd.applying || readStaged(e.data) != nil {
		t.Fatal("被拒绝后应解除占用、不写 staged")
	}
	// 跨站提交被拒
	body, ct := multipartBody(e.f.signed("9.9.9", bin, serverPlatform()), bin)
	req, _ := http.NewRequest("POST", e.srv.URL+"/update/upload", body)
	req.Header.Set("Content-Type", ct)
	req.Header.Set("Origin", "http://evil.example")
	req.AddCookie(&http.Cookie{Name: cookieName, Value: e.sess})
	if resp, _ := noRedirect.Do(req); resp.StatusCode != 403 {
		t.Fatalf("跨站提交应 403，得到 %d", resp.StatusCode)
	}
	// 合法：后台安装，完成后请求重启
	if _, f := upload(true, e.f.signed("9.9.9", bin, serverPlatform()), bin); !strings.Contains(f, "正在安装") {
		t.Fatalf("合法的包应接受：%q", f)
	}
	select {
	case <-e.h.restart:
	case <-time.After(5 * time.Second):
		t.Fatalf("安装没完成：%s", e.h.upd.applyErr)
	}
	if s := readStaged(e.data); s == nil || s.Version != "9.9.9" {
		t.Fatalf("应写入 staged.json：%+v", s)
	}
	noUploadLeft(t, e.data)
	// 安装完成、等待重启期间再上传：拒绝
	if _, f := upload(true, e.f.signed("9.9.9", bin, serverPlatform()), bin); !strings.Contains(f, "正在更新") {
		t.Fatalf("正在更新时应拒绝：%q", f)
	}
}

// 并发：同时发起多次推送，只有一个能进入安装
func TestServerPushConcurrent(t *testing.T) {
	e := newPushEnv(t)
	bin := []byte("#!/bin/sh\necho 9.9.9\n")
	good := e.f.signed("9.9.9", bin, serverPlatform())
	var wg sync.WaitGroup
	codes := make([]int, 5)
	for i := range codes {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			codes[i], _ = e.push(t, e.tok, good, bin)
		}(i)
	}
	wg.Wait()
	ok := 0
	for _, c := range codes {
		switch c {
		case 200:
			ok++
		case 409:
		default:
			t.Fatalf("意外的状态码：%v", codes)
		}
	}
	if ok != 1 {
		t.Fatalf("应只有一个成功：%v", codes)
	}
	noUploadLeft(t, e.data)
}

// 设置页：更新进行中显示进度并轮询；说明用 .notes；代理密码不出现在页面里
func TestSettingsUpdateCardRender(t *testing.T) {
	resetPageProxy(t)
	setPageProxy("http://alice:s3cret@127.0.0.1:7890")
	t.Setenv("HUIJIAN_SERVER_UPDATE_MIRROR", "https://u:mirrorpw@ghproxy.example/")
	h := &Hub{dataDir: t.TempDir()}
	h.upd.applying, h.upd.stage = true, progressStage("9.9.9", 3250586, 14050918, 122880)
	h.upd.latest = &serverUpdate{Version: "9.9.9", Notes: "第一行\n第二行", Newer: true, Page: "https://example.com"}
	var b strings.Builder
	err := tpl.ExecuteTemplate(&b, "settings", map[string]any{"Nav": "settings", "Title": "设置", "Version": version,
		"Storage": storageInfo{}, "Update": h.updateView()})
	if err != nil {
		t.Fatal(err)
	}
	out := b.String()
	for _, want := range []string{`data-upd-poll="` + version + `"`, "下载 9.9.9：3.1 / 13.4 MB · 120 KB/s", `<pre class="notes">第一行` + "\n第二行</pre>",
		"http://***@127.0.0.1:7890", "https://***@ghproxy.example/", `action="/update/upload"`, `enctype="multipart/form-data"`, `name="clear"`, "含密码时会保存在数据库和备份里"} {
		if !strings.Contains(out, want) {
			t.Errorf("页面缺少 %q", want)
		}
	}
	for _, bad := range []string{"s3cret", "mirrorpw", `class="code"`} {
		if strings.Contains(out, bad) {
			t.Errorf("页面不应出现 %q", bad)
		}
	}
}

// 推送的程序签名正确、但在这台机器上跑不起来：500，释放占用、记下错误，不留临时文件、不写 staged
func TestServerPushInstallFails(t *testing.T) {
	e := newPushEnv(t)
	bin := []byte("#!/bin/sh\necho 1.0.0-wrong\n")
	code, b := e.push(t, e.tok, e.f.signed("9.9.9", bin, serverPlatform()), bin)
	if code != 500 || !strings.Contains(b, "无法在这台服务器上运行") {
		t.Fatalf("试运行失败应 500：%d %s", code, b)
	}
	e.h.upd.mu.Lock()
	applying, applyErr := e.h.upd.applying, e.h.upd.applyErr
	e.h.upd.mu.Unlock()
	if applying || !strings.Contains(applyErr, "无法在这台服务器上运行") {
		t.Fatalf("应释放占用并记下错误：%v %q", applying, applyErr)
	}
	noUploadLeft(t, e.data)
	if readStaged(e.data) != nil {
		t.Fatal("安装失败不应写 staged")
	}
	if _, err := os.Stat(stagedFile(e.data, "9.9.9")); !os.IsNotExist(err) {
		t.Fatal("安装失败不应留下程序文件")
	}
	// 之后可以再推送正确的包
	good := []byte("#!/bin/sh\necho 9.9.9\n")
	if code, b := e.push(t, e.tok, e.f.signed("9.9.9", good, serverPlatform()), good); code != 200 {
		t.Fatalf("失败后应能再次推送：%d %s", code, b)
	}
}

// 系统代理（HTTPS_PROXY）格式不对：固定文案 + 遮住密码，不把原文（含密码）带出去，也不悄悄直连
func TestSystemProxyErrorMasked(t *testing.T) {
	resetPageProxy(t)
	t.Setenv("HUIJIAN_SERVER_UPDATE_PROXY", "")
	t.Setenv("https_proxy", "")
	t.Setenv("HTTPS_PROXY", "http://bob:S3cretPw@[bad")
	p := currentUpdateProxy()
	if p.Source != "system" || p.Err == nil || !strings.Contains(p.Err.Error(), "系统代理 HTTPS_PROXY 格式不对") {
		t.Fatalf("应报系统代理格式不对：%+v", p)
	}
	req, _ := http.NewRequest("GET", "https://api.github.com/x", nil)
	_, err := updProxyFunc(req)
	v := (&Hub{dataDir: t.TempDir()}).updateView()
	for _, s := range []string{p.Err.Error(), fmt.Sprint(err), fmt.Sprint(v), proxyHint()} {
		if strings.Contains(s, "S3cretPw") || strings.Contains(s, "bob") {
			t.Fatalf("不应带出密码：%s", s)
		}
	}
	if err == nil || !strings.Contains(err.Error(), "格式不对") {
		t.Fatalf("请求应失败而不是直连：%v", err)
	}
	// 标准库返回错误（错误文字里带原文）时也只给固定文案
	t.Setenv("HTTPS_PROXY", "http://bob:S3cretPw@127.0.0.1:7890")
	old := sysProxyFunc
	sysProxyFunc = func(*http.Request) (*url.URL, error) {
		return nil, fmt.Errorf("invalid proxy address %q", "http://bob:S3cretPw@127.0.0.1:7890")
	}
	t.Cleanup(func() { sysProxyFunc = old })
	_, err = updProxyFunc(req)
	p = currentUpdateProxy()
	if err == nil || strings.Contains(err.Error(), "S3cretPw") || p.Err == nil || strings.Contains(p.Err.Error()+p.Masked, "S3cretPw") ||
		!strings.Contains(err.Error(), "http://***@127.0.0.1:7890") {
		t.Fatalf("应包装标准库的错误：%v / %+v", err, p)
	}
	// 标准库能接受的宽松写法（没写 http://）不算错
	sysProxyFunc = old
	t.Setenv("HTTPS_PROXY", "127.0.0.1:7890")
	if sysProxyBad("https") != nil {
		t.Fatal("127.0.0.1:7890 标准库会当成 http://，不应报错")
	}
}

// 下载完成后因为和文件无关的原因失败（这里用版本检查模拟备份失败、试运行超时）：保留文件和记录，下次不重新下载
func TestDownloadKeptAfterInstallFailure(t *testing.T) {
	resetPageProxy(t)
	f := newFakeGitHub(t, "9.9.9")
	u, err := checkServerUpdate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	data := t.TempDir()
	h := &Hub{dataDir: data, restart: make(chan string, 1)}
	dl := filepath.Join(binDir(data), ".download")
	old := version
	version = "10.0.0" // 让安装在文件校验之后的步骤失败
	_, err = h.applyUpdate(u)
	version = old
	if err == nil || f.binHits.Load() != 1 {
		t.Fatalf("应下载一次后在安装时失败：%v %d", err, f.binHits.Load())
	}
	if _, err := os.Lstat(dl); err != nil {
		t.Fatal("和文件无关的失败应保留下载的文件")
	}
	if _, err := os.Stat(dl + ".json"); err != nil {
		t.Fatal("应保留下载记录")
	}
	path, err := h.applyUpdate(u)
	if err != nil {
		t.Fatal(err)
	}
	if f.binHits.Load() != 1 {
		t.Fatalf("已下完的文件应直接用，不再下载：共下载 %d 次", f.binHits.Load())
	}
	if path != stagedFile(data, "9.9.9") {
		t.Fatalf("路径不对：%s", path)
	}
	for _, p := range []string{dl, dl + ".json"} {
		if _, err := os.Lstat(p); !os.IsNotExist(err) {
			t.Fatalf("安装成功后应清理 %s", p)
		}
	}
	// 文件本身和清单不一致：丢弃
	os.WriteFile(dl, []byte("#!/bin/sh\necho 9.9.9 # evil\n"), 0o750)
	b, _ := json.Marshal(downloadMeta{Sha256: u.manifest.Platforms[serverPlatform()].Sha256, Size: int64(len("#!/bin/sh\necho 9.9.9 # evil\n"))})
	os.WriteFile(dl+".json", b, 0o640)
	if _, err := h.installVerified(u.manifest, dl, true); err == nil {
		t.Fatal("文件不一致应拒绝")
	}
	for _, p := range []string{dl, dl + ".json"} {
		if _, err := os.Lstat(p); !os.IsNotExist(err) {
			t.Fatalf("文件不一致时应丢弃 %s", p)
		}
	}
}

// 已下完的分支：记录和文件都在、sha 正确时不发请求；sha 不对时重新下载
func TestDownloadCompleteReuse(t *testing.T) {
	body := bytes.Repeat([]byte("x"), 5000)
	rs := newRangeServer(t, body)
	dst := filepath.Join(t.TempDir(), ".download")
	if err := downloadResumable(context.Background(), rs.srv.URL, dst, int64(len(body)), shaHex(body), nil); err != nil {
		t.Fatal(err)
	}
	if err := downloadResumable(context.Background(), rs.srv.URL, dst, int64(len(body)), shaHex(body), nil); err != nil || rs.hits != 1 {
		t.Fatalf("已下完应直接用：%v，请求 %d 次", err, rs.hits)
	}
	os.WriteFile(dst, bytes.Repeat([]byte("y"), 5000), 0o750) // 大小对、内容被改
	if err := downloadResumable(context.Background(), rs.srv.URL, dst, int64(len(body)), shaHex(body), nil); err != nil || rs.hits != 2 || rs.ranges[1] != "" {
		t.Fatalf("内容不对应从头重新下载：%v，请求 %d 次 %q", err, rs.hits, rs.ranges)
	}
	if got, _ := os.ReadFile(dst); !bytes.Equal(got, body) {
		t.Fatal("重新下载的内容不对")
	}
}

// 部分文件是符号链接：不跟随（不改动链接指向的文件），删掉后从头下载
func TestDownloadSymlinkDiscarded(t *testing.T) {
	body := bytes.Repeat([]byte("z"), 5000)
	dir := t.TempDir()
	target := filepath.Join(dir, "victim")
	os.WriteFile(target, body[:1000], 0o640)
	dst := filepath.Join(dir, ".download")
	if err := os.Symlink(target, dst); err != nil {
		t.Skip(err)
	}
	b, _ := json.Marshal(downloadMeta{Sha256: shaHex(body), Size: int64(len(body))})
	os.WriteFile(dst+".json", b, 0o640)
	rs := newRangeServer(t, body)
	if err := downloadResumable(context.Background(), rs.srv.URL, dst, int64(len(body)), shaHex(body), nil); err != nil {
		t.Fatal(err)
	}
	if rs.ranges[0] != "" {
		t.Fatalf("符号链接不应续传：%q", rs.ranges)
	}
	if fi, err := os.Lstat(dst); err != nil || !fi.Mode().IsRegular() {
		t.Fatal("应换成普通文件")
	}
	if got, _ := os.ReadFile(target); !bytes.Equal(got, body[:1000]) {
		t.Fatal("不应改动符号链接指向的文件")
	}
	// 已下完的文件被换成指向完整内容的符号链接：同样不用
	full := filepath.Join(dir, "full")
	os.WriteFile(full, body, 0o640)
	os.Remove(dst)
	os.Symlink(full, dst)
	os.WriteFile(dst+".json", b, 0o640)
	if err := downloadResumable(context.Background(), rs.srv.URL, dst, int64(len(body)), shaHex(body), nil); err != nil || rs.hits != 2 {
		t.Fatalf("符号链接不应当成已下完的文件：%v %d", err, rs.hits)
	}
	if fi, _ := os.Lstat(dst); !fi.Mode().IsRegular() {
		t.Fatal("应换成普通文件")
	}
}

// 磁盘写满：下载丢弃部分文件；上传提示「写入失败或磁盘空间不足」
func TestDiskFull(t *testing.T) {
	old := writeChunk
	var written atomic.Int64
	writeChunk = func(f *os.File, b []byte) (int, error) {
		if written.Add(int64(len(b))) > 2000 {
			return 0, &os.PathError{Op: "write", Path: f.Name(), Err: syscall.ENOSPC}
		}
		return f.Write(b)
	}
	t.Cleanup(func() { writeChunk = old })
	body := bytes.Repeat([]byte("d"), 200000)
	rs := newRangeServer(t, body)
	dst := filepath.Join(t.TempDir(), ".download")
	err := downloadResumable(context.Background(), rs.srv.URL, dst, int64(len(body)), shaHex(body), nil)
	if err == nil || !strings.Contains(err.Error(), "磁盘空间不足") {
		t.Fatalf("应报磁盘空间不足：%v", err)
	}
	for _, p := range []string{dst, dst + ".json"} {
		if _, err := os.Lstat(p); !os.IsNotExist(err) {
			t.Fatalf("磁盘满时应删除 %s", p)
		}
	}

	written.Store(0)
	e := newPushEnv(t)
	bin := []byte("#!/bin/sh\necho 9.9.9\n" + strings.Repeat("#", 5000))
	code, b := e.push(t, e.tok, e.f.signed("9.9.9", bin, serverPlatform()), bin)
	if code != 400 || !strings.Contains(b, "写入失败或磁盘空间不足") {
		t.Fatalf("上传写盘失败应提示：%d %s", code, b)
	}
	noUploadLeft(t, e.data)
	if e.h.upd.applying {
		t.Fatal("失败后应释放占用")
	}
}

// 代理出口被 GitHub API 限流时改用直连查版本，程序下载仍走代理；令牌只发给 API
func TestGitHubAPIRateLimitFallback(t *testing.T) {
	resetPageProxy(t)
	newFakeGitHub(t, "9.9.9")
	t.Setenv("HUIJIAN_SERVER_UPDATE_GITHUB_TOKEN", "ghp_test_only")
	old := ghTokenHost
	ghTokenHost = "127.0.0.1" // 假 GitHub 的 API 和下载都在 127.0.0.1
	t.Cleanup(func() { ghTokenHost = old })
	var apiViaProxy, otherViaProxy, leaked atomic.Int32
	direct := &http.Transport{}
	px := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "/repos/") {
			apiViaProxy.Add(1)
			w.Header().Set("X-RateLimit-Remaining", "0")
			http.Error(w, `{"message":"API rate limit exceeded"}`, http.StatusForbidden)
			return
		}
		otherViaProxy.Add(1)
		if r.Header.Get("Authorization") != "" {
			leaked.Add(1)
		}
		req, _ := http.NewRequest(r.Method, r.URL.String(), nil)
		req.Header = r.Header.Clone()
		resp, err := direct.RoundTrip(req)
		if err != nil {
			http.Error(w, err.Error(), 502)
			return
		}
		defer resp.Body.Close()
		for k, v := range resp.Header {
			w.Header()[k] = v
		}
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	}))
	t.Cleanup(px.Close)
	t.Setenv("HUIJIAN_SERVER_UPDATE_PROXY", px.URL)
	u, err := checkServerUpdate(context.Background())
	if err != nil {
		t.Fatalf("经代理被限流时应改用直连：%v", err)
	}
	if apiViaProxy.Load() != 1 || otherViaProxy.Load() != 1 {
		t.Fatalf("API 应先经代理一次再直连，清单仍走代理：api=%d other=%d", apiViaProxy.Load(), otherViaProxy.Load())
	}
	h := &Hub{dataDir: t.TempDir(), restart: make(chan string, 1)}
	if _, err := h.applyUpdate(u); err != nil {
		t.Fatal(err)
	}
	if otherViaProxy.Load() != 2 {
		t.Fatalf("程序下载应走代理：%d", otherViaProxy.Load())
	}
	if leaked.Load() != 0 {
		t.Fatal("GitHub 令牌不应发给清单和程序下载地址")
	}
}

// 令牌只发给官方 API 主机：API 换成镜像时不带令牌
func TestGitHubTokenOnlyToOfficialAPI(t *testing.T) {
	resetPageProxy(t)
	f := newFakeGitHub(t, "9.9.9")
	t.Setenv("HUIJIAN_SERVER_UPDATE_GITHUB_TOKEN", "ghp_test_only")
	var sawAuth atomic.Int32
	inner := f.srv.Config.Handler
	f.srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" {
			sawAuth.Add(1)
		}
		inner.ServeHTTP(w, r)
	})
	if _, err := checkServerUpdate(context.Background()); err != nil { // ghTokenHost 仍是 api.github.com
		t.Fatal(err)
	}
	if sawAuth.Load() != 0 {
		t.Fatal("API 地址不是 api.github.com 时不应带令牌")
	}
	old := ghTokenHost
	ghTokenHost = "127.0.0.1"
	t.Cleanup(func() { ghTokenHost = old })
	if _, err := checkServerUpdate(context.Background()); err != nil {
		t.Fatal(err)
	}
	if sawAuth.Load() != 1 { // 只有 API 列表那一次带令牌，清单下载不带
		t.Fatalf("官方 API 请求应带令牌且只带一次：%d", sawAuth.Load())
	}
}
