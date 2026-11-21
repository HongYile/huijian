package io.github.hongyile.huijian.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.hongyile.huijian.AgentConnectCode
import io.github.hongyile.huijian.AgentHub
import io.github.hongyile.huijian.AgentKeyInfo
import io.github.hongyile.huijian.AgentNewKey
import io.github.hongyile.huijian.AgentPhase
import io.github.hongyile.huijian.AgentSession
import io.github.hongyile.huijian.AgentText
import io.github.hongyile.huijian.E2EHub
import io.github.hongyile.huijian.E2EStatus
import io.github.hongyile.huijian.Hub
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * Pushkey 页里的 agent 部分（docs/agent-mcp.md §8）：Agent key 和 pushkey 一样是交给程序的钥匙，放在一起。和 Mac 的 AgentSettings.swift 一致。
 * AgentRequestsPart：页面最上方的「请求登录的 agent」（有请求时才显示，点 agent 登录通知打开 Pushkey 页时第一眼看到）；
 * AgentMainPart：页面底部的连接 agent（连接码，服务端支持 agent.connect 时）、Agent key（新建 / 只显示一次 / 复制 / 吊销）、
 * 已登录的 agent（在线状态、结束）、用法
 */
@Composable
fun AgentRequestsPart(say: (String) -> Unit) {
    val unsupported by AgentHub.unsupported.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { runCatching { AgentHub.reload() } }
    if (!unsupported) Requests(say)
}

@Composable
fun AgentMainPart(say: (String) -> Unit) {
    val unsupported by AgentHub.unsupported.collectAsStateWithLifecycle()
    val connect by AgentHub.connectSupported.collectAsStateWithLifecycle()
    var loadError by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        val e1 = runCatching { AgentHub.reload() }.exceptionOrNull()
        val e2 = if (AgentHub.unsupported.value) null else runCatching { AgentHub.loadKeys() }.exceptionOrNull()
        loadError = (e1 ?: e2)?.let(::describe)
        // 读不到 /v1/info 时不显示连接码卡片（沿用上次的结果），不影响其他部分
        if (!AgentHub.unsupported.value) runCatching { AgentHub.loadFeatures() }
    }
    if (unsupported) {
        SectionCard("Agent") { Text(AgentText.UNSUPPORTED, color = WARNING, fontSize = 14.sp) }
        return
    }
    loadError?.let { SectionCard(null) { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 14.sp) } }
    if (connect) ConnectCard()
    KeyCard(say)
    SessionsCard(say)
    UsageCard(connect)
}

// ---------- 连接 agent（连接码） ----------

private val hm = DateTimeFormatter.ofPattern("HH:mm")

/**
 * 生成连接码 → 在 agent 所在的电脑上运行 huijian agent setup，一步完成登录和配置（和 Mac / iPhone 的 connectSection 一致）。
 * 连接码只放内存（remember，不进 saved state），离开页面就没了；有效期按本机生成时刻 + expires_in 算，到期自动收起
 */
@Composable
private fun ConnectCard() {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf<AgentConnectCode?>(null) }
    var until by remember { mutableStateOf(0L) }       // 到期时刻（本机时钟，毫秒）
    var busy by remember { mutableStateOf(false) }
    var msg by remember { mutableStateOf<String?>(null) }
    var msgError by remember { mutableStateOf(false) }
    val c = code
    LaunchedEffect(c, until) {
        if (c == null) return@LaunchedEffect
        delay((until - System.currentTimeMillis()).coerceAtLeast(0))
        code = null; msg = null
    }
    val live = c != null && System.currentTimeMillis() < until
    val footer = if (live) null else "在 agent 所在的电脑上用连接码一步接入：自动登录、自动配置那台电脑上的 agent。"
    SectionCard("连接 agent", footer) {
        if (c != null && live) {
            val cmd = AgentText.setupCommand(Hub.store.server, c.code)
            SelectionContainer {
                Text(c.code, fontFamily = FontFamily.Monospace, fontSize = 30.sp, fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.primary, modifier = Modifier.testTag("agentConnectCode"))
            }
            Text(hm.format(Instant.ofEpochMilli(until).atZone(ZoneId.systemDefault())) + " 前有效，只能用一次", fontSize = 13.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Surface(shape = RoundedCornerShape(8.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
                SelectionContainer {
                    Text(cmd, Modifier.fillMaxWidth().padding(10.dp), fontFamily = FontFamily.Monospace, fontSize = 12.sp, lineHeight = 17.sp)
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton({
                    copyText(ctx, "连接命令", cmd)
                    msg = "已复制命令"; msgError = false
                }, modifier = Modifier.testTag("agentCopySetup")) { Text("复制命令") }
                OutlinedButton({ openLink(ctx, AgentText.CLI_DOWNLOAD) }) { Text("下载命令行") }
                Button({ code = null; msg = null }) { Text("完成") }
            }
            msg?.let { Text(it, fontSize = 13.sp, color = if (msgError) MaterialTheme.colorScheme.error else SUCCESS) }
            Text(AgentText.CONNECT_STEPS, fontSize = 13.sp, lineHeight = 19.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("用连接码接入一台电脑上的 agent", Modifier.weight(1f), fontSize = 14.sp)
                Button({
                    busy = true; msg = null
                    scope.launch {
                        try {
                            val n = AgentHub.connectCode()
                            until = System.currentTimeMillis() + n.expiresIn * 1000
                            code = n
                        } catch (e: Exception) {
                            msg = describe(e); msgError = true
                        } finally { busy = false }
                    }
                }, enabled = !busy, modifier = Modifier.testTag("agentConnectButton")) { Text(if (busy) "生成中…" else "生成连接码") }
            }
            msg?.let { Text(it, fontSize = 13.sp, color = if (msgError) MaterialTheme.colorScheme.error else SUCCESS) }
        }
    }
}

/** 用浏览器打开链接；没有能打开的应用时提示 */
private fun openLink(ctx: android.content.Context, url: String) {
    try {
        ctx.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))
            .addCategory(android.content.Intent.CATEGORY_BROWSABLE).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (_: Exception) {
        android.widget.Toast.makeText(ctx, "没有能打开这个链接的应用", android.widget.Toast.LENGTH_SHORT).show()
    }
}

// ---------- 登录请求 ----------

/** 请求登录的 agent：批准 → 等 agent 揭晓 → 核对码 → 一致才写会话证明 */
@Composable
private fun Requests(say: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    val sessions by AgentHub.sessions.collectAsStateWithLifecycle()
    val phases by AgentHub.phases.collectAsStateWithLifecycle()
    val status by E2EHub.status.collectAsStateWithLifecycle()
    val unlocked = status == E2EStatus.UNLOCKED
    val reqs = sessions.filter { it.pending }
    // 已经不在等待列表里的（批准完、被拒绝、失败、过期）：显示结果，点「关闭」才去掉
    val finished = phases.keys.filter { id -> reqs.none { it.id == id } }.sorted()
    // 等 agent 揭晓期间每 3 秒查一次；收到 kind "agent" 变更（刷新完 revision 加一）时立即再查
    val waiting = phases.any { it.value == AgentPhase.Challenged }
    LaunchedEffect(waiting) {
        while (waiting) {
            val t = AgentHub.revision.value
            withTimeoutOrNull(3000) { AgentHub.revision.first { it > t } }
            runCatching { AgentHub.reload() }
        }
    }
    var busy by remember { mutableStateOf(false) }
    fun run(block: suspend () -> Unit) {
        busy = true
        scope.launch {
            try { block() } catch (e: Exception) { say(describe(e)) } finally { busy = false }
        }
    }
    if (reqs.isEmpty() && finished.isEmpty()) return
    SectionCard("请求登录的 agent", "批准前先核对两边的 6 位核对码是否一致；不一致说明可能有人冒充，请拒绝。") {
        reqs.forEachIndexed { i, s ->
            if (i > 0) HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(">_", fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Column(Modifier.weight(1f)) {
                        Text(s.name.ifBlank { "agent" }, fontWeight = FontWeight.Medium)
                        Text("请求于 " + (rfcText(s.createdAt) ?: "—"), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                when (val ph = phases[s.id]) {
                    null -> {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button({ run { AgentHub.beginApproval(s) } }, enabled = !busy && unlocked, modifier = Modifier.testTag("agentApprove")) { Text("批准") }
                            OutlinedButton({ run { AgentHub.deny(s.id); say("已拒绝「${s.name}」") } }, enabled = !busy) {
                                Text("拒绝", color = MaterialTheme.colorScheme.error)
                            }
                        }
                        if (!unlocked) Text(AgentText.LOCKED_APPROVE_HINT, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    AgentPhase.Challenged -> Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                            Text("等待 agent 显示核对码…", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        OutlinedButton({ run { AgentHub.deny(s.id) } }, enabled = !busy, modifier = Modifier.testTag("agentDeny")) {
                            Text("拒绝", color = MaterialTheme.colorScheme.error)
                        }
                    }
                    is AgentPhase.Code -> {
                        SasCode(ph.code)
                        Text(AgentText.codeHint(s.name), fontSize = 14.sp)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button({ run { AgentHub.approve(s.id) } }, enabled = !busy, modifier = Modifier.testTag("agentApproveMatch")) { Text("一致，批准") }
                            OutlinedButton({ run { AgentHub.deny(s.id) } }, enabled = !busy) {
                                Text("不一致，拒绝", color = MaterialTheme.colorScheme.error)
                            }
                        }
                    }
                    is AgentPhase.Failed -> Done(ph.message, MaterialTheme.colorScheme.error) { AgentHub.forgetApproval(s.id) }
                    else -> {}
                }
            }
        }
        finished.forEachIndexed { i, id ->
            if (i > 0 || reqs.isNotEmpty()) HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
            val n = AgentHub.approvalName(id)
            val (text, color) = when (val ph = phases[id]) {
                AgentPhase.Approved -> "已批准「$n」，它现在可以给你发消息、收你的回复" to SUCCESS
                AgentPhase.Rejected -> "已拒绝「$n」" to MaterialTheme.colorScheme.onSurfaceVariant
                is AgentPhase.Failed -> "「$n」：${ph.message}" to MaterialTheme.colorScheme.error
                else -> "「$n」的请求已结束" to MaterialTheme.colorScheme.onSurfaceVariant
            }
            Done(text, color) { AgentHub.forgetApproval(id) }
        }
    }
}

// ---------- Agent key ----------

@Composable
private fun KeyCard(say: (String) -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val keys by AgentHub.keys.collectAsStateWithLifecycle()
    /** 刚新建的 key：只显示这一次，只在内存里（不进 saved state），离开页面就没了 */
    var newKey by remember { mutableStateOf<AgentNewKey?>(null) }
    var busy by remember { mutableStateOf(false) }
    var confirmRevoke by remember { mutableStateOf<AgentKeyInfo?>(null) }
    var confirmRegen by remember { mutableStateOf<AgentKeyInfo?>(null) }
    // 显示 key 期间窗口加 FLAG_SECURE：不能截图，最近任务的缩略图里也看不到（和恢复码、配对码一样）
    val showing = newKey != null
    DisposableEffect(showing) {
        val w = ctx.findActivity()?.window
        if (showing) w?.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        onDispose { if (showing) w?.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE) }
    }
    SectionCard("Agent key", "agent 用它发起登录，每次登录都要在已解锁的设备上核对批准。key 只显示一次，请放进 agent 所在机器的环境变量 HUIJIAN_AGENT_KEY；没保存好就点「重新生成」。") {
        val k = newKey
        val list = keys
        when {
            k != null -> {
                SelectionContainer {
                    Text(k.key, fontFamily = FontFamily.Monospace, fontSize = 14.sp, color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.testTag("agentNewKey"))
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton({ copyText(ctx, "Agent key", k.key, sensitive = true) }) { Text("复制") }
                    Button({ newKey = null }) { Text("我已保存") }
                }
            }
            list == null -> Text("正在读取…", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            list.isEmpty() -> Row(verticalAlignment = Alignment.CenterVertically) {
                Text("还没有 Agent key", Modifier.weight(1f))
                Button({
                    busy = true
                    scope.launch {
                        try { newKey = AgentHub.createKey() } catch (e: Exception) { say(describe(e)) } finally { busy = false }
                    }
                }, enabled = !busy, modifier = Modifier.testTag("agentNewKeyButton")) { Text(if (busy) "生成中…" else "新建") }
            }
            else -> list.forEachIndexed { i, key ->
                if (i > 0) HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(key.label, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Medium)
                        Text(rfcText(key.lastUsed)?.let { "上次使用 $it" } ?: "还没用过", fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    OutlinedButton({ confirmRegen = key }, enabled = !busy, modifier = Modifier.testTag("agentRegenKeyButton")) {
                        Text(if (busy) "生成中…" else "重新生成")
                    }
                    Spacer(Modifier.width(8.dp))
                    OutlinedButton({ confirmRevoke = key }, enabled = !busy) { Text("吊销", color = MaterialTheme.colorScheme.error) }
                }
            }
        }
    }
    confirmRevoke?.let { key ->
        ConfirmDialog("吊销这把 Agent key？", "用它登录的 agent 会话全部结束，之后要用新的 key 重新登录。", "吊销", { confirmRevoke = null }) {
            busy = true
            scope.launch {
                try { AgentHub.revokeKey(key.id); say("已吊销") } catch (e: Exception) { say(describe(e)) } finally { busy = false }
            }
        }
    }
    // key 只显示一次：没保存好时用「重新生成」换一把（吊销旧的 + 新建，新 key 显示出来可复制）
    confirmRegen?.let { key ->
        ConfirmDialog("重新生成 Agent key？", "旧 key 立即作废，用它登录的 agent 会话全部结束，要用新 key 重新登录。新 key 只显示一次，记得复制。",
            "重新生成", { confirmRegen = null }) {
            busy = true
            scope.launch {
                try { AgentHub.revokeKey(key.id); newKey = AgentHub.createKey() } catch (e: Exception) { say(describe(e)) } finally { busy = false }
            }
        }
    }
}

// ---------- 会话 ----------

/** 名称取自会话证明；核实不了的标出来 */
@Composable
private fun sessionName(s: AgentSession): String {
    val verified by AgentHub.verified.collectAsStateWithLifecycle()
    return verified[s.id]?.name ?: "${s.name}（来源无法核实）"
}

@Composable
private fun SessionsCard(say: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    val sessions by AgentHub.sessions.collectAsStateWithLifecycle()
    val list = sessions.filter { it.active }
    var busy by remember { mutableStateOf<String?>(null) }
    var confirmEnd by remember { mutableStateOf<AgentSession?>(null) }
    SectionCard("已登录的 agent", if (list.isEmpty()) "还没有已登录的 agent。" else "最近 90 秒内取过回复的显示为在线；同时在线最多 3 个。") {
        if (list.isEmpty()) Text("—", color = MaterialTheme.colorScheme.onSurfaceVariant)
        list.forEachIndexed { i, s ->
            if (i > 0) HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(sessionName(s), fontWeight = FontWeight.Medium)
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Box(Modifier.size(7.dp).background(if (s.online) SUCCESS else MaterialTheme.colorScheme.outline, CircleShape))
                        Text(if (s.online) "在线" else rfcText(s.lastSeen)?.let { "上次在线 $it" } ?: "还没上线",
                            fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                OutlinedButton({ confirmEnd = s }, enabled = busy == null) {
                    Text(if (busy == s.id) "处理中…" else "结束", color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
    confirmEnd?.let { s ->
        val n = sessionName(s)
        ConfirmDialog("结束这个 agent 会话？", "「$n」不能再发消息、收回复；还没取走的回复一起删除。", "结束", { confirmEnd = null }) {
            busy = s.id
            scope.launch {
                try { AgentHub.endSession(s.id); say("已结束「$n」") } catch (e: Exception) { say(describe(e)) } finally { busy = null }
            }
        }
    }
}

/** connect：服务端支持连接码时推荐 huijian agent setup，手动方式放后面 */
@Composable
private fun UsageCard(connect: Boolean) {
    val server = Hub.store.server
    SectionCard("用法", "MCP 工具：notify（发消息）、ask（提问并等回复）、check_replies（取之后才到的回复）。" +
        "huijian agent status 查看接入情况，huijian agent setup -remove 撤销。") {
        CodeBox(
            if (connect) """
            # 推荐：上面「生成连接码」后一步接入
            huijian agent setup -u $server 连接码
            # 手动：用 Agent key 登录，再自己配置 MCP
            huijian agent login -u $server -k AK_… -name "家里 Claude Code"
            claude mcp add huijian -- huijian mcp
            """.trimIndent() else """
            export HUIJIAN_URL=$server
            export HUIJIAN_AGENT_KEY=AK_…
            huijian agent login -name "家里 Claude Code"
            claude mcp add huijian -- huijian mcp
            """.trimIndent()
        )
    }
}
