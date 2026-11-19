package main

import (
	"html/template"
	"strconv"
	"strings"
)

// 管理网页展示消息正文：和客户端用同一套回笺 Markdown 解析（md.go），再输出 HTML。
// 所有文字都经过 HTML 转义，链接只放行 http / https / mailto（解析时已过滤），用户内容无法注入标签或属性。

func mdToHTML(src string) template.HTML { return docHTML(parseMD(src, nil)) }

// msgHTML 带附件解析（attachment: 引用），复用发给设备时的解析缓存；type=text 原样显示
func msgHTML(m Message) template.HTML {
	if m.Type == "text" {
		return template.HTML("<p>" + strings.ReplaceAll(esc(m.Desp), "\n", "<br>") + "</p>")
	}
	if e := cachedDoc(&m); e != nil {
		return docHTML(e.doc)
	}
	return ""
}

// msgPlain 一行摘要（复用缓存里的 preview）
func msgPlain(m Message) string {
	p := m.Desp
	if e := cachedDoc(&m); e != nil {
		p = e.preview
	}
	var out []string
	for _, ln := range strings.Split(p, "\n") {
		if t := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(ln), "· ")); t != "" {
			out = append(out, t)
		}
	}
	return strings.Join(out, " · ")
}

// mdPlain 去掉 Markdown 符号并压成一行，用于摘要。
func mdPlain(src string) string {
	var out []string
	for _, ln := range strings.Split(docPlain(parseMD(src, nil)), "\n") {
		if t := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(ln), "· ")); t != "" {
			out = append(out, t)
		}
	}
	return strings.Join(out, " · ")
}

var esc = template.HTMLEscapeString

func runsHTML(rs []MDRun) string {
	var b strings.Builder
	for _, r := range rs {
		t := strings.ReplaceAll(esc(r.Text), "\n", "<br>")
		if r.Fn != 0 {
			b.WriteString("<sup>[" + t + "]</sup>")
			continue
		}
		if r.Code {
			t = "<code>" + t + "</code>"
		}
		if r.B {
			t = "<b>" + t + "</b>"
		}
		if r.I {
			t = "<i>" + t + "</i>"
		}
		if r.S {
			t = "<s>" + t + "</s>"
		}
		switch {
		case r.Href != "" && !strings.HasPrefix(r.Href, "huijian://"):
			t = `<a href="` + esc(r.Href) + `" target="_blank" rel="noopener noreferrer">` + t + "</a>"
		case r.Att != "":
			t = `<span class="att">📎 ` + t + "</span>"
		}
		b.WriteString(t)
	}
	return b.String()
}

var calloutIcon = map[string]string{"note": "ℹ️", "tip": "💡", "important": "❗", "warning": "⚠️", "caution": "⛔", "success": "✅", "failure": "❌"}

func docHTML(d *MDDoc) template.HTML {
	var b strings.Builder
	var blocks func([]MDBlock)
	blocks = func(bs []MDBlock) {
		for _, x := range bs {
			switch x.Type {
			case "heading":
				b.WriteString(`<p class="h h` + strconv.Itoa(x.Level) + `">` + runsHTML(x.Runs) + "</p>")
			case "paragraph":
				b.WriteString("<p>" + runsHTML(x.Runs) + "</p>")
			case "list":
				tag := "ul"
				if x.Ordered {
					tag = "ol"
				}
				b.WriteString("<" + tag)
				if x.Ordered && x.Start != nil && *x.Start != 1 {
					b.WriteString(` start="` + strconv.Itoa(*x.Start) + `"`)
				}
				b.WriteString(">")
				for _, it := range x.Items {
					b.WriteString("<li>")
					if it.Check != nil {
						b.WriteString(map[bool]string{true: "☑ ", false: "☐ "}[*it.Check])
					}
					if x.Tight && len(it.Blocks) > 0 && it.Blocks[0].Type == "paragraph" {
						b.WriteString(runsHTML(it.Blocks[0].Runs))
						blocks(it.Blocks[1:])
					} else {
						blocks(it.Blocks)
					}
					b.WriteString("</li>")
				}
				b.WriteString("</" + tag + ">")
			case "quote":
				b.WriteString("<blockquote>")
				blocks(x.Blocks)
				b.WriteString("</blockquote>")
			case "callout":
				title := esc(strings.TrimSpace(calloutIcon[x.Kind] + " " + calloutTitle(x)))
				if x.Fold != "" {
					open := ""
					if x.Fold == "open" {
						open = " open"
					}
					b.WriteString(`<details class="callout ` + x.Kind + `"` + open + "><summary>" + title + "</summary>")
					blocks(x.Blocks)
					b.WriteString("</details>")
				} else {
					b.WriteString(`<div class="callout ` + x.Kind + `"><p class="ct">` + title + "</p>")
					blocks(x.Blocks)
					b.WriteString("</div>")
				}
			case "code":
				b.WriteString(`<pre class="code"><code>` + esc(x.Text) + "</code></pre>")
			case "rule":
				b.WriteString("<hr>")
			case "table":
				b.WriteString(`<div class="tbl"><table>`)
				cell := func(tag string, i int, rs []MDRun) {
					al := ""
					if i < len(x.Align) && x.Align[i] != "" {
						al = ` style="text-align:` + x.Align[i] + `"`
					}
					b.WriteString("<" + tag + al + ">" + runsHTML(rs) + "</" + tag + ">")
				}
				if len(x.Head) > 0 {
					b.WriteString("<thead><tr>")
					for i, c := range x.Head {
						cell("th", i, c)
					}
					b.WriteString("</tr></thead>")
				}
				b.WriteString("<tbody>")
				for _, r := range x.Rows {
					b.WriteString("<tr>")
					for i, c := range r {
						cell("td", i, c)
					}
					b.WriteString("</tr>")
				}
				b.WriteString("</tbody></table></div>")
			case "image":
				// 管理网页不加载图片（外部图片会暴露访问者，附件在客户端看）
				b.WriteString(`<p class="att">🖼 ` + esc(firstNonEmpty(x.Alt, x.Name, x.Src, "图片")) + "</p>")
			case "file":
				b.WriteString(`<p class="att">📎 ` + esc(firstNonEmpty(x.Alt, x.Name)) + "</p>")
			case "progress":
				pct := strconv.FormatFloat(*x.Value*100, 'f', 0, 64)
				b.WriteString(`<div class="prog"><span>` + esc(progressText(x)) + `</span><i style="width:` + pct + `%"></i></div>`)
			case "footnotes":
				b.WriteString(`<div class="fn">`)
				for _, it := range x.Items {
					b.WriteString("<p>[" + strconv.Itoa(it.N) + "] " + esc(docPlain(&MDDoc{Blocks: it.Blocks})) + "</p>")
				}
				b.WriteString("</div>")
			}
		}
	}
	blocks(d.Blocks)
	return template.HTML(b.String())
}
