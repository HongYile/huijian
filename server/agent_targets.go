package main

// huijian agent setup 支持的 agent（docs/agent-mcp.md §7.1）。每种 agent 的配置位置和格式见各自注释。
// 配置目录都先看该 agent 自己的环境变量（CLAUDE_CONFIG_DIR、CODEX_HOME、HERMES_HOME、PI_CODING_AGENT_DIR、QWEN_HOME、DSH_HOME），
// 这样测试时可以把配置指到隔离目录；没设时用用户目录下的默认位置。
// 超时：ask 默认最多等 30 分钟，各 agent 的工具调用超时都设到约 1900 秒（Cursor 命令行固定 60 秒，改不了，见 skill）。

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
)

const mcpTimeoutSec = 1900

func init() {
	agentTargets = []agentTarget{
		claudeTarget(), codexTarget(), cursorTarget(), dshTarget(), hermesTarget(), qwenTarget(), piTarget(),
	}
}

// 共用 skill 目录：Codex、Cursor、Pi、Qwen Code、DeepSeek Harness 都读 ~/.agents/skills
func sharedSkillDir() string { return homeJoin(".agents", "skills") }

// yamlQuote：YAML 单引号字符串（Windows 路径里的反斜杠不用转义）
func yamlQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

// tomlLiteral：TOML 字面量字符串（单引号，反斜杠原样）；路径里有单引号时退回基本字符串
func tomlLiteral(s string) string {
	if !strings.Contains(s, "'") {
		return "'" + s + "'"
	}
	return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(s) + `"`
}

// ---------- Claude Code ----------
// 用户级配置在 ~/.claude.json（或 $CLAUDE_CONFIG_DIR/.claude.json）顶层的 mcpServers。
// 有 claude 命令时用它自己的 `claude mcp add-json -s user` 写（Claude Code 运行中也会改这个文件，用它自己的写法更稳），没有时直接改 JSON。
// timeout（毫秒）同时抬高 stdio 服务器的空闲超时（默认 30 分钟，正好等于 ask 的最长等待）。

func claudeTarget() agentTarget {
	dir := func() string { return envDir("CLAUDE_CONFIG_DIR", ".claude") }
	cfg := func() string {
		if v := strings.TrimSpace(os.Getenv("CLAUDE_CONFIG_DIR")); v != "" {
			return filepath.Join(v, ".claude.json")
		}
		return homeJoin(".claude.json")
	}
	entry := func(bin string) map[string]any {
		return map[string]any{"type": "stdio", "command": bin, "args": []string{"mcp"}, "env": map[string]string{}, "timeout": mcpTimeoutSec * 1000}
	}
	return agentTarget{
		id: "claude", name: "Claude Code",
		detect: func() bool { return lookCmd("claude") != "" || exists(dir()) || exists(cfg()) },
		configure: func(bin string) (string, error) {
			if c := lookCmd("claude"); c != "" {
				exec.Command(c, "mcp", "remove", "-s", "user", "huijian").Run()
				js, _ := encodeIndent(entry(bin))
				out, err := exec.Command(c, "mcp", "add-json", "-s", "user", "huijian", strings.TrimSpace(string(js))).CombinedOutput()
				if err == nil {
					return "已用 claude mcp add-json 加入用户级配置，新开的会话生效", nil
				}
				fmt.Fprintf(os.Stderr, "（claude mcp add-json 失败：%s，改为直接写 %s）\n", strings.TrimSpace(string(out)), cfg())
			}
			if err := jsonSetServer(cfg(), "mcpServers", entry(bin)); err != nil {
				return "", err
			}
			return "已写入 " + cfg() + "，新开的会话生效", nil
		},
		remove: func() (bool, error) {
			had := jsonHasServer(cfg(), "mcpServers")
			if c := lookCmd("claude"); c != "" && had {
				if exec.Command(c, "mcp", "remove", "-s", "user", "huijian").Run() == nil {
					return true, nil
				}
			}
			return jsonRemoveServer(cfg(), "mcpServers")
		},
		configured: func() (bool, string) { return jsonHasServer(cfg(), "mcpServers"), cfg() },
		skillDir:   func() string { return filepath.Join(dir(), "skills") },
	}
}

// ---------- Codex CLI ----------
// $CODEX_HOME/config.toml（默认 ~/.codex）：[mcp_servers.huijian]，tool_timeout_sec 默认 60 秒，要调大。
// 没有 TOML 库：追加一段带标记的表，撤销时整段删掉。

func codexTarget() agentTarget {
	dir := func() string { return envDir("CODEX_HOME", ".codex") }
	cfg := func() string { return filepath.Join(dir(), "config.toml") }
	return agentTarget{
		id: "codex", name: "Codex",
		detect: func() bool { return lookCmd("codex") != "" || exists(dir()) },
		configure: func(bin string) (string, error) {
			p := cfg()
			b, err := os.ReadFile(p)
			if err != nil && !errors.Is(err, os.ErrNotExist) {
				return "", err
			}
			s, _ := stripBlock(string(b))
			if regexp.MustCompile(`(?m)^\s*\[mcp_servers\.(huijian|"huijian")\]`).MatchString(s) {
				return "", fmt.Errorf("%s 里已有你自己写的 [mcp_servers.huijian]，没有改动", p)
			}
			nl := eol(string(b))
			blk := strings.Join([]string{blockBegin, "[mcp_servers.huijian]", "command = " + tomlLiteral(bin), `args = ["mcp"]`,
				fmt.Sprintf("tool_timeout_sec = %d", mcpTimeoutSec), "startup_timeout_sec = 30", blockEnd}, nl) + nl
			if s != "" && !strings.HasSuffix(s, "\n") {
				s += nl
			}
			if err := backupOnce(p); err != nil {
				return "", err
			}
			if err := writeFileKeepMode(p, []byte(s+blk)); err != nil {
				return "", err
			}
			return "已写入 " + p + "，重启 Codex 生效", nil
		},
		remove:     func() (bool, error) { return removeTextBlock(cfg()) },
		configured: func() (bool, string) { return fileHasBlock(cfg()), cfg() },
		skillDir:   sharedSkillDir,
	}
}

// ---------- Cursor（编辑器 + cursor-agent 命令行） ----------
// 共用 ~/.cursor/mcp.json 的 mcpServers。没有超时字段：编辑器约 60 分钟，命令行固定约 60 秒（skill 里教它分段等）。

func cursorTarget() agentTarget {
	dir := func() string { return homeJoin(".cursor") }
	cfg := func() string { return filepath.Join(dir(), "mcp.json") }
	cli := func() string {
		if c := lookCmd("cursor-agent"); c != "" {
			return c
		}
		return ""
	}
	return agentTarget{
		id: "cursor", name: "Cursor",
		detect: func() bool { return exists(dir()) || cli() != "" },
		configure: func(bin string) (string, error) {
			if err := jsonSetServer(cfg(), "mcpServers", map[string]any{"type": "stdio", "command": bin, "args": []string{"mcp"}, "env": map[string]string{}}); err != nil {
				return "", err
			}
			note := "已写入 " + cfg() + "，重启 Cursor 生效"
			if c := cli(); c != "" {
				if exec.Command(c, "mcp", "enable", "huijian").Run() == nil {
					note += "（命令行已批准）"
				}
			}
			return note + "；Cursor 命令行的工具调用最多 60 秒，ask 会分段等", nil
		},
		remove:     func() (bool, error) { return jsonRemoveServer(cfg(), "mcpServers") },
		configured: func() (bool, string) { return jsonHasServer(cfg(), "mcpServers"), cfg() },
		skillDir:   sharedSkillDir,
	}
}

// ---------- DeepSeek Harness ----------
// $DSH_HOME/profiles/<profile>/cordis.patch.yml（默认 ~/.dsh）：patch 条目 id 必须是 mcp-manager（文档示例的 mcp 会被忽略，
// 已用 dsh --dump-config 验证），config.servers.huijian；工具调用默认 60 秒，toolCallTimeoutMs 调大。
// 注意 patch 层会整个替换 servers：文件里已有用户自己的 mcp-manager 条目时不动，请用户手动加。

func dshTarget() agentTarget {
	home := func() string { return envDir("DSH_HOME", ".dsh") }
	profiles := func() []string {
		var out []string
		ents, _ := os.ReadDir(filepath.Join(home(), "profiles"))
		for _, e := range ents {
			if p := filepath.Join(home(), "profiles", e.Name(), "cordis.patch.yml"); e.IsDir() && exists(p) {
				out = append(out, p)
			}
		}
		return out
	}
	return agentTarget{
		id: "harness", name: "DeepSeek Harness",
		detect: func() bool { return len(profiles()) > 0 },
		configure: func(bin string) (string, error) {
			var done []string
			for _, p := range profiles() {
				if err := dshWrite(p, bin); err != nil {
					return "", err
				}
				done = append(done, filepath.Base(filepath.Dir(p)))
			}
			return "已写入配置 " + strings.Join(done, "、") + "（" + filepath.Join(home(), "profiles") + "），完全退出 Harness 再打开生效", nil
		},
		remove: func() (bool, error) {
			any := false
			for _, p := range profiles() {
				ok, err := removeTextBlock(p)
				if err != nil {
					return any, err
				}
				if ok {
					any = true
					dshEnsureArray(p)
				}
			}
			return any, nil
		},
		configured: func() (bool, string) {
			ps := profiles()
			for _, p := range ps {
				if fileHasBlock(p) {
					return true, p
				}
			}
			return false, filepath.Join(home(), "profiles")
		},
		skillDir: sharedSkillDir,
	}
}

var reDshMCP = regexp.MustCompile(`(?m)^-\s+id:\s*['"]?mcp-manager['"]?\s*$`)

func dshWrite(p, bin string) error {
	b, err := os.ReadFile(p)
	if err != nil {
		return err
	}
	s, _ := stripBlock(string(b))
	if reDshMCP.MatchString(s) {
		return fmt.Errorf("%s 里已有你自己的 mcp-manager 配置（patch 会整个替换 servers），请手动在它的 servers 下加 huijian", p)
	}
	nl := eol(string(b))
	// 模板里空的 patch 列表写作一行 []：换成我们的条目
	s = regexp.MustCompile(`(?m)^\[\]\s*$\r?\n?`).ReplaceAllString(s, "")
	if s != "" && !strings.HasSuffix(s, "\n") {
		s += nl
	}
	blk := blockBegin + nl + indentBlock(fmt.Sprintf(`- id: mcp-manager
  config:
    servers:
      huijian:
        transport: stdio
        command: %s
        args: ['mcp']
        toolCallTimeoutMs: %d`, yamlQuote(bin), mcpTimeoutSec*1000), "", nl) + blockEnd + nl
	if err := backupOnce(p); err != nil {
		return err
	}
	return writeFileKeepMode(p, []byte(s+blk))
}

// dshEnsureArray：撤销后文件里没有任何 patch 条目时写回 []（和模板一样，空文件会被当成 null）
func dshEnsureArray(p string) {
	b, err := os.ReadFile(p)
	if err != nil {
		return
	}
	if regexp.MustCompile(`(?m)^\s*-\s`).Match(b) || regexp.MustCompile(`(?m)^\[\]\s*$`).Match(b) {
		return
	}
	s := string(b)
	if s != "" && !strings.HasSuffix(s, "\n") {
		s += eol(s)
	}
	writeFileKeepMode(p, []byte(s+"[]"+eol(s)))
}

// ---------- Hermes Agent ----------
// $HERMES_HOME/config.yaml（默认 macOS / Linux ~/.hermes，Windows %LOCALAPPDATA%\hermes）的 mcp_servers.huijian；
// timeout 单位秒（默认 300）。hermes mcp add 是交互式的，直接写 YAML。

func hermesHome() string {
	if v := strings.TrimSpace(os.Getenv("HERMES_HOME")); v != "" {
		return v
	}
	if runtime.GOOS == "windows" {
		if la := os.Getenv("LOCALAPPDATA"); la != "" {
			if p := filepath.Join(la, "hermes"); exists(p) || !exists(homeJoin(".hermes")) {
				return p
			}
		}
	}
	return homeJoin(".hermes")
}

var reHermesMCP = regexp.MustCompile(`(?m)^mcp_servers:[ \t]*(\{\s*\})?[ \t]*(#.*)?$`)

func hermesTarget() agentTarget {
	cfg := func() string { return filepath.Join(hermesHome(), "config.yaml") }
	return agentTarget{
		id: "hermes", name: "Hermes Agent",
		detect: func() bool { return lookCmd("hermes") != "" || exists(hermesHome()) },
		configure: func(bin string) (string, error) {
			p := cfg()
			b, err := os.ReadFile(p)
			if err != nil && !errors.Is(err, os.ErrNotExist) {
				return "", err
			}
			s, _ := stripBlock(string(b))
			nl := eol(string(b))
			body := fmt.Sprintf(`huijian:
  command: %s
  args: [mcp]
  timeout: %d
  connect_timeout: 60`, yamlQuote(bin), mcpTimeoutSec)
			if m := reHermesMCP.FindStringSubmatchIndex(s); m != nil && m[2] >= 0 {
				// mcp_servers: {}（空的行内写法）：整行换成我们的块（撤销后整行消失，等于没有 mcp_servers）
				rest := strings.TrimPrefix(strings.TrimPrefix(s[m[1]:], "\r"), "\n")
				s = s[:m[0]] + blockBegin + nl + "mcp_servers:" + nl + indentBlock(body, "  ", nl) + blockEnd + nl + rest
			} else if loc := reHermesMCP.FindStringIndex(s); loc != nil {
				// 已有 mcp_servers：在它下面插入（缩进两格）
				head := "mcp_servers:" + nl
				rest := s[loc[1]:]
				rest = strings.TrimPrefix(strings.TrimPrefix(rest, "\r"), "\n")
				if regexp.MustCompile(`(?m)^  huijian:`).MatchString(rest) {
					return "", fmt.Errorf("%s 的 mcp_servers 里已有你自己写的 huijian，没有改动", p)
				}
				s = s[:loc[0]] + head + "  " + blockBegin + nl + indentBlock(body, "  ", nl) + "  " + blockEnd + nl + rest
			} else {
				if s != "" && !strings.HasSuffix(s, "\n") {
					s += nl
				}
				s += blockBegin + nl + "mcp_servers:" + nl + indentBlock(body, "  ", nl) + blockEnd + nl
			}
			if err := backupOnce(p); err != nil {
				return "", err
			}
			if err := writeFileKeepMode(p, []byte(s)); err != nil {
				return "", err
			}
			return "已写入 " + p + "，重启 Hermes（或在会话里 /reload-mcp）生效", nil
		},
		remove:     func() (bool, error) { return removeTextBlock(cfg()) },
		configured: func() (bool, string) { return fileHasBlock(cfg()), cfg() },
		skillDir:   func() string { return filepath.Join(hermesHome(), "skills") },
	}
}

// ---------- Qwen Code ----------
// $QWEN_HOME/settings.json（默认 ~/.qwen）的 mcpServers.huijian；timeout 单位毫秒（默认 10 分钟）。

func qwenTarget() agentTarget {
	dir := func() string { return envDir("QWEN_HOME", ".qwen") }
	cfg := func() string { return filepath.Join(dir(), "settings.json") }
	return agentTarget{
		id: "qwen", name: "Qwen Code",
		detect: func() bool { return lookCmd("qwen") != "" || exists(dir()) },
		configure: func(bin string) (string, error) {
			if err := jsonSetServer(cfg(), "mcpServers", map[string]any{"command": bin, "args": []string{"mcp"}, "timeout": mcpTimeoutSec * 1000}); err != nil {
				return "", err
			}
			return "已写入 " + cfg() + "，重启 Qwen Code 生效", nil
		},
		remove:     func() (bool, error) { return jsonRemoveServer(cfg(), "mcpServers") },
		configured: func() (bool, string) { return jsonHasServer(cfg(), "mcpServers"), cfg() },
		skillDir:   sharedSkillDir,
	}
}

// ---------- Pi ----------
// <agent 目录>/mcp.json（默认 ~/.pi/agent，PI_CODING_AGENT_DIR 可改）的 mcpServers.huijian；timeout 单位秒（默认 60）。
// 旧版 pi 没有内置 MCP：skill 里有命令行用法，pi 也能用。

func piTarget() agentTarget {
	dir := func() string { return envDir("PI_CODING_AGENT_DIR", ".pi", "agent") }
	cfg := func() string { return filepath.Join(dir(), "mcp.json") }
	return agentTarget{
		id: "pi", name: "Pi",
		detect: func() bool { return lookCmd("pi") != "" || exists(dir()) },
		configure: func(bin string) (string, error) {
			if err := jsonSetServer(cfg(), "mcpServers", map[string]any{"command": bin, "args": []string{"mcp"}, "timeout": mcpTimeoutSec}); err != nil {
				return "", err
			}
			return "已写入 " + cfg() + "，重启 Pi 生效（旧版 Pi 没有内置 MCP 时，它会按 skill 用命令行）", nil
		},
		remove:     func() (bool, error) { return jsonRemoveServer(cfg(), "mcpServers") },
		configured: func() (bool, string) { return jsonHasServer(cfg(), "mcpServers"), cfg() },
		skillDir:   sharedSkillDir,
	}
}

// ---------- 文本块小工具 ----------

func removeTextBlock(p string) (bool, error) {
	b, err := os.ReadFile(p)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	s, ok := stripBlock(string(b))
	if !ok {
		return false, nil
	}
	return true, writeFileKeepMode(p, []byte(s))
}

func fileHasBlock(p string) bool {
	b, err := os.ReadFile(p)
	return err == nil && hasBlock(string(b))
}
