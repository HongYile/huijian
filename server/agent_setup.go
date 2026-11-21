package main

// huijian agent setup：一步接入（docs/agent-mcp.md §7.1）。
//   1. 把自己装到固定位置（Windows：%LOCALAPPDATA%\Programs\huijian，加进用户 PATH；macOS / Linux：已在 PATH 里就不动，否则 ~/.local/bin）
//   2. 用连接码换一把这台电脑专用的 Agent key（存在 ~/.huijian/agent/<槽位>/agent_key，0600），然后照常登录（设备核对 6 位核对码后批准）
//   3. 找出这台电脑上装了哪些 agent，把 huijian mcp 写进它们的配置、装上 skill（写之前备份，写入的内容带标记，-remove 原样撤销）
// huijian agent status 列出接入情况；huijian agent setup -remove 撤销全部接入并结束会话。

import (
	"bufio"
	_ "embed"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
)

const setupMark = "huijian agent setup" // 写进配置的标记（注释 / 说明里都带这个字符串）

// agentTarget：一种 agent 的接入方式
type agentTarget struct {
	id, name string
	// detect：这台电脑上有没有装（找到配置目录或命令就算）
	detect func() bool
	// configure：写入 MCP 配置（bin 为 huijian 的绝对路径），返回给用户看的说明（例如「重启后生效」）
	configure func(bin string) (string, error)
	// remove：撤销 configure 写入的内容；没写过返回 false
	remove func() (bool, error)
	// configured：现在的配置里有没有 huijian，返回配置文件位置（给 status 看）
	configured func() (bool, string)
	// skillDir：用户级 skill 目录（装 SKILL.md）；没有 skill 机制时为 nil
	skillDir func() string
}

var agentTargets []agentTarget // 在 agent_targets.go 里注册

//go:embed agent_skill.md
var agentSkillMD string

func agentSetupCmd(args []string) error {
	fs := flag.NewFlagSet("agent setup", flag.ContinueOnError)
	server := fs.String("u", defaultURLs(), "回笺服务器地址")
	host, _ := os.Hostname()
	name := fs.String("name", env("HUIJIAN_AGENT_NAME", strings.TrimSuffix(host, ".local")+" agent"), "在回笺里显示的名字")
	slot := fs.String("s", defaultSlot(), "会话槽位")
	only := fs.String("agents", "", "只接入这些 agent（逗号分隔，如 claude,codex；默认问你）")
	yes := fs.Bool("yes", false, "不提问：接入找到的全部 agent")
	remove := fs.Bool("remove", false, "撤销：删除写入各 agent 的配置和 skill，结束会话")
	noInstall := fs.Bool("no-install", false, "不把 huijian 复制到固定位置（用当前程序的路径）")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *remove {
		return agentSetupRemove(*slot)
	}
	in := bufio.NewReader(os.Stdin)

	// 1. 装到固定位置
	bin, err := os.Executable()
	if err != nil {
		return err
	}
	if b, err := filepath.EvalSymlinks(bin); err == nil {
		bin = b
	}
	if !*noInstall {
		if b, note, err := installSelf(bin); err != nil {
			fmt.Fprintf(os.Stderr, "⚠️ 没能把 huijian 装到固定位置（%v），配置里用当前路径 %s\n", err, bin)
		} else {
			bin = b
			if note != "" {
				fmt.Fprintln(os.Stderr, note)
			}
		}
	}

	// 2. 登录（已有有效会话就跳过）
	srv := strings.TrimRight(strings.Split(*server, ",")[0], "/")
	if old, _ := loadAgentState(*slot); old != nil && old.Token != "" && (srv == "" || old.Server == srv) {
		if _, err := agentReq("GET", old.Server, "/v1/agent/replies?wait=0", old.Token, nil, 20*time.Second); err == nil {
			fmt.Fprintf(os.Stderr, "✅ 已经登录：「%s」（%s），跳过登录\n", old.Name, old.Server)
			srv = old.Server
			goto configure
		}
	}
	if srv == "" {
		srv = strings.TrimRight(prompt(in, "回笺服务器地址（如 https://push.example.com）："), "/")
		if srv == "" {
			return errors.New("缺少服务器地址")
		}
	}
	{
		code := strings.TrimSpace(fs.Arg(0))
		key := strings.TrimSpace(env("HUIJIAN_AGENT_KEY", ""))
		if code == "" && !strings.HasPrefix(key, "AK_") {
			code = prompt(in, "连接码（回笺「设置 → Pushkey」→「连接 agent」→ 生成连接码）：")
		}
		if code != "" {
			out, err := agentReq("POST", srv, "/v1/agent/connect", "", map[string]any{"code": code, "name": *name}, 20*time.Second)
			if err != nil {
				return err
			}
			key, _ = out["key"].(string)
			if !strings.HasPrefix(key, "AK_") {
				return errors.New("服务器没有返回 Agent key")
			}
			if err := saveAgentKey(*slot, srv, key); err != nil {
				return fmt.Errorf("保存 Agent key 失败：%v", err)
			}
			fmt.Fprintln(os.Stderr, "✅ 连接码有效，已为这台电脑新建 Agent key（只存在本机）")
		}
		if err := agentLoginCmd([]string{"-u", srv, "-k", key, "-name", *name, "-s", *slot}); err != nil {
			return err
		}
	}

configure:
	// 3. 接入 agent
	var found []agentTarget
	for _, t := range agentTargets {
		if t.detect() {
			found = append(found, t)
		}
	}
	if len(found) == 0 {
		fmt.Fprintln(os.Stderr, "没有找到已安装的 agent（支持：", targetNames(agentTargets), "）。装好后再运行 huijian agent setup 即可（不用再输连接码）。")
		return nil
	}
	chosen := found
	switch {
	case *only != "":
		chosen = nil
		for _, id := range strings.Split(*only, ",") {
			t := findTarget(strings.TrimSpace(id))
			if t == nil {
				return fmt.Errorf("不认识的 agent：%s（可选：%s）", id, targetIDs())
			}
			chosen = append(chosen, *t)
		}
	case !*yes:
		fmt.Fprintln(os.Stderr, "找到这些 agent：")
		for i, t := range found {
			fmt.Fprintf(os.Stderr, "  %d. %s\n", i+1, t.name)
		}
		ans := prompt(in, "要接入哪些？直接回车 = 全部，或输入序号（如 1,3），n = 都不接入：")
		chosen = pickTargets(found, ans)
	}
	var lines []string
	for _, t := range chosen {
		note, err := t.configure(bin)
		if err != nil {
			lines = append(lines, fmt.Sprintf("❌ %s：%v", t.name, err))
			continue
		}
		if t.skillDir != nil {
			if dir := t.skillDir(); dir != "" {
				if err := installSkill(dir); err != nil {
					note += fmt.Sprintf("（skill 没装上：%v）", err)
				}
			}
		}
		lines = append(lines, fmt.Sprintf("✅ %s：%s", t.name, note))
	}
	fmt.Fprintln(os.Stderr, strings.Join(lines, "\n"))
	fmt.Fprintln(os.Stderr, "完成。重启上面的 agent 后，它就能用 notify / ask / check_replies 给你发消息、问你问题。")
	fmt.Fprintln(os.Stderr, "查看接入情况：huijian agent status；撤销：huijian agent setup -remove")
	return nil
}

func agentSetupRemove(slot string) error {
	var lines []string
	for _, t := range agentTargets {
		ok, err := t.remove()
		if err != nil {
			lines = append(lines, fmt.Sprintf("❌ %s：%v", t.name, err))
		} else if ok {
			lines = append(lines, "✅ 已从 "+t.name+" 撤销")
		}
		if t.skillDir != nil {
			if dir := t.skillDir(); dir != "" {
				removeSkill(dir)
			}
		}
	}
	if len(lines) == 0 {
		lines = append(lines, "各 agent 的配置里都没有 huijian")
	}
	fmt.Fprintln(os.Stderr, strings.Join(lines, "\n"))
	if s, _ := loadAgentState(slot); s != nil && s.Token != "" {
		if err := agentLogoutCmd([]string{"-s", slot}); err != nil {
			fmt.Fprintln(os.Stderr, "结束会话失败：", err)
		}
	}
	if dir, err := agentDir(slot); err == nil {
		os.Remove(filepath.Join(dir, "agent_key"))
	}
	return nil
}

// agentSetupStatus：status 命令里列出各 agent 的接入情况
func agentSetupStatus() {
	var rows []string
	for _, t := range agentTargets {
		if !t.detect() {
			continue
		}
		ok, where := t.configured()
		mark := "未接入"
		if ok {
			mark = "已接入"
		}
		rows = append(rows, fmt.Sprintf("  %s：%s（%s）", t.name, mark, where))
	}
	if len(rows) == 0 {
		fmt.Println("本机 agent：没有找到已安装的 agent")
		return
	}
	fmt.Println("本机 agent：")
	fmt.Println(strings.Join(rows, "\n"))
}

func findTarget(id string) *agentTarget {
	for i := range agentTargets {
		if agentTargets[i].id == id {
			return &agentTargets[i]
		}
	}
	return nil
}

func targetIDs() string {
	var s []string
	for _, t := range agentTargets {
		s = append(s, t.id)
	}
	return strings.Join(s, ",")
}

func targetNames(ts []agentTarget) string {
	var s []string
	for _, t := range ts {
		s = append(s, t.name)
	}
	return strings.Join(s, "、")
}

// pickTargets：回车 = 全部；n = 都不要；否则按序号
func pickTargets(found []agentTarget, ans string) []agentTarget {
	ans = strings.TrimSpace(strings.ToLower(ans))
	if ans == "" || ans == "y" || ans == "all" {
		return found
	}
	if ans == "n" || ans == "no" {
		return nil
	}
	var out []agentTarget
	seen := map[int]bool{}
	for _, f := range strings.FieldsFunc(ans, func(r rune) bool { return r == ',' || r == ' ' || r == '，' }) {
		var i int
		if _, err := fmt.Sscan(f, &i); err == nil && i >= 1 && i <= len(found) && !seen[i] {
			seen[i] = true
			out = append(out, found[i-1])
		}
	}
	return out
}

func prompt(in *bufio.Reader, q string) string {
	fmt.Fprint(os.Stderr, q)
	s, _ := in.ReadString('\n')
	return strings.TrimSpace(s)
}

// saveAgentKey：连接码换来的 key 存在会话目录里，以后会话被结束了可以直接重新 login，不用再要连接码
func saveAgentKey(slot, srv, key string) error {
	dir, err := agentDir(slot)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	b, _ := json.Marshal(map[string]string{"server": srv, "key": key})
	return os.WriteFile(filepath.Join(dir, "agent_key"), b, 0o600)
}

// loadAgentKey：setup 保存的 key（login 在没有 -k / HUIJIAN_AGENT_KEY 时用）
func loadAgentKey(slot string) (srv, key string) {
	dir, err := agentDir(slot)
	if err != nil {
		return "", ""
	}
	b, err := os.ReadFile(filepath.Join(dir, "agent_key"))
	if err != nil {
		return "", ""
	}
	var m map[string]string
	if json.Unmarshal(b, &m) != nil {
		return "", ""
	}
	return m["server"], m["key"]
}

// ---------- 安装自己 ----------

// installSelf：把正在运行的程序复制到固定位置，返回那个位置（各 agent 的配置里写它）
func installSelf(cur string) (string, string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return cur, "", err
	}
	var dir string
	if runtime.GOOS == "windows" {
		base := os.Getenv("LOCALAPPDATA")
		if base == "" {
			base = filepath.Join(home, "AppData", "Local")
		}
		dir = filepath.Join(base, "Programs", "huijian")
	} else {
		// 已经在 PATH 里的目录（例如 ~/bin、/usr/local/bin、Homebrew）：不动
		if inPath(filepath.Dir(cur)) {
			return cur, "", nil
		}
		dir = filepath.Join(home, ".local", "bin")
	}
	name := "huijian"
	if runtime.GOOS == "windows" {
		name = "huijian.exe"
	}
	dst := filepath.Join(dir, name)
	if !samePath(cur, dst) {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return cur, "", err
		}
		if err := copyExecutable(cur, dst); err != nil {
			return cur, "", err
		}
	}
	note := ""
	if !inPath(dir) {
		if runtime.GOOS == "windows" {
			if err := addUserPathWindows(dir); err != nil {
				note = fmt.Sprintf("⚠️ 没能把 %s 加进 PATH（%v），可以手动加", dir, err)
			} else {
				note = "已把 huijian 装到 " + dst + " 并加进用户 PATH（新开的终端生效）"
			}
		} else {
			note = fmt.Sprintf("已把 huijian 装到 %s；这个目录不在 PATH 里，想在终端直接用 huijian 的话把它加进 PATH", dst)
		}
	} else if !samePath(cur, dst) {
		note = "已把 huijian 装到 " + dst
	}
	return dst, note, nil
}

func inPath(dir string) bool {
	for _, p := range filepath.SplitList(os.Getenv("PATH")) {
		if p != "" && samePath(p, dir) {
			return true
		}
	}
	return false
}

func samePath(a, b string) bool {
	a, b = filepath.Clean(a), filepath.Clean(b)
	if runtime.GOOS == "windows" || runtime.GOOS == "darwin" {
		return strings.EqualFold(a, b)
	}
	return a == b
}

// copyExecutable：先写临时文件再改名。Windows 上目标正在运行（例如 agent 正开着 huijian mcp）时不能覆盖，但能改名：旧的改成 .old
func copyExecutable(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".new"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, dst); err != nil {
		old := dst + ".old"
		os.Remove(old)
		if err2 := os.Rename(dst, old); err2 != nil {
			os.Remove(tmp)
			return err
		}
		if err := os.Rename(tmp, dst); err != nil {
			return err
		}
	}
	return nil
}

// addUserPathWindows：追加到用户级 PATH（HKCU\Environment），用 PowerShell 写，避免 setx 截断到 1024 字符
func addUserPathWindows(dir string) error {
	ps := `$d=$args[0]; $p=[Environment]::GetEnvironmentVariable('Path','User'); if(-not $p){$p=''}; ` +
		`if(($p -split ';') -notcontains $d){ [Environment]::SetEnvironmentVariable('Path', ($p.TrimEnd(';') + ';' + $d).TrimStart(';'), 'User') }`
	return exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", ps, dir).Run()
}

// ---------- 配置文件小工具 ----------

// backupOnce：第一次改某个配置文件前备份成 <文件>.bak-huijian（已有备份就不再覆盖，保留最原始的那份）
func backupOnce(path string) error {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	bak := path + ".bak-huijian"
	if _, err := os.Stat(bak); err == nil {
		return nil
	}
	return os.WriteFile(bak, b, 0o600)
}

// writeFileKeepMode：保持原文件权限（新文件 0600）
func writeFileKeepMode(path string, b []byte) error {
	mode := os.FileMode(0o600)
	if st, err := os.Stat(path); err == nil {
		mode = st.Mode().Perm()
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, b, mode)
}

// 文本块：YAML / TOML 里用「# >>> huijian agent setup」…「# <<< huijian agent setup」包起来，撤销时整块删掉
const (
	blockBegin = "# >>> " + setupMark + "（huijian agent setup -remove 会删掉这一段）"
	blockEnd   = "# <<< " + setupMark
)

// stripBlock：删掉文本里的标记块（含标记行），返回新文本和是否删过
func stripBlock(s string) (string, bool) {
	lines := strings.SplitAfter(s, "\n")
	var out []string
	in, found := false, false
	for _, l := range lines {
		t := strings.TrimSpace(l)
		switch {
		case strings.HasPrefix(t, "# >>> "+setupMark):
			in, found = true, true
		case in && strings.HasPrefix(t, "# <<< "+setupMark):
			in = false
		case !in:
			out = append(out, l)
		}
	}
	return strings.Join(out, ""), found
}

func hasBlock(s string) bool { return strings.Contains(s, "# >>> "+setupMark) }

// eol：沿用文件原来的换行符
func eol(s string) string {
	if strings.Contains(s, "\r\n") {
		return "\r\n"
	}
	return "\n"
}

// indentBlock：给一段多行文本每行加缩进，并换成文件的换行符
func indentBlock(body, indent, nl string) string {
	var b strings.Builder
	for _, l := range strings.Split(strings.TrimRight(body, "\n"), "\n") {
		if l == "" {
			b.WriteString(nl)
			continue
		}
		b.WriteString(indent + l + nl)
	}
	return b.String()
}

// ---------- 保持键顺序的 JSON ----------

// jsonObj：解析 / 写回时保持键的原有顺序（不打乱用户的配置文件）
type jsonObj struct {
	keys []string
	vals map[string]json.RawMessage
}

func parseJSONObj(b []byte) (*jsonObj, error) {
	o := &jsonObj{vals: map[string]json.RawMessage{}}
	if len(bytes.TrimSpace(b)) == 0 {
		return o, nil
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	t, err := dec.Token()
	if err != nil {
		return nil, err
	}
	if d, ok := t.(json.Delim); !ok || d != '{' {
		return nil, errors.New("不是 JSON 对象")
	}
	for dec.More() {
		t, err := dec.Token()
		if err != nil {
			return nil, err
		}
		k, _ := t.(string)
		var v json.RawMessage
		if err := dec.Decode(&v); err != nil {
			return nil, err
		}
		if _, dup := o.vals[k]; !dup {
			o.keys = append(o.keys, k)
		}
		o.vals[k] = v
	}
	if _, err := dec.Token(); err != nil {
		return nil, err
	}
	return o, nil
}

func (o *jsonObj) get(k string) (json.RawMessage, bool) { v, ok := o.vals[k]; return v, ok }

func (o *jsonObj) set(k string, v any) error {
	b, err := json.Marshal(v)
	if raw, ok := v.(json.RawMessage); ok {
		b, err = raw, nil
	}
	if err != nil {
		return err
	}
	if _, ok := o.vals[k]; !ok {
		o.keys = append(o.keys, k)
	}
	o.vals[k] = b
	return nil
}

func (o *jsonObj) del(k string) bool {
	if _, ok := o.vals[k]; !ok {
		return false
	}
	delete(o.vals, k)
	for i, x := range o.keys {
		if x == k {
			o.keys = append(o.keys[:i], o.keys[i+1:]...)
			break
		}
	}
	return true
}

func (o *jsonObj) MarshalJSON() ([]byte, error) {
	var b bytes.Buffer
	b.WriteByte('{')
	for i, k := range o.keys {
		if i > 0 {
			b.WriteByte(',')
		}
		kb, _ := json.Marshal(k)
		b.Write(kb)
		b.WriteByte(':')
		b.Write(o.vals[k])
	}
	b.WriteByte('}')
	return b.Bytes(), nil
}

// encodeIndent：两格缩进写回（中文不转义）
func encodeIndent(v any) ([]byte, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	var out bytes.Buffer
	if err := json.Indent(&out, raw, "", "  "); err != nil {
		return nil, err
	}
	out.WriteByte('\n')
	return out.Bytes(), nil
}

// jsonSetServer：在 JSON 配置文件的 <容器键>（如 mcpServers）里设置 huijian 一项；文件不存在就新建
func jsonSetServer(path, container string, entry any) error {
	b, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	root, err := parseJSONObj(b)
	if err != nil {
		return fmt.Errorf("%s 不是标准 JSON（可能有注释），请手动添加：%v", path, err)
	}
	servers := &jsonObj{vals: map[string]json.RawMessage{}}
	if raw, ok := root.get(container); ok {
		if servers, err = parseJSONObj(raw); err != nil {
			return fmt.Errorf("%s 里的 %s 格式不对：%v", path, container, err)
		}
	}
	if err := servers.set("huijian", entry); err != nil {
		return err
	}
	if err := root.set(container, servers); err != nil {
		return err
	}
	out, err := encodeIndent(root)
	if err != nil {
		return err
	}
	if err := backupOnce(path); err != nil {
		return err
	}
	return writeFileKeepMode(path, out)
}

// jsonRemoveServer：删掉 <容器键>.huijian；容器空了也删掉
func jsonRemoveServer(path, container string) (bool, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	root, err := parseJSONObj(b)
	if err != nil {
		return false, nil
	}
	raw, ok := root.get(container)
	if !ok {
		return false, nil
	}
	servers, err := parseJSONObj(raw)
	if err != nil || !servers.del("huijian") {
		return false, nil
	}
	if len(servers.keys) == 0 {
		root.del(container)
	} else if err := root.set(container, servers); err != nil {
		return false, err
	}
	out, err := encodeIndent(root)
	if err != nil {
		return false, err
	}
	return true, writeFileKeepMode(path, out)
}

func jsonHasServer(path, container string) bool {
	b, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	root, err := parseJSONObj(b)
	if err != nil {
		return false
	}
	raw, ok := root.get(container)
	if !ok {
		return false
	}
	servers, err := parseJSONObj(raw)
	if err != nil {
		return false
	}
	_, ok = servers.get("huijian")
	return ok
}

// ---------- skill ----------

// installSkill：把内置的 SKILL.md 写到 <dir>/huijian/SKILL.md（已有且不是我们装的就不覆盖）
func installSkill(dir string) error {
	p := filepath.Join(dir, "huijian", "SKILL.md")
	if b, err := os.ReadFile(p); err == nil && !bytes.Contains(b, []byte(setupMark)) {
		return nil // 用户自己装的（例如开发副本），不动
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	return os.WriteFile(p, []byte(agentSkillMD), 0o644)
}

func removeSkill(dir string) {
	p := filepath.Join(dir, "huijian", "SKILL.md")
	if b, err := os.ReadFile(p); err == nil && bytes.Contains(b, []byte(setupMark)) {
		os.Remove(p)
		os.Remove(filepath.Dir(p))
	}
}

// homeJoin：~ 下的路径
func homeJoin(parts ...string) string {
	h, _ := os.UserHomeDir()
	return filepath.Join(append([]string{h}, parts...)...)
}

// envDir：环境变量指定的目录优先（测试时把配置目录指到隔离位置），否则 ~ 下的默认目录
func envDir(envName string, def ...string) string {
	if v := strings.TrimSpace(os.Getenv(envName)); v != "" {
		return v
	}
	return homeJoin(def...)
}

func exists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// lookCmd：PATH 里有没有这个命令
func lookCmd(name string) string {
	p, err := exec.LookPath(name)
	if err != nil {
		return ""
	}
	return p
}

// sortedKeys 给测试用
func sortedKeys(m map[string]json.RawMessage) []string {
	var k []string
	for x := range m {
		k = append(k, x)
	}
	sort.Strings(k)
	return k
}
