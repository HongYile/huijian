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
class SingleFlight<K, V>(private val scope: CoroutineScope) {
    private val running = HashMap<K, Deferred<V>>()

    fun start(key: K, block: suspend () -> V): Deferred<V> = synchronized(running) {
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
    /** 加密附件解密失败（附件卡片显示这几个字） */
    const val DECRYPT_FAILED = "解密失败"
    /**
     * 附件已被服务器补加密（410 reason sealed，§11.5）：消息已重新拉取，附件换了新 id，但没法确定接着下载哪个新附件
     * （服务端说的消息和本地放这个附件的不是同一条，或者拉到的还没解开）。挂在新附件上，提示重新点开
     */
    const val RESEALED = "附件已更新，请重新点开"
    /** 410 sealed 但重新拉取没有换到可用的新记录（或同一条消息已经重拉过 2 次）：不再自动重拉 */
    const val RESEAL_LATER = "附件已更新，请稍后重试"
    /** 服务器上的附件文件丢失（410 reason missing；没有 reason 也按这个处理，不比较错误文字） */
    const val MISSING = "失败：服务器上的附件文件已丢失"
    /** 同一条消息因为 410 sealed 最多重新拉 2 次，防止服务器不断给新 id */
    const val MAX_RESEAL_REFETCH = 2
    /** 410 sealed 后接着下载新附件最多接 1 层：新附件再遇到 410 sealed 不再往下接，防止 A→B→A 互相等待 */
    const val MAX_RESEAL_CHAIN = 1

    /** 下载结果：最终下载的附件（补加密换了新 id 时是新附件，打开时用它的 mime）和文件 */
    data class Fetched(val att: Attachment, val file: File)
    private val refetched = HashMap<Long, Int>()

    /** 410 sealed 时要不要再重拉 message_id 那条（每条最多 MAX_RESEAL_REFETCH 次）；纯计数，方便单测 */
    internal fun allowRefetch(counts: MutableMap<Long, Int>, messageId: Long): Boolean = synchronized(counts) {
        if (messageId <= 0) return false
        val n = counts[messageId] ?: 0
        if (n >= MAX_RESEAL_REFETCH) return false
        counts[messageId] = n + 1
        true
    }

    private class DecryptFailed : IOException(DECRYPT_FAILED)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val flight = SingleFlight<String, Fetched>(scope)

    /** att.id → LOADING / DONE / 「失败：…」（界面读它；只在主线程写） */
    val status = mutableStateMapOf<String, String>()

    private suspend fun set(id: String, v: String?) = withContext(Dispatchers.Main) {
        if (v == null) status.remove(id) else status[id] = v
    }

    /**
     * 下载到 dest；已经在下载时返回同一个 Deferred。成功时返回最终的附件和文件，失败时 await 抛出异常。
     * 附件被服务器补加密（410 sealed）时重新拉取消息、接着下载同一位置的新附件（和 Mac 一致），返回新附件和它的文件；
     * destFor 算新附件的存放位置。depth：已经接了几层（最多 MAX_RESEAL_CHAIN）
     */
    fun download(a: Attachment, dest: File, destFor: (Attachment) -> File, depth: Int = 0): Deferred<Fetched> =
        flight.start(a.id) { fetch(a, dest, destFor, depth) }

    private suspend fun fetch(a: Attachment, dest: File, destFor: (Attachment) -> File, depth: Int): Fetched {
        val session = Hub.session
        set(a.id, LOADING)
        val sealed = try {
            dest.parentFile?.mkdirs()
            val api = Hub.api() ?: throw IOException("未登录")
            if (a.encrypted) {
                // 加密附件（e2ee-client.md §6.4）：先下载密文并校验密文的 sha256，再用载荷里的钥匙解密到真实文件名，最后删掉密文
                val enc = File.createTempFile("att", ".enc", dest.parentFile)
                try {
                    api.download(a, enc)
                    try { E2EHub.decryptFile(a.key, enc, dest) } catch (e: Exception) { throw DecryptFailed() }
                } finally {
                    enc.delete()
                }
            } else api.download(a, dest)
            if (Hub.session != session) { dest.delete(); throw IOException("已退出登录") }
            set(a.id, DONE)
            Hub.trimAttachments()
            return Fetched(a, dest)
        } catch (e: CancellationException) {
            set(a.id, null); throw e
        } catch (e: ApiException) {
            if (e.status != 410 || e.reason != "sealed") { set(a.id, if (e.status == 410) MISSING else "失败：${e.message}"); throw e }
            e
        } catch (e: Exception) {
            set(a.id, if (e is DecryptFailed) DECRYPT_FAILED else "失败：${e.message}"); throw e
        }
        // §11.5：附件已被服务器补加密、换了新 id。下载从头开始（新 id、新临时文件），不和旧的半截文件拼接
        if (!canChain(depth)) { set(a.id, RESEAL_LATER); throw sealed }
        val next = afterSealed(a, sealed.messageId, session) ?: throw sealed
        set(a.id, null)
        return download(next, destFor(next), destFor, depth + 1).await()
    }

    /**
     * 410 sealed 之后：重新拉取 message_id 那条和本地放这个附件的那条（替换本地记录、丢弃旧附件缓存），
     * 返回要接着下载的新附件。不能接着下载时写好提示并返回 null：重拉失败（或已经重拉过 2 次）提示挂在旧附件上，
     * 重拉成功但对不上是哪个新附件时挂在新附件上（旧附件已经不显示了）
     */
    private suspend fun afterSealed(a: Attachment, messageId: Long, session: Long): Attachment? {
        val holder = Hub.messages.value.firstOrNull { m -> m.attachments.any { it.id == a.id } }
        val owner = messageId.takeIf { it > 0 } ?: holder?.id ?: 0L
        val api = Hub.api()
        val ok = api != null && allowRefetch(refetched, owner) &&
            runCatching { Hub.refetchSealed(listOfNotNull(owner, holder?.id).distinct(), api, session) }.getOrDefault(0) > 0
        if (!ok) { set(a.id, RESEAL_LATER); return null }
        val after = Hub.messages.value
        resealedSuccessor(holder, owner, a.id, after.firstOrNull { it.id == owner })?.let { return it }
        val fresh = after.firstOrNull { it.id == holder?.id }?.attachments.orEmpty().filter { it.id != a.id }
        if (fresh.isEmpty()) set(a.id, RESEALED) else fresh.forEach { set(it.id, RESEALED) }
        return null
    }

    /**
     * 补加密以后接着下载哪个附件（纯函数，方便单测）：服务端说的消息就是本地放这个附件的那条、重新拉到的已经解开，
     * 取同一位置、id 换了的那个；否则 null（和 Mac 一致）
     */
    internal fun canChain(depth: Int) = depth < MAX_RESEAL_CHAIN

    internal fun resealedSuccessor(holder: Message?, owner: Long, attId: String, refreshed: Message?): Attachment? {
        if (holder == null || refreshed == null || holder.id != owner || refreshed.id != owner) return null
        if (!refreshed.encrypted || refreshed.e2eStatus != E2EMessages.OK) return null
        val pos = holder.attachments.indexOfFirst { it.id == attId }
        return refreshed.attachments.getOrNull(pos)?.takeIf { it.id != attId }
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
