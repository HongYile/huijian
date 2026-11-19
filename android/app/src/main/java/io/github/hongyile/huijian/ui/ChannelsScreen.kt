package io.github.hongyile.huijian.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.hongyile.huijian.ChannelSetting
import io.github.hongyile.huijian.Hub
import io.github.hongyile.huijian.Manage
import kotlinx.coroutines.launch

/**
 * 设置 → 频道：改显示名、排序（上移 / 下移，置顶的在最前）、置顶、静音、隐藏、删除。
 * 设置属于账号，所有设备共用；和 Mac 侧栏频道右键菜单的功能一致。
 */
@Composable
fun ChannelsScreen(back: () -> Unit) {
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    val messages by Hub.messages.collectAsStateWithLifecycle()
    val settings by Hub.channels.collectAsStateWithLifecycle()
    var renaming by remember { mutableStateOf<String?>(null) }
    var deleting by remember { mutableStateOf<String?>(null) }
    var resetting by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }

    // 本机有消息的频道 + 服务端设置过的频道（包括隐藏的，方便取消隐藏）
    val counts = remember(messages) { messages.groupingBy { it.topic }.eachCount() }
    val last = remember(messages) { messages.groupBy { it.topic }.mapValues { (_, v) -> v.maxOf { it.id } } }
    val order = remember(counts, settings, last) { Manage.orderChannels(counts.keys + settings.keys, settings, last) }

    fun say(s: String) { scope.launch { snackbar.showSnackbar(s) } }
    fun run(what: String, block: suspend () -> Unit) {
        busy = true
        scope.launch {
            try { block() } catch (e: Exception) { say("$what 失败：${describe(e)}") } finally { busy = false }
        }
    }
    fun patch(topic: String, alias: String? = null, hidden: Boolean? = null, muted: Boolean? = null, pinned: Boolean? = null) =
        run("保存") { Hub.putChannel(api { it.updateChannel(topic, alias, hidden, muted, pinned) }) }
    fun reorder(next: List<String>) = run("保存顺序") {
        api { it.setChannelOrder(next) }
        Hub.setChannelOrderLocal(next)
    }
    fun refresh() = run("刷新") { val list = api { it.channels() }; Hub.setChannels(list, Hub.session) }

    ManageScaffold("频道", back, snackbar, actions = {
        IconButton({ refresh() }, enabled = !busy) { Icon(Icons.Default.Refresh, "刷新") }
    }) {
        SectionCard(null, "频道就是发送时的 topic 参数。显示名、顺序、置顶、静音、隐藏属于账号，所有设备共用。" +
            "静音：照常显示，P1–P4 不提醒（P5 紧急照常）；隐藏：不进收件箱、不提醒。删除频道会删除它在服务器上的全部消息和附件。") {
            if (order.isEmpty()) Text("还没有频道：收到消息后会出现在这里", color = MaterialTheme.colorScheme.onSurfaceVariant)
            order.forEachIndexed { i, t ->
                if (i > 0) HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                val c = settings[t] ?: ChannelSetting(t, "", false, false, false, 0)
                val prev = order.getOrNull(i - 1)?.let { settings[it]?.pinned == true }
                val next = order.getOrNull(i + 1)?.let { settings[it]?.pinned == true }
                ChannelRow(
                    c, counts[t] ?: 0, enabled = !busy,
                    canUp = prev != null && prev == c.pinned,      // 只在同一组（置顶 / 不置顶）里移动
                    canDown = next != null && next == c.pinned,
                    onUp = { reorder(Manage.moved(order, i, i - 1)) },
                    onDown = { reorder(Manage.moved(order, i, i + 1)) },
                    onRename = { renaming = t },
                    onPin = { patch(t, pinned = !c.pinned) },
                    onMute = { patch(t, muted = !c.muted) },
                    onHide = { patch(t, hidden = !c.hidden) },
                    onDelete = { deleting = t },
                )
            }
        }
        if (settings.values.any { it.sort > 0 }) OutlinedButton({ resetting = true }, enabled = !busy) { Text("恢复按最近活跃排序") }
    }

    renaming?.let { t ->
        var alias by remember(t) { mutableStateOf(settings[t]?.alias.orEmpty()) }
        AlertDialog(
            onDismissRequest = { renaming = null },
            title = { Text("重命名「$t」") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    OutlinedTextField(alias, { alias = it.take(32) }, Modifier.fillMaxWidth(), label = { Text("显示名（最多 32 个字）") },
                        placeholder = { Text(t) }, singleLine = true)
                    Text("留空恢复原名。发送时仍然用 topic「$t」。", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            },
            confirmButton = { TextButton({ renaming = null; patch(t, alias = alias.trim()) }) { Text("保存") } },
            dismissButton = { TextButton({ renaming = null }) { Text("取消") } },
        )
    }
    if (resetting) ConfirmDialog(
        "恢复按最近活跃排序？",
        "会清除手动排好的顺序，所有设备同步改回按最近有消息的先后排列（置顶的频道仍在最前）。",
        "恢复", { resetting = false },
    ) { reorder(emptyList()) }

    deleting?.let { t ->
        val n = counts[t] ?: 0
        val atts = messages.filter { it.topic == t }.sumOf { it.attachments.size }
        ConfirmDialog(
            "删除频道「${Hub.channelName(t)}」？",
            "会从服务器删除这个频道的全部消息（本机 $n 条" + (if (atts > 0) "，附件 $atts 个" else "") + "）和它的设置，所有设备同步删除，不能恢复。之后再有这个频道的消息发来，频道会重新出现。",
            "删除", { deleting = null },
        ) {
            run("删除频道") {
                val deleted = api { it.deleteChannel(t) }
                Hub.removeTopic(t)
                say("已删除 $deleted 条消息")
            }
        }
    }
}

@Composable
private fun ChannelRow(
    c: ChannelSetting, count: Int, enabled: Boolean, canUp: Boolean, canDown: Boolean,
    onUp: () -> Unit, onDown: () -> Unit, onRename: () -> Unit, onPin: () -> Unit, onMute: () -> Unit, onHide: () -> Unit, onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("# " + c.alias.ifBlank { c.topic }, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                    color = if (c.hidden) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface)
                if (c.pinned) Tag("置顶", MaterialTheme.colorScheme.primary)
                if (c.muted) Tag("静音", WARNING)
                if (c.hidden) Tag("隐藏", MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text(listOfNotNull(c.topic.takeIf { c.alias.isNotBlank() }?.let { "topic：$it" }, "本机 $count 条").joinToString(" · "),
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        IconButton(onUp, enabled = enabled && canUp) { Icon(Icons.Default.KeyboardArrowUp, "上移") }
        IconButton(onDown, enabled = enabled && canDown) { Icon(Icons.Default.KeyboardArrowDown, "下移") }
        Box {
            IconButton({ menu = true }, enabled = enabled) { Icon(Icons.Default.MoreVert, "更多操作") }
            DropdownMenu(menu, { menu = false }) {
                DropdownMenuItem({ Text("重命名…") }, { menu = false; onRename() })
                if (!c.hidden) DropdownMenuItem({ Text(if (c.pinned) "取消置顶" else "置顶") }, { menu = false; onPin() })
                DropdownMenuItem({ Text(if (c.muted) "取消静音" else "静音（紧急消息除外）") }, { menu = false; onMute() })
                DropdownMenuItem({ Text(if (c.hidden) "取消隐藏" else "隐藏频道") }, { menu = false; onHide() })
                HorizontalDivider()
                DropdownMenuItem({ Text("删除频道…", color = MaterialTheme.colorScheme.error) }, { menu = false; onDelete() })
            }
        }
    }
}
