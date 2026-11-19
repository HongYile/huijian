package io.github.hongyile.huijian

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.hongyile.huijian.ui.AccountScreen
import io.github.hongyile.huijian.ui.ChannelsScreen
import io.github.hongyile.huijian.ui.DetailScreen
import io.github.hongyile.huijian.ui.E2EScreen
import io.github.hongyile.huijian.ui.KeysScreen
import io.github.hongyile.huijian.ui.HomeScreen
import io.github.hongyile.huijian.ui.HuijianTheme
import io.github.hongyile.huijian.ui.LoginScreen
import io.github.hongyile.huijian.ui.SettingsScreen

sealed interface Screen {
    data object Home : Screen
    /** from：从哪条消息的 huijian://message/<id> 链接跳过来，返回时回到那条（只记一层） */
    data class Detail(val id: Long, val from: Long? = null) : Screen
    data object Settings : Screen
    /** 设置里的管理页：Pushkey、账户与设备、频道（返回到设置） */
    data object Keys : Screen
    data object Account : Screen
    data object Channels : Screen
    /** 设置 → 端到端加密 */
    data object E2E : Screen

    fun encode() = when (this) {
        Home -> "home"; Settings -> "settings"; Keys -> "keys"; Account -> "account"; Channels -> "channels"; E2E -> "e2e"
        is Detail -> "detail:$id" + (from?.let { ":$it" } ?: "")
    }

    companion object {
        fun decode(s: String): Screen = when {
            s == "settings" -> Settings
            s == "keys" -> Keys
            s == "account" -> Account
            s == "channels" -> Channels
            s == "e2e" -> E2E
            s.startsWith("detail:") -> s.removePrefix("detail:").split(":").let { p ->
                p[0].toLongOrNull()?.let { Detail(it, p.getOrNull(1)?.toLongOrNull()) } ?: Home
            }
            else -> Home
        }
    }
}

class MainActivity : ComponentActivity() {
    private var screen by mutableStateOf<Screen>(Screen.Home)

    private val askNotify = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        // 拒绝过两次后系统不再弹窗、直接返回 false：这时改为打开通知设置
        if (!granted && Build.VERSION.SDK_INT >= 33 && !shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)) {
            Background.openAppNotificationSettings(this)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Hub.init(this)
        if (Hub.loggedIn && savedInstanceState == null) SyncService.start(this)   // 旋转屏幕重建时不重复触发
        val saved = savedInstanceState?.getString(KEY_SCREEN)
        if (saved != null) screen = Screen.decode(saved) else handle(intent)
        setContent {
            HuijianTheme {
                val state by Hub.state.collectAsStateWithLifecycle()
                // 每条消息的详情页各存一份界面状态（滚动位置等）：A 跳到 B 时 B 从头开始，返回 A 时回到 A 原来的位置
                val details = rememberSaveableStateHolder()
                if (state == ConnState.LoggedOut) {
                    LoginScreen(onSignedIn = {
                        SyncService.start(this, restart = true)
                        requestNotificationPermission()
                        screen = Screen.Settings      // 登录后先去「后台运行检查」把权限设好
                    })
                } else {
                    // 有没点「完成」的恢复码（开启加密后 App 被终止、刷新时才确认开启成功等）：回到「保存恢复码」页（§4.1）
                    val recovery by E2EHub.pendingRecovery.collectAsStateWithLifecycle()
                    LaunchedEffect(recovery != null) { if (recovery != null && screen != Screen.E2E) screen = Screen.E2E }
                    when (val s = screen) {
                        Screen.Home -> HomeScreen(
                            open = { screen = Screen.Detail(it) },
                            openSettings = { screen = Screen.Settings },
                            openE2E = { screen = Screen.E2E },
                        )
                        is Screen.Detail -> {
                            val back = { screen = s.from?.let { Screen.Detail(it) } ?: Screen.Home }
                            BackHandler(onBack = back)
                            details.SaveableStateProvider("detail:${s.id}") {      // 按 id 区分，不同消息不共用 remember 的状态
                                DetailScreen(s.id, back = back, openMessage = { if (it != s.id) screen = Screen.Detail(it, from = s.id) })
                            }
                        }
                        Screen.Settings -> {
                            BackHandler { screen = Screen.Home }
                            SettingsScreen(
                                back = { screen = Screen.Home },
                                requestNotify = ::requestNotificationPermission,
                                open = { screen = it },
                            )
                        }
                        Screen.E2E -> {
                            val toSettings = { screen = Screen.Settings }
                            BackHandler(onBack = toSettings)        // 加密页里的子页面有自己的返回处理（后注册的优先）
                            E2EScreen(toSettings, openKeys = { screen = Screen.Keys })
                        }
                        Screen.Keys, Screen.Account, Screen.Channels -> {
                            val toSettings = { screen = Screen.Settings }
                            BackHandler(onBack = toSettings)
                            when (s) {
                                Screen.Keys -> KeysScreen(toSettings)
                                Screen.Account -> AccountScreen(toSettings)
                                else -> ChannelsScreen(toSettings)
                            }
                        }
                    }
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // 回到前台：重新读取加密状态（§3）
        if (Hub.loggedIn) E2EHub.refreshAsync()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString(KEY_SCREEN, screen.encode())
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
    }

    /** 点通知打开对应消息 */
    private fun handle(i: Intent?) {
        val id = i?.getLongExtra(Notifier.EXTRA_MESSAGE_ID, -1L) ?: -1L
        if (id > 0) screen = Screen.Detail(id)
        else if (i?.getBooleanExtra(Notifier.EXTRA_OPEN_E2E, false) == true) screen = Screen.E2E
    }

    private fun requestNotificationPermission() {
        if (Notifier.canPost(this)) return
        val granted = Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == android.content.pm.PackageManager.PERMISSION_GRANTED
        // 有权限但在系统设置里关了通知：请求权限会直接返回「已授予」，只能打开设置
        if (granted) Background.openAppNotificationSettings(this) else askNotify.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    private companion object { const val KEY_SCREEN = "screen" }
}
