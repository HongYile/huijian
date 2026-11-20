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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Done
import androidx.compose.material.icons.filled.Lock
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.platform.LocalDensity
import kotlinx.coroutines.launch
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
import io.github.hongyile.huijian.E2EHub
import io.github.hongyile.huijian.E2EStatus
import io.github.hongyile.huijian.E2EText
import io.github.hongyile.huijian.Hub
import io.github.hongyile.huijian.Manage
import io.github.hongyile.huijian.SyncService
import io.github.hongyile.huijian.Message
import io.github.hongyile.huijian.Notifier
import kotlinx.coroutines.delay

private enum class Filter(val label: String) { ALL("全部"), UNREAD("未读"), IMPORTANT("重要") }

@Composable
fun HomeScreen(open: (Long) -> Unit, openSettings: () -> Unit, openE2E: () -> Unit = {}) {
    val ctx = LocalContext.current
    val messages by Hub.messages.collectAsStateWithLifecycle()
    val read by Hub.read.collectAsStateWithLifecycle()
    val state by Hub.state.collectAsStateWithLifecycle()
    val channels by Hub.channels.collectAsStateWithLifecycle()
    val e2eStatus by E2EHub.status.collectAsStateWithLifecycle()
    val e2eState by E2EHub.state.collectAsStateWithLifecycle()
    /** 账号已开启加密：明文消息标「未加密」 */
    val e2eOn = e2eState?.enabled == true
    var filter by rememberSaveable { mutableStateOf(Filter.ALL) }
    var topic by rememberSaveable { mutableStateOf<String?>(null) }
    // 回到前台时重新检查权限（用户可能刚去系统设置里改过）
    var resumeTick by remember { mutableIntStateOf(0) }
    LifecycleResumeEffect(Unit) { resumeTick++; onPauseOrDispose { } }
    // 回到前台时重新检查：在系统设置里开了通知，提示条自动消失
    val notifyOk = remember(resumeTick) { Notifier.canPost(ctx) }
    val setupOk = remember(resumeTick) { Background.ignoringBatteryOptimizations(ctx) }
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

    // 新消息到达（列表按 id 作 key，插到最前面时会停在原来的第一条上，新消息跑到可见区上方）：
    // 已在顶部 → 自动滚到最上面；不在顶部 → 显示「有 N 条新消息」，点了滚到顶部，自己滚到顶部后消失
    val listState = rememberLazyListState()
    val listScope = rememberCoroutineScope()
    val slop = with(LocalDensity.current) { NewMessages.TOP_SLOP_DP.dp.roundToPx() }
    var newCount by remember { mutableIntStateOf(0) }
    var prevTop by remember { mutableStateOf<Long?>(null) }
    var prevView by remember { mutableStateOf(filter to topic) }
    LaunchedEffect(shown.firstOrNull()?.id, filter, topic) {
        val top = shown.firstOrNull()?.id
        val view = filter to topic
        if (view != prevView) {
            // 切换筛选 / 频道：不是新消息，重新开始计数
            prevView = view; prevTop = top; newCount = 0
            return@LaunchedEffect
        }
        val arrived = NewMessages.arrived(prevTop, shown.map { it.id })
        val first = listState.layoutInfo.visibleItemsInfo.firstOrNull()
        val wasAtTop = NewMessages.wasAtTop(prevTop, first?.key, listState.firstVisibleItemScrollOffset, slop)
        prevTop = top
        if (arrived == 0) return@LaunchedEffect
        if (wasAtTop) { newCount = 0; listState.animateScrollToItem(0) } else newCount += arrived
    }
    // 自己滚到顶部：提示消失
    LaunchedEffect(listState) {
        snapshotFlow { listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset <= slop }
            .collect { if (it) newCount = 0 }
    }

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
                    Hub.logout(ctx, notifyServer = false, keepE2EKeys = true)   // 同一台设备重新登录后加密私钥还能用
                }
            } else if (!notifyOk) {
                // 通知被关掉（拒绝过权限、或在系统设置里关了）：不自动跳转，点提示条才进系统的通知设置
                Banner("通知已关闭，点这里开启", null, Modifier.testTag("notifyOff")) { Background.openAppNotificationSettings(ctx) }
            } else if (!setupOk) {
                Banner("后台运行还没设置好，锁屏后可能收不到消息", "去设置", onClick = openSettings)
            }
            if (state != ConnState.Unauthorized && e2eStatus == E2EStatus.LOCKED) {
                LockBanner(openE2E)
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
                Box(Modifier.fillMaxSize()) {
                    LazyColumn(Modifier.fillMaxSize().testTag("messageList"), state = listState) {
                        items(shown, key = { it.id }) { m ->
                            // 频道显示名从这里传进去：频道设置变了（包括别的设备改的）消息行跟着更新
                            val ch = channels[m.topic]?.alias?.takeIf { it.isNotBlank() } ?: m.topic
                            MessageRow(m, ch, unread = m.id !in read, clock = clock, e2eOn = e2eOn) { open(m.id) }
                            HorizontalDivider(Modifier.padding(start = 30.dp), color = MaterialTheme.colorScheme.surfaceVariant)
                        }
                    }
                    if (newCount > 0) Surface(
                        onClick = { newCount = 0; listScope.launch { listState.animateScrollToItem(0) } },
                        modifier = Modifier.align(Alignment.TopCenter).padding(top = 8.dp).testTag("newMessages"),
                        shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.primary,
                        shadowElevation = 3.dp,
                    ) {
                        Text("有 $newCount 条新消息 ↑", Modifier.padding(horizontal = 14.dp, vertical = 7.dp),
                            fontSize = 13.sp, color = MaterialTheme.colorScheme.onPrimary)
                    }
                }
            }
        }
    }
}

@Composable
private fun MessageRow(m: Message, channel: String, unread: Boolean, clock: Int, e2eOn: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 11.dp)) {
        Box(Modifier.padding(top = 6.dp).size(9.dp).clip(CircleShape)
            .background(if (unread) priorityColor(m.priority) else MaterialTheme.colorScheme.surfaceVariant))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                // 加密消息：标题前一个小锁（弱化颜色）；账号开了加密、这条却是明文：「未加密」灰色小徽章（e2ee-client.md §6.3）
                if (m.encrypted) {
                    Icon(Icons.Default.Lock, "端到端加密", Modifier.size(13.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f))
                    Spacer(Modifier.width(4.dp))
                } else if (e2eOn) {
                    PlainBadge()
                    Spacer(Modifier.width(5.dp))
                }
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

/** 「未加密」灰色小徽章 */
@Composable
private fun PlainBadge() {
    Surface(shape = RoundedCornerShape(4.dp), color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.12f)) {
        Text("未加密", Modifier.padding(horizontal = 4.dp), fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** 加密消息已锁定（T10）：整条可点，进入解锁页 */
@Composable
private fun LockBanner(onClick: () -> Unit) {
    Surface(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp).clip(RoundedCornerShape(12.dp)).clickable(onClick = onClick)
            .testTag("e2eLocked"),
        shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.secondaryContainer,
    ) {
        Text(E2EText.T10, Modifier.padding(horizontal = 14.dp, vertical = 11.dp), fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSecondaryContainer)
    }
}

/** 首页顶部的提示条；action 为 null 时整条可点 */
@Composable
private fun Banner(text: String, action: String?, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val m = modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)
    val shape = RoundedCornerShape(12.dp)
    val content: @Composable () -> Unit = {
        Row(Modifier.padding(start = 12.dp, end = 4.dp, top = 4.dp, bottom = 4.dp).heightIn(min = 40.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Warning, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onPrimaryContainer)
            Spacer(Modifier.width(8.dp))
            Text(text, Modifier.weight(1f), fontSize = 13.sp, color = MaterialTheme.colorScheme.onPrimaryContainer)
            if (action != null) TextButton(onClick) { Text(action) }
        }
    }
    if (action == null) Surface(onClick, m, shape = shape, color = MaterialTheme.colorScheme.primaryContainer, content = content)
    else Surface(m, shape = shape, color = MaterialTheme.colorScheme.primaryContainer, content = content)
}

@Composable
fun stateColor(s: ConnState) = when (s) {
    ConnState.Connected, is ConnState.Waiting -> androidx.compose.ui.graphics.Color(0xFF3C8D5A)
    is ConnState.Reconnecting, ConnState.Unauthorized -> MaterialTheme.colorScheme.error
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}

@Composable
fun Spacer8() = Spacer(Modifier.height(8.dp))

/** 首页「新消息」的判断（纯函数，方便单元测试） */
internal object NewMessages {
    /** 判断「在顶部」的容差：第一条只被滚走这么多时仍算在顶部 */
    const val TOP_SLOP_DP = 24

    /** 列表（按 id 从新到旧）最前面比上次的第一条（prevTop）新的有几条；第一次显示、或没有更新的消息时为 0 */
    fun arrived(prevTop: Long?, ids: List<Long>): Int = if (prevTop == null) 0 else ids.takeWhile { it > prevTop }.size

    /**
     * 新消息到达之前是否停在顶部：可见区第一条还是上次的第一条，并且几乎没被滚走。
     * 列表按 key 保持位置，插入后第一条可见的仍是原来那条，所以不管布局是否已经更新都能判断
     */
    fun wasAtTop(prevTop: Long?, firstVisibleKey: Any?, offsetPx: Int, slopPx: Int): Boolean =
        prevTop != null && firstVisibleKey == prevTop && offsetPx <= slopPx
}
