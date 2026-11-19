package io.github.hongyile.huijian

import org.json.JSONArray
import org.json.JSONObject
import java.math.BigDecimal
import java.math.RoundingMode

/**
 * 回笺 Markdown 的结构化结果（服务端 0.6.0 起随消息下发的 `doc` 字段，规范见 docs/markdown.md）。
 * 只认识 v=1；版本不认识或结构损坏时 parse 返回 null，调用方退回 Markdown.kt 自己解析 desp。
 * 未知的块类型跳过、未知字段忽略。
 */
object MdDoc {
    const val VERSION = 1

    data class Run(
        val text: String,
        val b: Boolean = false,
        val i: Boolean = false,
        val s: Boolean = false,
        val code: Boolean = false,
        val href: String = "",
        val att: String = "",
        val fn: Int = 0,
    )

    data class Item(val check: Boolean?, val blocks: List<Block>)
    data class Footnote(val n: Int, val blocks: List<Block>)

    enum class Align { NONE, LEFT, CENTER, RIGHT }

    sealed interface Block {
        data class Heading(val level: Int, val runs: List<Run>) : Block
        data class Paragraph(val runs: List<Run>) : Block
        data class ListBlock(val ordered: Boolean, val start: Int, val tight: Boolean, val items: List<Item>) : Block
        data class Quote(val blocks: List<Block>) : Block
        data class Callout(val kind: String, val title: String, val fold: String, val blocks: List<Block>) : Block
        data class Code(val lang: String, val text: String) : Block
        data object Rule : Block
        /** head / rows 已按表头列数补齐或截断，align 长度等于列数 */
        data class Table(val align: List<Align>, val head: List<List<Run>>, val rows: List<List<List<Run>>>) : Block {
            val columns get() = align.size
        }
        data class Image(val att: String, val src: String, val alt: String, val name: String, val mime: String, val size: Long) : Block
        data class File(val att: String, val name: String, val mime: String, val size: Long, val alt: String) : Block
        data class Progress(val value: Double, val label: String, val text: String) : Block {
            /** 显示的百分比 ≥100（0.995 也显示成 100%）时算完成，进度条变绿 */
            val done get() = percentInt(value) >= 100

            /** 和服务端 progressText 一致：label + 百分比 + （text） */
            val display: String get() {
                var s = percent(value)
                if (text.isNotEmpty()) s += "（$text）"
                if (label.isNotEmpty()) s = "$label $s"
                return s
            }
        }
        data class Footnotes(val items: List<Footnote>) : Block
    }

    /** 提示框类型（服务端已把同义写法归一成这 7 种；不认识的按 note 处理） */
    val CALLOUT_KINDS = listOf("note", "tip", "important", "warning", "caution", "success", "failure")

    /** 进度百分比：四舍五入到整数（与服务端 Go 的 %.0f 一致，恰好 .5 时取偶） */
    fun percentInt(v: Double): Int = BigDecimal(v.coerceIn(0.0, 1.0) * 100).setScale(0, RoundingMode.HALF_EVEN).toInt()

    fun percent(v: Double): String = "${percentInt(v)}%"

    /** 解析 doc；null / 版本不认识 / 结构损坏 / 一个能显示的块都没有时返回 null（调用方退回自己解析 desp） */
    fun parse(o: JSONObject?): List<Block>? {
        if (o == null || o.optInt("v", -1) != VERSION) return null
        val arr = o.optJSONArray("blocks") ?: return null
        return runCatching { blocks(arr, 0) }.getOrNull()?.takeIf { it.isNotEmpty() }
    }

    fun parse(json: String?): List<Block>? =
        if (json.isNullOrBlank()) null else runCatching { JSONObject(json) }.getOrNull()?.let { parse(it) }

    private const val MAX_DEPTH = 64

    private fun blocks(arr: JSONArray?, depth: Int): List<Block> {
        if (arr == null || depth > MAX_DEPTH) return emptyList()
        val out = ArrayList<Block>(arr.length())
        for (k in 0 until arr.length()) {
            val o = arr.optJSONObject(k) ?: continue
            block(o, depth)?.let { out += it }
        }
        return out
    }

    private fun block(o: JSONObject, depth: Int): Block? = when (o.optString("type")) {
        "heading" -> Block.Heading(o.optInt("level", 1).coerceIn(1, 6), runs(o.optJSONArray("runs")))
        "paragraph" -> Block.Paragraph(runs(o.optJSONArray("runs")))
        "list" -> {
            val items = o.optJSONArray("items")
            Block.ListBlock(
                ordered = o.optBoolean("ordered"),
                start = o.optInt("start", 1),
                tight = o.optBoolean("tight"),
                items = if (items == null) emptyList() else (0 until items.length()).mapNotNull { k ->
                    val it = items.optJSONObject(k) ?: return@mapNotNull null
                    Item(
                        check = if (it.has("check") && !it.isNull("check")) it.optBoolean("check") else null,
                        blocks = blocks(it.optJSONArray("blocks"), depth + 1),
                    )
                },
            )
        }
        "quote" -> Block.Quote(blocks(o.optJSONArray("blocks"), depth + 1))
        "callout" -> Block.Callout(
            kind = o.optString("kind").lowercase().takeIf { it in CALLOUT_KINDS } ?: "note",
            title = o.optString("title"),
            fold = o.optString("fold").takeIf { it == "open" || it == "closed" } ?: "",
            blocks = blocks(o.optJSONArray("blocks"), depth + 1),
        )
        "code" -> Block.Code(o.optString("lang"), o.optString("text"))
        "rule" -> Block.Rule
        "table" -> table(o)
        "image" -> {
            val att = o.optString("att")
            val src = o.optString("src").takeIf { it.matches(HTTP) }.orEmpty()
            if (att.isEmpty() && src.isEmpty()) null
            else Block.Image(att, src, o.optString("alt"), o.optString("name"), o.optString("mime"), o.optLong("size"))
        }
        "file" -> o.optString("att").takeIf { it.isNotEmpty() }?.let {
            Block.File(it, o.optString("name"), o.optString("mime"), o.optLong("size"), o.optString("alt"))
        }
        "progress" -> {
            val v = o.optDouble("value", 0.0).let { if (it.isNaN()) 0.0 else it.coerceIn(0.0, 1.0) }
            Block.Progress(v, o.optString("label").trim(), o.optString("text").trim())
        }
        "footnotes" -> {
            val items = o.optJSONArray("items")
            Block.Footnotes(if (items == null) emptyList() else (0 until items.length()).mapNotNull { k ->
                val it = items.optJSONObject(k) ?: return@mapNotNull null
                Footnote(it.optInt("n", k + 1), blocks(it.optJSONArray("blocks"), depth + 1))
            })
        }
        else -> null      // 未知类型跳过
    }

    private fun table(o: JSONObject): Block.Table? {
        val head = o.optJSONArray("head")
        val rowsArr = o.optJSONArray("rows")
        val headCells = if (head == null) emptyList() else (0 until head.length()).map { runs(head.optJSONArray(it)) }
        val rows = if (rowsArr == null) emptyList() else (0 until rowsArr.length()).map { r ->
            val row = rowsArr.optJSONArray(r)
            if (row == null) emptyList() else (0 until row.length()).map { runs(row.optJSONArray(it)) }
        }
        // 列数以表头为准；没有表头时取最宽的一行
        val cols = if (headCells.isNotEmpty()) headCells.size else rows.maxOfOrNull { it.size } ?: 0
        if (cols == 0) return null
        val alignArr = o.optJSONArray("align")
        val align = List(cols) { c ->
            when (alignArr?.optString(c)) { "left" -> Align.LEFT; "center" -> Align.CENTER; "right" -> Align.RIGHT; else -> Align.NONE }
        }
        fun fit(cells: List<List<Run>>) = List(cols) { cells.getOrNull(it) ?: emptyList() }
        return Block.Table(align, if (headCells.isEmpty()) emptyList() else fit(headCells), rows.map(::fit))
    }

    private fun runs(arr: JSONArray?): List<Run> {
        if (arr == null) return emptyList()
        val out = ArrayList<Run>(arr.length())
        for (k in 0 until arr.length()) {
            val r = arr.optJSONObject(k) ?: continue
            val text = r.optString("text")
            if (text.isEmpty()) continue
            out += Run(
                text = text,
                b = r.optBoolean("b"), i = r.optBoolean("i"), s = r.optBoolean("s"), code = r.optBoolean("code"),
                href = r.optString("href"), att = r.optString("att"), fn = r.optInt("fn"),
            )
        }
        return out
    }

    private val HTTP = Regex("""(?i)^https?://\S+""")

    /** huijian://message/<id>，也认旧写法 huijian://msg/<id> 和改名前的 hongyan:// */
    private val MESSAGE_LINK = Regex("""(?i)^(?:huijian|hongyan)://(?:message|msg)/(\d{1,18})/?$""")

    sealed interface Link {
        data class External(val url: String) : Link
        data class Message(val id: Long) : Link
    }

    /** 判断链接去向：http / https / mailto 交给系统（沿用 Markdown.SAFE_LINK），huijian://message/<id> 在应用内打开；其他协议（file: intent: javascript: 等）返回 null，显示成普通文字 */
    fun link(href: String): Link? {
        if (href.isBlank()) return null
        MESSAGE_LINK.matchEntire(href)?.let { m -> return m.groupValues[1].toLongOrNull()?.let { Link.Message(it) } }
        return if (href.matches(Markdown.SAFE_LINK)) Link.External(href) else null
    }

    /** 块的纯文本（复制、无障碍朗读用） */
    fun plain(runs: List<Run>): String = runs.joinToString("") { if (it.fn != 0) "[${it.text}]" else it.text }
}
