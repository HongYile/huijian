package main

// 不经过 GitHub 的服务端更新：
//
//   - 管理后台「服务端更新」卡片手动上传：程序文件 + update-server.json（服务器下载不了 GitHub 时用）；
//   - 开发机推送：`huijian server-push -manifest update-server.json` → 管理端口的 POST /api/server-update（管理令牌）。
//
// 两者都只在管理端口上，需要登录会话或管理令牌；收到的文件和一键更新下载的文件走同一个 installVerified，
// 签名、sha256、大小、版本的校验一项不少。

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

const maxManifestSize = 1 << 20 // update-server.json 的大小上限

// maxServerUpload：上传请求体上限 = 程序上限 + 清单上限 + multipart 头部的余量
const maxServerUpload = maxServerBinary + maxManifestSize + 64<<10

// cleanUpdateTemps：启动时清理上次没处理完的上传临时文件（下载的部分文件 .download 保留，用于续传）
func cleanUpdateTemps(data string) {
	ents, _ := filepath.Glob(filepath.Join(binDir(data), ".upload-*"))
	for _, p := range ents {
		os.Remove(p)
	}
}

// receiveServerUpdate 读取 multipart 里的 manifest（update-server.json）和 file（程序），
// 校验本平台条目的签名、文件的 sha256 和大小、版本比当前新。通过后返回清单和 bin/ 里的临时文件路径；
// 失败时临时文件已删除。上传的文件名一律忽略，安装时的文件名只由验过签的版本号决定。
func (h *Hub) receiveServerUpdate(w http.ResponseWriter, r *http.Request) (m *serverManifestFile, tmp string, err error) {
	defer func() {
		if err != nil && tmp != "" {
			os.Remove(tmp)
			tmp = ""
		}
	}()
	r.Body = http.MaxBytesReader(w, r.Body, maxServerUpload)
	mr, err := r.MultipartReader()
	if err != nil {
		return nil, "", errors.New("需要 multipart/form-data")
	}
	dir := binDir(h.dataDir)
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, "", fmt.Errorf("创建 %s 失败：%v", dir, err)
	}
	var raw []byte
	var size int64
	for {
		p, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, tmp, uploadErr(err)
		}
		switch p.FormName() {
		case "manifest":
			if raw != nil {
				return nil, tmp, errors.New("只能有一个 update-server.json")
			}
			if raw, err = io.ReadAll(io.LimitReader(p, maxManifestSize+1)); err != nil {
				return nil, tmp, uploadErr(err)
			}
			if len(raw) > maxManifestSize {
				return nil, tmp, errors.New("update-server.json 过大")
			}
		case "file":
			if tmp != "" {
				return nil, tmp, errors.New("只能上传一个程序文件")
			}
			f, err := os.CreateTemp(dir, ".upload-*")
			if err != nil {
				return nil, "", err
			}
			tmp = f.Name()
			fw := &fileWriter{f: f}
			size, err = io.Copy(fw, io.LimitReader(p, maxServerBinary+1))
			if cerr := f.Close(); cerr != nil && fw.err == nil {
				fw.err = cerr
			}
			if fw.err != nil {
				return nil, tmp, fmt.Errorf("写入失败或磁盘空间不足：%v", fw.err)
			}
			if err != nil {
				return nil, tmp, uploadErr(err)
			}
			if size > maxServerBinary {
				return nil, tmp, fmt.Errorf("程序文件超过 %s", humanBytes(maxServerBinary))
			}
		default:
			io.Copy(io.Discard, io.LimitReader(p, 64<<10))
		}
	}
	switch {
	case len(raw) == 0:
		return nil, tmp, errors.New("缺少 update-server.json")
	case tmp == "" || size == 0:
		return nil, tmp, errors.New("缺少程序文件")
	}
	m = &serverManifestFile{}
	if err := json.Unmarshal(raw, m); err != nil {
		return nil, tmp, errors.New("update-server.json 格式不对")
	}
	bin, err := verifyServerBinary(m, serverPlatform(), updatePubKey())
	if err != nil {
		return nil, tmp, err
	}
	if !versionLess(version, m.Version) {
		return nil, tmp, fmt.Errorf("v%s 不比当前的 v%s 新，不需要更新", m.Version, version)
	}
	if sum, err := fileSha256(tmp); err != nil || size != bin.Size || sum != bin.Sha256 {
		return nil, tmp, fmt.Errorf("程序文件和 update-server.json 里 %s 的条目不一致（是不是选错了平台的文件？这台服务器是 %s）",
			serverPlatform(), serverPlatform())
	}
	return m, tmp, nil
}

// fileWriter：区分「写盘失败」和「读取上传内容失败」
type fileWriter struct {
	f   *os.File
	err error
}

func (w *fileWriter) Write(b []byte) (int, error) {
	n, err := writeChunk(w.f, b)
	if err != nil {
		w.err = err
	}
	return n, err
}

func uploadErr(err error) error {
	var mbe *http.MaxBytesError
	if errors.As(err, &mbe) {
		return fmt.Errorf("上传内容超过 %s", humanBytes(maxServerUpload))
	}
	return fmt.Errorf("读取上传内容失败：%v", err)
}

// ---------- 管理网页 ----------

// adminUploadUpdate：管理后台手动上传。收到并校验通过后在后台安装（和一键更新一样显示进度），页面马上返回
func (h *Hub) adminUploadUpdate(w http.ResponseWriter, r *http.Request) {
	if err := h.beginApply(); err != nil {
		redirectFlash(w, r, "/settings#update", err.Error())
		return
	}
	h.setProgress("接收上传的文件")
	m, tmp, err := h.receiveServerUpdate(w, r)
	if err != nil {
		h.abortApply()
		log.Printf("服务端更新：拒绝上传的文件：%v", err)
		redirectFlash(w, r, "/settings#update", "上传的更新没有通过校验："+err.Error())
		return
	}
	log.Printf("服务端更新：管理后台上传了 %s（签名校验通过）", m.Version)
	go func() { h.finishApply(h.installVerified(m, tmp, false)) }()
	redirectFlash(w, r, "/settings#update", "签名校验通过，正在安装 v"+m.Version+"，完成后服务自动重启")
}

// adminUpdateStatus：页面在更新进行中每秒轮询，显示进度；完成（或进程被替换）后刷新整页
func (h *Hub) adminUpdateStatus(w http.ResponseWriter, r *http.Request) {
	h.upd.mu.Lock()
	defer h.upd.mu.Unlock()
	writeJSON(w, 200, map[string]any{"version": version, "applying": h.upd.applying, "stage": h.upd.stage, "error": h.upd.applyErr})
}

// adminSetUpdateProxy：设置或清除只用于服务端更新的下载代理
func (h *Hub) adminSetUpdateProxy(w http.ResponseWriter, r *http.Request) {
	v := strings.TrimSpace(r.FormValue("proxy"))
	if r.FormValue("clear") != "" {
		h.st.SetKV(updProxyKey, "")
		setPageProxy("")
		redirectFlash(w, r, "/settings#update", "已清除管理页设置的下载代理，现在："+proxyHint())
		return
	}
	if v == "" {
		redirectFlash(w, r, "/settings#update", "请填写代理地址，或点「清除」")
		return
	}
	u, err := parseUpdateProxy(v)
	if err != nil {
		redirectFlash(w, r, "/settings#update", err.Error())
		return
	}
	h.st.SetKV(updProxyKey, u.String())
	setPageProxy(u.String())
	redirectFlash(w, r, "/settings#update", "下载代理已设置为 "+maskURL(u)+"（只用于服务端更新）")
}

// ---------- 推送 API（管理端口，Bearer 管理令牌） ----------

// apiServerUpdateInfo：GET /api/server-update，server-push 先用它确认对方的平台和版本
func (h *Hub) apiServerUpdateInfo(w http.ResponseWriter, r *http.Request) {
	h.upd.mu.Lock()
	applying := h.upd.applying
	h.upd.mu.Unlock()
	writeJSON(w, 200, map[string]any{"version": version, "platform": serverPlatform(), "enabled": selfUpdateEnabled(), "applying": applying})
}

// apiServerUpdatePush：POST /api/server-update（multipart：manifest、file）。
// 同步完成校验、试运行、备份和写入，成功后返回 JSON，然后平滑重启到新程序。
func (h *Hub) apiServerUpdatePush(w http.ResponseWriter, r *http.Request) {
	if err := h.beginApply(); err != nil {
		code := 409
		if !selfUpdateEnabled() {
			code = 403
		}
		apiErr(w, code, err.Error())
		return
	}
	h.setProgress("接收推送的文件")
	m, tmp, err := h.receiveServerUpdate(w, r)
	if err != nil {
		h.abortApply()
		log.Printf("服务端更新：拒绝推送的文件：%v", err)
		apiErr(w, 400, err.Error())
		return
	}
	log.Printf("服务端更新：收到推送的 %s（签名校验通过）", m.Version)
	path, err := h.installVerified(m, tmp, false)
	if err != nil {
		h.finishApply("", err)
		apiErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "version": m.Version, "previous": version, "platform": serverPlatform(), "restarting": true})
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
	h.finishApply(path, nil) // 平滑关闭会等这个请求结束，响应能完整发出
}
