//go:build e2etool

package main

// 端到端测试脚本（tests/e2e_local.sh、tests/web_shots.sh）用的辅助命令，只在 go build -tags e2etool 时编进去，
// 正式发布的程序里没有。模拟客户端：生成钥匙开启加密、算登录凭证、解密消息和附件。
//
//	huijian e2e-setup <密码>              → 第一行私钥（base64url），第二行 POST /v1/e2e/setup 的请求体
//	huijian e2e-authkey <密码> <盐 hex>   → auth_key（新登录协议）
//	huijian e2e-register <用户名> <密码> [邀请码] [平台] [设备名]
//	                                      → 第一行私钥（base64url），第二行 POST /v1/register 的请求体（0.9.0 注册即开启加密）
//	huijian e2e-open <钥匙文件>           标准输入是 /v1/messages（或 /v1/messages/{id}）的响应，输出同样的 JSON，
//	                                      加密消息的 text / desp / type 换成解密后的内容，多一个 atts（真实名字、类型、大小、钥匙）
//	huijian e2e-file <附件钥匙>           标准输入是附件密文，标准输出是明文

import (
	"bufio"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

func init() {
	extraCommands["e2e-setup"] = toolSetup
	extraCommands["e2e-authkey"] = toolAuthKey
	extraCommands["e2e-register"] = toolRegister
	extraCommands["e2e-open"] = toolOpen
	extraCommands["e2e-file"] = toolFile
}

func toolSetup(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "用法: e2e-setup <密码>")
		return 2
	}
	sk, _ := ecdh.X25519().GenerateKey(rand.Reader)
	salt := make([]byte, 16)
	rand.Read(salt)
	auth, unlock := e2ePasswordKeys(args[0], salt)
	wrap, err := e2eWrap("hjp1", unlock, sk.Bytes())
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	body, _ := json.Marshal(map[string]any{"pub": b64.EncodeToString(sk.PublicKey().Bytes()), "auth_salt": hex.EncodeToString(salt),
		"auth_key": b64.EncodeToString(auth), "password_wrap": wrap, "current_password": args[0]})
	fmt.Println(b64.EncodeToString(sk.Bytes()))
	fmt.Println(string(body))
	return 0
}

func toolRegister(args []string) int {
	if len(args) < 2 || len(args) > 5 {
		fmt.Fprintln(os.Stderr, "用法: e2e-register <用户名> <密码> [邀请码] [平台] [设备名]")
		return 2
	}
	a := append(args, "", "", "")
	platform, name := a[3], a[4]
	if platform == "" {
		platform = "test"
	}
	if name == "" {
		name = "e2e"
	}
	fp := make([]byte, 16)
	rand.Read(fp)
	body, sk, err := registerBody(args[0], args[1], a[2], name, platform, hex.EncodeToString(fp))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	b, _ := json.Marshal(body)
	fmt.Println(b64.EncodeToString(sk.Bytes()))
	fmt.Println(string(b))
	return 0
}

func toolAuthKey(args []string) int {
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "用法: e2e-authkey <密码> <盐 hex>")
		return 2
	}
	salt, err := hex.DecodeString(args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	auth, _ := e2ePasswordKeys(args[0], salt)
	fmt.Println(b64.EncodeToString(auth))
	return 0
}

func toolOpen(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "用法: e2e-open <钥匙文件（每行一个私钥）>")
		return 2
	}
	f, err := os.Open(args[0])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var keys []*ecdh.PrivateKey
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if raw, err := b64.DecodeString(strings.TrimSpace(sc.Text())); err == nil {
			if k, err := ecdh.X25519().NewPrivateKey(raw); err == nil {
				keys = append(keys, k)
			}
		}
	}
	f.Close()
	var in map[string]any
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		fmt.Fprintln(os.Stderr, "解析失败：", err)
		return 1
	}
	open := func(m map[string]any) {
		env, _ := m["e2e"].(string)
		if env == "" {
			return
		}
		for _, k := range keys {
			pt, err := e2eOpenMessage(k, env)
			if err != nil {
				continue
			}
			var p e2ePayload
			if json.Unmarshal(pt, &p) == nil {
				m["text"], m["desp"], m["type"], m["atts"], m["decrypted"] = p.Text, p.Desp, p.Type, p.Atts, true
				if p.Type == "" {
					m["type"] = "markdown"
				}
			}
			return
		}
		m["decrypted"] = false
	}
	if list, ok := in["messages"].([]any); ok {
		for _, x := range list {
			if m, ok := x.(map[string]any); ok {
				open(m)
			}
		}
	}
	if m, ok := in["message"].(map[string]any); ok {
		open(m)
	}
	json.NewEncoder(os.Stdout).Encode(in)
	return 0
}

func toolFile(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "用法: e2e-file <附件钥匙>")
		return 2
	}
	key, err := b64.DecodeString(args[0])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if err := e2eDecryptFile(key, io.Reader(os.Stdin), os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "解密失败：", err)
		return 1
	}
	return 0
}
