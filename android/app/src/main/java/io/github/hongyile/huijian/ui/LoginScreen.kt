package io.github.hongyile.huijian.ui

import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.hongyile.huijian.Api
import io.github.hongyile.huijian.BuildConfig
import io.github.hongyile.huijian.ConnState
import io.github.hongyile.huijian.E2EError
import io.github.hongyile.huijian.E2EHub
import io.github.hongyile.huijian.Hub
import io.github.hongyile.huijian.LoginOutcome
import io.github.hongyile.huijian.Manage
import io.github.hongyile.huijian.RegisterUi
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.material3.OutlinedButton
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import io.github.hongyile.huijian.Core
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
fun LoginScreen(onSignedIn: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var server by rememberSaveable { mutableStateOf(Hub.store.server.ifBlank { BuildConfig.DEFAULT_SERVER }) }
    var usePair by rememberSaveable { mutableStateOf(false) }
    var username by rememberSaveable { mutableStateOf(Hub.store.username) }
    // 密码、配对码、邀请码只放在内存里（remember），不进 saved state Bundle（会被系统写到磁盘）
    var password by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    val defaultName = remember(ctx) {
        Settings.Global.getString(ctx.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: "${Build.MANUFACTURER} ${Build.MODEL}"
    }
    var name by rememberSaveable { mutableStateOf(defaultName) }
    var busy by rememberSaveable { mutableStateOf(false) }
    var error by rememberSaveable { mutableStateOf<String?>(null) }
    /** 密码强度不够（注册时核心库检查的结果）：显示在密码框下面 */
    var passwordError by rememberSaveable { mutableStateOf<String?>(null) }
    /** 配对码输入框的解析结果：6 位、长配对码、配对链接（docs/e2ee-client.md §12.3）；格式不对时 null */
    val parsed = remember(code) { if (code.isBlank()) null else runCatching { Core.pairParse(code) }.getOrNull() }
    // 系统打开的 huijian://pair 链接（系统相机扫码、点链接）：切到「配对码」并填好，等用户确认后再点「配对」
    val pendingLink by Hub.pendingPairLink.collectAsStateWithLifecycle()
    LaunchedEffect(pendingLink) {
        val l = pendingLink ?: return@LaunchedEffect
        Hub.pendingPairLink.value = null
        usePair = true; error = null; code = l
    }
    // 链接里带服务器地址：填进服务器地址栏（用户看得到、可以改）
    LaunchedEffect(parsed?.server) { parsed?.server?.let { if (Api.normalize(it) != Api.normalize(server)) server = it } }
    val scanner = rememberLauncherForActivityResult(ScanContract()) { r ->
        val s = r.contents ?: return@rememberLauncherForActivityResult
        usePair = true; code = s
        error = if (runCatching { Core.pairParse(s) }.isFailure) "扫到的不是回笺配对码" else null
    }
    // 注册新账号：服务端开放注册或要邀请码时才显示（填好服务器地址后查 /v1/info 的 register）；关闭时没有注册入口。
    // 读不到 /v1/info 时注册入口照样显示，点了（或提交注册前）重新读，读到后按结果显示（Manage.registerUi）
    var reg by remember { mutableStateOf(Manage.registerUi(null)) }
    var register by rememberSaveable { mutableStateOf(false) }
    var password2 by remember { mutableStateOf("") }
    var invite by remember { mutableStateOf("") }
    /** 上次注册结果不确定（网络断了 / 超时）时的「服务器|用户名」：同一个账号再注册被拒时提示去登录 */
    var registerUnsureFor by remember { mutableStateOf<String?>(null) }
    /** 读 /v1/info，更新注册相关的显示；返回是否读到。地址在读的期间变了就丢掉结果 */
    suspend fun loadInfo(url: String): Boolean {
        val info = runCatching { withContext(Dispatchers.IO) { Api(url, null).info() } }.getOrNull()
        if (Api.normalize(server) != url) return false
        reg = Manage.registerUi(info, failed = info == null)
        return info != null
    }
    LaunchedEffect(server) {
        reg = Manage.registerUi(null)
        val url = Api.normalize(server)
        if (url.length < 8) return@LaunchedEffect
        delay(600)      // 输入停下来再查
        loadInfo(url)
    }
    val registering = reg.registering(register, usePair)
    val needInvite = reg.needInvite(registering)

    fun submit() {
        val url = Api.normalize(server)
        // 现算（不用组合时算好的值）：读完 /v1/info 再提交时注册方式可能变了（例如要邀请码）
        val registering = reg.registering(register, usePair)
        val needInvite = reg.needInvite(registering)
        when {
            url.isBlank() -> { error = "请填写服务器地址"; return }
            // 还不知道服务端的注册方式：先读 /v1/info，读不到不提交；读到后还是注册就接着提交（要邀请码时由下面的校验提示）
            reg.submitPlan(register, usePair) == RegisterUi.SubmitPlan.NEED_INFO -> {
                busy = true; error = null
                scope.launch {
                    val ok = loadInfo(url)
                    busy = false
                    if (!ok) error = Manage.INFO_UNREACHABLE
                    else if (reg.submitPlan(register, usePair) == RegisterUi.SubmitPlan.REGISTER) submit()
                }
                return
            }
            usePair && parsed == null -> { error = "配对码格式不对：应为 6 位数字，或扫码 / 复制得到的长配对码"; return }
            !usePair && (username.isBlank() || password.isEmpty()) -> { error = "请填写用户名和密码"; return }
            registering -> (Manage.usernameProblem(username) ?: Manage.passwordProblem(password, password2, required = true)
                ?: Manage.inviteProblem(reg.mode, invite))?.let { error = it; return }
        }
        busy = true; error = null; passwordError = null
        scope.launch {
            try {
                val api = Api(url, null)
                val fp = Hub.store.fingerprint()
                val dev = name.trim()
                // 账号密码登录、注册走新协议（e2ee-client.md §2）：在本机派生凭证，从不发送密码原文；Argon2id 在后台线程算
                val p = parsed
                val o = if (usePair && p != null) E2EHub.work { E2EHub.logic.pair(api, p.code, p.secret, dev, fp) { Api(url, it) } }
                else E2EHub.work {
                    // 邀请码只在要邀请码时带上；被拒（邀请码不对、用完了等）时服务端的 403 说明原样显示
                    // 服务端有 register.e2e：注册时一起开启加密（本机生成钥匙），成功后本机直接已解锁
                    if (registering) E2EHub.logic.register(api, url, Manage.normalizeUsername(username), password, dev, fp,
                        inviteCode = if (needInvite) invite else "", withKeys = reg.withKeys)
                    else E2EHub.logic.login(api, url, username.trim(), password, dev, fp) { Api(url, it) }
                }
                withContext(Dispatchers.IO) {      // Keystore 加密、同步写入，不放主线程
                    Hub.signedIn(url, o.result, if (usePair) "" else if (registering) Manage.normalizeUsername(username) else username.trim())
                    E2EHub.afterLogin(o, Api(url, o.result.token))   // 取账号 id，保存登录时顺带解开的私钥（账号已开启加密时）
                }
                password = ""; password2 = ""; code = ""; invite = ""; registerUnsureFor = null
                onSignedIn()
                Hub.setState(ConnState.Connecting)
            } catch (e: E2EError) {
                // 本地检查没通过（密码太短等）：不动「上次注册结果不确定」的标记
                if (e.kind == E2EError.Kind.WEAK_PASSWORD) passwordError = e.message else error = e.message
            } catch (e: Exception) {
                if (registering) {
                    // 注册请求可能已经到了服务器（超时、断网）：提示先登录；同一个账号上次不确定、这次被拒，多半是上次已经成功
                    val key = url + "|" + Manage.normalizeUsername(username)
                    val (msg, unsure) = E2EHub.logic.registerError(e, registerUnsureFor == key)
                    registerUnsureFor = if (unsure) key else null
                    error = msg ?: "注册失败"
                    // 403（注册关闭、邀请码问题）：注册方式可能刚变了，重新读一次 /v1/info（读不到不提示，保留上面的说明）
                    if (Manage.refetchInfoAfter(e)) launch { loadInfo(url) }
                } else error = when (e) {
                    is java.net.UnknownHostException -> "找不到服务器，请检查地址"
                    is java.net.ConnectException -> "连不上服务器"
                    else -> e.message ?: "登录失败"
                }
            } finally {
                busy = false
            }
        }
    }

    Column(
        Modifier.fillMaxSize().systemBarsPadding().imePadding().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Spacer(Modifier.height(24.dp))
        Text("回笺", fontSize = 34.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.primary)
        Text("登录你自己的回笺服务器，接收分级推送。", color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(
            server, { server = it }, Modifier.fillMaxWidth().testTag("server"),
            label = { Text("服务器地址") }, placeholder = { Text("https://push.example.com") }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next),
        )
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            SegmentedButton(!usePair, { usePair = false }, SegmentedButtonDefaults.itemShape(0, 2)) { Text("账号登录") }
            SegmentedButton(usePair, { usePair = true }, SegmentedButtonDefaults.itemShape(1, 2)) { Text("配对码") }
        }
        if (usePair) {
            OutlinedButton({
                scanner.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("对准已登录设备上「添加设备」里的二维码")
                    .setBeepEnabled(false).setOrientationLocked(true))
            }, Modifier.fillMaxWidth().testTag("scan")) { Text("扫码登录") }
            OutlinedTextField(
                code, { v -> code = v.take(400) }, Modifier.fillMaxWidth().testTag("code"),
                label = { Text("配对码") }, placeholder = { Text("6 位数字，或粘贴长配对码") },
                isError = parsed == null && code.trim().length > 6,
                supportingText = {
                    Text(when {
                        parsed?.secret != null -> "✓ 带钥匙的配对码：登录后直接解锁加密消息"
                        parsed == null && code.trim().length > 6 -> "配对码格式不对"
                        else -> "在已登录的设备上生成：手机「设置 → 账户与设备」，或 Mac「设置 → 账户」。扫二维码或输入长配对码，登录后直接解锁加密消息；只输 6 位时要再输一次密码解锁。3 分钟内有效，只能用一次"
                    })
                },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { submit() }),
            )
        } else {
            OutlinedTextField(
                username, { username = it }, Modifier.fillMaxWidth().testTag("username"),
                label = { Text("用户名") }, singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
            )
            OutlinedTextField(
                password, { password = it; passwordError = null }, Modifier.fillMaxWidth().testTag("password"),
                label = { Text("密码") }, singleLine = true, visualTransformation = PasswordVisualTransformation(),
                isError = passwordError != null,
                supportingText = passwordError?.let { { Text(it) } },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = if (registering) ImeAction.Next else ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { submit() }),
            )
            if (registering) OutlinedTextField(
                password2, { password2 = it }, Modifier.fillMaxWidth().testTag("password2"),
                label = { Text("再输入一次密码") }, singleLine = true, visualTransformation = PasswordVisualTransformation(),
                supportingText = { Text("用户名 2–32 个字（中文、字母、数字、空格、_ . -）；密码至少 10 位，不要用常见密码") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = if (needInvite) ImeAction.Next else ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { submit() }),
            )
            if (needInvite) OutlinedTextField(
                invite, { invite = it.take(64) }, Modifier.fillMaxWidth().testTag("inviteCode"),
                label = { Text("邀请码") }, singleLine = true,
                supportingText = { Text("这台服务器注册需要邀请码，向服务器管理员索取") },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { submit() }),
            )
            // 读到了服务端信息、注册已关闭：不给注册入口，说明一句（没读到时不显示，免得把连不上说成没开放）
            reg.closedNote?.let { Text(it, Modifier.testTag("registerClosed"), fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            if (reg.entryVisible(register)) TextButton({
                when (reg.onEntryTap(register)) {
                    RegisterUi.EntryTap.TOGGLE -> { register = !register; error = null }
                    // 没读到 /v1/info：先重新读，读到且允许注册才切到注册；读不到提示连不上
                    RegisterUi.EntryTap.FETCH_INFO -> {
                        val url = Api.normalize(server)
                        error = null
                        scope.launch {
                            if (!loadInfo(url)) error = Manage.INFO_UNREACHABLE
                            else if (reg.showEntry) register = true
                        }
                    }
                }
            }, Modifier.testTag("toggleRegister")) {
                Text(if (register) "已有账号？直接登录" else "没有账号？注册新账号")
            }
        }
        OutlinedTextField(
            name, { name = it.take(40) }, Modifier.fillMaxWidth().testTag("deviceName"),
            label = { Text("这台设备的名称") }, singleLine = true,
        )
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Button(::submit, Modifier.fillMaxWidth().height(50.dp).testTag("login"), enabled = !busy) {
            if (busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            else Text(if (usePair) "配对" else if (registering) "注册并登录" else "登录")
        }
    }
}
