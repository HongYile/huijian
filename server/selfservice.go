package main

// 设备自助管理：已配对的设备用自己的 token 管理 pushkey、给自己改名，不必再登录管理后台。
//
//	PATCH /v1/me                 {"name": "...", "away_silent": true}  改本机名称 / 其他设备在用时本机静默
//	以下是本账号范围内的操作，本账号的任何设备都可以（0.5.0 以前需要「允许管理」）：
//	GET   /v1/keys                                             列出 pushkey
//	POST  /v1/keys               {"name": "...", "key": "..."}  新建（key 可省略，自动生成）
//	PATCH /v1/keys/{id}          {"name": "...", "key": "..."}  改名 / 换 key 内容（旧 key 立即失效），返回该 key
//	POST  /v1/keys/{id}/revoke                                 吊销，返回该 key
//
// 设备 ID 形如 d_20261117083015_a1b2：UTC 时间戳 + 随机后缀，按时间有序、不会重复，
// 名称可以随便改、可以重名，找设备时用 ID。

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
)

var reCustomKey = regexp.MustCompile(`^[A-Za-z0-9_-]{16,64}$`)

const keyRule = "key 只能包含字母、数字、下划线和短横线，长度 16–64（太短容易被猜到）"

var errKeyTaken = errors.New("这个 key 已被使用（包括已吊销的），请换一个")

// newDeviceID：UTC 时间戳（到秒）+ 4 位随机十六进制
func newDeviceID() string {
	return "d_" + time.Now().UTC().Format("20060102150405") + "_" + randHex(2)
}

// cleanLabel：名称去掉控制字符和首尾空白，按字符截断
func cleanLabel(s string, max int) string {
	s = strings.TrimSpace(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, s))
	if r := []rune(s); len(r) > max {
		s = string(r[:max])
	}
	return s
}

// ---------- 存储 ----------

func isUniqueErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "UNIQUE")
}

// CreatePushkeyWith 创建 pushkey；key 为空时自动生成。
// 自定义 key 不能和已删除账号的 key、换掉的旧 key 重复（retired_pushkeys），检查和写入在同一个事务里
func (s *Store) CreatePushkeyWith(userID int64, name, key string) (*Pushkey, error) {
	if key == "" {
		return s.CreatePushkey(userID, name)
	}
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if retired, err := keyRetired(tx, key); err != nil {
		return nil, err
	} else if retired {
		return nil, errKeyTaken
	}
	res, err := tx.Exec(`INSERT INTO pushkeys(user_id,key,name,created_at) VALUES(?,?,?,?)`, userID, key, name, now())
	if isUniqueErr(err) {
		return nil, errKeyTaken
	}
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	s.settingsChanged(userID, changeKeys)
	return &Pushkey{ID: id, UserID: userID, Key: key, Name: name, Created: now()}, nil
}

var errKeyRevoked = errors.New("已吊销的 pushkey 不能修改")

// UpdatePushkey 改名和/或换 key 内容（空字符串表示不改），在一个事务里完成，不会只改一半。已吊销的不能改。
// 换掉的旧 key 字符串留墓碑：还在用旧 key 的脚本收到 403，别的账号也不能认领它
func (s *Store) UpdatePushkey(userID, id int64, name, key string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var old string
	var revoked int
	switch err := tx.QueryRow(`SELECT key, revoked FROM pushkeys WHERE id=? AND user_id=? AND deleted=0`, id, userID).Scan(&old, &revoked); {
	case errors.Is(err, sql.ErrNoRows):
		return sql.ErrNoRows
	case err != nil:
		return err
	case revoked != 0:
		return errKeyRevoked
	}
	if key != "" && key != old {
		if retired, err := keyRetired(tx, key); err != nil {
			return err
		} else if retired {
			return errKeyTaken
		}
		if err := retireKey(tx, old); err != nil {
			return err
		}
	}
	_, err = tx.Exec(`UPDATE pushkeys SET name=COALESCE(NULLIF(?,''),name), key=COALESCE(NULLIF(?,''),key) WHERE id=? AND user_id=?`, name, key, id, userID)
	if isUniqueErr(err) {
		return errKeyTaken
	}
	if err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	s.settingsChanged(userID, changeKeys)
	return nil
}

var errKeyNotRevoked = errors.New("请先吊销这把 pushkey，再删除")

// DeletePushkey 删除一把已吊销的 pushkey：软删除，列表里不再显示。
// 行保留（仍是吊销状态），key 字符串和 id 继续被占用：泄露的旧 key 不会被别的账号用自定义 key 认领，
// id 也不会被新建的 key 复用；历史消息不受影响
func (s *Store) DeletePushkey(userID, id int64) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var revoked int
	switch err := tx.QueryRow(`SELECT revoked FROM pushkeys WHERE id=? AND user_id=? AND deleted=0`, id, userID).Scan(&revoked); {
	case errors.Is(err, sql.ErrNoRows):
		return sql.ErrNoRows
	case err != nil:
		return err
	case revoked == 0:
		return errKeyNotRevoked
	}
	for _, q := range []string{
		`DELETE FROM device_keys WHERE pushkey_id=?`,
		`UPDATE pushkeys SET deleted=1 WHERE id=?`,
	} {
		if _, err := tx.Exec(q, id); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	s.settingsChanged(userID, changeKeys)
	return nil
}

// PushkeyByID 取某用户的一把 pushkey
func (s *Store) PushkeyByID(userID, id int64) (*Pushkey, error) {
	p := &Pushkey{}
	var rev int
	err := s.db.QueryRow(`SELECT id,user_id,key,name,created_at,revoked,last_used FROM pushkeys WHERE id=? AND user_id=? AND deleted=0`, id, userID).
		Scan(&p.ID, &p.UserID, &p.Key, &p.Name, &p.Created, &rev, &p.LastUsed)
	p.Revoked = rev != 0
	return p, err
}

// RenameDevice 改名；设备不存在或已吊销时返回 sql.ErrNoRows
func (s *Store) RenameDevice(userID int64, id, name string) error {
	res, err := s.db.Exec(`UPDATE devices SET name=? WHERE id=? AND user_id=? AND revoked=0`, name, id, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return sql.ErrNoRows
	}
	s.settingsChanged(userID, changeDevices)
	return nil
}

// ---------- 设备接口 ----------

type keyJSON struct {
	ID       int64   `json:"id"`
	Name     string  `json:"name"`
	Key      string  `json:"key"`
	Created  string  `json:"created_at"`
	LastUsed *string `json:"last_used"`
	Revoked  bool    `json:"revoked"`
}

func toKeyJSON(k Pushkey) keyJSON {
	j := keyJSON{ID: k.ID, Name: k.Name, Key: k.Key, Created: time.Unix(k.Created, 0).UTC().Format(time.RFC3339), Revoked: k.Revoked}
	if k.LastUsed.Valid {
		s := time.Unix(k.LastUsed.Int64, 0).UTC().Format(time.RFC3339)
		j.LastUsed = &s
	}
	return j
}

func readJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(v); err != nil {
		apiErr(w, 400, "请求体不是有效的 JSON")
		return false
	}
	return true
}

func (h *Hub) handleMeUpdate(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct {
		Name       *string
		AwaySilent *bool `json:"away_silent"`
	}
	if !readJSON(w, r, &in) {
		return
	}
	if in.Name != nil {
		name := cleanLabel(*in.Name, 64)
		if name == "" {
			apiErr(w, 400, "名称不能为空")
			return
		}
		if err := h.st.RenameDevice(d.UserID, d.ID, name); err != nil {
			apiErr(w, 500, "保存失败")
			return
		}
		d.Name = name
	}
	if in.AwaySilent != nil {
		if err := h.st.SetAwaySilent(d.ID, *in.AwaySilent); err != nil {
			apiErr(w, 500, "保存失败")
			return
		}
		d.AwaySilent = *in.AwaySilent
	}
	h.handleMe(w, r, d)
}

func (h *Hub) handleKeysList(w http.ResponseWriter, r *http.Request, d *Device) {
	keys, err := h.st.ListPushkeys(d.UserID)
	if err != nil {
		apiErr(w, 500, "查询失败")
		return
	}
	out := []keyJSON{}
	for _, k := range keys {
		out = append(out, toKeyJSON(k))
	}
	writeJSON(w, 200, map[string]any{"keys": out})
}

func (h *Hub) handleKeysCreate(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct{ Name, Key string }
	if !readJSON(w, r, &in) {
		return
	}
	name := cleanLabel(in.Name, 40)
	if name == "" {
		name = "未命名"
	}
	key := strings.TrimSpace(in.Key)
	if key != "" && !reCustomKey.MatchString(key) {
		apiErr(w, 400, keyRule)
		return
	}
	k, err := h.st.CreatePushkeyWith(d.UserID, name, key)
	if errors.Is(err, errKeyTaken) {
		apiErr(w, 409, err.Error())
		return
	}
	if err != nil {
		apiErr(w, 500, "创建失败")
		return
	}
	writeJSON(w, 200, toKeyJSON(*k))
}

func (h *Hub) handleKeysUpdate(w http.ResponseWriter, r *http.Request, d *Device) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	var in struct{ Name, Key string }
	if !readJSON(w, r, &in) {
		return
	}
	name, key := cleanLabel(in.Name, 40), strings.TrimSpace(in.Key)
	if key != "" && !reCustomKey.MatchString(key) {
		apiErr(w, 400, keyRule)
		return
	}
	switch err := h.st.UpdatePushkey(d.UserID, id, name, key); {
	case errors.Is(err, sql.ErrNoRows):
		apiErr(w, 404, "pushkey 不存在")
		return
	case errors.Is(err, errKeyTaken):
		apiErr(w, 409, err.Error())
		return
	case errors.Is(err, errKeyRevoked):
		apiErr(w, 400, err.Error())
		return
	case err != nil:
		apiErr(w, 500, "保存失败")
		return
	}
	h.writeKey(w, d, id)
}

func (h *Hub) writeKey(w http.ResponseWriter, d *Device, id int64) {
	k, err := h.st.PushkeyByID(d.UserID, id)
	if err != nil {
		apiErr(w, 500, "查询失败")
		return
	}
	writeJSON(w, 200, toKeyJSON(*k))
}

// DELETE /v1/keys/{id}：删除已吊销的 pushkey → 204
func (h *Hub) handleKeysDelete(w http.ResponseWriter, r *http.Request, d *Device) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	switch err := h.st.DeletePushkey(d.UserID, id); {
	case errors.Is(err, sql.ErrNoRows):
		apiErr(w, 404, "pushkey 不存在")
	case errors.Is(err, errKeyNotRevoked):
		apiErr(w, 409, err.Error())
	case err != nil:
		apiErr(w, 500, "删除失败")
	default:
		w.WriteHeader(204)
	}
}

func (h *Hub) handleKeysRevoke(w http.ResponseWriter, r *http.Request, d *Device) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if _, err := h.st.PushkeyByID(d.UserID, id); err != nil {
		apiErr(w, 404, "pushkey 不存在")
		return
	}
	if err := h.st.RevokePushkey(d.UserID, id); err != nil {
		apiErr(w, 500, "吊销失败")
		return
	}
	h.writeKey(w, d, id)
}
