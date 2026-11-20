package io.github.hongyile.huijian.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.hongyile.huijian.E2EHub
import io.github.hongyile.huijian.E2EText
import io.github.hongyile.huijian.Hub
import io.github.hongyile.huijian.Manage
import io.github.hongyile.huijian.PushKey
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import java.time.LocalTime
import java.time.format.DateTimeFormatter

/** 编辑对话框的种类 */
private sealed interface KeyEdit {
    data object Create : KeyEdit
    data class Rename(val k: PushKey) : KeyEdit
    data class Replace(val k: PushKey) : KeyEdit
}

/**
 * 设置 → Pushkey：查看、新建（可自定义 key）、改名、换 key、吊销、删除、复制、发送示例、测试推送，
 * 以及本机对每把 key 的接收方式。和 Mac 的「设置 → Pushkey」功能一致，修改立即提交。
 */
@Composable
fun KeysScreen(back: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    var keys by remember { mutableStateOf<List<PushKey>?>(null) }
    var modes by remember { mutableStateOf<Map<Long, String>?>(null) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var edit by remember { mutableStateOf<KeyEdit?>(null) }
    var revoke by remember { mutableStateOf<PushKey?>(null) }
    var delete by remember { mutableStateOf<PushKey?>(null) }
    var example by remember { mutableStateOf<PushKey?>(null) }
    /** 刚新建的 key：弹出结果页（§11.6 优先显示加密发送密钥） */
    var created by remember { mutableStateOf<PushKey?>(null) }
    var saving by remember { mutableStateOf(false) }
    val server = Hub.store.server

    fun say(s: String) { scope.launch { snackbar.showSnackbar(s) } }
    fun replace(k: PushKey) { keys = keys?.map { if (it.id == k.id) k else it } }

    // 同一时间只保留一次刷新：变更流连着来、或手动点刷新时，先取消上一次，免得旧结果晚到覆盖新结果
    var loadJob by remember { mutableStateOf<Job?>(null) }
    fun reload() {
        loadJob?.cancel()
        loading = true
        loadJob = scope.launch {
            val me = coroutineContext[Job]
            try {
                val k = api { it.keys() }
                val m = try { api { it.subscriptions() } } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
                keys = k; modes = m; error = null
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = describe(e)
            } finally { if (loadJob == null || loadJob == me) loading = false }
        }
    }
    // 打开时加载；其他设备改了 pushkey（变更流 keys）或本机接收规则（devices）时立即重新加载
    val keysTick by Hub.keysTick.collectAsStateWithLifecycle()
    // 账号开启了加密：每把 key 下面多一行「加密发送密钥」（e2ee-client.md §7.1）
    val e2eState by E2EHub.state.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { E2EHub.refreshAsync() }
    val account by Hub.account.collectAsStateWithLifecycle()
    LaunchedEffect(keysTick, account) { reload() }

    ManageScaffold("Pushkey", back, snackbar, actions = {
        IconButton({ reload() }, enabled = !loading) { Icon(Icons.Default.Refresh, "刷新") }
        IconButton({ edit = KeyEdit.Create }, enabled = keys != null) { Icon(Icons.Default.Add, "新建") }
    }) {
        // agent 请求登录：放在最上面（点通知打开这一页时第一眼看到）
        AgentRequestsPart(::say)
        val list = keys
        SectionCard(
            Hub.store.username.takeIf { it.isNotBlank() }?.let { "账号「$it」的 Pushkey" } ?: "Pushkey",
            "pushkey 属于账号：这个账号的所有设备看到的是同一组。发送方用 pushkey 把消息发给你，建议每台机器、每个项目各用一把，泄露时只吊销那一把。" +
                if (modes != null) "「本机」决定这把 key 发来的消息在这台手机上提醒、静默（只进列表）还是不接收。" else "",
        ) {
            when {
                error != null && list == null -> Text(error!!, color = MaterialTheme.colorScheme.error)
                list == null -> Text("正在加载…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                list.isEmpty() -> Text("还没有 pushkey，点右上角 + 新建一把", color = MaterialTheme.colorScheme.onSurfaceVariant)
                else -> list.forEachIndexed { i, k ->
                    if (i > 0) HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                    KeyRow(
                        k, modes?.let { it[k.id] ?: "notify" },
                        sendKey = if (k.revoked || e2eState?.enabled != true) null else E2EHub.sendKey(k.key),
                        onCopySendKey = { copyText(ctx, "加密发送密钥", it, sensitive = true) },
                        onMode = { m ->
                            val old = modes
                            modes = modes?.plus(k.id to m)
                            scope.launch {
                                try { api { it.setSubscription(k.id, m) } } catch (e: Exception) { modes = old; say("保存失败：${describe(e)}") }
                            }
                        },
                        onCopy = { copyText(ctx, "pushkey", k.key, sensitive = true) },
                        onExample = { example = k },
                        onRename = { edit = KeyEdit.Rename(k) },
                        onReplace = { edit = KeyEdit.Replace(k) },
                        onRevoke = { revoke = k },
                        onDelete = { delete = k },
                    )
                }
            }
            if (error != null && list != null) Text(error!!, color = MaterialTheme.colorScheme.error, fontSize = 13.sp)
        }
        Button({ edit = KeyEdit.Create }, Modifier.fillMaxWidth(), enabled = list != null) {
            Icon(Icons.Default.Add, null); Text(" 新建 pushkey")
        }
        list?.firstOrNull { !it.revoked }?.let { k ->
            SectionCard("试一下：用「${k.name}」发一条", "浏览器里打开这个地址，或在终端里运行，就能收到一条消息。") {
                CodeBox(Manage.sendUrl(server, k.key))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton({ copyText(ctx, "url", Manage.sendUrl(server, k.key), sensitive = true) }) { Text("复制地址") }
                    OutlinedButton({ example = k }) { Text("更多示例与测试") }
                }
            }
        }
        // agent 双向：Agent key、已登录的 agent、用法（服务端 0.10.0 起）
        AgentMainPart(::say)
    }

    edit?.let { e ->
        KeyEditDialog(
            e, hasActive = keys.orEmpty().any { !it.revoked }, busy = saving,
            onDismiss = { edit = null },
        ) { name, key ->
            saving = true
            scope.launch {
                try {
                    when (e) {
                        KeyEdit.Create -> {
                            val k = api { it.createKey(name, key) }
                            keys = keys.orEmpty() + k
                            created = k
                        }
                        is KeyEdit.Rename -> { replace(api { it.updateKey(e.k.id, name, "") }); say("已改名") }
                        is KeyEdit.Replace -> { replace(api { it.updateKey(e.k.id, "", key) }); say("已更换，旧 key 已失效") }
                    }
                    edit = null
                } catch (ex: Exception) {
                    say(describe(ex))       // 对话框保留，可以改了再提交
                } finally { saving = false }
            }
        }
    }
    revoke?.let { k ->
        ConfirmDialog("吊销「${k.name}」？", "吊销后，使用这把 key 的脚本和程序将无法再发送消息。这个操作不能撤销。", "吊销", { revoke = null }) {
            scope.launch {
                try { replace(api { it.revokeKey(k.id) }); say("已吊销「${k.name}」") } catch (e: Exception) { say("吊销失败：${describe(e)}") }
            }
        }
    }
    delete?.let { k ->
        ConfirmDialog("删除「${k.name}」？", "删除后列表里不再显示，历史消息会保留；这个 key 以后也不能再被使用。", "删除", { delete = null }) {
            scope.launch {
                try {
                    api { it.deleteKey(k.id) }
                    keys = keys?.filter { it.id != k.id }; say("已删除「${k.name}」")
                } catch (e: Exception) {
                    if ((e as? io.github.hongyile.huijian.ApiException)?.status == 404 && !e.oldServer) {
                        keys = keys?.filter { it.id != k.id }; say("「${k.name}」已不存在（可能在别的设备上删除了）")
                    } else say("删除失败：${describe(e)}")
                }
            }
        }
    }
    example?.let { k -> ExampleDialog(k, server, { example = null }, ::say) }
    created?.let { k ->
        CreatedDialog(k, if (e2eState?.enabled == true) E2EHub.sendKey(k.key) else null,
            onCopySendKey = { copyText(ctx, "加密发送密钥", it, sensitive = true) },
            onCopy = { copyText(ctx, "pushkey", k.key, sensitive = true) }, onDismiss = { created = null })
    }
}

@Composable
private fun KeyRow(
    k: PushKey, mode: String?, sendKey: io.github.hongyile.huijian.SendKey?, onCopySendKey: (String) -> Unit, onMode: (String) -> Unit, onCopy: () -> Unit, onExample: () -> Unit,
    onRename: () -> Unit, onReplace: () -> Unit, onRevoke: () -> Unit, onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            // 名称和标签占满左边（名称太长时省略号截断），菜单按钮靠右
            Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(k.name, Modifier.weight(1f, fill = false), fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    color = if (k.revoked) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface)
                if (k.revoked) Tag("已吊销", MaterialTheme.colorScheme.error) else Tag("有效", SUCCESS)
            }
            Box {
                IconButton({ menu = true }) { Icon(Icons.Default.MoreVert, "更多操作") }
                DropdownMenu(menu, { menu = false }) {
                    if (!k.revoked) {
                        DropdownMenuItem({ Text(if (sendKey?.key != null) "复制普通 pushkey" else "复制 key") }, { menu = false; onCopy() })
                        DropdownMenuItem({ Text("发送示例与测试") }, { menu = false; onExample() })
                        DropdownMenuItem({ Text("改名") }, { menu = false; onRename() })
                        DropdownMenuItem({ Text("更换 key") }, { menu = false; onReplace() })
                        DropdownMenuItem({ Text("吊销", color = MaterialTheme.colorScheme.error) }, { menu = false; onRevoke() })
                    } else {
                        DropdownMenuItem({ Text("删除", color = MaterialTheme.colorScheme.error) }, { menu = false; onDelete() })
                    }
                }
            }
        }
        val encrypted = if (k.revoked) null else sendKey?.key
        if (encrypted == null) SelectionContainer {
            Text(k.key, fontFamily = FontFamily.Monospace, fontSize = 13.sp,
                color = if (k.revoked) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                textDecoration = if (k.revoked) TextDecoration.LineThrough else null)
        } else SendKeyBox(encrypted, onCopySendKey)
        Text(
            listOfNotNull(
                rfcText(k.lastUsed)?.let { "最近使用 $it" } ?: if (!k.revoked) "从未使用" else null,
                rfcText(k.createdAt)?.let { "创建于 $it" },
            ).joinToString(" · "),
            fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (!k.revoked) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            // 有加密发送密钥时只在它的框里复制（§11.6，卡片上只留一个「复制」）；还没有时复制普通 pushkey
            if (encrypted == null) TextButton(onCopy, contentPadding = ZeroPadding, modifier = Modifier.testTag("copyKey")) { Text("复制") }
            if (mode != null) {
                Box(Modifier.weight(1f))
                ModePicker(mode, onMode)
            }
        }
        if (encrypted != null) PlainKeyFold(k.key, onCopy)
        else if (sendKey != null && !k.revoked) {
            // 只显示本机钉住的公钥（e2ee-client.md §7 第 1 项）：没钉住显示 T73，和服务器的不同显示 T46
            Surface(shape = RoundedCornerShape(8.dp), color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)) {
                Column(Modifier.fillMaxWidth().padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("🔒 加密发送密钥", fontSize = 13.sp, fontWeight = FontWeight.Medium)
                    Text(sendKey.note.orEmpty(), fontSize = 12.sp,
                        color = if (sendKey.note == E2EText.T43 || sendKey.note == E2EText.T46) MaterialTheme.colorScheme.error
                        else MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

/** 加密发送密钥（§7 第 1 项、§11.6：放在最前面，默认复制它） */
@Composable
private fun SendKeyBox(key: String, onCopy: (String) -> Unit) {
    Surface(shape = RoundedCornerShape(8.dp), color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)) {
        Column(Modifier.fillMaxWidth().padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("🔒 加密发送密钥", Modifier.weight(1f), fontSize = 13.sp, fontWeight = FontWeight.Medium)
                TextButton({ onCopy(key) }, contentPadding = ZeroPadding, modifier = Modifier.testTag("copyKey")) { Text("复制") }
            }
            SelectionContainer { Text(key, Modifier.testTag("sendKey"), fontFamily = FontFamily.Monospace, fontSize = 12.sp) }
            Text(E2EText.T70, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** 普通 pushkey 收进「显示普通 pushkey」折叠项，配说明 T66（§11.6） */
@Composable
private fun PlainKeyFold(key: String, onCopy: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        TextButton({ open = !open }, contentPadding = ZeroPadding, modifier = Modifier.testTag("showPlainKey")) {
            Text(if (open) "隐藏普通 pushkey ▴" else "显示普通 pushkey ▾", fontSize = 13.sp)
        }
        if (open) {
            Text(E2EText.T66, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(verticalAlignment = Alignment.CenterVertically) {
                SelectionContainer(Modifier.weight(1f)) { Text(key, Modifier.testTag("plainKey"), fontFamily = FontFamily.Monospace, fontSize = 13.sp) }
                TextButton(onCopy, contentPadding = ZeroPadding) { Text("复制") }
            }
        }
    }
}

/** 新建 pushkey 的结果：优先显示加密发送密钥（§11.6），普通 key 折叠 */
@Composable
private fun CreatedDialog(k: PushKey, sendKey: io.github.hongyile.huijian.SendKey?, onCopySendKey: (String) -> Unit, onCopy: () -> Unit,
                          onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("已新建「${k.name}」") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                val encrypted = sendKey?.key
                if (encrypted != null) {
                    SendKeyBox(encrypted, onCopySendKey)
                    PlainKeyFold(k.key, onCopy)
                } else {
                    CodeBox(k.key)
                    TextButton(onCopy, contentPadding = ZeroPadding) { Text("复制 pushkey") }
                    sendKey?.note?.let { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
            }
        },
        confirmButton = { TextButton(onDismiss) { Text("完成") } },
    )
}

private val MODES = listOf("notify" to "提醒", "silent" to "静默", "off" to "不接收")

/** 本机对这把 key 的接收方式 */
@Composable
private fun ModePicker(mode: String, onMode: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        TextButton({ open = true }) { Text("本机：" + (MODES.firstOrNull { it.first == mode }?.second ?: "提醒") + " ▾") }
        DropdownMenu(open, { open = false }) {
            for ((m, label) in MODES) DropdownMenuItem(
                { Text(label + when (m) { "silent" -> "（只进列表）"; "off" -> "（本机看不到）"; else -> "" }) },
                { open = false; if (m != mode) onMode(m) },
            )
        }
    }
}

@Composable
private fun KeyEditDialog(e: KeyEdit, hasActive: Boolean, busy: Boolean, onDismiss: () -> Unit, onSave: (name: String, key: String) -> Unit) {
    var name by remember { mutableStateOf(when (e) { KeyEdit.Create -> if (hasActive) "新的 pushkey" else "default"; is KeyEdit.Rename -> e.k.name; is KeyEdit.Replace -> e.k.name }) }
    var key by remember { mutableStateOf(if (e is KeyEdit.Replace) Manage.randomKey() else "") }
    val nameErr = if (e is KeyEdit.Replace) null else Manage.nameProblem(name)
    val keyErr = if (e is KeyEdit.Rename) null else Manage.keyProblem(key, isNew = e is KeyEdit.Create)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(when (e) { KeyEdit.Create -> "新建 pushkey"; is KeyEdit.Rename -> "改名"; is KeyEdit.Replace -> "更换「${e.k.name}」的 key" }) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (e !is KeyEdit.Replace) OutlinedTextField(
                    name, { name = it.take(40) }, Modifier.fillMaxWidth(), label = { Text("名称") }, singleLine = true,
                    isError = nameErr != null, supportingText = nameErr?.let { { Text(it) } },
                )
                if (e !is KeyEdit.Rename) {
                    OutlinedTextField(
                        key, { key = it.trim() }, Modifier.fillMaxWidth(), singleLine = true,
                        label = { Text(if (e is KeyEdit.Create) "自定义 key（可选）" else "新 key") },
                        placeholder = { if (e is KeyEdit.Create) Text("留空自动生成") },
                        textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                        isError = keyErr != null,
                        supportingText = { Text(keyErr ?: "16–64 位字母、数字、_ 或 -") },
                    )
                    TextButton({ key = Manage.randomKey() }, contentPadding = ZeroPadding) { Text("随机生成") }
                }
                if (e is KeyEdit.Replace) Text("更换后旧 key 立即失效，正在使用它的脚本需要改成新 key。", color = WARNING, fontSize = 13.sp)
            }
        },
        confirmButton = {
            TextButton({ onSave(name.trim(), key.trim()) }, enabled = nameErr == null && keyErr == null && !busy) {
                Text(when (e) { KeyEdit.Create -> "新建"; is KeyEdit.Rename -> "保存"; is KeyEdit.Replace -> "更换" },
                    color = if (e is KeyEdit.Replace) MaterialTheme.colorScheme.error else androidx.compose.ui.graphics.Color.Unspecified)
            }
        },
        dismissButton = { TextButton(onDismiss) { Text("取消") } },
    )
}

/** 发送示例（URL、curl）+ 用这把 key 给自己发一条测试 */
@Composable
private fun ExampleDialog(k: PushKey, server: String, onDismiss: () -> Unit, say: (String) -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var sending by remember { mutableStateOf(false) }
    val url = Manage.sendUrl(server, k.key)
    val curl = Manage.curlExample(server, k.key)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("用「${k.name}」发送") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("浏览器里打开：", fontSize = 13.sp)
                CodeBox(url)
                TextButton({ copyText(ctx, "url", url, sensitive = true) }, contentPadding = ZeroPadding) { Text("复制地址") }
                Text("命令行：", fontSize = 13.sp)
                CodeBox(curl)
                TextButton({ copyText(ctx, "curl", curl, sensitive = true) }, contentPadding = ZeroPadding) { Text("复制 curl") }
            }
        },
        confirmButton = {
            TextButton({
                sending = true
                scope.launch {
                    try {
                        val now = LocalTime.now().format(DateTimeFormatter.ofPattern("HH:mm:ss"))
                        api { it.push(k.key, "测试推送 $now", "用 pushkey「${k.name}」从「${Hub.store.deviceName}」发送于 **$now**。", 4, "test") }
                        say("已发送，等通知弹出")
                        onDismiss()
                    } catch (e: Exception) { say("发送失败：${describe(e)}") } finally { sending = false }
                }
            }, enabled = !sending) { Text(if (sending) "发送中…" else "给自己发一条测试") }
        },
        dismissButton = { TextButton(onDismiss) { Text("关闭") } },
    )
}

/** 等宽、可选择、可横向滑动的代码框 */
@Composable
fun CodeBox(text: String) {
    Surface(shape = RoundedCornerShape(8.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
        SelectionContainer {
            Text(text, Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(10.dp),
                fontFamily = FontFamily.Monospace, fontSize = 12.sp, lineHeight = 17.sp, softWrap = false)
        }
    }
}
