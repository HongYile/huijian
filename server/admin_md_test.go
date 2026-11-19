package main

import (
	"strings"
	"testing"
)

func TestMarkdownSafeAndFormatted(t *testing.T) {
	cases := []struct{ in, must, mustNot string }{
		{"val_loss **0.231**", "<b>0.231</b>", "**"},
		{"<script>alert(1)</script>", "&lt;script&gt;", "<script>"},
		{"**<img src=x onerror=alert(1)>**", "<b>&lt;img", "<img"},
		{"[点我](javascript:alert(1))", "<p>点我</p>", "javascript"},
		{"[文档](https://a.com/x?y=1&z=2)", `href="https://a.com/x?y=1&amp;z=2"`, ""},
		{"```\n<b>x</b> **y**\n```", "<pre class=\"code\"><code>&lt;b&gt;x&lt;/b&gt; **y**</code></pre>", ""},
		{"- a\n- **b**\n\n1. c\n2. d", "<ul><li>a</li><li><b>b</b></li></ul><ol><li>c</li><li>d</li></ol>", ""},
		{"用 `rm -rf *` 小心", "<code>rm -rf *</code>", "<i>"},
		{"# 标题\n正文", `<p class="h h1">标题</p><p>正文</p>`, ""},
		{"a\"b' onmouseover=x", "&#34;", "\" onmouseover"},
	}
	for _, c := range cases {
		out := string(mdToHTML(c.in))
		if !strings.Contains(out, c.must) {
			t.Errorf("输入 %q\n输出 %q\n缺少 %q", c.in, out, c.must)
		}
		if c.mustNot != "" && strings.Contains(out, c.mustNot) {
			t.Errorf("输入 %q\n输出 %q\n不应包含 %q", c.in, out, c.mustNot)
		}
	}
	if p := mdPlain("best **0.231**\n\n```\ncode\n```\n- item"); p != "best 0.231 · code · item" {
		t.Errorf("摘要: %q", p)
	}
}

func TestIPSet(t *testing.T) {
	s := parseIPSet("10.0.0.1, 172.16.0.0/12 ,bad")
	for ip, want := range map[string]bool{"10.0.0.1": true, "10.0.0.2": false, "172.18.0.1": true, "172.32.0.1": false, "::ffff:10.0.0.1": true, "x": false} {
		if got := s.has(ip); got != want {
			t.Errorf("%s: got %v want %v", ip, got, want)
		}
	}
}
