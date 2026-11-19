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
import io.github.hongyile.huijian.Hub
import io.github.hongyile.huijian.Manage
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun LoginScreen(onSignedIn: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var server by rememberSaveable { mutableStateOf(Hub.store.server.ifBlank { BuildConfig.DEFAULT_SERVER }) }
    var usePair by rememberSaveable { mutableStateOf(false) }
    var username by rememberSaveable { mutableStateOf(Hub.store.username) }
    var password by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    val defaultName = remember(ctx) {
        Settings.Global.getString(ctx.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: "${Build.MANUFACTURER} ${Build.MODEL}"
    }
    var name by rememberSaveable { mutableStateOf(defaultName) }
    var busy by rememberSaveable { mutableStateOf(false) }
    var error by rememberSaveable { mutableStateOf<String?>(null) }
    // 注册新账号：服务端开放注册时才显示（填好服务器地址后查 /v1/info）
    var registerOpen by remember { mutableStateOf(false) }
    var register by rememberSaveable { mutableStateOf(false) }
    var password2 by rememberSaveable { mutableStateOf("") }
    LaunchedEffect(server) {
        registerOpen = false
        val url = Api.normalize(server)
        if (url.length < 8) return@LaunchedEffect
        delay(600)      // 输入停下来再查
        registerOpen = runCatching { withContext(Dispatchers.IO) { Api(url, null).info().optBoolean("register_open") } }.getOrDefault(false)
    }
    val registering = register && registerOpen && !usePair

    fun submit() {
        val url = Api.normalize(server)
        when {
            url.isBlank() -> { error = "请填写服务器地址"; return }
            usePair && !code.trim().matches(Regex("\\d{6}")) -> { error = "配对码是 6 位数字"; return }
            !usePair && (username.isBlank() || password.isEmpty()) -> { error = "请填写用户名和密码"; return }
            registering -> (Manage.usernameProblem(username) ?: Manage.passwordProblem(password, password2, required = true))?.let { error = it; return }
        }
        busy = true; error = null
        scope.launch {
            try {
                val api = Api(url, null)
                val fp = Hub.store.fingerprint()
                val r = withContext(Dispatchers.IO) {
                    if (usePair) api.pair(code.trim(), name.trim(), fp)
                    else api.login(if (registering) Manage.normalizeUsername(username) else username.trim(), password, name.trim(), fp, register = registering)
                }
                withContext(Dispatchers.IO) { Hub.signedIn(url, r, if (usePair) "" else username.trim()) }  // Keystore 加密、同步写入，不放主线程
                password = ""; password2 = ""; code = ""
                onSignedIn()
                Hub.setState(ConnState.Connecting)
            } catch (e: Exception) {
                error = when (e) {
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
            OutlinedTextField(
                code, { v -> code = v.filter { it.isDigit() }.take(6) }, Modifier.fillMaxWidth().testTag("code"),
                label = { Text("6 位配对码") }, singleLine = true,
                supportingText = { Text("在已登录的设备上生成：手机「设置 → 账户与设备」，或 Mac 客户端点左下角头像 → 账户（3 分钟内有效，只能用一次）") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { submit() }),
            )
        } else {
            OutlinedTextField(
                username, { username = it }, Modifier.fillMaxWidth().testTag("username"),
                label = { Text("用户名") }, singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
            )
            OutlinedTextField(
                password, { password = it }, Modifier.fillMaxWidth().testTag("password"),
                label = { Text("密码") }, singleLine = true, visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = if (registering) ImeAction.Next else ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { submit() }),
            )
            if (registering) OutlinedTextField(
                password2, { password2 = it }, Modifier.fillMaxWidth().testTag("password2"),
                label = { Text("再输入一次密码") }, singleLine = true, visualTransformation = PasswordVisualTransformation(),
                supportingText = { Text("用户名 2–32 个字（中文、字母、数字、空格、_ . -），密码至少 8 位") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { submit() }),
            )
            if (registerOpen) TextButton({ register = !register; error = null }, Modifier.testTag("toggleRegister")) {
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
