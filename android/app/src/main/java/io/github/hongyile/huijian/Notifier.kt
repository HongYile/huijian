package io.github.hongyile.huijian

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * 按优先级分通知渠道（用户可以在系统设置里分别调整每一级的声音和横幅）：
 * P5 紧急：横幅 + 响铃 + 振动，勿扰模式下也提醒（需要用户授予勿扰权限）；
 * P4 重要：横幅 + 响铃；P3 普通：进通知栏、不出声；P0–P2 不发通知，只进列表。
 */
object Notifier {
    const val CH_SERVICE = "service"
    const val CH_E2E = "e2e"
    const val CH_AGENT = "agent"
    const val CH_P5 = "p5"
    const val CH_P4 = "p4"
    const val CH_P3 = "p3"
    const val ID_SERVICE = 1
    private const val ID_SUMMARY = 2
    private const val ID_E2E = 3
    private const val TAG_E2E = "e2e:"
    private const val ID_AGENT = 4
    private const val TAG_AGENT = "agent:"
    private const val ID_MESSAGE_BASE = 1000
    private const val TAG_URGENT = "p5"
    /** 单独显示的普通消息通知最多几条（小米系统每个 App 大约十几条就开始挤掉旧的） */
    private const val MAX_SINGLE = 6
    const val EXTRA_MESSAGE_ID = "message_id"
    /** 点「设备请求解锁」的通知：打开加密页 */
    const val EXTRA_OPEN_E2E = "open_e2e"
    /** 点「agent 请求登录」的通知：打开 Agent 页 */
    const val EXTRA_OPEN_AGENT = "open_agent"

    fun setup(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        val alarmAttrs = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).build()
        nm.createNotificationChannels(listOf(
            NotificationChannel(CH_P5, "P5 紧急", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "需要马上处理的告警，勿扰模式下也提醒"
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 400, 200, 400, 200, 400)
                setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION), alarmAttrs)
                setBypassDnd(true)
            },
            NotificationChannel(CH_P4, "P4 重要", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "在等的结果：任务完成、关键指标"
            },
            NotificationChannel(CH_P3, "P3 普通", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "一般进展，只进通知栏，不出声"
                setSound(null, null)
                enableVibration(false)
            },
            NotificationChannel(CH_E2E, "设备请求解锁", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "账号的另一台设备请求解锁加密消息，需要在这里核对后批准"
            },
            NotificationChannel(CH_AGENT, "agent 请求登录", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "agent（Claude Code 等）请求用你的账号收发消息，需要在这里核对后批准"
            },
            NotificationChannel(CH_SERVICE, "后台连接", NotificationManager.IMPORTANCE_MIN).apply {
                description = "保持和回笺服务器的连接（系统要求常驻显示）"
                setShowBadge(false)
            },
        ))
    }

    /** 13 以上看运行时权限，所有版本都再看系统设置里的「允许通知」总开关 */
    /** 退出登录：清掉通知栏里本 App 的所有通知 */
    fun cancelAll(ctx: Context) = NotificationManagerCompat.from(ctx).cancelAll()

    fun canPost(ctx: Context) = (Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
        NotificationManagerCompat.from(ctx).areNotificationsEnabled()

    private fun openIntent(ctx: Context, messageId: Long?): PendingIntent {
        val i = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            messageId?.let { putExtra(EXTRA_MESSAGE_ID, it) }
        }
        return PendingIntent.getActivity(ctx, (messageId ?: 0L).toInt(), i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    fun serviceNotification(ctx: Context, text: String): Notification =
        NotificationCompat.Builder(ctx, CH_SERVICE)
            .setSmallIcon(R.drawable.ic_stat_huijian)
            .setContentTitle("回笺")
            .setContentText(text)
            .setOngoing(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(openIntent(ctx, null))
            .build()

    /** 常驻通知当前的文字；服务没在运行时为 null */
    @Volatile var serviceText: String? = null

    fun updateService(ctx: Context, text: String) {
        serviceText = text
        if (!canPost(ctx)) return
        NotificationManagerCompat.from(ctx).notify(ID_SERVICE, serviceNotification(ctx, text))
    }

    /** 小米等系统限制每个 App 的通知条数，通知多了会把最早的「已连接」常驻通知挤掉；发现不见了就补回来 */
    private fun ensureService(ctx: Context) {
        val text = serviceText ?: return
        val nm = ctx.getSystemService(NotificationManager::class.java)
        if (nm.activeNotifications.none { it.id == ID_SERVICE }) {
            try { nm.notify(ID_SERVICE, serviceNotification(ctx, text)) } catch (_: SecurityException) {}
        }
    }

    private fun shouldAlert(m: Message) = !m.silent && m.priority >= 3

    /** 汇总通知里已经算进去的条数（汇总被撤掉后归零） */
    private var summaryCount = 0

    /**
     * 新消息提醒。P5 每条单独提醒；其他的单独通知最多留 MAX_SINGLE 条，再多（例如离线后补拉、短时间连发）
     * 就把它们收进一条「N 条新消息」汇总，避免刷屏，也避免超过系统的每 App 通知上限。
     */
    @Synchronized
    fun post(ctx: Context, fresh: List<Message>) {
        if (!canPost(ctx)) return
        val alert = fresh.filter(::shouldAlert)
        if (alert.isEmpty()) return
        val nm = NotificationManagerCompat.from(ctx)
        val sys = ctx.getSystemService(NotificationManager::class.java)
        val (urgent, normal) = alert.partition { it.priority >= 5 }
        val active = sys.activeNotifications
        val singles = active.filter { it.id >= ID_MESSAGE_BASE && it.tag == null }
        if (active.none { it.id == ID_SUMMARY }) summaryCount = 0
        val single = if (summaryCount > 0 || singles.size + normal.size > MAX_SINGLE) {
            for (n in singles) nm.cancel(n.id)
            summaryCount += singles.size + normal.size
            val top = normal.maxOfOrNull { it.priority } ?: 3
            val s = NotificationCompat.Builder(ctx, channelFor(top))
                .setSmallIcon(R.drawable.ic_stat_huijian)
                .setContentTitle("$summaryCount 条新消息")
                .setContentText(normal.takeLast(3).reversed().joinToString("；") { it.title })
                .setNumber(summaryCount)
                .setOnlyAlertOnce(normal.isEmpty())
                .setAutoCancel(true)
                .setContentIntent(openIntent(ctx, null))
                .build()
            if (normal.isNotEmpty()) try { nm.notify(ID_SUMMARY, s) } catch (_: SecurityException) {}
            urgent
        } else alert
        for (m in single) {
            val body = m.summary().take(400)
            val b = NotificationCompat.Builder(ctx, channelFor(m.priority))
                .setSmallIcon(R.drawable.ic_stat_huijian)
                .setContentTitle(m.title)
                .setContentText(body.ifBlank { Priority.label(m.priority) })
                .setStyle(NotificationCompat.BigTextStyle().bigText(body.ifBlank { Priority.label(m.priority) }))
                .setSubText(Hub.channelName(m.topic))
                .setWhen(m.createdAt.toEpochMilli())
                .setShowWhen(true)
                .setAutoCancel(true)
                .setGroup("topic:" + m.topic)
                .setCategory(if (m.priority >= 5) NotificationCompat.CATEGORY_ALARM else NotificationCompat.CATEGORY_MESSAGE)
                .setContentIntent(openIntent(ctx, m.id))
            if (m.priority >= 5) b.setColor(0xFFC0392B.toInt())
            // P5 用 tag 区分：收进汇总时不撤 P5
            try { nm.notify(if (m.priority >= 5) TAG_URGENT else null, notificationId(m.id), b.build()) } catch (_: SecurityException) {}
        }
        ensureService(ctx)
    }

    /** 打开一条消息：撤掉它的通知，以及「收到 N 条新消息」汇总（汇总点开也只是进列表） */
    @Synchronized
    fun cancel(ctx: Context, messageId: Long) {
        val nm = NotificationManagerCompat.from(ctx)
        nm.cancel(notificationId(messageId))
        nm.cancel(TAG_URGENT, notificationId(messageId))
        nm.cancel(ID_SUMMARY)
        summaryCount = 0
    }

    /**
     * 消息在别的设备上被删除（或删了整个频道）：只撤这些消息各自的单条通知（含 P5），
     * 不动「N 条新消息」汇总和它的计数——汇总里还有别的消息没看
     */
    fun cancelRemoved(ctx: Context, ids: Collection<Long>) {
        if (ids.isEmpty()) return
        val nm = NotificationManagerCompat.from(ctx)
        for (id in ids) {
            nm.cancel(notificationId(id))
            nm.cancel(TAG_URGENT, notificationId(id))
        }
    }

    /** 全部已读：撤掉所有消息通知（保留常驻的「已连接」） */
    @Synchronized
    fun cancelMessages(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        for (n in nm.activeNotifications) if (n.id != ID_SERVICE && n.id != ID_E2E && n.id != ID_AGENT) nm.cancel(n.tag, n.id)   // 设备请求解锁、agent 请求登录的通知留着
        summaryCount = 0
    }

    /** 有设备请求批准（T50）：同一个请求只通知一次（E2EHub 记着），点开进加密页 */
    fun postE2ERequest(ctx: Context, r: E2ERequest) {
        if (!canPost(ctx)) return
        val i = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_OPEN_E2E, true)
        }
        val pi = PendingIntent.getActivity(ctx, 900_000_001, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val text = E2EText.t50(r.name.ifBlank { r.deviceId })
        val n = NotificationCompat.Builder(ctx, CH_E2E)
            .setSmallIcon(R.drawable.ic_stat_huijian)
            .setContentTitle("设备请求解锁")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setContentIntent(pi)
            .build()
        try { NotificationManagerCompat.from(ctx).notify(TAG_E2E + r.deviceId, ID_E2E, n) } catch (_: SecurityException) {}
        ensureService(ctx)
    }

    /** 请求已处理（批准、拒绝、取消）：撤掉它的通知 */
    fun cancelE2ERequest(ctx: Context, deviceId: String) = NotificationManagerCompat.from(ctx).cancel(TAG_E2E + deviceId, ID_E2E)

    fun cancelE2ERequests(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        runCatching { for (n in nm.activeNotifications) if (n.id == ID_E2E) nm.cancel(n.tag, n.id) }
    }

    /** agent 请求登录（docs/agent-mcp.md §8）：同一个请求只通知一次（AgentHub 记着），点开进 Agent 页核对后批准 */
    fun postAgentRequest(ctx: Context, s: AgentSession) {
        if (!canPost(ctx)) return
        val i = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_OPEN_AGENT, true)
        }
        val pi = PendingIntent.getActivity(ctx, 900_000_002, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val text = "「${s.name.ifBlank { "agent" }}」想用你的账号收发消息。打开回笺核对 6 位核对码后批准。"
        val n = NotificationCompat.Builder(ctx, CH_AGENT)
            .setSmallIcon(R.drawable.ic_stat_huijian)
            .setContentTitle("agent 请求登录")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setContentIntent(pi)
            .build()
        try { NotificationManagerCompat.from(ctx).notify(TAG_AGENT + s.id, ID_AGENT, n) } catch (_: SecurityException) {}
        ensureService(ctx)
    }

    /** 请求已处理（批准、拒绝、过期）：撤掉它的通知 */
    fun cancelAgentRequest(ctx: Context, id: String) = NotificationManagerCompat.from(ctx).cancel(TAG_AGENT + id, ID_AGENT)

    fun cancelAgentRequests(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        runCatching { for (n in nm.activeNotifications) if (n.id == ID_AGENT) nm.cancel(n.tag, n.id) }
    }

    private fun notificationId(id: Long) = ID_MESSAGE_BASE + (id % 1_000_000).toInt()

    private fun channelFor(p: Int) = when {
        p >= 5 -> CH_P5
        p == 4 -> CH_P4
        else -> CH_P3
    }
}
