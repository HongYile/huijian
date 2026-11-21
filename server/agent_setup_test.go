package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// setupHome：隔离的 HOME，PATH 指向空目录（不会调用到本机真的 claude / cursor-agent），各 agent 的目录变量清空
func setupHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("LOCALAPPDATA", filepath.Join(home, "AppData", "Local"))
	t.Setenv("PATH", t.TempDir())
	for _, k := range []string{"CLAUDE_CONFIG_DIR", "CODEX_HOME", "HERMES_HOME", "QWEN_HOME", "PI_CODING_AGENT_DIR", "DSH_HOME"} {
		t.Setenv(k, "")
	}
	return home
}

func writeT(t *testing.T, p, s string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
		t.Fatal(err)
	}
}

func readT(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("读 %s：%v", p, err)
	}
	return string(b)
}

func TestAgentSetupTargets(t *testing.T) {
	home := setupHome(t)
	bin := `/opt/hj dir/huijian`

	claude := filepath.Join(home, ".claude.json")
	writeT(t, claude, `{"numStartups":3,"mcpServers":{"other":{"command":"x"}},"zzz":{"中文":true}}`)
	codex := filepath.Join(home, ".codex", "config.toml")
	codexOrig := "model = \"gpt-5\"\n\n[mcp_servers.other]\ncommand = \"x\"\n"
	writeT(t, codex, codexOrig)
	os.MkdirAll(filepath.Join(home, ".cursor"), 0o700) // Cursor：只有目录，mcp.json 由我们新建
	dshDesk := filepath.Join(home, ".dsh", "profiles", "desktop", "cordis.patch.yml")
	dshOrig := "# 注释\r\n- id: ui-chat\r\n  config:\r\n    transcriptView: detailed\r\n"
	writeT(t, dshDesk, dshOrig)
	dshHead := filepath.Join(home, ".dsh", "profiles", "headless", "cordis.patch.yml")
	writeT(t, dshHead, "# 模板\n[]\n")
	hermes := filepath.Join(home, ".hermes", "config.yaml")
	hermesOrig := "model: x\nmcp_servers:\n  other:\n    command: y\nskills:\n  enabled: true\n"
	writeT(t, hermes, hermesOrig)
	qwen := filepath.Join(home, ".qwen", "settings.json")
	writeT(t, qwen, `{"theme":"dark"}`)
	pi := filepath.Join(home, ".pi", "agent", "mcp.json")
	os.MkdirAll(filepath.Dir(pi), 0o700)
	// 用户自己装的同名 skill（例如开发副本）不能被覆盖
	ownSkill := filepath.Join(home, ".claude", "skills", "huijian", "SKILL.md")
	writeT(t, ownSkill, "我自己的")

	for _, tg := range agentTargets {
		if !tg.detect() {
			t.Fatalf("%s 应该被找到", tg.name)
		}
		if _, err := tg.configure(bin); err != nil {
			t.Fatalf("%s 配置失败：%v", tg.name, err)
		}
		if ok, where := tg.configured(); !ok {
			t.Fatalf("%s 应显示已接入（%s）", tg.name, where)
		}
		if tg.skillDir != nil {
			if err := installSkill(tg.skillDir()); err != nil {
				t.Fatal(err)
			}
		}
	}

	// Claude：键顺序不变，原有服务器保留，timeout 毫秒
	var cj map[string]any
	cs := readT(t, claude)
	json.Unmarshal([]byte(cs), &cj)
	if strings.Index(cs, "numStartups") > strings.Index(cs, "zzz") || !strings.Contains(cs, `"中文": true`) {
		t.Fatalf("Claude 配置的键顺序 / 中文被改了：%s", cs)
	}
	hj := cj["mcpServers"].(map[string]any)["huijian"].(map[string]any)
	if hj["command"] != bin || hj["timeout"] != float64(1900000) || cj["mcpServers"].(map[string]any)["other"] == nil {
		t.Fatalf("Claude 配置不对：%s", cs)
	}
	if !exists(claude + ".bak-huijian") {
		t.Fatal("Claude 配置应先备份")
	}
	// Codex：追加带标记的表，路径用字面量字符串
	if s := readT(t, codex); !strings.HasPrefix(s, codexOrig) || !strings.Contains(s, "command = '"+bin+"'") || !strings.Contains(s, "tool_timeout_sec = 1900") {
		t.Fatalf("Codex 配置不对：%s", s)
	}
	// Cursor：新建 mcp.json
	if s := readT(t, filepath.Join(home, ".cursor", "mcp.json")); !strings.Contains(s, `"huijian"`) || !strings.Contains(s, `"type": "stdio"`) {
		t.Fatalf("Cursor 配置不对：%s", s)
	}
	// Harness：保留 CRLF，条目 id 是 mcp-manager；headless 的 [] 被换掉
	if s := readT(t, dshDesk); !strings.HasPrefix(s, dshOrig) || !strings.Contains(s, "- id: mcp-manager\r\n") || !strings.Contains(s, "toolCallTimeoutMs: 1900000\r\n") || strings.Contains(strings.ReplaceAll(s, "\r\n", ""), "\n") {
		t.Fatalf("Harness 配置不对：%q", s)
	}
	if s := readT(t, dshHead); strings.Contains(s, "[]") || !strings.Contains(s, "- id: mcp-manager") {
		t.Fatalf("Harness headless 配置不对：%s", s)
	}
	// Hermes：插在已有 mcp_servers 下面，其他段不动
	hs := readT(t, hermes)
	if !strings.Contains(hs, "mcp_servers:\n  # >>> ") || !strings.Contains(hs, "  huijian:\n    command: '"+bin+"'\n    args: [mcp]\n    timeout: 1900\n") ||
		!strings.Contains(hs, "  other:\n    command: y\nskills:\n") {
		t.Fatalf("Hermes 配置不对：%s", hs)
	}
	if s := readT(t, qwen); !strings.HasPrefix(s, "{\n  \"theme\": \"dark\",") || !strings.Contains(s, `"timeout": 1900000`) {
		t.Fatalf("Qwen 配置不对：%s", s)
	}
	if s := readT(t, pi); !strings.Contains(s, `"timeout": 1900`) {
		t.Fatalf("Pi 配置不对：%s", s)
	}
	// skill：共用目录和 Hermes 目录装上了；用户自己的不覆盖
	for _, p := range []string{filepath.Join(home, ".agents", "skills", "huijian", "SKILL.md"), filepath.Join(home, ".hermes", "skills", "huijian", "SKILL.md")} {
		if s := readT(t, p); !strings.Contains(s, setupMark) || !strings.HasPrefix(s, "---\nname: huijian\n") {
			t.Fatalf("skill 没装上：%s", p)
		}
	}
	if readT(t, ownSkill) != "我自己的" {
		t.Fatal("用户自己的 skill 被覆盖了")
	}

	// 再运行一次：幂等（不会出现两段）
	for _, tg := range agentTargets {
		if _, err := tg.configure(bin); err != nil {
			t.Fatalf("%s 第二次配置失败：%v", tg.name, err)
		}
	}
	if n := strings.Count(readT(t, hermes), "# >>> "); n != 1 {
		t.Fatalf("Hermes 重复写入了 %d 段", n)
	}
	if n := strings.Count(readT(t, codex), "[mcp_servers.huijian]"); n != 1 {
		t.Fatalf("Codex 重复写入了 %d 段", n)
	}

	// 撤销：恢复原样（JSON 按原顺序重新排版）
	if err := agentSetupRemove("none"); err != nil {
		t.Fatal(err)
	}
	for _, tg := range agentTargets {
		if ok, _ := tg.configured(); ok {
			t.Fatalf("%s 撤销后仍显示已接入", tg.name)
		}
	}
	if s := readT(t, codex); s != codexOrig {
		t.Fatalf("Codex 撤销后不是原样：%q", s)
	}
	if s := readT(t, dshDesk); s != dshOrig {
		t.Fatalf("Harness 撤销后不是原样：%q", s)
	}
	if s := readT(t, dshHead); !strings.Contains(s, "[]") {
		t.Fatalf("Harness headless 撤销后应恢复 []：%q", s)
	}
	if s := readT(t, hermes); s != hermesOrig {
		t.Fatalf("Hermes 撤销后不是原样：%q", s)
	}
	if s := readT(t, claude); strings.Contains(s, "huijian") || !strings.Contains(s, `"other"`) {
		t.Fatalf("Claude 撤销不对：%s", s)
	}
	if s := readT(t, qwen); strings.Contains(s, "mcpServers") {
		t.Fatalf("Qwen 撤销后应删掉空的 mcpServers：%s", s)
	}
	if exists(filepath.Join(home, ".agents", "skills", "huijian")) || readT(t, ownSkill) != "我自己的" {
		t.Fatal("skill 撤销不对")
	}
}

func TestAgentSetupEdgeCases(t *testing.T) {
	home := setupHome(t)
	// Hermes：mcp_servers: {} 和没有 mcp_servers
	hermes := filepath.Join(home, ".hermes", "config.yaml")
	writeT(t, hermes, "mcp_servers: {}\nmodel: x\n")
	h := hermesTarget()
	if _, err := h.configure("/b/huijian"); err != nil {
		t.Fatal(err)
	}
	if s := readT(t, hermes); !strings.Contains(s, "mcp_servers:\n  huijian:\n") || strings.Contains(s, "{}") || !strings.HasSuffix(s, "model: x\n") {
		t.Fatalf("Hermes {} 处理不对：%s", s)
	}
	h.remove()
	if s := readT(t, hermes); s != "model: x\n" {
		t.Fatalf("Hermes {} 撤销后：%q", s)
	}
	os.Remove(hermes)
	if _, err := h.configure("/b/huijian"); err != nil {
		t.Fatal(err)
	}
	if s := readT(t, hermes); !strings.Contains(s, "mcp_servers:\n  huijian:\n") {
		t.Fatalf("Hermes 新建不对：%s", s)
	}
	// 用户自己写过 huijian：不动
	writeT(t, hermes, "mcp_servers:\n  huijian:\n    command: mine\n")
	if _, err := h.configure("/b/huijian"); err == nil {
		t.Fatal("Hermes 已有用户自己的 huijian 应报错")
	}
	codex := filepath.Join(home, ".codex", "config.toml")
	writeT(t, codex, "[mcp_servers.huijian]\ncommand = \"mine\"\n")
	if _, err := codexTarget().configure("/b/huijian"); err == nil {
		t.Fatal("Codex 已有用户自己的 huijian 应报错")
	}
	// Harness：已有用户自己的 mcp-manager 条目
	dsh := filepath.Join(home, ".dsh", "profiles", "desktop", "cordis.patch.yml")
	writeT(t, dsh, "- id: mcp-manager\n  config:\n    servers: {}\n")
	if _, err := dshTarget().configure("/b/huijian"); err == nil || !strings.Contains(err.Error(), "手动") {
		t.Fatalf("Harness 已有 mcp-manager 应报错：%v", err)
	}
	// JSON 带注释：不改，报错
	qwen := filepath.Join(home, ".qwen", "settings.json")
	writeT(t, qwen, "{\n  // 注释\n  \"a\": 1\n}\n")
	if _, err := qwenTarget().configure("/b/huijian"); err == nil {
		t.Fatal("带注释的 JSON 应报错")
	}
	if readT(t, qwen) != "{\n  // 注释\n  \"a\": 1\n}\n" {
		t.Fatal("带注释的 JSON 不应被改动")
	}
	// Windows 路径
	if got := tomlLiteral(`C:\Users\a\huijian.exe`); got != `'C:\Users\a\huijian.exe'` {
		t.Fatal(got)
	}
	if got := yamlQuote(`C:\it's\huijian.exe`); got != `'C:\it''s\huijian.exe'` {
		t.Fatal(got)
	}
	// Hermes：CRLF、四格缩进、mcp_servers 行带注释、引号写的 huijian、别的段里同名项不误报
	writeT(t, hermes, "model: x\r\nmcp_servers:   # 我的\r\n    other:\r\n        command: y\r\nother_section:\r\n  huijian: 不相干\r\n")
	orig := readT(t, hermes)
	if _, err := h.configure("/b/huijian"); err != nil {
		t.Fatalf("Hermes CRLF / 四格缩进：%v", err)
	}
	hs := readT(t, hermes)
	if strings.Count(hs, "mcp_servers:") != 1 || !strings.Contains(hs, "mcp_servers:   # 我的\r\n    # >>> ") ||
		!strings.Contains(hs, "    huijian:\r\n      command: '/b/huijian'\r\n") || strings.Contains(strings.ReplaceAll(hs, "\r\n", ""), "\n") {
		t.Fatalf("Hermes CRLF / 四格缩进写得不对：%q", hs)
	}
	h.remove()
	if readT(t, hermes) != orig {
		t.Fatalf("Hermes CRLF 撤销后不是原样：%q", readT(t, hermes))
	}
	writeT(t, hermes, "mcp_servers:\n  \"huijian\":\n    command: mine\n")
	if _, err := h.configure("/b/huijian"); err == nil {
		t.Fatal("引号写的 huijian 也应报错")
	}
	// JSON：用户自己的 huijian 不覆盖、撤销也不删；& < > 和 CRLF 保持
	cursor := filepath.Join(home, ".cursor", "mcp.json")
	writeT(t, cursor, "{\r\n  \"mcpServers\": {\"huijian\": {\"command\": \"mine\"}},\r\n  \"note\": \"a&b<c>\"\r\n}\r\n")
	if _, err := cursorTarget().configure("/b/huijian"); err == nil || !strings.Contains(err.Error(), "你自己写的") {
		t.Fatalf("用户自己的 huijian 应报错：%v", err)
	}
	if ok, _ := cursorTarget().remove(); ok || !strings.Contains(readT(t, cursor), "mine") {
		t.Fatal("撤销不应删用户自己的 huijian")
	}
	writeT(t, cursor, "{\r\n  \"note\": \"a&b<c>\"\r\n}\r\n")
	if _, err := cursorTarget().configure("/b/huijian"); err != nil {
		t.Fatal(err)
	}
	if cs := readT(t, cursor); !strings.Contains(cs, `"a&b<c>"`) || !strings.Contains(cs, "\r\n") || strings.Contains(strings.ReplaceAll(cs, "\r\n", ""), "\n") || !strings.Contains(cs, setupEnvMark) {
		t.Fatalf("JSON 转义 / CRLF / 标记不对：%q", cs)
	}
	if ok, _ := cursorTarget().remove(); !ok || exists(cursor+".bak-huijian") {
		t.Fatal("撤销应删掉 setup 写的项和备份")
	}
	// 标记块缺结束标记：不动
	if out, ok := stripBlock("a\n" + blockBegin + "\nb\nc\n"); ok || out != "a\n"+blockBegin+"\nb\nc\n" {
		t.Fatal("缺结束标记时不应删除")
	}
	// 选择
	ts := []agentTarget{{id: "a"}, {id: "b"}, {id: "c"}}
	if got := pickTargets(ts, ""); len(got) != 3 {
		t.Fatal("回车应选全部")
	}
	if got := pickTargets(ts, "n"); len(got) != 0 {
		t.Fatal("n 应都不选")
	}
	if got := pickTargets(ts, "3，1 3 9"); len(got) != 2 || got[0].id != "c" || got[1].id != "a" {
		t.Fatalf("按序号选不对：%v", got)
	}
}

// 完整流程：设备生成连接码 → setup 兑换、登录（设备批准）→ 写配置 → status → -remove
func TestAgentSetupFlow(t *testing.T) {
	f := newAgentFixture(t)
	home := setupHome(t)
	t.Setenv("HUIJIAN_URL", "")
	t.Setenv("HUIJIAN_AGENT_KEY", "")
	t.Setenv("HUIJIAN_AGENT_SESSION", "")
	writeT(t, filepath.Join(home, ".codex", "config.toml"), "")
	code := f.e.agentMust(200, "POST", "/v1/agent/connect-codes", f.tokB, nil)["code"].(string)

	done := make(chan error, 1)
	go func() {
		done <- agentSetupCmd([]string{"-u", f.e.srv.URL, "-name", "测试电脑", "-s", "st", "-yes", "-no-install", strings.ToLower(code)})
	}()
	f.approveNext(t)
	if err := <-done; err != nil {
		t.Fatalf("setup 失败：%v", err)
	}
	if srv, key := loadAgentKey("st"); srv != f.e.srv.URL || !strings.HasPrefix(key, "AK_") {
		t.Fatalf("setup 应保存 Agent key：%s", srv)
	}
	if fi, _ := os.Stat(filepath.Join(home, ".huijian", "agent", "st", "agent_key")); fi == nil || fi.Mode().Perm() != 0o600 {
		t.Fatal("agent_key 权限应为 0600")
	}
	ks := f.e.agentMust(200, "GET", "/v1/agent/keys", f.tokB, nil)["keys"].([]any)
	if ks[len(ks)-1].(map[string]any)["name"] != "测试电脑" {
		t.Fatalf("新 key 应带名字：%v", ks)
	}
	if !fileHasBlock(filepath.Join(home, ".codex", "config.toml")) {
		t.Fatal("Codex 应已接入")
	}
	// 再运行：已登录，跳过登录，不需要连接码
	if err := agentSetupCmd([]string{"-s", "st", "-yes", "-no-install"}); err != nil {
		t.Fatalf("第二次 setup：%v", err)
	}
	_, key1 := loadAgentKey("st")
	// 会话被结束后再运行（没给连接码）：用保存的 key 重新登录，不再要连接码，不多建 key
	s1, _ := loadAgentState("st")
	f.e.agentMust(200, "DELETE", "/v1/agent/sessions/"+s1.SessionID, f.tokA, nil)
	nKeys := len(f.e.agentMust(200, "GET", "/v1/agent/keys", f.tokB, nil)["keys"].([]any))
	go func() { done <- agentSetupCmd([]string{"-s", "st", "-yes", "-no-install"}) }()
	f.approveNext(t)
	if err := <-done; err != nil {
		t.Fatalf("会话结束后重新 setup：%v", err)
	}
	if n := len(f.e.agentMust(200, "GET", "/v1/agent/keys", f.tokB, nil)["keys"].([]any)); n != nKeys {
		t.Fatalf("不应多建 key：%d → %d", nKeys, n)
	}
	// 已登录但给了新连接码：照样兑换（换一把新 key）、重新登录
	code2 := f.e.agentMust(200, "POST", "/v1/agent/connect-codes", f.tokB, nil)["code"].(string)
	go func() { done <- agentSetupCmd([]string{"-u", f.e.srv.URL, "-s", "st", "-yes", "-no-install", code2}) }()
	f.approveNext(t)
	if err := <-done; err != nil {
		t.Fatalf("带新连接码 setup：%v", err)
	}
	if _, key2 := loadAgentKey("st"); key2 == key1 || key2 == "" {
		t.Fatal("带新连接码时应换成新 key")
	}
	// 撤销：配置删掉、会话结束、key 文件删掉
	if err := agentSetupCmd([]string{"-s", "st", "-remove"}); err != nil {
		t.Fatal(err)
	}
	if fileHasBlock(filepath.Join(home, ".codex", "config.toml")) {
		t.Fatal("撤销后 Codex 不应再有 huijian")
	}
	if _, key := loadAgentKey("st"); key != "" {
		t.Fatal("撤销后应删掉保存的 key")
	}
	// 撤销时在服务端吊销了这台电脑的 key（列表里不再有「测试电脑」）
	for _, k := range f.e.agentMust(200, "GET", "/v1/agent/keys", f.tokB, nil)["keys"].([]any) {
		if k.(map[string]any)["name"] == "测试电脑" && k.(map[string]any)["prefix"] != key1[:7] {
			t.Fatalf("撤销后服务端仍有这台电脑的当前 key：%v", k)
		}
	}
	// 用过的连接码不能再用
	if c, _ := f.e.call("POST", "/v1/agent/connect", "", map[string]any{"code": code, "name": "x"}); c != 403 {
		t.Fatalf("连接码只能用一次：%d", c)
	}
}
