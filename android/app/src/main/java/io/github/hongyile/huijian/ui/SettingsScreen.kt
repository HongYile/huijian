@file:OptIn(ExperimentalMaterial3Api::class)

package io.github.hongyile.huijian.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.hongyile.huijian.Background
import io.github.hongyile.huijian.BuildConfig
import io.github.hongyile.huijian.Hub
import io.github.hongyile.huijian.Notifier
import io.github.hongyile.huijian.ReceiveMode
import io.github.hongyile.huijian.Screen
import io.github.hongyile.huijian.SyncService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalTime
import java.time.format.DateTimeFormatter

private val OK = Color(0xFF3C8D5A)

@Composable
fun SettingsScreen(back: () -> Unit, requestNotify: () -> Unit, open: (Screen) -> Unit = {}) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val state by Hub.state.collectAsStateWithLifecycle()
    val lastContact by Hub.lastContact.collectAsStateWithLifecycle()
    val store = Hub.store
    var mode by remember { mutableStateOf(store.mode) }
    var interval by remember { mutableIntStateOf(store.intervalMin) }
    var tick by remember { mutableIntStateOf(0) }
    LifecycleResumeEffect(Unit) { tick++; onPauseOrDispose { } }
    LaunchedEffect(Unit) { while (true) { delay(1000); tick++ } }
    val notifyOk = remember(tick) { Notifier.canPost(ctx) }
    val batteryOk = remember(tick) { Background.ignoringBatteryOptimizations(ctx) }
    val dndOk = remember(tick) { Background.canBypassDnd(ctx) }
    // 勿扰权限是建渠道之后才给的：重新建一次渠道，P5 的「穿透勿扰」才会生效（用户没改过该渠道时系统允许更新）
    LaunchedEffect(dndOk) { if (dndOk) Notifier.setup(ctx) }
    var testMsg by remember { mutableStateOf<String?>(null) }
    var confirmLogout by remember { mutableStateOf(false) }

    fun applyMode(m: ReceiveMode, min: Int) {
        mode = m; interval = min
        store.mode = m; store.intervalMin = min
        SyncService.start(ctx, restart = true)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("设置") },
                navigationIcon = { IconButton(back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { pad ->
        Column(
            Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 14.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Card("后台运行检查", "锁屏后还能准时收到消息，靠的是上面这几项。小米、华为等手机还要手动打开「自启动」：没开的话，回笺被系统清理后不会自己恢复。") {
                Check("通知权限", notifyOk, "去开启", Modifier.testTag("fixNotify")) { requestNotify() }
                Check("不受电池优化限制", batteryOk, "去设置", Modifier.testTag("fixBattery")) { Background.requestIgnoreBatteryOptimizations(ctx) }
                Check("P5 紧急消息穿透勿扰（可选）", dndOk, "去授权") { Background.openDndAccess(ctx) }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("自启动 / 锁定后台", Modifier.weight(1f))
                    OutlinedButton({ Background.openAutoStart(ctx) }) { Text("去设置") }
                }
                for (s in Background.manualSteps()) Text("· $s", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                Info("连接状态", stateText(state), stateColor(state), Modifier.testTag("settingsState"))
                Info("最后一次和服务器通信", remember(lastContact, tick) { ago(lastContact) })
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(testMsg ?: "给自己发一条 P4 测试推送，看多久能收到", Modifier.weight(1f), fontSize = 13.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.width(8.dp))
                    Button({
                        testMsg = "发送中…"
                        scope.launch {
                            testMsg = try {
                                withContext(Dispatchers.IO) { sendTest() }
                                "已发送 " + LocalTime.now().format(DateTimeFormatter.ofPattern("HH:mm:ss")) + "，等通知弹出"
                            } catch (e: Exception) { "发送失败：${e.message}" }
                        }
                    }, Modifier.testTag("sendTest")) { Text("测试推送") }
                }
            }

            Card("接收方式", "实时：一直保持连接，消息秒到；定时：每隔一段时间检查一次，更省电，但消息会晚一个间隔左右（检查时间由系统安排，可能再晚几分钟）。两种方式都会在通知栏常驻一条「回笺」。") {
                Radio("实时接收（推荐）", mode == ReceiveMode.REALTIME, Modifier.testTag("modeRealtime")) { applyMode(ReceiveMode.REALTIME, interval) }
                Radio("定时检查", mode == ReceiveMode.INTERVAL, Modifier.testTag("modeInterval")) { applyMode(ReceiveMode.INTERVAL, interval) }
                if (mode == ReceiveMode.INTERVAL) {
                    Row(Modifier.padding(start = 40.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        for (n in ReceiveMode.intervalOptions) FilterChip(interval == n, { applyMode(ReceiveMode.INTERVAL, n) }, { Text("$n 分钟") })
                    }
                }
            }

            Card("管理", "pushkey、设备和频道属于账号，在这里改和在 Mac 上改效果一样。") {
                NavRow("Pushkey", "新建、改名、换 key、吊销，发送示例", Modifier.testTag("openKeys")) { open(Screen.Keys) }
                HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                NavRow("账户与设备", "用户名和密码、配对码、我的设备", Modifier.testTag("openAccount")) { open(Screen.Account) }
                HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                NavRow("频道", "显示名、排序、置顶、静音、隐藏、删除", Modifier.testTag("openChannels")) { open(Screen.Channels) }
            }

            Card("账号", null) {
                Info("用户", store.username.ifBlank { "（配对码登录）" })
                Info("服务器", store.server)
                Info("本机", store.deviceName)
                Info("设备 ID", store.deviceId)
                TextButton({ confirmLogout = true }, Modifier.testTag("logout")) { Text("退出登录", color = MaterialTheme.colorScheme.error) }
            }

            Card("关于", null) {
                Info("版本", "${BuildConfig.VERSION_NAME} (build ${BuildConfig.VERSION_CODE})")
                Info("许可", "AGPL-3.0 · github.com/HongYile/huijian")
            }
            Spacer(Modifier.width(1.dp))
        }
    }

    if (confirmLogout) {
        AlertDialog(
            onDismissRequest = { confirmLogout = false },
            title = { Text("退出登录？") },
            text = { Text("这台手机将不再接收消息，本地消息记录会清除。") },
            confirmButton = {
                TextButton({
                    confirmLogout = false
                    Hub.logout(ctx, notifyServer = true)
                }) { Text("退出", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton({ confirmLogout = false }) { Text("取消") } },
        )
    }
}

/** 用本账号第一把有效的 pushkey 发一条 P4；账号还没有 key 时新建一把 default */
private fun sendTest() {
    val api = Hub.api() ?: error("未登录")
    val key = api.keys().firstOrNull { !it.revoked }?.key ?: api.createKey("default").key
    val now = LocalTime.now().format(DateTimeFormatter.ofPattern("HH:mm:ss"))
    api.push(key, "测试推送 $now", "来自「${Hub.store.deviceName}」的测试，发送于 **$now**。", 4, "test")
}

@Composable
private fun Card(title: String, footer: String?, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 4.dp, top = 6.dp))
        Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surface, tonalElevation = 1.dp) {
            Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp), content = content)
        }
        footer?.let { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 4.dp)) }
    }
}

@Composable
private fun Check(label: String, ok: Boolean, fix: String, modifier: Modifier = Modifier, onFix: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(if (ok) "✓" else "✗", color = if (ok) OK else MaterialTheme.colorScheme.error, fontWeight = FontWeight.Bold,
            modifier = Modifier.width(22.dp))
        Text(label, Modifier.weight(1f))
        if (ok) Text("已开启", color = OK, fontSize = 13.sp) else OutlinedButton(onFix, modifier) { Text(fix) }
    }
}

@Composable
private fun NavRow(title: String, sub: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Row(modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            Text(sub, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun Info(label: String, value: String, color: Color = Color.Unspecified, modifier: Modifier = Modifier) {
    Row {
        Text(label, Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 14.sp)
        Text(value, modifier, color = if (color == Color.Unspecified) MaterialTheme.colorScheme.onSurface else color, fontSize = 14.sp)
    }
}

@Composable
private fun Radio(label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Row(modifier.fillMaxWidth().clickable(onClick = onClick), verticalAlignment = Alignment.CenterVertically) {
        RadioButton(selected, onClick)
        Text(label)
    }
}
