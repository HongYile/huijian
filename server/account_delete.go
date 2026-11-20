package main

// 删除账号（0.9.0，管理后台「账号」页）：删掉这个账号的全部数据——消息、附件、pushkey、设备和配对记录、
// 接收规则、频道设置、加密钥匙和私钥副本、变更记录。
//
//   - 一个事务里删库；附件文件按内容去重时可能被别的账号共用，只把删完以后没有附件记录再引用的文件
//     登记到 pending_unlink，提交后删除（删不掉的启动时和每 10 分钟重试，和补加密同一套机制）。
//   - pushkey 字符串留墓碑（retired_pushkeys 存 key 的 SHA-256）：别的账号不能认领同一个字符串（409），
//     被删用户的脚本继续推送时返回 403，消息不会进到别人的账号里。
//   - 账号 id 不复用（kv 里记高水位 users_max_id，注册时从它往上分配）。
//   - 邀请码使用记录只留次数和时间（user_id 置 0、用户名清空，页面上显示「已删除账号」）；按天的活跃记录
//     改成负的 id 保留，历史统计不变。全服务器的每日计数（stats_daily）不变。
//   - 第一个账号（接收服务器自己的通知）不能删。

import (
	"database/sql"
	"errors"
	"net/http"
	"strconv"
	"strings"
)

func (s *Store) migrateRetired() error {
	_, err := s.db.Exec(`CREATE TABLE IF NOT EXISTS retired_pushkeys(key_hash TEXT PRIMARY KEY, at INTEGER NOT NULL)`)
	return err
}

// q：*sql.DB 和 *sql.Tx 共有的查询方法
type q interface {
	Exec(query string, args ...any) (sql.Result, error)
	QueryRow(query string, args ...any) *sql.Row
}

// retireKey：把不再使用的 pushkey 字符串记成墓碑（只存哈希）
func retireKey(x q, key string) error {
	_, err := x.Exec(`INSERT OR IGNORE INTO retired_pushkeys(key_hash,at) VALUES(?,?)`, sha256Hex(key), now())
	return err
}

// keyRetired：这个 pushkey 字符串是否属于已删除的账号（或被换掉的旧 key）。
// 查询出错时返回 error，认领 key 的调用方据此拒绝（不能在查不到墓碑时放行）
func keyRetired(x q, key string) (bool, error) {
	var n int
	if err := x.QueryRow(`SELECT COUNT(*) FROM retired_pushkeys WHERE key_hash=?`, sha256Hex(key)).Scan(&n); err != nil {
		return false, err
	}
	return n > 0, nil
}

// bumpUserHighWater：记下用过的最大账号 id，以后注册的账号从它往上分配（删除的 id 不复用）
func bumpUserHighWater(x q, id int64) error {
	_, err := x.Exec(`INSERT INTO kv(k,v) VALUES('users_max_id',?) ON CONFLICT(k) DO UPDATE SET v=CAST(max(CAST(v AS INTEGER),CAST(excluded.v AS INTEGER)) AS TEXT)`, strconv.FormatInt(id, 10))
	return err
}

// nextUserID：下一个账号 id = max(高水位, 现有最大 id) + 1
func nextUserID(x q) (int64, error) {
	var hw, mx int64
	x.QueryRow(`SELECT COALESCE((SELECT CAST(v AS INTEGER) FROM kv WHERE k='users_max_id'),0)`).Scan(&hw)
	if err := x.QueryRow(`SELECT COALESCE(MAX(id),0) FROM users`).Scan(&mx); err != nil {
		return 0, err
	}
	return max(hw, mx) + 1, nil
}

var errDeleteOwner = errors.New("第一个账号接收服务器自己的通知（备份失败等），不能删除")

// DeleteAccount：删除账号和它的全部数据，返回需要删除的附件文件（已登记 pending_unlink）
func (s *Store) DeleteAccount(userID int64) ([]string, error) {
	if userID == s.OwnerID() {
		return nil, errDeleteOwner
	}
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var exists int64
	if err := tx.QueryRow(`SELECT id FROM users WHERE id=?`, userID).Scan(&exists); err != nil {
		return nil, err // sql.ErrNoRows：账号不存在
	}
	var blobs []string
	rows, err := tx.Query(`SELECT DISTINCT a.blob FROM attachments a JOIN messages m ON m.id=a.message_id WHERE m.user_id=?`, userID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var b string
		if rows.Scan(&b) == nil {
			blobs = append(blobs, b)
		}
	}
	rows.Close()
	// pushkey 字符串（包括已吊销、已删除的）留墓碑
	krows, err := tx.Query(`SELECT key FROM pushkeys WHERE user_id=?`, userID)
	if err != nil {
		return nil, err
	}
	var keys []string
	for krows.Next() {
		var k string
		if krows.Scan(&k) == nil {
			keys = append(keys, k)
		}
	}
	krows.Close()
	for _, k := range keys {
		if err := retireKey(tx, k); err != nil {
			return nil, err
		}
	}
	if err := bumpUserHighWater(tx, userID); err != nil {
		return nil, err
	}
	devs := `(SELECT id FROM devices WHERE user_id=?)`
	for _, q := range []string{
		`DELETE FROM attachments WHERE message_id IN (SELECT id FROM messages WHERE user_id=?)`,
		`DELETE FROM sealed_atts WHERE user_id=?`,
		`DELETE FROM messages WHERE user_id=?`,
		`DELETE FROM msg_changes WHERE user_id=?`,
		`DELETE FROM device_keys WHERE device_id IN ` + devs,
		`DELETE FROM admin_links WHERE device_id IN ` + devs,
		`DELETE FROM device_pairings WHERE user_id=?`,
		`DELETE FROM e2e_wraps WHERE user_id=?`,
		`DELETE FROM e2e_keys WHERE user_id=?`,
		`DELETE FROM channels WHERE user_id=?`,
		`DELETE FROM pair_codes WHERE user_id=?`,
		`DELETE FROM agent_replies WHERE user_id=?`,
		`DELETE FROM agent_sessions WHERE user_id=?`,
		`DELETE FROM agent_keys WHERE user_id=?`,
		`DELETE FROM devices WHERE user_id=?`,
		`DELETE FROM pushkeys WHERE user_id=?`,
		`UPDATE invite_uses SET user_id=0, username='' WHERE user_id=?`,
		`UPDATE OR REPLACE daily_active SET user_id=-user_id WHERE user_id=?`,
		`DELETE FROM users WHERE id=?`,
	} {
		if _, err := tx.Exec(q, userID); err != nil {
			return nil, err
		}
	}
	// 删完以后没有附件记录再引用的文件：登记待删
	var orphans []string
	at := now()
	for _, b := range blobs {
		var n int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM attachments WHERE blob=?`, b).Scan(&n); err != nil {
			return nil, err
		}
		if n == 0 {
			if _, err := tx.Exec(`INSERT OR IGNORE INTO pending_unlink(blob,at) VALUES(?,?)`, b, at); err != nil {
				return nil, err
			}
			orphans = append(orphans, b)
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	s.active.forget(userID)
	return orphans, nil
}

// POST /accounts/{id}/delete  confirm=<用户名>：二次确认要输入这个账号的用户名
func (h *Hub) adminDeleteAccount(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	a, err := h.st.AccountByID(id)
	if err != nil {
		redirectFlash(w, r, "/accounts", "账号不存在")
		return
	}
	if strings.TrimSpace(r.FormValue("confirm")) != a.Label() {
		redirectFlash(w, r, "/accounts", "没有删除：输入的用户名和「"+a.Label()+"」不一致")
		return
	}
	// 账号的设备立刻失效（删库后 token 查不到 → 401）；正在长轮询的先唤醒
	orphans, err := h.st.DeleteAccount(id)
	if err != nil {
		msg := err.Error()
		if errors.Is(err, sql.ErrNoRows) {
			msg = "账号不存在"
		} else if !errors.Is(err, errDeleteOwner) {
			msg = "删除失败：" + msg
		}
		redirectFlash(w, r, "/accounts", msg)
		return
	}
	h.br.Notify(id)
	if len(orphans) > 0 {
		h.unlinkPending(orphans)
	}
	h.st.truncateWAL("删除账号")
	redirectFlash(w, r, "/accounts", "已删除账号「"+a.Label()+"」和它的全部数据")
}
