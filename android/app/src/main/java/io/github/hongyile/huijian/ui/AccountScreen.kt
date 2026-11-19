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
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.hongyile.huijian.Hub
import io.github.hongyile.huijian.Manage
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * 设置 → 账户与设备：用户名和密码、生成配对码（3 分钟倒计时、显示被哪台设备用掉）、
 * 设备列表（标出本机、可移除其他设备）、给本机改名、服务器管理权限。和 Mac 的「账户」页一致。
 */
@Composable
fun AccountScreen(back: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    var detail by remember { mutableStateOf<AccountDetail?>(null) }
    /** 本机是否「允许管理」：null = 还不知道 */
    var canAdmin by remember { mutableStateOf<Boolean?>(null) }
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
            canAdmin = runCatching { api { it.me() } }.getOrNull()?.let { if (it.has("can_admin")) it.optBoolean("can_admin") else null } ?: canAdmin
        }
    }
    LaunchedEffect(Unit) { load() }
    // 其他设备改了账户或设备（变更流 devices / account）：同步服务已经拉好最新的，直接显示，再复核本机的管理权限
    val pushed by Hub.account.collectAsStateWithLifecycle()
    LaunchedEffect(pushed) {
        val p = pushed ?: return@LaunchedEffect
        detail = p; error = null
        canAdmin = runCatching { api { it.me() } }.getOrNull()?.let { if (it.has("can_admin")) it.optBoolean("can_admin") else null } ?: canAdmin
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
                canAdmin != false -> Button({ editCred = true }) { Text("设置用户名和密码") }
                else -> Text("这个账号还没有密码，需要在开启了「允许管理」的设备上或管理网页的「账号」页设置。设置后就能在其他设备上用账号登录。",
                    color = WARNING, fontSize = 13.sp)
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

        SectionCard("服务器管理权限", if (canAdmin == true) "可以在管理后台管理服务器（存储、备份、所有账号）。"
            else "服务器级权限：管理后台、存储与备份。需要时在管理网页的「设备」页为本机打开「允许管理」。管理自己账号的 pushkey、设备和频道不需要这个权限。") {
            Row {
                Text("允许管理服务器", Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(when (canAdmin) { true -> "已开启"; false -> "未开启"; null -> "未知" },
                    color = if (canAdmin == true) SUCCESS else MaterialTheme.colorScheme.onSurface)
            }
        }
    }

    if (editCred) detail?.account?.let { a ->
        CredentialsDialog(a.username, a.hasPassword, admin = canAdmin == true, onDismiss = { editCred = false }) { u, pw, cur, done ->
            scope.launch {
                try {
                    val saved = api { it.setCredentials(u, pw, cur) }
                    if (saved.username.isNotBlank()) Hub.store.username = saved.username
                    say(if (pw.isEmpty()) "用户名已保存" else "已保存，新密码立即生效（已登录的设备不受影响）")
                    editCred = false
                    load()
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

    LaunchedEffect(code) { while (code != null) { now = System.currentTimeMillis(); delay(1000) } }
    LaunchedEffect(code) {
        val c = code ?: return@LaunchedEffect
        while (code == c && usedBy == null && !dead && !statusUnsupported) {
            delay(2000)
            if (code != c) return@LaunchedEffect
            if (System.currentTimeMillis() - expiresAt > 30_000) { dead = true; return@LaunchedEffect }   // 过期 30 秒仍查不到：按失效处理
            val s = try { api { it.pairCodeStatus(c) } } catch (e: ApiException) {
                if (e.oldServer) statusUnsupported = true else if (e.status == 404) dead = true
                null
            } catch (_: Exception) { null } ?: continue
            when (s.state) {
                "used" -> { usedBy = s.usedBy ?: "新设备"; onUsed() }
                "expired" -> dead = true
                else -> s.expiresIn?.let { expiresAt = System.currentTimeMillis() + it * 1000L }
            }
        }
    }

    SectionCard("添加设备到这个账号", "新设备在登录页选「配对码」输入这 6 位数字，直接进入这个账号；也可以选「账号登录」用用户名密码。重新生成后，之前的配对码立即作废。") {
        val c = code
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
                    val r = api { it.createPairCode() }
                    code = r.code; expiresAt = System.currentTimeMillis() + r.expiresIn * 1000L
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
    SectionCard("本机", "名称可以随时修改、可以重名；设备 ID 是唯一的，在管理后台搜索或排查问题时用 ID。") {
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

/** 设置 / 修改用户名和密码（规则和服务端一致：已有密码时要当前密码，「允许管理」的设备可以直接重设） */
@Composable
private fun CredentialsDialog(
    username0: String, hasPassword: Boolean, admin: Boolean, onDismiss: () -> Unit,
    onSave: (username: String, password: String, current: String, done: () -> Unit) -> Unit,
) {
    var username by remember { mutableStateOf(username0) }
    var current by remember { mutableStateOf("") }
    var pw by remember { mutableStateOf("") }
    var pw2 by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var tick by remember { mutableIntStateOf(0) }
    val needCurrent = hasPassword && !admin
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
                if (hasPassword && admin) Text("本机有「允许管理」权限，可以不填当前密码直接重设。", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
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
