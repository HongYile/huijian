package io.github.hongyile.huijian.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.hongyile.huijian.Api
import io.github.hongyile.huijian.ApiException
import io.github.hongyile.huijian.RecoveryRotation
import io.github.hongyile.huijian.Approval
import io.github.hongyile.huijian.DeviceRequest
import io.github.hongyile.huijian.E2EError
import io.github.hongyile.huijian.E2EHub
import io.github.hongyile.huijian.E2ERequest
import io.github.hongyile.huijian.E2EState
import io.github.hongyile.huijian.E2EStatus
import io.github.hongyile.huijian.E2EText
import io.github.hongyile.huijian.Hub
import io.github.hongyile.huijian.SetupMode
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException

/** 加密页里的子页面（返回键先回到主页面） */
private sealed interface Page {
    data object Main : Page
    data object Setup : Page
    data object UnlockPassword : Page
    data object UnlockDevice : Page
    data object UnlockRecovery : Page
    data object ResetPassword : Page
    data object RotateRecovery : Page
    /** 重置加密（锁定时「都不行？重置加密」）/ 更换加密钥匙（已解锁时），§11.3 */
    data class Reset(val locked: Boolean) : Page
}

/**
 * 设置 → 端到端加密（docs/e2ee-client.md）：开启加密、保存恢复码、三种解锁方式（密码 / 另一台设备批准 / 恢复码）、
 * 管理员重设密码后重新设置密码、批准其他设备（先承诺后揭晓的核对码）、更换恢复码、更换加密钥匙。
 * 所有消息都加密：没有「只接受加密消息」开关，也没有「删除服务器上的明文消息」（0.9.0 起取消，§7 第 2、4 项）
 */
@Composable
fun E2EScreen(back: () -> Unit, openKeys: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    val status by E2EHub.status.collectAsStateWithLifecycle()
    val state by E2EHub.state.collectAsStateWithLifecycle()
    val vaultError by E2EHub.vaultError.collectAsStateWithLifecycle()
    val notice by E2EHub.notice.collectAsStateWithLifecycle()
    var page by remember { mutableStateOf<Page>(Page.Main) }
    /** 刚生成的恢复码（T21）：只显示这一次、不保存在本机；放在 E2EHub 的内存里，转屏不会丢 */
    val pending by E2EHub.pendingRecovery.collectAsStateWithLifecycle()
    /** 刚开启加密：主页面顶部提示 T22 */
    var justEnabled by rememberSaveable { mutableStateOf(false) }
    var loadError by remember { mutableStateOf<String?>(null) }

    fun say(s: String) { scope.launch { snackbar.showSnackbar(s) } }
    fun reload() {
        scope.launch {
            loadError = try { api { E2EHub.refresh(it) }; null } catch (e: Exception) { describe(e) }
        }
    }
    LaunchedEffect(Unit) { reload() }

    /** 解锁之后：管理员重设过密码（账号回到旧登录方式或密码副本已失效）时进入「重新设置密码」（§4.4） */
    fun afterUnlock(st: E2EState?) {
        if (st?.needsNewPassword == true) page = Page.ResetPassword
        else { page = Page.Main; say("已解锁，加密消息正在解开") }
    }

    // 恢复码页：勾选「我已把恢复码保存好」点「完成」才能离开；其他子页面返回到主页面
    BackHandler(page != Page.Main || pending != null) { if (pending == null) page = Page.Main }
    val title = if (pending != null) E2EText.T21_TITLE else when (page) {
        Page.Main -> "端到端加密"
        Page.Setup -> E2EText.T20_TITLE
        Page.UnlockPassword -> "用密码解锁"
        Page.UnlockDevice -> E2EText.T30_TITLE
        Page.UnlockRecovery -> E2EText.T40_TITLE
        Page.ResetPassword -> E2EText.T42_TITLE
        Page.RotateRecovery -> if (state?.recoveryWrap.isNullOrEmpty()) "设置恢复码" else "更换恢复码"
        is Page.Reset -> if ((page as Page.Reset).locked) E2EText.RESET_TITLE else E2EText.ROTATE_KEY_TITLE
    }
    ManageScaffold(title, back = { if (pending != null) Unit else if (page == Page.Main) back() else page = Page.Main }, snackbar) {
        val code = pending
        if (code != null) {
            CodePage(code.first, ctx) {
                if (code.second) justEnabled = true else say("新恢复码已生效，以前的恢复码（如果有）已失效")
                E2EHub.recoveryDone()
                page = Page.Main
            }
            return@ManageScaffold
        }
        when (page) {
            Page.Main -> MainPage(
                status, state, vaultError ?: loadError, notice, justEnabled,
                go = { page = it }, openKeys = openKeys, say = ::say, reload = ::reload,
            )
            Page.Setup -> SetupPage(onDone = { page = Page.Main }, onConflict = { msg ->
                say(msg); reload(); page = Page.Main
            })
            Page.UnlockPassword -> UnlockPasswordPage(onUnlocked = { afterUnlock(it) }, other = { page = it })
            Page.UnlockDevice -> UnlockDevicePage(onUnlocked = { afterUnlock(it) }, onCancel = { page = Page.Main })
            Page.UnlockRecovery -> UnlockRecoveryPage(onUnlocked = { afterUnlock(it) })
            Page.ResetPassword -> PasswordFormPage(
                intro = E2EText.T42, currentLabel = "当前密码（管理员重设后的临时密码）", newPassword = true, action = "保存新密码",
                currentHelp = E2EText.T42_CURRENT,
            ) { cur, new ->
                E2EHub.work {
                    val net = Hub.api() ?: throw IOException("未登录")
                    E2EHub.logic.setPassword(net, Hub.store.server, ownUsername(), cur, new!!, enabled = true, sk = E2EHub.activeSk(),
                        afterAdminReset = true)
                    E2EHub.passwordChanged()
                    E2EHub.refresh(net)
                }
                say("已重新设置密码"); page = Page.Main
            }
            // 设置恢复码（§11.2，还没有时）和更换恢复码同一个接口、同一套流程（§7 第 3 项）
            Page.RotateRecovery -> PasswordFormPage(
                intro = if (state?.recoveryWrap.isNullOrEmpty()) "生成一个恢复码。忘记密码、又没有其他设备时，可以用它找回加密消息。先输入当前密码确认是你本人。"
                else "换一个新的恢复码，旧恢复码立即失效。先输入当前密码确认是你本人。",
                currentLabel = "当前密码", newPassword = false, action = "生成新恢复码",
            ) { cur, _ ->
                E2EHub.work {
                    val net = Hub.api() ?: throw IOException("未登录")
                    val sk = E2EHub.activeSk() ?: throw E2EError("本机还没有解锁，不能更换恢复码")
                    var rot: RecoveryRotation? = null
                    try {
                        // 新恢复码在发请求之前就存进 Keystore（服务端一换旧恢复码就失效，新的不能丢）
                        E2EHub.logic.rotateRecovery(net, Hub.store.server, ownUsername(), cur, sk) { rot = it; E2EHub.rotationGenerated(it) }
                        rot?.let { E2EHub.finishRotation(it) }
                    } catch (e: E2EError) {
                        // 结果不明：保留，之后刷新时 recovery_wrap 等于这次上传的就显示新恢复码；其他失败（T3、确认没换成）：删除
                        if (e.kind == E2EError.Kind.SETUP_UNSURE) E2EHub.rotationUnsure() else E2EHub.dropRotation(rot)
                        throw e
                    } catch (e: ApiException) {
                        if (e.status < 500) E2EHub.dropRotation(rot) else E2EHub.rotationUnsure()
                        throw e
                    } catch (e: Exception) {
                        E2EHub.rotationUnsure()
                        throw e
                    }
                    runCatching { E2EHub.refresh(net) }
                }
            }
            is Page.Reset -> {
                val locked = (page as Page.Reset).locked
                PasswordFormPage(
                    intro = if (locked) "忘了密码、没有其他已解锁的设备、也没有恢复码时，用当前密码换一把新的加密钥匙。以前的加密消息在这台设备上解不开。"
                    else "换一把新的加密钥匙：以后的新消息用新钥匙加密，本机仍保留旧钥匙，能看以前的消息。",
                    currentLabel = "当前密码", newPassword = false, action = if (locked) E2EText.RESET_TITLE else E2EText.ROTATE_KEY_TITLE,
                    confirm = E2EText.T45, confirmAction = if (locked) "重置" else "更换",
                ) { cur, _ ->
                    E2EHub.work {
                        val net = Hub.api() ?: throw IOException("未登录")
                        E2EHub.reset(net, ownUsername(), cur)
                    }
                    say(if (locked) "已重置加密" else "已更换加密钥匙")
                    page = Page.Main
                }
            }
        }
    }
}

/** 自己的用户名：以服务端为准（可能在别的设备上改过名；配对码登录的设备本地没有） */
private fun ownUsername(): String {
    val fromServer = runCatching { Hub.api()?.account()?.account?.username }.getOrNull().orEmpty()
    if (fromServer.isNotBlank()) { Hub.store.username = fromServer; return fromServer }
    return Hub.store.username.ifBlank { throw E2EError("这个账号还没有用户名和密码，请先在「账户与设备」里设置") }
}

// ---------- 主页面 ----------

@Composable
private fun ColumnScope.MainPage(
    status: E2EStatus, state: E2EState?, error: String?, notice: String?, justEnabled: Boolean,
    go: (Page) -> Unit, openKeys: () -> Unit, say: (String) -> Unit, reload: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    if (notice != null) SectionCard(null) {
        Text(notice, color = MaterialTheme.colorScheme.error, fontSize = 14.sp)
        TextButton({ E2EHub.notice.value = null }) { Text("知道了") }
    }
    if (justEnabled && status == E2EStatus.UNLOCKED) SectionCard(null) {
        Text(E2EText.T22, fontSize = 14.sp)
        Button(openKeys) { Text("去 Pushkey 页") }
    }
    when (status) {
        E2EStatus.UNKNOWN -> SectionCard(null) {
            Text(error ?: "正在读取加密状态…", color = if (error != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
            if (error != null) OutlinedButton(reload) { Text("重试") }
        }
        E2EStatus.UNSUPPORTED -> SectionCard(null) {
            Text("服务端版本较旧，不支持端到端加密。把服务端更新到 0.7.0 或更新版本后可用。", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        E2EStatus.DISABLED -> {
            // §11.1：账号一有密码就自动开启；手动开启只作为自动开启失败时的出口（没有「暂不开启」）
            val auto by E2EHub.autoState.collectAsStateWithLifecycle()
            when (auto) {
                E2EHub.AutoState.RUNNING -> SectionCard(null) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        Text(E2EText.AUTO_RUNNING, Modifier.testTag("autoRunning"), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                E2EHub.AutoState.FAILED -> Note(E2EText.AUTO_FAILED, Modifier.testTag("autoFailed"))
                E2EHub.AutoState.IDLE -> {}
            }
            SectionCard(E2EText.T20_TITLE, E2EText.T20) {
                Text("未开启", color = MaterialTheme.colorScheme.onSurfaceVariant)
                // 本机存着进行中的开启，服务器上还没开启（§4.1）：提示重试（重试时先核对，不会重复开启）
                val interrupted by E2EHub.setupPending.collectAsStateWithLifecycle()
                // 只提示手动开启留下的（自动开启留下的由自动开启自己处理，用户没点过「开启」，不显示两种提示）
                if (interrupted && auto == E2EHub.AutoState.IDLE && E2EHub.pendingSetup()?.mode == SetupMode.MANUAL) {
                    Text(E2EText.SETUP_PENDING, color = MaterialTheme.colorScheme.error, fontSize = 13.sp)
                    var confirmAbandon by remember { mutableStateOf(false) }
                    OutlinedButton({ confirmAbandon = true }, Modifier.testTag("abandonSetup")) { Text("放弃这次开启") }
                    if (confirmAbandon) ConfirmDialog("放弃这次开启？", "本机保存的这次开启的新钥匙和恢复码会删掉。如果服务器其实已经开启了，之后可以用密码解锁。",
                        "放弃", { confirmAbandon = false }) { E2EHub.abandonSetup(SetupMode.MANUAL) }
                }
                // 自动开启进行中：不能同时手动开启（两次开启会争同一个进行中记录）
                Button({ go(Page.Setup) }, Modifier.testTag("e2eSetup"), enabled = auto != E2EHub.AutoState.RUNNING) { Text(E2EText.T20_TITLE) }
            }
        }
        E2EStatus.LOCKED -> {
            // 钉住的公钥不是服务器启用中的钥匙（别的设备重置过加密）：说明换成 T46，用密码或恢复码解锁确认新钥匙（§11.4）。
            // 这时本机还留着旧钥匙，不能说「还没有账号的加密钥匙」
            val keyChanged by E2EHub.keyChanged.collectAsStateWithLifecycle()
            ResetPending()
            SectionCard("本机已锁定", if (keyChanged) E2EText.T46
                else "这台设备还没有账号的加密钥匙，加密消息显示为「${E2EText.T60}」。选一种方式解锁，解锁后会自动解开。") {
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 13.sp) }
                Nav("用密码解锁", "输入账号密码", Modifier.testTag("unlockPassword")) { go(Page.UnlockPassword) }
                HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                // 设备批准拿到的钥匙不能替换钉住的公钥：钥匙更换过时不提供（§11.4）
                if (!keyChanged) {
                    Nav(E2EText.T30_TITLE, "在另一台已解锁的设备上核对后批准", Modifier.testTag("unlockDevice")) { go(Page.UnlockDevice) }
                    HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                }
                Nav(E2EText.T40_TITLE, "开启加密时保存的恢复码", Modifier.testTag("unlockRecovery")) { go(Page.UnlockRecovery) }
            }
            SectionCard(null) {
                Nav("都不行？重置加密", "用当前密码换一把新的加密钥匙", Modifier.testTag("e2eReset")) { go(Page.Reset(locked = true)) }
            }
        }
        E2EStatus.UNLOCKED -> state?.let { UnlockedPage(it, error, go, openKeys, say) }
    }
}

@Composable
private fun ColumnScope.UnlockedPage(st: E2EState, error: String?, go: (Page) -> Unit, openKeys: () -> Unit, say: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    if (st.needsNewPassword) SectionCard(E2EText.T42_TITLE) {
        Text(E2EText.T42, color = WARNING, fontSize = 14.sp)
        Button({ go(Page.ResetPassword) }) { Text(E2EText.T42_TITLE) }
    }
    ResetPending()
    // §11.1 第 5 步：密码偏弱照样开启，提示换个更长的密码
    val weak by E2EHub.weakPassword.collectAsStateWithLifecycle()
    if (weak) Note(E2EText.T24, Modifier.testTag("weakPassword"))
    // §11.2：恢复码改为可选，还没有时提示并给「设置恢复码」
    if (st.recoveryWrap.isEmpty()) SectionCard("恢复码") {
        Text(E2EText.T23, color = WARNING, fontSize = 14.sp)
        Button({ go(Page.RotateRecovery) }, Modifier.testTag("setRecovery")) { Text("设置恢复码") }
    }
    SectionCard("状态") {
        Row {
            Text("端到端加密", Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("已开启 · 钥匙 " + (st.activeKey?.kid?.take(8) ?: "—"), color = SUCCESS)
        }
        Row {
            Text("本机", Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("已解锁", color = SUCCESS)
        }
        Row {
            Text("恢复码", Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(if (st.recoveryWrap.isNotEmpty()) "已设置" else "未设置", color = if (st.recoveryWrap.isNotEmpty()) MaterialTheme.colorScheme.onSurface else WARNING)
        }
        if (st.serverSeal) {
            // §11.5：服务器代加密始终开启，没有开关，只读说明 T65
            Row {
                Text("服务器代加密", Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("始终开启")
            }
            Text(E2EText.T65, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("serverSealNote"))
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 13.sp) }
    }

    if (st.requests.isNotEmpty()) Requests(st.requests, say)

    SectionCard("加密发送密钥", E2EText.T70) {
        Nav("到 Pushkey 页复制", "每把 pushkey 下面都有一行「加密发送密钥」") { openKeys() }
    }
    SectionCard("更多") {
        if (st.recoveryWrap.isNotEmpty()) {
            Nav("更换恢复码", "旧恢复码立即失效") { go(Page.RotateRecovery) }
            HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
        }
        Nav(E2EText.ROTATE_KEY_TITLE, "以后的新消息用新钥匙加密，本机保留旧钥匙", Modifier.testTag("e2eRotateKey")) { go(Page.Reset(locked = false)) }
    }
}

/** 一行提示（警告色底） */
@Composable
private fun Note(text: String, modifier: Modifier = Modifier) {
    SectionCard(null) { Text(text, modifier, color = WARNING, fontSize = 14.sp) }
}

/** 本机存着进行中的重置（结果不明，§11.3）：提示稍后刷新时自动核对 */
@Composable
private fun ResetPending() {
    val pending by E2EHub.setupPending.collectAsStateWithLifecycle()
    if (pending && E2EHub.pendingSetup()?.mode == SetupMode.RESET) SectionCard(null) {
        Text(E2EText.RESET_NOT_YET, color = WARNING, fontSize = 14.sp)
        var confirmAbandon by remember { mutableStateOf(false) }
        OutlinedButton({ confirmAbandon = true }, Modifier.testTag("abandonReset")) { Text("放弃这次重置") }
        if (confirmAbandon) ConfirmDialog("放弃这次重置？", "本机保存的这次重置的新钥匙会删掉，继续用现在的钥匙。如果服务器其实已经重置了，之后可以用密码或恢复码解锁。",
            "放弃", { confirmAbandon = false }) { E2EHub.abandonSetup(SetupMode.RESET) }
    }
}

/** 等待批准的设备（§5）：批准 → 等对方揭晓 → 核对码 → 一致才转交 */
@Composable
private fun Requests(reqs: List<E2ERequest>, say: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    val stages by E2EHub.approvalStages.collectAsStateWithLifecycle()
    // 等对方揭晓期间每 3 秒查一次；长轮询收到 e2e 变更时立即再查
    val waiting = stages.filterValues { it is Approval.Stage.Waiting }.keys
    LaunchedEffect(waiting) {
        while (waiting.isNotEmpty()) {
            for (id in waiting) runCatching { E2EHub.stepApproval(id) }
            val t = E2EHub.tick.value
            withTimeoutOrNull(3000) { E2EHub.tick.first { it > t } }
        }
    }
    var busy by remember { mutableStateOf(false) }
    fun run(block: suspend () -> Unit) {
        busy = true
        scope.launch {
            try { block() } catch (e: E2EError) { say(e.message ?: "操作失败") } catch (e: Exception) { say(describe(e)) } finally { busy = false }
        }
    }
    SectionCard("等待批准的设备", "批准后，对方能解开这个账号的全部加密消息。核对码不一致时不要批准。") {
        reqs.forEachIndexed { i, r ->
            if (i > 0) HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(when (r.platform) { "macos" -> "💻"; "ios" -> "📱"; "android" -> "🤖"; else -> "🖥" }, fontSize = 18.sp)
                    Column(Modifier.weight(1f)) {
                        Text(r.name.ifBlank { r.deviceId }, fontWeight = FontWeight.Medium)
                        Text(listOf(r.platform, "请求于 " + epochText(r.requestedAt)).filter { it.isNotBlank() }.joinToString(" · "),
                            fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                when (val s = stages[r.deviceId]) {
                    null -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button({ run { E2EHub.beginApproval(r) } }, enabled = !busy, modifier = Modifier.testTag("approve")) { Text("批准") }
                        OutlinedButton({ run { E2EHub.deny(r.deviceId); say("已拒绝") } }, enabled = !busy) {
                            Text("拒绝", color = MaterialTheme.colorScheme.error)
                        }
                    }
                    // 等对方揭晓（§5 第 2 步）：「拒绝」发送 deny；「取消」只停止本机的等待
                    Approval.Stage.Waiting -> Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                            Text("等待「${r.name}」显示核对码…", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton({ run { E2EHub.deny(r.deviceId); E2EHub.dismissApproval(r.deviceId); say("已拒绝") } }, enabled = !busy,
                                modifier = Modifier.testTag("approvalDeny")) { Text("拒绝", color = MaterialTheme.colorScheme.error) }
                            TextButton({ E2EHub.dismissApproval(r.deviceId) }, enabled = !busy, modifier = Modifier.testTag("approvalCancel")) { Text("取消") }
                        }
                    }
                    is Approval.Stage.Code -> {
                        SasCode(s.code)
                        Text(E2EText.t53(s.code), fontSize = 14.sp)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button({ run { E2EHub.approve(r.deviceId); say("已批准「${r.name}」") } }, enabled = !busy,
                                modifier = Modifier.testTag("approveMatch")) { Text("一致，批准") }
                            OutlinedButton({ run { E2EHub.deny(r.deviceId); say("已拒绝") } }, enabled = !busy) {
                                Text("不一致，拒绝", color = MaterialTheme.colorScheme.error)
                            }
                        }
                    }
                    Approval.Stage.Granted -> Done("已批准", SUCCESS) { E2EHub.dismissApproval(r.deviceId) }
                    Approval.Stage.Rejected -> Done("已拒绝", MaterialTheme.colorScheme.onSurfaceVariant) { E2EHub.dismissApproval(r.deviceId) }
                    is Approval.Stage.Failed -> Done(s.message, MaterialTheme.colorScheme.error) { E2EHub.dismissApproval(r.deviceId) }
                }
            }
        }
    }
}

@Composable
private fun Done(text: String, color: androidx.compose.ui.graphics.Color, onClose: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(text, Modifier.weight(1f), color = color, fontSize = 14.sp)
        TextButton(onClose) { Text("关闭") }
    }
}

/** 核对码大字等宽显示，按 3+3 位 */
@Composable
private fun SasCode(code: String) {
    SelectionContainer {
        Text(E2EText.sasText(code), fontSize = 34.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.primary, modifier = Modifier.testTag("sasCode"))
    }
}

@Composable
private fun Nav(title: String, sub: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Row(modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            Text(sub, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

// ---------- 开启加密（§4.1） ----------

@Composable
private fun SetupPage(onDone: () -> Unit, onConflict: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var current by remember { mutableStateOf("") }
    var change by remember { mutableStateOf(true) }
    var pw by remember { mutableStateOf("") }
    var pw2 by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var pwError by remember { mutableStateOf<String?>(null) }
    SectionCard(null, E2EText.T20) {
        PasswordField(current, { current = it; error = null }, "当前密码", Modifier.testTag("setupCurrent"))
        Row(Modifier.fillMaxWidth().clickable { change = !change }, verticalAlignment = Alignment.CenterVertically) {
            Checkbox(change, { change = it })
            Text("同时换一个新密码（推荐）")
        }
        if (change) {
            PasswordField(pw, { pw = it; pwError = null }, "新密码", Modifier.testTag("setupNew"), error = pwError)
            PasswordField(pw2, { pw2 = it; pwError = null }, "再输入一次新密码", Modifier.testTag("setupNew2"))
            Text("旧密码以前以原文发给过服务器，换一个新密码更安全。新密码至少 10 位，不要用常见密码。",
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 13.sp) }
        Button({
            when {
                current.isEmpty() -> { error = "请填写当前密码"; return@Button }
                change && pw.isEmpty() -> { pwError = "请填写新密码"; return@Button }
                change && pw != pw2 -> { pwError = "两次输入的新密码不一样"; return@Button }
            }
            if (E2EHub.autoState.value == E2EHub.AutoState.RUNNING) { error = E2EText.AUTO_RUNNING; return@Button }
            busy = true; error = null; pwError = null
            scope.launch {
                try {
                    E2EHub.work {
                        val net = Hub.api() ?: throw IOException("未登录")
                        if (E2EHub.autoState.value == E2EHub.AutoState.RUNNING) throw E2EError(E2EText.AUTO_RUNNING)
                        try {
                            // 新钥匙对和恢复码在发请求之前就存进 Keystore（setupGenerated），App 被终止也不丢
                            val session = Hub.session
                            E2EHub.setupInFlight = true
                            val r = try {
                                E2EHub.logic.setup(net, Hub.store.server, ownUsername(), current, if (change) pw else null,
                                    E2EHub.pendingSetup()?.takeIf { it.mode == SetupMode.MANUAL }, onGenerated = { E2EHub.setupGenerated(it, session) })
                            } finally { E2EHub.setupInFlight = false }
                            if (session != Hub.session) throw IOException("已退出登录")
                            // 恢复码先存好、放进 App 状态（点「完成」才清除），再保存私钥
                            E2EHub.finishSetup(r, session = session, confirmed = true)
                            E2EHub.passwordChanged()     // 手动开启时密码都通过了强度检查
                            runCatching { E2EHub.refresh(net) }
                            r
                        } catch (e: E2EError) {
                            // 结果不明：留着，之后每次刷新状态都会核对；确认失败（4xx、没开启、别的设备开启了）：删除
                            if (e.kind != E2EError.Kind.SETUP_UNSURE) E2EHub.dropSetup(SetupMode.MANUAL)
                            throw e
                        } catch (e: ApiException) {
                            E2EHub.dropSetup(SetupMode.MANUAL)
                            throw e
                        }
                    }
                    current = ""; pw = ""; pw2 = ""
                    onDone()
                } catch (e: E2EError) {
                    when (e.kind) {
                        E2EError.Kind.WEAK_CURRENT -> { change = true; error = e.message }
                        E2EError.Kind.WEAK_PASSWORD -> pwError = e.message
                        E2EError.Kind.CONFLICT -> onConflict(e.message ?: "别的设备刚开启了加密")
                        else -> error = e.message
                    }
                } catch (e: Exception) {
                    error = describe(e)
                } finally { busy = false }
            }
        }, Modifier.fillMaxWidth().testTag("setupSubmit"), enabled = !busy) {
            if (busy) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) else Text(E2EText.T20_TITLE)
        }
    }
}

/**
 * 保存恢复码（T21）：大字等宽显示，可以复制（剪贴板内容标为敏感，系统不预览）；必须勾选「我已把恢复码保存好」才能点「完成」。
 * 显示期间窗口加 FLAG_SECURE：不能截图，最近任务里的缩略图也看不到恢复码
 */
@Composable
private fun CodePage(code: String, ctx: android.content.Context, onDone: () -> Unit) {
    var saved by remember { mutableStateOf(false) }
    DisposableEffect(Unit) {
        val w = ctx.findActivity()?.window
        w?.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        onDispose { w?.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE) }
    }
    SectionCard(null, E2EText.T21) {
        SelectionContainer {
            Text(code, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.primary, modifier = Modifier.testTag("recoveryCode"))
        }
        OutlinedButton({ copyText(ctx, "恢复码", code, sensitive = true) }) { Text("复制") }
        Row(Modifier.fillMaxWidth().clickable { saved = !saved }, verticalAlignment = Alignment.CenterVertically) {
            Checkbox(saved, { saved = it }, Modifier.testTag("recoverySaved"))
            Text(E2EText.T21_CHECK)
        }
        Button(onDone, Modifier.fillMaxWidth().testTag("recoveryDone"), enabled = saved) { Text("完成") }
    }
}

private fun android.content.Context.findActivity(): android.app.Activity? {
    var c: android.content.Context? = this
    while (c is android.content.ContextWrapper) {
        if (c is android.app.Activity) return c
        c = c.baseContext
    }
    return null
}

// ---------- 解锁（§4.2–4.4） ----------

@Composable
private fun UnlockPasswordPage(onUnlocked: (E2EState?) -> Unit, other: (Page) -> Unit) {
    val scope = rememberCoroutineScope()
    var pw by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var wrapGone by remember { mutableStateOf(false) }
    SectionCard(null, "输入账号密码，在本机解开服务器上用密码锁住的钥匙。密码不会发给服务器。") {
        PasswordField(pw, { pw = it; error = null }, "密码", Modifier.testTag("unlockPw"))
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 13.sp) }
        if (wrapGone) {
            Text("可以改用另外两种方式解锁：", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton({ other(Page.UnlockDevice) }) { Text("另一台设备批准") }
                OutlinedButton({ other(Page.UnlockRecovery) }) { Text("恢复码") }
            }
        }
        Button({
            if (pw.isEmpty()) { error = "请填写密码"; return@Button }
            busy = true; error = null
            scope.launch {
                try {
                    val st = E2EHub.work {
                        val net = Hub.api() ?: throw IOException("未登录")
                        val u = ownUsername()
                        val key = E2EHub.logic.unlockWithPassword(net, Hub.store.server, u, pw)
                        E2EHub.adopt(key, trusted = true)       // 密码解锁的钥匙可以替换钉住的公钥（§11.4）
                        E2EHub.notePasswordStrength(pw, u)      // 顺带按这次的密码重新判断 T24
                        runCatching { E2EHub.refresh(net) }.getOrNull()
                    }
                    pw = ""
                    onUnlocked(st)
                } catch (e: E2EError) {
                    error = e.message
                    wrapGone = e.kind == E2EError.Kind.WRAP_INVALID
                } catch (e: Exception) {
                    error = describe(e)
                } finally { busy = false }
            }
        }, Modifier.fillMaxWidth().testTag("unlockPwSubmit"), enabled = !busy) {
            if (busy) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) else Text("解锁")
        }
    }
}

/** 请另一台设备批准（新设备一侧）：等待 → 核对码（T31）→ 收到转交的钥匙；被拒绝显示 T32 */
@Composable
private fun UnlockDevicePage(onUnlocked: (E2EState?) -> Unit, onCancel: () -> Unit) {
    val scope = rememberCoroutineScope()
    val step by E2EHub.requestStep.collectAsStateWithLifecycle()
    var error by remember { mutableStateOf<String?>(null) }
    // 进入页面时还没有请求会自动发起：一开始就算「正在发起」，不闪一下「重新请求」
    var starting by remember { mutableStateOf(E2EHub.requestStep.value == null) }
    var cancelling by remember { mutableStateOf(false) }
    fun start() {
        starting = true; error = null
        scope.launch {
            // E2EError（账号公钥对不上 T43 等）已经放进 requestStep 的 Failed，页面显示原因和「重新请求」
            try { E2EHub.startRequest() } catch (_: E2EError) {} catch (e: Exception) { error = describe(e) } finally { starting = false }
        }
    }
    // 进入页面时还没有请求：自动发起
    LaunchedEffect(Unit) { if (E2EHub.requestStep.value == null) start() }
    // 等待批准、等待核对期间每 3 秒查一次；长轮询收到 e2e 变更时立即再查
    val polling = step == DeviceRequest.Step.Waiting || step is DeviceRequest.Step.Code
    LaunchedEffect(polling) {
        while (polling) {
            val t = E2EHub.tick.value
            withTimeoutOrNull(3000) { E2EHub.tick.first { it > t } }
            try { E2EHub.pollRequest(); error = null } catch (_: E2EError) {} catch (e: Exception) { error = describe(e) }
        }
    }
    LaunchedEffect(step) {
        val s = step
        if (s is DeviceRequest.Step.Unlocked) { E2EHub.clearRequest(); onUnlocked(s.state) }
    }
    SectionCard(null, E2EText.T30) {
        when (val s = step) {
            // 发起失败（网络错误等）：不转圈，显示原因（下面的 error）和「重新请求」
            null -> if (starting) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                Text("正在发起请求…", color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else Button({ start() }) { Text("重新请求") }
            DeviceRequest.Step.Waiting -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                Text("等待另一台设备批准…", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            is DeviceRequest.Step.Failed -> {
                Text(s.message, color = MaterialTheme.colorScheme.error)
                Button({ E2EHub.clearRequest(); start() }, enabled = !starting) { Text("重新请求") }
            }
            is DeviceRequest.Step.Code -> {
                SasCode(s.code)
                Text(E2EText.t31(s.code), fontSize = 14.sp)
            }
            DeviceRequest.Step.Denied -> {
                Text(E2EText.T32, color = MaterialTheme.colorScheme.error)
                Button({ E2EHub.clearRequest(); start() }, enabled = !starting) { Text("重新请求") }
            }
            is DeviceRequest.Step.Unlocked -> Text("已解锁", color = SUCCESS)
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 13.sp) }
        if (step != DeviceRequest.Step.Denied && step !is DeviceRequest.Step.Failed) OutlinedButton({
            cancelling = true; error = null
            scope.launch {
                // 取消失败：服务器上的请求还在（其他设备会继续弹通知），留在这页提示原因，可以再点「取消」
                try { E2EHub.cancelRequest(); onCancel() }
                catch (e: E2EError) { error = "取消失败：${e.message}" }
                catch (e: Exception) { error = "取消失败：${describe(e)}，请重试" }
                finally { cancelling = false }
            }
        }, Modifier.testTag("cancelRequest"), enabled = !cancelling) { Text(if (cancelling) "正在取消…" else "取消") }
        else OutlinedButton({ E2EHub.clearRequest(); onCancel() }) { Text("返回") }
    }
}

@Composable
private fun UnlockRecoveryPage(onUnlocked: (E2EState?) -> Unit) {
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    SectionCard(null, "输入开启加密时保存的恢复码（大小写、空格、横线都可以）。") {
        OutlinedTextField(code, { code = it.take(64); error = null }, Modifier.fillMaxWidth().testTag("recoveryInput"),
            label = { Text("恢复码") }, placeholder = { Text(E2EText.T40_PLACEHOLDER, fontFamily = FontFamily.Monospace) },
            singleLine = true, textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace),
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false,
                keyboardType = KeyboardType.Ascii))
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 13.sp) }
        Button({
            if (code.isBlank()) { error = "请填写恢复码"; return@Button }
            busy = true; error = null
            scope.launch {
                try {
                    val st = E2EHub.work {
                        val net = Hub.api() ?: throw IOException("未登录")
                        val (key, st) = E2EHub.logic.unlockWithRecovery(net, code)
                        E2EHub.adopt(key, st, trusted = true)   // 恢复码解锁的钥匙可以替换钉住的公钥（§11.4）
                        st
                    }
                    code = ""
                    onUnlocked(st)
                } catch (e: E2EError) {
                    error = e.message
                } catch (e: Exception) {
                    error = describe(e)
                } finally { busy = false }
            }
        }, Modifier.fillMaxWidth().testTag("recoverySubmit"), enabled = !busy) {
            if (busy) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) else Text("解锁")
        }
    }
}

// ---------- 需要当前密码的表单：重新设置密码（T42）、更换恢复码 ----------

@Composable
private fun PasswordFormPage(intro: String, currentLabel: String, newPassword: Boolean, action: String, currentHelp: String? = null,
                             confirm: String? = null, confirmAction: String = action,
                             submit: suspend (current: String, new: String?) -> Unit) {
    var asking by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var cur by remember { mutableStateOf("") }
    var pw by remember { mutableStateOf("") }
    var pw2 by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var pwError by remember { mutableStateOf<String?>(null) }
    SectionCard(null, intro) {
        PasswordField(cur, { cur = it; error = null }, currentLabel, Modifier.testTag("formCurrent"), help = currentHelp)
        if (newPassword) {
            PasswordField(pw, { pw = it; pwError = null }, "新密码", Modifier.testTag("formNew"), error = pwError)
            PasswordField(pw2, { pw2 = it; pwError = null }, "再输入一次新密码", Modifier.testTag("formNew2"))
            Text("新密码至少 10 位，不要用常见密码。", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 13.sp) }
        Button({
            when {
                cur.isEmpty() -> { error = "请填写$currentLabel"; return@Button }
                newPassword && pw.isEmpty() -> { pwError = "请填写新密码"; return@Button }
                newPassword && pw != pw2 -> { pwError = "两次输入的新密码不一样"; return@Button }
            }
            if (confirm != null) { asking = true; return@Button }
            busy = true; error = null; pwError = null
            scope.launch {
                try {
                    submit(cur, if (newPassword) pw else null)
                    cur = ""; pw = ""; pw2 = ""
                } catch (e: E2EError) {
                    if (e.kind == E2EError.Kind.WEAK_PASSWORD) pwError = e.message else error = e.message
                    if (e.kind == E2EError.Kind.STALE_KEY) E2EHub.refreshAsync()     // 本机钥匙已停用（T46）：刷新状态
                } catch (e: Exception) {
                    error = describe(e)
                } finally { busy = false }
            }
        }, Modifier.fillMaxWidth().testTag("formSubmit"), enabled = !busy) {
            if (busy) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) else Text(action)
        }
    }
    // 二次确认（重置加密 T45）
    if (asking && confirm != null) ConfirmDialog(action, confirm, confirmAction, { asking = false }) {
        asking = false
        busy = true; error = null
        scope.launch {
            try {
                submit(cur, null)
                cur = ""
            } catch (e: E2EError) {
                error = e.message
            } catch (e: Exception) {
                error = describe(e)
            } finally { busy = false }
        }
    }
}

@Composable
private fun PasswordField(value: String, onChange: (String) -> Unit, label: String, modifier: Modifier = Modifier, error: String? = null,
                          help: String? = null) {
    OutlinedTextField(value, onChange, modifier.fillMaxWidth(), label = { Text(label) }, singleLine = true,
        visualTransformation = PasswordVisualTransformation(), isError = error != null,
        supportingText = (error ?: help)?.let { { Text(it) } },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
}
