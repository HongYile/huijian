package main

// 服务器代加密（0.8.0，docs/e2ee.md「服务器代加密」，始终开启）：账号开启了加密时，用普通 pushkey 发来的明文消息
// 在写库之前用账号的 active 公钥封成和发送端加密完全一样的 hje1 信封，附件按 HJF1 分块加密（每个附件一把随机钥匙，钥匙在信封里）。
// 数据库、备份、附件目录（包括 NAS）里只有密文；明文只在处理这次请求的内存和上传临时文件里，临时文件用完立即删除。
// 服务器在收到的那一刻看得到内容，所以比发送端加密弱；消息带 sealed: "server" 让客户端如实显示。

import (
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"io/fs"
	"log"
	"os"
	"sync"
	"time"
)

const sealedServer = "server"

// sealFiles：把上传的明文临时文件逐个加密成新的临时文件（名字、类型换成占位的），返回密文文件和信封里的附件信息。
// 失败时已删掉这次生成的密文临时文件；明文临时文件由调用方删除
func (h *Hub) sealFiles(files []*upFile) ([]*upFile, []e2eAtt, error) {
	out := make([]*upFile, 0, len(files))
	atts := make([]e2eAtt, 0, len(files))
	for i, f := range files {
		key := make([]byte, 32)
		if _, err := rand.Read(key); err != nil {
			removeTemps(out)
			return nil, nil, err
		}
		ef, err := h.encryptTemp(key, f.tmp)
		if err != nil {
			removeTemps(out)
			return nil, nil, err
		}
		ef.name, ef.mime = fmt.Sprintf("encrypted-%d.bin", i+1), "application/octet-stream"
		out = append(out, ef)
		atts = append(atts, e2eAtt{Name: f.name, Mime: f.mime, Size: f.size, Key: b64.EncodeToString(key)})
	}
	return out, atts, nil
}

// encryptTemp：src 加密后写到 tmpDir 里的新临时文件；sha256 和大小都是密文的（按明文去重会泄露「两条消息附件相同」）
func (h *Hub) encryptTemp(key []byte, src string) (*upFile, error) {
	in, err := os.Open(src)
	if err != nil {
		return nil, err
	}
	defer in.Close()
	out, err := os.CreateTemp(h.tmpDir, "seal-*")
	if err != nil {
		return nil, err
	}
	hs := sha256.New()
	cw := &countWriter{w: io.MultiWriter(out, hs)}
	err = e2eEncryptFile(key, in, cw)
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(out.Name())
		return nil, err
	}
	return &upFile{tmp: out.Name(), size: cw.n, sha256: hexSum(hs)}, nil
}

type countWriter struct {
	w io.Writer
	n int64
}

func (c *countWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += int64(n)
	return n, err
}

func hexSum(h hash.Hash) string { return hex.EncodeToString(h.Sum(nil)) }

func removeTemps(fs []*upFile) {
	for _, f := range fs {
		if f.tmp != "" {
			os.Remove(f.tmp)
			f.tmp = ""
		}
	}
}

// sealNewMessage：把一条明文 NewMessage 换成代加密的形式（标题换占位文字、正文清空、type=e2e、sealed=server）。
// atts 是信封里的附件信息（和 m.Files 里的密文按顺序对应）。SealKID 让写库的事务核对这把钥匙仍然启用
func sealNewMessage(pub *ecdh.PublicKey, m *NewMessage, text string, atts []e2eAtt) error {
	env, err := e2eSealPayload(pub, text, m.Desp, m.Type, atts)
	if err != nil {
		return err
	}
	m.Text, m.Desp, m.Type, m.E2E, m.Sealed, m.SealKID = e2ePlaceholder, "", "e2e", env, sealedServer, e2eKID(pub.Bytes())
	return nil
}

// pushError：代加密失败时给发送端的状态码和提示
type pushError struct {
	code int
	msg  string
}

func (e *pushError) Error() string { return e.msg }

// pushSealed：代加密一条推送并写库。写库的事务里核对加密用的钥匙仍然启用：
// 加密和写库之间账号被重置过加密时，删掉刚存的密文，重读公钥重新加密（最多 3 次）
func (h *Hub) pushSealed(pub *ecdh.PublicKey, m NewMessage, sealText string, files []*upFile) (int64, bool, error) {
	if m.Idem != "" { // 幂等键已存在：不再加密、不再保存附件
		if id := h.st.MessageIDByIdem(m.UserID, m.Idem); id != 0 {
			return id, true, nil
		}
	}
	for attempt := 0; attempt < 3; attempt++ {
		msg := m
		enc, atts, err := h.sealFiles(files)
		if err != nil {
			log.Printf("代加密附件失败（账号 #%d）：%v", m.UserID, safeErr(err))
			return 0, false, &pushError{500, "加密附件失败"}
		}
		if err := sealNewMessage(pub, &msg, sealText, atts); err != nil {
			removeTemps(enc)
			return 0, false, &pushError{400, err.Error()}
		}
		var rels []string
		if len(enc) > 0 { // 目录名用占位标题：附件目录（可能在 NAS 上）里不出现明文标题
			if rels, err = h.files.save(enc, e2ePlaceholder, time.Now()); err != nil {
				removeTemps(enc)
				log.Printf("保存附件失败（账号 #%d）：%v", m.UserID, safeErr(err))
				return 0, false, &pushError{500, "保存附件失败"}
			}
			for i, f := range enc {
				msg.Files = append(msg.Files, Attachment{Name: f.name, Mime: f.mime, Size: f.size, Sha256: f.sha256, blob: rels[i]})
			}
		}
		id, dup, err := h.st.InsertMessage(msg)
		if err == nil && !dup {
			return id, false, nil
		}
		h.files.remove(rels) // 没有写进库（幂等键并发重复 / 写库失败 / 钥匙换了）：刚存的密文文件删掉
		if err == nil {
			return id, true, nil
		}
		if !errors.Is(err, errKeyChanged) {
			log.Printf("写入消息失败（账号 #%d）：%v", m.UserID, err)
			return 0, false, &pushError{500, "写入消息失败"}
		}
		if pub, err = h.st.E2EActivePub(m.UserID); err != nil || pub == nil {
			return 0, false, &pushError{503, errKeyChanged.Error()}
		}
	}
	return 0, false, &pushError{503, errKeyChanged.Error()}
}

// insertServerMessage：服务端自己生成的消息（管理后台的测试消息、系统通知）。账号开启了加密时同样代加密；
// 读不到公钥（数据库出错）时返回错误，不存明文
func (h *Hub) insertServerMessage(m NewMessage) (int64, bool, error) {
	if m.E2E != "" {
		return h.st.InsertMessage(m)
	}
	for attempt := 0; attempt < 3; attempt++ {
		pub, err := h.st.E2EActivePub(m.UserID)
		if err != nil {
			return 0, false, err
		}
		msg := m
		if pub != nil {
			if err := sealNewMessage(pub, &msg, m.Text, nil); err != nil {
				return 0, false, err
			}
		}
		id, dup, err := h.st.InsertMessage(msg)
		if !errors.Is(err, errKeyChanged) {
			return id, dup, err
		}
	}
	return 0, false, errKeyChanged
}

// safeErr：去掉错误里的文件路径（附件路径里有明文标题和文件名，不能进日志）
func safeErr(err error) error {
	var pe *fs.PathError
	if errors.As(err, &pe) {
		return fmt.Errorf("%s: %w", pe.Op, pe.Err)
	}
	var le *os.LinkError
	if errors.As(err, &le) {
		return fmt.Errorf("%s: %w", le.Op, le.Err)
	}
	return err
}

// ---------- 补加密：开启加密以前存下的明文消息 ----------
//
// 账号还没有钥匙时（新建后还没有客户端用密码登录过、或者开启加密以前的历史）收到的消息是明文。
// 开启加密后由服务器补加密：和代加密一样的信封和附件格式，消息标 sealed: "server"，消息 id 不变；
// 附件换成新 id（旧 id 下载返回 410「附件已加密，请刷新消息」，绝不返回密文），并记一条 kind "sealed" 的变更，
// 已同步过这条消息的设备据此重新拉取。
// 附件读不到（NAS 掉线、文件被手动删掉）的消息先跳过、保持明文，下次再试。
// 旧的明文附件文件在同一个事务里登记到 pending_unlink，提交后删除，删不掉的启动时和定时重试。
// 已经同步到各设备的本地副本不受影响；之前做的备份里仍有明文（附件镜像只增不删），需要的话手动清理。

const changeSealed = "sealed" // 0.8.0：这条消息被服务器补加密了（id 是消息 id），客户端重新拉取

var backlogLocks sync.Map // userID → *sync.Mutex：同一账号同时只跑一个补加密

// startSealBacklog：在后台补加密（开启加密、重置加密成功后，明文消息写进已开启加密的账号时调用）
func (h *Hub) startSealBacklog(userID int64) {
	go func() {
		n, skipped := h.sealBacklog(userID)
		if n > 0 || skipped > 0 {
			log.Printf("账号 #%d 补加密明文消息 %d 条，跳过 %d 条（附件暂时读不到，下次再试）", userID, n, skipped)
		}
	}()
}

// startAllSealBacklogs：服务启动时，先重试没删掉的旧明文文件，再给所有已开启加密、还有明文消息的账号补加密
func (h *Hub) startAllSealBacklogs() {
	h.unlinkPending(nil)
	rows, err := h.st.db.Query(`SELECT DISTINCT m.user_id FROM messages m JOIN e2e_keys k ON k.user_id=m.user_id AND k.active=1 WHERE m.e2e=''`)
	if err != nil {
		log.Printf("查询待补加密的账号失败：%v", err)
		return
	}
	var ids []int64
	for rows.Next() {
		var id int64
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	go func() {
		for _, id := range ids {
			n, skipped := h.sealBacklog(id)
			log.Printf("账号 #%d 补加密明文消息 %d 条，跳过 %d 条", id, n, skipped)
		}
	}()
}

// sealBacklog：把账号的明文消息逐条补加密，返回加密了几条、跳过了几条
func (h *Hub) sealBacklog(userID int64) (sealed, skipped int) {
	mu, _ := backlogLocks.LoadOrStore(userID, &sync.Mutex{})
	mu.(*sync.Mutex).Lock()
	defer mu.(*sync.Mutex).Unlock()
	pub, err := h.st.E2EActivePub(userID)
	if err != nil {
		log.Printf("补加密：读取账号 #%d 的公钥失败：%v", userID, err)
		return 0, 0
	}
	if pub == nil {
		return 0, 0
	}
	after := int64(0)
	for {
		var ids []int64
		rows, err := h.st.db.Query(`SELECT id FROM messages WHERE user_id=? AND e2e='' AND id>? ORDER BY id LIMIT 200`, userID, after)
		if err != nil {
			log.Printf("补加密：查询账号 #%d 的明文消息失败：%v", userID, err)
			break
		}
		for rows.Next() {
			var id int64
			if rows.Scan(&id) == nil {
				ids = append(ids, id)
			}
		}
		rows.Close()
		if len(ids) == 0 {
			break
		}
		for _, id := range ids {
			after = id
			for attempt := 0; ; attempt++ {
				ok, err := h.sealStored(userID, id, pub)
				if errors.Is(err, errKeyChanged) && attempt < 3 { // 补加密途中账号被重置：换成新的公钥重来
					if pub, err = h.st.E2EActivePub(userID); err != nil || pub == nil {
						return
					}
					continue
				}
				switch {
				case err != nil:
					skipped++
					log.Printf("补加密消息 #%d 失败：%v", id, safeErr(err))
				case ok:
					sealed++
				}
				break
			}
		}
	}
	if sealed > 0 {
		// secure_delete 已把旧内容在数据库页里清零；再把 WAL 里的旧页写回并截断，磁盘上不留明文
		h.st.truncateWAL("补加密")
	}
	h.unlinkPending(nil)
	return
}

// sealStored：补加密一条已经存下的明文消息。ok=false 且 err=nil 表示它已经不是明文（被别处处理或删掉了）；
// errKeyChanged 表示 pub 已经停用，要换新公钥重来
func (h *Hub) sealStored(userID, msgID int64, pub *ecdh.PublicKey) (ok bool, err error) {
	// 和「搬回暂存附件」（relocate）互斥：搬文件会改附件路径，补加密要按读到的路径删旧文件
	h.files.moveMu.Lock()
	defer h.files.moveMu.Unlock()
	var typ, text, desp string
	var created int64
	if err := h.st.db.QueryRow(`SELECT type, text, desp, created_at FROM messages WHERE id=? AND user_id=? AND e2e=''`, msgID, userID).
		Scan(&typ, &text, &desp, &created); err != nil {
		return false, nil
	}
	type oldAtt struct {
		id, blob, name, mime string
	}
	var olds []oldAtt
	rows, err := h.st.db.Query(`SELECT id, blob, name, mime FROM attachments WHERE message_id=? ORDER BY rowid`, msgID)
	if err != nil {
		return false, err
	}
	for rows.Next() {
		var a oldAtt
		if err := rows.Scan(&a.id, &a.blob, &a.name, &a.mime); err != nil {
			rows.Close()
			return false, err
		}
		olds = append(olds, a)
	}
	rows.Close()

	// 附件：逐个加密到临时文件，再按消息时间存进附件目录（目录名用占位标题）
	var enc []*upFile
	var atts []e2eAtt
	defer func() { removeTemps(enc) }()
	for i, a := range olds {
		p, found := h.files.find(a.blob)
		if !found {
			return false, fmt.Errorf("附件 %s 读不到", a.id)
		}
		st, err := os.Stat(p)
		if err != nil {
			return false, fmt.Errorf("附件 %s：%w", a.id, safeErr(err))
		}
		key := make([]byte, 32)
		if _, err := rand.Read(key); err != nil {
			return false, err
		}
		ef, err := h.encryptTemp(key, p)
		if err != nil {
			return false, fmt.Errorf("附件 %s：%w", a.id, safeErr(err))
		}
		ef.name, ef.mime = fmt.Sprintf("encrypted-%d.bin", i+1), "application/octet-stream"
		enc = append(enc, ef)
		atts = append(atts, e2eAtt{Name: a.name, Mime: a.mime, Size: st.Size(), Key: b64.EncodeToString(key)})
	}
	env, err := e2eSealPayload(pub, text, desp, typ, atts)
	if err != nil {
		return false, err
	}
	var rels []string
	if len(enc) > 0 {
		if rels, err = h.files.save(enc, e2ePlaceholder, time.Unix(created, 0)); err != nil {
			return false, safeErr(err)
		}
	}
	committed := false
	defer func() {
		if !committed {
			h.files.remove(rels) // 没写进数据库：新存的密文文件删掉
		}
	}()
	tx, err := h.st.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	if active, err := kidActive(tx, userID, e2eKID(pub.Bytes())); err != nil {
		return false, err
	} else if !active {
		return false, errKeyChanged
	}
	res, err := tx.Exec(`UPDATE messages SET type='e2e', text=?, desp='', e2e=?, sealed=? WHERE id=? AND user_id=? AND e2e=''`,
		e2ePlaceholder, env, sealedServer, msgID, userID)
	if err != nil {
		return false, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return false, nil
	}
	at := now()
	// 附件换新 id：已同步过这条消息的设备拿着旧 id 下载时得到 410（而不是悄悄拿到密文），收到 sealed 变更后重新拉取
	for i, a := range olds {
		if _, err := tx.Exec(`DELETE FROM attachments WHERE id=?`, a.id); err != nil {
			return false, err
		}
		if _, err := tx.Exec(`INSERT INTO attachments(id,message_id,blob,name,mime,size,sha256) VALUES(?,?,?,?,?,?,?)`,
			"a_"+randHex(16), msgID, rels[i], enc[i].name, enc[i].mime, enc[i].size, enc[i].sha256); err != nil {
			return false, err
		}
		if _, err := tx.Exec(`INSERT OR REPLACE INTO sealed_atts(id,user_id,message_id,at) VALUES(?,?,?,?)`, a.id, userID, msgID, at); err != nil {
			return false, err
		}
	}
	// 旧的明文附件：没有别的附件记录再用它（同内容去重时可能共用）就登记待删，提交后删除
	var orphans []string
	for _, a := range olds {
		var n int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM attachments WHERE blob=?`, a.blob).Scan(&n); err != nil {
			return false, err
		}
		if n == 0 {
			if _, err := tx.Exec(`INSERT OR IGNORE INTO pending_unlink(blob,at) VALUES(?,?)`, a.blob, at); err != nil {
				return false, err
			}
			orphans = append(orphans, a.blob)
		}
	}
	if err := recordChanges(tx, userID, []int64{msgID}, changeSealed, 0); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	committed = true
	forgetDoc(msgID)
	if h.br != nil {
		h.br.Notify(userID) // 在线设备马上收到 sealed 变更
	}
	if len(orphans) > 0 {
		h.unlinkPending(orphans)
	}
	return true, nil
}

// unlinkPending：删除登记待删的旧明文附件文件（only 为 nil 时处理全部）。删掉或确认已不存在才清记录；
// 删之前再确认没有附件记录重新引用它
func (h *Hub) unlinkPending(only []string) {
	blobs := only
	if blobs == nil {
		rows, err := h.st.db.Query(`SELECT blob FROM pending_unlink ORDER BY at`)
		if err != nil {
			return
		}
		for rows.Next() {
			var b string
			if rows.Scan(&b) == nil {
				blobs = append(blobs, b)
			}
		}
		rows.Close()
	}
	failed := 0
	for _, b := range blobs {
		var refs int
		h.st.db.QueryRow(`SELECT COUNT(*) FROM attachments WHERE blob=?`, b).Scan(&refs)
		if refs == 0 && !h.files.removeBlob(b) {
			failed++
			continue
		}
		h.st.db.Exec(`DELETE FROM pending_unlink WHERE blob=?`, b)
	}
	if failed > 0 {
		log.Printf("有 %d 个旧明文附件文件暂时删不掉（附件目录不可用或文件被占用），稍后重试", failed)
	}
}

// SealedAttachment：attID 是不是补加密时换掉的旧附件 id，是的话返回所属的消息 id
func (s *Store) SealedAttachment(userID int64, attID string) (int64, bool) {
	var msgID int64
	err := s.db.QueryRow(`SELECT message_id FROM sealed_atts WHERE id=? AND user_id=?`, attID, userID).Scan(&msgID)
	return msgID, err == nil
}

// truncateWAL：把 WAL 里的旧页写回数据库并截断（删掉或补加密的明文不留在 WAL 里）。
// 有读事务（例如正在备份）时 checkpoint 会被挡住：记日志，在后台每 5 秒重试，最多 10 分钟
func (s *Store) truncateWAL(why string) {
	try := func() bool {
		var busy, logN, ckpt int
		if err := s.db.QueryRow(`PRAGMA wal_checkpoint(TRUNCATE)`).Scan(&busy, &logN, &ckpt); err != nil {
			log.Printf("%s：WAL checkpoint 失败：%v", why, err)
			return false
		}
		return busy == 0
	}
	if try() {
		return
	}
	log.Printf("%s：WAL checkpoint 被占用（可能正在备份），稍后重试", why)
	go func() {
		for i := 0; i < 120; i++ {
			time.Sleep(5 * time.Second)
			if try() {
				log.Printf("%s：WAL checkpoint 重试成功", why)
				return
			}
		}
		log.Printf("%s：WAL checkpoint 一直被占用，WAL 里的旧页要等下次 checkpoint 才清掉", why)
	}()
}
