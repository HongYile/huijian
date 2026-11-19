package io.github.hongyile.huijian

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle

/** 精简版 Markdown：够看通知正文（标题、列表、引用、代码块、粗体、斜体、行内代码、链接） */
object Markdown {
    sealed interface Block {
        data class Heading(val level: Int, val text: String) : Block
        data class Para(val text: String) : Block
        data class Bullet(val marker: String, val text: String, val indent: Int) : Block
        data class Quote(val text: String) : Block
        data class Code(val lang: String, val code: String) : Block
        data object Rule : Block
    }

    fun parse(src: String): List<Block> {
        val out = mutableListOf<Block>()
        val lines = src.replace("\r\n", "\n").split("\n")
        var i = 0
        val para = StringBuilder()
        fun flush() { if (para.isNotBlank()) out += Block.Para(para.toString().trim()); para.clear() }
        while (i < lines.size) {
            val line = lines[i]
            val t = line.trim()
            when {
                t.startsWith("```") -> {
                    flush()
                    val lang = t.removePrefix("```").trim()
                    val code = StringBuilder()
                    i++
                    while (i < lines.size && !lines[i].trim().startsWith("```")) { code.appendLine(lines[i]); i++ }
                    out += Block.Code(lang, code.toString().trimEnd())
                }
                t.isEmpty() -> flush()
                Regex("^#{1,6}\\s").containsMatchIn(t) -> {
                    flush(); val lv = t.takeWhile { it == '#' }.length
                    out += Block.Heading(lv, t.drop(lv).trim())
                }
                t == "---" || t == "***" -> { flush(); out += Block.Rule }
                t.startsWith(">") -> { flush(); out += Block.Quote(t.removePrefix(">").trim()) }
                Regex("^([-*+]|\\d+[.)])\\s").containsMatchIn(t) -> {
                    flush()
                    val m = Regex("^([-*+]|\\d+[.)])\\s+(.*)").find(t)!!
                    val marker = m.groupValues[1].let { if (it in setOf("-", "*", "+")) "•" else it }
                    out += Block.Bullet(marker, m.groupValues[2], (line.length - line.trimStart().length) / 2)
                }
                else -> { if (para.isNotEmpty()) para.append('\n'); para.append(t) }
            }
            i++
        }
        flush()
        return out
    }

    /** 只放行 http / https / mailto（MdDoc.link 也用它） */
    internal val SAFE_LINK = Regex("""(?i)^(https?://|mailto:).+""")
    private val inline = Regex("""\*\*(.+?)\*\*|__(.+?)__|`([^`]+)`|\[([^\]]+)]\(([^)\s]+)\)|(?<![*\w])\*(?!\s)(.+?)(?<!\s)\*(?!\*)""")

    fun inline(s: String, link: Color, codeBg: Color): AnnotatedString = buildAnnotatedString {
        var pos = 0
        for (m in inline.findAll(s)) {
            append(s.substring(pos, m.range.first))
            val g = m.groupValues
            when {
                g[1].isNotEmpty() || g[2].isNotEmpty() ->
                    withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(g[1].ifEmpty { g[2] }) }
                g[3].isNotEmpty() ->
                    withStyle(SpanStyle(fontFamily = FontFamily.Monospace, background = codeBg)) { append(" ${g[3]} ") }
                g[4].isNotEmpty() && !g[5].matches(SAFE_LINK) -> append(g[4])    // 只放行 http/https/mailto，file: intent: 等不可点
                g[4].isNotEmpty() ->
                    withLink(LinkAnnotation.Url(g[5], TextLinkStyles(SpanStyle(color = link, textDecoration = TextDecoration.Underline)))) { append(g[4]) }
                g[6].isNotEmpty() -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(g[6]) }
            }
            pos = m.range.last + 1
        }
        append(s.substring(pos))
    }

    /** 去掉标记的纯文本，用于通知和列表预览 */
    fun plain(s: String): String = parse(s).joinToString("\n") { b ->
        when (b) {
            is Block.Heading -> b.text
            is Block.Para -> b.text
            is Block.Bullet -> "${b.marker} ${b.text}"
            is Block.Quote -> b.text
            is Block.Code -> b.code
            Block.Rule -> ""
        }
    }.replace(Regex("""\*\*(.+?)\*\*|__(.+?)__"""), "$1$2")
        .replace(Regex("""`([^`]+)`"""), "$1")
        .replace(Regex("""\[([^\]]+)]\([^)]+\)"""), "$1")
        .trim()
}
