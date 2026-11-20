package main

import (
	"bufio"
	"context"
	"crypto/ecdh"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode"
)

type Hub struct {
	dataDir      string
	paths        storePaths
	files        *fileStore
	backup       *backupper
	tmpDir       string
	releaseDir   string
	maxUpload    int64
	trustedProxy ipSet
	adminDeny    ipSet
	userID       int64 // 接收系统通知的账号；0 = 第一个账号（noticeUser）
	st           *Store
	br           *Broker
	pushLimit    *Limiter
	pairLimit    *Limiter
	loginLimit   *Limiter // 管理后台登录（令牌 / 一次性链接）按来源 IP 限速，防暴力猜测
	acctLimit    *Limiter // 账号登录 / 注册：按来源 IP 和用户名分别限速
	admin        *adminState
	presence     presence
	upd          updaterState
	restart      chan string // 一键更新完成后，新程序的路径
}

func runHub() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	data := dataDir()
	bootStaged(data) // 数据目录里有已更新的新版本就直接切过去（见 selfupdate.go）
	h := &Hub{
		restart:      make(chan string, 1),
		dataDir:      data,
		paths:        resolvePaths(data),
		tmpDir:       filepath.Join(data, "tmp"),
		releaseDir:   filepath.Join(data, "releases"),
		maxUpload:    envInt("HUIJIAN_MAX_UPLOAD_MB", 512) << 20,
		trustedProxy: parseIPSet(env("HUIJIAN_TRUSTED_PROXY", "")),
		adminDeny:    parseIPSet(env("HUIJIAN_ADMIN_DENY", "")),
		br:           NewBroker(),
		pushLimit:    NewLimiter(float64(envInt("HUIJIAN_PUSH_PER_MIN", 60)), 30),
		pairLimit:    NewLimiter(10, 5),
		loginLimit:   NewLimiter(6, 6),
		acctLimit:    NewLimiter(20, 20),
	}
	if fileConfPath != "" {
		log.Printf("配置文件 %s", fileConfPath)
	}
	log.Printf("数据目录 %s", absPath(data))
	if err := checkPaths(data, h.paths); err != nil {
		log.Fatalf("目录配置有误：%v", err)
	}
	for _, d := range []string{h.tmpDir, h.releaseDir} {
		if err := os.MkdirAll(d, 0o750); err != nil {
			log.Fatalf("创建目录 %s: %v", d, err)
		}
	}
	// 清理上次异常退出遗留的临时文件
	if ents, err := os.ReadDir(h.tmpDir); err == nil {
		for _, e := range ents {
			os.Remove(filepath.Join(h.tmpDir, e.Name()))
		}
	}
	st, err := OpenStore(dbPath(data))
	if err != nil {
		log.Fatal(err)
	}
	h.st = st
	st.notify = h.br.Notify
	setPageProxy(st.GetKV(updProxyKey)) // 管理页设置的更新代理（见 selfupdate_net.go）
	cleanUpdateTemps(data)
	if err = st.EnsureLegacyOwner(); err != nil {
		log.Fatal(err)
	}
	h.admin = newAdminState(data)
	h.files = newFileStore(h, h.paths.files)
	h.backup = newBackupper(h)
	if err := h.files.files.ready(); err != nil {
		log.Printf("⚠️ 附件目录 %s 暂不可用，新附件先存本地：%v", h.paths.files, err)
	} else {
		log.Printf("附件目录 %s", absPath(h.paths.files))
	}
	stopBg := h.startBackground()
	h.startAllSealBacklogs() // 已开启加密的账号里还有明文消息（开启以前的历史、上次附件读不到跳过的）：后台补加密

	pub := &http.Server{
		Addr:              env("HUIJIAN_PUBLIC_ADDR", "127.0.0.1:8790"),
		Handler:           logMW("pub", h.realIP, withServerHeader(h.publicMux())),
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	adm := &http.Server{
		Addr:              env("HUIJIAN_ADMIN_ADDR", "127.0.0.1:8791"),
		Handler:           logMW("adm", func(r *http.Request) string { return hostOf(r.RemoteAddr) }, h.adminMux()),
		ReadHeaderTimeout: 15 * time.Second,
	}
	errc := make(chan error, 2)
	go func() { log.Printf("公网 API 监听 %s", pub.Addr); errc <- pub.ListenAndServe() }()
	go func() { log.Printf("管理网页监听 %s", adm.Addr); errc <- adm.ListenAndServe() }()
	log.Printf("登录管理后台：在服务器上执行 `docker exec huijian huijian admin-link`（或 `huijian admin-link`）获取一次性登录链接")

	stopUpd := make(chan struct{})
	go h.updateLoop(stopUpd)
	go markBootHealthy(data, stopUpd)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	next := ""
	select {
	case err := <-errc:
		log.Fatalf("监听失败: %v", err)
	case s := <-sig:
		log.Printf("收到 %v，退出", s)
		resetBootAttempts(data) // 正常停止不算启动失败（崩溃不会走到这里）
	case next = <-h.restart:
		log.Printf("服务端更新：关闭服务，切换到 %s", next)
	}
	close(stopUpd)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	h.br.CloseAll()
	stopBg()
	pub.Shutdown(ctx)
	adm.Shutdown(ctx)
	st.db.Close()
	if next != "" {
		cancel()
		err := execSelf(next)
		// exec 失败：退出让 Docker / systemd 重启，启动时 bootStaged 会再试（最多 3 次后回退）
		log.Fatalf("切换到新版本失败：%v", err)
	}
}

// realIP：只有来自可信反向代理（HUIJIAN_TRUSTED_PROXY）的请求才采信 X-Real-IP。
func (h *Hub) realIP(r *http.Request) string {
	ip := hostOf(r.RemoteAddr)
	if h.trustedProxy.has(ip) {
		if x := strings.TrimSpace(r.Header.Get("X-Real-IP")); x != "" {
			return x
		}
	}
	return ip
}

// ---------- 广播 ----------

type Broker struct {
	mu     sync.Mutex
	subs   map[int64]map[chan struct{}]string // userID -> chan -> deviceID
	closed bool
}

func NewBroker() *Broker { return &Broker{subs: map[int64]map[chan struct{}]string{}} }

func (b *Broker) Subscribe(userID int64, deviceID string) chan struct{} {
	b.mu.Lock()
	defer b.mu.Unlock()
	ch := make(chan struct{}, 1)
	if b.subs[userID] == nil {
		b.subs[userID] = map[chan struct{}]string{}
	}
	b.subs[userID][ch] = deviceID
	return ch
}

func (b *Broker) Unsubscribe(userID int64, ch chan struct{}) {
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.subs[userID], ch)
}

func (b *Broker) Notify(userID int64) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for ch := range b.subs[userID] {
		select {
		case ch <- struct{}{}:
		default: // 已有待处理通知，合并
		}
	}
}

func (b *Broker) Online(userID int64) map[string]int {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := map[string]int{}
	for _, d := range b.subs[userID] {
		out[d]++
	}
	return out
}

// OnlineCount：全服务器正在长轮询等消息的设备数（管理后台概览用，只是个数）
func (b *Broker) OnlineCount() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := 0
	for _, m := range b.subs {
		seen := map[string]bool{}
		for _, d := range m {
			if !seen[d] {
				seen[d] = true
				n++
			}
		}
	}
	return n
}

func (b *Broker) CloseAll() {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, m := range b.subs {
		for ch := range m {
			close(ch)
		}
	}
	b.subs = map[int64]map[chan struct{}]string{}
}

// ---------- 公网路由 ----------

func (h *Hub) publicMux() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("/message/push", h.handlePush)
	m.HandleFunc("POST /v1/pair", h.handlePair)
	m.HandleFunc("GET /v1/me", h.deviceAuth(h.handleMe))
	m.HandleFunc("PATCH /v1/me", h.deviceAuth(h.handleMeUpdate))
	// 账号内的操作：本账号的任何设备都可以
	m.HandleFunc("GET /v1/keys", h.deviceAuth(h.handleKeysList))
	m.HandleFunc("POST /v1/keys", h.deviceAuth(h.handleKeysCreate))
	m.HandleFunc("PATCH /v1/keys/{id}", h.deviceAuth(h.handleKeysUpdate))
	m.HandleFunc("POST /v1/keys/{id}/revoke", h.deviceAuth(h.handleKeysRevoke))
	m.HandleFunc("DELETE /v1/keys/{id}", h.deviceAuth(h.handleKeysDelete))
	m.HandleFunc("GET /v1/messages/state", h.deviceAuth(h.handleMessageStates))
	m.HandleFunc("GET /v1/channels", h.deviceAuth(h.handleChannels))
	m.HandleFunc("PATCH /v1/channels", h.deviceAuth(h.handleChannelUpdate))
	m.HandleFunc("PUT /v1/channels/order", h.deviceAuth(h.handleChannelOrder))
	m.HandleFunc("POST /v1/channels/delete", h.deviceAuth(h.handleChannelDelete))
	m.HandleFunc("POST /v1/messages/delete", h.deviceAuth(h.handleDeleteMessages))
	m.HandleFunc("POST /v1/messages/archive", h.deviceAuth(h.handleArchiveMessages))
	m.HandleFunc("POST /v1/login", h.handleLogin)
	m.HandleFunc("POST /v1/register", h.handleRegister)
	m.HandleFunc("POST /v1/logout", h.deviceAuth(h.handleLogout))
	m.HandleFunc("GET /v1/account", h.deviceAuth(h.handleAccount))
	m.HandleFunc("POST /v1/account/credentials", h.deviceAuth(h.handleCredentials))
	m.HandleFunc("POST /v1/pair-codes", h.deviceAuth(h.handleCreatePairCode))
	m.HandleFunc("GET /v1/pair-codes/{code}", h.deviceAuth(h.handlePairCodeStatus))
	m.HandleFunc("POST /v1/devices/{id}/revoke", h.deviceAuth(h.handleRevokeOwnDevice))
	m.HandleFunc("GET /v1/subscriptions", h.deviceAuth(h.handleSubscriptions))
	m.HandleFunc("PUT /v1/subscriptions/{id}", h.deviceAuth(h.handleSetSubscription))
	m.HandleFunc("POST /v1/presence", h.deviceAuth(h.handlePresence))
	m.HandleFunc("GET /v1/messages", h.deviceAuth(h.handleMessages))
	m.HandleFunc("GET /v1/messages/{id}", h.deviceAuth(h.handleMessage))
	m.HandleFunc("GET /v1/stream", h.deviceAuth(h.handleStream))
	m.HandleFunc("GET /v1/att/{id}", h.deviceAuth(h.handleAtt))
	m.HandleFunc("GET /v1/update", h.deviceAuth(h.handleUpdate))
	m.HandleFunc("GET /v1/update/{id}", h.deviceAuth(h.handleUpdateDownload))
	m.HandleFunc("GET /v1/info", h.handleInfo)
	h.registerE2ERoutes(m)
	m.HandleFunc("PUT /v1/bark", h.deviceAuth(h.handleBarkSet))
	m.HandleFunc("POST /v1/bark/test", h.deviceAuth(h.handleBarkTest))
	m.HandleFunc("GET /ios/gbox.appsrc", h.handleGBoxSource)
	m.HandleFunc("GET /ios/{file}", h.handleIPA)
	m.HandleFunc("GET /icon.png", serveIcon(appleTouchIconPNG))
	// 0.9.0 起没有任何账号或设备能进入管理后台、查看服务器存储与备份：/v1/admin/link、/v1/storage* 已删除（404）。
	// 管理后台只能在服务器上进入（huijian admin-link 或管理令牌登录）
	m.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok\n") })
	m.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { http.Error(w, "not found", 404) })
	return m
}

type ctxKey struct{}

func (h *Hub) deviceAuth(next func(http.ResponseWriter, *http.Request, *Device)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || !strings.HasPrefix(tok, "DT_") {
			apiErr(w, 401, "缺少设备 token")
			return
		}
		d, err := h.st.DeviceByToken(tok)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			// 数据库出错不是「登录失效」：返回 500，客户端稍后重试，不会把设备踢下线
			log.Printf("查询设备失败：%v", err)
			apiErr(w, 500, "服务器暂时无法验证设备，请稍后重试")
			return
		}
		if err != nil || d.Revoked {
			apiErr(w, 401, "设备 token 无效或已吊销")
			return
		}
		if h.st.AccountDisabled(d.UserID) {
			apiErr(w, 403, errDisabled.Error())
			return
		}
		h.st.markActive(d.UserID) // 统计：今天活跃的账号（内存去重，一天只写一次库）
		if !d.LastSeen.Valid || now()-d.LastSeen.Int64 > 60 {
			h.st.TouchDevice(d.ID)
			if fp := clientHeader(r.Header, "Fingerprint"); fp != "" {
				h.st.BackfillFingerprint(d, fp)
			}
		}
		if c := clientLabel(clientHeader(r.Header, "Client")); c != "" && c != d.Client {
			h.st.SetDeviceClient(d.ID, c)
			d.Client = c
		}
		next(w, r, d)
	}
}

// ---------- 发送 ----------

type upFile struct {
	tmp    string
	name   string
	mime   string
	size   int64
	sha256 string
}

func cleanName(n string) string {
	n = filepath.Base(strings.ReplaceAll(n, "\\", "/"))
	n = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || r == '/' {
			return -1
		}
		return r
	}, n)
	if n == "" || n == "." || n == ".." {
		n = "file"
	}
	if r := []rune(n); len(r) > 200 {
		n = string(r[:200])
	}
	return n
}

func (h *Hub) saveTemp(part io.Reader, name, partCT string) (*upFile, error) {
	f, err := os.CreateTemp(h.tmpDir, "up-*")
	if err != nil {
		return nil, err
	}
	defer f.Close()
	br := bufio.NewReaderSize(part, 64<<10)
	head, _ := br.Peek(512)
	hs := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, hs), br)
	if err != nil {
		os.Remove(f.Name())
		return nil, err
	}
	mt := mime.TypeByExtension(strings.ToLower(filepath.Ext(name)))
	if mt == "" && partCT != "" && partCT != "application/octet-stream" {
		mt = partCT
	}
	if mt == "" {
		mt = http.DetectContentType(head)
	}
	return &upFile{tmp: f.Name(), name: name, mime: mt, size: n, sha256: hex.EncodeToString(hs.Sum(nil))}, nil
}

func (h *Hub) handlePush(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		apiErr(w, 405, "只支持 GET/POST")
		return
	}
	ip := h.realIP(r)
	r.Body = http.MaxBytesReader(w, r.Body, h.maxUpload)
	fields := url.Values{}
	for k, v := range r.URL.Query() {
		fields[k] = v
	}
	var files []*upFile
	defer func() {
		for _, f := range files {
			if f.tmp != "" {
				os.Remove(f.tmp)
			}
		}
	}()

	if r.Method == http.MethodPost {
		ct, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
		switch ct {
		case "multipart/form-data":
			mr, err := r.MultipartReader()
			if err != nil {
				apiErr(w, 400, "multipart 解析失败")
				return
			}
			for {
				part, err := mr.NextPart()
				if err == io.EOF {
					break
				}
				if err != nil {
					var mbe *http.MaxBytesError
					if errors.As(err, &mbe) {
						apiErr(w, 413, fmt.Sprintf("请求体超过 %dMB", h.maxUpload>>20))
						return
					}
					apiErr(w, 400, "multipart 读取失败")
					return
				}
				if part.FileName() != "" {
					if len(files) >= 20 {
						apiErr(w, 400, "附件最多 20 个")
						return
					}
					uf, err := h.saveTemp(part, cleanName(part.FileName()), part.Header.Get("Content-Type"))
					if err != nil {
						var mbe *http.MaxBytesError
						if errors.As(err, &mbe) {
							apiErr(w, 413, fmt.Sprintf("请求体超过 %dMB", h.maxUpload>>20))
						} else {
							apiErr(w, 500, "保存附件失败")
						}
						return
					}
					files = append(files, uf)
				} else {
					b, _ := io.ReadAll(io.LimitReader(part, 128<<10))
					fields.Add(part.FormName(), string(b))
				}
			}
		case "application/json":
			var m map[string]any
			if err := json.NewDecoder(io.LimitReader(r.Body, 256<<10)).Decode(&m); err != nil {
				apiErr(w, 400, "JSON 解析失败")
				return
			}
			for k, v := range m {
				switch x := v.(type) {
				case string:
					fields.Set(k, x)
				case float64:
					fields.Set(k, strconv.FormatFloat(x, 'f', -1, 64))
				}
			}
		default:
			if err := r.ParseForm(); err != nil {
				apiErr(w, 400, "表单解析失败")
				return
			}
			for k, v := range r.PostForm {
				fields[k] = v
			}
		}
	}

	// pushkey 也允许放在 Authorization: Bearer PK_xxx
	keyStr := fields.Get("pushkey")
	if keyStr == "" {
		if t, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer "); ok && strings.HasPrefix(t, "PK_") {
			keyStr = t
		}
	}
	keys := splitList(keyStr)
	sendKey := false
	for i, k := range keys { // 加密发送密钥 PK_xxx.e2e.<公钥>：后半段是给发送端加密用的，这里只认 pushkey
		var cut bool
		keys[i], _, cut = strings.Cut(k, e2eSendKeySep)
		sendKey = sendKey || cut
	}
	if len(keys) == 0 {
		apiErr(w, 400, "缺少 pushkey")
		return
	}
	if len(keys) > 20 {
		apiErr(w, 400, "pushkey 最多 20 个")
		return
	}
	var pks []*Pushkey
	seen := map[string]bool{}
	for _, k := range keys {
		if seen[k] {
			continue
		}
		seen[k] = true
		pk, err := h.st.PushkeyByKey(k)
		if err != nil || pk.Revoked {
			time.Sleep(300 * time.Millisecond) // 拖慢暴力猜测
			msg := "pushkey 无效或已吊销"
			if err != nil { // 墓碑只影响提示文字，查询出错时用通用提示
				if retired, _ := keyRetired(h.st.db, k); retired {
					msg = "pushkey 已停用（所属账号已删除，或已换成新的 key）"
				}
			}
			apiErr(w, 403, msg)
			return
		}
		if h.st.AccountDisabled(pk.UserID) {
			apiErr(w, 403, "pushkey 所属账号已停用")
			return
		}
		if !h.pushLimit.Allow("pk:" + strconv.FormatInt(pk.ID, 10)) {
			apiErr(w, 429, "发送太频繁，请稍后再试")
			return
		}
		pks = append(pks, pk)
	}

	text := strings.TrimSpace(fields.Get("text"))
	desp := fields.Get("desp")
	// 端到端加密：标题、正文、附件名都在信封里，服务端只校验格式和钥匙，不解密
	env := strings.TrimSpace(fields.Get("e2e"))
	if env != "" {
		kid, _, err := e2eParseEnvelope(env)
		if err != nil || len(env) > e2eMaxEnvelope {
			apiErr(w, 400, "加密信封格式不对")
			return
		}
		for _, pk := range pks {
			if pk.UserID != pks[0].UserID {
				apiErr(w, 400, "加密消息只能发给同一个账号的 pushkey")
				return
			}
		}
		if !h.st.E2EHasKID(pks[0].UserID, kid) {
			apiErr(w, 400, "加密用的公钥不是这个账号的（钥匙可能已更换）：请在回笺里重新复制加密发送密钥")
			return
		}
		text, desp = e2ePlaceholder, ""
		for i, f := range files { // 附件是密文：真实的名字和类型在信封里
			f.name, f.mime = fmt.Sprintf("encrypted-%d.bin", i+1), "application/octet-stream"
		}
	} else {
		if sendKey { // 用了加密发送密钥却没加密：多半是旧版命令行 / SDK 或 curl，不能让人以为发出去的是加密的
			apiErr(w, 400, "这是加密发送密钥，但消息没有加密：请用新版 huijian 命令行或 Python SDK 发送；只能用 curl 时请改用普通 pushkey（明文发送：服务器收到时能看到内容，随后立即加密保存）")
			return
		}
	}
	if text == "" && len(files) == 0 {
		apiErr(w, 400, "缺少 text")
		return
	}
	sealText := text // 代加密时信封里的标题：和发送端加密一样，为空时由客户端用附件名代替
	if text == "" {
		names := make([]string, len(files))
		for i, f := range files {
			names[i] = f.name
		}
		text = "📎 " + strings.Join(names, "、")
	}
	if len([]rune(text)) > 2000 {
		text = string([]rune(text)[:2000])
	}
	if len(desp) > 64<<10 {
		desp = desp[:64<<10]
	}
	typ := fields.Get("type")
	switch {
	case env != "":
		typ = "e2e" // 真实类型在信封里
	case typ == "" || typ == "markdown":
		typ = "markdown"
	case typ == "text" || typ == "image":
	default:
		apiErr(w, 400, "type 只能是 text / markdown / image")
		return
	}
	prio := 3
	if p := fields.Get("priority"); p != "" {
		v, err := strconv.Atoi(p)
		if err != nil || v < 0 || v > 5 {
			apiErr(w, 400, "priority 取值 0-5")
			return
		}
		prio = v
	}
	topic := strings.TrimSpace(fields.Get("topic"))
	if topic == "" {
		topic = "default"
	}
	thread := strings.TrimSpace(fields.Get("thread"))
	idem := strings.TrimSpace(fields.Get("idem"))
	if len(topic) > 64 || len(thread) > 128 || len(idem) > 64 {
		apiErr(w, 400, "topic 最长 64 字节，thread 最长 128 字节，idem 最长 64 字节")
		return
	}

	// 每个账号一条消息（同一账号的多个 pushkey 只投递一次）：
	// 发送端加密的原样保存；明文发来的由服务器用各自的公钥加密（代加密始终开启）。
	// 0.9.0 起服务器不再保存明文：明文发给还没有钥匙的账号时整条推送返回 403，什么都不存
	type target struct {
		pk   *Pushkey
		seal *ecdh.PublicKey
		msg  NewMessage
	}
	var targets []*target
	done := map[int64]bool{}
	for _, pk := range pks {
		h.st.TouchPushkey(pk.ID)
		if done[pk.UserID] {
			continue
		}
		done[pk.UserID] = true
		t := &target{pk: pk, msg: NewMessage{UserID: pk.UserID, PushkeyID: pk.ID, Topic: topic, Thread: thread, Priority: prio,
			Type: typ, Text: text, Desp: desp, Source: pk.Name, SrcIP: ip, Idem: idem, E2E: env}}
		if env == "" {
			pub, err := h.st.E2EActivePub(pk.UserID)
			if err != nil { // 读不到公钥时不能当成「没开启」存明文
				log.Printf("读取账号 #%d 的公钥失败：%v", pk.UserID, err)
				apiErr(w, 503, "服务器暂时无法加密这条消息，请稍后重试")
				return
			}
			if pub == nil {
				apiErr(w, 403, errNoE2E.Error())
				return
			}
			t.seal = pub
		}
		targets = append(targets, t)
	}
	ids := make([]string, len(targets))
	sent := func(uid, id int64, dup bool, bark *barkPlain) {
		if dup {
			log.Printf("幂等键重复，返回已有消息 #%d", id)
			return
		}
		h.br.Notify(uid)
		go h.forwardBark(uid, id, bark)
	}

	// 1. 代加密的账号：各自加密附件、落盘、写库（写库时核对钥匙仍然启用，被重置时重新加密）
	for i, t := range targets {
		if t.seal == nil {
			continue
		}
		id, dup, err := h.pushSealed(t.seal, t.msg, sealText, files)
		if err != nil {
			var pe *pushError
			if errors.As(err, &pe) {
				apiErr(w, pe.code, pe.msg)
			} else {
				apiErr(w, 500, "写入消息失败")
			}
			return
		}
		ids[i] = strconv.FormatInt(id, 10)
		sent(t.pk.UserID, id, dup, &barkPlain{Text: text, Desp: desp, Type: typ}) // Bark 照旧转发明文（Bark 本来就由服务器转发明文）
	}

	// 2. 发送端密文：附件（已是密文）落盘一次（年/月/日/时分秒_标题/文件名，同样内容只存一份），各账号共用
	var rels []string
	var atts []Attachment
	needFiles := false
	for _, t := range targets {
		needFiles = needFiles || t.seal == nil
	}
	if len(files) > 0 && needFiles {
		var err error
		if rels, err = h.files.save(files, text, time.Now()); err != nil {
			log.Printf("保存附件失败: %v", safeErr(err))
			apiErr(w, 500, "保存附件失败")
			return
		}
		for i, f := range files {
			atts = append(atts, Attachment{Name: f.name, Mime: f.mime, Size: f.size, Sha256: f.sha256, blob: rels[i]})
		}
	}
	removeTemps(files) // 临时文件：用完立即删除
	used := false      // 落盘的附件有没有被写进库（全是幂等重复或写库失败时删掉）
	defer func() {
		if !used {
			h.files.remove(rels)
		}
	}()
	for i, t := range targets {
		if t.seal != nil {
			continue
		}
		t.msg.Files = atts
		id, dup, err := h.st.InsertMessage(t.msg)
		if errors.Is(err, errAccountGone) { // 推送途中账号被删除：不写库，落盘的附件由上面的 defer 删掉
			apiErr(w, 403, err.Error())
			return
		}
		if err != nil {
			log.Printf("写入消息失败: %v", err)
			apiErr(w, 500, "写入消息失败")
			return
		}
		used = used || !dup
		ids[i] = strconv.FormatInt(id, 10)
		sent(t.pk.UserID, id, dup, nil)
	}
	writeJSON(w, 200, map[string]any{"code": 0, "content": map[string]any{"result": ids}})
}

// ---------- 设备 ----------

func (h *Hub) handlePair(w http.ResponseWriter, r *http.Request) {
	if !h.pairLimit.Allow("ip:" + h.realIP(r)) {
		apiErr(w, 429, "尝试太频繁")
		return
	}
	var req struct{ Code, Name, Platform, Fingerprint string }
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&req); err != nil {
		apiErr(w, 400, "JSON 解析失败")
		return
	}
	req.Name = cleanLabel(req.Name, 64)
	if req.Name == "" {
		req.Name = "未命名设备"
	}
	req.Platform = cleanLabel(req.Platform, 16)
	if req.Platform == "" {
		req.Platform = "unknown"
	}
	d, tok, reused, keyWrap, err := h.st.PairWithKey(strings.TrimSpace(req.Code), pairReq{Name: req.Name, Platform: req.Platform,
		Fingerprint: req.Fingerprint, IP: h.realIP(r), Client: clientLabel(clientHeader(r.Header, "Client"))})
	if err != nil {
		time.Sleep(500 * time.Millisecond)
		apiErr(w, 403, err.Error())
		return
	}
	if reused {
		log.Printf("设备重新配对（按指纹复用原记录）: %s (%s/%s)", d.ID, d.Name, d.Platform)
	} else {
		log.Printf("新设备配对: %s (%s/%s)", d.ID, d.Name, d.Platform)
	}
	out := map[string]any{"device_id": d.ID, "name": d.Name, "token": tok, "reused": reused}
	if keyWrap != "" {
		out["key_wrap"] = keyWrap // 0.10.0：用一次性钥匙锁住的账号私钥，服务器解不开（e2ee-client.md §12）
	}
	writeJSON(w, 200, out)
}

func (h *Hub) handleMe(w http.ResponseWriter, r *http.Request, d *Device) {
	writeJSON(w, 200, map[string]any{"device_id": d.ID, "name": d.Name, "platform": d.Platform,
		"can_admin": false, "admin_url": "", // 0.9.0 起恒为 false / 空：没有账号能进入管理后台，保留字段兼容旧客户端
		"account": h.accountJSON(d), "away_silent": d.AwaySilent,
		"bark": h.st.BarkConfig(d.ID).json()})
}

// adminURL：浏览器访问管理后台的地址（一次性登录链接的前缀）。管理端口本身只说 http。按优先级：
//  1. HUIJIAN_ADMIN_URL（管理后台放在 HTTPS 反向代理后面等情况）
//  2. HUIJIAN_ADMIN_ADDR 明确写了监听 IP（例如只监听内网 / WG 地址）——链接必须指向它
//  3. HUIJIAN_ADMIN_BIND（docker 端口映射到宿主机的地址，例如 127.0.0.1 = 只能 SSH 隧道访问）
//  4. HUIJIAN_PUBLIC_URL 的主机名，或本次请求的主机名（公网 IP 直连的部署）
//
// r 为 nil（命令行）且无法推导时返回空。
func adminURL(r *http.Request) string {
	if u := env("HUIJIAN_ADMIN_URL", ""); u != "" {
		return strings.TrimRight(u, "/")
	}
	port := externalPort("HUIJIAN_ADMIN_PORT", "HUIJIAN_ADMIN_ADDR", "8791")
	host := specificHost(env("HUIJIAN_ADMIN_ADDR", "127.0.0.1:8791")) // 与实际监听的默认值一致
	if host == "" {
		host = specificHost(env("HUIJIAN_ADMIN_BIND", "") + ":0")
	}
	if host == "" {
		if pu := env("HUIJIAN_PUBLIC_URL", ""); pu != "" {
			if u, err := url.Parse(pu); err == nil {
				host = u.Hostname()
			}
		}
	}
	if host == "" && r != nil {
		host = requestHost(r)
	}
	if host == "" {
		return ""
	}
	return "http://" + net.JoinHostPort(host, port)
}

// specificHost：监听地址里明确写了的 IP / 主机名；0.0.0.0、:: 或没写时返回空
func specificHost(addr string) string {
	h := hostOf(addr)
	if h == "0.0.0.0" || h == "::" || h == "[::]" {
		return ""
	}
	return h
}

// requestHost：请求里的主机名（不含端口）；Host 为空或不像主机名时返回空
func requestHost(r *http.Request) string {
	h := r.Host
	if hh, _, err := net.SplitHostPort(h); err == nil {
		h = hh
	}
	h = strings.Trim(h, "[]")
	if h == "" || len(h) > 253 || strings.ContainsAny(h, "/\\@?#<>\"' ") {
		return ""
	}
	return h
}

func portOf(addr, def string) string {
	if _, p, err := net.SplitHostPort(addr); err == nil && p != "" {
		return p
	}
	return def
}

// externalPort：对外端口。容器里监听的端口和宿主机映射出去的端口可能不同，
// docker compose 会把映射后的端口通过 HUIJIAN_PUBLIC_PORT / HUIJIAN_ADMIN_PORT 传进来。
func externalPort(portEnv, addrEnv, def string) string {
	if p := env(portEnv, ""); p != "" {
		return p
	}
	return portOf(env(addrEnv, ""), def)
}

// longPollMax：长轮询最长挂起秒数，HUIJIAN_LONGPOLL_MAX 可调（55–3600，默认 600）。
// 反向代理的读超时（nginx proxy_read_timeout）要比它长，否则会被代理提前切断；客户端遇到切断会自动把等待时长调低。
func longPollMax() int {
	v, err := strconv.Atoi(strings.TrimSpace(env("HUIJIAN_LONGPOLL_MAX", "")))
	switch {
	case err != nil:
		return 600
	case v < 55:
		return 55
	case v > 3600:
		return 3600
	}
	return v
}

func parseSince(r *http.Request) int64 {
	s := r.URL.Query().Get("since")
	if s == "" {
		s = r.Header.Get("Last-Event-ID")
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return -1
	}
	return v
}

// GET /v1/messages/{id}：取单条消息（格式同列表）。0.8.0 起客户端收到 kind "sealed" 的变更后用它重新拉取被补加密的消息
func (h *Hub) handleMessage(w http.ResponseWriter, r *http.Request, d *Device) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		apiErr(w, 400, "消息 id 不对")
		return
	}
	msgs, err := h.st.Messages(d.UserID, d.ID, id-1, 1)
	if err != nil {
		apiErr(w, 500, "查询失败")
		return
	}
	if len(msgs) == 0 || msgs[0].ID != id {
		apiErr(w, 404, "消息不存在")
		return
	}
	h.decorate(d, msgs)
	attachDocs(msgs)
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, 200, map[string]any{"message": msgs[0]})
}

func (h *Hub) handleMessages(w http.ResponseWriter, r *http.Request, d *Device) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	since := parseSince(r)
	// 长轮询：since 之后暂时没有消息时最多挂起 wait 秒，有新消息立即返回。
	// 每个响应都是完整结束的，能穿过会缓冲流式响应的代理/杀毒软件（例如对 HTTPS 做中间人扫描的杀毒软件）。
	// 0.6.4 起上限由 55 秒放宽到 longPollMax()（默认 10 分钟）：客户端按所在网络自适应，等得越久，手机被唤醒的次数越少
	wait, _ := strconv.Atoi(r.URL.Query().Get("wait"))
	if m := longPollMax(); wait > m {
		wait = m
	}
	var ch chan struct{}
	if wait > 0 && since >= 0 {
		ch = h.br.Subscribe(d.UserID, d.ID) // 先订阅再查询，避免漏掉查询间隙到达的消息
		defer h.br.Unsubscribe(d.UserID, ch)
	}
	// query 返回可见消息和「扫描到哪里」：本机设为不接收的消息也算扫过，游标照样往前走，
	// 否则高频的「不接收」key 会让每次查询都重扫越来越长的积压
	next := since
	query := func() ([]Message, error) {
		top := h.st.MaxMessageID(d.UserID) // 先取上界再查：单连接串行写入，≤ top 的消息此时都已提交
		msgs, err := h.st.Messages(d.UserID, d.ID, next, limit)
		if err != nil {
			return nil, err
		}
		if len(msgs) == limit {
			next = msgs[len(msgs)-1].ID
		} else if top > next {
			next = top
		}
		return msgs, nil
	}
	// 0.5.4 起：带 changes_since 时一并返回之后的删除 / 归档变更（同账号其他设备的操作），有变更也立即返回
	cs, hasCS := int64(0), r.URL.Query().Has("changes_since")
	if hasCS {
		cs, _ = strconv.ParseInt(r.URL.Query().Get("changes_since"), 10, 64)
	}
	var changes []MsgChange
	changesNext, changesReset := cs, false
	fetchChanges := func() error {
		if !hasCS {
			return nil
		}
		c, n, reset, err := h.st.Changes(d.UserID, cs, 500)
		if err != nil {
			return err
		}
		changes, changesNext, changesReset = c, n, reset
		return nil
	}
	var msgs []Message
	var err error
	if err := fetchChanges(); err != nil {
		apiErr(w, 500, "查询失败")
		return
	}
	if since >= 0 {
		msgs, err = query()
	} else {
		msgs, err = h.st.Messages(d.UserID, d.ID, since, limit)
		if len(msgs) > 0 {
			next = msgs[len(msgs)-1].ID
		}
	}
	if err != nil {
		apiErr(w, 500, "查询失败")
		return
	}
	if len(msgs) == 0 && len(changes) == 0 && !changesReset && ch != nil {
		t := time.NewTimer(time.Duration(wait) * time.Second)
		defer t.Stop()
	wait:
		for len(msgs) == 0 && len(changes) == 0 && !changesReset { // 本机「不接收」的 key 发来的消息不会唤醒客户端，继续等
			select {
			case _, open := <-ch:
				if !open { // 服务端正在关闭
					break wait
				}
				// 唤醒时先确认这台设备还有效：注销全部登录、移除设备、删除账号、停用账号后，
				// 挂着的长轮询不能再带回新消息（和 /v1/stream 一样）
				if !h.st.DeviceActive(d.ID) {
					if h.st.AccountDisabled(d.UserID) {
						apiErr(w, 403, errDisabled.Error())
					} else {
						apiErr(w, 401, "设备已失效，请重新登录")
					}
					return
				}
				// 先取变更再查消息（和第一次查询顺序一致）：同一个响应里不会出现「消息还在、删除它的变更却漏掉」
				if err := fetchChanges(); err != nil {
					apiErr(w, 500, "查询失败")
					return
				}
				if msgs, err = query(); err != nil {
					apiErr(w, 500, "查询失败")
					return
				}
			case <-t.C:
				break wait
			case <-r.Context().Done():
				return
			}
		}
	}
	h.decorate(d, msgs)
	attachDocs(msgs)
	w.Header().Set("Cache-Control", "no-store")
	h.latestBuildHeader(w, d)
	resp := map[string]any{"messages": msgs}
	if since >= 0 {
		resp["next_since"] = next // 0.5.0 起：下次请求用它做 since（旧客户端忽略，继续用最后一条消息的 id）
	}
	if hasCS {
		resp["changes"] = changes
		resp["changes_next"] = changesNext
		resp["changes_epoch"] = h.st.ChangesEpoch()
		if changesReset {
			resp["changes_reset"] = true // 离线太久，变更记录已清理：客户端需要重新对账（GET /v1/messages/state）
		}
	}
	writeJSON(w, 200, resp)
}

// handleStream：SSE。先补发 since 之后的消息，再实时推送；每 20 秒心跳。
func (h *Hub) handleStream(w http.ResponseWriter, r *http.Request, d *Device) {
	fl, ok := w.(http.Flusher)
	if !ok {
		apiErr(w, 500, "不支持流式响应")
		return
	}
	since := parseSince(r)
	if since < 0 {
		// 没有游标的新客户端：从当前最新处开始，历史用 /v1/messages 拉
		latest, _ := h.st.Messages(d.UserID, d.ID, -1, 1)
		since = 0
		if len(latest) > 0 {
			since = latest[0].ID
		}
	}
	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(200)
	fmt.Fprintf(w, "retry: 3000\nevent: hello\ndata: {\"since\":%d}\n\n", since)
	fl.Flush()

	ch := h.br.Subscribe(d.UserID, d.ID)
	defer h.br.Unsubscribe(d.UserID, ch)

	send := func() error {
		if !h.st.DeviceActive(d.ID) { // 设备被吊销、退出登录、账号被停用后断开
			return errors.New("device inactive")
		}
		for {
			msgs, err := h.st.Messages(d.UserID, d.ID, since, 100)
			h.decorate(d, msgs)
			attachDocs(msgs)
			if err != nil {
				return err
			}
			for _, m := range msgs {
				b, _ := json.Marshal(m)
				if _, err := fmt.Fprintf(w, "id: %d\nevent: message\ndata: %s\n\n", m.ID, b); err != nil {
					return err
				}
				since = m.ID
			}
			fl.Flush()
			if len(msgs) < 100 {
				return nil
			}
		}
	}
	if err := send(); err != nil {
		return
	}
	tick := time.NewTicker(20 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case _, ok := <-ch:
			if !ok {
				return
			}
			if err := send(); err != nil {
				return
			}
		case <-tick.C:
			if _, err := io.WriteString(w, ": ping\n\n"); err != nil {
				return
			}
			fl.Flush()
		}
	}
}

func (h *Hub) handleAtt(w http.ResponseWriter, r *http.Request, d *Device) {
	h.serveAttachment(w, r, d.UserID, r.PathValue("id"))
}

func (h *Hub) serveAttachment(w http.ResponseWriter, r *http.Request, userID int64, attID string) {
	a, err := h.st.AttachmentFor(userID, attID)
	if err != nil {
		if msgID, ok := h.st.SealedAttachment(userID, attID); ok { // 0.8.0 补加密换掉的旧 id：绝不返回密文，让客户端重新拉取消息
			writeJSON(w, 410, map[string]any{"code": 410, "error": "附件已加密，请刷新消息", "reason": "sealed", "message_id": msgID})
			return
		}
		apiErr(w, 404, "附件不存在")
		return
	}
	// 文件找不到也是 410，用 reason 区分（0.8.0 起）：missing = 文件丢失，sealed = 已补加密
	missing := func(msg string) {
		writeJSON(w, 410, map[string]any{"code": 410, "error": msg, "reason": "missing"})
	}
	p, ok := h.files.find(a.blob)
	if !ok {
		missing("附件文件已丢失（附件目录不可用或文件被删除）")
		return
	}
	f, err := os.Open(p)
	if err != nil {
		missing("附件文件已丢失")
		return
	}
	defer f.Close()
	fi, _ := f.Stat()
	w.Header().Set("Content-Type", a.Mime)
	w.Header().Set("Content-Disposition", "attachment; filename*=UTF-8''"+url.PathEscape(a.Name))
	setServerHeader(w.Header(), "Sha256", a.Sha256)
	w.Header().Set("X-Beacon-Sha256", a.Sha256) // 兼容旧客户端
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "private, max-age=0")
	http.ServeContent(w, r, a.Name, fi.ModTime(), f)
}
