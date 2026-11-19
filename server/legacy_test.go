package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestLegacyEnvAndConf(t *testing.T) {
	t.Setenv("HONGYAN_LEGACYTEST_A", "old")
	t.Setenv("BEACON_LEGACYTEST_B", "older")
	t.Setenv("HONGYAN_LEGACYTEST_C", "old")
	t.Setenv("HUIJIAN_LEGACYTEST_C", "new")
	t.Setenv("HONGYAN_LEGACYTEST_D", "hongyan")
	t.Setenv("BEACON_LEGACYTEST_D", "beacon")
	t.Cleanup(func() {
		os.Unsetenv("HUIJIAN_LEGACYTEST_A")
		os.Unsetenv("HUIJIAN_LEGACYTEST_B")
		os.Unsetenv("HUIJIAN_LEGACYTEST_D")
	})
	migrateLegacyEnv()
	for k, want := range map[string]string{"HUIJIAN_LEGACYTEST_A": "old", "HUIJIAN_LEGACYTEST_B": "older", "HUIJIAN_LEGACYTEST_C": "new", "HUIJIAN_LEGACYTEST_D": "hongyan"} {
		if got := os.Getenv(k); got != want {
			t.Errorf("%s = %q，应为 %q", k, got, want)
		}
	}
	m := map[string]string{"HONGYAN_PUBLIC_PORT": "1", "HONGYAN_DATA": "/old", "HUIJIAN_DATA": "/new", "BEACON_X": "b", "HONGYAN_X": "h"}
	migrateLegacyConf(m)
	if m["HUIJIAN_PUBLIC_PORT"] != "1" || m["HUIJIAN_DATA"] != "/new" || m["HUIJIAN_X"] != "h" {
		t.Errorf("配置文件旧前缀映射不对：%v", m)
	}
}

func TestLegacyFiles(t *testing.T) {
	dir := t.TempDir()
	// 改名前的 hongyan.db 原名沿用（旧程序回退时还要找它）；beacon.db 改名为 huijian.db
	os.WriteFile(filepath.Join(dir, "hongyan.db"), []byte("db"), 0o600)
	if p := dbPath(dir); filepath.Base(p) != "hongyan.db" || dbFileName(dir) != "hongyan.db" {
		t.Fatalf("应沿用 hongyan.db：%s", p)
	}
	b := t.TempDir()
	os.WriteFile(filepath.Join(b, "beacon.db"), []byte("db"), 0o600)
	os.WriteFile(filepath.Join(b, "beacon.db-wal"), []byte("wal"), 0o600)
	if p := dbPath(b); filepath.Base(p) != "huijian.db" || !fileExists(p+"-wal") || fileExists(filepath.Join(b, "beacon.db")) {
		t.Fatalf("beacon.db 应改名为 huijian.db：%s", p)
	}
	// 已下载的新版本：只有旧名时用旧名，新旧都有时用新名
	bin := binDir(dir)
	os.MkdirAll(bin, 0o755)
	os.WriteFile(filepath.Join(bin, "hongyan-0.7.0"), []byte("x"), 0o755)
	if p := stagedFile(dir, "0.7.0"); filepath.Base(p) != "hongyan-0.7.0" {
		t.Fatalf("应沿用旧名下载的程序：%s", p)
	}
	os.WriteFile(filepath.Join(bin, "huijian-0.7.0"), []byte("x"), 0o755)
	if p := stagedFile(dir, "0.7.0"); filepath.Base(p) != "huijian-0.7.0" {
		t.Fatalf("新名存在时应优先：%s", p)
	}
	if p := stagedFile(dir, "0.8.0"); filepath.Base(p) != "huijian-0.8.0" {
		t.Fatalf("都不存在时用新名：%s", p)
	}
	// 目录标记与临时文件
	if !isMarkerName(".hongyan") || !isMarkerName(".huijian") || isMarkerName("hongyan") {
		t.Error("目录标记识别不对")
	}
	if !hasPartSuffix("a.png.hongyan-part") || !hasPartSuffix("a.png.huijian-part") || hasPartSuffix("a.part") {
		t.Error("临时文件识别不对")
	}
}

// 外部附件目录里只有旧版本写的 .hongyan 标记：仍视为已挂载，并补写新标记
func TestLegacyMarkerDir(t *testing.T) {
	st, err := OpenStore(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	nas := t.TempDir()
	os.WriteFile(filepath.Join(nas, ".hongyan"), []byte("old"), 0o640)
	g := &dirGuard{st: st, dir: nas, kind: "files"}
	st.SetKV("marker:files:"+absPath(nas), "1") // 以前用过这个目录
	if err := g.ready(); err != nil {
		t.Fatalf("有旧标记时不应报未挂载：%v", err)
	}
	if !fileExists(filepath.Join(nas, ".huijian")) {
		t.Error("应补写新标记 .huijian")
	}
	os.Remove(filepath.Join(nas, ".hongyan"))
	os.Remove(filepath.Join(nas, ".huijian"))
	if err := g.ready(); err == nil {
		t.Error("标记都不见了应报未挂载")
	}
}

func TestLegacyHeaders(t *testing.T) {
	r := httptest.NewRequest("GET", "/", nil)
	r.Header.Set("X-Hongyan-Client", "old")
	if clientHeader(r.Header, "Client") != "old" {
		t.Error("应识别旧请求头")
	}
	r.Header.Set("X-Huijian-Client", "new")
	if clientHeader(r.Header, "Client") != "new" {
		t.Error("新请求头优先")
	}
	h := http.Header{}
	setServerHeader(h, "Server", "0.7.0")
	if h.Get("X-Huijian-Server") != "0.7.0" || h.Get("X-Hongyan-Server") != "0.7.0" {
		t.Error("响应头应新旧都写")
	}
}

// 默认数据目录：以里面有数据库为准；一键更新在旧部署里留旧名硬链接，删除时新旧一起删；旧快照参与排序
func TestLegacyDataDirStagedSnapshots(t *testing.T) {
	root := t.TempDir()
	def := filepath.Join(root, "huijian")
	old := filepath.Join(root, "hongyan")
	os.MkdirAll(def, 0o755) // 新目录存在但是空的（例如先放了配置文件）
	os.MkdirAll(old, 0o755)
	os.WriteFile(filepath.Join(old, "hongyan.db"), []byte("db"), 0o600)
	if d := pickDataDir(def); d != old {
		t.Fatalf("应选有数据库的旧目录：%s", d)
	}
	os.WriteFile(filepath.Join(def, "huijian.db"), []byte("db"), 0o600)
	if d := pickDataDir(def); d != def {
		t.Fatalf("新目录有数据库时用新目录：%s", d)
	}

	os.MkdirAll(binDir(old), 0o755)
	os.WriteFile(filepath.Join(binDir(old), "huijian-0.7.1"), []byte("bin"), 0o755)
	linkLegacyStaged(old, "0.7.1")
	if !fileExists(filepath.Join(binDir(old), "hongyan-0.7.1")) {
		t.Fatal("旧部署应留旧名链接")
	}
	removeStaged(old, "0.7.1")
	if fileExists(filepath.Join(binDir(old), "hongyan-0.7.1")) || fileExists(filepath.Join(binDir(old), "huijian-0.7.1")) {
		t.Fatal("删除时新旧两个名字都要删")
	}
	os.MkdirAll(binDir(def), 0o755)
	os.WriteFile(filepath.Join(binDir(def), "huijian-0.7.1"), []byte("bin"), 0o755)
	linkLegacyStaged(def, "0.7.1")
	if fileExists(filepath.Join(binDir(def), "hongyan-0.7.1")) {
		t.Fatal("新部署不需要旧名链接")
	}

	bk := t.TempDir()
	os.MkdirAll(filepath.Join(bk, "db"), 0o755)
	for _, n := range []string{"huijian-20261120-010000-a.db", "hongyan-20261119-010000-a.db", "hongyan-20261121-010000-a.db", "other.db"} {
		os.WriteFile(filepath.Join(bk, "db", n), nil, 0o600)
	}
	got := listSnapshots(bk)
	want := []string{"hongyan-20261119-010000-a.db", "huijian-20261120-010000-a.db", "hongyan-20261121-010000-a.db"}
	if len(got) != 3 || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] {
		t.Fatalf("快照应按时间排序且包含旧前缀：%v", got)
	}
}
