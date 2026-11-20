package main

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net"
	"net/http"
	"net/textproto"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error { *m = append(*m, v); return nil }

// Job 是一次发送任务，也是 outbox 中保存的格式。
type Job struct {
	URLs     []string `json:"urls"`
	Pushkey  string   `json:"pushkey"`
	Text     string   `json:"text"`
	Desp     string   `json:"desp,omitempty"`
	Type     string   `json:"type,omitempty"`
	Priority int      `json:"priority"`
	Topic    string   `json:"topic,omitempty"`
	Thread   string   `json:"thread,omitempty"`
	Files    []string `json:"files,omitempty"`
	Names    []string `json:"names,omitempty"` // 附件显示名（outbox 里的副本带序号前缀，发送时用原来的名字）；空时用文件名
	Idem     string   `json:"idem"`            // 幂等键：同一任务重试/补发多少次，服务端只记一条
}

var pushClient = &http.Client{Transport: &http.Transport{
	Proxy:                 http.ProxyFromEnvironment,
	DialContext:           (&net.Dialer{Timeout: 5 * time.Second}).DialContext,
	TLSHandshakeTimeout:   10 * time.Second,
	ResponseHeaderTimeout: 120 * time.Second,
}}

func defaultURLs() string {
	return env("HUIJIAN_URL", "")
}

func runPush(args []string) int {
	fs := flag.NewFlagSet("push", flag.ContinueOnError)
	key := fs.String("k", env("HUIJIAN_PUSHKEY", ""), "接收方 pushkey")
	urls := fs.String("u", defaultURLs(), "服务器地址，逗号分隔")
	desp := fs.String("d", "", "正文")
	prio := fs.Int("p", -1, "优先级 0-5")
	topic := fs.String("topic", "", "频道")
	thread := fs.String("thread", "", "线程")
	typ := fs.String("type", "", "text/markdown/image")
	noOutbox := fs.Bool("no-outbox", false, "失败时不写入 outbox")
	var files multiFlag
	fs.Var(&files, "f", "附件（可重复）")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	text := strings.Join(fs.Args(), " ")
	if text == "-" {
		b, _ := io.ReadAll(io.LimitReader(os.Stdin, 64<<10))
		text = strings.TrimSpace(string(b))
	}
	if *urls == "" {
		fmt.Fprintln(os.Stderr, "缺少服务器地址：用 -u 或环境变量 HUIJIAN_URL（例如 https://push.example.com）")
		return 2
	}
	if *key == "" {
		fmt.Fprintln(os.Stderr, "缺少 pushkey：用 -k 或环境变量 HUIJIAN_PUSHKEY")
		return 2
	}
	// 加密发送密钥（PK_xxx.e2e.<公钥>，客户端 Pushkey 页复制）：标题、正文、附件都在本机加密后再发
	if _, _, err := splitSendKeys(*key); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	if text == "" && len(files) == 0 {
		fmt.Fprintln(os.Stderr, "缺少消息文本")
		return 2
	}
	for i, f := range files {
		abs, err := filepath.Abs(f)
		if err != nil {
			return 2
		}
		if st, err := os.Stat(abs); err != nil || st.IsDir() {
			fmt.Fprintf(os.Stderr, "附件不存在或是目录: %s\n", f)
			return 2
		}
		files[i] = abs
	}
	job := Job{URLs: splitList(*urls), Pushkey: *key, Text: text, Desp: *desp, Type: *typ,
		Priority: *prio, Topic: *topic, Thread: *thread, Files: files, Idem: "cli_" + randHex(12)}

	flushOutbox(true) // 顺带补发之前积压的
	id, retryable, err := sendJob(job)
	if err == nil {
		fmt.Println("已发送，消息 id:", id)
		return 0
	}
	if retryable && !*noOutbox {
		if p, oerr := saveOutbox(job); oerr == nil {
			fmt.Fprintf(os.Stderr, "发送失败（%v），已存入 outbox：%s，下次发送或执行 huijian flush 时自动重试\n", err, p)
			return 3
		}
	}
	fmt.Fprintln(os.Stderr, "发送失败:", err)
	return 1
}

// sendJob 按顺序尝试每个地址。返回 (消息id, 是否值得重试, 错误)。
func sendJob(j Job) (string, bool, error) {
	if len(j.URLs) == 0 {
		j.URLs = splitList(defaultURLs())
	}
	var lastErr error
	for _, base := range j.URLs {
		id, status, err := sendOnce(strings.TrimRight(base, "/"), j)
		if err == nil {
			return id, false, nil
		}
		lastErr = fmt.Errorf("%s: %w", base, err)
		if status >= 400 && status < 500 && status != 408 && status != 429 {
			return "", false, lastErr // 参数/权限错误，换地址也没用
		}
	}
	return "", true, lastErr
}

// splitSendKeys：拆开（可能逗号分隔的多个）发送密钥。带公钥的必须是同一把公钥（加密消息只能发给同一个账号）；
// 返回给服务器的 pushkey 列表和公钥（都是普通 pushkey 时为 nil）
func splitSendKeys(s string) (string, *ecdh.PublicKey, error) {
	var keys []string
	var pub *ecdh.PublicKey
	plain := false
	for _, k := range splitList(s) {
		pk, p, err := e2eSplitSendKey(k)
		if err != nil {
			return "", nil, err
		}
		keys = append(keys, pk)
		switch {
		case p == nil:
			plain = true
		case pub == nil:
			pub = p
		case !pub.Equal(p):
			return "", nil, errors.New("多个加密发送密钥属于不同的账号：加密消息只能一次发给同一个账号")
		}
	}
	if pub != nil && plain {
		return "", nil, errors.New("加密发送密钥不能和普通 pushkey 混在一起发送")
	}
	return strings.Join(keys, ","), pub, nil
}

// fileName：第 i 个附件发给服务器 / 写进信封的名字
func (j Job) fileName(i int) string {
	if i < len(j.Names) && j.Names[i] != "" {
		return j.Names[i]
	}
	return filepath.Base(j.Files[i])
}

// e2eSeal：用加密发送密钥里的公钥把标题、正文、附件信息封进信封；返回信封和每个附件的密钥（顺序同 j.Files）
func e2eSeal(pub *ecdh.PublicKey, j Job) (string, [][]byte, error) {
	var atts []e2eAtt
	keys := make([][]byte, len(j.Files))
	for i, path := range j.Files {
		st, err := os.Stat(path)
		if err != nil {
			return "", nil, err
		}
		keys[i] = make([]byte, 32)
		if _, err := rand.Read(keys[i]); err != nil {
			return "", nil, err
		}
		atts = append(atts, e2eAtt{Name: j.fileName(i), Mime: fileMime(path), Size: st.Size(), Key: b64.EncodeToString(keys[i])})
	}
	env, err := e2eSealPayload(pub, j.Text, j.Desp, j.Type, atts)
	if err != nil {
		return "", nil, err
	}
	return env, keys, nil
}

// fileMime：附件类型，按扩展名，认不出时看文件头（和服务端的判断方式一致）
func fileMime(path string) string {
	if mt := mime.TypeByExtension(strings.ToLower(filepath.Ext(path))); mt != "" {
		return mt
	}
	f, err := os.Open(path)
	if err != nil {
		return "application/octet-stream"
	}
	defer f.Close()
	head := make([]byte, 512)
	n, _ := io.ReadFull(f, head)
	return http.DetectContentType(head[:n])
}

func sendOnce(base string, j Job) (string, int, error) {
	pushkey, pub, err := splitSendKeys(j.Pushkey)
	if err != nil {
		return "", 400, err
	}
	fields := map[string]string{"pushkey": pushkey, "text": j.Text, "desp": j.Desp,
		"type": j.Type, "topic": j.Topic, "thread": j.Thread, "idem": j.Idem}
	var keys [][]byte
	if pub != nil { // 每次发送都重新加密（新的一次性密钥）；同一个 idem，服务端只记一条
		env, k, err := e2eSeal(pub, j)
		if err != nil {
			return "", 400, err
		}
		fields = map[string]string{"pushkey": pushkey, "e2e": env, "topic": j.Topic, "thread": j.Thread, "idem": j.Idem}
		keys = k
	}
	pr, pw := io.Pipe()
	mw := multipart.NewWriter(pw)
	go func() {
		err := func() error {
			if j.Priority >= 0 {
				fields["priority"] = strconv.Itoa(j.Priority)
			}
			for k, v := range fields {
				if v != "" {
					if err := mw.WriteField(k, v); err != nil {
						return err
					}
				}
			}
			for i, p := range j.Files {
				f, err := os.Open(p)
				if err != nil {
					return err
				}
				name := j.fileName(i)
				if keys != nil {
					name = fmt.Sprintf("encrypted-%d.bin", i+1) // 真实文件名在信封里
				}
				hdr := make(textproto.MIMEHeader)
				hdr.Set("Content-Disposition", fmt.Sprintf(`form-data; name="file"; filename="%s"`,
					strings.NewReplacer(`"`, "_", "\r", "", "\n", "").Replace(name)))
				hdr.Set("Content-Type", "application/octet-stream")
				w, err := mw.CreatePart(hdr)
				if err == nil {
					if keys != nil {
						err = e2eEncryptFile(keys[i], f, w) // 边读边加密，不落临时文件
					} else {
						_, err = io.Copy(w, f)
					}
				}
				f.Close()
				if err != nil {
					return err
				}
			}
			return mw.Close()
		}()
		pw.CloseWithError(err)
	}()
	req, err := http.NewRequest("POST", base+"/message/push", pr)
	if err != nil {
		return "", 0, err
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("User-Agent", "huijian-cli/"+version)
	resp, err := pushClient.Do(req)
	if err != nil {
		return "", 0, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	var r struct {
		Code    int    `json:"code"`
		Error   string `json:"error"`
		Content struct {
			Result []string `json:"result"`
		} `json:"content"`
	}
	json.Unmarshal(body, &r)
	if resp.StatusCode != 200 || r.Code != 0 {
		msg := r.Error
		if msg == "" {
			msg = strings.TrimSpace(string(body))
			if len(msg) > 200 {
				msg = msg[:200]
			}
		}
		return "", resp.StatusCode, fmt.Errorf("HTTP %d %s", resp.StatusCode, msg)
	}
	return strings.Join(r.Content.Result, ","), 200, nil
}

// ---------- outbox ----------

func outboxDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(preferExisting(filepath.Join(home, ".huijian")), "outbox")
}

func saveOutbox(j Job) (string, error) {
	dir := filepath.Join(outboxDir(), strconv.FormatInt(time.Now().UnixNano(), 10))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	// 复制附件，避免原文件被训练脚本删除或覆盖。副本名带序号前缀（同名文件不冲突），原来的名字记在 names 里
	j.Files = append([]string(nil), j.Files...)
	if len(j.Names) == 0 {
		for _, p := range j.Files {
			j.Names = append(j.Names, filepath.Base(p))
		}
	}
	for i, p := range j.Files {
		dst := filepath.Join(dir, fmt.Sprintf("%02d_%s", i, filepath.Base(p)))
		if err := copyFile(p, dst); err != nil {
			os.RemoveAll(dir)
			return "", err
		}
		j.Files[i] = dst
	}
	b, _ := json.MarshalIndent(j, "", "  ")
	return dir, os.WriteFile(filepath.Join(dir, "job.json"), b, 0o600)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// flushOutbox 返回 (成功数, 剩余数)。
func flushOutbox(quiet bool) (int, int) {
	ents, err := os.ReadDir(outboxDir())
	if err != nil {
		return 0, 0
	}
	var dirs []string
	for _, e := range ents {
		name := e.Name()
		if !e.IsDir() || name == "failed" {
			continue
		}
		// 认领超过 10 分钟仍未释放（进程崩溃）的任务，放回队列
		if base, _, claimed := strings.Cut(name, ".claim-"); claimed {
			if info, err := e.Info(); err == nil && time.Since(info.ModTime()) > 10*time.Minute {
				os.Rename(filepath.Join(outboxDir(), name), filepath.Join(outboxDir(), base))
				name = base
			} else {
				continue
			}
		}
		dirs = append(dirs, name)
	}
	sort.Strings(dirs)
	ok, left := 0, 0
	tag := fmt.Sprintf(".claim-%d", os.Getpid())
	for i, d := range dirs {
		dir := filepath.Join(outboxDir(), d)
		claimed := dir + tag
		// 原子改名认领：多个 huijian 进程同时补发时，只有一个能拿到这个任务
		if err := os.Rename(dir, claimed); err != nil {
			continue
		}
		now := time.Now()
		os.Chtimes(claimed, now, now)
		b, err := os.ReadFile(filepath.Join(claimed, "job.json"))
		var j Job
		if err != nil || json.Unmarshal(b, &j) != nil {
			os.RemoveAll(claimed)
			continue
		}
		claimedFiles(&j, claimed)
		_, retryable, err := sendJob(j)
		switch {
		case err == nil:
			os.RemoveAll(claimed)
			ok++
		case !retryable:
			os.MkdirAll(filepath.Join(outboxDir(), "failed"), 0o700)
			os.Rename(claimed, filepath.Join(outboxDir(), "failed", d))
			if !quiet {
				fmt.Fprintf(os.Stderr, "outbox %s 无法发送（%v），已移到 failed/\n", d, err)
			}
		default:
			os.Rename(claimed, dir) // 释放，等下次重试
			left += len(dirs) - i   // 服务器仍不可达，后面的不再尝试
			if !quiet {
				fmt.Fprintf(os.Stderr, "服务器仍不可达：%v\n", err)
			}
			return ok, left
		}
	}
	return ok, left
}

// claimedFiles：job.json 里记的附件路径指向认领前的目录（outbox/<id>/NN_名字），认领时目录改了名，
// 附件要按文件名到认领后的目录里找；旧版本存的任务没有 names，去掉副本的序号前缀作为显示名
func claimedFiles(j *Job, claimed string) {
	if len(j.Names) == 0 {
		j.Names = make([]string, len(j.Files))
		for i, p := range j.Files {
			j.Names[i] = filepath.Base(p)
			if n := j.Names[i]; len(n) > 3 && n[0] >= '0' && n[0] <= '9' && n[1] >= '0' && n[1] <= '9' && n[2] == '_' {
				j.Names[i] = n[3:]
			}
		}
	}
	for i, p := range j.Files {
		if c := filepath.Join(claimed, filepath.Base(p)); fileExists(c) {
			j.Files[i] = c
		}
	}
}

func runFlush() int {
	ok, left := flushOutbox(false)
	fmt.Printf("补发成功 %d 条，剩余 %d 条\n", ok, left)
	if left > 0 {
		return 3
	}
	return 0
}
