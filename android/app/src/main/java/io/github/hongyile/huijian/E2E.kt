package io.github.hongyile.huijian

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/*
 * 端到端加密的客户端逻辑（docs/e2ee-client.md）：登录协议、开启加密、三种解锁、批准其他设备、解密消息。
 * 不依赖 Android：密码学计算经 E2ECrypto（正式实现是 Core，Rust 共用核心），网络经 E2ENet（正式实现是 Api），
 * 「已升级」标记经 UpgradeFlags。单元测试换成假实现，测状态机和协议规则。
 * 界面、Keystore、通知这些和 Android 有关的部分在 E2EHub.kt。
 */

/** 文案（docs/e2ee-client.md 第 9 节，三端一致） */
object E2EText {
    const val T1 = "这个账号已经升级到新的登录方式，服务器却要求用旧方式登录。可能有人冒充服务器，已停止登录。如果管理员刚重设过你的密码：请用配对码登录，解锁后重新设置密码。"
    const val T2 = "服务器给的密码保护参数不安全，已拒绝登录。可能有人冒充服务器。"
    const val T3 = "密码不对"
    const val T10 = "🔒 加密消息已锁定：点这里解锁"
    const val T20_TITLE = "开启端到端加密"
    const val T20 = "开启后，新消息的标题、正文和附件只有你登录过的设备能解开，服务器和备份里只有密文。发送端要换成「加密发送密钥」才会加密。旧消息保持原样。"
    const val T21_TITLE = "保存恢复码"
    const val T21 = "忘记密码、又没有其他设备可以批准时，只能用它解锁加密消息。恢复码只显示这一次，请抄下来或存进密码管理器。"
    const val T21_CHECK = "我已把恢复码保存好"
    const val T22 = "已开启端到端加密。到「Pushkey」页复制「加密发送密钥」，换掉脚本里原来的 pushkey，新消息就会加密。"
    const val T30_TITLE = "请另一台设备批准"
    const val T30 = "在另一台已解锁的设备上打开回笺，它会提示有设备请求解锁。"
    fun t31(code: String) = "核对码 ${sasText(code)}：确认和另一台设备上显示的一样，再在那台设备上点「一致，批准」。"
    const val T32 = "另一台设备拒绝了这次请求。"
    const val T40_TITLE = "用恢复码解锁"
    const val T40_PLACEHOLDER = "XXXXX-XXXXX-XXXXX-XXXXX-XXXXXX"
    const val T41 = "恢复码不对，或者已经被更换。"
    const val T42_TITLE = "重新设置密码"
    const val T42 = "管理员重设过你的密码，需要设置一个新密码来保护加密钥匙。"
    /** T42 页「当前密码」输入框的说明 */
    const val T42_CURRENT = "填管理员告诉你的临时密码，不要填你自己原来的密码。"
    const val T43 = "收到的钥匙和账号的钥匙对不上，已丢弃。可能有人冒充服务器。"
    const val T44 = "用密码解锁失败：管理员可能重设过你的密码。请用恢复码或另一台设备解锁，解锁后重新设置密码。"
    fun t50(name: String) = "「$name」请求解锁加密消息：打开回笺核对后批准。"
    const val T51 = "这个请求已经由另一台设备处理。"
    const val T52 = "核对失败，可能有人冒充这台设备，已拒绝。"
    fun t53(code: String) = "核对码 ${sasText(code)}：和新设备上显示的一致吗？"
    const val T60 = "🔒 加密消息（解锁后查看）"
    const val T61 = "🔒 用别的钥匙加密的消息，这台设备解不开"
    const val T62 = "🔒 加密消息已损坏，无法解开"
    const val T63 = "未加密：发送端用的是普通 pushkey"
    const val T70 = "发送端用它代替 pushkey，消息会在发送端加密，只有你的设备能解开。它只能加密、不能解密，泄露了也看不到你的消息。"
    const val T71 = "打开后，服务器拒收没有加密的消息，防止有脚本忘了换成加密发送密钥。"
    const val T73 = "本机解锁一次后才显示（防止被冒充的服务器换掉公钥）。"
    const val T72 = "删除服务器上本账号的全部明文消息？加密消息不受影响，本机已同步的消息保留。服务器以前做的备份里仍有这些消息。"

    /** 详情页元信息行里加密消息的标记 */
    const val ENCRYPTED = "🔒 端到端加密"
    const val WEAK_CURRENT = "当前密码不够安全，请换一个新密码"
    const val LOCKED_CHANGE = "本机处于锁定状态，请先解锁加密消息再改密码"
    const val NO_PRELOGIN = "服务器没有返回密码派生参数（prelogin 不存在），无法安全地核对密码，已停止。"
    const val SETUP_RETRY = "开启加密时网络出错，服务器上还没有开启，请重试。"
    const val SETUP_UNSURE = "开启加密时网络出错，暂时无法确认是否已经开启。请稍后点「开启端到端加密」重试（会先核对，不会重复开启）。"
    const val GRANT_BAD = "转交来的钥匙解不开，请重新请求批准"
    const val WRAP_GONE = "用密码锁住的私钥已失效（管理员重设过密码）：请用另一台设备批准，或用恢复码解锁"

    /** 6 位核对码按 3+3 显示：482 913 */
    fun sasText(code: String) = if (code.length == 6) code.take(3) + " " + code.drop(3) else code
}

/** 加密相关的失败，message 直接显示给用户 */
class E2EError(message: String, val kind: Kind = Kind.OTHER, val pending: SetupResult? = null) : Exception(message) {
    enum class Kind {
        OTHER,
        /** 新密码（或注册密码）强度不够：显示在密码框下面 */
        WEAK_PASSWORD,
        /** 开启加密时没勾选换密码，而当前密码不够安全：自动勾选「同时换一个新密码」 */
        WEAK_CURRENT,
        /** 当前密码不对（服务端 403，T3） */
        WRONG_PASSWORD,
        /** 用密码锁住的私钥已失效：引导用户用另外两种方式解锁 */
        WRAP_INVALID,
        /** 别的设备刚开启过加密（409）：重新读取状态 */
        CONFLICT,
        /** 收到的钥匙和账号的钥匙对不上（T43） */
        MISMATCH,
        /** 开启加密时网络出错、又取不到状态：pending 里的钥匙和恢复码留在内存里，重试时先核对 */
        SETUP_UNSURE,
    }
}

// ---------- 接口：正式实现是 Core / Api / Store，测试时换成假的 ----------

/** 共用核心里加密用到的操作（Core 的子集，签名一致） */
interface E2ECrypto {
    fun passwordKeys(password: String, saltHex: String): Pair<String, String>
    fun pbkdf2(password: String, saltHex: String, iterations: Int): String
    fun newSalt(): String
    fun passwordProblem(password: String, username: String): String?
    fun keypair(): Core.KeyPair
    fun publicKey(sk: String): Pair<String, String>
    fun random32(): String
    fun wrap(prefix: String, key: String, data: String): String
    fun unwrap(prefix: String, key: String, wrap: String): String
    fun recoveryNew(): Pair<String, String>
    fun recoveryKey(code: String): String
    fun grantSeal(sk: String, pub: String): String
    fun grantOpen(deviceSk: String, grant: String): String
    fun sasCommit(pub: String, account: String, nonce: String): String
    fun sasCode(pub: String, account: String, na: String, nb: String): String
    fun openMessage(keys: List<String>, envelope: String): JSONObject
    fun mdBuild(text: String, desp: String, atts: List<Map<String, Any?>>): Pair<String, String>
    fun decryptFile(key: String, src: File, dst: File)
}

/** 正式实现：Rust 共用核心（第一次用到时才加载 .so） */
object CoreCrypto : E2ECrypto {
    override fun passwordKeys(password: String, saltHex: String) = Core.passwordKeys(password, saltHex)
    override fun pbkdf2(password: String, saltHex: String, iterations: Int) = Core.pbkdf2(password, saltHex, iterations)
    override fun newSalt() = Core.newSalt()
    override fun passwordProblem(password: String, username: String) = Core.passwordProblem(password, username)
    override fun keypair() = Core.keypair()
    override fun publicKey(sk: String) = Core.publicKey(sk)
    override fun random32() = Core.random32()
    override fun wrap(prefix: String, key: String, data: String) = Core.wrap(prefix, key, data)
    override fun unwrap(prefix: String, key: String, wrap: String) = Core.unwrap(prefix, key, wrap)
    override fun recoveryNew() = Core.recoveryNew()
    override fun recoveryKey(code: String) = Core.recoveryKey(code)
    override fun grantSeal(sk: String, pub: String) = Core.grantSeal(sk, pub)
    override fun grantOpen(deviceSk: String, grant: String) = Core.grantOpen(deviceSk, grant)
    override fun sasCommit(pub: String, account: String, nonce: String) = Core.sasCommit(pub, account, nonce)
    override fun sasCode(pub: String, account: String, na: String, nb: String) = Core.sasCode(pub, account, na, nb)
    override fun openMessage(keys: List<String>, envelope: String) = Core.openMessage(keys, envelope)
    override fun mdBuild(text: String, desp: String, atts: List<Map<String, Any?>>) = Core.mdBuild(text, desp, atts)
    override fun decryptFile(key: String, src: File, dst: File) = Core.decryptFile(key, src, dst)
}

/**
 * 加密用到的服务端接口（docs/api.md「账号」「端到端加密」），Api 实现它。
 * 失败抛 ApiException（oldServer = 路由层的纯文本 404，说明服务端没有这个接口）/ UnauthorizedException / IOException。
 */
interface E2ENet {
    fun prelogin(username: String): JSONObject
    fun loginRaw(body: JSONObject, register: Boolean): JSONObject
    fun e2eState(): JSONObject
    fun e2eSetup(body: JSONObject): JSONObject
    fun e2eUnlock(authKey: String): JSONObject
    fun e2eDevice(pub: String, request: Boolean, commit: String?): JSONObject
    fun e2eChallenge(deviceId: String, nonce: String)
    fun e2eReveal(nonce: String)
    fun e2eGrant(deviceId: String, pub: String, grant: String)
    fun e2eDeny(deviceId: String)
    fun e2eRecovery(body: JSONObject)
    fun e2eSetOnly(only: Boolean): JSONObject
    fun e2eDeletePlain(): Int
    fun accountAuth(body: JSONObject): JSONObject
    fun credentials(body: JSONObject): JSONObject
}

/** 「这个服务器上的这个账号已升级到新登录协议」标记：普通偏好设置，退出登录也不删 */
interface UpgradeFlags {
    fun isUpgraded(server: String, username: String): Boolean
    fun markUpgraded(server: String, username: String)

    companion object {
        /** 标记的键：规范化的服务器地址 + 用户名（规范化空白、小写；服务端登录时不区分大小写） */
        fun key(server: String, username: String) = canonicalServer(server) + "|" + Manage.normalizeUsername(username).lowercase()
    }
}

// ---------- 数据 ----------

data class E2EKeyInfo(val kid: String, val pub: String, val active: Boolean)

/** GET /v1/e2e 的 device：本机登记的公钥、转交给本机的副本、批准请求的进度 */
data class E2EDevice(val pub: String, val grant: String, val requested: Boolean, val challenge: String, val revealed: Boolean)

/** 等待批准的其他设备 */
data class E2ERequest(
    val deviceId: String, val name: String, val platform: String, val pub: String, val requestedAt: Long,
    val commit: String, val challenge: String, val reveal: String,
)

/** GET /v1/e2e */
data class E2EState(
    val enabled: Boolean,
    val keys: List<E2EKeyInfo>,
    val e2eOnly: Boolean,
    /** 账号已升级到新登录协议 */
    val authKey: Boolean,
    val hasPasswordWrap: Boolean,
    val recoveryWrap: String,
    val device: E2EDevice,
    val requests: List<E2ERequest>,
) {
    val activeKey get() = keys.firstOrNull { it.active }

    /** 管理员重设过密码（账号回到旧登录方式，或密码副本已失效）：解锁后要重新设置密码（§4.4，T42） */
    val needsNewPassword get() = enabled && (!authKey || !hasPasswordWrap)

    companion object {
        fun parseKeys(a: JSONArray?): List<E2EKeyInfo> = objects(a).map {
            E2EKeyInfo(it.optString("kid"), it.optString("pub"), it.optBoolean("active"))
        }

        fun parse(o: JSONObject): E2EState {
            val d = o.optJSONObject("device") ?: JSONObject()
            return E2EState(
                enabled = o.optBoolean("enabled"),
                keys = parseKeys(o.optJSONArray("keys")),
                e2eOnly = o.optBoolean("e2e_only"),
                authKey = o.optBoolean("auth_key"),
                hasPasswordWrap = o.optBoolean("has_password_wrap"),
                recoveryWrap = o.optString("recovery_wrap"),
                device = E2EDevice(d.optString("pub"), d.optString("grant"), d.optBoolean("requested"),
                    d.optString("challenge"), d.optBoolean("revealed")),
                requests = objects(o.optJSONArray("requests")).map {
                    E2ERequest(it.optString("device_id"), it.optString("name"), it.optString("platform"), it.optString("pub"),
                        it.optLong("requested_at"), it.optString("commit"), it.optString("challenge"), it.optString("reveal"))
                },
            )
        }

        private fun objects(a: JSONArray?): List<JSONObject> =
            if (a == null) emptyList() else (0 until a.length()).mapNotNull { a.optJSONObject(it) }
    }
}

/** 本机保存的一把账号私钥（kid、公钥都是本机用私钥算出来的，不信服务器给的） */
data class LocalKey(val kid: String, val pub: String, val sk: String)

/** 加密状态（§3） */
enum class E2EStatus {
    /** 还没读到 */
    UNKNOWN,
    /** 服务端没有 e2e 功能 */
    UNSUPPORTED,
    DISABLED,
    LOCKED,
    UNLOCKED,
}

/** 「当前密码」凭证（§2.4）：field 是 current_auth_key / current_password_key / current_password（只用于没有 e2e 的旧服务端） */
data class Cred(val field: String, val value: String, val unlock: String? = null) {
    fun into(o: JSONObject): JSONObject = o.put(field, value)
}

/** 账号密码登录 / 注册的结果。keys：登录时顺带解开的私钥（调用方在 Hub.signedIn 之后保存） */
data class LoginOutcome(val result: LoginResult, val keys: List<LocalKey> = emptyList(), val notice: String? = null, val upgraded: Boolean = false)

data class SetupResult(val key: LocalKey, val recoveryCode: String)

// ---------- 逻辑 ----------

/**
 * 服务器地址规范化（§1）：scheme、host 小写，去掉默认端口（http 80、https 443）和末尾的 /。
 * 「已升级」标记、钉住的公钥、本机私钥都按规范化后的地址记，换一种写法（https://x:443）绕不过去
 */
fun canonicalServer(raw: String): String {
    val t = raw.trim().trimEnd('/')
    val u = runCatching { java.net.URI(t) }.getOrNull() ?: return t.lowercase()
    val scheme = u.scheme?.lowercase() ?: return t.lowercase()
    val host = u.host?.lowercase() ?: return t.lowercase()
    val port = u.port.takeIf { it != -1 && !(scheme == "http" && it == 80) && !(scheme == "https" && it == 443) }
    return "$scheme://$host" + (port?.let { ":$it" } ?: "") + (u.rawPath ?: "").trimEnd('/')
}

/** Pushkey 页的加密发送密钥（§7 第 1 项）：key 为空时显示 note（T73 / T43） */
data class SendKey(val key: String?, val note: String?)

/**
 * 本机已经知道的情况（不是这一次 prelogin 告诉的），防降级时和「已升级」标记一起用（§2.1 第 4 条、§2.4）。
 * localUsername：本机登录时记下的用户名（不随服务器 /v1/account 返回的变）；authKey：GET /v1/e2e 说账号已升级；
 * hasE2E：这次运行里读到过 GET /v1/e2e（服务端一定有 prelogin）
 */
data class Known(val localUsername: String? = null, val authKey: Boolean = false, val hasE2E: Boolean = false)

/** known：已登录时的本机情况（登录、注册不用它：那时还不知道是不是同一个账号） */
class E2ELogic(private val c: E2ECrypto, private val flags: UpgradeFlags, private val known: () -> Known = { Known() }) {

    /** 服务器给的密码派生方式 */
    sealed interface Kdf {
        data class Argon(val salt: String) : Kdf
        data class Pbkdf2(val salt: String, val iterations: Int) : Kdf
        /** 服务端没有 e2e 功能（prelogin 是纯文本 404）且账号没有「已升级」标记：只有这时才能按旧方式发原文 */
        data object Legacy : Kdf
    }

    /** 在哪里计算密码凭证：决定 prelogin 404、已升级账号收到 pbkdf2 时怎么办 */
    enum class Use {
        /** 登录、注册、改用户名、改密码、设置初始密码：prelogin 纯文本 404 且没有「已升级」标记时按旧方式 */
        ACCOUNT,
        /** 开启加密、更换恢复码等 /v1/e2e/… 和新接口：服务端一定有 prelogin，404 直接报错 */
        E2E,
        /** 用密码解锁（§4.2）：已升级的账号收到 pbkdf2 时显示 T44 */
        UNLOCK,
        /** 「重新设置密码」页（§4.4 第 4 步）：唯一允许已升级的账号走 pbkdf2 的地方 */
        RESET,
    }

    /**
     * GET /v1/prelogin 并按 §2.1 核对：参数不对 → T2；已升级的账号却收到 pbkdf2 / 旧服务端 → T1（解锁时 T44）。
     * 「已升级」：这个用户名或本机登录时记下的用户名有标记，或者 GET /v1/e2e 说 auth_key 为真
     */
    fun kdf(net: E2ENet, server: String, username: String, use: Use = Use.ACCOUNT, k: Known = Known()): Kdf {
        val upgraded = flags.isUpgraded(server, username) ||
            k.localUsername?.takeIf { it.isNotBlank() }?.let { flags.isUpgraded(server, it) } == true || k.authKey
        val o = try {
            net.prelogin(username)
        } catch (e: ApiException) {
            // 只有纯文本 404 才算「服务端没有 e2e」；5xx、网络错误照常报错
            if (!e.oldServer) throw e
            if (use != Use.ACCOUNT) throw E2EError(E2EText.NO_PRELOGIN)
            if (upgraded) throw E2EError(E2EText.T1)
            // 这次运行里读到过 /v1/e2e：服务端一定有 prelogin，404 是有人在篡改
            if (k.hasE2E) throw E2EError(E2EText.NO_PRELOGIN)
            return Kdf.Legacy
        }
        return when (o.optString("kdf")) {
            "argon2id" -> {
                val salt = o.optString("salt")
                val ok = o.optInt("time", -1) == ARGON_TIME && o.optInt("memory_kib", -1) == ARGON_MEMORY_KIB &&
                    o.optInt("lanes", -1) == ARGON_LANES && salt.length >= 32 && salt.length % 2 == 0 && salt.all { it in HEX }
                if (!ok) throw E2EError(E2EText.T2)
                Kdf.Argon(salt.lowercase())
            }
            "pbkdf2-sha256" -> {
                if (upgraded) when (use) {
                    Use.RESET -> {}
                    Use.UNLOCK -> throw E2EError(E2EText.T44, E2EError.Kind.WRAP_INVALID)
                    else -> throw E2EError(E2EText.T1)
                }
                Kdf.Pbkdf2(o.optString("salt"), o.optInt("iterations", 0))
            }
            else -> throw E2EError(E2EText.T2)
        }
    }

    private fun pbkdf2(password: String, k: Kdf.Pbkdf2): String = try {
        c.pbkdf2(password, k.salt, k.iterations)
    } catch (e: Core.Failure) {
        throw if (e.code == "weak_params" || e.code == "bad_request") E2EError(E2EText.T2) else e
    }

    private fun credOf(k: Kdf, password: String): Cred = when (k) {
        is Kdf.Argon -> c.passwordKeys(password, k.salt).let { (auth, unlock) -> Cred("current_auth_key", auth, unlock) }
        is Kdf.Pbkdf2 -> Cred("current_password_key", pbkdf2(password, k))
        Kdf.Legacy -> Cred("current_password", password)
    }

    /** §2.4：按 prelogin 算出「当前密码」凭证（argon2 时顺带得到解锁钥匙）；已登录时用，带上本机已知情况 */
    fun credential(net: E2ENet, server: String, username: String, password: String, use: Use = Use.ACCOUNT): Cred =
        credOf(kdf(net, server, username, use, known()), password)

    // ---------- 登录、注册（§2） ----------

    private fun loginBody(username: String, name: String, fingerprint: String) = JSONObject()
        .put("username", username).put("name", name).put("platform", "android").put("fingerprint", fingerprint)

    /**
     * 账号密码登录（§2.1）。authed(token)：用新 token 访问接口（PBKDF2 登录后自动升级用）。
     * 从不发送密码原文，只有一个例外：prelogin 是纯文本 404，且账号没有「已升级」标记。
     * 顺带解开的私钥只核对服务器的 keys；和钉住的公钥比对要等知道账号 id 之后（E2EHub.adopt）
     */
    fun login(net: E2ENet, server: String, username: String, password: String, name: String, fingerprint: String,
              authed: (String) -> E2ENet): LoginOutcome {
        val body = loginBody(username, name, fingerprint)
        when (val k = kdf(net, server, username)) {
            Kdf.Legacy -> return LoginOutcome(loginResult(net.loginRaw(body.put("password", password), register = false)))
            is Kdf.Argon -> {
                val (auth, unlock) = c.passwordKeys(password, k.salt)
                val o = net.loginRaw(body.put("auth_key", auth), register = false)
                val r = loginResult(o)
                flags.markUpgraded(server, username)
                val e = o.optJSONObject("e2e")
                val wrap = e?.optString("password_wrap").orEmpty()
                if (e == null || !e.optBoolean("enabled") || wrap.isEmpty()) return LoginOutcome(r, upgraded = true)
                // unwrap 失败（管理员重设过密码等）不阻止登录，进入「已锁定」；钥匙对不上时丢弃并提示 T43
                val sk = try { c.unwrap("hjp1", unlock, wrap) } catch (_: Exception) { return LoginOutcome(r, upgraded = true) }
                return try {
                    LoginOutcome(r, listOf(verify(sk, E2EState.parseKeys(e.optJSONArray("keys")), null)), upgraded = true)
                } catch (x: E2EError) {
                    LoginOutcome(r, notice = x.message, upgraded = true)
                }
            }
            is Kdf.Pbkdf2 -> {
                val pk = pbkdf2(password, k)
                val r = loginResult(net.loginRaw(body.put("password_key", pk), register = false))
                // 登录后立即自动升级；失败不影响登录，下次登录再试
                val up = try { autoUpgrade(authed(r.token), server, username, password, pk) } catch (_: Exception) { false }
                return LoginOutcome(r, upgraded = up)
            }
        }
    }

    /** §2.1 第 7 步：PBKDF2 登录后升级到 Argon2id。账号已开启加密（管理员重设过密码）时先不升级，等解锁后在 §4.4 完成 */
    fun autoUpgrade(net: E2ENet, server: String, username: String, password: String, passwordKey: String): Boolean {
        if (E2EState.parse(net.e2eState()).enabled) return false
        val salt = c.newSalt()
        val (auth, _) = c.passwordKeys(password, salt)
        net.accountAuth(JSONObject().put("current_password_key", passwordKey).put("auth_salt", salt).put("auth_key", auth))
        flags.markUpgraded(server, username)
        return true
    }

    /** 注册（§2.2）：服务端有 e2e 时用新协议，密码强度由核心库检查；旧服务端（且没有「已升级」标记）按原来的方式 */
    fun register(net: E2ENet, server: String, username: String, password: String, name: String, fingerprint: String): LoginOutcome {
        val body = loginBody(username, name, fingerprint)
        if (kdf(net, server, username) == Kdf.Legacy) {
            return LoginOutcome(loginResult(net.loginRaw(body.put("password", password), register = true)))
        }
        c.passwordProblem(password, username)?.let { throw E2EError(it, E2EError.Kind.WEAK_PASSWORD) }
        val salt = c.newSalt()
        val (auth, _) = c.passwordKeys(password, salt)
        val r = loginResult(net.loginRaw(body.put("auth_key", auth).put("auth_salt", salt), register = true))
        flags.markUpgraded(server, username)
        return LoginOutcome(r, upgraded = true)
    }

    private fun loginResult(o: JSONObject) = LoginResult(o.getString("device_id"), o.optString("name"), o.getString("token"))

    // ---------- 状态、核对（§3、§4.5） ----------

    /** pinned：本机钉住的账号公钥；有时，只有和它相同的本机私钥才算解锁 */
    fun status(st: E2EState?, local: List<LocalKey>, pinned: String? = null): E2EStatus = when {
        st == null -> E2EStatus.UNKNOWN
        !st.enabled -> E2EStatus.DISABLED
        local.any { l -> (pinned == null || l.pub == pinned) && st.keys.any { it.active && it.pub == l.pub } } -> E2EStatus.UNLOCKED
        else -> E2EStatus.LOCKED
    }

    /**
     * §4.5：私钥对应的公钥必须是账号某把 active 的钥匙；本机钉住过公钥时还必须和它相同。否则丢弃（T43）
     */
    fun verify(sk: String, keys: List<E2EKeyInfo>, pinned: String?): LocalKey {
        val (pub, kid) = try { c.publicKey(sk) } catch (_: Exception) { throw E2EError(E2EText.T43, E2EError.Kind.MISMATCH) }
        if (keys.none { it.active && it.pub == pub }) throw E2EError(E2EText.T43, E2EError.Kind.MISMATCH)
        if (pinned != null && pub != pinned) throw E2EError(E2EText.T43, E2EError.Kind.MISMATCH)
        return LocalKey(kid, pub, sk)
    }

    /**
     * §4.3 第 1 步：新设备认定的账号公钥 acc。钉住过就用钉住的（服务器的 active 钥匙不是它 → T43）；
     * 没有时用 keys 里唯一一把 active 钥匙（不是正好一把 → T43）
     */
    fun accountPub(st: E2EState, pinned: String?): String {
        val active = st.keys.filter { it.active }
        if (pinned != null) {
            if (active.none { it.pub == pinned }) throw E2EError(E2EText.T43, E2EError.Kind.MISMATCH)
            return pinned
        }
        if (active.size != 1 || active[0].pub.isEmpty()) throw E2EError(E2EText.T43, E2EError.Kind.MISMATCH)
        return active[0].pub
    }

    /** §7 第 1 项：只用钉住的公钥；没有钉住 → T73；服务器的 active 钥匙和钉住的不同 → T43。账号没开启加密时为 null */
    fun sendKey(pushkey: String, st: E2EState?, pinned: String?): SendKey? {
        if (st == null || !st.enabled) return null
        if (pinned == null) return SendKey(null, E2EText.T73)
        if (st.keys.none { it.active && it.pub == pinned }) return SendKey(null, E2EText.T43)
        return SendKey("$pushkey.e2e.$pinned", null)
    }

    /** 核对当前密码的请求：403 → T3 */
    private inline fun <T> checked(block: () -> T): T = try {
        block()
    } catch (e: ApiException) {
        throw if (e.status == 403) E2EError(E2EText.T3, E2EError.Kind.WRONG_PASSWORD) else e
    }

    // ---------- 开启加密（§4.1） ----------

    /**
     * newPassword 为 null：不换密码，继续用当前密码。
     * pending：上一次网络出错、结果不明时留在内存里的钥匙和恢复码：先 GET /v1/e2e 核对（第 4 步），已经开启成功就直接用它
     */
    fun setup(net: E2ENet, server: String, username: String, current: String, newPassword: String?, pending: SetupResult? = null): SetupResult {
        if (pending != null && confirmSetup(net, server, username, pending)) return pending
        if (newPassword == null) {
            if (c.passwordProblem(current, username) != null) throw E2EError(E2EText.WEAK_CURRENT, E2EError.Kind.WEAK_CURRENT)
        } else {
            c.passwordProblem(newPassword, username)?.let { throw E2EError(it, E2EError.Kind.WEAK_PASSWORD) }
        }
        val actual = newPassword ?: current
        val cred = credential(net, server, username, current, Use.E2E)
        val kp = c.keypair()
        val salt = c.newSalt()
        val (auth, unlock) = c.passwordKeys(actual, salt)
        val (code, rkey) = c.recoveryNew()
        val result = SetupResult(LocalKey(kp.kid, kp.pub, kp.sk), code)
        val body = cred.into(JSONObject().put("pub", kp.pub).put("auth_salt", salt).put("auth_key", auth)
            .put("password_wrap", c.wrap("hjp1", unlock, kp.sk))
            .put("recovery_wrap", c.wrap("hjr1", rkey, kp.sk)))
        try {
            checked { net.e2eSetup(body) }
        } catch (e: ApiException) {
            if (e.status == 409) throw E2EError(e.message ?: "别的设备刚开启了加密", E2EError.Kind.CONFLICT)
            if (e.status < 500) throw e
            if (!confirmSetup(net, server, username, result)) throw E2EError(E2EText.SETUP_RETRY)
            return result
        } catch (e: UnauthorizedException) {
            throw e
        } catch (e: java.io.IOException) {
            // 网络出错：可能其实已经开启成功（响应丢了）。先核对，不要马上丢掉钥匙和恢复码
            if (!confirmSetup(net, server, username, result)) throw E2EError(E2EText.SETUP_RETRY)
            return result
        }
        flags.markUpgraded(server, username)
        return result
    }

    /**
     * 开启加密的结果不明时核对：开启了、active 公钥就是这把 → true（成功）；没开启 → false（可以重试）；
     * 开启了但公钥不是这把 → 丢弃（CONFLICT）。取不到状态 → SETUP_UNSURE，钥匙和恢复码留在内存里
     */
    private fun confirmSetup(net: E2ENet, server: String, username: String, p: SetupResult): Boolean {
        val st = try {
            E2EState.parse(net.e2eState())
        } catch (e: UnauthorizedException) {
            throw e
        } catch (e: Exception) {
            throw E2EError(E2EText.SETUP_UNSURE, E2EError.Kind.SETUP_UNSURE, pending = p)
        }
        if (!st.enabled) return false
        if (st.keys.any { it.active && it.pub == p.key.pub }) { flags.markUpgraded(server, username); return true }
        throw E2EError("别的设备刚开启了加密，已重新读取状态", E2EError.Kind.CONFLICT)
    }

    // ---------- 解锁（§4.2、§4.4） ----------

    /** §4.2：用密码解锁（配对码登录的设备） */
    fun unlockWithPassword(net: E2ENet, server: String, username: String, password: String, pinned: String?): LocalKey {
        val cred = credential(net, server, username, password, Use.UNLOCK)
        // 账号回到了旧登录方式（管理员重设过密码）：密码副本已失效
        val unlock = cred.unlock ?: throw E2EError(E2EText.WRAP_GONE, E2EError.Kind.WRAP_INVALID)
        val wrap = try {
            checked { net.e2eUnlock(cred.value) }.optString("password_wrap")
        } catch (e: ApiException) {
            if (e.status == 409) throw E2EError(e.message ?: E2EText.WRAP_GONE, E2EError.Kind.WRAP_INVALID)
            throw e
        }
        val sk = try { c.unwrap("hjp1", unlock, wrap) } catch (_: Exception) { throw E2EError(E2EText.WRAP_GONE, E2EError.Kind.WRAP_INVALID) }
        return verify(sk, E2EState.parse(net.e2eState()).keys, pinned)
    }

    /** §4.4：用恢复码解锁，返回私钥和解锁时的状态（看是否需要重新设置密码） */
    fun unlockWithRecovery(net: E2ENet, code: String, pinned: String?): Pair<LocalKey, E2EState> {
        val key = try { c.recoveryKey(code) } catch (e: Core.Failure) { throw E2EError(e.message ?: E2EText.T41) }
        val st = E2EState.parse(net.e2eState())
        if (st.recoveryWrap.isEmpty()) throw E2EError(E2EText.T41)
        val sk = try { c.unwrap("hjr1", key, st.recoveryWrap) } catch (_: Exception) { throw E2EError(E2EText.T41) }
        return verify(sk, st.keys, pinned) to st
    }

    // ---------- 密码、恢复码、用户名（§2.4、§4.4 T42、§7） ----------

    /**
     * 改密码 / 重新设置密码：PUT /v1/account/auth。已开启加密时用新密码的解锁钥匙重新锁住本机私钥 sk
     * （锁定状态下 sk 为 null，不能改）。afterAdminReset：「重新设置密码」页（T42），当前密码是管理员用原文设的，
     * 即使本机标记了「已升级」也允许用 pbkdf2 算当前密码凭证（§4.4 第 4 步）；其他地方都不允许
     */
    fun setPassword(net: E2ENet, server: String, username: String, current: String, newPassword: String, enabled: Boolean, sk: String?,
                    afterAdminReset: Boolean = false) {
        c.passwordProblem(newPassword, username)?.let { throw E2EError(it, E2EError.Kind.WEAK_PASSWORD) }
        if (enabled && sk == null) throw E2EError(E2EText.LOCKED_CHANGE)
        val cred = credential(net, server, username, current, if (afterAdminReset) Use.RESET else Use.E2E)
        putPassword(net, server, username, cred, newPassword, enabled, sk)
    }

    private fun putPassword(net: E2ENet, server: String, username: String, cred: Cred, newPassword: String, enabled: Boolean, sk: String?) {
        val salt = c.newSalt()
        val (auth, unlock) = c.passwordKeys(newPassword, salt)
        val body = cred.into(JSONObject().put("auth_salt", salt).put("auth_key", auth))
        if (enabled && sk != null) body.put("password_wrap", c.wrap("hjp1", unlock, sk))
        checked { net.accountAuth(body) }
        flags.markUpgraded(server, username)
    }

    /**
     * 账户页改用户名 / 改密码（账号已有密码，§2.4、§7 第 5 项）：一律先算「当前密码」凭证，不管本机是不是管理员设备。
     * 只有 prelogin 是纯文本 404 且没有「已升级」标记时，按旧接口发原文。newPassword 为 null：只改用户名
     */
    fun changeCredentials(net: E2ENet, server: String, oldUsername: String, newUsername: String, current: String,
                          newPassword: String?, enabled: Boolean?, sk: String?) {
        // 所有检查都在发出修改请求之前做完，不会出现用户名改了、密码没改的半截结果
        if (newPassword != null) {
            c.passwordProblem(newPassword, newUsername)?.let { throw E2EError(it, E2EError.Kind.WEAK_PASSWORD) }
            if (enabled == true && sk == null) throw E2EError(E2EText.LOCKED_CHANGE)
        }
        val k = kdf(net, server, oldUsername, Use.ACCOUNT, known())
        if (k == Kdf.Legacy) {
            checked { net.credentials(JSONObject().put("username", newUsername).put("password", newPassword.orEmpty()).put("current_password", current)) }
            return
        }
        // 加密状态还没读到：先读一次（开启了加密就要用新密码重新锁住私钥，锁定时不能改）
        val en = enabled ?: try { E2EState.parse(net.e2eState()).enabled } catch (e: ApiException) { if (e.oldServer) false else throw e }
        if (newPassword != null && en && sk == null) throw E2EError(E2EText.LOCKED_CHANGE)
        val cred = credOf(k, current)
        if (newUsername != oldUsername) {
            checked { net.credentials(cred.into(JSONObject().put("username", newUsername))) }
            if (flags.isUpgraded(server, oldUsername)) flags.markUpgraded(server, newUsername)
        }
        if (newPassword != null) putPassword(net, server, newUsername, cred, newPassword, en, sk)
    }

    /**
     * 设置初始密码（账号还没有密码，§2.1 第 4 条）：没有新接口，只能发原文。本机标记了「已升级」（或服务器说 auth_key 为真）时
     * 拒绝（T1）；成功后立即按 §2.1 第 7 步升级（失败不影响，下次用密码登录时再升级）。返回是否已升级
     */
    fun setInitialPassword(net: E2ENet, server: String, username: String, password: String): Boolean {
        val k = known()
        if (flags.isUpgraded(server, username) || k.authKey ||
            k.localUsername?.takeIf { it.isNotBlank() }?.let { flags.isUpgraded(server, it) } == true) throw E2EError(E2EText.T1)
        checked { net.credentials(JSONObject().put("username", username).put("password", password)) }
        return try {
            when (val kd = kdf(net, server, username)) {
                is Kdf.Pbkdf2 -> autoUpgrade(net, server, username, password, pbkdf2(password, kd))
                is Kdf.Argon -> { flags.markUpgraded(server, username); true }
                Kdf.Legacy -> false
            }
        } catch (_: Exception) { false }
    }

    /** §7 第 3 项：更换恢复码，返回新恢复码（只显示一次，不保存） */
    fun rotateRecovery(net: E2ENet, server: String, username: String, current: String, sk: String): String {
        val cred = credential(net, server, username, current, Use.E2E)
        val (code, rkey) = c.recoveryNew()
        checked { net.e2eRecovery(cred.into(JSONObject().put("recovery_wrap", c.wrap("hjr1", rkey, sk)))) }
        return code
    }

    companion object {
        const val ARGON_TIME = 3
        const val ARGON_MEMORY_KIB = 65536
        const val ARGON_LANES = 1
        private const val HEX = "0123456789abcdefABCDEF"
    }
}

/**
 * 新设备一侧：请另一台设备批准（§4.3，先承诺、后揭晓，承诺和核对码里带着账号公钥 acc）。
 * acc、nb 只在内存里，App 重启后从第 1 步重来。所有方法在同一把锁里执行；每次重新开始序号加一，
 * 开始之前发出、之后才回来的状态一律丢弃，不会误判为「被拒绝」。
 */
class DeviceRequest(private val c: E2ECrypto, private val logic: E2ELogic, val dev: Core.KeyPair, private val pinned: String?) {
    sealed interface Step {
        data object Waiting : Step
        /** 已揭晓，显示核对码（T31） */
        data class Code(val code: String) : Step
        data class Unlocked(val key: LocalKey, val state: E2EState) : Step
        /** 对方拒绝了（T32） */
        data object Denied : Step
        /** 转交来的钥匙解不开、对不上（T43）等：这次请求结束，显示原因和「重新请求」 */
        data class Failed(val message: String) : Step
    }

    private var acc: String? = null
    private var nb: String? = null
    /** 已经对哪个 challenge 揭晓过 nb */
    private var revealedFor: String? = null
    private var code: String? = null
    /** 请求序号：每次重新开始加一 */
    private var gen = 0
    @Volatile var active = false
        private set

    /** 第 1–3 步：定下账号公钥 acc（T43 时停止），新的 nb，登记公钥并请求批准（每次都让之前的核对过程作废） */
    @Synchronized
    fun start(net: E2ENet) {
        active = false
        val a = logic.accountPub(E2EState.parse(net.e2eState()), pinned)
        val n = c.random32()
        net.e2eDevice(dev.pub, request = true, commit = c.sasCommit(dev.pub, a, n))
        acc = a; nb = n; revealedFor = null; code = null; gen++; active = true
    }

    /** 第 4 步：读一次状态并推进；返回这一步的结果和读到的状态 */
    @Synchronized
    fun step(net: E2ENet): Pair<Step, E2EState> {
        val g = gen
        val st = E2EState.parse(net.e2eState())
        if (g != gen) return Step.Waiting to st       // 发出之后又重新开始过：这份状态过期了
        return advance(net, st) to st
    }

    private fun advance(net: E2ENet, st: E2EState): Step {
        if (!active) return Step.Waiting
        val d = st.device
        val a = acc ?: run { start(net); return Step.Waiting }
        val n = nb ?: run { start(net); return Step.Waiting }
        // 公钥被换掉了（例如另一个进程重新登记）：重新开始
        if (d.pub != dev.pub) { start(net); return Step.Waiting }
        // 只在本次请求已经揭晓、核对码已经显示之后才接受转交：之前的 grant 谁都能伪造，一律忽略
        val shown = code
        if (revealedFor != null && shown != null && d.grant.isNotEmpty()) {
            active = false      // 无论解不解得开，这次请求都结束了
            val sk = try { c.grantOpen(dev.sk, d.grant) } catch (_: Exception) { return Step.Failed(E2EText.GRANT_BAD) }
            val pub = try { c.publicKey(sk).first } catch (_: Exception) { "" }
            if (pub != a) return Step.Failed(E2EText.T43)
            return try { Step.Unlocked(logic.verify(sk, st.keys, pinned), st) } catch (e: E2EError) { Step.Failed(e.message ?: E2EText.T43) }
        }
        if (d.challenge.isNotEmpty()) {
            val seen = revealedFor
            if (seen == null) {
                // 先算出核对码再揭晓：算失败就从第 1 步重来，不会停在「已揭晓却没有核对码」
                val sas = try { c.sasCode(dev.pub, a, d.challenge, n) } catch (_: Exception) { start(net); return Step.Waiting }
                try {
                    net.e2eReveal(n)
                } catch (e: ApiException) {
                    if (e.status == 409) { start(net); return Step.Waiting }
                    throw e
                }
                revealedFor = d.challenge
                code = sas
                return Step.Code(sas)
            }
            // 揭晓之后 challenge 变了：对方重新开始，整个请求重来（新的 nb）
            if (seen != d.challenge) { start(net); return Step.Waiting }
            return Step.Code(shown ?: run { start(net); return Step.Waiting })
        }
        if (!d.requested) { active = false; return Step.Denied }
        // 已揭晓过，challenge 却被清掉了：核对过程作废，重来
        if (revealedFor != null) { start(net); return Step.Waiting }
        return Step.Waiting
    }

    /** 第 5 步：取消 */
    @Synchronized
    fun cancel(net: E2ENet) {
        active = false
        gen++
        net.e2eDevice(dev.pub, request = false, commit = null)
    }
}

/**
 * 已解锁设备一侧：批准另一台设备（§5）。na 只用自己生成的随机数；account 是用本机私钥算出的账号公钥，
 * 不用服务器给的 keys（服务器给新设备看了假的账号公钥时，承诺对不上，自动拒绝）。
 */
class Approval(private val c: E2ECrypto, val deviceId: String, val name: String, private val account: String) {
    sealed interface Stage {
        /** 等对方揭晓 */
        data object Waiting : Stage
        /** 显示核对码（T53） */
        data class Code(val code: String) : Stage
        data object Granted : Stage
        data object Rejected : Stage
        data class Failed(val message: String) : Stage
    }

    private var na: String? = null
    /** 核对码对应的公钥（算核对码时的那把；批准时转交给它） */
    private var pub: String? = null
    @Volatile var stage: Stage = Stage.Waiting
        private set

    /** 接手请求；409 说明已被别的设备接手（T51） */
    @Synchronized
    fun begin(net: E2ENet) {
        val n = c.random32()
        try {
            net.e2eChallenge(deviceId, n)
        } catch (e: ApiException) {
            if (e.status == 409) { stage = Stage.Failed(E2EText.T51); throw E2EError(E2EText.T51) }
            throw e
        }
        na = n
        stage = Stage.Waiting
    }

    /** 读一次状态：对方揭晓后核对承诺，一致才显示核对码；不一致立即拒绝（T52） */
    @Synchronized
    fun step(net: E2ENet): Pair<Stage, E2EState> {
        val st = E2EState.parse(net.e2eState())
        return advance(net, st) to st
    }

    private fun advance(net: E2ENet, st: E2EState): Stage {
        val cur = stage
        if (cur !is Stage.Waiting) return cur
        val n = na ?: return cur
        val r = st.requests.firstOrNull { it.deviceId == deviceId }
        val next = when {
            r == null -> Stage.Failed("对方取消了请求")
            r.challenge.isEmpty() -> Stage.Failed("对方重新发起了请求，请重新点「批准」")
            r.challenge != n -> Stage.Failed(E2EText.T51)
            r.reveal.isEmpty() -> Stage.Waiting
            runCatching { c.sasCommit(r.pub, account, r.reveal) }.getOrNull() != r.commit -> {
                runCatching { net.e2eDeny(deviceId) }
                Stage.Failed(E2EText.T52)
            }
            else -> runCatching { c.sasCode(r.pub, account, n, r.reveal) }.fold(
                { pub = r.pub; Stage.Code(it) },
                { Stage.Failed("核对码算不出来，请让对方重新发起请求") },
            )
        }
        stage = next
        return next
    }

    /** 「一致，批准」：把账号私钥转交给核对过的公钥；409 显示服务端说明（对方取消了或换了公钥） */
    @Synchronized
    fun approve(net: E2ENet, sk: String) {
        val p = pub ?: throw E2EError("还没有核对码，不能批准")
        try {
            net.e2eGrant(deviceId, p, c.grantSeal(sk, p))
        } catch (e: ApiException) {
            if (e.status == 409) { stage = Stage.Failed(e.message ?: E2EText.T51); throw E2EError(e.message ?: E2EText.T51) }
            throw e
        }
        stage = Stage.Granted
    }

    /** 「不一致，拒绝」/「拒绝」 */
    @Synchronized
    fun reject(net: E2ENet) {
        net.e2eDeny(deviceId)
        stage = Stage.Rejected
    }
}

/** 收消息（§6.1）：解开信封，换成载荷里的标题、正文、类型和附件，本地生成 doc */
object E2EMessages {
    const val OK = "ok"
    const val LOCKED = "locked"
    const val WRONG_KEY = "wrong_key"
    const val FORMAT = "format"

    /** 还没解开（或解不开）的加密消息：标题换成说明，正文清空，保留信封原文和服务端附件（解锁后重新解密要用） */
    fun sealed(m: Message, status: String): Message = m.copy(
        text = when (status) { WRONG_KEY -> E2EText.T61; FORMAT -> E2EText.T62; else -> E2EText.T60 },
        desp = "", doc = null, preview = "", e2eStatus = status,
    )

    /** keys：本账号全部私钥；没有时（已锁定）返回 sealed。不是加密消息、或已经解开的原样返回 */
    fun open(m: Message, keys: List<String>, c: E2ECrypto): Message {
        val env = m.e2e ?: return m
        if (m.e2eStatus == OK) return m
        if (keys.isEmpty()) return sealed(m, LOCKED)
        val p = try {
            c.openMessage(keys, env)
        } catch (e: Core.Failure) {
            return sealed(m, if (e.code == "wrong_key") WRONG_KEY else FORMAT)
        } catch (_: Exception) {
            return sealed(m, FORMAT)
        }
        val text = p.optString("text")
        val desp = p.optString("desp")
        val type = p.optString("type").ifBlank { "markdown" }
        // 载荷 atts[i] 对应服务端 attachments[i]：显示用载荷的名字、类型、大小，下载用服务端的 id（校验的是密文的 sha256）
        val pa = p.optJSONArray("atts") ?: JSONArray()
        // 两边数量不一致：整条按 format（T62）处理，不截断，也不把多出的服务端附件当明文下载
        if (pa.length() != m.attachments.size) return sealed(m, FORMAT)
        val atts = m.attachments.mapIndexed { i, a ->
            val o = pa.optJSONObject(i) ?: JSONObject()
            a.copy(
                name = o.optString("name").ifBlank { a.name },
                mime = o.optString("mime").ifBlank { "application/octet-stream" },
                size = if (o.has("size")) o.optLong("size") else a.size,
                key = o.optString("key"),
            )
        }
        // 和服务端一样：text / image 类型、或正文为空时没有 doc
        val (doc, preview) = if (type == "text" || type == "image" || desp.isBlank()) null to "" else try {
            c.mdBuild(text, desp, atts.map { mapOf("id" to it.id, "name" to it.name, "mime" to it.mime, "size" to it.size) })
        } catch (_: Exception) { null to "" }
        return m.copy(text = text, desp = desp, type = type, attachments = atts, doc = doc, preview = preview, e2eStatus = OK)
    }
}
