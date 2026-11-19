package main

// 客户端应用内更新。
//
// 信任模型：更新包由发布方（开发机）用 Ed25519 私钥签名，客户端内置公钥校验。
// hub 只负责存储和分发，不持有私钥——即使 hub 被攻破，也无法向客户端推送伪造的更新。
//
//	发布：POST {admin}/api/releases      管理端口，Authorization: Bearer <管理令牌>，multipart
//	查询：GET  /v1/update?build=<当前构建号> 设备 token；按设备平台返回比当前新的最新版本
//	下载：GET  /v1/update/{id}             设备 token；支持 Range
//	提示：长轮询响应头 X-Huijian-Latest-Build，客户端据此立即发现新版本，不必等定时检查

import (
	"crypto/ed25519"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	releaseKeep     = 5 // 每个平台保留最近几个版本
	releaseMaxNotes = 16 << 10
)

var (
	rePlatform = regexp.MustCompile(`^[a-z0-9_-]{1,16}$`)
	reVersion  = regexp.MustCompile(`^[0-9A-Za-z][0-9A-Za-z.+-]{0,31}$`)
	reSha256   = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

type Release struct {
	ID        int64
	Platform  string
	Version   string
	Build     int64
	Notes     string
	Sha256    string
	Size      int64
	Signature string
	Created   int64
}

// releaseMessage 是被签名的内容。平台和构建号都在签名范围内，防止把旧版本或其他平台的合法包
// 冒充成新版本（降级 / 串包攻击）；更新说明的 sha256 也在内，hub 无法篡改客户端看到的说明文字。
func releaseMessage(platform string, build int64, version, sha, notes string) []byte {
	return []byte(fmt.Sprintf("hongyan-update-v1\n%s\n%d\n%s\n%s\n%s", platform, build, version, sha, sha256Hex(notes)))
}

// ---------- 存储 ----------

const releaseSchema = `
CREATE TABLE IF NOT EXISTS releases(
  id INTEGER PRIMARY KEY, platform TEXT NOT NULL, version TEXT NOT NULL, build INTEGER NOT NULL,
  notes TEXT NOT NULL DEFAULT '', sha256 TEXT NOT NULL, size INTEGER NOT NULL, signature TEXT NOT NULL,
  created_at INTEGER NOT NULL, UNIQUE(platform, build));`

const releaseCols = `id,platform,version,build,notes,sha256,size,signature,created_at`

func scanRelease(sc interface{ Scan(...any) error }) (*Release, error) {
	r := &Release{}
	err := sc.Scan(&r.ID, &r.Platform, &r.Version, &r.Build, &r.Notes, &r.Sha256, &r.Size, &r.Signature, &r.Created)
	return r, err
}

func (s *Store) InsertRelease(r *Release) error {
	res, err := s.db.Exec(`INSERT INTO releases(platform,version,build,notes,sha256,size,signature,created_at) VALUES(?,?,?,?,?,?,?,?)`,
		r.Platform, r.Version, r.Build, r.Notes, r.Sha256, r.Size, r.Signature, now())
	if err != nil {
		return err
	}
	r.ID, err = res.LastInsertId()
	return err
}

// LatestRelease 返回某平台构建号最大的版本；没有时返回 nil, nil。
func (s *Store) LatestRelease(platform string) (*Release, error) {
	r, err := scanRelease(s.db.QueryRow(`SELECT `+releaseCols+` FROM releases WHERE platform=? ORDER BY build DESC LIMIT 1`, platform))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return r, err
}

func (s *Store) ReleaseByID(id int64) (*Release, error) {
	return scanRelease(s.db.QueryRow(`SELECT `+releaseCols+` FROM releases WHERE id=?`, id))
}

func (s *Store) ListReleases() ([]Release, error) {
	rows, err := s.db.Query(`SELECT ` + releaseCols + ` FROM releases ORDER BY platform, build DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Release{}
	for rows.Next() {
		r, err := scanRelease(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *r)
	}
	return out, rows.Err()
}

// DeleteRelease 删除记录，返回不再被任何版本引用、可以删除的文件 sha256。
func (s *Store) DeleteRelease(id int64) (orphan string, err error) {
	r, err := s.ReleaseByID(id)
	if err != nil {
		return "", err
	}
	if _, err := s.db.Exec(`DELETE FROM releases WHERE id=?`, id); err != nil {
		return "", err
	}
	if !s.releaseFileUsed(r.Sha256) {
		return r.Sha256, nil
	}
	return "", nil
}

// PruneReleases 每个平台只保留最近 keep 个版本，返回可以删除的文件。
func (s *Store) PruneReleases(platform string, keep int) []string {
	rows, err := s.db.Query(`SELECT id FROM releases WHERE platform=? ORDER BY build DESC LIMIT -1 OFFSET ?`, platform, keep)
	if err != nil {
		return nil
	}
	var ids []int64
	for rows.Next() {
		var id int64
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	var orphans []string
	for _, id := range ids {
		if o, err := s.DeleteRelease(id); err == nil && o != "" {
			orphans = append(orphans, o)
		}
	}
	return orphans
}

func (s *Store) releaseFileUsed(sha string) bool {
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM releases WHERE sha256=?`, sha).Scan(&n)
	return n > 0
}

// SetDeviceClient 记录设备上报的客户端版本（例如 "macos 0.4.0 (37)"），在管理后台展示。
func (s *Store) SetDeviceClient(id, client string) {
	s.db.Exec(`UPDATE devices SET client=? WHERE id=?`, client, id)
}

// ---------- 设备接口 ----------

func (h *Hub) releasePath(sha string) string { return filepath.Join(h.releaseDir, sha+".zip") }

type updateInfo struct {
	ID        int64  `json:"id"`
	Version   string `json:"version"`
	Build     int64  `json:"build"`
	Notes     string `json:"notes"`
	Size      int64  `json:"size"`
	Sha256    string `json:"sha256"`
	Signature string `json:"signature"`
	URL       string `json:"url"`
	Published string `json:"published_at"`
}

func (h *Hub) handleUpdate(w http.ResponseWriter, r *http.Request, d *Device) {
	cur, _ := strconv.ParseInt(r.URL.Query().Get("build"), 10, 64)
	w.Header().Set("Cache-Control", "no-store")
	rel, err := h.st.LatestRelease(d.Platform)
	if err != nil {
		apiErr(w, 500, "查询失败")
		return
	}
	if rel == nil || rel.Build <= cur {
		writeJSON(w, 200, map[string]any{"update": nil})
		return
	}
	writeJSON(w, 200, map[string]any{"update": updateInfo{
		ID: rel.ID, Version: rel.Version, Build: rel.Build, Notes: rel.Notes, Size: rel.Size,
		Sha256: rel.Sha256, Signature: rel.Signature, URL: fmt.Sprintf("/v1/update/%d", rel.ID),
		Published: time.Unix(rel.Created, 0).UTC().Format(time.RFC3339),
	}})
}

func (h *Hub) handleUpdateDownload(w http.ResponseWriter, r *http.Request, d *Device) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	rel, err := h.st.ReleaseByID(id)
	if err != nil || rel.Platform != d.Platform {
		apiErr(w, 404, "更新包不存在")
		return
	}
	f, err := os.Open(h.releasePath(rel.Sha256))
	if err != nil {
		apiErr(w, 410, "更新包文件已丢失")
		return
	}
	defer f.Close()
	fi, _ := f.Stat()
	name := fmt.Sprintf("Huijian-%s-%d.zip", rel.Version, rel.Build)
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	setServerHeader(w.Header(), "Sha256", rel.Sha256)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "private, max-age=0")
	http.ServeContent(w, r, name, fi.ModTime(), f)
}

// latestBuildHeader：在长轮询响应里告诉客户端最新构建号。
func (h *Hub) latestBuildHeader(w http.ResponseWriter, d *Device) {
	if rel, err := h.st.LatestRelease(d.Platform); err == nil && rel != nil {
		setServerHeader(w.Header(), "Latest-Build", strconv.FormatInt(rel.Build, 10))
	}
}

// ---------- 管理端口：发布 ----------

// adminBearer：给脚本用的管理 API 认证（Authorization: Bearer <管理令牌>）。
// 不使用 Cookie，因此不存在 CSRF 问题。
func (h *Hub) adminBearer(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || subtle.ConstantTimeCompare([]byte(sha256Hex(strings.TrimSpace(tok))), []byte(h.admin.tokenHash)) != 1 {
			time.Sleep(time.Second)
			apiErr(w, 401, "管理令牌无效")
			return
		}
		next(w, r)
	}
}

func (h *Hub) apiPublishRelease(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, h.maxUpload)
	mr, err := r.MultipartReader()
	if err != nil {
		apiErr(w, 400, "需要 multipart/form-data")
		return
	}
	fields := map[string]string{}
	var up *upFile
	defer func() {
		if up != nil && up.tmp != "" {
			os.Remove(up.tmp)
		}
	}()
	for {
		p, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			apiErr(w, 400, "读取上传内容失败："+err.Error())
			return
		}
		name := p.FormName()
		if name == "file" {
			if up != nil {
				apiErr(w, 400, "只能上传一个文件")
				return
			}
			if up, err = h.saveTemp(p, p.FileName(), p.Header.Get("Content-Type")); err != nil {
				apiErr(w, 400, "保存上传文件失败："+err.Error())
				return
			}
			continue
		}
		b, err := io.ReadAll(io.LimitReader(p, releaseMaxNotes+1))
		if err != nil || len(b) > releaseMaxNotes {
			apiErr(w, 400, "字段 "+name+" 过长")
			return
		}
		fields[name] = string(b)
	}

	rel := &Release{
		Platform:  strings.TrimSpace(fields["platform"]),
		Version:   strings.TrimSpace(fields["version"]),
		Notes:     fields["notes"], // 原样保存：说明文字在签名范围内，不能改动
		Sha256:    strings.ToLower(strings.TrimSpace(fields["sha256"])),
		Signature: strings.TrimSpace(fields["signature"]),
	}
	rel.Build, _ = strconv.ParseInt(strings.TrimSpace(fields["build"]), 10, 64)
	switch {
	case up == nil:
		apiErr(w, 400, "缺少 file")
		return
	case !rePlatform.MatchString(rel.Platform):
		apiErr(w, 400, "platform 格式不对")
		return
	case !reVersion.MatchString(rel.Version):
		apiErr(w, 400, "version 格式不对")
		return
	case rel.Build <= 0 || rel.Build > 1e9:
		apiErr(w, 400, "build 必须是正整数")
		return
	case !reSha256.MatchString(rel.Sha256) || rel.Sha256 != up.sha256:
		apiErr(w, 400, "sha256 与上传文件不一致")
		return
	}
	sig, err := base64.StdEncoding.DecodeString(rel.Signature)
	if err != nil || len(sig) != ed25519.SignatureSize {
		apiErr(w, 400, "signature 必须是 base64 编码的 64 字节 Ed25519 签名")
		return
	}
	// 可选：服务端也配置公钥时，上传即校验，尽早发现签错的包
	if pk := env("HUIJIAN_UPDATE_PUBKEY", ""); pk != "" {
		key, err := base64.StdEncoding.DecodeString(pk)
		if err != nil || len(key) != ed25519.PublicKeySize {
			apiErr(w, 500, "服务端 HUIJIAN_UPDATE_PUBKEY 配置错误")
			return
		}
		if !ed25519.Verify(key, releaseMessage(rel.Platform, rel.Build, rel.Version, rel.Sha256, rel.Notes), sig) {
			apiErr(w, 400, "签名校验失败")
			return
		}
	}
	if latest, err := h.st.LatestRelease(rel.Platform); err != nil {
		apiErr(w, 500, "查询失败")
		return
	} else if latest != nil && rel.Build <= latest.Build {
		apiErr(w, 409, fmt.Sprintf("build 必须大于当前最新版本的 %d（%s）", latest.Build, latest.Version))
		return
	}
	rel.Size = up.size
	dst := h.releasePath(rel.Sha256)
	if _, err := os.Stat(dst); err == nil {
		os.Remove(up.tmp)
	} else if err := os.Rename(up.tmp, dst); err != nil {
		apiErr(w, 500, "保存更新包失败")
		return
	}
	up.tmp = ""
	if err := h.st.InsertRelease(rel); err != nil {
		if !h.st.releaseFileUsed(rel.Sha256) {
			os.Remove(dst)
		}
		apiErr(w, 409, "写入失败（可能重复发布）："+err.Error())
		return
	}
	for _, o := range h.st.PruneReleases(rel.Platform, releaseKeep) {
		os.Remove(h.releasePath(o))
	}
	log.Printf("发布更新 %s %s (build %d, %d 字节)", rel.Platform, rel.Version, rel.Build, rel.Size)
	writeJSON(w, 200, map[string]any{"id": rel.ID, "platform": rel.Platform, "version": rel.Version, "build": rel.Build})
}

// ---------- 管理网页 ----------

func (h *Hub) adminDeleteRelease(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	o, err := h.st.DeleteRelease(id)
	if err != nil {
		redirectFlash(w, r, "/settings", "版本不存在")
		return
	}
	if o != "" {
		os.Remove(h.releasePath(o))
	}
	redirectFlash(w, r, "/settings", "已删除该版本")
}

// clientLabel 清洗客户端上报的版本字符串：只保留可打印字符，最长 64 字节。
func clientLabel(s string) string {
	s = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, strings.TrimSpace(s))
	if len(s) > 64 {
		s = s[:64]
		for !utf8.ValidString(s) {
			s = s[:len(s)-1]
		}
	}
	return s
}

// LatestReleaseVersion 某平台已发布的最新版本号（没有则为空）
func (s *Store) LatestReleaseVersion(platform string) string {
	var v string
	s.db.QueryRow(`SELECT version FROM releases WHERE platform=? ORDER BY build DESC LIMIT 1`, platform).Scan(&v)
	return v
}
