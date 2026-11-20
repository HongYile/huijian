package io.github.hongyile.huijian

import okhttp3.Call
import okhttp3.EventListener
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/**
 * oldServer：服务端没有这个接口（路由层的纯文本 404 / 405），说明服务端版本较旧。
 * reason / messageId：错误响应里的 reason、message_id（附件 410：reason "sealed" = 已被服务器补加密、要重新拉这条消息；
 * "missing" = 文件丢失，§11.5）
 */
class ApiException(val status: Int, message: String, val oldServer: Boolean = false,
                   val reason: String? = null, val messageId: Long = 0) : IOException(message)

/** token 失效（设备被移除、退出登录）：停止同步，回到登录页 */
class UnauthorizedException : IOException("登录已失效，请重新登录")

data class LoginResult(val deviceId: String, val name: String, val token: String)

/** changes：带 changes_since 时服务端返回的变更（旧服务端没有时为 null） */
data class MessagePage(val messages: List<Message>, val nextSince: Long?, val latestBuild: Int?, val changes: ChangesPage? = null)

/**
 * 回笺设备接口（docs/api.md）。长轮询的读超时 = wait + 20 秒；
 * 手机睡眠时 OkHttp 的超时计时会暂停，所以连接是否卡死由 SyncService 的看门狗闹钟兜底。
 */
class Api(val server: String, private val token: String?) : E2ENet, AgentNet {

    /** 最近一次响应头 X-Huijian-Server 里的服务端版本：变了说明服务端升级 / 降级过，同步服务据此重新读取 /v1/info */
    @Volatile var serverVersion: String? = null

    /** 当前进行中的长轮询，看门狗或网络切换时取消它以立即重连 */
    @Volatile var inFlight: Call? = null
    @Volatile private var cancelled = false

    /** 并发请求用的子实例（各自记自己的进行中请求）：cancelAll 时一起取消 */
    private val children: MutableSet<Api> = java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap())

    /** 取消正在进行的请求（包括子实例的），并让之后的请求都直接失败（同步循环重启时，旧循环不会再拉后面的分页） */
    fun cancelAll() { cancelled = true; inFlight?.cancel(); children.forEach { it.cancelAll() } }
    val wasCancelled get() = cancelled

    /**
     * 用一个子实例发一次请求（补加密等并发场景：inFlight 只有一个槽，共用一个实例时 cancelAll 只能取消最后一个）。
     * 子实例先登记再检查取消标记，不会漏掉中途的 cancelAll
     */
    fun <T> withChild(block: (Api) -> T): T {
        val c = Api(server, token)
        children += c
        try {
            if (cancelled) c.cancelAll()
            return block(c)
        } finally {
            children -= c
        }
    }

    private fun req(path: String) = req((server + path).toHttpUrl())

    private fun req(url: HttpUrl) = Request.Builder().url(url).apply {
        token?.let { header("Authorization", "Bearer $it") }
        val label = "android ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})"
        header("X-Huijian-Client", label)
        header("X-Hongyan-Client", label) // 改名前的服务端只认旧名
    }

    private fun exec(r: Request, readTimeoutSec: Long = 20, track: Boolean = true, onSent: (() -> Unit)? = null): Response {
        val b = client.newBuilder().readTimeout(readTimeoutSec, TimeUnit.SECONDS)
        if (onSent != null) b.eventListener(object : EventListener() {
            override fun requestHeadersEnd(call: Call, request: Request) = onSent()
        })
        val c = b.build().newCall(r)
        if (cancelled) throw IOException("Canceled")
        if (track) { inFlight = c; if (cancelled) c.cancel() }
        val resp = try { c.execute() } finally { if (track) inFlight = null }
        (resp.header("X-Huijian-Server") ?: resp.header("X-Hongyan-Server"))?.takeIf { it.isNotBlank() }?.let { serverVersion = it }
        if (resp.code == 401) { resp.close(); throw UnauthorizedException() }
        if (!resp.isSuccessful) {
            val body = resp.body?.string().orEmpty()
            resp.close()
            val o = runCatching { JSONObject(body) }.getOrNull()
            val err = o?.optString("error")?.takeIf { it.isNotBlank() }
            val old = err == null && (resp.code == 404 || resp.code == 405)
            throw ApiException(resp.code, err ?: if (old) OLD_SERVER else "HTTP ${resp.code}", old,
                o?.optString("reason")?.takeIf { it.isNotBlank() }, o?.optLong("message_id") ?: 0)
        }
        return resp
    }

    private fun json(r: Request, readTimeoutSec: Long = 20, track: Boolean = true): JSONObject =
        exec(r, readTimeoutSec, track).use { JSONObject(it.body?.string().orEmpty().ifBlank { "{}" }) }

    private fun post(path: String, body: JSONObject) =
        req(path).post(body.toString().toRequestBody(JSON)).build()

    fun info(): JSONObject = json(req("/v1/info").build())

    /**
     * 旧协议：发送密码原文。App 里的登录、注册都走 E2ELogic（新协议，只有服务端没有 e2e 功能时才发原文），这里只留给测试用。
     * register=true 时注册新账号（服务端开放注册时才可用，否则 403）
     */
    fun login(username: String, password: String, name: String, fingerprint: String, register: Boolean = false) = loginResult(
        json(post(if (register) "/v1/register" else "/v1/login", JSONObject().put("username", username).put("password", password)
            .put("name", name).put("platform", "android").put("fingerprint", fingerprint)))
    )

    // ---------- 新登录协议、端到端加密（服务端 0.7.0 起；逻辑在 E2E.kt） ----------

    /** 登录前取密码派生参数；旧服务端是纯文本 404（ApiException.oldServer） */
    override fun prelogin(username: String): JSONObject =
        json(req(server.toHttpUrl().newBuilder().addPathSegments("v1/prelogin").addQueryParameter("username", username).build()).build())

    /** 登录 / 注册，请求体由 E2ELogic 拼好（auth_key / password_key，旧服务端才带 password），返回原始响应（含 e2e） */
    override fun loginRaw(body: JSONObject, register: Boolean): JSONObject =
        json(post(if (register) "/v1/register" else "/v1/login", body))

    override fun e2eState(): JSONObject = json(req("/v1/e2e").build())
    override fun e2eSetup(body: JSONObject): JSONObject = json(post("/v1/e2e/setup", body))
    override fun e2eUnlock(authKey: String): JSONObject = json(post("/v1/e2e/unlock", JSONObject().put("auth_key", authKey)))
    override fun e2eDevice(pub: String, request: Boolean, commit: String?): JSONObject =
        json(req("/v1/e2e/device").put(JSONObject().put("pub", pub).put("request", request)
            .apply { if (commit != null) put("commit", commit) }.toString().toRequestBody(JSON)).build())
    override fun e2eChallenge(deviceId: String, nonce: String) { json(post("/v1/e2e/challenge", JSONObject().put("device_id", deviceId).put("nonce", nonce))) }
    override fun e2eReveal(nonce: String) { json(post("/v1/e2e/reveal", JSONObject().put("nonce", nonce))) }
    override fun e2eGrant(deviceId: String, pub: String, grant: String, kid: String) {
        json(post("/v1/e2e/grant", JSONObject().put("device_id", deviceId).put("pub", pub).put("grant", grant).put("kid", kid)))
    }
    override fun e2eReset(body: JSONObject): JSONObject = json(post("/v1/e2e/reset", body))
    override fun e2eDeny(deviceId: String) { json(post("/v1/e2e/deny", JSONObject().put("device_id", deviceId))) }
    override fun e2eRecovery(body: JSONObject) { json(req("/v1/e2e/recovery").put(body.toString().toRequestBody(JSON)).build()) }
    override fun accountAuth(body: JSONObject): JSONObject = json(req("/v1/account/auth").put(body.toString().toRequestBody(JSON)).build())
    override fun credentials(body: JSONObject): JSONObject = json(post("/v1/account/credentials", body))

    fun pair(code: String, name: String, fingerprint: String) = loginResult(
        json(post("/v1/pair", JSONObject().put("code", code).put("name", name)
            .put("platform", "android").put("fingerprint", fingerprint)))
    )

    private fun loginResult(o: JSONObject) = LoginResult(o.getString("device_id"), o.optString("name"), o.getString("token"))

    fun logout() { exec(req("/v1/logout").post(ByteArray(0).toRequestBody()).build()).close() }

    fun me(): JSONObject = json(req("/v1/me").build())

    fun account(): AccountDetail = Manage.accountDetail(json(req("/v1/account").build()))

    /** 设置 / 修改用户名和密码：password 为空只改用户名；没有密码时本账号任何设备都能设置初始密码，已有密码时需要当前密码 */
    fun setCredentials(username: String, password: String, current: String): AccountInfo =
        Manage.account(json(post("/v1/account/credentials", JSONObject().put("username", username)
            .put("password", password).put("current_password", current))).optJSONObject("account") ?: JSONObject())

    fun createPairCode(): PairCode = Manage.pairCode(json(req("/v1/pair-codes").post(ByteArray(0).toRequestBody()).build()))

    override fun createPairCodeRaw(keyWrap: String?): JSONObject =
        if (keyWrap == null) json(req("/v1/pair-codes").post(ByteArray(0).toRequestBody()).build())
        else json(post("/v1/pair-codes", JSONObject().put("key_wrap", keyWrap)))

    override fun pairRaw(body: JSONObject): JSONObject = json(post("/v1/pair", body))

    fun pairCodeStatus(code: String): PairCodeStatus = Manage.pairStatus(json(req(pathUrl("v1/pair-codes", code)).build()))

    fun revokeDevice(id: String) { exec(req(pathUrl("v1/devices", id, "revoke")).post(ByteArray(0).toRequestBody()).build()).close() }

    /**
     * 带参数的接口地址：参数只允许字母、数字、_、-（配对码、设备 ID 都是这种格式），
     * 用 addPathSegment 拼接，参数里的 / ? # 之类不会改变请求的路径
     */
    private fun pathUrl(prefix: String, param: String, suffix: String = ""): HttpUrl {
        if (!SEGMENT.matches(param)) throw ApiException(400, "参数格式不对")
        return server.toHttpUrl().newBuilder().addPathSegments(prefix).addPathSegment(param)
            .apply { if (suffix.isNotEmpty()) addPathSegments(suffix) }.build()
    }

    // ---------- agent 双向（服务端 0.10.0 起，docs/agent-mcp.md §11.3；逻辑在 Agent.kt） ----------

    override fun agentKeys(): JSONObject = json(req("/v1/agent/keys").build())
    override fun agentCreateKey(): JSONObject = json(post("/v1/agent/keys", JSONObject()))
    override fun agentRevokeKey(id: Long) { exec(req("/v1/agent/keys/$id").delete().build()).close() }
    override fun agentSessions(): JSONObject = json(req("/v1/agent/sessions").build())
    override fun agentEnd(id: String) { exec(req(pathUrl("v1/agent/sessions", id)).delete().build()).close() }
    override fun agentChallenge(id: String, nonce: String) {
        json(req(pathUrl("v1/agent/sessions", id, "challenge")).post(JSONObject().put("nonce", nonce).toString().toRequestBody(JSON)).build())
    }
    override fun agentApprove(id: String, attest: String) {
        json(req(pathUrl("v1/agent/sessions", id, "approve")).post(JSONObject().put("attest", attest).toString().toRequestBody(JSON)).build())
    }
    override fun agentDeny(id: String) {
        json(req(pathUrl("v1/agent/sessions", id, "deny")).post(JSONObject().toString().toRequestBody(JSON)).build())
    }
    override fun agentReply(msgId: Long, envelope: String, copy: String): JSONObject =
        json(post("/v1/agent/replies", JSONObject().put("msg_id", msgId).put("e2e", envelope).put("copy", copy)))
    override fun agentReplyStatus(msgId: Long): JSONObject =
        json(req(server.toHttpUrl().newBuilder().addPathSegments("v1/agent/replies/status").addQueryParameter("msg_id", msgId.toString()).build()).build())

    /** 给本机改名，返回服务端保存后的名称 */
    fun renameMe(name: String): String =
        json(req("/v1/me").patch(JSONObject().put("name", name).toString().toRequestBody(JSON)).build()).optString("name", name)

    /**
     * 拉取 id > since 的消息；since 为 null 时返回最新的 limit 条。
     * wait > 0 时是长轮询：没有新消息就挂起，最多 wait 秒（服务端上限见 /v1/info 的 long_poll_max，旧服务端 55）。
     */
    /** onSent：请求已发出（长轮询开始等待）时回调，同步服务在这里放开 WakeLock */
    /** changesSince 不为 null 时一并返回之后的删除 / 归档 / 设置变更（有新变更也会立即唤醒长轮询） */
    fun messages(since: Long?, limit: Int = 200, wait: Int = 0, changesSince: Long? = null, onSent: (() -> Unit)? = null): MessagePage {
        val q = buildString {
            append("/v1/messages?limit=$limit")
            if (since != null) append("&since=$since")
            if (wait > 0) append("&wait=$wait")
            if (changesSince != null) append("&changes_since=$changesSince")
        }
        exec(req(q).build(), readTimeoutSec = wait + 20L, track = true, onSent = onSent).use { resp ->
            val o = JSONObject(resp.body?.string().orEmpty())
            val arr = o.optJSONArray("messages")
            val list = if (arr == null) emptyList() else List(arr.length()) { Message.fromServer(arr.getJSONObject(it)) }
            return MessagePage(
                messages = list,
                nextSince = if (o.has("next_since")) o.optLong("next_since") else null,
                latestBuild = (resp.header("X-Huijian-Latest-Build") ?: resp.header("X-Hongyan-Latest-Build"))?.toIntOrNull(),
                changes = if (changesSince != null) Changes.parse(o) else null,
            )
        }
    }

    /** 单条消息（服务端 0.8.0 起，§11.5）：被服务器补加密（变更 kind "sealed"）后重新拉取。不存在时 ApiException(404) */
    fun message(id: Long): Message = Message.fromServer(json(req("/v1/messages/$id").build()).getJSONObject("message"))

    /** 对账：本账号全部消息的归档状态、变更游标、服务端数据纪元（服务端 0.5.4 起） */
    fun messageStates(): MessageStates = Changes.parseStates(json(req("/v1/messages/state").build(), readTimeoutSec = 60))

    /** 频道设置（服务端 0.5.5 起）；旧服务端没有这个接口时返回空 */
    fun channels(): List<ChannelSetting> {
        val arr = try { json(req("/v1/channels").build()).optJSONArray("channels") } catch (e: ApiException) {
            if (e.status == 404 || e.status == 405) return emptyList() else throw e
        } ?: return emptyList()
        return List(arr.length()) {
            val o = arr.getJSONObject(it)
            ChannelSetting(o.optString("topic"), o.optString("alias"), o.optBoolean("hidden"),
                o.optBoolean("muted"), o.optBoolean("pinned"), o.optInt("sort"))
        }
    }

    fun keys(): List<PushKey> = Manage.keys(json(req("/v1/keys").build()))

    /** 新建；key 为空时服务端自动生成 */
    fun createKey(name: String, key: String = ""): PushKey =
        Manage.key(json(post("/v1/keys", JSONObject().put("name", name).apply { if (key.isNotBlank()) put("key", key.trim()) })))

    /** 改名 / 换 key（空字符串表示不改）；换 key 后旧 key 立即失效 */
    fun updateKey(id: Long, name: String, key: String): PushKey =
        Manage.key(json(req("/v1/keys/$id").patch(JSONObject().put("name", name).put("key", key.trim()).toString().toRequestBody(JSON)).build()))

    fun revokeKey(id: Long): PushKey = Manage.key(json(req("/v1/keys/$id/revoke").post(ByteArray(0).toRequestBody()).build()))

    /** 删除一把已吊销的 key（服务端 0.5.2 起） */
    fun deleteKey(id: Long) { exec(req("/v1/keys/$id").delete().build()).close() }

    /** 本机对每把 key 的接收方式；服务端太旧时返回 null */
    fun subscriptions(): Map<Long, String>? = try {
        Manage.subscriptions(json(req("/v1/subscriptions").build()))
    } catch (e: ApiException) { if (e.oldServer) null else throw e }

    fun setSubscription(keyId: Long, mode: String) {
        exec(req("/v1/subscriptions/$keyId").put(JSONObject().put("mode", mode).toString().toRequestBody(JSON)).build()).close()
    }

    /** 修改频道设置（只改传了的字段），返回修改后的设置 */
    fun updateChannel(topic: String, alias: String? = null, hidden: Boolean? = null, muted: Boolean? = null, pinned: Boolean? = null): ChannelSetting {
        val b = JSONObject().put("topic", topic)
        alias?.let { b.put("alias", it) }; hidden?.let { b.put("hidden", it) }
        muted?.let { b.put("muted", it) }; pinned?.let { b.put("pinned", it) }
        return Manage.channel(json(req("/v1/channels").patch(b.toString().toRequestBody(JSON)).build()))
    }

    /** 手动排序；空列表 = 恢复按最近活跃排序 */
    fun setChannelOrder(topics: List<String>) {
        exec(req("/v1/channels/order").put(JSONObject().put("topics", org.json.JSONArray(topics)).toString().toRequestBody(JSON)).build()).close()
    }

    /** 删除频道：这个频道的全部消息（附件一起）和设置，返回删除条数 */
    fun deleteChannel(topic: String): Int = json(post("/v1/channels/delete", JSONObject().put("topic", topic))).optInt("deleted")

    /** 用本账号的一把 pushkey 给自己发一条测试消息（走公开的发送接口） */
    fun push(pushkey: String, text: String, desp: String, priority: Int, topic: String) {
        val body = FormBody.Builder().add("pushkey", pushkey).add("text", text).add("desp", desp)
            .add("priority", priority.toString()).add("topic", topic).build()
        exec(Request.Builder().url("$server/message/push").post(body).build()).close()
    }

    /**
     * 下载附件到 dest，校验 sha256；失败时删除半成品。
     * 临时文件在同目录下用 createTempFile 取唯一名字，两个下载同时进行也不会写进同一个文件。
     */
    fun download(att: Attachment, dest: File) {
        dest.parentFile?.mkdirs()
        val tmp = File.createTempFile("att", ".part", dest.parentFile)
        try {
            var want = att.sha256
            exec(req("/v1/att/${att.id}").build(), readTimeoutSec = 60).use { resp ->
                val md = MessageDigest.getInstance("SHA-256")
                resp.body!!.byteStream().use { input ->
                    tmp.outputStream().use { out ->
                        val buf = ByteArray(64 * 1024)
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            md.update(buf, 0, n); out.write(buf, 0, n)
                        }
                    }
                }
                val got = md.digest().joinToString("") { "%02x".format(it) }
                want = (resp.header("X-Huijian-Sha256") ?: resp.header("X-Hongyan-Sha256")) ?: att.sha256
                if (want.isNotBlank() && !got.equals(want, ignoreCase = true)) throw IOException("附件校验失败")
            }
            commit(tmp, dest, want)
        } finally {
            tmp.delete()      // 成功时已改名，这里删不到东西
        }
    }

    companion object {
        const val OLD_SERVER = "服务端版本较旧，不支持这个功能，请更新服务端"

        /** 路径参数允许的格式 */
        internal val SEGMENT = Regex("^[A-Za-z0-9_-]{1,128}$")

        /**
         * 把下载好的临时文件改名为 dest。改名失败（比如另一份下载刚把同一附件写好）时，
         * dest 已存在且校验通过就算成功；否则报错。
         */
        internal fun commit(tmp: File, dest: File, want: String) {
            if (tmp.renameTo(dest)) return
            if (dest.isFile && (want.isBlank() || sha256(dest).equals(want, ignoreCase = true))) return
            throw IOException("保存附件失败")
        }

        internal fun sha256(f: File): String {
            val md = MessageDigest.getInstance("SHA-256")
            f.inputStream().use { input ->
                val buf = ByteArray(64 * 1024)
                while (true) { val n = input.read(buf); if (n < 0) break; md.update(buf, 0, n) }
            }
            return md.digest().joinToString("") { "%02x".format(it) }
        }

        private val JSON = "application/json; charset=utf-8".toMediaType()
        private val client = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
            .build()

        /** 规范化服务器地址：去空白和末尾斜杠；没写协议时，IP / localhost 用 http，域名用 https（与 Mac 端一致） */
        fun normalize(raw: String): String {
            var s = raw.trim().trimEnd('/')
            if (s.isEmpty()) return s
            if (!s.contains("://")) {
                val host = s.substringBefore('/').substringBefore(':')
                val plain = host == "localhost" || host.endsWith(".local") ||
                    host.matches(Regex("""\d+\.\d+\.\d+\.\d+""")) || s.startsWith("[")
                s = (if (plain) "http://" else "https://") + s
            }
            return s
        }
    }
}
