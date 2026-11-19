package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

func randBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}

func randToken(n int) string { return base64.RawURLEncoding.EncodeToString(randBytes(n)) }
func randHex(n int) string   { return hex.EncodeToString(randBytes(n)) }

func randDigits(n int) string {
	var sb strings.Builder
	for i := 0; i < n; i++ {
		d, _ := rand.Int(rand.Reader, big.NewInt(10))
		sb.WriteString(d.String())
	}
	return sb.String()
}

func sha256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

// env 读取 HUIJIAN_* 环境变量，没有时读配置文件 huijian.conf。
// 旧名 HONGYAN_* / BEACON_* 已在启动时映射过来（legacy.go）。
func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	if v := fileConf[k]; v != "" {
		return v
	}
	return def
}

func envInt(k string, def int64) int64 {
	if v, err := strconv.ParseInt(env(k, ""), 10, 64); err == nil {
		return v
	}
	return def
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// PushDeer 风格的错误返回
func apiErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]any{"code": status, "error": msg})
}

func hostOf(addr string) string {
	h, _, err := net.SplitHostPort(addr)
	if err != nil {
		return addr
	}
	return h
}

// ---------- 限速：简单令牌桶 ----------

type bucket struct {
	tokens float64
	last   time.Time
}

type Limiter struct {
	mu    sync.Mutex
	rate  float64 // 每秒补充
	burst float64
	m     map[string]*bucket
}

func NewLimiter(perMinute, burst float64) *Limiter {
	return &Limiter{rate: perMinute / 60, burst: burst, m: map[string]*bucket{}}
}

func (l *Limiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	t := time.Now()
	b, ok := l.m[key]
	if !ok {
		b = &bucket{tokens: l.burst, last: t}
		l.m[key] = b
	}
	b.tokens += t.Sub(b.last).Seconds() * l.rate
	if b.tokens > l.burst {
		b.tokens = l.burst
	}
	b.last = t
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	if len(l.m) > 10000 { // 防止 map 无限增长
		for k, v := range l.m {
			if t.Sub(v.last) > 10*time.Minute {
				delete(l.m, k)
			}
		}
	}
	return true
}

// ---------- 访问日志（不记录 query，避免 pushkey 落盘） ----------

type statusRec struct {
	http.ResponseWriter
	status int
	n      int64
}

func (s *statusRec) WriteHeader(c int) { s.status = c; s.ResponseWriter.WriteHeader(c) }
func (s *statusRec) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = 200
	}
	n, err := s.ResponseWriter.Write(b)
	s.n += int64(n)
	return n, err
}
func (s *statusRec) Flush() {
	if f, ok := s.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}
func (s *statusRec) Unwrap() http.ResponseWriter { return s.ResponseWriter }

func logMW(tag string, realIP func(*http.Request) string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t := time.Now()
		rec := &statusRec{ResponseWriter: w}
		next.ServeHTTP(rec, r)
		log.Printf("%s %s %s %s %d %dB %s", tag, realIP(r), r.Method, r.URL.Path, rec.status, rec.n, time.Since(t).Round(time.Millisecond))
	})
}

// ipSet：逗号分隔的 IP 或 CIDR，例如 "10.0.0.1, 172.16.0.0/12"。
type ipSet []netip.Prefix

func parseIPSet(s string) ipSet {
	var out ipSet
	for _, item := range splitList(s) {
		if p, err := netip.ParsePrefix(item); err == nil {
			out = append(out, p.Masked())
		} else if a, err := netip.ParseAddr(item); err == nil {
			out = append(out, netip.PrefixFrom(a, a.BitLen()))
		} else {
			log.Printf("忽略无法解析的地址: %q", item)
		}
	}
	return out
}

func (s ipSet) has(ip string) bool {
	a, err := netip.ParseAddr(ip)
	if err != nil {
		return false
	}
	a = a.Unmap()
	for _, p := range s {
		if p.Contains(a) {
			return true
		}
	}
	return false
}
