package main

// 转发到 Bark：iPhone 上的回笺由用户用 GBox 等工具自签安装，用不了苹果推送（APNs）。
// 锁屏通知借用 App Store 免费 App「Bark」的推送通道：每台设备可以登记一个 Bark 推送地址，
// 新消息按这台设备的接收规则判断后转发过去，点通知用 huijian://message/<id> 跳回回笺看详情和附件。
//
//	PUT  /v1/bark       {"url": "https://api.day.app/<key>", "cipher_key": "", "cipher_iv": ""}  url 为空 = 关闭
//	POST /v1/bark/test  发一条测试通知
//	GET  /v1/me         返回里带 "bark": {"url": "...", "encrypted": true}（没配置时为 null）
//
// 端到端加密（可选）：和 Bark App「加密设置」一致，AES-128/192/256 + CBC + PKCS7。所有参数
// （title/body/level/group/url/icon 等）序列化后加密为 ciphertext，表单外只有 ciphertext 和 iv：
// Bark 加密推送只认密文里的参数，Bark 的服务器也就看不到任何内容。

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type barkConfig struct {
	URL string // 规范化后的 scheme://host[:port]/<key>
	Key string // 加密密钥（16 / 24 / 32 字节），空 = 不加密
	IV  string // 16 字节
}

func (c barkConfig) encrypted() bool { return c.Key != "" }

func (c barkConfig) json() any {
	if c.URL == "" {
		return nil
	}
	return map[string]any{"url": c.URL, "encrypted": c.encrypted()}
}

func (s *Store) migrateBark() error {
	for _, col := range []string{"bark_url", "bark_key", "bark_iv"} {
		if err := s.addColumn("devices", col, "TEXT NOT NULL DEFAULT ''"); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) BarkConfig(deviceID string) barkConfig {
	var c barkConfig
	s.db.QueryRow(`SELECT bark_url,bark_key,bark_iv FROM devices WHERE id=?`, deviceID).Scan(&c.URL, &c.Key, &c.IV)
	return c
}

func (s *Store) SetBarkConfig(deviceID string, c barkConfig) error {
	_, err := s.db.Exec(`UPDATE devices SET bark_url=?,bark_key=?,bark_iv=? WHERE id=?`, c.URL, c.Key, c.IV, deviceID)
	return err
}

// barkDevices：账号下登记了 Bark 的有效设备
func (s *Store) barkDevices(userID int64) []Device {
	list, _ := s.queryDevices(`SELECT `+deviceCols+` FROM devices WHERE user_id=? AND revoked=0 AND bark_url!=''`, userID)
	return list
}

var barkKeyRe = regexp.MustCompile(`^[A-Za-z0-9_-]{4,128}$`)

// parseBarkURL 接受 Bark App 里复制的地址，例如 https://api.day.app/AbCd123/这里改成你自己的推送内容，
// 规范化为 https://api.day.app/AbCd123
func parseBarkURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return "", fmt.Errorf("Bark 地址格式不对，应为 https://api.day.app/<你的 key>")
	}
	seg := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(seg) == 0 || !barkKeyRe.MatchString(seg[0]) {
		return "", fmt.Errorf("Bark 地址里没有找到 key，应为 https://api.day.app/<你的 key>")
	}
	return u.Scheme + "://" + u.Host + "/" + seg[0], nil
}

// ---------- 发送 ----------

type barkNote struct {
	Title, Body, Group, URL string
	Priority                int
}

func barkLevel(p int) string {
	switch {
	case p >= 5:
		return "critical"
	case p == 4:
		return "timeSensitive"
	default:
		return "active"
	}
}

func pkcs7(b []byte, size int) []byte {
	n := size - len(b)%size
	return append(b, bytes.Repeat([]byte{byte(n)}, n)...)
}

func barkEncrypt(c barkConfig, plain []byte) (string, error) {
	block, err := aes.NewCipher([]byte(c.Key))
	if err != nil {
		return "", err
	}
	if len(c.IV) != aes.BlockSize {
		return "", fmt.Errorf("IV 必须是 16 个字符")
	}
	data := pkcs7(plain, aes.BlockSize)
	out := make([]byte, len(data))
	cipher.NewCBCEncrypter(block, []byte(c.IV)).CryptBlocks(out, data)
	return base64.StdEncoding.EncodeToString(out), nil
}

var barkClient = &http.Client{Timeout: 15 * time.Second}

// sendBark 发一条 Bark 通知；失败时返回的错误里不含 key
func sendBark(c barkConfig, n barkNote, icon string) error {
	p := map[string]string{"level": barkLevel(n.Priority), "isArchive": "0"} // 历史记录在回笺里看，Bark 里不重复保存
	if n.Priority >= 5 {
		p["volume"], p["sound"] = "8", "alarm"
	}
	for k, v := range map[string]string{"group": n.Group, "url": n.URL, "icon": icon, "title": n.Title, "body": n.Body} {
		if v != "" {
			p[k] = v
		}
	}
	form := url.Values{}
	if c.encrypted() {
		// 加密推送时 Bark 只认密文里的参数（实测放在外面的 level 不生效），所以全部放进密文；
		// 外面只留 ciphertext 和 iv，Bark 服务器也看不到频道名、消息编号这些信息
		plain, _ := json.Marshal(p)
		ct, err := barkEncrypt(c, plain)
		if err != nil {
			return err
		}
		form.Set("ciphertext", ct)
		form.Set("iv", c.IV)
	} else {
		for k, v := range p {
			form.Set(k, v)
		}
	}
	var last error
	for attempt := 0; attempt < 2; attempt++ {
		if attempt > 0 {
			time.Sleep(2 * time.Second)
		}
		resp, err := barkClient.PostForm(c.URL, form)
		if err != nil {
			last = fmt.Errorf("连不上 Bark 服务器：%s", redactBark(err.Error(), c.URL))
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		var r struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		}
		json.Unmarshal(body, &r)
		if resp.StatusCode == 200 && (r.Code == 0 || r.Code == 200) {
			return nil
		}
		msg := r.Message
		if msg == "" {
			msg = "HTTP " + strconv.Itoa(resp.StatusCode)
		}
		last = fmt.Errorf("Bark 返回：%s", msg)
		if resp.StatusCode >= 400 && resp.StatusCode < 500 {
			break // key 不对等，重试没用
		}
	}
	return last
}

// redactBark：错误信息里可能带完整 URL（含 key），日志和返回前去掉
func redactBark(s, u string) string {
	if i := strings.LastIndex(u, "/"); i > 0 {
		s = strings.ReplaceAll(s, u[i+1:], "***")
	}
	return s
}

// plainText：回笺 Markdown 转成通知用的纯文本（表格每行「列 · 列」，提示框带图标，见 md.go）
func plainText(s string) string { return clip(docPlain(parseMD(s, nil)), 300) }

// clip 按字符截断，超出加「…」。APNs 负载上限 4KB，加密后还要 base64，标题和正文都要限长
func clip(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n]) + "…"
	}
	return s
}

func (h *Hub) channelDisplayName(userID int64, topic string) string {
	list, _ := h.st.Channels(userID)
	for _, c := range list {
		if c.Topic == topic && c.Alias != "" {
			return c.Alias
		}
	}
	return topic
}

func barkIcon() string {
	if u := env("HUIJIAN_PUBLIC_URL", ""); u != "" {
		return strings.TrimRight(u, "/") + "/icon.png"
	}
	return ""
}

// forwardBark：新消息转发到账号下登记了 Bark 的设备。按每台设备的接收规则判断（不接收的 key、
// 静默的 key / 频道、正在别的设备上使用），P0–P2 不转发。在后台 goroutine 里调用。
func (h *Hub) forwardBark(userID, msgID int64) {
	devs := h.st.barkDevices(userID)
	if len(devs) == 0 {
		return
	}
	for i := range devs {
		d := &devs[i]
		msgs, err := h.st.Messages(userID, d.ID, msgID-1, 1)
		if err != nil || len(msgs) == 0 || msgs[0].ID != msgID {
			continue // 这台设备设为不接收这把 key
		}
		h.decorate(d, msgs)
		m := msgs[0]
		if m.Silent || m.Priority < 3 {
			continue
		}
		if m.E2E != "" { // 加密消息：服务端读不到内容，锁屏只提示有新消息（点开回笺在本机解密）
			body := "打开回笺查看（端到端加密）"
			if n := len(m.Attachments); n > 0 {
				body += fmt.Sprintf(" · 📎 %d 个附件", n)
			}
			note := barkNote{Title: "🔒 新消息", Body: body, Group: h.channelDisplayName(userID, m.Topic),
				URL: fmt.Sprintf("huijian://message/%d", m.ID), Priority: m.Priority}
			if err := sendBark(h.st.BarkConfig(d.ID), note, barkIcon()); err != nil {
				log.Printf("转发到 Bark 失败（设备 %s，消息 #%d）：%v", d.ID, m.ID, err)
			}
			continue
		}
		body := clip(m.Desp, 300)
		if m.Type != "text" {
			if e := cachedDoc(&m); e != nil {
				body = clip(docPlain(e.doc), 300)
			}
		}
		if n := len(m.Attachments); n > 0 {
			body = strings.TrimSpace(body + fmt.Sprintf("\n📎 %d 个附件", n))
		}
		if body == "" {
			body = "来自 " + m.Source
		}
		note := barkNote{Title: clip(m.Text, 100), Body: body, Group: h.channelDisplayName(userID, m.Topic),
			URL: fmt.Sprintf("huijian://message/%d", m.ID), Priority: m.Priority}
		if err := sendBark(h.st.BarkConfig(d.ID), note, barkIcon()); err != nil {
			log.Printf("转发到 Bark 失败（设备 %s，消息 #%d）：%v", d.ID, m.ID, err)
		}
	}
}

// ---------- 设备接口 ----------

// PUT /v1/bark
func (h *Hub) handleBarkSet(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct {
		URL       string `json:"url"`
		CipherKey string `json:"cipher_key"`
		CipherIV  string `json:"cipher_iv"`
	}
	if !readJSON(w, r, &in) {
		return
	}
	u, err := parseBarkURL(in.URL)
	if err != nil {
		apiErr(w, 400, err.Error())
		return
	}
	c := barkConfig{URL: u}
	if u != "" && in.CipherKey != "" {
		switch len(in.CipherKey) {
		case 16, 24, 32:
		default:
			apiErr(w, 400, "加密密钥必须是 16、24 或 32 个字符（对应 AES128 / AES192 / AES256）")
			return
		}
		if len(in.CipherIV) != 16 {
			apiErr(w, 400, "加密 IV 必须是 16 个字符")
			return
		}
		c.Key, c.IV = in.CipherKey, in.CipherIV
	}
	if err := h.st.SetBarkConfig(d.ID, c); err != nil {
		apiErr(w, 500, "保存失败")
		return
	}
	if u == "" {
		log.Printf("设备 %s 关闭了 Bark 转发", d.ID)
	} else {
		log.Printf("设备 %s 设置了 Bark 转发（加密：%v）", d.ID, c.encrypted())
	}
	writeJSON(w, 200, map[string]any{"url": c.URL, "encrypted": c.encrypted()})
}

// POST /v1/bark/test
func (h *Hub) handleBarkTest(w http.ResponseWriter, r *http.Request, d *Device) {
	c := h.st.BarkConfig(d.ID)
	if c.URL == "" {
		apiErr(w, 400, "这台设备还没有设置 Bark 地址")
		return
	}
	if !h.pushLimit.Allow("bark:" + d.ID) {
		apiErr(w, 429, "发送太频繁，请稍后再试")
		return
	}
	note := barkNote{Title: "回笺测试", Body: fmt.Sprintf("「%s」的 Bark 转发已设置好，发送于 %s。", d.Name, time.Now().Format("15:04:05")),
		Group: "回笺", URL: "huijian://", Priority: 4}
	if err := sendBark(c, note, barkIcon()); err != nil {
		apiErr(w, 502, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}
