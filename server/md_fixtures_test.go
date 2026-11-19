package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"strings"
	"testing"
)

var updateMDFixtures = flag.Bool("update-md-fixtures", false, "重新生成 testdata/md_fixtures.json")

// mdCorpus：跨实现对齐用的 Markdown 样例（客户端的共用核心库要逐条得到和服务端一样的 doc / preview）
var mdCorpus = []struct{ name, title, in string }{
	// 基本格式
	{"标题和段落", "", "# 一级\n## 二级\n###### 六级\n正文"},
	{"setext 标题", "", "标题\n===\n\n副标题\n---"},
	{"单换行即换行", "", "第一行\n第二行\n第三行"},
	{"硬换行", "", "行尾两个空格  \n反斜杠\\\n下一行"},
	{"加粗斜体删除线", "", "**粗** *斜* ***粗斜*** ~~删~~ _下划线斜_ __下划线粗__"},
	{"单波浪线", "", "~单~ 和 ~~双~~"},
	{"中文加粗补救", "", "**注意：**内容"},
	{"补救只管紧挨标点", "", "** 空格 ** 和 **注意：**看"},
	{"「」紧贴加粗", "", "**「结果」**很好"},
	{"x**2 不补救", "", "x**2 + y**2 = z**2"},
	{"中文删除线补救", "", "~~（作废）~~新内容"},
	{"词中下划线", "", "调用 my__init__fn 方法"},
	{"行内代码", "", "运行 `make test` 和 ``a`b``"},
	{"代码里的星号", "", "`x**2 + y**2`"},
	{"反斜杠转义", "", `\*不是斜体\* 1\. a \# b`},
	{"HTML 实体", "", "&amp; &copy; &#x4E2D; &lt;tag&gt;"},
	{"NUL", "", "a\x00b"},
	// 链接
	{"普通链接", "", "[官网](https://example.com) 和 [邮件](mailto:a@b.c)"},
	{"带标题的链接", "", `[x](https://a.com "标题")`},
	{"不安全链接", "", "[点](javascript:alert(1)) [文件](file:///etc/passwd)"},
	{"消息链接", "", "[上次](huijian://message/12)"},
	{"其他深链", "", "[配对](huijian://pair?code=1)"},
	{"尖括号自动链接", "", "<https://a.com/x?y=1> <a@b.com>"},
	{"裸网址", "", "访问 https://a.com/path?q=1. 结束"},
	{"www 网址", "", "见 www.example.com 吧"},
	{"裸邮箱", "", "联系 dev@example.com 谢谢"},
	{"中文标点后的网址", "", "见、https://a.com/x。"},
	{"网址末尾标点", "", "（https://a.com/x）, https://b.com/y!"},
	{"链接里的格式", "", "[**粗** 和 `码`](https://a.com)"},
	{"引用式链接", "", "[文档][d]\n\n[d]: https://a.com/doc"},
	{"消息链接新旧写法", "", "[上次](huijian://message/12) [更早](hongyan://message/3) [坏](hongyan://settings)"},
	// 附件、图片、进度
	{"附件图片按名字", "", "![曲线](attachment:loss.png)"},
	{"附件按序号", "", "![](attachment:2) [报告](<attachment:My Report.pdf>)"},
	{"附件链接转义", "", "[报告](attachment:My%20Report.pdf)"},
	{"附件大小写", "", "![](attachment:LOSS.PNG)"},
	{"找不到附件", "", "![x](attachment:nope.png)"},
	{"段落里的图片拆块", "", "前文\n![曲线](attachment:1)\n后文"},
	{"外部图片", "", "![图](https://x.com/a.png)"},
	{"不支持的图片", "", "![图](data:image/png;base64,xx) ![b](ftp://x/y.png)"},
	{"进度", "", "![训练进度](progress:15000/20000)\n![下载](progress:42%)\n![评估](progress:0.8)\n![x](progress:75)"},
	{"进度越界", "", "![](progress:3/2) ![](progress:-1) ![](progress:.5) ![](progress:1.)"},
	{"进度除零", "", "![a](progress:5/0)"},
	{"NaN 进度", "", "![x](progress:" + strings.Repeat("9", 400) + "/" + strings.Repeat("9", 400) + ")"},
	{"标题里的图片和进度", "", "# 进度 ![p](progress:50%) ![图](attachment:1)"},
	{"表格里的图片", "", "| a | b |\n|---|---|\n| ![曲线](attachment:loss.png) | ![p](progress:1/4) |"},
	{"链接里的图片", "", "[![图](attachment:1)](https://a.com)"},
	// 提示框
	{"提示框", "", "> [!WARNING] 磁盘 **95%**\n> 清理旧文件"},
	{"提示框无标题", "", "> [!NOTE]\n> 内容"},
	{"提示框只有标题", "", "> [!TIP] 只有标题"},
	{"折叠提示框", "", "> [!info]- 日志\n> 内容"},
	{"展开提示框", "", "> [!success]+ 完成\n> 版本 0.6.0"},
	{"提示框别名", "", "> [!danger] a\n\n> [!bug] b\n\n> [!hint] c\n\n> [!done] d\n\n> [!attention] e"},
	{"未知类型", "", "> [!FOO] x"},
	{"提示框多段", "", "> [!IMPORTANT] 标题\n> 第一段\n>\n> 第二段\n> - 列表\n> ```\n> code\n> ```"},
	{"提示框标题格式", "", "> [!TIP] 用 **A** 方案\n> 内容"},
	{"嵌套引用", "", "> 外层\n>> 内层\n>>> 第三层"},
	// 列表
	{"无序列表", "", "- a\n- b\n  - 子项\n  - 子项2\n- c"},
	{"有序列表", "", "3. a\n4. b"},
	{"从 0 开始", "", "0. a\n1. b"},
	{"括号有序列表", "", "1) a\n2) b"},
	{"松散列表", "", "- 第一项\n\n  第二段\n- 第二项"},
	{"任务列表", "", "- [x] 完成\n- [ ] 待办\n- 普通"},
	{"任务后接图片", "", "- [ ] ![a](attachment:1)"},
	{"任务列表嵌套", "", "- [x] 父\n  - [ ] 子"},
	{"NUL 伪造勾选框", "", "- \x00check:true 文字"},
	{"列表里的代码块", "", "- 步骤\n\n  ```bash\n  make\n  ```"},
	// 代码块、HTML、分隔线
	{"代码块语言", "", "```python\nprint(1)\n```"},
	{"代码块信息串", "", "```js title=\"a.js\"\nx\n```"},
	{"无语言代码块", "", "```\nplain\n\n两行\n```"},
	{"缩进代码块", "", "    indented\n    code"},
	{"波浪线代码块", "", "~~~\ntilde\n~~~"},
	{"未闭合代码块", "", "```\n没有结尾"},
	{"HTML 块", "", "<div>\n<b>x</b>\n</div>\n\n正文"},
	{"行内 HTML", "", "<b>x</b><br>y<br/>z<BR />w"},
	{"分隔线", "", "上\n\n---\n\n下\n\n***\n\n___"},
	// 表格
	{"表格对齐", "", "| a | b | c | d |\n|:--|:-:|--:|---|\n| 1 | 2 | 3 | 4 |"},
	{"表格里的格式", "", "| 模型 | val_loss |\n|:-----|---------:|\n| base | 0.231 |\n| **large** | **0.198** |"},
	{"表格竖线转义", "", "| a |\n|---|\n| x \\| y |"},
	{"表格缺单元格", "", "| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |"},
	{"表格空单元格", "", "| a | b |\n|---|---|\n|  | x |"},
	// 脚注
	{"脚注", "", "正文[^1]\n\n[^1]: 说明"},
	{"多个脚注", "", "a[^x] b[^y] 再引 a[^x]\n\n[^y]: 第二\n[^x]: 第一\n[^z]: 没用到"},
	{"脚注里多段", "", "见[^n]\n\n[^n]: 第一段\n\n    第二段"},
	// 预览
	{"预览跳过同名标题", "exp43 报告", "# exp43 报告\n结论：好"},
	{"预览不跳过不同标题", "别的标题", "# exp43 报告\n结论：好"},
	{"预览只有标题", "exp43", "# exp43"},
	{"预览超长", "", strings.Repeat("很长的一句话。", 50)},
	{"预览列表和提示框", "", "> [!WARNING]\n> 小心\n\n1. 一\n2. 二\n\n- [x] 完成\n- [ ] 待办\n\n| a | b |\n|---|---|\n| 1 | 2 |"},
	// 文档里的示例
	{"文档：表格", "", "| 模型 | val_loss | 用时 |\n|:-----|---------:|:----:|\n| base | 0.231 | 3h |\n| **large** | **0.198** | 6h |"},
	{"文档：训练结果", "训练结果", "## 训练结果\n![损失曲线](attachment:loss.png)\n验证集上 val_loss 降到 **0.198**。\n\n![](attachment:2)\n完整报告见 [report.pdf](attachment:report.pdf)。"},
	{"文档：提示框", "", "> [!WARNING] 磁盘快满了\n> /data 已用 95%，清理旧的 checkpoint。\n\n> [!SUCCESS] 部署完成\n> 版本 0.6.0 已上线。\n\n> [!INFO]- 完整日志（默认折叠）\n> ```\n> step 15000 loss 0.198\n> ```"},
	// 真实消息
	{"训练报告", "exp42 完成", "**exp42** 训练完成 ✅\n\n| 指标 | 值 |\n|---|---:|\n| val_loss | 0.198 |\n| acc | 93.1% |\n\n![训练进度](progress:20000/20000)\n\n> [!TIP] 下一步\n> 试试 lr=3e-4\n\n日志：`/data/runs/exp42/log.txt`，详情 https://wandb.ai/x/exp42"},
	{"告警", "磁盘告警", "⚠️ /data 使用率 **95%**\n\n```\nFilesystem  Size  Used\n/dev/sda1   2T    1.9T\n```\n\n- [ ] 清理 checkpoint\n- [ ] 扩容"},
	{"agent 汇报", "", "已完成：\n1. 拉取代码\n2. 跑测试（**全部通过**）\n3. 提交 PR：https://github.com/a/b/pull/1\n\n需要你确认是否合并？"},
	// 限制
	{"深层引用退化", "", strings.Repeat("> ", 40) + "x"},
	{"超深缩进", "", strings.Repeat(" ", 70) + "x"},
	{"深层列表退化", "", strings.Repeat("- ", 20) + "x"},
	{"超多节点退化", "", strings.Repeat("- **a** `b` [c](https://d)\n", 6000)},
}

var mdFixtureAtts = []Attachment{
	{ID: "a_1", Name: "loss.png", Mime: "image/png", Size: 1000},
	{ID: "a_2", Name: "My Report.pdf", Mime: "application/pdf", Size: 2000},
	{ID: "a_3", Name: "report.pdf", Mime: "application/pdf", Size: 3000},
}

// 用 go test -run TestMDFixtures -update-md-fixtures 重新生成；平时校验文件和当前实现一致（改了解析规则要同时更新共用核心库）
func TestMDFixtures(t *testing.T) {
	type fixture struct {
		Name    string          `json:"name"`
		Title   string          `json:"title"`
		In      string          `json:"in"`
		Doc     json.RawMessage `json:"doc"`
		Preview string          `json:"preview"`
	}
	out := struct {
		Note  string       `json:"note"`
		Atts  []Attachment `json:"atts"`
		Cases []fixture    `json:"cases"`
	}{Note: "回笺 Markdown 跨实现样例（server/md_fixtures_test.go 生成）：用 atts 作为附件解析 in，doc 和 preview 要和这里完全一致", Atts: mdFixtureAtts}
	for _, c := range mdCorpus {
		e := buildDoc(&Message{Type: "markdown", Text: c.title, Desp: c.in, Attachments: mdFixtureAtts})
		out.Cases = append(out.Cases, fixture{Name: c.name, Title: c.title, In: c.in, Doc: e.raw, Preview: e.preview})
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", " ")
	enc.Encode(out)
	const path = "testdata/md_fixtures.json"
	if *updateMDFixtures {
		if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("缺少 %s：用 -update-md-fixtures 生成", path)
	}
	if !bytes.Equal(want, buf.Bytes()) {
		t.Fatal("Markdown 样例和当前实现不一致：改了解析规则？用 -update-md-fixtures 重新生成，并同步更新共用核心库")
	}
}
