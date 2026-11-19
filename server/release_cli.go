package main

// 发布端命令：生成签名密钥、签名并上传客户端更新包。在开发机上运行，私钥不离开开发机。
//
//	huijian release-key  <私钥文件>                   生成 Ed25519 私钥（0600），打印公钥
//	huijian release-pubkey <私钥文件>                 打印公钥（写进客户端构建配置）
//	huijian release -key <私钥文件> -version 0.4.0 -build 37 [-platform macos] [-notes 说明] 包.zip
//	        上传到 $HUIJIAN_ADMIN_URL/api/releases，管理令牌读 $HUIJIAN_ADMIN_TOKEN
//	huijian server-push -manifest update-server.json [-dir 目录]
//	        把签名的服务端程序推送到 $HUIJIAN_ADMIN_URL/api/server-update（server/release_github.sh 发布后自动调用）

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func loadReleaseKey(path string) (ed25519.PrivateKey, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(b)))
	if err != nil || len(seed) != ed25519.SeedSize {
		return nil, errors.New("私钥文件格式不对（应为 base64 编码的 32 字节种子）")
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

func pubB64(k ed25519.PrivateKey) string {
	return base64.StdEncoding.EncodeToString(k.Public().(ed25519.PublicKey))
}

func runReleaseKey(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "用法: huijian release-key <私钥文件>")
		return 2
	}
	seed := make([]byte, ed25519.SeedSize)
	if _, err := rand.Read(seed); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if err := os.MkdirAll(filepath.Dir(args[0]), 0o700); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	f, err := os.OpenFile(args[0], os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		fmt.Fprintln(os.Stderr, "创建私钥文件失败（已存在时不会覆盖）:", err)
		return 1
	}
	fmt.Fprintln(f, base64.StdEncoding.EncodeToString(seed))
	f.Close()
	fmt.Println(pubB64(ed25519.NewKeyFromSeed(seed)))
	return 0
}

func runReleasePubkey(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "用法: huijian release-pubkey <私钥文件>")
		return 2
	}
	k, err := loadReleaseKey(args[0])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Println(pubB64(k))
	return 0
}

func runRelease(args []string) int {
	fs := flag.NewFlagSet("release", flag.ContinueOnError)
	keyFile := fs.String("key", "", "Ed25519 私钥文件")
	platform := fs.String("platform", "macos", "平台")
	ver := fs.String("version", "", "版本号，例如 0.4.0")
	build := fs.Int64("build", 0, "构建号（必须递增）")
	notes := fs.String("notes", "", "更新说明")
	admin := fs.String("admin", env("HUIJIAN_ADMIN_URL", ""), "管理后台地址（默认 $HUIJIAN_ADMIN_URL）")
	dry := fs.Bool("dry", false, "只计算并打印签名，不上传")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 || *keyFile == "" || *ver == "" || *build <= 0 {
		fmt.Fprintln(os.Stderr, "用法: huijian release -key <私钥> -version <版本> -build <构建号> [-platform macos] [-notes 说明] [-dry] <包.zip>")
		return 2
	}
	*notes = strings.TrimSpace(*notes)
	key, err := loadReleaseKey(*keyFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, "读取私钥:", err)
		return 1
	}
	pkg := fs.Arg(0)
	f, err := os.Open(pkg)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer f.Close()
	hs := sha256.New()
	if _, err := io.Copy(hs, f); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	sum := hex.EncodeToString(hs.Sum(nil))
	sig := base64.StdEncoding.EncodeToString(ed25519.Sign(key, releaseMessage(*platform, *build, *ver, sum, *notes)))
	fmt.Printf("%s %s (build %d)\nsha256    %s\nsignature %s\n", *platform, *ver, *build, sum, sig)
	if *dry {
		return 0
	}
	tok := env("HUIJIAN_ADMIN_TOKEN", "")
	if *admin == "" || tok == "" {
		fmt.Fprintln(os.Stderr, "需要 HUIJIAN_ADMIN_URL 和 HUIJIAN_ADMIN_TOKEN 才能上传")
		return 2
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	pr, pw := io.Pipe()
	mw := multipart.NewWriter(pw)
	go func() {
		for _, kv := range [][2]string{{"platform", *platform}, {"version", *ver}, {"build", strconv.FormatInt(*build, 10)},
			{"notes", *notes}, {"sha256", sum}, {"signature", sig}} {
			mw.WriteField(kv[0], kv[1])
		}
		part, err := mw.CreateFormFile("file", filepath.Base(pkg))
		if err == nil {
			_, err = io.Copy(part, f)
		}
		if err == nil {
			err = mw.Close()
		}
		pw.CloseWithError(err)
	}()
	req, _ := http.NewRequest("POST", strings.TrimRight(*admin, "/")+"/api/releases", pr)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := (&http.Client{Timeout: 10 * time.Minute}).Do(req)
	if err != nil {
		fmt.Fprintln(os.Stderr, "上传失败:", err)
		return 1
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if resp.StatusCode != 200 {
		var e struct{ Error string }
		json.Unmarshal(body, &e)
		if e.Error == "" {
			e.Error = string(bytes.TrimSpace(body))
		}
		fmt.Fprintf(os.Stderr, "上传失败（HTTP %d）：%s\n", resp.StatusCode, e.Error)
		return 1
	}
	fmt.Println("已发布：", string(bytes.TrimSpace(body)))
	return 0
}

// runServerPush：先 GET 对方的平台和版本，再从清单里取对应平台的程序上传。
// 签名由服务器用内置公钥校验，这里只做本地的 sha256 / 大小自查，避免传错文件白等。令牌不会被打印。
func runServerPush(args []string) int {
	fs := flag.NewFlagSet("server-push", flag.ContinueOnError)
	manifest := fs.String("manifest", "", "update-server.json（server/release_github.sh 生成在 server/bin/release/）")
	dir := fs.String("dir", "", "程序文件所在目录（默认和清单同一目录）")
	admin := fs.String("admin", env("HUIJIAN_ADMIN_URL", ""), "管理后台地址（默认 $HUIJIAN_ADMIN_URL）")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *manifest == "" || fs.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "用法: huijian server-push -manifest update-server.json [-dir 目录]（读 HUIJIAN_ADMIN_URL、HUIJIAN_ADMIN_TOKEN）")
		return 2
	}
	tok := strings.TrimSpace(env("HUIJIAN_ADMIN_TOKEN", ""))
	if *admin == "" || tok == "" {
		fmt.Fprintln(os.Stderr, "需要 HUIJIAN_ADMIN_URL 和 HUIJIAN_ADMIN_TOKEN 才能推送")
		return 2
	}
	if *dir == "" {
		*dir = filepath.Dir(*manifest)
	}
	raw, err := os.ReadFile(*manifest)
	if err != nil {
		fmt.Fprintln(os.Stderr, "读取清单:", err)
		return 1
	}
	var m serverManifestFile
	if len(raw) > maxManifestSize || json.Unmarshal(raw, &m) != nil || !reVersion.MatchString(m.Version) {
		fmt.Fprintln(os.Stderr, "清单格式不对:", *manifest)
		return 1
	}
	base := strings.TrimRight(*admin, "/") + "/api/server-update"

	// 1. 对方的平台和版本
	req, _ := http.NewRequest("GET", base, nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	var info struct {
		Version  string `json:"version"`
		Platform string `json:"platform"`
		Enabled  *bool  `json:"enabled"`
		Applying bool   `json:"applying"`
		Error    string `json:"error"`
	}
	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		fmt.Fprintln(os.Stderr, "连不上服务器:", err)
		return 1
	}
	json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&info)
	resp.Body.Close()
	switch {
	case resp.StatusCode == 404:
		fmt.Fprintln(os.Stderr, "服务器不支持推送（0.6.2 起才有），请先用管理后台一键更新或手动上传")
		return 1
	case resp.StatusCode != 200:
		fmt.Fprintf(os.Stderr, "查询服务器版本失败（HTTP %d）：%s\n", resp.StatusCode, info.Error)
		return 1
	case info.Enabled != nil && !*info.Enabled:
		fmt.Fprintln(os.Stderr, "服务器关闭了服务端更新（HUIJIAN_SERVER_UPDATE=0），没有推送")
		return 1
	case !versionLess(info.Version, m.Version):
		fmt.Printf("服务器已是 v%s（%s），不低于 v%s，无需推送\n", info.Version, info.Platform, m.Version)
		return 0
	case info.Applying:
		fmt.Fprintln(os.Stderr, "服务器正在更新，稍后再试")
		return 1
	}

	// 2. 本地自查对应平台的文件
	b, ok := m.Platforms[info.Platform]
	if !ok {
		fmt.Fprintf(os.Stderr, "清单里没有服务器平台 %s 的程序\n", info.Platform)
		return 1
	}
	if b.File == "" || b.File != filepath.Base(b.File) || b.File == "." || b.File == ".." {
		fmt.Fprintf(os.Stderr, "清单里的文件名不合法：%q\n", b.File)
		return 1
	}
	path := filepath.Join(*dir, b.File)
	f, err := os.Open(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer f.Close()
	hs := sha256.New()
	n, err := io.Copy(hs, f)
	if err != nil || n != b.Size || hex.EncodeToString(hs.Sum(nil)) != b.Sha256 {
		fmt.Fprintf(os.Stderr, "%s 和清单不一致（大小或 sha256 不符）\n", path)
		return 1
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}

	// 3. 上传：清单在前，程序在后
	fmt.Printf("推送 v%s（%s，%s）到服务器，当前 v%s…\n", m.Version, info.Platform, humanBytes(b.Size), info.Version)
	pr, pw := io.Pipe()
	mw := multipart.NewWriter(pw)
	go func() {
		part, err := mw.CreateFormFile("manifest", serverManifest)
		if err == nil {
			_, err = part.Write(raw)
		}
		if err == nil {
			part, err = mw.CreateFormFile("file", b.File)
		}
		if err == nil {
			_, err = io.Copy(part, f)
		}
		if err == nil {
			err = mw.Close()
		}
		pw.CloseWithError(err)
	}()
	req, _ = http.NewRequest("POST", base, pr)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err = (&http.Client{Timeout: 30 * time.Minute}).Do(req) // 服务器要试运行、备份数据库，可能要一会儿
	if err != nil {
		fmt.Fprintln(os.Stderr, "推送失败:", err)
		return 1
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if resp.StatusCode != 200 {
		var e struct{ Error string }
		json.Unmarshal(body, &e)
		if e.Error == "" {
			e.Error = string(bytes.TrimSpace(body))
		}
		fmt.Fprintf(os.Stderr, "推送失败（HTTP %d）：%s\n", resp.StatusCode, e.Error)
		return 1
	}
	fmt.Printf("已推送：服务器 v%s → v%s，正在平滑重启（约半分钟）\n", info.Version, m.Version)
	return 0
}
