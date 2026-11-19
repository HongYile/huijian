package main

import (
	"strings"
	"testing"
	"time"
)

func mdJSON(src string, atts ...Attachment) string {
	return string(marshalDoc(parseMD(src, atts)))
}

func TestMDRules(t *testing.T) {
	atts := []Attachment{{ID: "a_1", Name: "loss.png", Mime: "image/png"}, {ID: "a_2", Name: "My Report.pdf", Mime: "application/pdf"}}
	cases := []struct{ name, in, must, mustNot string }{
		{"中文加粗补救", "**注意：**内容", `{"text":"注意：","b":true}`, "**"},
		{"词中间的 __ 不当加粗", "调用 my__init__fn 方法", `"text":"调用 my__init__fn 方法"`, `"b":true`},
		{"单个换行就是换行", "第一行\n第二行", `第一行\n第二行`, ""},
		{"删除线", "~~旧~~", `"s":true`, ""},
		{"表格对齐", "| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |", `"align":["left","center","right"]`, ""},
		{"任务列表", "- [x] 完成\n- [ ] 待办", `"check":true`, `\u0000`},
		{"附件按名字", "![曲线](attachment:loss.png)", `{"type":"image","att":"a_1","alt":"曲线"`, ""},
		{"附件按序号、带空格的名字", "![](attachment:2) [报告](<attachment:My Report.pdf>)", `{"type":"file","att":"a_2"`, ""},
		{"附件链接", "[报告](attachment:My%20Report.pdf)", `{"text":"报告","att":"a_2"}`, ""},
		{"找不到附件", "![x](attachment:nope.png)", "找不到附件 nope.png", ""},
		{"进度：分数", "![训练](progress:15000/20000)", `"text":"15000/20000","value":0.75,"label":"训练"`, ""},
		{"进度：百分比", "![](progress:30%)", `"value":0.3`, ""},
		{"进度：超出范围截断", "![](progress:3/2)", `"value":1`, ""},
		{"提示框", "> [!WARNING] 磁盘 **95%**\n> 清理旧文件", `"kind":"warning","title":"磁盘 95%"`, "[!WARNING]"},
		{"折叠提示框", "> [!info]- 日志\n> 内容", `"kind":"note","title":"日志","fold":"closed"`, ""},
		{"未知类型是普通引用", "> [!FOO] x", `"type":"quote"`, "callout"},
		{"不安全链接只留文字", "[点](javascript:alert(1))", `{"text":"点"}`, "javascript:"},
		{"消息链接", "[上次](huijian://message/12)", `"href":"huijian://message/12"`, ""},
		{"中文标点后的网址", "见、https://a.com/x。", `{"text":"https://a.com/x","href":"https://a.com/x"}`, ""},
		{"HTML 原样显示", "<b>x</b><br>y", `<b>x</b>`, `"b":true`},
		{"外部图片", "![图](https://x.com/a.png)", `{"type":"image","src":"https://x.com/a.png","alt":"图"}`, ""},
		{"表格里的图片降级为文字", "| a |\n|---|\n| ![曲线](attachment:loss.png) |", `"text":"🖼 曲线","att":"a_1"`, `"type":"image"`},
		{"脚注", "正文[^1]\n\n[^1]: 说明", `"fn":1`, ""},
		{"有序列表起始号", "3. a\n4. b", `"ordered":true,"start":3`, ""},
		{"有序列表从 0 开始", "0. a\n1. b", `"ordered":true,"start":0`, ""},
		{"代码块语言", "```python\nprint(1)\n```", `{"type":"code","lang":"python","text":"print(1)"}`, ""},
		{"代码里的 ** 不加粗", "`x**2 + y**2`", `{"text":"x**2 + y**2","code":true}`, `"b":true`},
		{"补救只管紧挨标点的情况", "** 空格 ** 和 **注意：**看", `{"text":"** 空格 ** 和 "},{"text":"注意：","b":true}`, ""},
		{"「」紧贴加粗", "**「结果」**很好", `{"text":"「结果」","b":true}`, ""},
		{"反斜杠转义", `\*不是斜体\* 1\. a`, `{"text":"*不是斜体* 1. a"}`, `\\`},
		{"表格里的竖线转义", "| a |\n|---|\n| x \\| y |", `"text":"x | y"`, ""},
		{"HTML 实体", "&amp; &copy; &#x4E2D;", `{"text":"& © 中"}`, "&amp;"},
		{"其他 huijian:// 深链不放行", "[配对](huijian://pair?code=1)", `{"text":"配对"}`, "huijian://pair"},
		{"NaN 进度不生成", "![x](progress:" + strings.Repeat("9", 400) + "/" + strings.Repeat("9", 400) + ")", `"text":"x"`, "progress"},
		{"勾选框后接图片不留空段落", "- [ ] ![a](attachment:1)", `"check":false,"blocks":[{"type":"image"`, `{"type":"paragraph"}`},
		{"提示框标题里的格式", "> [!TIP] 用 **A** 方案\n> 内容", `"title":"用 A 方案"`, ""},
		{"NUL 伪造勾选框无效", "- \x00check:true 文字", "\uFFFDcheck:true", `"check"`},
	}
	for _, c := range cases {
		out := mdJSON(c.in, atts...)
		if !strings.Contains(out, c.must) {
			t.Errorf("%s：%q\n输出 %s\n缺少 %s", c.name, c.in, out, c.must)
		}
		if c.mustNot != "" && strings.Contains(out, c.mustNot) {
			t.Errorf("%s：%q\n输出 %s\n不应包含 %s", c.name, c.in, out, c.mustNot)
		}
	}
}

func TestMDLimits(t *testing.T) {
	deep := strings.Repeat("> ", 40) + "x"
	if d := parseMD(deep, nil); len(d.Blocks) != 1 || d.Blocks[0].Type != "paragraph" {
		t.Fatalf("深层嵌套应退化为纯文本段落：%s", mdJSON(deep))
	}
	// 审查发现的病态输入：每种都要在 300ms 内解析完（原来 1~26 秒）
	evil := map[string]string{
		"提示框标题递归": strings.Repeat("> [!NOTE] ", 6500),
		"深层强调":    strings.Repeat("*a ", 10000) + "x" + strings.Repeat(" a*", 10000),
		"深层下划线强调": strings.Repeat("_a ", 10000) + "x" + strings.Repeat(" a_", 10000),
		"深层引用":    strings.Repeat(">", 65000),
		"深层列表":    strings.Repeat("- ", 30000) + "x",
	}
	for name, src := range evil {
		t0 := time.Now()
		parseMD(src, nil)
		if d := time.Since(t0); d > 300*time.Millisecond {
			t.Errorf("%s：解析用了 %v", name, d)
		}
	}
	// 附件引用放大：doc 超过上限就退回纯文本
	att := []Attachment{{ID: "a_" + strings.Repeat("x", 60), Name: strings.Repeat("长", 60) + ".png", Mime: "image/png"}}
	src := strings.Repeat("![](attachment:1)", 3800)
	if e := buildDoc(&Message{Type: "markdown", Desp: src, Attachments: att}); len(e.raw) > docMaxBytes {
		t.Fatalf("doc 体积应受限，得到 %d 字节", len(e.raw))
	}
	big := strings.Repeat("- **a** `b` [c](https://d)\n", 6000)
	d := parseMD(big, nil)
	if len(d.Blocks) != 1 || d.Blocks[0].Type != "paragraph" {
		t.Fatalf("超大文档应退回纯文本，得到 %d 块", len(d.Blocks))
	}
	m := Message{ID: 7, Type: "markdown", Desp: "| a | b |\n|---|---|\n| 1 | 2 |"}
	doc, prev := messageDoc(&m)
	if pm := (&Message{ID: 9, Type: "markdown", Text: "exp43 报告", Desp: "# exp43 报告\n结论：好"}); true {
		if _, p := messageDoc(pm); p != "结论：好" {
			t.Fatalf("预览应跳过和标题相同的开头标题：%q", p)
		}
	}
	if !strings.Contains(string(doc), `"type":"table"`) || prev != "a · b\n1 · 2" {
		t.Fatalf("消息 doc / preview 不对：%s %q", doc, prev)
	}
	if doc, _ := messageDoc(&Message{ID: 8, Type: "text", Desp: "**x**"}); doc != nil {
		t.Fatal("type=text 不应解析")
	}
}
