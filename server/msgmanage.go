package main

// 消息管理：删除（从账号删除，附件文件一起删）、归档状态，以及把这些变化同步给同账号的其他设备。
//
// 归档状态 messages.archive：
//   0 = 自动（客户端按「超过 N 天自动归档」显示在归档里，收藏的除外）
//   1 = 手动归档
//   2 = 保留在收件箱（从归档里恢复的，不再自动归档）
//
// 变更记录 msg_changes：每次删除 / 改归档状态写一条（seq 递增）。客户端长轮询时带 changes_since，
// 服务端返回之后的变更；有新变更时立即唤醒长轮询。记录保留 90 天，客户端离线更久时返回 changes_reset，
// 客户端用 GET /v1/messages/state 重新对账。

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const msgManageSchema = `
CREATE TABLE IF NOT EXISTS msg_changes(
  seq INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, msg_id INTEGER NOT NULL,
  kind TEXT NOT NULL, state INTEGER NOT NULL DEFAULT 0, at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS idx_changes_user ON msg_changes(user_id, seq);
CREATE INDEX IF NOT EXISTS idx_changes_at ON msg_changes(at);
CREATE INDEX IF NOT EXISTS idx_att_blob ON attachments(blob);
`

const (
	archiveAuto = 0
	archiveOn   = 1
	archiveKeep = 2

	changesKeep   = 90 * 24 * time.Hour
	maxManageIDs  = 1000
	changeDelete  = "delete"
	changeArchive = "archive"
	// 0.6.1 起：账号设置的变更（id 都是 0），客户端收到后重新拉取对应的设置
	changeKeys    = "keys"    // pushkey 新建、改名、换 key、吊销、删除
	changeDevices = "devices" // 设备加入、改名、移除、管理权限（只有本机能改的接收规则、离开静音、Bark 设置不广播）
	changeAccount = "account" // 用户名、密码、账号停用
	changeE2E     = "e2e"     // 端到端加密：开启、设备请求批准 / 已批准、只接受加密消息（0.7.0 起）
)

// settingsChanged：账号的 key / 设备 / 账户设置改了以后记一条变更（id 0），并唤醒这个账号在线设备的长轮询，
// 其他设备马上重新拉取。管理后台和设备接口的修改都走这里。记录失败不影响修改本身（客户端下次打开相应页面也会刷新）。
func (s *Store) settingsChanged(userID int64, kind string) {
	if userID <= 0 {
		return
	}
	at := now()
	if _, err := s.db.Exec(`INSERT INTO msg_changes(user_id,msg_id,kind,state,at) VALUES(?,0,?,0,?)`, userID, kind, at); err != nil {
		log.Printf("记录设置变更失败：%v", err)
	}
	s.db.Exec(`DELETE FROM msg_changes WHERE at<?`, at-int64(changesKeep/time.Second))
	if s.notify != nil {
		s.notify(userID)
	}
}

func (s *Store) migrateMessages() error {
	if err := s.addColumn("messages", "archive", "INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	if _, err := s.db.Exec(msgManageSchema); err != nil {
		return err
	}
	if s.GetKV(kvChangesEpoch) == "" {
		s.SetKV(kvChangesEpoch, randHex(8))
	}
	return nil
}

// 变更游标的纪元：新建数据库或从备份恢复（huijian restore 会删掉它）时换一个。
// 客户端发现纪元变了，说明服务端的数据不是原来那份，游标作废，重新对账且不按「服务端没有」删除本地消息。
const kvChangesEpoch = "changes_epoch"

func (s *Store) ChangesEpoch() string { return s.GetKV(kvChangesEpoch) }

type MsgChange struct {
	Seq   int64  `json:"seq"`
	ID    int64  `json:"id"`
	Kind  string `json:"kind"` // delete / archive
	State int    `json:"state,omitempty"`
}

// ownedIDs：只保留属于这个账号的消息 id
func ownedIDs(tx *sql.Tx, userID int64, ids []int64) ([]int64, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	ph := strings.TrimSuffix(strings.Repeat("?,", len(ids)), ",")
	args := []any{userID}
	for _, id := range ids {
		args = append(args, id)
	}
	rows, err := tx.Query(`SELECT id FROM messages WHERE user_id=? AND id IN (`+ph+`)`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

func idArgs(ids []int64) (string, []any) {
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	return strings.TrimSuffix(strings.Repeat("?,", len(ids)), ","), args
}

func recordChanges(tx *sql.Tx, userID int64, ids []int64, kind string, state int) error {
	at := now()
	for _, id := range ids {
		if _, err := tx.Exec(`INSERT INTO msg_changes(user_id,msg_id,kind,state,at) VALUES(?,?,?,?,?)`, userID, id, kind, state, at); err != nil {
			return err
		}
	}
	_, err := tx.Exec(`DELETE FROM msg_changes WHERE at<?`, at-int64(changesKeep/time.Second))
	return err
}

// DeleteMessages 删除这个账号的消息，返回不再被任何附件引用的文件（相对路径），由调用方删除文件
func (s *Store) DeleteMessages(userID int64, ids []int64) (deleted int, orphans []string, err error) {
	tx, err := s.db.Begin()
	if err != nil {
		return 0, nil, err
	}
	defer tx.Rollback()
	own, err := ownedIDs(tx, userID, ids)
	if err != nil || len(own) == 0 {
		return 0, nil, err
	}
	ph, args := idArgs(own)
	rows, err := tx.Query(`SELECT DISTINCT blob FROM attachments WHERE message_id IN (`+ph+`)`, args...)
	if err != nil {
		return 0, nil, err
	}
	var blobs []string
	for rows.Next() {
		var b string
		if err := rows.Scan(&b); err != nil {
			rows.Close()
			return 0, nil, err
		}
		blobs = append(blobs, b)
	}
	rows.Close()
	if _, err := tx.Exec(`DELETE FROM attachments WHERE message_id IN (`+ph+`)`, args...); err != nil {
		return 0, nil, err
	}
	if _, err := tx.Exec(`DELETE FROM messages WHERE id IN (`+ph+`)`, args...); err != nil {
		return 0, nil, err
	}
	if err := recordChanges(tx, userID, own, changeDelete, 0); err != nil {
		return 0, nil, err
	}
	// 旧版本的附件可能按内容共用一个文件：还有别的附件引用的不删（blob 有索引，分批查）
	for i := 0; i < len(blobs); i += 500 {
		part := blobs[i:min(i+500, len(blobs))]
		bargs := make([]any, len(part))
		for j, b := range part {
			bargs[j] = b
		}
		used := map[string]bool{}
		rows, err := tx.Query(`SELECT DISTINCT blob FROM attachments WHERE blob IN (`+strings.TrimSuffix(strings.Repeat("?,", len(part)), ",")+`)`, bargs...)
		if err != nil {
			return 0, nil, err
		}
		for rows.Next() {
			var b string
			if err := rows.Scan(&b); err != nil {
				rows.Close()
				return 0, nil, err
			}
			used[b] = true
		}
		rows.Close()
		for _, b := range part {
			if !used[b] {
				orphans = append(orphans, b)
			}
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, nil, err
	}
	return len(own), orphans, nil
}

// SetArchive 设置这个账号的消息的归档状态
func (s *Store) SetArchive(userID int64, ids []int64, state int) (int, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	own, err := ownedIDs(tx, userID, ids)
	if err != nil || len(own) == 0 {
		return 0, err
	}
	ph, args := idArgs(own)
	if _, err := tx.Exec(`UPDATE messages SET archive=? WHERE id IN (`+ph+`)`, append([]any{state}, args...)...); err != nil {
		return 0, err
	}
	if err := recordChanges(tx, userID, own, changeArchive, state); err != nil {
		return 0, err
	}
	return len(own), tx.Commit()
}

// topSeq：分配过的最大 seq（AUTOINCREMENT 记在 sqlite_sequence 里，旧记录清理后也不会变小）
func (s *Store) topSeq() int64 {
	var top sql.NullInt64
	s.db.QueryRow(`SELECT seq FROM sqlite_sequence WHERE name='msg_changes'`).Scan(&top)
	return top.Int64
}

// Changes 返回 since 之后的变更和新的游标；since 早于保留范围（或晚于服务端记录，例如数据库从备份恢复过）时
// reset=true，客户端需要重新对账（GET /v1/messages/state）
func (s *Store) Changes(userID, since int64, limit int) (out []MsgChange, next int64, reset bool, err error) {
	top := s.topSeq()
	if since < 0 { // 第一次：从现在开始
		return []MsgChange{}, top, false, nil
	}
	if since > top {
		return []MsgChange{}, top, true, nil
	}
	if since < top {
		var minSeq sql.NullInt64
		s.db.QueryRow(`SELECT MIN(seq) FROM msg_changes`).Scan(&minSeq)
		oldest := top + 1 // 全部清理过了
		if minSeq.Valid {
			oldest = minSeq.Int64
		}
		if since < oldest-1 {
			return []MsgChange{}, top, true, nil
		}
	}
	next = top
	rows, err := s.db.Query(`SELECT seq,msg_id,kind,state FROM msg_changes WHERE user_id=? AND seq>? AND seq<=? ORDER BY seq LIMIT ?`, userID, since, top, limit)
	if err != nil {
		return nil, since, false, err
	}
	defer rows.Close()
	out = []MsgChange{}
	for rows.Next() {
		var c MsgChange
		if err := rows.Scan(&c.Seq, &c.ID, &c.Kind, &c.State); err != nil {
			return nil, since, false, err
		}
		out = append(out, c)
	}
	if len(out) == limit {
		next = out[len(out)-1].Seq
	}
	return out, next, false, rows.Err()
}

// MessageStates 返回这个账号全部消息的 [id, 归档状态]，以及当时的变更游标（客户端对账用）
func (s *Store) MessageStates(userID int64) (items [][2]int64, next int64, err error) {
	next = s.topSeq() // 先取游标：对账期间发生的变更下次还会再拿到一次（重复应用无害）
	rows, err := s.db.Query(`SELECT id, archive FROM messages WHERE user_id=? ORDER BY id`, userID)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	items = [][2]int64{}
	for rows.Next() {
		var it [2]int64
		if err := rows.Scan(&it[0], &it[1]); err != nil {
			return nil, 0, err
		}
		items = append(items, it)
	}
	return items, next, rows.Err()
}

// remove 删除附件文件，以及这条消息自己的附件目录（变空时）。年/月/日目录不删：
// 同一时刻可能有新上传正在里面建目录（claimAttDir），删掉会让上传失败；空的日期目录不占空间。
func (fst *fileStore) remove(rels []string) {
	for _, rel := range rels {
		if !safeRel(rel) {
			continue
		}
		found := false
		for _, root := range fst.roots() {
			p := filepath.Join(root, filepath.FromSlash(strings.ReplaceAll(rel, `\`, "/")))
			err := os.Remove(p)
			if err == nil {
				found = true
				removeOwnDir(filepath.Dir(p), root)
			} else if !os.IsNotExist(err) {
				log.Printf("删除附件文件失败（%s）：%v", rel, err)
			}
		}
		if !found {
			if err := fst.files.ready(); err != nil {
				log.Printf("附件目录暂时不可用，没能删除附件文件 %s：%v", rel, err)
			}
		}
	}
}

// removeOwnDir 删除附件所在的目录（只有它比「年/月/日」更深、且已经变空时）
func removeOwnDir(dir, root string) {
	rel, err := filepath.Rel(filepath.Clean(root), filepath.Clean(dir))
	if err != nil || strings.HasPrefix(rel, "..") || len(strings.Split(filepath.ToSlash(rel), "/")) < 4 {
		return
	}
	os.Remove(dir) // 非空时失败，正好不删
}

// ---------- API ----------

type manageReq struct {
	IDs   []int64 `json:"ids"`
	State *int    `json:"state"`
}

func readManage(w http.ResponseWriter, r *http.Request) (manageReq, bool) {
	var in manageReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&in); err != nil {
		apiErr(w, 400, "请求格式不对")
		return in, false
	}
	if len(in.IDs) == 0 || len(in.IDs) > maxManageIDs {
		apiErr(w, 400, "ids 需要 1–1000 个")
		return in, false
	}
	return in, true
}

// GET /v1/messages/state → {"items":[[id, archive], …], "changes_next": seq}
// 客户端第一次启用消息管理、或变更记录已清理（changes_reset）时对账：本地有、服务端没有的消息已被删除。
func (h *Hub) handleMessageStates(w http.ResponseWriter, r *http.Request, d *Device) {
	items, next, err := h.st.MessageStates(d.UserID)
	if err != nil {
		apiErr(w, 500, "读取失败")
		return
	}
	writeJSON(w, 200, map[string]any{"items": items, "changes_next": next, "epoch": h.st.ChangesEpoch()})
}

// POST /v1/messages/delete {"ids":[…]} → {"deleted": n}
func (h *Hub) handleDeleteMessages(w http.ResponseWriter, r *http.Request, d *Device) {
	in, ok := readManage(w, r)
	if !ok {
		return
	}
	n, err := h.deleteMessages(d.UserID, in.IDs)
	if err != nil {
		apiErr(w, 500, "删除失败")
		return
	}
	writeJSON(w, 200, map[string]any{"deleted": n})
}

func (h *Hub) deleteMessages(userID int64, ids []int64) (int, error) {
	n, orphans, err := h.st.DeleteMessages(userID, ids)
	if err != nil {
		return 0, err
	}
	h.files.remove(orphans)
	if n > 0 {
		h.br.Notify(userID) // 同账号其他设备的长轮询立即拿到删除
	}
	return n, nil
}

// POST /v1/messages/archive {"ids":[…], "state": 0|1|2} → {"updated": n}
func (h *Hub) handleArchiveMessages(w http.ResponseWriter, r *http.Request, d *Device) {
	in, ok := readManage(w, r)
	if !ok {
		return
	}
	if in.State == nil || *in.State < archiveAuto || *in.State > archiveKeep {
		apiErr(w, 400, "state 只能是 0（自动）、1（归档）、2（保留在收件箱）")
		return
	}
	n, err := h.st.SetArchive(d.UserID, in.IDs, *in.State)
	if err != nil {
		apiErr(w, 500, "保存失败")
		return
	}
	if n > 0 {
		h.br.Notify(d.UserID)
	}
	writeJSON(w, 200, map[string]any{"updated": n})
}
