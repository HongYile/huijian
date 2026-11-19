package io.github.hongyile.huijian.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.BitmapFactory
import android.widget.Toast
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.DisableSelection
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.key
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.BaselineShift
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import io.github.hongyile.huijian.AttDownloads
import io.github.hongyile.huijian.Attachment
import io.github.hongyile.huijian.MdDoc
import io.github.hongyile.huijian.MdDoc.Block
import io.github.hongyile.huijian.Message
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.TimeUnit

/*
 * 按服务端下发的 doc 绘制回笺 Markdown（docs/markdown.md「给客户端开发者」）。
 * 顶层块是详情页 LazyColumn 的列表项（docItems），整个列表包在 SelectionContainer 里，文字可以选择复制；按钮、占位提示用 DisableSelection 排除。
 */

/** 正文绘制需要的上下文：所属消息（找附件）、附件下载状态、跳转回调 */
@Stable
class MdEnv(
    val message: Message,
    val atts: AttLoader,
    val openMessage: (Long) -> Unit,
    val showImage: (ImageBitmap) -> Unit,
    /** 点脚注上标：滚到文末对应的脚注 */
    val footnote: (Int) -> Unit = {},
) {
    fun attachment(id: String) = message.attachments.firstOrNull { it.id == id }

    /** 外部图片的加载状态（src → LOADING / ImageBitmap / 错误文字）。放在这里而不是列表项里，滚出屏幕再回来不用重新加载 */
    val external = mutableStateMapOf<String, Any>()

    /** 最近一次手势是不是长按：长按是在选文字，不能顺带打开链接（Compose 的链接在长按松手时也会触发） */
    var longPress = false

    /** 链接点击统一走这里，长按时忽略 */
    fun click(action: () -> Unit) { if (!longPress) action() }

    /** 点附件链接 / 附件卡片：已下载的直接打开（图片在应用内看大图），没下载的先下载 */
    fun open(ctx: Context, a: Attachment) = atts.open(ctx, a, showImage)
}

/**
 * 一个详情页用的附件操作。下载本身和下载状态在进程级的 AttDownloads 里（同一附件只下一份）；
 * scope 是这个页面的协程作用域：「下完再打开」的回调挂在它上面，用户离开这条消息后就不会再打开。
 */
@Stable
class AttLoader(private val ctx: Context, private val scope: CoroutineScope) {
    /** id → LOADING / DONE / 「失败：…」（进程级，所有页面共用） */
    val status get() = AttDownloads.status

    fun file(a: Attachment) = attFile(ctx, a)
    fun have(a: Attachment) = status[a.id] == DONE || (status[a.id] == null && file(a).exists())
    fun loading(a: Attachment) = status[a.id] == LOADING
    fun error(a: Attachment) = status[a.id]?.takeIf { it != DONE && it != LOADING }

    /** 开始下载（已在下载时等同一份）；then 在下载成功后调用，下载中重复点也会登记，不会丢 */
    fun download(a: Attachment, then: (() -> Unit)? = null) {
        val d = AttDownloads.download(a, file(a))
        if (then != null) scope.launch { if (runCatching { d.await() }.isSuccess) then() }
    }

    fun open(ctx: Context, a: Attachment, showImage: (ImageBitmap) -> Unit) {
        val go = {
            val f = file(a)
            if (a.isImage) scope.launch {
                val bmp = withContext(Dispatchers.IO) { decodeSampled(f)?.asImageBitmap() }
                if (bmp != null) showImage(bmp) else openFile(ctx, f, a.mime)
            } else openFile(ctx, f, a.mime)
        }
        if (have(a)) go() else download(a) { go() }
    }

    companion object {
        const val LOADING = AttDownloads.LOADING
        const val DONE = AttDownloads.DONE
    }
}

private val LocalListDepth = compositionLocalOf { 0 }

/** 正文在详情页 LazyColumn 里的一项：顶层的每个块各占一项；脚注拆开，每条脚注一项（点上标时按序号滚过去） */
sealed interface DocItem {
    data class Top(val block: Block) : DocItem
    data object FootnotesStart : DocItem
    data class Note(val note: MdDoc.Footnote) : DocItem
}

fun docItems(blocks: List<Block>): List<DocItem> = buildList {
    for (b in blocks) {
        if (b is Block.Footnotes) { add(DocItem.FootnotesStart); b.items.forEach { add(DocItem.Note(it)) } }
        else add(DocItem.Top(b))
    }
}

/** 第 n 条脚注在 docItems 里的位置，找不到返回 -1 */
fun List<DocItem>.footnoteIndex(n: Int) = indexOfFirst { it is DocItem.Note && it.note.n == n }

/** 正文入口：把每一项加进详情页的 LazyColumn（长文档只组合屏幕上看得到的部分） */
fun LazyListScope.docItems(items: List<DocItem>, env: MdEnv) {
    itemsIndexed(items) { _, it ->
        ProvideTextStyle(TextStyle(fontSize = 15.sp, lineHeight = 22.sp)) {
            when (it) {
                is DocItem.Top -> Box(Modifier.padding(top = 10.dp)) { BlockView(it.block, env) }
                DocItem.FootnotesStart -> HorizontalDivider(Modifier.padding(top = 16.dp, bottom = 2.dp).width(80.dp), color = lineColor())
                is DocItem.Note -> Box(Modifier.padding(top = 4.dp)) { FootnoteRow(it.note, env) }
            }
        }
    }
}

/**
 * 长按守卫：Initial 阶段先于链接看到按下 / 松开，记下这次是不是长按。
 * 长按是在选文字，Compose 的链接在长按松手时也会触发，靠 env.click 忽略掉。
 */
fun Modifier.linkGuard(env: MdEnv) = pointerInput(env) {
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
        env.longPress = false
        val up = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
            waitForUpOrCancellation(PointerEventPass.Initial)
        }
        if (up == null) env.longPress = true      // 超过长按时间还没松开（或手势被取消）
    }
}

@Composable
private fun Blocks(blocks: List<Block>, env: MdEnv, gap: androidx.compose.ui.unit.Dp = 8.dp) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(gap)) {
        blocks.forEachIndexed { k, b -> key(k) { BlockView(b, env) } }     // key：折叠状态等按位置区分
    }
}

@Composable
private fun BlockView(b: Block, env: MdEnv) {
    when (b) {
        is Block.Heading -> Text(
            runsText(b.runs, env),
            Modifier.padding(top = if (b.level <= 2) 4.dp else 2.dp),
            fontSize = when (b.level) { 1 -> 21.sp; 2 -> 18.5.sp; 3 -> 16.5.sp; else -> 15.sp },
            lineHeight = when (b.level) { 1 -> 28.sp; 2 -> 25.sp; else -> 22.sp },
            fontWeight = FontWeight.SemiBold,
            color = if (b.level >= 5) MaterialTheme.colorScheme.onSurfaceVariant else androidx.compose.ui.graphics.Color.Unspecified,
        )
        is Block.Paragraph -> if (b.runs.isNotEmpty()) Text(runsText(b.runs, env), style = LocalTextStyle.current)
        is Block.ListBlock -> ListView(b, env)
        is Block.Quote -> QuoteView(b, env)
        is Block.Callout -> CalloutView(b, env)
        is Block.Code -> CodeView(b)
        Block.Rule -> HorizontalDivider(Modifier.padding(vertical = 4.dp), color = lineColor())
        is Block.Table -> TableView(b, env)
        is Block.Image -> if (b.att.isNotEmpty()) AttImageView(b, env) else ExternalImageView(b, env)
        is Block.File -> FileCard(b, env)
        is Block.Progress -> ProgressView(b)
        is Block.Footnotes -> FootnotesView(b, env)
    }
}

// ---------------- 行内 ----------------

@Composable
private fun runsText(runs: List<MdDoc.Run>, env: MdEnv, bold: Boolean = false): AnnotatedString {
    val ctx = LocalContext.current
    val link = MaterialTheme.colorScheme.primary
    val codeBg = codeBackground()
    return remember(runs, link, codeBg, bold, env) { buildRuns(runs, link, codeBg, bold, env, ctx) }
}

private fun buildRuns(runs: List<MdDoc.Run>, link: Color, codeBg: Color, bold: Boolean, env: MdEnv, ctx: Context) = buildAnnotatedString {
    val linkStyle = TextLinkStyles(SpanStyle(color = link, textDecoration = TextDecoration.Underline))
    for (r in runs) {
        if (r.fn != 0) {      // 脚注编号：上标 [1]
            withLink(LinkAnnotation.Clickable("fn:${r.fn}", TextLinkStyles(SpanStyle(color = link))) { env.click { env.footnote(r.fn) } }) {
                withStyle(SpanStyle(baselineShift = BaselineShift.Superscript, fontSize = 0.72.em)) { append("[${r.fn}]") }
            }
            continue
        }
        val style = SpanStyle(
            fontWeight = if (r.b || bold) FontWeight.SemiBold else null,
            fontStyle = if (r.i) FontStyle.Italic else null,
            textDecoration = if (r.s) TextDecoration.LineThrough else null,
            background = if (r.code) codeBg else Color.Unspecified,
        )
        val mono = SpanStyle(fontFamily = FontFamily.Monospace, fontSize = 0.9.em)
        // 行内代码：前后各加一个窄空格（不套等宽字体），背景不贴字
        val text: AnnotatedString.Builder.() -> Unit = {
            if (r.code) { append("\u2009"); withStyle(mono) { append(r.text) }; append("\u2009") } else append(r.text)
        }
        val target = MdDoc.link(r.href)
        when {
            r.att.isNotEmpty() -> {
                val a = env.attachment(r.att)
                if (a == null) withStyle(style) { text() }
                else withLink(LinkAnnotation.Clickable("att:${r.att}", linkStyle) { env.click { env.open(ctx, a) } }) {
                    withStyle(style) { append("📎 "); text() }
                }
            }
            target is MdDoc.Link.External -> withLink(LinkAnnotation.Clickable("url", linkStyle) { env.click { openUrl(ctx, target.url) } }) {
                withStyle(style) { text() }
            }
            target is MdDoc.Link.Message -> withLink(LinkAnnotation.Clickable("msg:${target.id}", linkStyle) { env.click { env.openMessage(target.id) } }) {
                withStyle(style) { text() }
            }
            else -> withStyle(style) { text() }     // 其他协议不可点
        }
    }
}

/** 系统打开 http / https / mailto（调用前已用 MdDoc.link 过滤协议） */
private fun openUrl(ctx: Context, url: String) {
    try {
        ctx.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))
            .addCategory(android.content.Intent.CATEGORY_BROWSABLE).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (_: Exception) {
        Toast.makeText(ctx, "没有能打开这个链接的应用", Toast.LENGTH_SHORT).show()
    }
}

// ---------------- 列表 / 引用 / 提示框 ----------------

@Composable
private fun ListView(b: Block.ListBlock, env: MdEnv) {
    val depth = LocalListDepth.current
    Column(verticalArrangement = Arrangement.spacedBy(if (b.tight) 3.dp else 8.dp)) {
        b.items.forEachIndexed { k, item ->
            Row {
                Box(Modifier.widthIn(min = 24.dp).padding(end = 4.dp)) {
                    when {
                        item.check != null -> CheckMark(item.check)
                        b.ordered -> Text("${b.start + k}.", style = LocalTextStyle.current, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        else -> Text(listOf("•", "◦", "▪")[depth % 3], style = LocalTextStyle.current,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                Column(Modifier.weight(1f)) {
                    CompositionLocalProvider(LocalListDepth provides depth + 1) {
                        Blocks(item.blocks, env, if (b.tight) 3.dp else 6.dp)
                    }
                }
            }
        }
    }
}

@Composable
private fun CheckMark(checked: Boolean) {
    val c = MaterialTheme.colorScheme.primary
    val shape = RoundedCornerShape(4.dp)
    Box(
        Modifier.padding(top = 3.dp).size(16.dp).clip(shape)
            .then(if (checked) Modifier.background(c) else Modifier.border(1.5.dp, MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f), shape)),
        contentAlignment = Alignment.Center,
    ) {
        if (checked) Icon(Icons.Default.Check, "已完成", Modifier.size(13.dp), tint = MaterialTheme.colorScheme.onPrimary)
    }
}

/** 左侧竖条（引用、提示框） */
private fun Modifier.leftBar(color: Color) = drawBehind {
    drawRect(color, size = Size(3.dp.toPx(), size.height))
}

@Composable
private fun QuoteView(b: Block.Quote, env: MdEnv) {
    Box(Modifier.fillMaxWidth().leftBar(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.3f)).padding(start = 12.dp)) {
        CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onSurfaceVariant) {
            Blocks(b.blocks, env, 6.dp)
        }
    }
}

private val CALLOUT_ICON = mapOf(
    "note" to "ℹ️", "tip" to "💡", "important" to "❗", "warning" to "⚠️", "caution" to "⛔", "success" to "✅", "failure" to "❌",
)
private val CALLOUT_TITLE = mapOf(
    "note" to "说明", "tip" to "建议", "important" to "重要", "warning" to "警告", "caution" to "危险", "success" to "成功", "failure" to "失败",
)

/** 提示框颜色：浅色 / 深色模式各一套（深色提亮，背景透明度稍高）；与 Mac / iPhone 端取值相同 */
private fun calloutColor(kind: String, dark: Boolean): Color = if (!dark) when (kind) {
    "tip" -> Color(0xFF2E9E7A); "important" -> Color(0xFF8250DF); "warning" -> Color(0xFFD9822B)
    "caution" -> Color(0xFFC0392B); "success" -> Color(0xFF3C8D5A); "failure" -> Color(0xFFD64545)
    else -> Color(0xFF4A6FD6)
} else when (kind) {
    "tip" -> Color(0xFF5CC4A2); "important" -> Color(0xFFB394F2); "warning" -> Color(0xFFEFA65C)
    "caution" -> Color(0xFFEA7468); "success" -> Color(0xFF66C08A); "failure" -> Color(0xFFF08080)
    else -> Color(0xFF8EA8F0)
}

@Composable
private fun isDark() = MaterialTheme.colorScheme.background.luminance() < 0.5f

@Composable
private fun CalloutView(b: Block.Callout, env: MdEnv) {
    val dark = isDark()
    val fg = calloutColor(b.kind, dark)
    var open by rememberSaveable(b.fold) { mutableStateOf(b.fold != "closed") }
    val foldable = b.fold.isNotEmpty()
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp))
            .background(fg.copy(alpha = if (dark) 0.14f else 0.09f))
            .leftBar(fg)
            .padding(start = 14.dp, end = 10.dp, top = 8.dp, bottom = 9.dp),
    ) {
        Row(
            Modifier.fillMaxWidth().then(if (foldable) Modifier.clickable { open = !open } else Modifier),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                (CALLOUT_ICON[b.kind] ?: "ℹ️") + " " + b.title.ifBlank { CALLOUT_TITLE[b.kind] ?: "说明" },
                Modifier.weight(1f), color = fg, fontWeight = FontWeight.SemiBold, style = LocalTextStyle.current,
            )
            if (foldable) Icon(
                Icons.Default.KeyboardArrowDown, if (open) "折叠" else "展开",
                Modifier.size(22.dp).rotate(if (open) 0f else -90f), tint = fg,
            )
        }
        if (open && b.blocks.isNotEmpty()) {
            Spacer(Modifier.height(5.dp))
            Blocks(b.blocks, env, 6.dp)
        }
    }
}

// ---------------- 代码 / 表格 ----------------

@Composable
private fun codeBackground(): Color =
    if (isDark()) Color(0xFF2E2C28) else Color(0xFFEFECE5)

@Composable
private fun lineColor() = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.14f)

@Composable
private fun CodeView(b: Block.Code) {
    val ctx = LocalContext.current
    Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(8.dp), color = codeBackground()) {
        Column {
            DisableSelection {
                Row(Modifier.fillMaxWidth().padding(start = 10.dp, end = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(b.lang.ifBlank { "代码" }, Modifier.weight(1f), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    TextButton({ copy(ctx, b.text) }, Modifier.height(30.dp), contentPadding = PaddingValues(horizontal = 10.dp)) {
                        Text("复制", fontSize = 12.sp)
                    }
                }
            }
            Text(
                b.text,
                Modifier.horizontalScroll(rememberScrollState()).padding(start = 10.dp, end = 10.dp, bottom = 10.dp),
                fontFamily = FontFamily.Monospace, fontSize = 13.sp, lineHeight = 19.sp, softWrap = false,
            )
        }
    }
}

private fun copy(ctx: Context, text: String) {
    val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    cm.setPrimaryClip(ClipData.newPlainText("code", text))
    // Android 13 起系统自己会提示已复制
    if (android.os.Build.VERSION.SDK_INT < 33) Toast.makeText(ctx, "已复制", Toast.LENGTH_SHORT).show()
}

private const val TABLE_ROWS = 200

/**
 * 表格：列宽取该列最宽单元格（单列最宽 260dp，超出换行），行高取该行最高单元格；整张表可以横向滚动。
 * 每个单元格只问一次最大固有宽度、按列宽测量一次；网格线、表头和隔行底色由表格自己按算好的位置画，
 * 单元格本身不带背景（不用为了撑满行高再测一遍）。超过 200 行时先只画前 200 行。
 */
@Composable
private fun TableView(t: Block.Table, env: MdEnv) {
    val line = lineColor()
    val headBg = MaterialTheme.colorScheme.surfaceVariant
    val stripe = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.03f)
    val bg = MaterialTheme.colorScheme.background
    val cols = t.columns
    var all by rememberSaveable(t) { mutableStateOf(false) }
    val body = if (all || t.rows.size <= TABLE_ROWS) t.rows else t.rows.subList(0, TABLE_ROWS)
    val hasHead = t.head.isNotEmpty()
    val rows = remember(t, body) { (if (hasHead) listOf(t.head) else emptyList()) + body }
    // 布局阶段算出的列宽 / 行高 / 线宽，绘制阶段按同一组数画底色和网格线（线宽也要用同一个值，否则行数多了会错位）
    var geo by remember { mutableStateOf<Triple<IntArray, IntArray, Int>?>(null) }
    Column {
        Box(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
            Layout(
                content = {
                    rows.forEachIndexed { r, row ->
                        val isHead = r == 0 && hasHead
                        row.forEachIndexed { c, cell ->
                            Box(Modifier.padding(horizontal = 10.dp, vertical = 6.dp)) {
                                Text(
                                    runsText(cell, env, bold = isHead), Modifier.fillMaxWidth(),
                                    textAlign = when (t.align[c]) {
                                        MdDoc.Align.CENTER -> TextAlign.Center; MdDoc.Align.RIGHT -> TextAlign.End; else -> TextAlign.Start
                                    },
                                    fontSize = 14.sp, lineHeight = 20.sp,
                                )
                            }
                        }
                    }
                },
                modifier = Modifier.clip(RoundedCornerShape(6.dp)).drawBehind {
                    val (ws, hs, gap) = geo ?: return@drawBehind
                    drawRect(line)
                    var y = gap
                    for (r in hs.indices) {
                        val fill = if (r == 0 && hasHead) headBg else bg
                        val tint = if (!(r == 0 && hasHead) && (if (hasHead) r - 1 else r) % 2 == 1) stripe else null
                        var x = gap
                        for (c in ws.indices) {
                            drawRect(fill, Offset(x.toFloat(), y.toFloat()), Size(ws[c].toFloat(), hs[r].toFloat()))
                            if (tint != null) drawRect(tint, Offset(x.toFloat(), y.toFloat()), Size(ws[c].toFloat(), hs[r].toFloat()))
                            x += ws[c] + gap
                        }
                        y += hs[r] + gap
                    }
                },
            ) { ms, _ ->
                val n = rows.size
                val gap = 1.dp.roundToPx().coerceAtLeast(1)
                val maxW = 260.dp.roundToPx()
                val minW = 36.dp.roundToPx()
                val widths = IntArray(cols) { minW }
                for (k in ms.indices) {
                    val c = k % cols
                    widths[c] = maxOf(widths[c], ms[k].maxIntrinsicWidth(Constraints.Infinity).coerceAtMost(maxW))
                }
                val ps = ms.mapIndexed { k, m -> m.measure(Constraints.fixedWidth(widths[k % cols])) }
                val heights = IntArray(n) { r -> (0 until cols).maxOf { c -> ps[r * cols + c].height } }
                geo = Triple(widths, heights, gap)
                val w = widths.sum() + gap * (cols + 1)
                val h = heights.sum() + gap * (n + 1)
                layout(w, h) {
                    var y = gap
                    for (r in 0 until n) {
                        var x = gap
                        for (c in 0 until cols) {
                            ps[r * cols + c].place(x, y)
                            x += widths[c] + gap
                        }
                        y += heights[r] + gap
                    }
                }
            }
        }
        if (t.rows.size > TABLE_ROWS) DisableSelection {
            TextButton({ all = !all }, contentPadding = PaddingValues(horizontal = 4.dp)) {
                Text(if (all) "只显示前 $TABLE_ROWS 行" else "显示全部 ${t.rows.size} 行", fontSize = 13.sp)
            }
        }
    }
}

// ---------------- 图片 / 附件 / 进度 / 脚注 ----------------

/** 按宽度铺满（小图保持原尺寸），高度最多 420dp */
@Composable
private fun FittedImage(bmp: ImageBitmap, desc: String, onClick: () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val density = LocalDensity.current
        val natural = with(density) { bmp.width.toDp() }
        var w = if (bmp.width < 240) natural else maxWidth
        if (w > maxWidth) w = maxWidth
        var h = w * (bmp.height.toFloat() / bmp.width.coerceAtLeast(1))
        val maxH = 420.dp
        if (h > maxH) { w = w * (maxH / h); h = maxH }
        Image(
            bmp, desc,
            Modifier.size(w, h).clip(RoundedCornerShape(8.dp)).clickable(onClick = onClick),
            contentScale = ContentScale.Fit,
        )
    }
}

@Composable
private fun Caption(text: String) {
    if (text.isNotBlank()) Text(text, Modifier.padding(top = 4.dp), fontSize = 12.sp, lineHeight = 16.sp,
        color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun Placeholder(title: String, sub: String, onClick: (() -> Unit)?) {
    DisableSelection {
        Surface(
            Modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
            shape = RoundedCornerShape(10.dp), color = MaterialTheme.colorScheme.surfaceVariant,
        ) {
            Row(Modifier.padding(horizontal = 12.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("🖼", fontSize = 22.sp)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(title, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                    if (sub.isNotBlank()) Text(sub, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

private const val AUTO_IMAGE_BYTES = 20L * 1024 * 1024

/** 附件图片：进入详情自动下载（同附件区的缓存），点开大图 */
@Composable
private fun AttImageView(b: Block.Image, env: MdEnv) {
    val ctx = LocalContext.current
    val a = env.attachment(b.att)
    if (a == null) {
        Text("🖼 " + b.alt.ifBlank { b.name }, color = MaterialTheme.colorScheme.onSurfaceVariant)
        return
    }
    val have = env.atts.have(a)
    // 不超过 20MB 的图片进入详情就自动下载；更大的等用户点（省流量）
    val auto = a.size <= AUTO_IMAGE_BYTES
    LaunchedEffect(a.id) { if (auto && !env.atts.have(a) && env.atts.error(a) == null) env.atts.download(a) }
    val bmp by produceState<ImageBitmap?>(null, have, a.id) {
        value = if (have) withContext(Dispatchers.IO) { decodeSampled(env.atts.file(a))?.asImageBitmap() } else null
    }
    Column {
        val img = bmp
        when {
            img != null -> FittedImage(img, b.alt.ifBlank { a.name }) { env.showImage(img) }
            env.atts.error(a) != null -> Placeholder("图片加载失败，点按重试", a.name + " · " + env.atts.error(a)) { env.atts.download(a) }
            have -> Placeholder("无法显示这张图片", a.name + " · 点按用其他应用打开") { openFile(ctx, env.atts.file(a), a.mime) }
            env.atts.loading(a) || auto -> Placeholder("正在加载图片…", a.name + " · " + sizeText(a.size), null)
            else -> Placeholder("点按加载图片", a.name + " · " + sizeText(a.size)) { env.atts.download(a) }
        }
        Caption(b.alt.takeIf { it != a.name }.orEmpty())
    }
}

/** 外部图片：默认不加载（不向陌生服务器暴露 IP 和打开时间），点按后下载；不带任何鉴权头 */
@Composable
private fun ExternalImageView(b: Block.Image, env: MdEnv) {
    val scope = rememberCoroutineScope()
    val state = env.external[b.src]        // null 未加载 / LOADING / ImageBitmap / 错误文字
    val host = remember(b.src) { runCatching { java.net.URI(b.src).host }.getOrNull().orEmpty() }
    Column {
        when (val s = state) {
            is ImageBitmap -> FittedImage(s, b.alt.ifBlank { host }) { env.showImage(s) }
            AttLoader.LOADING -> Placeholder("正在加载图片…", listOf(b.alt, host).filter { it.isNotBlank() }.joinToString(" · "), null)
            else -> Placeholder(
                if (s == null) "点按加载图片" else "加载失败，点按重试",
                listOf(b.alt, host, s as? String).filter { !it.isNullOrBlank() }.joinToString(" · "),
            ) {
                env.external[b.src] = AttLoader.LOADING
                scope.launch {
                    env.external[b.src] = try { withContext(Dispatchers.IO) { ExternalImages.load(b.src) } } catch (e: Exception) { e.message ?: "加载失败" }
                }
            }
        }
        if (state is ImageBitmap) Caption(b.alt)
    }
}

private object ExternalImages {
    private const val MAX_BYTES = 20L * 1024 * 1024
    private const val MAX_REDIRECTS = 5

    /**
     * 跳转由 noDowngrade 拦截器自己跟随：http → https、同协议都放行，https → http 拒绝（不让加密连接降级成明文）。
     * 不带 Cookie 和任何鉴权头。
     */
    private val noDowngrade = Interceptor { chain ->
        var req = chain.request()
        var resp = chain.proceed(req)
        var hops = 0
        while (resp.isRedirect) {
            val next = resp.header("Location")?.let { req.url.resolve(it) } ?: break
            if (req.url.isHttps && !next.isHttps) { resp.close(); throw IOException("图片地址从 https 跳到了 http，已拦截") }
            if (++hops > MAX_REDIRECTS) { resp.close(); throw IOException("跳转次数太多") }
            resp.close()
            req = req.newBuilder().url(next).build()
            resp = chain.proceed(req)
        }
        resp
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS)
        .followRedirects(false).followSslRedirects(false)     // 交给 noDowngrade 处理
        .addInterceptor(noDowngrade)
        .build()

    fun load(url: String): ImageBitmap {
        client.newCall(Request.Builder().url(url).header("User-Agent", "Huijian").build()).execute().use { r ->
            if (!r.isSuccessful) throw IOException("HTTP ${r.code}")
            val body = r.body ?: throw IOException("空响应")
            if (body.contentLength() > MAX_BYTES) throw IOException("图片太大")
            val out = ByteArrayOutputStream()
            body.byteStream().use { inp ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val n = inp.read(buf); if (n < 0) break
                    out.write(buf, 0, n)
                    if (out.size() > MAX_BYTES) throw IOException("图片太大")
                }
            }
            val bytes = out.toByteArray()
            val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, o)
            if (o.outWidth <= 0) throw IOException("不是图片")
            var s = 1
            while (o.outWidth / s > 2048 || o.outHeight / s > 2048) s *= 2
            return (BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = s })
                ?: throw IOException("不是图片")).asImageBitmap()
        }
    }
}

/** 非图片附件卡片：点开查看（没下载先下载，同附件区） */
@Composable
private fun FileCard(b: Block.File, env: MdEnv) {
    val ctx = LocalContext.current
    val a = env.attachment(b.att)
    val name = a?.name ?: b.name
    val sub = buildList {
        add(sizeText(a?.size ?: b.size))
        if (b.alt.isNotBlank() && b.alt != name) add(b.alt)
        a?.let { env.atts.status[it.id]?.takeIf { s -> s != AttLoader.DONE }?.let(::add) }
    }.joinToString(" · ")
    DisableSelection {
        Surface(
            Modifier.fillMaxWidth().then(if (a != null) Modifier.clickable { env.open(ctx, a) } else Modifier),
            shape = RoundedCornerShape(10.dp), color = MaterialTheme.colorScheme.surface, tonalElevation = 1.dp,
            border = androidx.compose.foundation.BorderStroke(1.dp, lineColor()),
        ) {
            Row(Modifier.padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(fileIcon(a?.mime ?: b.mime, name), fontSize = 22.sp)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(name, fontWeight = FontWeight.Medium, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(sub, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                if (a != null) Text(if (env.atts.have(a)) "打开" else "下载", color = MaterialTheme.colorScheme.primary, fontSize = 14.sp)
            }
        }
    }
}

private fun fileIcon(mime: String, name: String): String {
    val ext = name.substringAfterLast('.', "").lowercase()
    return when {
        mime == "application/pdf" || ext == "pdf" -> "📕"
        mime.startsWith("text/") || ext in setOf("log", "txt", "md", "csv", "json") -> "📄"
        ext in setOf("zip", "gz", "tar", "7z", "rar") -> "🗜"
        mime.startsWith("audio/") -> "🎵"
        mime.startsWith("video/") -> "🎬"
        else -> "📎"
    }
}

@Composable
private fun ProgressView(b: Block.Progress) {
    val color = if (b.done) calloutColor("success", isDark()) else MaterialTheme.colorScheme.primary
    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Text(b.display, fontSize = 14.sp, lineHeight = 20.sp)
        LinearProgressIndicator(
            progress = { b.value.toFloat() },
            Modifier.fillMaxWidth().height(6.dp),
            color = color, trackColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.1f),
            strokeCap = StrokeCap.Round, gapSize = 0.dp, drawStopIndicator = {},
        )
    }
}

/** 嵌在其他块里的脚注区（服务端只把脚注放在正文末尾，这里只是兜底；顶层脚注由 docItems 拆成单独的列表项） */
@Composable
private fun FootnotesView(b: Block.Footnotes, env: MdEnv) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        HorizontalDivider(Modifier.padding(top = 6.dp, bottom = 4.dp).width(80.dp), color = lineColor())
        for (it in b.items) FootnoteRow(it, env)
    }
}

@Composable
private fun FootnoteRow(n: MdDoc.Footnote, env: MdEnv) {
    ProvideTextStyle(TextStyle(fontSize = 13.sp, lineHeight = 19.sp)) {
        CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onSurfaceVariant) {
            Row {
                Text("[${n.n}]", Modifier.widthIn(min = 28.dp).padding(end = 4.dp), style = LocalTextStyle.current)
                Column(Modifier.weight(1f)) { Blocks(n.blocks, env, 4.dp) }
            }
        }
    }
}

// ---------------- 大图查看 ----------------

/** 全屏看图：双指缩放、拖动，双击放大 / 还原，单击关闭 */
@Composable
fun ImageViewer(bmp: ImageBitmap, onClose: () -> Unit) {
    Dialog(onClose, DialogProperties(usePlatformDefaultWidth = false)) {
        var scale by remember { mutableFloatStateOf(1f) }
        var offset by remember { mutableStateOf(Offset.Zero) }
        Box(
            Modifier.fillMaxSize().background(Color.Black)
                .pointerInput(Unit) {
                    detectTransformGestures { _, pan, zoom, _ ->
                        scale = (scale * zoom).coerceIn(1f, 6f)
                        offset = if (scale == 1f) Offset.Zero else offset + pan
                    }
                }
                .pointerInput(Unit) {
                    detectTapGestures(
                        onTap = { onClose() },
                        onDoubleTap = { scale = if (scale > 1f) 1f else 2.5f; offset = Offset.Zero },
                    )
                },
        ) {
            Image(
                bmp, null,
                Modifier.fillMaxSize().graphicsLayer(scaleX = scale, scaleY = scale, translationX = offset.x, translationY = offset.y),
                contentScale = ContentScale.Fit,
            )
            IconButton(onClose, Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(8.dp)) {
                Icon(Icons.Default.Close, "关闭", tint = Color.White)
            }
        }
    }
}
