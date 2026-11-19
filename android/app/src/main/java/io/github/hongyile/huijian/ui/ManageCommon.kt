@file:OptIn(ExperimentalMaterial3Api::class)

package io.github.hongyile.huijian.ui

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.hongyile.huijian.Api
import io.github.hongyile.huijian.ApiException
import io.github.hongyile.huijian.Hub
import io.github.hongyile.huijian.UnauthorizedException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/*
 * 管理页（Pushkey、账户与设备、频道）共用的界面零件和工具。
 */

val SUCCESS = Color(0xFF3C8D5A)
val WARNING = Color(0xFFD9822B)

/** 管理页的外壳：顶栏 + 返回 + 可滚动内容 + 底部提示条 */
@Composable
fun ManageScaffold(
    title: String,
    back: () -> Unit,
    snackbar: SnackbarHostState,
    actions: @Composable () -> Unit = {},
    content: @Composable ColumnScope.() -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = { IconButton(back) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                actions = { actions() },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { pad ->
        Column(
            Modifier.padding(pad).fillMaxSize().imePadding().verticalScroll(rememberScrollState()).padding(horizontal = 14.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            content()
            Spacer(Modifier.height(24.dp))
        }
    }
}

/** 带标题和脚注的分组卡片（和设置页同一风格） */
@Composable
fun SectionCard(title: String?, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        title?.let {
            Text(it, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 4.dp, top = 6.dp))
        }
        Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surface, tonalElevation = 1.dp) {
            Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp), content = content)
        }
        footer?.let { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 4.dp)) }
    }
}

/** 小标签（有效、已吊销、本机、在线……） */
@Composable
fun Tag(text: String, color: Color) {
    Surface(shape = RoundedCornerShape(50), color = color.copy(alpha = 0.13f)) {
        Text(text, Modifier.padding(horizontal = 7.dp, vertical = 1.dp), fontSize = 11.sp, color = color, fontWeight = FontWeight.Medium)
    }
}

/** 危险操作的二次确认 */
@Composable
fun ConfirmDialog(title: String, text: String, confirm: String, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(text) },
        confirmButton = { TextButton({ onDismiss(); onConfirm() }) { Text(confirm, color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onDismiss) { Text("取消") } },
    )
}

/** 错误说明：服务端给了说明（例如权限不足）就直接显示；旧服务端没有接口时提示更新 */
fun describe(e: Throwable): String = when (e) {
    is UnauthorizedException -> e.message ?: "登录已失效"
    is ApiException -> if (e.oldServer) Api.OLD_SERVER else (e.message ?: "HTTP ${e.status}")
    is java.net.UnknownHostException -> "找不到服务器，请检查网络"
    is java.net.ConnectException, is java.net.SocketTimeoutException -> "连不上服务器"
    else -> e.message ?: e.javaClass.simpleName
}

/** 在 IO 线程调用接口；没登录时报错 */
suspend fun <T> api(block: (Api) -> T): T = withContext(Dispatchers.IO) {
    block(Hub.api() ?: throw java.io.IOException("未登录"))
}

/** sensitive：标为敏感内容（pushkey 等），系统的复制提示和剪贴板预览里不显示原文 */
fun copyText(ctx: Context, label: String, text: String, sensitive: Boolean = false) {
    val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    val clip = ClipData.newPlainText(label, text)
    if (sensitive) clip.description.extras = PersistableBundle().apply {
        putBoolean(if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE", true)
    }
    cm.setPrimaryClip(clip)
    if (Build.VERSION.SDK_INT < 33) Toast.makeText(ctx, "已复制", Toast.LENGTH_SHORT).show()     // 13 起系统自己提示
}

private val ymdhm = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")

fun epochText(sec: Long): String = if (sec <= 0) "—" else ymdhm.format(Instant.ofEpochSecond(sec).atZone(ZoneId.systemDefault()))

fun rfcText(s: String?): String? = s?.let { runCatching { relTime(Instant.parse(it)) }.getOrNull() }

val ZeroPadding = PaddingValues(0.dp)
