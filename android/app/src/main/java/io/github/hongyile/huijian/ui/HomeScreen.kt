@file:OptIn(ExperimentalMaterial3Api::class)

package io.github.hongyile.huijian.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Done
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.hongyile.huijian.Background
import io.github.hongyile.huijian.ConnState
import io.github.hongyile.huijian.Hub
import io.github.hongyile.huijian.Manage
import io.github.hongyile.huijian.SyncService
import io.github.hongyile.huijian.Message
import io.github.hongyile.huijian.Notifier
import kotlinx.coroutines.delay

private enum class Filter(val label: String) { ALL("全部"), UNREAD("未读"), IMPORTANT("重要") }

@Composable
fun HomeScreen(open: (Long) -> Unit, openSettings: () -> Unit) {
    val ctx = LocalContext.current
    val messages by Hub.messages.collectAsStateWithLifecycle()
    val read by Hub.read.collectAsStateWithLifecycle()
    val state by Hub.state.collectAsStateWithLifecycle()
    val channels by Hub.channels.collectAsStateWithLifecycle()
    var filter by rememberSaveable { mutableStateOf(Filter.ALL) }
    var topic by rememberSaveable { mutableStateOf<String?>(null) }
    // 回到前台时重新检查权限（用户可能刚去系统设置里改过）
    var resumeTick by remember { mutableIntStateOf(0) }
    LifecycleResumeEffect(Unit) { resumeTick++; onPauseOrDispose { } }
    val setupOk = remember(resumeTick) { Notifier.canPost(ctx) && Background.ignoringBatteryOptimizations(ctx) }
    // 每 30 秒刷新一次相对时间
    var clock by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) { while (true) { delay(30_000); clock++ } }

    val visible = remember(messages, channels) {
        messages.filter { !Hub.isHidden(it.topic) && it.archive != 1 }.asReversed()
    }
    // 频道顺序和 Mac 一致：置顶在前，再按手动顺序，其余按最近活跃
    val topics = remember(visible, topic, channels) {
        val last = HashMap<String, Long>()
        for (m in visible) last[m.topic] = maxOf(last[m.topic] ?: 0, m.id)
        Manage.orderChannels((visible.map { it.topic } + listOfNotNull(topic)).distinct(), channels, last)
    }
    val shown = remember(visible, read, filter, topic) {
        visible.filter { m ->
            (topic == null || m.topic == topic) && when (filter) {
                Filter.ALL -> true
                Filter.UNREAD -> m.id !in read
                Filter.IMPORTANT -> m.priority >= 4
            }
        }
    }
    val unread = visible.count { it.id !in read && it.priority >= 2 }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(if (unread > 0) "回笺 · $unread 未读" else "回笺", fontWeight = FontWeight.SemiBold)
                        Text(stateText(state), fontSize = 12.sp, color = stateColor(state), modifier = Modifier.testTag("connState"))
                    }
                },
                actions = {
                    IconButton({ Hub.markAllRead(); Notifier.cancelMessages(ctx) }) { Icon(Icons.Default.Done, "全部已读") }
                    IconButton(openSettings, Modifier.testTag("settings")) { Icon(Icons.Default.Settings, "设置") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            if (state == ConnState.Unauthorized) {
                Banner("登录已失效（设备可能已被移除），请重新登录", "重新登录") {
                    Hub.logout(ctx, notifyServer = false)
                }
            } else if (!setupOk) {
                Banner("后台运行还没设置好，锁屏后可能收不到消息", "去设置", openSettings)
            }
            LazyRow(contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(Filter.entries) { f -> FilterChip(filter == f, { filter = f }, { Text(f.label) }) }
                items(topics) { t ->
                    FilterChip(topic == t, { topic = if (topic == t) null else t }, { Text("# " + Hub.channelName(t)) })
                }
            }
            if (shown.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(
                        if (messages.isEmpty()) "还没有消息\n在「设置」里可以给自己发一条测试推送" else "没有符合条件的消息",
                        color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 15.sp,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )
                }
            } else {
                LazyColumn(Modifier.fillMaxSize().testTag("messageList")) {
                    items(shown, key = { it.id }) { m ->
                        // 频道显示名从这里传进去：频道设置变了（包括别的设备改的）消息行跟着更新
                        val ch = channels[m.topic]?.alias?.takeIf { it.isNotBlank() } ?: m.topic
                        MessageRow(m, ch, unread = m.id !in read, clock = clock) { open(m.id) }
                        HorizontalDivider(Modifier.padding(start = 30.dp), color = MaterialTheme.colorScheme.surfaceVariant)
                    }
                }
            }
        }
    }
}

@Composable
private fun MessageRow(m: Message, channel: String, unread: Boolean, clock: Int, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 11.dp)) {
        Box(Modifier.padding(top = 6.dp).size(9.dp).clip(CircleShape)
            .background(if (unread) priorityColor(m.priority) else MaterialTheme.colorScheme.surfaceVariant))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    m.title, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis,
                    fontWeight = if (unread) FontWeight.SemiBold else FontWeight.Normal, fontSize = 16.sp,
                    color = if (m.priority >= 5) priorityColor(5) else MaterialTheme.colorScheme.onSurface,
                )
                Text(remember(m.createdAt, clock) { relTime(m.createdAt) }, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            val preview = remember(m.id, m.preview, m.desp) { m.summary().replace("\n", " ") }
            if (preview.isNotBlank()) {
                Text(preview, maxLines = 2, overflow = TextOverflow.Ellipsis, fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            val meta = buildList {
                add("# $channel")
                if (m.thread.isNotBlank()) add(m.thread)
                if (m.attachments.isNotEmpty()) add("附件 ${m.attachments.size}")
                if (m.silent) add("静默")
            }.joinToString(" · ")
            Text(meta, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f))
        }
    }
}

@Composable
private fun Banner(text: String, action: String, onClick: () -> Unit) {
    Surface(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
        shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.primaryContainer,
    ) {
        Row(Modifier.padding(start = 12.dp, end = 4.dp, top = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Warning, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onPrimaryContainer)
            Spacer(Modifier.width(8.dp))
            Text(text, Modifier.weight(1f), fontSize = 13.sp, color = MaterialTheme.colorScheme.onPrimaryContainer)
            TextButton(onClick) { Text(action) }
        }
    }
}

@Composable
fun stateColor(s: ConnState) = when (s) {
    ConnState.Connected, is ConnState.Waiting -> androidx.compose.ui.graphics.Color(0xFF3C8D5A)
    is ConnState.Reconnecting, ConnState.Unauthorized -> MaterialTheme.colorScheme.error
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}

@Composable
fun Spacer8() = Spacer(Modifier.height(8.dp))
