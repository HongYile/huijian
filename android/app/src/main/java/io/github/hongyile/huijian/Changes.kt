package io.github.hongyile.huijian

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.json.JSONObject

/** 同账号其他设备（或管理网页）的操作：delete / archive（state 0/1/2），以及 id 为 0 的设置变更 */
data class MsgChange(val seq: Long, val id: Long, val kind: String, val state: Int?)

/** 长轮询带 changes_since 时响应里多出的部分 */
data class ChangesPage(
    val changes: List<MsgChange>,
    /** 下一次请求用的变更游标 */
    val next: Long?,
    /** 游标已失效（离线太久、变更记录已清理、服务端从备份恢复）：需要重新对账 */
    val reset: Boolean,
    /** 服务端数据纪元：变了说明服务端重建或从备份恢复过 */
    val epoch: String?,
)

/** GET /v1/messages/state 的结果 */
data class MessageStates(val states: Map<Long, Int>, val next: Long, val epoch: String?)

/** 需要重新拉取的账号设置 */
enum class SettingKind {
    CHANNELS, KEYS, ACCOUNT,
    /** 端到端加密（开启、设备请求批准 / 已批准、换钥匙）：重新 GET /v1/e2e */
    E2E,
}

/**
 * 多设备变更流（docs/api.md「多设备同步」「设置实时同步」）：解析、按 kind 分发、对账。
 * 行为和 iPhone 端（ios/Sources/AppModel.swift 的 deliver / reconcile / applyChanges）一致；不依赖 Android，可以做单元测试。
 */
object Changes {
    /** 解析长轮询响应里的变更；服务端没返回变更字段（旧服务端、没带 changes_since）时返回 null */
    fun parse(o: JSONObject): ChangesPage? {
        if (!o.has("changes") && !o.has("changes_next") && !o.has("changes_reset")) return null
        val arr = o.optJSONArray("changes")
        val list = if (arr == null) emptyList() else (0 until arr.length()).mapNotNull { i ->
            val c = arr.optJSONObject(i) ?: return@mapNotNull null
            val kind = c.optString("kind")
            if (kind.isEmpty()) null
            else MsgChange(c.optLong("seq"), c.optLong("id"), kind, if (c.has("state") && !c.isNull("state")) c.optInt("state") else null)
        }
        return ChangesPage(
            changes = list,
            next = if (o.has("changes_next") && !o.isNull("changes_next")) o.optLong("changes_next") else null,
            reset = o.optBoolean("changes_reset"),
            epoch = o.optString("changes_epoch").ifBlank { null },
        )
    }

    fun parseStates(o: JSONObject): MessageStates {
        val items = o.optJSONArray("items")
        val states = HashMap<Long, Int>()
        if (items != null) for (i in 0 until items.length()) {
            val it = items.optJSONArray(i) ?: continue
            if (it.length() == 0) continue
            states[it.optLong(0)] = if (it.length() > 1) it.optInt(1) else 0
        }
        return MessageStates(states, o.optLong("changes_next"), o.optString("epoch").ifBlank { null })
    }

    /** 一批变更要做的事 */
    data class Plan(
        val deleted: Set<Long>,
        /** 消息 id → 归档状态 */
        val archive: Map<Long, Int>,
        /** 要重新拉取的设置（同一批里同一种只拉一次） */
        val refresh: Set<SettingKind>,
        /** 服务器删掉的明文消息（kind purge），本机副本保留、记为「仅本机保留」（0.8 以前的「删除服务器上的明文消息」，0.9.0 起客户端没有这个入口；服务端可能还会发，保留兼容） */
        val purged: Set<Long> = emptySet(),
        /** 服务端 0.8.0 起：被服务器补加密的消息（kind sealed），用 GET /v1/messages/{id} 重新拉取、替换本地记录（§11.5） */
        val sealed: Set<Long> = emptySet(),
    ) {
        val isEmpty get() = deleted.isEmpty() && archive.isEmpty() && refresh.isEmpty() && purged.isEmpty() && sealed.isEmpty()
    }

    /**
     * 按 kind 分发：delete / archive 针对消息（id 0 不是消息，忽略）；channels / keys / devices / account 是设置变更
     * （devices、account 都重新拉 /v1/account；e2e 重新拉 /v1/e2e；purge 是服务器删了明文、本机保留；sealed 是服务器补加密了、
     * 重新拉这条消息）；不认识的 kind 忽略。按顺序应用：先删除后又出现的归档以删除为准。
     */
    fun plan(changes: List<MsgChange>): Plan {
        val del = LinkedHashSet<Long>()
        val arch = LinkedHashMap<Long, Int>()
        val refresh = LinkedHashSet<SettingKind>()
        val purged = LinkedHashSet<Long>()
        val sealed = LinkedHashSet<Long>()
        for (c in changes) when (c.kind) {
            "delete" -> if (c.id > 0) { del += c.id; arch.remove(c.id); purged.remove(c.id); sealed.remove(c.id) }
            "sealed" -> if (c.id > 0 && c.id !in del) sealed += c.id
            "purge" -> if (c.id > 0 && c.id !in del) purged += c.id
            "archive" -> if (c.id > 0 && c.id !in del) arch[c.id] = c.state ?: 0
            "channels" -> refresh += SettingKind.CHANNELS
            "keys" -> refresh += SettingKind.KEYS
            "devices", "account" -> refresh += SettingKind.ACCOUNT
            "e2e" -> refresh += SettingKind.E2E
            else -> {}
        }
        return Plan(del, arch, refresh, purged, sealed)
    }

    /**
     * §11.5：重新拉到的「被补加密」的消息能不能替换本地记录。只接受：本地那条是明文、新的是加密的而且 sealed == "server"、
     * id 就是请求的那条。否则丢弃——不然服务器发一条 sealed 变更就能改写任意本地消息（发送端加密的、已解开的）
     */
    fun acceptResealed(old: Message?, new: Message, requested: Long): Boolean =
        old != null && old.id == requested && new.id == requested && old.e2e == null && new.e2e != null && new.serverSealed

    /**
     * 一批被补加密的消息（§11.5）：
     * - done：不用再管（拉到了、404、本地没有、本地已经是加密的、拉到的不合规）；
     * - dropped：放弃（4xx，404 / 408 / 410 / 429 除外：再拉也不会好）；
     * - failed：这次没拉成（网络错误、5xx、408、410、429），失败次数加一，下次重试；
     * - skipped：同步循环已经取消，这次没处理，次数不变；
     * - accepted：要替换本地记录的
     */
    data class ResealResult(val accepted: List<Message>, val done: Set<Long>, val failed: Set<Long>,
                            val dropped: Set<Long> = emptySet(), val skipped: Set<Long> = emptySet())

    /**
     * 拉取被补加密的消息遇到这个状态码时直接放弃（和 Mac / iPhone 一致）：4xx 里 404 保留本地（fetch 返回 null）、
     * 410 走 sealed 流程、408 / 429 是暂时的（按失败计次重试），其余 4xx 放弃
     */
    fun resealGiveUp(status: Int): Boolean = status in 400..499 && status !in setOf(404, 408, 410, 429)

    /** 连续失败这么多次就放弃（和 Mac / iPhone 一致） */
    const val RESEAL_MAX_FAILS = 5

    /**
     * 并发（最多 parallel 条同时）拉取被补加密的消息。本地没有、本地已经是加密的直接算完成，不发请求；
     * fetch 返回 null = 404（已被删除，保留本地）；抛出 = 这条失败，不影响其他条。fatal(e) 为真的异常（登录失效）照常抛出；
     * cancelled() 为真（同步循环重启）后不再发新请求，正在进行的由调用方取消（Api 子实例），都算 skipped
     */
    fun fetchResealed(ids: Collection<Long>, local: Map<Long, Message>, parallel: Int = 4,
                      fatal: (Throwable) -> Boolean = { false }, cancelled: () -> Boolean = { false },
                      fetch: (Long) -> Message?): ResealResult {
        val todo = ids.filter { id -> local.containsKey(id) && local[id]?.e2e == null }
        val done = HashSet(ids.filter { it !in todo })
        if (todo.isEmpty()) return ResealResult(emptyList(), done, emptySet())
        val gate = Semaphore(parallel)
        val results = runBlocking(Dispatchers.IO) {
            todo.map { id ->
                async {
                    gate.withPermit {
                        if (cancelled()) return@withPermit id to null
                        try { id to Result.success(fetch(id)) } catch (e: Throwable) { if (fatal(e)) throw e; id to Result.failure(e) }
                    }
                }
            }.awaitAll()
        }
        val accepted = ArrayList<Message>()
        val failed = HashSet<Long>()
        val dropped = HashSet<Long>()
        val skipped = HashSet<Long>()
        for ((id, r) in results) {
            when {
                r == null -> skipped += id
                r.isFailure -> {
                    val e = r.exceptionOrNull()
                    when {
                        cancelled() -> skipped += id
                        e is ApiException && resealGiveUp(e.status) -> dropped += id
                        else -> failed += id
                    }
                }
                else -> {
                    done += id
                    val m = r.getOrNull()
                    if (m != null && acceptResealed(local[id], m, id)) accepted += m
                }
            }
        }
        return ResealResult(accepted, done, failed, dropped, skipped)
    }

    /**
     * 处理完一批后的重试集合：完成、放弃的去掉；失败的次数加一，到 maxFails 次放弃；跳过的不变。
     * cur 是处理完时最新的集合（处理期间新记进来的不在 r 里，原样保留）
     */
    fun nextRetry(cur: Map<Long, Int>, r: ResealResult, maxFails: Int = RESEAL_MAX_FAILS): Map<Long, Int> {
        val out = HashMap(cur)
        for (id in r.done + r.dropped) out.remove(id)
        for (id in r.failed) {
            val n = (cur[id] ?: 0) + 1
            if (n >= maxFails) out.remove(id) else out[id] = n
        }
        return out
    }

    /** 重试集合的存储格式：id:次数,id:次数（旧格式只有 id，次数按 0） */
    fun encodeRetry(m: Map<Long, Int>): String = m.entries.joinToString(",") { "${it.key}:${it.value}" }

    fun decodeRetry(s: String): Map<Long, Int> = s.split(',').mapNotNull { part ->
        val p = part.split(':')
        val id = p[0].trim().toLongOrNull() ?: return@mapNotNull null
        id to (p.getOrNull(1)?.toIntOrNull() ?: 0)
    }.toMap()

    /** 这一页的变更游标还能不能用：changes_reset，或服务端纪元和上次记下的不同，都要重新对账 */
    fun cursorValid(page: ChangesPage, savedEpoch: String?): Boolean =
        !page.reset && !(page.epoch != null && savedEpoch != null && page.epoch != savedEpoch)

    /** 对账时服务端数据是不是同一份（任何一边不知道纪元时按同一份处理） */
    fun sameData(savedEpoch: String?, serverEpoch: String?) = savedEpoch == null || serverEpoch == null || savedEpoch == serverEpoch

    /**
     * 对账：返回（要删除的本地消息、要改的归档状态）。
     * - 只看 id ≤ upTo（请求前已同步到的位置）的消息：快照期间新合并进来的消息不在快照里，但不是被删了；
     * - 服务端纪元变了（sameData=false，服务端重建或从备份恢复）时，服务端没有的消息不能当作被删除，只同步归档状态。
     */
    fun reconcile(local: List<Message>, states: Map<Long, Int>, upTo: Long, sameData: Boolean): Pair<Set<Long>, Map<Long, Int>> {
        val del = if (!sameData) emptySet() else local.asSequence().filter { it.id <= upTo && it.id !in states }.map { it.id }.toSet()
        val arch = local.asSequence().mapNotNull { m -> states[m.id]?.takeIf { it != m.archive }?.let { m.id to it } }.toMap()
        return del to arch
    }

    /**
     * 对账要删的 id 分成（明文 → 记为「仅本机保留」，加密 → 照常删除）。账号开了加密时用（e2ee-client.md §7.4）：
     * 离线超过 90 天收不到 purge，服务器上找不到的明文消息可能是被服务器删掉的明文（0.8 以前的「删除服务器上的明文消息」，0.9.0 起客户端没有这个入口；服务端可能还会发，保留兼容）
     */
    fun splitPlain(local: List<Message>, del: Set<Long>): Pair<Set<Long>, Set<Long>> {
        val plain = local.asSequence().filter { it.id in del && it.e2e == null }.map { it.id }.toSet()
        return plain to (del - plain)
    }
}
