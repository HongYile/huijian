package main

// 频道设置：频道就是消息的 topic（发送时带的参数，没带时为 default）。这里按账号保存每个频道的
// 显示名、隐藏、静音、置顶和手动顺序，所有设备共用；改动写进 msg_changes（kind=channels），
// 同账号其他设备的长轮询立即拿到，再重新拉取 GET /v1/channels。
//
//   隐藏：不进收件箱、不计未读、不提醒（紧急消息也不提醒）
//   静音：照常显示，不弹通知；紧急（P5）照常提醒
//
// 删除频道 = 删除这个频道的全部消息（附件一起删），并清掉它的设置；之后再有消息发来会重新出现。

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"
	"unicode/utf8"
)

const channelSchema = `
CREATE TABLE IF NOT EXISTS channels(
  user_id INTEGER NOT NULL, topic TEXT NOT NULL, alias TEXT NOT NULL DEFAULT '',
  hidden INTEGER NOT NULL DEFAULT 0, muted INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0,
  sort INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(user_id, topic));
`

const (
	changeChannels = "channels"
	maxAliasRunes  = 32
	maxTopicRunes  = 128
	maxOrderTopics = 500
)

type Channel struct {
	Topic  string `json:"topic"`
	Alias  string `json:"alias"`
	Hidden bool   `json:"hidden"`
	Muted  bool   `json:"muted"`
	Pinned bool   `json:"pinned"`
	Sort   int    `json:"sort"` // 手动顺序，0 = 没有（按最近活跃）
}

func (s *Store) migrateChannels() error {
	_, err := s.db.Exec(channelSchema)
	return err
}

func (s *Store) Channels(userID int64) ([]Channel, error) {
	rows, err := s.db.Query(`SELECT topic,alias,hidden,muted,pinned,sort FROM channels WHERE user_id=? ORDER BY topic`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Channel{}
	for rows.Next() {
		var c Channel
		var h, m, p int
		if err := rows.Scan(&c.Topic, &c.Alias, &h, &m, &p, &c.Sort); err != nil {
			return nil, err
		}
		c.Hidden, c.Muted, c.Pinned = h == 1, m == 1, p == 1
		out = append(out, c)
	}
	return out, rows.Err()
}

// channelFlags：隐藏 / 静音的频道（给消息标静默用）
func (s *Store) channelFlags(userID int64) (hidden, muted map[string]bool) {
	hidden, muted = map[string]bool{}, map[string]bool{}
	rows, err := s.db.Query(`SELECT topic,hidden,muted FROM channels WHERE user_id=? AND (hidden=1 OR muted=1)`, userID)
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var t string
		var h, m int
		if rows.Scan(&t, &h, &m) == nil {
			hidden[t], muted[t] = h == 1, m == 1
		}
	}
	return
}

type channelPatch struct {
	Topic  string  `json:"topic"`
	Alias  *string `json:"alias"`
	Hidden *bool   `json:"hidden"`
	Muted  *bool   `json:"muted"`
	Pinned *bool   `json:"pinned"`
}

func recordChannelChange(tx *sql.Tx, userID int64) error {
	return recordChanges(tx, userID, []int64{0}, changeChannels, 0)
}

// UpdateChannel 修改一个频道的设置（只改传了的字段），返回修改后的设置
func (s *Store) UpdateChannel(userID int64, p channelPatch) (Channel, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return Channel{}, err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`INSERT OR IGNORE INTO channels(user_id,topic) VALUES(?,?)`, userID, p.Topic); err != nil {
		return Channel{}, err
	}
	set := func(col string, v any) error {
		_, err := tx.Exec(`UPDATE channels SET `+col+`=? WHERE user_id=? AND topic=?`, v, userID, p.Topic)
		return err
	}
	if p.Alias != nil {
		if err := set("alias", *p.Alias); err != nil {
			return Channel{}, err
		}
	}
	for col, v := range map[string]*bool{"hidden": p.Hidden, "muted": p.Muted, "pinned": p.Pinned} {
		if v != nil {
			if err := set(col, b2i(*v)); err != nil {
				return Channel{}, err
			}
		}
	}
	if err := recordChannelChange(tx, userID); err != nil {
		return Channel{}, err
	}
	var c Channel
	var h, m, pin int
	if err := tx.QueryRow(`SELECT topic,alias,hidden,muted,pinned,sort FROM channels WHERE user_id=? AND topic=?`, userID, p.Topic).
		Scan(&c.Topic, &c.Alias, &h, &m, &pin, &c.Sort); err != nil {
		return Channel{}, err
	}
	c.Hidden, c.Muted, c.Pinned = h == 1, m == 1, pin == 1
	return c, tx.Commit()
}

// SetChannelOrder 按给定顺序设置手动排序（1, 2, 3…），其余频道清掉顺序；空列表 = 恢复按最近活跃排序
func (s *Store) SetChannelOrder(userID int64, topics []string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`UPDATE channels SET sort=0 WHERE user_id=?`, userID); err != nil {
		return err
	}
	seen := map[string]bool{}
	n := 0
	for _, t := range topics {
		if seen[t] {
			continue
		}
		seen[t] = true
		n++
		if _, err := tx.Exec(`INSERT INTO channels(user_id,topic,sort) VALUES(?,?,?) ON CONFLICT(user_id,topic) DO UPDATE SET sort=excluded.sort`, userID, t, n); err != nil {
			return err
		}
	}
	if err := recordChannelChange(tx, userID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) messageIDsByTopic(userID int64, topic string) ([]int64, error) {
	rows, err := s.db.Query(`SELECT id FROM messages WHERE user_id=? AND topic=? ORDER BY id`, userID, topic)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func (s *Store) deleteChannelSettings(userID int64, topic string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM channels WHERE user_id=? AND topic=?`, userID, topic); err != nil {
		return err
	}
	if err := recordChannelChange(tx, userID); err != nil {
		return err
	}
	return tx.Commit()
}

// ---------- API ----------

func validTopic(t string) bool {
	return t != "" && utf8.RuneCountInString(t) <= maxTopicRunes
}

// GET /v1/channels → {"channels":[…]}（只有设置过的频道）
func (h *Hub) handleChannels(w http.ResponseWriter, r *http.Request, d *Device) {
	cs, err := h.st.Channels(d.UserID)
	if err != nil {
		apiErr(w, 500, "读取失败")
		return
	}
	writeJSON(w, 200, map[string]any{"channels": cs})
}

// PATCH /v1/channels {"topic":"train","alias":"训练","hidden":false,"muted":true,"pinned":true}（字段都可选）
func (h *Hub) handleChannelUpdate(w http.ResponseWriter, r *http.Request, d *Device) {
	var p channelPatch
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&p); err != nil || !validTopic(p.Topic) {
		apiErr(w, 400, "请求格式不对")
		return
	}
	if p.Alias != nil {
		a := strings.Join(strings.Fields(*p.Alias), " ")
		if utf8.RuneCountInString(a) > maxAliasRunes {
			apiErr(w, 400, "显示名最多 32 个字")
			return
		}
		if a == p.Topic {
			a = "" // 和原名一样就等于没起别名
		}
		p.Alias = &a
	}
	c, err := h.st.UpdateChannel(d.UserID, p)
	if err != nil {
		apiErr(w, 500, "保存失败")
		return
	}
	h.br.Notify(d.UserID)
	writeJSON(w, 200, c)
}

// PUT /v1/channels/order {"topics":["train","infra",…]} → 204；空列表 = 恢复按最近活跃排序
func (h *Hub) handleChannelOrder(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct {
		Topics []string `json:"topics"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256<<10)).Decode(&in); err != nil || len(in.Topics) > maxOrderTopics {
		apiErr(w, 400, "请求格式不对")
		return
	}
	for _, t := range in.Topics {
		if !validTopic(t) {
			apiErr(w, 400, "频道名不对")
			return
		}
	}
	if err := h.st.SetChannelOrder(d.UserID, in.Topics); err != nil {
		apiErr(w, 500, "保存失败")
		return
	}
	h.br.Notify(d.UserID)
	w.WriteHeader(204)
}

// POST /v1/channels/delete {"topic":"train"} → {"deleted": n}：删除这个频道的全部消息（附件一起删）和它的设置
func (h *Hub) handleChannelDelete(w http.ResponseWriter, r *http.Request, d *Device) {
	var in struct {
		Topic string `json:"topic"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&in); err != nil || !validTopic(in.Topic) {
		apiErr(w, 400, "请求格式不对")
		return
	}
	ids, err := h.st.messageIDsByTopic(d.UserID, in.Topic)
	if err != nil {
		apiErr(w, 500, "删除失败")
		return
	}
	total := 0
	for i := 0; i < len(ids); i += maxManageIDs {
		n, err := h.deleteMessages(d.UserID, ids[i:min(i+maxManageIDs, len(ids))])
		if err != nil {
			apiErr(w, 500, "删除失败")
			return
		}
		total += n
	}
	if err := h.st.deleteChannelSettings(d.UserID, in.Topic); err != nil {
		apiErr(w, 500, "删除失败")
		return
	}
	h.br.Notify(d.UserID)
	writeJSON(w, 200, map[string]any{"deleted": total})
}
