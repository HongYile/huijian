package io.github.hongyile.huijian.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.hongyile.huijian.AccountDetail
import io.github.hongyile.huijian.ApiException
import io.github.hongyile.huijian.DeviceInfo
import io.github.hongyile.huijian.E2EError
import io.github.hongyile.huijian.E2EHub
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.hongyile.huijian.Hub
import io.github.hongyile.huijian.Manage
import io.github.hongyile.huijian.Core
import io.github.hongyile.huijian.E2EText
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * 设置 → 账户与设备：用户名和密码、生成配对码（3 分钟倒计时、显示被哪台设备用掉）、
 * 设备列表（标出本机、可移除其他设备）、给本机改名。和 Mac 的「账户」页一致。
 * 客户端不提供任何服务器管理入口（服务端 0.9.0 起管理后台只能在服务器上进入，/v1/me 的 can_admin 恒为 false）
 */
@Composable
fun AccountScreen(back: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    var detail by remember { mutableStateOf<AccountDetail?>(null) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var editCred by remember { mutableStateOf(false) }
    var revokeTarget by remember { mutableStateOf<DeviceInfo?>(null) }

    fun say(s: String) { scope.launch { snackbar.showSnackbar(s) } }
    fun load() {
        loading = true
        scope.launch {
            try {
                detail = api { it.account() }
                error = null
                detail?.let(Hub::noteAccount)
            } catch (e: Exception) {
                error = describe(e)
            } finally { loading = false }
        }
    }
    LaunchedEffect(Unit) { load(); E2EHub.refreshAsync() }
    // 服务端有 e2e（读到了加密状态）：改密码走新协议（e2ee-client.md §7.5），从不发送密码原文
    val e2eState by E2EHub.state.collectAsStateWithLifecycle()
    // 其他设备改了账户或设备（变更流 devices / account）：同步服务已经拉好最新的，直接显示
    val pushed by Hub.account.collectAsStateWithLifecycle()
    LaunchedEffect(pushed) {
        val p = pushed ?: return@LaunchedEffect
        detail = p; error = null
    }

    // 首页提示条 T67 点进来、账号还没有密码：账户信息读到后直接弹出「设置用户名和密码」，成功后自动开启加密（§11.1 末尾）。
    // 本账号任何设备都能设置初始密码（服务端 0.9.0），不再看本机有没有管理权限
    val wantSetPassword by E2EHub.setPasswordRequested.collectAsStateWithLifecycle()
    LaunchedEffect(wantSetPassword, detail) {
        val a = detail?.account ?: return@LaunchedEffect
        if (!wantSetPassword) return@LaunchedEffect
        if (!a.hasPassword) editCred = true
        E2EHub.requestSetPassword(false)
    }

    ManageScaffold("账户与设备", back, snackbar, actions = {
        IconButton({ load() }, enabled = !loading) { Icon(Icons.Default.Refresh, "刷新") }
    }) {
        val d = detail
        // ---- 用户名和密码 ----
        SectionCard(null) {
            val a = d?.account
            Text(a?.username?.ifBlank { null } ?: if (a == null) Hub.store.username.ifBlank { "账户" } else "未设置用户名",
                fontSize = 21.sp, fontWeight = FontWeight.SemiBold,
                color = if (a != null && a.username.isBlank()) WARNING else MaterialTheme.colorScheme.onSurface)
            Text(Hub.store.server.substringAfter("://") + (d?.let { " · 本账号 ${it.devices.count { !it.revoked }} 台设备" } ?: ""),
                fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            when {
                error != null && d == null -> Text(error!!, color = MaterialTheme.colorScheme.error)
                a == null -> Text(if (loading) "正在加载…" else "", color = MaterialTheme.colorScheme.onSurfaceVariant)
                a.hasPassword -> OutlinedButton({ editCred = true }) { Text("修改用户名 / 密码") }
                else -> Button({ editCred = true }) { Text("设置用户名和密码") }
            }
        }

        // ---- 配对码 ----
        if (d != null || error == null) PairCodeCard(onUsed = { load() }, say = ::say)

        // ---- 我的设备 ----
        val devs = d?.devices.orEmpty().filter { !it.revoked }
        SectionCard("我的设备", "同一台设备重新配对或登录时沿用原来的记录，不会重复出现。点「配对 N 次」可以展开配对记录。") {
            when {
                d == null && error != null -> Text(error!!, color = MaterialTheme.colorScheme.error, fontSize = 13.sp)
                d == null -> Text("正在加载…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                devs.isEmpty() -> Text("暂无设备", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            devs.forEachIndexed { i, dev ->
                if (i > 0) HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                DeviceRow(dev) { revokeTarget = dev }
            }
        }

        ThisDeviceCard(detail?.devices?.firstOrNull { it.current && !it.revoked }?.name, say = ::say, onRenamed = { load() })
    }

    if (editCred) detail?.account?.let { a ->
        val st = e2eState
        CredentialsDialog(a.username, a.hasPassword, newProtocol = st != null,
            onDismiss = { editCred = false }) { u, pw, cur, done ->
            scope.launch {
                try {
                    val server = Hub.store.server
                    // 账号有密码时一律先算「当前密码」凭证，只有 prelogin 是纯文本 404 且没有「已升级」标记时才按旧接口发原文；
                    // 设置初始密码只能发原文，本机标记了「已升级」时拒绝（e2ee-client.md §2.1 第 4 条、§2.4）。
                    // 加密状态还没读到（st == null）时由 changeCredentials 自己读，不按「没开启」处理
                    E2EHub.work {
                        val net = Hub.api() ?: throw java.io.IOException("未登录")
                        if (!a.hasPassword) {
                            // 设置初始密码后账号有了密码：用这次的凭证在后台自动开启加密（§11.1）
                            val pre = E2EHub.logic.setInitialPassword(net, server, u, pw)
                            E2EHub.notePasswordKeys(u, pre, E2EHub.logic.weakPassword(pw, u))
                        } else {
                            E2EHub.logic.changeCredentials(net, server, a.username, u, cur, pw.ifEmpty { null },
                                st?.enabled, E2EHub.activeSk())
                            if (pw.isNotEmpty()) E2EHub.passwordChanged()     // 新密码通过了强度检查：去掉 T24
                        }
                        if (u.isNotBlank()) { Hub.store.username = u; Hub.store.loginUsername = u }
                    }
                    say(if (pw.isEmpty()) "用户名已保存" else "已保存，新密码立即生效（已登录的设备不受影响）")
                    editCred = false
                    load()
                    E2EHub.refreshAsync()
                } catch (e: E2EError) {
                    say(e.message ?: "保存失败")
                    if (e.kind == E2EError.Kind.STALE_KEY) E2EHub.refreshAsync()     // 本机钥匙已停用（T46）：刷新状态
                } catch (e: Exception) {
                    say("保存失败：${describe(e)}")
                } finally { done() }
            }
        }
    }
    revokeTarget?.let { dev ->
        ConfirmDialog("移除「${dev.name}」？", "移除后，这台设备立即停止接收消息，需要重新配对或登录才能再用。", "移除", { revokeTarget = null }) {
            scope.launch {
                try { api { it.revokeDevice(dev.id) }; say("已移除「${dev.name}」"); load() }
                catch (e: Exception) { say("移除失败：${describe(e)}") }
            }
        }
    }
}

@Composable
private fun DeviceRow(d: DeviceInfo, onRevoke: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(when (d.platform) { "macos" -> "💻"; "ios" -> "📱"; "android" -> "🤖"; else -> "🖥" }, fontSize = 18.sp)
                Text(d.name, Modifier.weight(1f, fill = false), fontWeight = FontWeight.Medium, maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                if (d.current) Tag("本机", MaterialTheme.colorScheme.primary)
                if (d.online) Tag("在线", SUCCESS)
            }
            if (!d.current) TextButton(onRevoke) { Text("移除", color = MaterialTheme.colorScheme.error) }
        }
        SelectionContainer {
            Text(d.id + (d.client.takeIf { it.isNotBlank() }?.let { " · $it" } ?: ""), fontSize = 12.sp,
                fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(
            "首次配对 ${epochText(d.createdAt)} · 配对 ${d.pairCount} 次" +
                (if (d.pairCount > 1) "，最近 ${epochText(d.lastPaired)}" else "") + if (d.pairings.isNotEmpty()) (if (open) " ▴" else " ▾") else "",
            Modifier.clickable(enabled = d.pairings.isNotEmpty()) { open = !open }.padding(vertical = 2.dp),
            fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (open) for (p in d.pairings) Text(
            listOf(epochText(p.at), p.methodLabel, p.ip, p.client).filter { it.isNotBlank() }.joinToString(" · "),
            Modifier.padding(start = 12.dp), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** 生成配对码：3 分钟倒计时；每 2 秒查一次状态，被用掉后显示是哪台设备并刷新设备列表 */
@Composable
private fun PairCodeCard(onUsed: () -> Unit, say: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf<String?>(null) }
    var expiresAt by remember { mutableLongStateOf(0L) }
    var usedBy by remember { mutableStateOf<String?>(null) }
    var dead by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var statusUnsupported by remember { mutableStateOf(false) }
    // 带钥匙的配对码（§12.2）：长配对码和配对链接（二维码内容）。一次性钥匙只在内存里，用掉、过期、重新生成、离开页面都清掉
    var keyText by remember { mutableStateOf<String?>(null) }
    var keyLink by remember { mutableStateOf<String?>(null) }
    val ctx = LocalContext.current
    val e2eEnabled = E2EHub.state.collectAsStateWithLifecycle().value?.enabled == true
    /** 这次生成的配对码带没带钥匙（底部说明按它选） */
    var hadKey by remember { mutableStateOf(false) }
    DisposableEffect(Unit) { onDispose { keyText = null; keyLink = null } }
    // 显示二维码 / 长配对码期间窗口加 FLAG_SECURE：不能截图，最近任务的缩略图里也看不到（和恢复码页一样）
    val showingKey = keyLink != null
    DisposableEffect(showingKey) {
        var c: android.content.Context? = ctx
        while (c is android.content.ContextWrapper && c !is android.app.Activity) c = c.baseContext
        val w = (c as? android.app.Activity)?.window
        if (showingKey) w?.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        onDispose { if (showingKey) w?.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE) }
    }

    LaunchedEffect(code) { while (code != null) { now = System.currentTimeMillis(); delay(1000) } }
    LaunchedEffect(code) {
        val c = code ?: return@LaunchedEffect
        while (code == c && usedBy == null && !dead && !statusUnsupported) {
            delay(2000)
            if (code != c) return@LaunchedEffect
            if (System.currentTimeMillis() - expiresAt > 30_000) { dead = true; keyText = null; keyLink = null; return@LaunchedEffect }   // 过期 30 秒仍查不到：按失效处理
            val s = try { api { it.pairCodeStatus(c) } } catch (e: ApiException) {
                if (e.oldServer) statusUnsupported = true else if (e.status == 404) { dead = true; keyText = null; keyLink = null }
                null
            } catch (_: Exception) { null } ?: continue
            when (s.state) {
                "used" -> { usedBy = s.usedBy ?: "新设备"; keyText = null; keyLink = null; onUsed() }
                "expired" -> { dead = true; keyText = null; keyLink = null }
                else -> s.expiresIn?.let { expiresAt = System.currentTimeMillis() + it * 1000L }
            }
        }
    }

    val footer = when {
        code == null -> "新设备在登录页选「配对码」，扫码或输入后直接进入这个账号。本机已解锁时生成的二维码 / 长配对码，新设备登录后直接解锁加密消息。重新生成后，之前的配对码立即作废。"
        hadKey -> E2EText.T80
        e2eEnabled -> E2EText.T81
        else -> "新设备在登录页选「配对码」输入这 6 位数字，直接进入这个账号。"
    }
    SectionCard("添加设备到这个账号", footer) {
        val c = code
        val link = keyLink
        val text = keyText
        if (link != null && text != null && usedBy == null && !dead) {
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                QrCode(link, Modifier.size(220.dp).testTag("pairQr"))
                SelectionContainer { Text(text, fontFamily = FontFamily.Monospace, fontSize = 13.sp, modifier = Modifier.testTag("pairLongCode")) }
                OutlinedButton({ copyText(ctx, "回笺配对码", text, sensitive = true) }) { Text("复制长配对码") }
            }
        }
        if (c != null) {
            val left = ((expiresAt - now) / 1000).coerceAtLeast(0)
            val gone = usedBy != null || dead || left == 0L
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SelectionContainer {
                    Text(c.chunked(3).joinToString(" "), fontSize = 30.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace,
                        color = if (gone) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary,
                        textDecoration = if (gone) TextDecoration.LineThrough else null)
                }
                Text(
                    when {
                        usedBy != null -> "✓ 已被「$usedBy」使用"
                        gone -> "已失效"
                        else -> "%d:%02d 后失效".format(left / 60, left % 60)
                    },
                    fontSize = 13.sp,
                    color = when { usedBy != null -> SUCCESS; gone -> MaterialTheme.colorScheme.onSurfaceVariant; left <= 30 -> WARNING; else -> MaterialTheme.colorScheme.onSurfaceVariant },
                )
            }
        } else {
            Text("生成一个配对码（3 分钟内有效，只能用一次）", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 14.sp)
        }
        Button({
            busy = true
            scope.launch {
                try {
                    keyText = null; keyLink = null
                    // 本机已解锁、服务端支持时带钥匙（§12.2）：新设备扫码 / 输入长配对码后直接解锁
                    val sk = E2EHub.logic.activeSecretKey(E2EHub.secretKeys(), E2EHub.state.value, E2EHub.pinned())
                    val (pc, expiresIn, secret) = api { a ->
                        val supports = sk != null && runCatching { Manage.hasFeature(a.info(), "pair.key") }.getOrDefault(false)
                        E2EHub.logic.createPairCode(a, sk, supports)
                    }
                    if (secret != null) Core.pairFormat(Hub.store.server, pc, secret).let { (t, l) -> keyText = t; keyLink = l }
                    hadKey = secret != null
                    code = pc; expiresAt = System.currentTimeMillis() + expiresIn * 1000L
                    usedBy = null; dead = false; now = System.currentTimeMillis()
                } catch (e: Exception) { say("生成失败：${describe(e)}") } finally { busy = false }
            }
        }, enabled = !busy) { Text(if (busy) "生成中…" else if (code == null) "生成配对码" else "重新生成") }
    }
}

@Composable
private fun ThisDeviceCard(serverName: String?, say: (String) -> Unit, onRenamed: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(Hub.store.deviceName) }
    var saved by remember { mutableStateOf(Hub.store.deviceName) }
    var saving by remember { mutableStateOf(false) }
    // 本机在别的设备上被改名：没在编辑时直接换成新名字，正在编辑就保留输入
    LaunchedEffect(serverName) {
        if (serverName.isNullOrBlank() || serverName == saved) return@LaunchedEffect
        if (name.trim() == saved) name = serverName
        saved = serverName
    }
    SectionCard("本机", "名称可以随时修改、可以重名；设备 ID 是唯一的，排查问题时用 ID。") {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(name, { name = it.take(40) }, Modifier.weight(1f), label = { Text("设备名称") }, singleLine = true)
            TextButton({
                saving = true
                scope.launch {
                    try {
                        val n = api { it.renameMe(name.trim()) }
                        Hub.store.deviceName = n; name = n; saved = n
                        say("已保存"); onRenamed()
                    } catch (e: Exception) { say("保存失败：${describe(e)}") } finally { saving = false }
                }
            }, enabled = !saving && name.isNotBlank() && name.trim() != saved) { Text("保存") }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("设备 ID", Modifier.width(72.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 14.sp)
            Text(Hub.store.deviceId, Modifier.weight(1f), fontFamily = FontFamily.Monospace, fontSize = 13.sp)
            TextButton({ copyText(ctx, "设备 ID", Hub.store.deviceId) }) { Text("复制") }
        }
    }
}

/** 设置 / 修改用户名和密码（规则和服务端一致：没有密码时本账号任何设备都能设置初始密码，已有密码时要当前密码） */
@Composable
private fun CredentialsDialog(
    username0: String, hasPassword: Boolean, newProtocol: Boolean, onDismiss: () -> Unit,
    onSave: (username: String, password: String, current: String, done: () -> Unit) -> Unit,
) {
    var username by remember { mutableStateOf(username0) }
    var current by remember { mutableStateOf("") }
    var pw by remember { mutableStateOf("") }
    var pw2 by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var tick by remember { mutableIntStateOf(0) }
    // 账号有密码时一律核对当前密码（在本机算成凭证，不发原文，e2ee-client.md §2.4）
    val needCurrent = hasPassword
    val uErr = if (Manage.normalizeUsername(username).isEmpty()) "请填写用户名" else Manage.usernameProblem(username)
    val pErr = Manage.passwordProblem(pw, pw2, required = !hasPassword)
    val cErr = if (needCurrent && current.isEmpty()) "请填写当前密码" else null
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (hasPassword) "修改用户名 / 密码" else "设置用户名和密码") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                OutlinedTextField(username, { username = it.take(40) }, Modifier.fillMaxWidth(), label = { Text("用户名（2–32 个字）") },
                    singleLine = true, isError = tick > 0 && uErr != null)
                if (needCurrent) OutlinedTextField(current, { current = it }, Modifier.fillMaxWidth(), label = { Text("当前密码") },
                    singleLine = true, visualTransformation = PasswordVisualTransformation())
                OutlinedTextField(pw, { pw = it }, Modifier.fillMaxWidth(),
                    label = { Text(if (hasPassword) "新密码（留空只改用户名）" else "密码，至少 8 位") },
                    singleLine = true, visualTransformation = PasswordVisualTransformation())
                OutlinedTextField(pw2, { pw2 = it }, Modifier.fillMaxWidth(), label = { Text("再输入一次") },
                    singleLine = true, visualTransformation = PasswordVisualTransformation())
                val shown = uErr.takeIf { username != username0 || tick > 0 } ?: pErr.takeIf { pw2.isNotEmpty() || tick > 0 } ?: cErr.takeIf { tick > 0 }
                shown?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 13.sp) }
                if (hasPassword && newProtocol) Text("新密码至少 10 位，不要用常见密码。密码只在本机派生成登录凭证，不会发给服务器。", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = {
            TextButton({
                tick++
                if (uErr == null && pErr == null && cErr == null) {
                    busy = true
                    onSave(Manage.normalizeUsername(username), pw, current) { busy = false }
                }
            }, enabled = !busy) { Text(if (busy) "保存中…" else "保存") }
        },
        dismissButton = { TextButton(onDismiss) { Text("取消") } },
    )
}

/** 二维码（共用核心生成矩阵，这里只负责画）：白底黑码、四周留 4 格白边，深色模式下也一样（扫码软件只认这种） */
@Composable
fun QrCode(text: String, modifier: Modifier = Modifier) {
    val q = remember(text) { runCatching { Core.qr(text) }.getOrNull() }
    Canvas(modifier) {
        drawRect(Color.White)
        val (n, m) = q ?: return@Canvas
        val cell = kotlin.math.floor(minOf(size.width, size.height) / (n + 8))
        val ox = kotlin.math.floor((size.width - cell * n) / 2)
        val oy = kotlin.math.floor((size.height - cell * n) / 2)
        for (y in 0 until n) for (x in 0 until n) if (m[y * n + x]) {
            drawRect(Color.Black, Offset(ox + x * cell, oy + y * cell), Size(cell, cell))
        }
    }
}
