package main

// 旧名兼容：项目曾叫 Beacon、鸿雁（Hongyan），现名回笺（Huijian）。
// 老部署里的环境变量、配置文件、数据目录、数据库、目录标记、已下载的新版本、命令行发件箱都继续可用，
// 老客户端发来的请求头也照常识别。新名字优先，旧名字只在新名字缺失时使用。

import (
	"os"
	"path/filepath"
	"strings"
)

// legacyPrefixes：旧的环境变量 / 配置项前缀，按新到旧排列
var legacyPrefixes = []string{"HONGYAN_", "BEACON_"}

// legacyNames：旧的文件名前缀（数据库、配置文件、目录、程序名）
var legacyNames = []string{"hongyan", "beacon"}

// migrateLegacyEnv：把旧前缀的环境变量映射到 HUIJIAN_*（已设置新名字的不覆盖）。启动时最先调用。
// 同一项新旧前缀都有时：新名 > HONGYAN_ > BEACON_（按 legacyPrefixes 顺序，先映射的不会被覆盖）。
func migrateLegacyEnv() {
	env := os.Environ()
	for _, p := range legacyPrefixes {
		for _, kv := range env {
			k, v, ok := strings.Cut(kv, "=")
			if !ok || v == "" {
				continue
			}
			if rest, found := strings.CutPrefix(k, p); found {
				if nk := "HUIJIAN_" + rest; os.Getenv(nk) == "" {
					os.Setenv(nk, v)
				}
			}
		}
	}
}

// migrateLegacyConf：配置文件里的旧前缀配置项同样映射到 HUIJIAN_*
func migrateLegacyConf(m map[string]string) {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	for _, p := range legacyPrefixes {
		for _, k := range keys {
			if rest, found := strings.CutPrefix(k, p); found && m[k] != "" {
				if nk := "HUIJIAN_" + rest; m[nk] == "" {
					m[nk] = m[k]
				}
			}
		}
	}
}

// legacyPath：把路径里的 huijian / Huijian 换成旧名，返回所有候选（不检查是否存在）
func legacyPaths(p string) []string {
	var out []string
	for _, n := range legacyNames {
		r := strings.NewReplacer("huijian", n, "Huijian", strings.ToUpper(n[:1])+n[1:])
		if q := r.Replace(p); q != p {
			out = append(out, q)
		}
	}
	return out
}

// preferExisting：新路径存在就用新路径；否则用第一个存在的旧路径；都不存在返回新路径
func preferExisting(p string) string {
	if p == "" || fileExists(p) {
		return p
	}
	for _, q := range legacyPaths(p) {
		if fileExists(q) {
			return q
		}
	}
	return p
}

// 目录标记与复制中的临时文件：旧版本写下的 .hongyan / .hongyan-part 也认
func isMarkerName(n string) bool {
	if n == markerName {
		return true
	}
	for _, l := range legacyNames {
		if n == "."+l {
			return true
		}
	}
	return false
}

func hasPartSuffix(n string) bool {
	if strings.HasSuffix(n, partSuffix) {
		return true
	}
	for _, l := range legacyNames {
		if strings.HasSuffix(n, "."+l+"-part") {
			return true
		}
	}
	return false
}

// legacyMarkerIn：目录里旧版本写下的标记文件（没有返回空）
func legacyMarkerIn(dir string) string {
	for _, l := range legacyNames {
		if p := filepath.Join(dir, "."+l); fileExists(p) {
			return p
		}
	}
	return ""
}

// clientHeader：读取客户端请求头，兼容旧名 X-Hongyan-*（name 不带前缀，例如 "Client"）
func clientHeader(h interface{ Get(string) string }, name string) string {
	if v := h.Get("X-Huijian-" + name); v != "" {
		return v
	}
	return h.Get("X-Hongyan-" + name)
}

// setServerHeader：响应头新旧两个名字都写，老客户端（重装前）照常识别
func setServerHeader(h interface{ Set(string, string) }, name, v string) {
	h.Set("X-Huijian-"+name, v)
	h.Set("X-Hongyan-"+name, v)
}

// dbFileName：数据目录里正在用的数据库文件名。huijian.db 优先；只有改名前的 hongyan.db 时沿用它
func dbFileName(dataDir string) string {
	if !fileExists(filepath.Join(dataDir, "huijian.db")) && fileExists(filepath.Join(dataDir, "hongyan.db")) {
		return "hongyan.db"
	}
	return "huijian.db"
}

// hasDB：目录里有任何一代的数据库
func hasDB(dir string) bool {
	for _, n := range append([]string{"huijian"}, legacyNames...) {
		if fileExists(filepath.Join(dir, n+".db")) {
			return true
		}
	}
	return false
}

// pickDataDir：默认数据目录以「里面有数据库」为准在新旧位置之间选择
// （只看目录是否存在不行：配置文件放到新默认位置时可能先建出了空的新目录）
func pickDataDir(def string) string {
	for _, d := range append([]string{def}, legacyPaths(def)...) {
		if hasDB(d) {
			return d
		}
	}
	return def
}

// linkLegacyStaged：改名前部署的数据目录（还在用 hongyan.db）里，为下载的新版本再留一个旧名硬链接
// bin/hongyan-<版本>：容器重建或连续启动失败回退到镜像里的旧程序时，旧程序只认这个名字
func linkLegacyStaged(data, ver string) {
	if dbFileName(data) != "hongyan.db" {
		return
	}
	p := filepath.Join(binDir(data), "hongyan-"+ver)
	os.Remove(p)
	os.Link(filepath.Join(binDir(data), "huijian-"+ver), p) // 失败也没关系：新程序本身仍可用
}

// removeStaged：删除某个下载版本的新旧两个文件名
func removeStaged(data, ver string) {
	if !reVersion.MatchString(ver) {
		return
	}
	for _, n := range append([]string{"huijian"}, legacyNames...) {
		os.Remove(filepath.Join(binDir(data), n+"-"+ver))
	}
}

// snapshotStamp：备份快照文件名里前缀之后的部分（时间戳-实例），不是快照时返回空
func snapshotStamp(n string) string {
	if !strings.HasSuffix(n, ".db") {
		return ""
	}
	for _, p := range append([]string{"huijian"}, legacyNames...) {
		if rest, ok := strings.CutPrefix(n, p+"-"); ok {
			return rest
		}
	}
	return ""
}
