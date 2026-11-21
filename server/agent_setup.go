package main

// huijian agent setup：一步接入（docs/agent-mcp.md §7.1）。
//   1. 把自己装到固定位置（Windows：%LOCALAPPDATA%\Programs\huijian，加进用户 PATH；macOS / Linux：已在 PATH 里就不动，否则 ~/.local/bin）
//   2. 用连接码换一把这台电脑专用的 Agent key（存在 ~/.huijian/agent/<槽位>/agent_key，0600），然后照常登录（设备核对 6 位核对码后批准）
//   3. 找出这台电脑上装了哪些 agent，把 huijian mcp 写进它们的配置、装上 skill（写之前备份，写入的内容带标记，-remove 原样撤销）
// huijian agent status 列出接入情况；huijian agent setup -remove 撤销全部接入并结束会话。

import (
	"bufio"
	"bytes"
	_ "embed"
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
	noLogin := fs.Bool("no-login", false, "只配置本机的 agent，不登录（已经用 huijian agent login 登录过时用）")
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
	code := strings.TrimSpace(fs.Arg(0))
	if *noLogin {
		goto configure
	}
	// 已登录、也没给新的连接码：跳过登录。只有服务器明确拒绝（401 / 403：会话已结束、key 已吊销）才重新登录；
	// 断网、429（在线会话满了）之类先按已登录处理（这时也登录不了），照常配置 agent
	if old, _ := loadAgentState(*slot); code == "" && old != nil && old.Token != "" && (srv == "" || old.Server == srv) {
		_, err := agentReq("GET", old.Server, "/v1/agent/replies?wait=0", old.Token, nil, 20*time.Second)
		var he *agentHTTPError
		if err == nil || !(errors.As(err, &he) && (he.Status == 401 || he.Status == 403)) {
			if err != nil {
				fmt.Fprintf(os.Stderr, "⚠️ 没能确认会话状态（%v），先按已登录处理\n", err)
			}
			fmt.Fprintf(os.Stderr, "✅ 已经登录：「%s」（%s），跳过登录\n", old.Name, old.Server)
			srv = old.Server
			goto configure
		}
		fmt.Fprintln(os.Stderr, "之前的会话已经结束，重新登录")
	}
	if srv == "" {
		if s, _ := loadAgentKey(*slot); s != "" {
			srv = s
		} else if srv = strings.TrimRight(prompt(in, "回笺服务器地址（如 https://push.example.com）："), "/"); srv == "" {
			return errors.New("缺少服务器地址")
		}
	}
	{
		key := strings.TrimSpace(env("HUIJIAN_AGENT_KEY", ""))
		// 以前用连接码换过 key（同一服务器）、这次没给新连接码：直接用它登录，不再要连接码，也不会多占一把 key
		if code == "" && !strings.HasPrefix(key, "AK_") {
			if s, k := loadAgentKey(*slot); k != "" && s == srv {
				key = k
				fmt.Fprintln(os.Stderr, "用这台电脑以前保存的 Agent key 登录（想换新的：带上新连接码运行）")
			}
		}
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
	// 连接码换来的 key：在服务端吊销（不占额度），再删本机文件；吊销不了就提示用户去设置里吊销
	if srv, key := loadAgentKey(slot); key != "" {
		if _, err := agentReq("DELETE", srv, "/v1/agent/key", key, nil, 20*time.Second); err != nil {
			var he *agentHTTPError
			if !(errors.As(err, &he) && he.Status == 401) {
				fmt.Fprintf(os.Stderr, "⚠️ 没能吊销这台电脑的 Agent key（%v），可以在回笺「设置 → Pushkey」里手动吊销\n", err)
			}
		} else {
			fmt.Fprintln(os.Stderr, "✅ 已吊销这台电脑的 Agent key")
		}
		if dir, err := agentDir(slot); err == nil {
			os.Remove(filepath.Join(dir, "agent_key"))
		}
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
	os.Remove(dst + ".old") // 上次更新时改名留下的旧程序（还在运行时删不掉，下次再删）
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
// HUIJIAN_SETUP_PATH_VAR 只给测试用：改写另一个用户变量，不动真的 PATH
func addUserPathWindows(dir string) error {
	v := env("HUIJIAN_SETUP_PATH_VAR", "Path")
	// -Command 后面的参数不会进 $args：值用单引号字符串直接写进脚本（单引号加倍转义）。
	// 直接读写 HKCU\Environment 的原值（不展开 %USERPROFILE% 之类，按 REG_EXPAND_SZ 写回）；
	// 写注册表不会通知别的程序，最后用 SetEnvironmentVariable 设一个临时变量再删掉，借它广播 WM_SETTINGCHANGE
	q := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }
	ps := `$d=` + q(dir) + `; $v=` + q(v) + `; $k=Get-Item 'HKCU:\Environment'; ` +
		`$p=$k.GetValue($v,'','DoNotExpandEnvironmentNames'); if(-not $p){$p=''}; ` +
		`if(($p -split ';') -notcontains $d){ ` +
		`New-ItemProperty -Path 'HKCU:\Environment' -Name $v -Value (($p.TrimEnd(';') + ';' + $d).TrimStart(';')) -PropertyType ExpandString -Force | Out-Null; ` +
		`[Environment]::SetEnvironmentVariable('HUIJIAN_PATH_REFRESH','1','User'); [Environment]::SetEnvironmentVariable('HUIJIAN_PATH_REFRESH',$null,'User') }`
	out, err := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", ps).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v %s", err, strings.TrimSpace(string(out)))
	}
	return nil
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

// stripBlock：删掉文本里的标记块（含标记行），返回新文本和是否删过。只有开始标记、没有结束标记（被手动改坏了）时不动，
// 免得把开始标记之后的内容全删掉
func stripBlock(s string) (string, bool) {
	if strings.Count(s, "# >>> "+setupMark) != strings.Count(s, "# <<< "+setupMark) {
		return s, false
	}
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

// marshalJSON：和 json.Marshal 一样，但不把 & < > 转成 \u0026 之类（保持用户配置原样）
func marshalJSON(v any) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(b.Bytes(), "\n"), nil
}

func (o *jsonObj) set(k string, v any) error {
	b, err := marshalJSON(v)
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
	raw, err := marshalJSON(v)
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

// setupEnvMark：写进各 JSON 配置里 huijian 一项的 env，标明是 setup 写的（撤销时只删带标记的，用户自己配的 huijian 不动）
const setupEnvMark = "HUIJIAN_SETUP"

// isSetupEntry：这一项是不是 setup 写的
func isSetupEntry(raw json.RawMessage) bool {
	var e struct {
		Env map[string]any `json:"env"`
	}
	return json.Unmarshal(raw, &e) == nil && e.Env[setupEnvMark] != nil
}

// jsonSetServer：在 JSON 配置文件的 <容器键>（如 mcpServers）里设置 huijian 一项；文件不存在就新建。
// 已有用户自己写的 huijian（没有 setup 标记）时报错不动
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
	if old, ok := servers.get("huijian"); ok && !isSetupEntry(old) {
		return fmt.Errorf("%s 里已有你自己写的 huijian，没有改动", path)
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
	if bytes.Contains(b, []byte("\r\n")) {
		out = bytes.ReplaceAll(out, []byte("\n"), []byte("\r\n"))
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
	if err != nil {
		return false, nil
	}
	if old, ok := servers.get("huijian"); !ok || !isSetupEntry(old) {
		return false, nil // 没有，或者是用户自己写的：不动
	}
	servers.del("huijian")
	if len(servers.keys) == 0 {
		root.del(container)
	} else if err := root.set(container, servers); err != nil {
		return false, err
	}
	out, err := encodeIndent(root)
	if err != nil {
		return false, err
	}
	if bytes.Contains(b, []byte("\r\n")) {
		out = bytes.ReplaceAll(out, []byte("\n"), []byte("\r\n"))
	}
	if err := writeFileKeepMode(path, out); err != nil {
		return false, err
	}
	os.Remove(path + ".bak-huijian") // 撤销完，原样恢复了，备份没用了（里面可能有别的凭据，不留）
	return true, nil
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
