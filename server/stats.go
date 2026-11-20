package main

// 服务器统计（0.9.0，管理后台概览用）：只存计数，不存任何内容。
//
//   - daily_active(day, user_id)：这一天有设备用 token 访问过接口（或登录、配对）的账号。设备鉴权成功时按天记一次
//     （内存里去重，同一账号一天只写一次库），保留 400 天。
//   - stats_daily(day, messages, att_bytes, new_accounts)：全服务器每天新写入的消息条数、附件字节数（存下的大小，
//     加密消息是密文大小）、新建账号数。消息写库、建号时在同一个事务里累加。
//
// day 是服务器本地时区（TZ）的日期 YYYY-MM-DD，和自动备份的时间用同一个时区。

import (
	"database/sql"
	"sort"
	"strings"
	"sync"
	"time"
)

const statsSchema = `
CREATE TABLE IF NOT EXISTS daily_active(day TEXT NOT NULL, user_id INTEGER NOT NULL, PRIMARY KEY(day, user_id));
CREATE TABLE IF NOT EXISTS stats_daily(day TEXT PRIMARY KEY, messages INTEGER NOT NULL DEFAULT 0,
  att_bytes INTEGER NOT NULL DEFAULT 0, new_accounts INTEGER NOT NULL DEFAULT 0);
`

const activeKeepDays = 400

// statsNow：测试里替换成固定时间（跨天）
var statsNow = time.Now

func statsDay(t time.Time) string { return t.Local().Format("2006-01-02") }

func (s *Store) migrateStats() error {
	if _, err := s.db.Exec(statsSchema); err != nil {
		return err
	}
	// 升级到 0.9.0 时，从现有的消息和账号补出以前每天的消息数、附件大小、新账号数（活跃账号没法补，从升级那天开始记）
	if s.GetKV("stats:backfilled") == "" {
		since := statsNow().AddDate(0, 0, -activeKeepDays).Unix()
		for _, q := range []string{
			`INSERT OR IGNORE INTO stats_daily(day) SELECT DISTINCT date(created_at,'unixepoch','localtime') FROM messages WHERE created_at>=?`,
			`INSERT OR IGNORE INTO stats_daily(day) SELECT DISTINCT date(created_at,'unixepoch','localtime') FROM users WHERE created_at>=?`,
			`UPDATE stats_daily SET messages=(SELECT COUNT(*) FROM messages m WHERE date(m.created_at,'unixepoch','localtime')=stats_daily.day AND m.created_at>=?)`,
			`UPDATE stats_daily SET att_bytes=(SELECT COALESCE(SUM(a.size),0) FROM attachments a JOIN messages m ON m.id=a.message_id
				WHERE date(m.created_at,'unixepoch','localtime')=stats_daily.day AND m.created_at>=?)`,
			`UPDATE stats_daily SET new_accounts=(SELECT COUNT(*) FROM users u WHERE date(u.created_at,'unixepoch','localtime')=stats_daily.day AND u.created_at>=?)`,
		} {
			if _, err := s.db.Exec(q, since); err != nil {
				return err
			}
		}
		s.SetKV("stats:backfilled", "1")
	}
	return nil
}

// bumpStats：在调用方的事务里给今天的计数加上增量
func bumpStats(tx *sql.Tx, messages, attBytes, newAccounts int64) error {
	_, err := tx.Exec(`INSERT INTO stats_daily(day,messages,att_bytes,new_accounts) VALUES(?,?,?,?)
		ON CONFLICT(day) DO UPDATE SET messages=messages+excluded.messages, att_bytes=att_bytes+excluded.att_bytes,
		new_accounts=new_accounts+excluded.new_accounts`, statsDay(statsNow()), messages, attBytes, newAccounts)
	return err
}

// activeMemo：今天已经记过活跃的账号（内存去重，避免每个请求写库）
type activeMemo struct {
	sync.Mutex
	day  string
	seen map[int64]bool
}

// forget：账号删除后清掉内存里的「今天已记过」
func (m *activeMemo) forget(userID int64) {
	m.Lock()
	delete(m.seen, userID)
	m.Unlock()
}

// markActive：设备鉴权成功时调用。同一账号一天只写一次库；换天时顺带清理 400 天以前的记录
func (s *Store) markActive(userID int64) {
	day := statsDay(statsNow())
	m := &s.active
	m.Lock()
	if m.day != day {
		m.day, m.seen = day, map[int64]bool{}
		go s.db.Exec(`DELETE FROM daily_active WHERE day<?`, statsDay(statsNow().AddDate(0, 0, -activeKeepDays)))
	}
	if m.seen[userID] {
		m.Unlock()
		return
	}
	m.seen[userID] = true
	m.Unlock()
	s.db.Exec(`INSERT OR IGNORE INTO daily_active(day,user_id) VALUES(?,?)`, day, userID)
}

// ---------- 概览用的查询 ----------

type dayStat struct {
	Day                                 string // YYYY-MM-DD
	Label                               string // 11/20
	Active, Messages, NewAccounts       int64
	AttBytes                            int64
	PctActive, PctMessages, PctAccounts float64 // 柱子高度（30 天里最大值为 barMax）
	Tick, Tick10                        bool    // 横轴上显示日期：每 5 天 / 每 10 天一个（窄图用），今天总显示
}

// barMax：最高的柱子占图表高度的百分比（上面留出数字、下面留出日期的位置）
const barMax = 68

// DailyStats：最近 n 天（含今天）每天的活跃账号、新消息、新账号，没有记录的日子为 0
func (s *Store) DailyStats(n int) []dayStat {
	now := statsNow()
	out := make([]dayStat, n)
	idx := map[string]int{}
	for i := 0; i < n; i++ {
		t := now.AddDate(0, 0, i-n+1)
		out[i] = dayStat{Day: statsDay(t), Label: t.Local().Format("1/2"), Tick: (n-1-i)%5 == 0, Tick10: (n-1-i)%10 == 0}
		idx[out[i].Day] = i
	}
	from := out[0].Day
	if rows, err := s.db.Query(`SELECT day, COUNT(*) FROM daily_active WHERE day>=? GROUP BY day`, from); err == nil {
		for rows.Next() {
			var d string
			var c int64
			if rows.Scan(&d, &c) == nil {
				if i, ok := idx[d]; ok {
					out[i].Active = c
				}
			}
		}
		rows.Close()
	}
	if rows, err := s.db.Query(`SELECT day, messages, att_bytes, new_accounts FROM stats_daily WHERE day>=?`, from); err == nil {
		for rows.Next() {
			var d string
			var m, b, a int64
			if rows.Scan(&d, &m, &b, &a) == nil {
				if i, ok := idx[d]; ok {
					out[i].Messages, out[i].AttBytes, out[i].NewAccounts = m, b, a
				}
			}
		}
		rows.Close()
	}
	var maxA, maxM, maxN int64
	for _, x := range out {
		maxA, maxM, maxN = max(maxA, x.Active), max(maxM, x.Messages), max(maxN, x.NewAccounts)
	}
	pct := func(v, m int64) float64 {
		if m == 0 {
			return 0
		}
		return float64(v) * barMax / float64(m)
	}
	for i := range out {
		out[i].PctActive, out[i].PctMessages, out[i].PctAccounts = pct(out[i].Active, maxA), pct(out[i].Messages, maxM), pct(out[i].NewAccounts, maxN)
	}
	return out
}

// ActiveAccounts：最近 days 天（含今天）有活动的账号数
func (s *Store) ActiveAccounts(days int) int64 {
	var n int64
	s.db.QueryRow(`SELECT COUNT(DISTINCT user_id) FROM daily_active WHERE day>=?`, statsDay(statsNow().AddDate(0, 0, 1-days))).Scan(&n)
	return n
}

type accountCounts struct {
	Total, Encrypted, Waiting, Disabled int64
}

// AccountCounts：账号总数、已加密（有 active 钥匙）、未加密的旧账号（没有钥匙，0.9 以前建的）、已停用
func (s *Store) AccountCounts() accountCounts {
	var c accountCounts
	s.db.QueryRow(`SELECT COUNT(*),
		COALESCE(SUM(EXISTS(SELECT 1 FROM e2e_keys k WHERE k.user_id=u.id AND k.active=1)),0),
		COALESCE(SUM(disabled),0) FROM users u`).Scan(&c.Total, &c.Encrypted, &c.Disabled)
	c.Waiting = c.Total - c.Encrypted
	return c
}

type platformStat struct {
	Platform string
	Total    int
	Outdated int
	Versions []versionStat
}

type versionStat struct {
	Version string
	Count   int
}

// DevicePlatforms：在用设备（未吊销）按平台、版本分布，以及其中较旧的个数（规则同 clientOutdated）
func (h *Hub) DevicePlatforms() []platformStat {
	rows, err := h.st.db.Query(`SELECT platform, client FROM devices WHERE revoked=0`)
	if err != nil {
		return nil
	}
	type key struct{ p, v string }
	by := map[string]*platformStat{}
	vers := map[key]int{}
	type pc struct{ p, c string }
	var list []pc
	for rows.Next() {
		var p, c string
		if rows.Scan(&p, &c) == nil {
			list = append(list, pc{p, c})
		}
	}
	rows.Close()
	for _, x := range list {
		p := strings.TrimSpace(x.p)
		if p == "" {
			p = "其他"
		}
		ps := by[p]
		if ps == nil {
			ps = &platformStat{Platform: p}
			by[p] = ps
		}
		ps.Total++
		if h.clientOutdated(x.c) {
			ps.Outdated++
		}
		v := clientVersion(x.c)
		if v == "" {
			v = "未知"
		}
		vers[key{p, v}]++
	}
	var out []platformStat
	for _, ps := range by {
		for k, n := range vers {
			if k.p == ps.Platform {
				ps.Versions = append(ps.Versions, versionStat{k.v, n})
			}
		}
		sort.Slice(ps.Versions, func(i, j int) bool {
			if ps.Versions[i].Count != ps.Versions[j].Count {
				return ps.Versions[i].Count > ps.Versions[j].Count
			}
			return verLess(ps.Versions[j].Version, ps.Versions[i].Version)
		})
		out = append(out, *ps)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Total != out[j].Total {
			return out[i].Total > out[j].Total
		}
		return out[i].Platform < out[j].Platform
	})
	return out
}

// AttachmentTotals：全服务器的附件个数和大小（数据库里记的大小）
func (s *Store) AttachmentTotals() (count, bytes int64) {
	s.db.QueryRow(`SELECT COUNT(*), COALESCE(SUM(size),0) FROM attachments`).Scan(&count, &bytes)
	return
}

// sumStats：一段日子的合计
func sumStats(days []dayStat) (messages, newAccounts int64) {
	for _, d := range days {
		messages += d.Messages
		newAccounts += d.NewAccounts
	}
	return
}
