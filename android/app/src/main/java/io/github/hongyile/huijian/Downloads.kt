package io.github.hongyile.huijian

import androidx.compose.runtime.mutableStateMapOf
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException

/** 同一个 key 同时只跑一份：后来的调用拿到同一个 Deferred，等同一个结果 */
class SingleFlight<K>(private val scope: CoroutineScope) {
    private val running = HashMap<K, Deferred<Unit>>()

    fun start(key: K, block: suspend () -> Unit): Deferred<Unit> = synchronized(running) {
        running[key]?.let { if (it.isActive) return it }
        val d = scope.async(start = CoroutineStart.LAZY) { block() }
        running[key] = d
        d.invokeOnCompletion { synchronized(running) { if (running[key] === d) running.remove(key) } }
        d.start()
        d
    }

    fun isRunning(key: K) = synchronized(running) { running[key]?.isActive == true }
}

/**
 * 附件下载（进程级，所有详情页共用）：同一个附件同时只下载一份，正文图片、附件卡片、附件区、
 * 从另一条消息跳过来再打开的页面都等同一个结果；状态表也只有一份，各处显示一致。
 */
object AttDownloads {
    const val LOADING = "下载中…"
    const val DONE = "done"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val flight = SingleFlight<String>(scope)

    /** att.id → LOADING / DONE / 「失败：…」（界面读它；只在主线程写） */
    val status = mutableStateMapOf<String, String>()

    private suspend fun set(id: String, v: String?) = withContext(Dispatchers.Main) {
        if (v == null) status.remove(id) else status[id] = v
    }

    /** 下载到 dest；已经在下载时返回同一个 Deferred。失败时 await 抛出异常 */
    fun download(a: Attachment, dest: File): Deferred<Unit> = flight.start(a.id) {
        val session = Hub.session
        set(a.id, LOADING)
        try {
            dest.parentFile?.mkdirs()
            (Hub.api() ?: throw IOException("未登录")).download(a, dest)
            if (Hub.session != session) { dest.delete(); throw IOException("已退出登录") }
            set(a.id, DONE)
            Hub.trimAttachments()
        } catch (e: CancellationException) {
            set(a.id, null); throw e
        } catch (e: Exception) {
            set(a.id, "失败：${e.message}"); throw e
        }
    }

    fun isDownloading(id: String) = flight.isRunning(id)

    /** 这些附件的文件已删除（消息被其他设备删除）：去掉它们的状态 */
    fun forget(ids: Collection<String>) {
        scope.launch(Dispatchers.Main) { ids.forEach { status.remove(it) } }
    }

    /** 退出登录、换账号时清掉状态（附件缓存目录同时被删） */
    fun reset() {
        scope.launch(Dispatchers.Main) { status.clear() }
    }
}
