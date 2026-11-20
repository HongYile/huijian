package main

// huijian register：在命令行里注册账号（0.9.0）。和回笺客户端注册一样：在本机生成账号钥匙、用密码锁住，
// 只把公钥、锁住的私钥和登录凭证发给服务器（服务器拿不到密码和私钥），注册成功即登录，这台机器成为账号的第一台设备。
// 用于没有图形界面的机器、自动化测试（三端测试脚本建号）。
//
//	echo 密码 | huijian register -u https://push.example.com -invite ABCD234567 -token-out token.txt 张三
//
// 密码从标准输入读第一行，或在终端里输入两次（不显示），不出现在命令行参数里。
// 设备 token 写到 -token-out 指定的文件（0600）；-key-out 可选，把账号私钥（base64url）写到文件，给测试脚本解密用——
// 私钥等于能看全部消息，正常使用不要导出。不往标准输出打印 token 和私钥。

import (
	"bufio"
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

// readPassword：标准输入不是终端时读第一行；是终端时提示输入两次（尽量不回显）
func readPassword() (string, error) {
	if fi, err := os.Stdin.Stat(); err == nil && fi.Mode()&os.ModeCharDevice == 0 {
		line, err := bufio.NewReader(os.Stdin).ReadString('\n')
		if err != nil && line == "" {
			return "", errors.New("没有从标准输入读到密码")
		}
		return strings.TrimRight(line, "\r\n"), nil
	}
	echo := func(on bool) {
		arg := "-echo"
		if on {
			arg = "echo"
		}
		c := exec.Command("stty", arg)
		c.Stdin = os.Stdin
		c.Run()
	}
	rd := bufio.NewReader(os.Stdin)
	ask := func(prompt string) string {
		fmt.Fprint(os.Stderr, prompt)
		echo(false)
		line, _ := rd.ReadString('\n')
		echo(true)
		fmt.Fprintln(os.Stderr)
		return strings.TrimRight(line, "\r\n")
	}
	p1 := ask("密码（至少 8 位，不显示）：")
	if p2 := ask("再输入一次："); p1 != p2 {
		return "", errors.New("两次输入的密码不一样")
	}
	return p1, nil
}

// withScheme：没写协议时按 http://（和客户端填「IP:端口」一样）
func withScheme(u string) string {
	if strings.Contains(u, "://") {
		return u
	}
	return "http://" + u
}

// registerBody：注册请求体（和客户端一致）。返回请求体和账号私钥
func registerBody(username, password, invite, name, platform, fingerprint string) (map[string]any, *ecdh.PrivateKey, error) {
	sk, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	salt := make([]byte, 16)
	rand.Read(salt)
	auth, unlock := e2ePasswordKeys(password, salt)
	wrap, err := e2eWrap("hjp1", unlock, sk.Bytes())
	if err != nil {
		return nil, nil, err
	}
	return map[string]any{"username": username, "invite_code": invite, "name": name, "platform": platform, "fingerprint": fingerprint,
		"auth_salt": hex.EncodeToString(salt), "auth_key": b64.EncodeToString(auth),
		"pub": b64.EncodeToString(sk.PublicKey().Bytes()), "password_wrap": wrap}, sk, nil
}

func runRegisterCLI(args []string) int {
	fs := flag.NewFlagSet("register", flag.ContinueOnError)
	url := fs.String("u", strings.Split(defaultURLs(), ",")[0], "服务器地址，例如 https://push.example.com")
	invite := fs.String("invite", "", "邀请码（服务器注册模式为 invite 时必填）")
	name := fs.String("name", "", "设备名（默认本机主机名）")
	platform := fs.String("platform", "cli", "设备平台")
	tokenOut := fs.String("token-out", "", "设备 token 写到这个文件（必填，权限 0600）")
	keyOut := fs.String("key-out", "", "可选：账号私钥写到这个文件（测试用，权限 0600）")
	use := func() int {
		fmt.Fprintln(os.Stderr, "用法: huijian register -u 服务器地址 [-invite 邀请码] -token-out 文件 [-key-out 文件] [-name 设备名] <用户名>\n      密码从标准输入读，或在终端里输入")
		return 2
	}
	if fs.Parse(args) != nil || fs.NArg() != 1 || *tokenOut == "" {
		return use()
	}
	if *url == "" {
		fmt.Fprintln(os.Stderr, "缺少服务器地址：用 -u 或环境变量 HUIJIAN_URL")
		return 2
	}
	if *name == "" {
		*name, _ = os.Hostname()
	}
	pw, err := readPassword()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if len([]rune(pw)) < 8 {
		fmt.Fprintln(os.Stderr, "密码至少 8 位")
		return 1
	}
	fp := make([]byte, 16)
	rand.Read(fp)
	body, sk, err := registerBody(fs.Arg(0), pw, *invite, *name, *platform, hex.EncodeToString(fp))
	if err != nil {
		fmt.Fprintln(os.Stderr, "生成钥匙失败：", err)
		return 1
	}
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest("POST", strings.TrimRight(withScheme(*url), "/")+"/v1/register", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Huijian-Client", "cli "+version)
	resp, err := (&http.Client{Timeout: 60 * time.Second}).Do(req)
	if err != nil {
		fmt.Fprintln(os.Stderr, "连不上服务器：", err)
		return 1
	}
	defer resp.Body.Close()
	rb, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	var out struct {
		DeviceID string `json:"device_id"`
		Token    string `json:"token"`
		Error    string `json:"error"`
	}
	json.Unmarshal(rb, &out)
	if resp.StatusCode != 200 || out.Token == "" {
		msg := out.Error
		if msg == "" {
			msg = strings.TrimSpace(string(rb))
		}
		fmt.Fprintf(os.Stderr, "注册失败（HTTP %d）：%s\n", resp.StatusCode, msg)
		return 1
	}
	if err := os.WriteFile(*tokenOut, []byte(out.Token+"\n"), 0o600); err != nil {
		fmt.Fprintln(os.Stderr, "已注册，但写入 token 文件失败：", err)
		return 1
	}
	if *keyOut != "" {
		if err := os.WriteFile(*keyOut, []byte(b64.EncodeToString(sk.Bytes())+"\n"), 0o600); err != nil {
			fmt.Fprintln(os.Stderr, "写入私钥文件失败：", err)
			return 1
		}
	}
	fmt.Printf("已注册账号「%s」，已开启端到端加密；本机是它的第一台设备（%s），设备 token 已写入 %s\n", fs.Arg(0), out.DeviceID, *tokenOut)
	return 0
}
