@file:OptIn(ExperimentalMaterial3Api::class)

package io.github.hongyile.huijian.ui

import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.selection.DisableSelection
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.hongyile.huijian.AgentHub
import io.github.hongyile.huijian.AgentReplyView
import io.github.hongyile.huijian.AgentText
import io.github.hongyile.huijian.E2EStatus
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.platform.testTag
import io.github.hongyile.huijian.Attachment
import io.github.hongyile.huijian.E2EHub
import io.github.hongyile.huijian.E2EMessages
import io.github.hongyile.huijian.E2EText
import io.github.hongyile.huijian.Hub
import io.github.hongyile.huijian.Markdown
import io.github.hongyile.huijian.MdDoc
import io.github.hongyile.huijian.Message
import io.github.hongyile.huijian.Notifier
import io.github.hongyile.huijian.Priority
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

@Composable
fun DetailScreen(id: Long, back: () -> Unit, openMessage: (Long) -> Unit = {}) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val messages by Hub.messages.collectAsStateWithLifecycle()
    val m = messages.firstOrNull { it.id == id }
    val e2eState by E2EHub.state.collectAsStateWithLifecycle()
    LaunchedEffect(id) { Hub.markRead(listOf(id)); Notifier.cancel(ctx, id) }
    val atts = remember(id) { AttLoader(ctx, scope) }
    var viewer by remember { mutableStateOf<ImageBitmap?>(null) }
    viewer?.let { ImageViewer(it) { viewer = null } }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(m?.let { "# " + Hub.channelName(it.topic) } ?: "消息") },
                navigationIcon = { IconButton(back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { pad ->
        if (m == null) {
            Box(Modifier.padding(pad).fillMaxSize(), contentAlignment = Alignment.Center) { Text("消息不存在或已被删除") }
            return@Scaffold
        }
        // 服务端 0.6.0 起带解析好的 doc；没有、版本不认识或没有能显示的块时退回本地的简单解析
        val doc = remember(m.id, m.doc) { if (m.type == "text") null else MdDoc.parse(m.doc) }
        val items = remember(doc) { doc?.let(::docItems).orEmpty() }
        val listState = rememberLazyListState()
        // 按 id 做键：同一条消息的 archive / silent 等元数据同步更新时不重建（已加载的外部图片不会回到占位）
        val env = remember(m.id, atts, items) {
            MdEnv(m, atts, openMessage, { viewer = it }) { n ->
                val k = items.footnoteIndex(n)
                if (k >= 0) scope.launch { listState.animateScrollToItem(HEADER_ITEMS + k) }
            }
        }
        // 正文里已经显示的图片，附件区不再重复大图预览（仍然列出，可以打开 / 分享）
        val inline = remember(doc) { doc?.let(::inlineImageIds).orEmpty() }
        // 整页是一个 LazyColumn：正文每个顶层块是一项，长文档只组合屏幕上看得到的部分
        SelectionContainer {
            LazyColumn(
                Modifier.padding(pad).fillMaxSize().imePadding().linkGuard(env), state = listState,
                contentPadding = PaddingValues(start = 18.dp, end = 18.dp, top = 8.dp, bottom = 24.dp),
            ) {
                // 以下 HEADER_ITEMS 个固定项（脚注跳转按它算位置）
                item {
                    DisableSelection {
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Chip(Priority.label(m.priority), priorityColor(m.priority))
                            if (m.thread.isNotBlank()) Chip(m.thread, MaterialTheme.colorScheme.onSurfaceVariant)
                            if (m.silent) Chip("静默", MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                item { Text(m.title, Modifier.padding(top = 10.dp), fontSize = 22.sp, fontWeight = FontWeight.SemiBold) }
                item {
                    DisableSelection {
                        // 元信息行：发送端加密「🔒 端到端加密」；服务器代加密的（sealed: "server"）T64「明文发送：…」（§11.5）；
                        // 账号开了加密、这条是明文（本机保留的旧消息）时 T63（e2ee-client.md §6.3）
                        val mark = E2EMessages.detailMark(m, e2eState?.enabled == true)
                        Text(
                            // agent 消息：名称取自会话证明（服务器给的 source 不用，docs/agent-mcp.md §8）
                            listOf(if (m.isAgent) ">_ " + (m.agentName ?: "agent") else m.source, fullTime(m.createdAt), "#${m.id}", mark)
                                .filter { it.isNotBlank() }.joinToString(" · "),
                            Modifier.padding(top = 10.dp), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                item { HorizontalDivider(Modifier.padding(top = 10.dp), color = MaterialTheme.colorScheme.surfaceVariant) }
                if (m.desp.isNotBlank()) when {
                    m.type == "text" -> item { Text(m.desp, Modifier.padding(top = 10.dp), fontSize = 15.sp) }
                    doc != null -> docItems(items, env)
                    else -> item { Box(Modifier.padding(top = 10.dp)) { MarkdownView(m.desp) } }
                }
                // agent 消息：已发出的回复和送达状态、快捷回复、回复框（§5.1、§8）
                // 按消息 id 重建：换消息时草稿、回复列表、错误提示都重置
                if (m.isAgent) item(key = "agentReply:${m.id}") { DisableSelection { androidx.compose.runtime.key(m.id) { AgentReplyPanel(m) } } }
                if (m.sealed && m.attachments.isNotEmpty()) item {
                    Text("附件 ${m.attachments.size} 个（解锁后查看）", Modifier.padding(top = 16.dp), fontSize = 13.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (!m.sealed && m.attachments.isNotEmpty()) item {
                    DisableSelection {
                        Column(Modifier.padding(top = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Attachments(m, atts, inline) { viewer = it }
                        }
                    }
                }
            }
        }
    }
}

/** 详情页 LazyColumn 里正文前面的固定项数：标签、标题、时间、分隔线 */
private const val HEADER_ITEMS = 4

@Composable
private fun Chip(text: String, color: Color) {
    Surface(shape = RoundedCornerShape(6.dp), color = color.copy(alpha = 0.12f)) {
        Text(text, Modifier.padding(horizontal = 7.dp, vertical = 2.dp), fontSize = 12.sp, color = color, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun MarkdownView(src: String) {
    val blocks = remember(src) { Markdown.parse(src) }
    val link = MaterialTheme.colorScheme.primary
    val codeBg = MaterialTheme.colorScheme.surfaceVariant
    SelectionContainer {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            for (b in blocks) when (b) {
                is Markdown.Block.Heading -> Text(Markdown.inline(b.text, link, codeBg),
                    fontSize = (22 - b.level * 2).coerceAtLeast(15).sp, fontWeight = FontWeight.SemiBold)
                is Markdown.Block.Para -> Text(Markdown.inline(b.text, link, codeBg), fontSize = 15.sp, lineHeight = 22.sp)
                is Markdown.Block.Bullet -> Row(Modifier.padding(start = (b.indent * 14).dp)) {
                    Text(b.marker, Modifier.width(22.dp), fontSize = 15.sp)
                    Text(Markdown.inline(b.text, link, codeBg), fontSize = 15.sp, lineHeight = 22.sp)
                }
                is Markdown.Block.Quote -> Row {
                    Box(Modifier.width(3.dp).heightIn(min = 20.dp).background(MaterialTheme.colorScheme.surfaceVariant))
                    Text(Markdown.inline(b.text, link, codeBg), Modifier.padding(start = 10.dp), fontSize = 15.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                is Markdown.Block.Code -> Surface(shape = RoundedCornerShape(8.dp), color = codeBg) {
                    Column(Modifier.padding(10.dp)) {
                        if (b.lang.isNotBlank()) Text(b.lang, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(b.code, Modifier.horizontalScroll(rememberScrollState()), fontFamily = FontFamily.Monospace, fontSize = 13.sp)
                    }
                }
                Markdown.Block.Rule -> HorizontalDivider()
            }
        }
    }
}

/** 附件：点「下载」保存到缓存目录并校验 sha256，图片直接预览（点开看大图），其他文件交给系统里能打开它的 App */
@Composable
private fun Attachments(m: Message, atts: AttLoader, inline: Set<String>, showImage: (ImageBitmap) -> Unit) {
    val ctx = LocalContext.current
    Text("附件 ${m.attachments.size} 个", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    for (a in m.attachments) {
        val have = atts.have(a)
        Surface(shape = RoundedCornerShape(10.dp), color = MaterialTheme.colorScheme.surface, tonalElevation = 1.dp) {
            Column(Modifier.fillMaxWidth().padding(10.dp)) {
                if (have && a.isImage && a.id !in inline) {
                    val bmp by produceState<ImageBitmap?>(null, a.id, have) {
                        value = withContext(Dispatchers.IO) { decodeSampled(atts.file(a))?.asImageBitmap() }
                    }
                    bmp?.let {
                        Image(it, a.name, Modifier.fillMaxWidth().heightIn(max = 320.dp).clip(RoundedCornerShape(8.dp))
                            .clickable { showImage(it) }, contentScale = ContentScale.Fit)
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(a.name, fontWeight = FontWeight.Medium, maxLines = 1)
                        Text(sizeText(a.size) + (atts.status[a.id]?.takeIf { it != AttLoader.DONE }?.let { " · $it" } ?: ""),
                            fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (have) {
                        OutlinedButton({ openFile(ctx, atts.file(a), a.mime) }) { Text("打开") }
                    } else {
                        OutlinedButton({ atts.download(a) }, enabled = !atts.loading(a)) { Text("下载") }
                    }
                }
            }
        }
    }
}

/** doc 里内嵌显示的附件图片 id（含引用、提示框、列表里的） */
private fun inlineImageIds(blocks: List<MdDoc.Block>): Set<String> {
    val out = HashSet<String>()
    fun walk(bs: List<MdDoc.Block>) {
        for (b in bs) when (b) {
            is MdDoc.Block.Image -> if (b.att.isNotEmpty()) out += b.att
            is MdDoc.Block.Quote -> walk(b.blocks)
            is MdDoc.Block.Callout -> walk(b.blocks)
            is MdDoc.Block.ListBlock -> b.items.forEach { walk(it.blocks) }
            is MdDoc.Block.Footnotes -> b.items.forEach { walk(it.blocks) }
            else -> {}
        }
    }
    walk(blocks)
    return out
}

internal fun attFile(ctx: Context, a: Attachment): File {
    val safe = a.name.replace(Regex("""[/\\:\u0000-\u001f]"""), "_").trim()
        .takeUnless { it.isEmpty() || it.all { c -> c == '.' } } ?: "file"
    return File(File(File(ctx.cacheDir, "att"), a.id.replace(Regex("[^A-Za-z0-9_-]"), "_")), safe)
}

internal fun decodeSampled(f: File) = runCatching {
    val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(f.path, o)
    var s = 1
    while (o.outWidth / s > 2048 || o.outHeight / s > 2048) s *= 2
    BitmapFactory.decodeFile(f.path, BitmapFactory.Options().apply { inSampleSize = s })
}.getOrNull()

internal fun openFile(ctx: Context, f: File, mime: String) {
    val uri = FileProvider.getUriForFile(ctx, ctx.packageName + ".files", f)
    val i = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    try { ctx.startActivity(Intent.createChooser(i, "打开 ${f.name}").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } catch (_: Exception) {}
}

/** agent 消息详情下方：已发出的回复及状态、快捷回复按钮、回复框；不能回复时显示原因（和 Mac 的 AgentReplyPanel 一致） */
@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun AgentReplyPanel(m: Message) {
    val scope = rememberCoroutineScope()
    val revision by AgentHub.revision.collectAsStateWithLifecycle()
    val status by E2EHub.status.collectAsStateWithLifecycle()
    val verified by AgentHub.verified.collectAsStateWithLifecycle()
    val sessions by AgentHub.sessions.collectAsStateWithLifecycle()
    val loaded by AgentHub.loaded.collectAsStateWithLifecycle()
    val block = remember(m, status, verified, sessions, loaded) { AgentHub.replyBlock(m, status == E2EStatus.UNLOCKED) }
    var replies by remember(m.id) { mutableStateOf<List<AgentReplyView>>(emptyList()) }
    var text by rememberSaveable(m.id) { mutableStateOf("") }
    var choice by rememberSaveable(m.id) { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    // 收到 kind "agent" 变更（回复、回执、会话变化）时 revision 加一：重新拉这条消息的回复状态
    LaunchedEffect(m.id, m.e2eStatus, revision, verified) {
        if (m.e2eStatus == E2EMessages.OK) runCatching { AgentHub.replies(m) }.getOrNull()?.let { if (it != replies) replies = it }
    }
    fun send() {
        val sentText = text
        val sentChoice = choice
        val t = AgentText.composeReply(sentChoice, sentText)
        if (t.isEmpty()) return
        busy = true; error = null
        scope.launch {
            try {
                AgentHub.reply(m, t)
                // 发送期间又改过的不清
                if (text == sentText) text = ""
                if (choice == sentChoice) choice = null
                runCatching { AgentHub.replies(m) }.getOrNull()?.let { replies = it }
            } catch (e: Exception) {
                error = describe(e)
            } finally { busy = false }
        }
    }
    Column(Modifier.padding(top = 22.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("回复 agent", Modifier.weight(1f), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (m.ask && replies.isEmpty()) Text(AgentText.WAITING_REPLY, fontSize = 12.sp, color = WARNING, fontWeight = FontWeight.Medium)
        }
        for (r in replies) {
            Surface(shape = RoundedCornerShape(8.dp), color = MaterialTheme.colorScheme.surfaceVariant, modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    SelectionContainer { Text(r.text, fontSize = 15.sp) }
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(r.label, fontSize = 12.sp,
                            color = if (r.state == AgentReplyView.State.RECEIVED) SUCCESS else MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(listOfNotNull(r.device.ifBlank { null }, r.sentAt?.let { fullTime(java.time.Instant.ofEpochSecond(it)) })
                            .joinToString(" · ") { "· $it" }, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        if (block == null) {
            if (replies.any { it.state == AgentReplyView.State.RECEIVED })
                Text(AgentText.TOOK_REPLY, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            // 快捷选项只是选中（再点取消），和补充文字一起点「发送」才发出
            if (m.choices.isNotEmpty()) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (c in m.choices) {
                        if (choice == c) Button({ choice = null }, enabled = !busy, modifier = Modifier.testTag("agentChoice")) { Text(c) }
                        else OutlinedButton({ choice = c }, enabled = !busy, modifier = Modifier.testTag("agentChoice")) { Text(c) }
                    }
                }
                Text(AgentText.CHOICE_HINT, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(text, { text = it }, Modifier.weight(1f).testTag("agentReplyText"), placeholder = { Text("回复…") }, maxLines = 8)
                Button({ send() }, enabled = !busy && AgentText.composeReply(choice, text).isNotEmpty(), modifier = Modifier.testTag("agentReplySend")) {
                    Text(if (busy) "发送中…" else "发送")
                }
            }
        } else {
            Text(block, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        error?.let { Text(it, fontSize = 13.sp, color = MaterialTheme.colorScheme.error) }
    }
}
