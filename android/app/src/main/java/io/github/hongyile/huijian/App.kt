package io.github.hongyile.huijian

import android.app.Application
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        Hub.init(this)
        Notifier.setup(this)
    }
}

/** 开机、App 更新后自动拉起常驻服务（关了电池优化才允许从后台启动前台服务） */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        Hub.init(ctx)
        if (!Hub.loggedIn) return
        try {
            SyncService.start(ctx)
        } catch (e: Exception) {
            Log.w("HuijianBoot", "开机启动服务失败：${e.message}")
        }
    }
}

/** 「后台运行检查」页用到的系统设置入口 */
object Background {
    fun ignoringBatteryOptimizations(ctx: Context) =
        ctx.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(ctx.packageName)

    fun requestIgnoreBatteryOptimizations(ctx: Context) {
        val i = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${ctx.packageName}"))
        tryStart(ctx, i) || tryStart(ctx, Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
    }

    fun canBypassDnd(ctx: Context) =
        ctx.getSystemService(android.app.NotificationManager::class.java).isNotificationPolicyAccessGranted

    fun openDndAccess(ctx: Context) {
        tryStart(ctx, Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS))
    }

    fun openAppNotificationSettings(ctx: Context) {
        val i = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, ctx.packageName)
        tryStart(ctx, i) || openAppDetails(ctx)
    }

    fun openAppDetails(ctx: Context) =
        tryStart(ctx, Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${ctx.packageName}")))

    val brand: String get() = Build.MANUFACTURER.lowercase()

    /** 各品牌的「自启动管理」页面；没有对应页面时打开应用详情 */
    fun openAutoStart(ctx: Context) {
        val candidates = when {
            brand.contains("xiaomi") || brand.contains("redmi") || brand.contains("poco") -> listOf(
                ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            )
            brand.contains("huawei") || brand.contains("honor") -> listOf(
                ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
                ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"),
                ComponentName("com.hihonor.systemmanager", "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            )
            brand.contains("oppo") || brand.contains("realme") || brand.contains("oneplus") -> listOf(
                ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
                ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
                ComponentName("com.oplus.safecenter", "com.oplus.safecenter.permission.startup.StartupAppListActivity"),
            )
            brand.contains("vivo") || brand.contains("iqoo") -> listOf(
                ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
                ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
                ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"),
            )
            else -> emptyList()
        }
        for (c in candidates) if (tryStart(ctx, Intent().setComponent(c))) return
        openAppDetails(ctx)
    }

    /** 按品牌给出需要手动打开的设置（系统没有接口能检测这些开关） */
    fun manualSteps(): List<String> = when {
        brand.contains("xiaomi") || brand.contains("redmi") || brand.contains("poco") -> listOf(
            "「自启动」里打开回笺",
            "设置 → 应用设置 → 应用管理 → 回笺 → 省电策略 → 选「无限制」",
            "最近任务里按住回笺的卡片 → 点锁形图标锁定，一键清理时不会被关掉",
        )
        brand.contains("huawei") || brand.contains("honor") -> listOf(
            "手机管家 → 应用启动管理 → 回笺 → 关闭「自动管理」，打开「允许自启动」「允许后台活动」",
            "最近任务里下拉回笺的卡片锁定",
        )
        brand.contains("oppo") || brand.contains("realme") || brand.contains("oneplus") -> listOf(
            "设置 → 应用 → 自启动管理 → 打开回笺",
            "设置 → 电池 → 应用耗电管理 → 回笺 → 允许后台运行",
            "最近任务里锁定回笺",
        )
        brand.contains("vivo") || brand.contains("iqoo") -> listOf(
            "i 管家 → 应用管理 → 权限管理 → 自启动 → 打开回笺",
            "设置 → 电池 → 后台耗电管理 → 回笺 → 允许后台高耗电",
            "最近任务里锁定回笺",
        )
        else -> listOf("如果收消息不及时：在系统设置里允许回笺自启动、后台运行，并在最近任务里锁定它")
    }

    private fun tryStart(ctx: Context, i: Intent): Boolean = try {
        ctx.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true
    } catch (_: Exception) { false }
}
