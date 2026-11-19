package io.github.hongyile.huijian

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
    /** 端到端加密（开启、设备请求批准 / 已批准、只接受加密消息）：重新 GET /v1/e2e */
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
        /** 服务端 0.7.0 起：「删除服务器上的明文消息」删掉的消息（kind purge），本机副本保留、记为「仅本机保留」 */
        val purged: Set<Long> = emptySet(),
    ) {
        val isEmpty get() = deleted.isEmpty() && archive.isEmpty() && refresh.isEmpty() && purged.isEmpty()
    }

    /**
     * 按 kind 分发：delete / archive 针对消息（id 0 不是消息，忽略）；channels / keys / devices / account 是设置变更
     * （devices、account 都重新拉 /v1/account；e2e 重新拉 /v1/e2e；purge 是服务器删了明文、本机保留）；不认识的 kind 忽略。按顺序应用：先删除后又出现的归档以删除为准。
     */
    fun plan(changes: List<MsgChange>): Plan {
        val del = LinkedHashSet<Long>()
        val arch = LinkedHashMap<Long, Int>()
        val refresh = LinkedHashSet<SettingKind>()
        val purged = LinkedHashSet<Long>()
        for (c in changes) when (c.kind) {
            "delete" -> if (c.id > 0) { del += c.id; arch.remove(c.id); purged.remove(c.id) }
            "purge" -> if (c.id > 0 && c.id !in del) purged += c.id
            "archive" -> if (c.id > 0 && c.id !in del) arch[c.id] = c.state ?: 0
            "channels" -> refresh += SettingKind.CHANNELS
            "keys" -> refresh += SettingKind.KEYS
            "devices", "account" -> refresh += SettingKind.ACCOUNT
            "e2e" -> refresh += SettingKind.E2E
            else -> {}
        }
        return Plan(del, arch, refresh, purged)
    }

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
}
