package io.github.hongyile.huijian.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import io.github.hongyile.huijian.ConnState
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

// 和 Mac 客户端一致的靛蓝主色、米白底
private val Light = lightColorScheme(
    primary = Color(0xFF4A5BA8), onPrimary = Color.White,
    primaryContainer = Color(0xFFDDE1F5), onPrimaryContainer = Color(0xFF1E2A5E),
    secondary = Color(0xFF5B6386), secondaryContainer = Color(0xFFDDE1F5), onSecondaryContainer = Color(0xFF1E2A5E),
    background = Color(0xFFF6F4EF), surface = Color(0xFFFBFAF7),
    surfaceVariant = Color(0xFFEDEAE3), onSurfaceVariant = Color(0xFF5E5B55),
    error = Color(0xFFC0392B),
)
private val Dark = darkColorScheme(
    primary = Color(0xFFAEB9F0), onPrimary = Color(0xFF16204D),
    primaryContainer = Color(0xFF323F7C), onPrimaryContainer = Color(0xFFDDE1F5),
    secondary = Color(0xFFBEC4E6), secondaryContainer = Color(0xFF323F7C), onSecondaryContainer = Color(0xFFDDE1F5),
    background = Color(0xFF1C1B19), surface = Color(0xFF242320),
    surfaceVariant = Color(0xFF34322E), onSurfaceVariant = Color(0xFFC9C5BC),
    error = Color(0xFFFF8A7A),
)

@Composable
fun HuijianTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) Dark else Light, content = content)
}

fun priorityColor(p: Int): Color = when (p) {
    5 -> Color(0xFFC0392B)
    4 -> Color(0xFFE67E22)
    3 -> Color(0xFF4A6FD6)
    2 -> Color(0xFF8E8A82)
    else -> Color(0xFFB9B4AA)
}

private val hm = DateTimeFormatter.ofPattern("HH:mm")
private val mdhm = DateTimeFormatter.ofPattern("MM-dd HH:mm")
private val full = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")

fun relTime(t: Instant, now: Instant = Instant.now()): String {
    val d = Duration.between(t, now)
    val local = t.atZone(ZoneId.systemDefault())
    return when {
        d.seconds < 60 -> "刚刚"
        d.toMinutes() < 60 -> "${d.toMinutes()} 分钟前"
        local.toLocalDate() == LocalDate.now() -> hm.format(local)
        else -> mdhm.format(local)
    }
}

fun fullTime(t: Instant): String = full.format(t.atZone(ZoneId.systemDefault()))

fun ago(ms: Long): String {
    if (ms <= 0) return "还没有"
    val s = (System.currentTimeMillis() - ms) / 1000
    return when {
        s < 5 -> "刚刚"
        s < 60 -> "$s 秒前"
        s < 3600 -> "${s / 60} 分钟前"
        else -> "${s / 3600} 小时前"
    }
}

fun stateText(s: ConnState): String = when (s) {
    ConnState.LoggedOut -> "未登录"
    ConnState.Connecting -> "正在连接…"
    ConnState.Connected -> "已连接 · 实时接收"
    is ConnState.Waiting -> "定时检查 · 下次约 " + hm.format(Instant.ofEpochMilli(s.nextCheckAt).atZone(ZoneId.systemDefault()))
    is ConnState.Reconnecting -> "重连中 · ${s.reason}"
    ConnState.Unauthorized -> "登录已失效"
}

fun sizeText(n: Long): String = when {
    n < 1024 -> "$n B"
    n < 1024 * 1024 -> "%.0f KB".format(n / 1024.0)
    else -> "%.1f MB".format(n / 1024.0 / 1024.0)
}
