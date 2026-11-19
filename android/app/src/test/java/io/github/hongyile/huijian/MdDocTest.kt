package io.github.hongyile.huijian

import io.github.hongyile.huijian.MdDoc.Block
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** doc 解析（服务端 server/md.go 的输出，样例来自 claude_test/markdown/sample.json） */
class MdDocTest {
    private fun sample(): JSONObject =
        JSONObject(javaClass.classLoader!!.getResource("md-sample.json")!!.readText())

    private fun doc(vararg blocks: String) = MdDoc.parse("""{"v":1,"blocks":[${blocks.joinToString(",")}]}""")!!

    @Test fun sampleParsesAllBlocks() {
        val bs = MdDoc.parse(sample())!!
        assertEquals(
            listOf("Heading", "Paragraph", "Progress", "Table", "Image", "Paragraph", "Callout", "Callout", "Quote",
                "ListBlock", "ListBlock", "Rule", "Paragraph", "Code", "Footnotes"),
            bs.map { it::class.simpleName },
        )
        val h = bs[0] as Block.Heading
        assertEquals(1, h.level); assertEquals("实验 exp42 完成", MdDoc.plain(h.runs))

        val p = bs[1] as Block.Paragraph
        assertTrue(p.runs[0].b); assertEquals("注意：", p.runs[0].text)
        assertTrue(p.runs.any { it.s && it.text == "旧方案" })
        assertTrue(p.runs.any { it.i && it.text == "斜体" })
        assertTrue(p.runs.any { it.code && it.text == "code" })
        assertTrue(p.runs.any { it.href == "https://example.com" })
        assertTrue(p.runs.any { it.text.contains("\n") })

        val prog = bs[2] as Block.Progress
        assertEquals(0.75, prog.value, 1e-9)
        assertEquals("训练进度 75%（15000/20000）", prog.display)

        val t = bs[3] as Block.Table
        assertEquals(listOf(MdDoc.Align.LEFT, MdDoc.Align.RIGHT, MdDoc.Align.CENTER), t.align)
        assertEquals(3, t.head.size); assertEquals(2, t.rows.size)
        assertTrue(t.rows[0][0][0].b)

        val img = bs[4] as Block.Image
        assertEquals("a_1", img.att); assertEquals("loss.png", img.name); assertEquals("", img.src)

        val links = (bs[5] as Block.Paragraph).runs
        assertEquals("a_2", links.first { it.text == "report.pdf" }.att)
        assertEquals(MdDoc.Link.Message(12), MdDoc.link(links.first { it.text == "#12" }.href))

        val warn = bs[6] as Block.Callout
        assertEquals("warning", warn.kind); assertEquals("磁盘 95%", warn.title); assertEquals("", warn.fold)
        val log = bs[7] as Block.Callout
        assertEquals("note", log.kind); assertEquals("closed", log.fold)
        assertTrue(log.blocks.single() is Block.Code)

        val q = bs[8] as Block.Quote
        assertTrue(q.blocks[1] is Block.Quote)

        val tasks = bs[9] as Block.ListBlock
        assertFalse(tasks.ordered); assertTrue(tasks.tight)
        assertEquals(true, tasks.items[0].check); assertEquals(false, tasks.items[1].check)
        val nested = tasks.items[1].blocks[1] as Block.ListBlock
        assertTrue(nested.ordered); assertEquals(1, nested.start); assertNull(nested.items[0].check)

        val three = bs[10] as Block.ListBlock
        assertTrue(three.ordered); assertEquals(3, three.start)

        val fnPara = bs[12] as Block.Paragraph
        assertEquals(1, fnPara.runs.first { it.fn != 0 }.fn)
        assertEquals("脚注测试[1]，<b>HTML</b> 不渲染\n换行。", MdDoc.plain(fnPara.runs))

        assertEquals(Block.Code("python", "print(\"hi\")"), bs[13])
        val fns = bs[14] as Block.Footnotes
        assertEquals(1, fns.items.single().n)
    }

    @Test fun unknownVersionOrMissingFallsBack() {
        assertNull(MdDoc.parse(null as JSONObject?))
        assertNull(MdDoc.parse(JSONObject("""{"v":2,"blocks":[]}""")))
        assertNull(MdDoc.parse(JSONObject("""{"blocks":[]}""")))
        assertNull(MdDoc.parse("not json"))
        assertNull(MdDoc.parse(""))
        // 一个能显示的块都没有：当作没有 doc，退回解析 desp
        assertNull(MdDoc.parse("""{"v":1,"blocks":[]}"""))
        assertNull(MdDoc.parse("""{"v":1,"blocks":[{"type":"mermaid"},{"type":"image"}]}"""))
        assertNotNull(MdDoc.parse("""{"v":1,"blocks":[{"type":"rule"}]}"""))
    }

    @Test fun unknownTypesAndFieldsIgnored() {
        val bs = doc(
            """{"type":"mermaid","text":"graph"}""",
            """{"type":"paragraph","runs":[{"text":"a","future":1},{"text":""},{"x":1}],"color":"red"}""",
            """{"type":"image"}""",
            """{"type":"image","src":"javascript:alert(1)"}""",
            """{"type":"file"}""",
            "42",
            """{"type":"rule"}""",
        )
        assertEquals(2, bs.size)
        assertEquals(listOf(MdDoc.Run("a")), (bs[0] as Block.Paragraph).runs)
    }

    @Test fun tableColumnsPaddedAndTruncated() {
        val t = doc(
            """{"type":"table","align":["right"],"head":[[{"text":"A"}],[{"text":"B"}],[{"text":"C"}]],
               "rows":[[[{"text":"1"}]],[[{"text":"1"}],[{"text":"2"}],[{"text":"3"}],[{"text":"4"}]]]}""",
        )[0] as Block.Table
        assertEquals(3, t.columns)
        assertEquals(listOf(MdDoc.Align.RIGHT, MdDoc.Align.NONE, MdDoc.Align.NONE), t.align)
        assertEquals(3, t.rows[0].size); assertTrue(t.rows[0][1].isEmpty())
        assertEquals(3, t.rows[1].size); assertEquals("3", t.rows[1][2][0].text)
        // 空表格跳过
        assertNull(MdDoc.parse("""{"v":1,"blocks":[{"type":"table","head":[],"rows":[]}]}"""))
    }

    @Test fun calloutKindAndFoldNormalized() {
        val c = doc("""{"type":"callout","kind":"SUCCESS","fold":"weird"}""", """{"type":"callout","kind":"bogus","fold":"open"}""")
        assertEquals("success", (c[0] as Block.Callout).kind); assertEquals("", (c[0] as Block.Callout).fold)
        assertEquals("note", (c[1] as Block.Callout).kind); assertEquals("open", (c[1] as Block.Callout).fold)
        assertTrue((c[0] as Block.Callout).blocks.isEmpty())
    }

    @Test fun progressText() {
        fun p(json: String) = doc(json)[0] as Block.Progress
        assertEquals("42%", p("""{"type":"progress","value":0.42}""").display)
        assertEquals("下载 100%", p("""{"type":"progress","value":3,"label":"下载"}""").display)
        assertEquals("0%（0/0）", p("""{"type":"progress","text":"0/0"}""").display)
        assertEquals("训练 50%（1/2）", p("""{"type":"progress","value":0.5,"label":"  训练 ","text":" 1/2 "}""").display)
        // 满格变绿按显示的百分比判断：0.995 显示 100%，算完成；0.994 显示 99%
        assertTrue(p("""{"type":"progress","value":0.995}""").done)
        assertEquals("100%", p("""{"type":"progress","value":0.995}""").display)
        assertFalse(p("""{"type":"progress","value":0.994}""").done)
        assertEquals("12%", MdDoc.percent(0.125))      // 与 Go 的 %.0f 一致：恰好一半时取偶
        assertEquals("67%", MdDoc.percent(2.0 / 3))
    }

    @Test fun links() {
        assertEquals(MdDoc.Link.External("https://a.b/c"), MdDoc.link("https://a.b/c"))
        assertEquals(MdDoc.Link.External("mailto:x@y.z"), MdDoc.link("mailto:x@y.z"))
        assertEquals(MdDoc.Link.Message(123), MdDoc.link("huijian://message/123"))
        assertEquals(MdDoc.Link.Message(45), MdDoc.link("huijian://msg/45"))          // 旧写法
        assertEquals(MdDoc.Link.Message(45), MdDoc.link("HUIJIAN://MSG/45/"))
        assertNull(MdDoc.link("huijian://message/abc"))
        assertNull(MdDoc.link("huijian://settings"))
        assertNull(MdDoc.link("javascript:alert(1)"))
        assertNull(MdDoc.link("intent://x#Intent;end"))
        assertNull(MdDoc.link("file:///sdcard/a"))
        assertNull(MdDoc.link(""))
    }

    @Test fun deepNestingIsBounded() {
        var json = """{"type":"paragraph","runs":[{"text":"x"}]}"""
        repeat(200) { json = """{"type":"quote","blocks":[$json]}""" }
        val bs = doc(json)
        var depth = 0
        var cur: Block = bs[0]
        while (cur is Block.Quote && cur.blocks.isNotEmpty()) { cur = cur.blocks[0]; depth++ }
        assertTrue(depth in 60..70)
    }

    @Test fun messageKeepsDocAndPreviewAcrossSave() {
        val raw = JSONObject()
            .put("id", 7).put("type", "markdown").put("text", "t").put("desp", "**hi**")
            .put("created_at", "2026-11-18T08:00:00Z")
            .put("doc", sample()).put("preview", "实验 exp42 完成")
        val m = Message.from(raw)
        assertNotNull(m.doc); assertEquals("实验 exp42 完成", m.preview)
        val saved = m.toJson()
        assertTrue(saved.get("doc") is String)                        // 本地缓存里存字符串，不常驻 JSONObject
        val again = Message.from(JSONObject(saved.toString()))      // 写盘再读回
        assertEquals(m.doc, again.doc)
        assertEquals(15, MdDoc.parse(again.doc)!!.size)
        assertEquals("实验 exp42 完成", again.preview)
        assertEquals("实验 exp42 完成", again.summary())
    }

    @Test fun devCacheWithDocObjectStillLoads() {
        // 0.2.0 开发版曾把 doc 作为对象写进缓存
        val m = Message.from(JSONObject().put("id", 3).put("desp", "x").put("doc", sample()))
        assertEquals(15, MdDoc.parse(m.doc)!!.size)
    }

    @Test fun oldCacheWithoutDocStillLoads() {
        // 0.1 版写的缓存：没有 doc / preview
        val m = Message.from(JSONObject("""{"id":1,"topic":"default","type":"markdown","text":"t","desp":"## 标题\n**粗体** 正文","created_at":"2026-11-01T00:00:00Z","attachments":[]}"""))
        assertNull(m.doc); assertEquals("", m.preview)
        assertNull(MdDoc.parse(m.doc))
        assertEquals("标题\n粗体 正文", m.summary())
        assertFalse(m.toJson().has("doc")); assertFalse(m.toJson().has("preview"))
    }
}
