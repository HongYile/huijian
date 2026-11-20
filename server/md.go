package main

// 回笺 Markdown：服务端统一解析，客户端只负责按结构绘制。规则见 docs/markdown.md。
//
// 标准部分是 CommonMark + GFM（表格、删除线、任务列表、自动链接）+ 脚注；回笺扩展：
//   - ![说明](attachment:loss.png)   在正文这里显示本条消息的附件（按文件名或序号 attachment:1）
//   - [报告](attachment:report.pdf)  链接到附件，点开查看 / 下载
//   - ![训练进度](progress:0.75)     进度条，也可写 progress:15000/20000 或 progress:75%
//   - > [!WARNING] 标题              提示框：NOTE / TIP / IMPORTANT / WARNING / CAUTION / SUCCESS / FAILURE；
//     > [!INFO]- 完整日志            标题后接 - 默认折叠，+ 默认展开但可折叠
//   - [上一次结果](huijian://message/123)  打开回笺里的另一条消息
//   - 单个换行就是换行（和聊天软件一样，不需要行尾两个空格）
//   - `**注意：**内容` 这种中文标点紧贴加粗符号的写法也按加粗处理（标准 CommonMark 不认）
//
// 输出结构（JSON，消息里的 doc 字段）：{"v":1,"blocks":[块...]}
//   块：heading{level,runs} paragraph{runs} list{ordered,start,tight,items:[{check?,blocks}]}
//       quote{blocks} callout{kind,title,fold,blocks} code{lang,text} rule
//       table{align,head:[runs...],rows:[[runs...]...]} image{att|src,alt,name} file{att,name,size,mime,alt}
//       progress{value,label,text} footnotes{items:[{n,blocks}]}
//   行内 runs：[{text, b, i, s, code, href, att, fn}]，扁平的一段段文字，样式用布尔标记。
//   图片、进度条只出现在块级（服务端会把段落从图片处拆开），表格单元格、标题里的图片降级为文字。

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"

	"github.com/yuin/goldmark"
	gast "github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/extension"
	east "github.com/yuin/goldmark/extension/ast"
	"github.com/yuin/goldmark/text"
	"github.com/yuin/goldmark/util"
)

const mdVersion = 1

type MDRun struct {
	Text string `json:"text"`
	B    bool   `json:"b,omitempty"`
	I    bool   `json:"i,omitempty"`
	S    bool   `json:"s,omitempty"`
	Code bool   `json:"code,omitempty"`
	Href string `json:"href,omitempty"` // http / https / mailto / huijian://
	Att  string `json:"att,omitempty"`  // 附件 id
	Fn   int    `json:"fn,omitempty"`   // 脚注编号
}

type MDItem struct {
	Check  *bool     `json:"check,omitempty"`
	N      int       `json:"n,omitempty"` // 脚注编号
	Blocks []MDBlock `json:"blocks"`
}

type MDBlock struct {
	Type    string      `json:"type"`
	Level   int         `json:"level,omitempty"`
	Runs    []MDRun     `json:"runs,omitempty"`
	Ordered bool        `json:"ordered,omitempty"`
	Start   *int        `json:"start,omitempty"` // 有序列表总是带（可能是 0）
	Tight   bool        `json:"tight,omitempty"`
	Items   []MDItem    `json:"items,omitempty"`
	Blocks  []MDBlock   `json:"blocks,omitempty"`
	Kind    string      `json:"kind,omitempty"`
	Title   string      `json:"title,omitempty"`
	Fold    string      `json:"fold,omitempty"` // "" 不可折叠 / open / closed
	Lang    string      `json:"lang,omitempty"`
	Text    string      `json:"text,omitempty"`
	Align   []string    `json:"align,omitempty"` // "" / left / center / right
	Head    [][]MDRun   `json:"head,omitempty"`
	Rows    [][][]MDRun `json:"rows,omitempty"`
	Att     string      `json:"att,omitempty"`
	Src     string      `json:"src,omitempty"`
	Alt     string      `json:"alt,omitempty"`
	Name    string      `json:"name,omitempty"`
	Mime    string      `json:"mime,omitempty"`
	Size    int64       `json:"size,omitempty"`
	Value   *float64    `json:"value,omitempty"`
	Label   string      `json:"label,omitempty"`
}

type MDDoc struct {
	V      int       `json:"v"`
	Blocks []MDBlock `json:"blocks"`
}

var mdParser = goldmark.New(
	goldmark.WithExtensions(extension.Table, extension.Strikethrough, extension.Linkify, extension.TaskList, extension.Footnote),
)

const (
	mdMaxNodes       = 20000
	mdMaxDepth       = 12 // 块级嵌套（引用、列表）
	mdMaxInlineDepth = 24 // 行内嵌套（加粗套斜体……）
	mdMaxQuoteMarks  = 16 // 一行开头最多几层 > 或列表符号，再多直接按纯文本（goldmark 解析深层嵌套本身就很慢）
	mdMaxIndent      = 64 // 行首缩进上限（深层嵌套列表）
)

type mdConv struct {
	src   []byte
	atts  []Attachment
	nodes int
}

// parseMD 把正文解析成回笺 Markdown 结构；atts 是这条消息的附件（解析 attachment: 引用）
func parseMD(desp string, atts []Attachment) *MDDoc {
	desp = strings.ReplaceAll(desp, "\x00", "\uFFFD") // CommonMark：NUL 换成替换字符
	if tooNested(desp) {
		return plainDoc(desp)
	}
	c := &mdConv{src: []byte(desp), atts: atts}
	root := mdParser.Parser().Parse(text.NewReader(c.src))
	blocks := c.blocks(root, 0)
	if c.nodes > mdMaxNodes { // 太复杂：退回纯文本段落，避免服务端和客户端卡顿
		return plainDoc(desp)
	}
	return &MDDoc{V: mdVersion, Blocks: blocks}
}

func plainDoc(s string) *MDDoc {
	return &MDDoc{V: mdVersion, Blocks: []MDBlock{{Type: "paragraph", Runs: []MDRun{{Text: s}}}}}
}

// tooNested：解析前粗查一遍嵌套深度。行首的 >、列表符号（- * + 1.）和缩进太多就直接按纯文本，
// 挡住构造出来的病态输入（goldmark 解析几万层引用或列表本身就要好几秒）
func tooNested(s string) bool {
	for _, line := range strings.Split(s, "\n") {
		marks, indent := 0, 0
		for i := 0; i < len(line); i++ {
			ch := line[i]
			switch {
			case ch == '>':
				marks++
			case ch == ' ':
				indent++
			case ch == '\t':
				indent += 4
			case (ch == '-' || ch == '*' || ch == '+') && i+1 < len(line) && (line[i+1] == ' ' || line[i+1] == '\t'):
				marks++
			case ch >= '0' && ch <= '9':
				j := i
				for j < len(line) && j-i < 9 && line[j] >= '0' && line[j] <= '9' {
					j++
				}
				if j+1 < len(line) && (line[j] == '.' || line[j] == ')') && line[j+1] == ' ' {
					marks++
					i = j
					continue
				}
				i = len(line)
				continue
			default:
				i = len(line)
				continue
			}
		}
		if marks > mdMaxQuoteMarks || indent > mdMaxIndent {
			return true
		}
	}
	return false
}

func (c *mdConv) blocks(parent gast.Node, depth int) []MDBlock {
	var out []MDBlock
	for n := parent.FirstChild(); n != nil; n = n.NextSibling() {
		out = append(out, c.block(n, depth)...)
	}
	return out
}

func (c *mdConv) block(n gast.Node, depth int) []MDBlock {
	c.nodes++
	if c.nodes > mdMaxNodes {
		return nil // 超限：后面整篇按纯文本，不必继续转换
	}
	if depth > mdMaxDepth {
		return []MDBlock{{Type: "paragraph", Runs: []MDRun{{Text: plainOf(n, c.src)}}}}
	}
	switch v := n.(type) {
	case *gast.Heading:
		return []MDBlock{{Type: "heading", Level: v.Level, Runs: flatten(c.inl(v, false))}}
	case *gast.Paragraph, *gast.TextBlock:
		return c.splitParagraph(c.inl(n, true))
	case *gast.ThematicBreak:
		return []MDBlock{{Type: "rule"}}
	case *gast.FencedCodeBlock:
		return []MDBlock{{Type: "code", Lang: strings.TrimSpace(string(v.Language(c.src))), Text: linesOf(v, c.src)}}
	case *gast.CodeBlock:
		return []MDBlock{{Type: "code", Text: linesOf(v, c.src)}}
	case *gast.HTMLBlock:
		// 不渲染 HTML：原样显示成文字
		t := linesOf(v, c.src)
		if v.HasClosure() {
			t += string(v.ClosureLine.Value(c.src))
		}
		return []MDBlock{{Type: "paragraph", Runs: []MDRun{{Text: strings.TrimRight(t, "\n")}}}}
	case *gast.Blockquote:
		if b, ok := c.callout(v, depth); ok {
			return []MDBlock{b}
		}
		return []MDBlock{{Type: "quote", Blocks: c.blocks(v, depth+1)}}
	case *gast.List:
		b := MDBlock{Type: "list", Ordered: v.IsOrdered(), Tight: v.IsTight}
		if v.IsOrdered() {
			start := v.Start
			b.Start = &start
		}
		for it := v.FirstChild(); it != nil; it = it.NextSibling() {
			item := MDItem{Blocks: c.blocks(it, depth+1)}
			item.Check = takeCheck(&item.Blocks)
			b.Items = append(b.Items, item)
		}
		return []MDBlock{b}
	case *east.Table:
		b := MDBlock{Type: "table"}
		for _, a := range v.Alignments {
			b.Align = append(b.Align, map[east.Alignment]string{east.AlignLeft: "left", east.AlignCenter: "center", east.AlignRight: "right"}[a])
		}
		for row := v.FirstChild(); row != nil; row = row.NextSibling() {
			var cells [][]MDRun
			for cell := row.FirstChild(); cell != nil; cell = cell.NextSibling() {
				c.nodes++
				cells = append(cells, flatten(c.inl(cell, false)))
			}
			if _, head := row.(*east.TableHeader); head {
				b.Head = cells
			} else {
				b.Rows = append(b.Rows, cells)
			}
		}
		return []MDBlock{b}
	case *east.FootnoteList:
		b := MDBlock{Type: "footnotes"}
		for f := v.FirstChild(); f != nil; f = f.NextSibling() {
			if fn, ok := f.(*east.Footnote); ok {
				b.Items = append(b.Items, MDItem{N: fn.Index, Blocks: c.blocks(fn, depth+1)})
			}
		}
		return []MDBlock{b}
	}
	if n.HasChildren() {
		return c.blocks(n, depth+1)
	}
	return nil
}

// ---------- 提示框 ----------

var brTag = regexp.MustCompile(`(?i)^<br\s*/?>$`)

var calloutHead = regexp.MustCompile(`^\[!([A-Za-z]+)\]([+-]?)[ \t]*(.*)$`)

var calloutKinds = map[string]string{
	"note": "note", "info": "note", "tip": "tip", "hint": "tip", "important": "important",
	"warning": "warning", "warn": "warning", "attention": "warning", "caution": "caution", "danger": "caution",
	"error": "failure", "failure": "failure", "fail": "failure", "bug": "failure",
	"success": "success", "done": "success", "check": "success",
}

func (c *mdConv) callout(q *gast.Blockquote, depth int) (MDBlock, bool) {
	p, ok := q.FirstChild().(*gast.Paragraph)
	if !ok || p.Lines().Len() == 0 {
		return MDBlock{}, false
	}
	first := strings.TrimSpace(string(segVal(p.Lines().At(0), c.src)))
	m := calloutHead.FindStringSubmatch(first)
	if m == nil {
		return MDBlock{}, false
	}
	kind, ok := calloutKinds[strings.ToLower(m[1])]
	if !ok {
		return MDBlock{}, false
	}
	// 第一段的首行是标记行：标题取首行已经解析好的文字（去掉 [!类型]），剩下的照常解析
	first, rest := splitFirstLine(c.inl(p, true))
	title := strings.TrimSpace(calloutPrefix.ReplaceAllString(first, ""))
	b := MDBlock{Type: "callout", Kind: kind, Title: title, Fold: map[string]string{"-": "closed", "+": "open"}[m[2]]}
	if len(rest) > 0 {
		b.Blocks = append(b.Blocks, c.splitParagraph(rest)...)
	}
	for n := p.NextSibling(); n != nil; n = n.NextSibling() {
		b.Blocks = append(b.Blocks, c.block(n, depth+1)...)
	}
	return b, true
}

var calloutPrefix = regexp.MustCompile(`^\s*\[![A-Za-z]+\][+-]?`)

// splitFirstLine：首行的纯文字，和第一个换行之后的内容
func splitFirstLine(nodes []mdNode) (string, []mdNode) {
	var b strings.Builder
	for i, n := range nodes {
		if n.kind != "" {
			continue
		}
		if j := strings.IndexByte(n.run.Text, '\n'); j >= 0 {
			b.WriteString(n.run.Text[:j])
			rest := append([]mdNode{}, nodes[i:]...)
			rest[0].run.Text = n.run.Text[j+1:]
			return b.String(), rest
		}
		b.WriteString(n.run.Text)
	}
	return b.String(), nil
}

// ---------- 行内 ----------

type mdStyle struct {
	b, i, s bool
	href    string
	att     string
}

// mdNode：行内解析的中间结果。kind 为空是文字；image / file / progress 是要提升为块的元素
type mdNode struct {
	kind  string
	run   MDRun
	block MDBlock
}

// inl：解析一个节点的行内内容
func (c *mdConv) inl(parent gast.Node, allowBlocks bool) []mdNode {
	var out []mdNode
	c.inlines(parent, mdStyle{}, allowBlocks, 0, &out)
	return out
}

// unescapeText：反斜杠转义（\*、\|）和 HTML 实体（&amp;、&#x4E2D;），和 goldmark 自带的 HTML 渲染一致
func unescapeText(b []byte) string {
	return string(util.UnescapePunctuations(util.ResolveNumericReferences(util.ResolveEntityNames(b))))
}

// inlines 把行内节点追加到 out（共享切片，避免逐层复制）；行内嵌套过深时按纯文字处理
func (c *mdConv) inlines(parent gast.Node, st mdStyle, allowBlocks bool, depth int, out *[]mdNode) {
	add := func(t string, s mdStyle, code bool) {
		if t == "" {
			return
		}
		*out = append(*out, mdNode{run: MDRun{Text: t, B: s.b, I: s.i, S: s.s, Code: code, Href: s.href, Att: s.att}})
	}
	for n := parent.FirstChild(); n != nil; n = n.NextSibling() {
		c.nodes++
		if c.nodes > mdMaxNodes {
			return
		}
		if depth > mdMaxInlineDepth && n.HasChildren() {
			add(plainOf(n, c.src), st, false)
			continue
		}
		switch v := n.(type) {
		case *gast.Text:
			if v.IsRaw() {
				add(string(v.Value(c.src)), st, false)
			} else {
				add(unescapeText(v.Value(c.src)), st, false)
			}
			if v.SoftLineBreak() || v.HardLineBreak() {
				add("\n", st, false)
			}
		case *gast.String:
			add(string(v.Value), st, false)
		case *gast.CodeSpan:
			add(plainOf(v, c.src), st, true)
		case *gast.Emphasis:
			s := st
			if v.Level >= 2 {
				s.b = true
			} else {
				s.i = true
			}
			c.inlines(v, s, allowBlocks, depth+1, out)
		case *east.Strikethrough:
			s := st
			s.s = true
			c.inlines(v, s, allowBlocks, depth+1, out)
		case *gast.Link:
			s := st
			s.href, s.att = c.linkTarget(unescapeText(v.Destination))
			if s.href == "" && s.att == "" { // 不允许的链接、找不到的附件：只留文字
				s.href, s.att = st.href, st.att
			}
			c.inlines(v, s, allowBlocks, depth+1, out)
		case *gast.AutoLink:
			s := st
			u := string(v.URL(c.src))
			if v.AutoLinkType == gast.AutoLinkEmail && !strings.HasPrefix(u, "mailto:") {
				u = "mailto:" + u
			}
			s.href, _ = c.linkTarget(u)
			add(string(v.Label(c.src)), s, false)
		case *gast.Image:
			alt := plainOf(v, c.src)
			b, ok := c.imageBlock(unescapeText(v.Destination), alt)
			switch {
			case ok && allowBlocks:
				*out = append(*out, mdNode{kind: b.Type, block: b})
			case ok && b.Type == "progress":
				add(progressText(b), st, false)
			case ok:
				s := st
				if b.Att != "" {
					s.att = b.Att
				}
				add("🖼 "+firstNonEmpty(alt, b.Name, "图片"), s, false)
			default:
				add(alt, st, false)
			}
		case *gast.RawHTML:
			var sb strings.Builder
			for i := 0; i < v.Segments.Len(); i++ {
				sb.Write(segVal(v.Segments.At(i), c.src))
			}
			h := sb.String()
			if brTag.MatchString(h) {
				add("\n", st, false)
			} else {
				add(h, st, false)
			}
		case *east.TaskCheckBox:
			*out = append(*out, mdNode{kind: "check", run: MDRun{Text: strconv.FormatBool(v.IsChecked)}})
		case *east.FootnoteLink:
			*out = append(*out, mdNode{run: MDRun{Text: strconv.Itoa(v.Index), Fn: v.Index}})
		case *east.FootnoteBacklink:
			// 不需要回跳链接
		default:
			c.inlines(n, st, allowBlocks, depth+1, out)
		}
	}
}

// linkTarget：只放行 http / https / mailto / huijian://；attachment: 解析成附件 id
func (c *mdConv) linkTarget(dest string) (href, att string) {
	dest = strings.TrimSpace(dest)
	lower := strings.ToLower(dest)
	switch {
	case strings.HasPrefix(lower, "attachment:"):
		if a := c.findAtt(dest[len("attachment:"):]); a != nil {
			return "", a.ID
		}
		return "", ""
	case strings.HasPrefix(lower, "http://"), strings.HasPrefix(lower, "https://"), strings.HasPrefix(lower, "mailto:"):
		return dest, ""
	case msgLink.MatchString(dest): // 只放行「打开另一条消息」，以后客户端新增的深链不会被消息利用
		return dest, ""
	case legacyMsgLink.MatchString(dest): // 改名前的写法，统一成新 scheme
		return "huijian" + dest[len("hongyan"):], ""
	}
	return "", ""
}

var msgLink = regexp.MustCompile(`^huijian://message/[0-9]{1,18}$`)
var legacyMsgLink = regexp.MustCompile(`^hongyan://message/[0-9]{1,18}$`)

func (c *mdConv) findAtt(ref string) *Attachment {
	if u, err := url.PathUnescape(ref); err == nil {
		ref = u
	}
	ref = strings.TrimSpace(ref)
	for i := range c.atts {
		if c.atts[i].Name == ref {
			return &c.atts[i]
		}
	}
	for i := range c.atts {
		if strings.EqualFold(c.atts[i].Name, ref) {
			return &c.atts[i]
		}
	}
	if n, err := strconv.Atoi(ref); err == nil && n >= 1 && n <= len(c.atts) {
		return &c.atts[n-1]
	}
	return nil
}

var progressRe = regexp.MustCompile(`^\s*([0-9]*\.?[0-9]+)\s*(%|/\s*([0-9]*\.?[0-9]+))?\s*$`)

func (c *mdConv) imageBlock(dest, alt string) (MDBlock, bool) {
	dest = strings.TrimSpace(dest)
	lower := strings.ToLower(dest)
	switch {
	case strings.HasPrefix(lower, "attachment:"):
		a := c.findAtt(dest[len("attachment:"):])
		if a == nil {
			return MDBlock{Type: "paragraph", Runs: []MDRun{{Text: "（找不到附件 " + dest[len("attachment:"):] + "）", I: true}}}, true
		}
		if strings.HasPrefix(a.Mime, "image/") {
			return MDBlock{Type: "image", Att: a.ID, Alt: alt, Name: a.Name, Mime: a.Mime, Size: a.Size}, true
		}
		return MDBlock{Type: "file", Att: a.ID, Alt: alt, Name: a.Name, Mime: a.Mime, Size: a.Size}, true
	case strings.HasPrefix(lower, "progress:"):
		m := progressRe.FindStringSubmatch(dest[len("progress:"):])
		if m == nil {
			return MDBlock{}, false
		}
		x, _ := strconv.ParseFloat(m[1], 64)
		var v float64
		txt := ""
		switch {
		case m[2] == "%":
			v = x / 100
		case m[3] != "":
			total, _ := strconv.ParseFloat(m[3], 64)
			if total > 0 {
				v = x / total
			}
			txt = m[1] + "/" + m[3]
		case x > 1: // 写成 75 当作百分比
			v = x / 100
		default:
			v = x
		}
		if math.IsNaN(v) || math.IsInf(v, 0) {
			return MDBlock{}, false
		}
		v = max(0, min(1, v))
		return MDBlock{Type: "progress", Value: &v, Label: alt, Text: txt}, true
	case strings.HasPrefix(lower, "http://"), strings.HasPrefix(lower, "https://"):
		return MDBlock{Type: "image", Src: dest, Alt: alt}, true
	}
	return MDBlock{}, false
}

func progressText(b MDBlock) string {
	s := fmt.Sprintf("%.0f%%", *b.Value*100)
	if b.Text != "" {
		s += "（" + b.Text + "）"
	}
	if b.Label != "" {
		s = b.Label + " " + s
	}
	return s
}

// splitParagraph：段落里的图片 / 附件 / 进度条提升为独立的块，其余文字组成段落
func (c *mdConv) splitParagraph(nodes []mdNode) []MDBlock {
	var out []MDBlock
	var cur []mdNode
	flush := func() {
		runs := flatten(cur)
		cur = nil
		// 去掉首尾的换行和空白（图片前后的换行）
		for len(runs) > 0 && strings.TrimSpace(runs[0].Text) == "" && runs[0].Fn == 0 {
			runs = runs[1:]
		}
		for len(runs) > 0 && strings.TrimSpace(runs[len(runs)-1].Text) == "" {
			runs = runs[:len(runs)-1]
		}
		if len(runs) > 0 {
			runs[0].Text = strings.TrimLeft(runs[0].Text, "\n")
			runs[len(runs)-1].Text = strings.TrimRight(runs[len(runs)-1].Text, "\n")
			out = append(out, MDBlock{Type: "paragraph", Runs: runs})
		}
	}
	for _, n := range nodes {
		switch n.kind {
		case "image", "file", "progress", "paragraph":
			flush()
			out = append(out, n.block)
		default:
			cur = append(cur, n)
		}
	}
	flush()
	return out
}

// takeCheck：任务列表项的勾选框在第一段开头，取出来放到 item 上
func takeCheck(blocks *[]MDBlock) *bool {
	if len(*blocks) == 0 {
		return nil
	}
	b := &(*blocks)[0]
	if b.Type != "paragraph" || len(b.Runs) == 0 || !strings.HasPrefix(b.Runs[0].Text, "\x00check:") {
		return nil
	}
	v := b.Runs[0].Text == "\x00check:true"
	b.Runs = b.Runs[1:]
	if len(b.Runs) > 0 {
		b.Runs[0].Text = strings.TrimLeft(b.Runs[0].Text, " ")
	}
	if len(b.Runs) == 0 || (len(b.Runs) == 1 && strings.TrimSpace(b.Runs[0].Text) == "") {
		*blocks = (*blocks)[1:] // 勾选框后面是图片等块：去掉空段落
	}
	return &v
}

var cjkBold = regexp.MustCompile(`\*\*([^*\n]+?)\*\*|~~([^~\n]+?)~~`)

// flatten：合并相邻同样式的文字，并补上 CommonMark 不认的中文加粗（**注意：**内容）
func flatten(nodes []mdNode) []MDRun {
	var out []MDRun
	push := func(r MDRun) {
		if r.Text == "" {
			return
		}
		if k := len(out) - 1; k >= 0 && r.Fn == 0 && out[k].Fn == 0 && sameStyle(out[k], r) &&
			!strings.HasPrefix(out[k].Text, "\x00") && !strings.HasPrefix(r.Text, "\x00") {
			out[k].Text += r.Text
			return
		}
		out = append(out, r)
	}
	for _, n := range nodes {
		if n.kind == "check" {
			push(MDRun{Text: "\x00check:" + n.run.Text})
			continue
		}
		if n.kind != "" {
			continue
		}
		push(n.run)
	}
	// 中文加粗补救：只处理同一段普通文字里成对的 ** / ~~，并且内侧紧挨标点（**注意：**、**「结果」**）——
	// 这正是 CommonMark 左右侧规则不认的情况；__ 不处理，免得误伤 __init__ 这类名字
	var fixed []MDRun
	for _, r := range out {
		if r.Code || r.Fn != 0 || !strings.ContainsAny(r.Text, "*~") {
			fixed = append(fixed, r)
			continue
		}
		last := 0
		for _, m := range cjkBold.FindAllStringSubmatchIndex(r.Text, -1) {
			var inner string
			if m[2] >= 0 {
				inner = r.Text[m[2]:m[3]]
			} else {
				inner = r.Text[m[4]:m[5]]
			}
			if !edgePunct(inner) {
				continue // 两侧都是字母数字（x**2 + y**2）：CommonMark 不认是有意的，保持原样
			}
			if m[0] > last {
				x := r
				x.Text = r.Text[last:m[0]]
				fixed = append(fixed, x)
			}
			x := r
			switch {
			case m[2] >= 0:
				x.Text, x.B = r.Text[m[2]:m[3]], true
			default:
				x.Text, x.S = r.Text[m[4]:m[5]], true
			}
			fixed = append(fixed, x)
			last = m[1]
		}
		if last < len(r.Text) {
			x := r
			x.Text = r.Text[last:]
			fixed = append(fixed, x)
		}
	}
	return linkifyRuns(fixed)
}

// 网址紧贴中文标点时 goldmark 不识别（要求前面是空格），这里补上；只认 ASCII 字符，结尾的标点不算
var bareURL = regexp.MustCompile(`https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'*+,;=%]+`)

func linkifyRuns(in []MDRun) []MDRun {
	var out []MDRun
	for _, r := range in {
		if r.Code || r.Href != "" || r.Att != "" || r.Fn != 0 || !strings.Contains(r.Text, "://") {
			out = append(out, r)
			continue
		}
		last := 0
		for _, m := range bareURL.FindAllStringIndex(r.Text, -1) {
			end := m[1]
			for end > m[0] && strings.ContainsRune(".,;:!?'", rune(r.Text[end-1])) {
				end--
			}
			if m[0] > last {
				x := r
				x.Text = r.Text[last:m[0]]
				out = append(out, x)
			}
			x := r
			x.Text, x.Href = r.Text[m[0]:end], r.Text[m[0]:end]
			out = append(out, x)
			last = end
		}
		if last < len(r.Text) {
			x := r
			x.Text = r.Text[last:]
			out = append(out, x)
		}
	}
	return out
}

// edgePunct：首字或尾字是标点 / 符号
func edgePunct(s string) bool {
	f, _ := utf8.DecodeRuneInString(s)
	l, _ := utf8.DecodeLastRuneInString(s)
	isP := func(r rune) bool { return unicode.IsPunct(r) || unicode.IsSymbol(r) }
	return isP(f) || isP(l)
}

func sameStyle(a, b MDRun) bool {
	return a.B == b.B && a.I == b.I && a.S == b.S && a.Code == b.Code && a.Href == b.Href && a.Att == b.Att
}

func linesOf(n gast.Node, src []byte) string {
	var b bytes.Buffer
	for i := 0; i < n.Lines().Len(); i++ {
		b.Write(segVal(n.Lines().At(i), src))
	}
	return strings.TrimRight(b.String(), "\n")
}

func plainOf(n gast.Node, src []byte) string {
	var b strings.Builder
	_ = gast.Walk(n, func(c gast.Node, entering bool) (gast.WalkStatus, error) {
		if !entering {
			return gast.WalkContinue, nil
		}
		switch v := c.(type) {
		case *gast.Text:
			b.Write(v.Value(src))
			if v.SoftLineBreak() || v.HardLineBreak() {
				b.WriteByte('\n')
			}
		case *gast.String:
			b.Write(v.Value)
		}
		return gast.WalkContinue, nil
	})
	if b.Len() == 0 && n.Type() == gast.TypeBlock && n.Lines() != nil {
		return linesOf(n, src)
	}
	return b.String()
}

func segVal(seg text.Segment, src []byte) []byte { return seg.Value(src) }

func firstNonEmpty(s ...string) string {
	for _, x := range s {
		if x != "" {
			return x
		}
	}
	return ""
}

// ---------- 纯文本（通知正文、列表预览、Bark） ----------

// docPlain 把结构转成适合通知的纯文本
func docPlain(d *MDDoc) string {
	var b strings.Builder
	var blocks func(bs []MDBlock, indent string)
	runs := func(rs []MDRun) string {
		var s strings.Builder
		for _, r := range rs {
			if r.Fn != 0 {
				s.WriteString("[" + r.Text + "]")
				continue
			}
			s.WriteString(r.Text)
		}
		return s.String()
	}
	line := func(s string) {
		if b.Len() > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(s)
	}
	blocks = func(bs []MDBlock, indent string) {
		for _, x := range bs {
			switch x.Type {
			case "heading", "paragraph":
				line(indent + strings.ReplaceAll(runs(x.Runs), "\n", "\n"+indent))
			case "list":
				for i, it := range x.Items {
					mark := "· "
					if x.Ordered {
						start := 1
						if x.Start != nil {
							start = *x.Start
						}
						mark = strconv.Itoa(start+i) + ". "
					}
					if it.Check != nil {
						mark = map[bool]string{true: "☑ ", false: "☐ "}[*it.Check]
					}
					sub := docPlain(&MDDoc{Blocks: it.Blocks})
					line(indent + mark + strings.ReplaceAll(sub, "\n", "\n"+indent+"  "))
				}
			case "quote":
				blocks(x.Blocks, indent)
			case "callout":
				icon := map[string]string{"note": "ℹ️", "tip": "💡", "important": "❗", "warning": "⚠️", "caution": "⛔", "success": "✅", "failure": "❌"}[x.Kind]
				line(indent + strings.TrimSpace(icon+" "+calloutTitle(x)))
				blocks(x.Blocks, indent)
			case "code":
				line(indent + x.Text)
			case "table":
				row := func(cells [][]MDRun) {
					var cs []string
					for _, c := range cells {
						cs = append(cs, strings.ReplaceAll(runs(c), "\n", " "))
					}
					line(indent + strings.Join(cs, " · "))
				}
				if len(x.Head) > 0 {
					row(x.Head)
				}
				for _, r := range x.Rows {
					row(r)
				}
			case "image":
				line(indent + "🖼 " + firstNonEmpty(x.Alt, x.Name, "图片"))
			case "file":
				line(indent + "📎 " + firstNonEmpty(x.Alt, x.Name))
			case "progress":
				line(indent + progressText(x))
			case "footnotes":
				for _, it := range x.Items {
					line(indent + "[" + strconv.Itoa(it.N) + "] " + docPlain(&MDDoc{Blocks: it.Blocks}))
				}
			}
		}
	}
	blocks(d.Blocks, "")
	return strings.TrimSpace(b.String())
}

// calloutNames：提示框没写标题时显示的类型名（各端一致，见 docs/markdown.md）
var calloutNames = map[string]string{"note": "说明", "tip": "建议", "important": "重要", "warning": "警告", "caution": "危险", "success": "成功", "failure": "失败"}

func calloutTitle(b MDBlock) string {
	if b.Title != "" {
		return b.Title
	}
	return calloutNames[b.Kind]
}

// ---------- 消息上的 doc / preview ----------

// docCache：解析结果按消息缓存（消息内容不会改），避免长轮询每次重新解析。
// 按字节预算（docCacheBytes）控制内存，超出时整体清空；同一条消息同时被多处请求时只解析一次。
const (
	docCacheBytes = 32 << 20
	docMaxBytes   = 256 << 10 // 单条 doc 上限；超过（且超过正文 4 倍）就按纯文本，防止构造的正文把 JSON 放大
)

var docCache = struct {
	sync.Mutex
	m      map[int64]*docEntry
	bytes  int
	flight map[int64]*sync.WaitGroup
}{m: map[int64]*docEntry{}, flight: map[int64]*sync.WaitGroup{}}

type docEntry struct {
	doc     *MDDoc
	raw     json.RawMessage
	preview string
}

func buildDoc(m *Message) *docEntry {
	d := parseMD(m.Desp, m.Attachments)
	raw := marshalDoc(d)
	if len(raw) > docMaxBytes && len(raw) > 4*len(m.Desp) {
		d = plainDoc(m.Desp)
		raw = marshalDoc(d)
	}
	// 预览跳过和消息标题相同的开头标题（列表里标题已经显示过）
	pv := d
	if len(d.Blocks) > 1 && d.Blocks[0].Type == "heading" && strings.TrimSpace(docPlain(&MDDoc{Blocks: d.Blocks[:1]})) == strings.TrimSpace(m.Text) {
		pv = &MDDoc{Blocks: d.Blocks[1:]}
	}
	return &docEntry{doc: d, raw: raw, preview: clip(docPlain(pv), 200)}
}

// forgetDoc：消息内容变了（补加密）时丢掉缓存的解析结果，内存里不留明文
func forgetDoc(id int64) {
	docCache.Lock()
	delete(docCache.m, id)
	docCache.Unlock()
}

// cachedDoc 返回消息的解析结果；type 为 text / image 或正文为空时返回 nil
func cachedDoc(m *Message) *docEntry {
	if m.Type == "text" || m.Type == "image" || strings.TrimSpace(m.Desp) == "" {
		return nil
	}
	if m.ID == 0 {
		return buildDoc(m)
	}
	for {
		docCache.Lock()
		if e, ok := docCache.m[m.ID]; ok {
			docCache.Unlock()
			return e
		}
		if wg, ok := docCache.flight[m.ID]; ok { // 别处正在解析同一条：等它
			docCache.Unlock()
			wg.Wait()
			continue
		}
		wg := &sync.WaitGroup{}
		wg.Add(1)
		docCache.flight[m.ID] = wg
		docCache.Unlock()

		e := buildDoc(m)
		size := len(e.raw) + len(e.preview) + 2*len(m.Desp) // 结构体本身大约和正文同量级
		docCache.Lock()
		if docCache.bytes+size > docCacheBytes {
			docCache.m, docCache.bytes = map[int64]*docEntry{}, 0
		}
		docCache.m[m.ID] = e
		docCache.bytes += size
		delete(docCache.flight, m.ID)
		docCache.Unlock()
		wg.Done()
		return e
	}
}

func messageDoc(m *Message) (json.RawMessage, string) {
	if e := cachedDoc(m); e != nil {
		return e.raw, e.preview
	}
	return nil, ""
}

// marshalDoc：不转义 < > &（JSON 里原样保留，体积更小，客户端解析结果一样）
func marshalDoc(d *MDDoc) json.RawMessage {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	enc.Encode(d)
	return bytes.TrimRight(b.Bytes(), "\n")
}

// attachDocs 给发往设备的消息补上 doc 和 preview（0.6.0 起）
func attachDocs(msgs []Message) {
	for i := range msgs {
		msgs[i].Doc, msgs[i].Preview = messageDoc(&msgs[i])
	}
}
