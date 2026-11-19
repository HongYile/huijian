package main

import (
	"os"
	"path/filepath"
	"strings"
	"time"
)

// 管理网页用的查询（单用户场景，按 userID 过滤）。

type MsgFilter struct {
	Priority int // -1 表示不限；否则 >= Priority
	Topic    string
	Q        string
	HasAtt   bool
	Before   int64 // 分页游标：id < Before；0 表示从最新开始
}

func (s *Store) AdminMessages(userID int64, f MsgFilter, limit int) ([]Message, error) {
	where := []string{"m.user_id=?"}
	args := []any{userID}
	if f.Priority >= 0 {
		where = append(where, "m.priority>=?")
		args = append(args, f.Priority)
	}
	if f.Topic != "" {
		where = append(where, "m.topic=?")
		args = append(args, f.Topic)
	}
	if f.Q != "" {
		where = append(where, "(m.text LIKE ? ESCAPE '\\' OR m.desp LIKE ? ESCAPE '\\' OR m.thread LIKE ? ESCAPE '\\' OR m.source LIKE ? ESCAPE '\\')")
		q := "%" + strings.NewReplacer(`\`, `\\`, "%", `\%`, "_", `\_`).Replace(f.Q) + "%"
		args = append(args, q, q, q, q)
	}
	if f.HasAtt {
		where = append(where, "EXISTS(SELECT 1 FROM attachments a WHERE a.message_id=m.id)")
	}
	if f.Before > 0 {
		where = append(where, "m.id<?")
		args = append(args, f.Before)
	}
	args = append(args, limit)
	rows, err := s.db.Query(`SELECT m.id,m.user_id,m.topic,m.thread,m.priority,m.type,m.text,m.desp,m.source,m.created_at
		FROM messages m WHERE `+strings.Join(where, " AND ")+` ORDER BY m.id DESC LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	out := []Message{}
	for rows.Next() {
		var m Message
		var ts int64
		if err := rows.Scan(&m.ID, &m.userID, &m.Topic, &m.Thread, &m.Priority, &m.Type, &m.Text, &m.Desp, &m.Source, &ts); err != nil {
			rows.Close()
			return nil, err
		}
		m.CreatedAt = time.Unix(ts, 0)
		m.Attachments = []Attachment{}
		out = append(out, m)
	}
	rows.Close()
	return out, s.loadAttachments(out)
}

func (s *Store) loadAttachments(out []Message) error {
	if len(out) == 0 {
		return nil
	}
	idx := map[int64]int{}
	args := make([]any, len(out))
	for i, m := range out {
		idx[m.ID] = i
		args[i] = m.ID
	}
	ph := strings.TrimSuffix(strings.Repeat("?,", len(out)), ",")
	rows, err := s.db.Query(`SELECT id,message_id,name,mime,size,sha256 FROM attachments WHERE message_id IN (`+ph+`) ORDER BY rowid`, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var a Attachment
		if err := rows.Scan(&a.ID, &a.msgID, &a.Name, &a.Mime, &a.Size, &a.Sha256); err != nil {
			return err
		}
		i := idx[a.msgID]
		out[i].Attachments = append(out[i].Attachments, a)
	}
	return rows.Err()
}

type TopicCount struct {
	Topic string
	Count int64
	Last  int64
}

func (s *Store) Topics(userID int64) []TopicCount {
	rows, err := s.db.Query(`SELECT topic, COUNT(*), MAX(created_at) FROM messages WHERE user_id=? GROUP BY topic ORDER BY MAX(created_at) DESC`, userID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []TopicCount
	for rows.Next() {
		var t TopicCount
		if rows.Scan(&t.Topic, &t.Count, &t.Last) == nil {
			out = append(out, t)
		}
	}
	return out
}

// PriorityCounts 返回 since 之后各优先级的消息数（下标即优先级）。
func (s *Store) PriorityCounts(userID, since int64) [6]int64 {
	var out [6]int64
	rows, err := s.db.Query(`SELECT priority, COUNT(*) FROM messages WHERE user_id=? AND created_at>=? GROUP BY priority`, userID, since)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var p int
		var c int64
		if rows.Scan(&p, &c) == nil && p >= 0 && p <= 5 {
			out[p] = c
		}
	}
	return out
}

type DayCount struct {
	Label string
	Count int64
	Pct   int // 相对最大值的百分比，画柱状图用
}

// DailyCounts 返回最近 n 天（含今天，按服务器本地时区）的每日消息数。
func (s *Store) DailyCounts(userID int64, n int) []DayCount {
	t := time.Now()
	start := time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.Local).AddDate(0, 0, -(n - 1))
	counts := make([]int64, n)
	rows, err := s.db.Query(`SELECT created_at FROM messages WHERE user_id=? AND created_at>=?`, userID, start.Unix())
	if err == nil {
		for rows.Next() {
			var ts int64
			if rows.Scan(&ts) == nil {
				d := int(time.Unix(ts, 0).Sub(start).Hours() / 24)
				if d >= 0 && d < n {
					counts[d]++
				}
			}
		}
		rows.Close()
	}
	var max int64 = 1
	for _, c := range counts {
		if c > max {
			max = c
		}
	}
	out := make([]DayCount, n)
	for i, c := range counts {
		out[i] = DayCount{Label: start.AddDate(0, 0, i).Format("01-02"), Count: c, Pct: int(c * 100 / max)}
	}
	return out
}

func (s *Store) LatestMessageTime(userID int64) int64 {
	var ts int64
	s.db.QueryRow(`SELECT COALESCE(MAX(created_at),0) FROM messages WHERE user_id=?`, userID).Scan(&ts)
	return ts
}

func dirSize(p string) int64 {
	var n int64
	filepath.Walk(p, func(_ string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			n += info.Size()
		}
		return nil
	})
	return n
}

func dbSize(dataDir string) int64 {
	var n int64
	db := dbFileName(dataDir)
	for _, f := range []string{db, db + "-wal", db + "-shm"} {
		if fi, err := os.Stat(filepath.Join(dataDir, f)); err == nil {
			n += fi.Size()
		}
	}
	return n
}
