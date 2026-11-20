import CryptoKit
import Foundation

/// 端到端加密自检（docs/e2ee-client.md §10）。只依赖 Foundation、CryptoKit（核对附件校验值）、Core、E2E：
/// Mac 自检（SelfTest.swift）和不碰钥匙串的独立测试程序共用；iPhone 可以原样复制。
@MainActor
enum E2ESelfTest {
    typealias Check = (_ name: String, _ ok: Bool, _ detail: String) -> Void

    // MARK: 假传输（离线用例）

    final class MockTransport: E2ETransport {
        var calls: [(method: String, path: String, body: [String: Any])] = []
        var handler: (String, String, [String: Any]) -> (Int, Any)

        init(_ handler: @escaping (String, String, [String: Any]) -> (Int, Any)) { self.handler = handler }

        func e2eSend(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> E2E.Response {
            let b = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            calls.append((method, path, b))
            let (status, obj) = handler(method, path, b)
            // 字符串原样返回（模拟旧服务端路由层的纯文本 404）
            if let text = obj as? String { return E2E.Response(status: status, data: Data(text.utf8), contentType: "text/plain; charset=utf-8") }
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
            return E2E.Response(status: status, data: data, contentType: "application/json")
        }
    }

    /// 写入很慢的安全存储：记录写入开始、结束（测 AliveFlag 持锁写入）
    final class SlowSecrets: E2ESecrets {
        let inner = E2E.MemorySecrets()
        let started = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _endedAt: Date?
        var endedAt: Date? { lock.lock(); defer { lock.unlock() }; return _endedAt }
        func read(_ name: String) throws -> Data? { try inner.read(name) }
        func write(_ name: String, _ value: Data) throws {
            started.signal()
            Thread.sleep(forTimeInterval: 0.2)
            try inner.write(name, value)
            lock.lock(); _endedAt = Date(); lock.unlock()
        }
        func remove(_ name: String) throws { try inner.remove(name) }
    }

    /// 写入进行中调用 kill()：kill() 要等写入结束才返回；kill() 之后 removeAll() 删得干干净净，再写报错
    static func aliveKillWaitsForWrite() -> Bool {
        let flag = E2E.AliveFlag()
        let secrets = SlowSecrets()
        let suite = "io.github.hongyile.huijian.e2e-selftest-alive2"
        UserDefaults().removePersistentDomain(forName: suite)
        let ring = E2E.KeyRing(secrets: secrets, scope: "alive#2", defaults: UserDefaults(suiteName: suite)!, alive: flag)
        final class Box: @unchecked Sendable { let ring: E2E.KeyRing; init(_ r: E2E.KeyRing) { ring = r } }
        let box = Box(ring)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? box.ring.saveDeviceKeypair(sk: "s", pub: "p")
            done.signal()
        }
        secrets.started.wait()
        flag.kill()
        let killedAt = Date()
        try? ring.removeAll()
        done.wait()
        var threw = false
        do { try ring.saveDeviceKeypair(sk: "s2", pub: "p2") } catch { threw = true }
        ring.replacePin("p2")
        guard let ended = secrets.endedAt else { return false }
        return killedAt >= ended && (try? ring.deviceKeypair()) == nil && threw && ring.pinned == nil
    }

    static func freshMarks(_ suite: String) -> E2E.UpgradeMarks {
        UserDefaults().removePersistentDomain(forName: suite)
        return E2E.UpgradeMarks(defaults: UserDefaults(suiteName: suite)!)
    }

    static func sealPayload(pub: String, text: String, desp: String, type: String = "markdown", atts: [[String: Any]] = []) throws -> String {
        let p: [String: Any] = ["v": 1, "text": text, "desp": desp, "type": type, "atts": atts]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: p), as: UTF8.self)
        guard let env = try Core.call("seal_message", ["pub": pub, "payload": json])["envelope"] as? String else {
            throw E2E.Failure(.core, "seal_message 没有返回信封")
        }
        return env
    }

    // MARK: 离线

    static func offline(_ check: Check) async {
        let marks = freshMarks("io.github.hongyile.huijian.e2e-selftest-offline")
        let server = "http://127.0.0.1:1"

        // 登录参数核对、防降级
        func prelogin(_ p: [String: Any]) -> MockTransport {
            MockTransport { _, path, _ in path == "/v1/prelogin" ? (200, p) : (500, ["error": "不该走到这里"]) }
        }
        let good: [String: Any] = ["kdf": "argon2id", "salt": String(repeating: "ab", count: 16), "time": 3, "memory_kib": 65536, "lanes": 1]
        let bad: [(String, [String: Any])] = [
            ("time=2", good.merging(["time": 2]) { $1 }),
            ("memory_kib=32768", good.merging(["memory_kib": 32768]) { $1 }),
            ("lanes=4", good.merging(["lanes": 4]) { $1 }),
            ("盐只有 8 字节", good.merging(["salt": String(repeating: "ab", count: 8)]) { $1 }),
            ("pbkdf2 只有 1000 轮", ["kdf": "pbkdf2-sha256", "salt": String(repeating: "cd", count: 16), "iterations": 1000]),
            ("不认识的 kdf", ["kdf": "scrypt", "salt": String(repeating: "cd", count: 16)]),
        ]
        for (name, p) in bad {
            do {
                _ = try await E2E.login(server: prelogin(p), authed: { _ in prelogin(p) }, serverID: server, username: "u", password: "x",
                                        device: .init(name: "t", platform: "macos", fingerprint: ""), register: false,
                                        marks: marks, secrets: E2E.MemorySecrets())
                check("参数被篡改（\(name)）时拒绝登录", false, "居然登录了")
            } catch let f as E2E.Failure {
                check("参数被篡改（\(name)）时拒绝登录（T2）", f.kind == .weakParams && f.message == E2E.T.t2, f.message)
            } catch {
                check("参数被篡改（\(name)）时拒绝登录", false, "\(error)")
            }
        }
        marks.mark(server: server, username: "Alex  Chen")
        check("「已升级」标记：用户名不区分大小写、空白合并", marks.isUpgraded(server: server + "/", username: "alex chen"), "")
        let pb = prelogin(["kdf": "pbkdf2-sha256", "salt": String(repeating: "cd", count: 16), "iterations": 600000])
        do {
            _ = try await E2E.login(server: pb, authed: { _ in pb }, serverID: server, username: "ALEX CHEN", password: "x",
                                    device: .init(name: "t", platform: "macos", fingerprint: ""), register: false,
                                    marks: marks, secrets: E2E.MemorySecrets())
            check("已升级的账号收到 pbkdf2 时拒绝", false, "居然登录了")
        } catch let f as E2E.Failure {
            check("已升级的账号收到 pbkdf2 时拒绝（T1），没有发出登录请求", f.kind == .downgrade && !pb.calls.contains { $0.path == "/v1/login" }, f.message)
        } catch { check("已升级的账号收到 pbkdf2 时拒绝", false, "\(error)") }
        let old = MockTransport { _, path, _ -> (Int, Any) in path == "/v1/prelogin" ? (404, "not found") : (500, ["error": "x"]) }
        do {
            _ = try await E2E.login(server: old, authed: { _ in old }, serverID: server, username: "alex chen", password: "x",
                                    device: .init(name: "t", platform: "macos", fingerprint: ""), register: false,
                                    marks: marks, secrets: E2E.MemorySecrets())
            check("已升级的账号遇到没有新登录协议的服务端时拒绝", false, "居然登录了")
        } catch let f as E2E.Failure {
            check("已升级的账号遇到没有新登录协议的服务端时拒绝（T1），不发密码原文",
                  f.kind == .downgrade && !old.calls.contains { $0.path == "/v1/login" }, f.message)
        } catch { check("旧服务端防降级", false, "\(error)") }
        // 从未升级的账号在旧服务端照旧用原文登录
        let legacy = MockTransport { _, path, _ -> (Int, Any) in
            path == "/v1/prelogin" ? (404, "404 page not found") : (200, ["device_id": "d_1", "name": "t", "token": "DT_x", "reused": false] as [String: Any])
        }
        if let r = try? await E2E.login(server: legacy, authed: { _ in legacy }, serverID: server, username: "never", password: "pw-1",
                                         device: .init(name: "t", platform: "macos", fingerprint: ""), register: false,
                                         marks: marks, secrets: E2E.MemorySecrets()) {
            let sent: [String: Any] = legacy.calls.first(where: { $0.path == "/v1/login" })?.body ?? [:]
            let plainSent = (sent["password"] as? String) == "pw-1" && sent["auth_key"] == nil
            check("旧服务端、从未升级的账号：照旧用密码原文登录", r.token == "DT_x" && plainSent, "")
        } else { check("旧服务端、从未升级的账号：照旧登录", false, "") }

        // 状态、§4.5、发送密钥
        guard let kp = try? Core.keypair(), let other = try? Core.keypair() else { check("生成钥匙对", false, ""); return }
        var st = E2E.State()
        check("未开启：状态 off", E2E.status(st, localKeys: [kp.sk]) == .off, "")
        st.enabled = true
        st.keys = [E2E.Key(kid: kp.kid, pub: kp.pub, active: true)]
        st.auth_key = true
        st.has_password_wrap = true
        check("已开启、本机没有私钥：已锁定", E2E.status(st, localKeys: []) == .locked, "")
        check("已开启、本机私钥对不上：已锁定", E2E.status(st, localKeys: [other.sk]) == .locked, "")
        check("已开启、本机有对应有效钥匙的私钥：已解锁", E2E.status(st, localKeys: [other.sk, kp.sk]) == .unlocked
              && E2E.usableKey(st, localKeys: [other.sk, kp.sk]) == kp.sk, "")
        do { try E2E.verify(sk: other.sk, keys: st.keys, pinned: nil); check("§4.5 别人的钥匙被丢弃", false, "") }
        catch let f as E2E.Failure { check("§4.5 对不上的私钥被丢弃（T43）", f.kind == .keyMismatch && f.message == E2E.T.t43, "") }
        catch { check("§4.5", false, "\(error)") }
        var inactive = st
        inactive.keys = [E2E.Key(kid: kp.kid, pub: kp.pub, active: false)]
        check("§4.5 已停用的钥匙也不接受", (try? E2E.verify(sk: kp.sk, keys: inactive.keys, pinned: nil)) == nil, "")

        // 服务器地址规范化（防止换一种写法绕过「已升级」标记和钉住的公钥）
        check("服务器地址规范化：scheme / host 小写，去掉默认端口和末尾 /",
              E2E.normalizeServer("HTTPS://Push.Example.com:443/") == "https://push.example.com"
              && E2E.normalizeServer("http://10.0.0.2:80") == "http://10.0.0.2" && E2E.normalizeServer("http://x.local:8790/") == "http://x.local:8790"
              && E2E.UpgradeMarks.id(server: "https://push.example.com:443", username: "A") == E2E.UpgradeMarks.id(server: "https://PUSH.example.com/", username: "a")
              && E2E.scope(server: "https://push.example.com:443", accountID: 3) == E2E.scope(server: "https://push.example.com", accountID: 3), "")

        // 钉住的账号公钥（§1、§4.5）与加密发送密钥（§7 第 1 项）
        let pinSuite = "io.github.hongyile.huijian.e2e-selftest-pins"
        UserDefaults().removePersistentDomain(forName: pinSuite)
        let pinRing = E2E.KeyRing(secrets: E2E.MemorySecrets(), scope: E2E.scope(server: server, accountID: 1), defaults: UserDefaults(suiteName: pinSuite)!)
        check("从没解锁过（没有钉住的公钥）：不显示发送密钥，显示 T73", E2E.sendKey(pushkey: "PK_abc", state: st, pinned: pinRing.pinned) == .needsUnlock, "")
        do {
            try E2E.acceptKey(kp.sk, keys: st.keys, ring: pinRing)
            let saved = try pinRing.accountKeys()
            check("§4.5 核对通过后保存并钉住公钥", pinRing.pinned == kp.pub && saved == [kp.sk], "")
        } catch { check("保存并钉住公钥", false, "\(error)") }
        check("加密发送密钥 = <pushkey>.e2e.<钉住的公钥 43 字符>",
              E2E.sendKey(pushkey: "PK_abc", state: st, pinned: pinRing.pinned) == .key("PK_abc.e2e.\(kp.pub)") && kp.pub.count == 43, "")
        var swapped = st
        swapped.keys = [E2E.Key(kid: other.kid, pub: other.pub, active: true)]
        check("服务器的有效钥匙和钉住的不同：不显示发送密钥（T43）", E2E.sendKey(pushkey: "PK_abc", state: swapped, pinned: pinRing.pinned) == .mismatch, "")
        do {
            try E2E.acceptKey(other.sk, keys: swapped.keys, ring: pinRing)
            check("服务器换了钥匙：和钉住的公钥不同的私钥被丢弃", false, "")
        } catch {
            check("服务器换了钥匙：和钉住的公钥不同的私钥被丢弃（T43），钉住的不变",
                  error.localizedDescription == E2E.T.t43 && pinRing.pinned == kp.pub && ((try? pinRing.accountKeys()) ?? []) == [kp.sk], "")
        }
        check("未开启时没有加密发送密钥这一行", E2E.sendKey(pushkey: "PK_abc", state: E2E.State(), pinned: pinRing.pinned) == .hidden, "")
        // §8 退出登录 / 设备被移除：删除私钥和设备钥匙对，钉住的账号公钥和「已升级」标记保留
        do {
            marks.mark(server: server, username: "pin-user")
            try pinRing.saveDeviceKeypair(sk: other.sk, pub: other.pub)
            try pinRing.removeAll()
            check("§8 删除本机钥匙后：私钥、设备钥匙对都没了，钉住的公钥和「已升级」标记还在",
                  ((try? pinRing.accountKeys()) ?? ["x"]).isEmpty && (try? pinRing.deviceKeypair()) == nil
                  && pinRing.pinned == kp.pub && marks.isUpgraded(server: server, username: "pin-user")
                  && E2E.sendKey(pushkey: "PK_abc", state: st, pinned: pinRing.pinned) == .key("PK_abc.e2e.\(kp.pub)"), "")
            do {
                try E2E.acceptKey(other.sk, keys: swapped.keys, ring: pinRing)
                check("§8 之后重新登录：服务器换的钥匙仍被拒", false, "")
            } catch { check("§8 之后重新登录：服务器换的钥匙仍被拒（T43）", error.localizedDescription == E2E.T.t43, "") }
        } catch { check("§8 删除本机钥匙", false, "\(error)") }
        var reset = st
        reset.auth_key = false
        check("账号回到旧登录方式：解锁后要重新设置密码", E2E.needsPasswordReset(reset) && !E2E.needsPasswordReset(st), "")
        check("核对码 3+3 显示", E2E.formatCode("048213") == "048 213" && E2E.T.t53("482913") == "核对码 482 913：和新设备上显示的一致吗？", "")

        // 消息解密：载荷、附件映射、本地 Markdown
        do {
            let desp = "## 结果\n\n- loss **0.12**\n\n![图](attachment:loss.png)"
            let env = try sealPayload(pub: kp.pub, text: "训练完成", desp: desp,
                                      atts: [["name": "loss.png", "mime": "image/png", "size": 1234, "key": try Core.random32()],
                                             ["name": "日志.txt", "mime": "text/plain", "size": 5, "key": try Core.random32()]])
            if case .ok(let o) = E2E.open(envelope: env, keys: [other.sk, kp.sk], serverAttachments: ["a_1", "a_2"]) {
                check("解开载荷：标题、正文、类型", o.text == "训练完成" && o.desp == desp && o.type == "markdown", "")
                check("附件按顺序对应服务端 id，显示载荷里的名字、类型、大小",
                      o.atts.map(\.id) == ["a_1", "a_2"] && o.atts.map(\.name) == ["loss.png", "日志.txt"] && o.atts[0].size == 1234
                      && o.atts[0].mime == "image/png" && !o.atts[0].key.isEmpty, "")
                let ref = try Core.mdBuild(text: "训练完成", desp: desp, atts: [["id": "a_1", "name": "loss.png", "mime": "image/png", "size": 1234],
                                                                             ["id": "a_2", "name": "日志.txt", "mime": "text/plain", "size": 5]])
                check("本地解析 Markdown：doc、preview 和核心库一致，正文图片指向服务端附件 id",
                      o.doc == ref.doc && o.preview == ref.preview && String(decoding: o.doc ?? Data(), as: UTF8.self).contains("a_1"), "")
            } else { check("解开加密消息", false, "") }
            let plain = try sealPayload(pub: kp.pub, text: "纯文本", desp: "**不解析**", type: "text")
            if case .ok(let o) = E2E.open(envelope: plain, keys: [kp.sk], serverAttachments: []) {
                check("type=text 不生成 doc", o.doc == nil && o.type == "text", "")
            } else { check("type=text", false, "") }
            let noTitle = try sealPayload(pub: kp.pub, text: "", desp: "", atts: [["name": "a.pdf", "mime": "application/pdf", "size": 1, "key": try Core.random32()]])
            if case .ok(let o) = E2E.open(envelope: noTitle, keys: [kp.sk], serverAttachments: ["a_9"]) {
                check("没有标题时用附件名（和服务端一致）", o.text == "📎 a.pdf", o.text)
            } else { check("没有标题", false, "") }
            let mismatch = try sealPayload(pub: kp.pub, text: "x", desp: "",
                                           atts: [["name": "a", "mime": "x", "size": 1, "key": try Core.random32()]])
            check("载荷附件和服务端附件数量不一致：按已损坏处理（T62）",
                  E2E.open(envelope: mismatch, keys: [kp.sk], serverAttachments: ["a_1", "a_2"]) == .broken
                  && E2E.open(envelope: mismatch, keys: [kp.sk], serverAttachments: []) == .broken, "")
            check("没有私钥：locked（T60）", E2E.open(envelope: env, keys: [], serverAttachments: []) == .locked && E2E.placeholder("locked") == E2E.T.t60, "")
            check("别的钥匙：wrong_key（T61）", E2E.open(envelope: env, keys: [other.sk], serverAttachments: []) == .wrongKey && E2E.placeholder("wrong_key") == E2E.T.t61, "")
            var broken = env
            broken.removeLast(4)
            broken += "AAAA"
            check("信封被篡改：format（T62）", E2E.open(envelope: broken, keys: [kp.sk], serverAttachments: []) == .broken && E2E.placeholder("format") == E2E.T.t62, "")
        } catch {
            check("消息解密用例", false, "\(error)")
        }

        // 附件解密：密文 → 真实文件，成功后删除密文；钥匙不对时不留文件
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hj-e2e-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let plainData = Data((0..<200_000).map { _ in UInt8.random(in: 0...255) })
            let src = dir.appendingPathComponent("p.bin"), ct = dir.appendingPathComponent("c.bin"), dst = dir.appendingPathComponent("真实名字.bin")
            try plainData.write(to: src)
            let fk = try Core.random32()
            try Core.call("encrypt_file", ["key": fk, "src": src.path, "dst": ct.path])
            try await E2E.decryptAttachment(key: fk, src: ct, dst: dst)
            check("附件解密成功，密文已删除", (try? Data(contentsOf: dst)) == plainData && !FileManager.default.fileExists(atPath: ct.path), "")
            try Core.call("encrypt_file", ["key": fk, "src": src.path, "dst": ct.path])
            let dst2 = dir.appendingPathComponent("x.bin")
            do {
                try await E2E.decryptAttachment(key: try Core.random32(), src: ct, dst: dst2)
                check("附件钥匙不对时报「解密失败」", false, "")
            } catch {
                let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                check("附件钥匙不对时报「解密失败」，不留半成品和密文", error.localizedDescription == "解密失败" && !left.contains("x.bin")
                      && !left.contains { $0.hasSuffix(".hj-part") } && !left.contains("c.bin"), "\(left)")
            }
        } catch {
            check("附件解密用例", false, "\(error)")
        }

        // 批准设备一侧：核对失败自动拒绝、假的账号公钥、核对码一致、T51
        do {
            let dev = try Core.keypair()
            let nb = try Core.random32()
            let req = E2E.Request(device_id: "d_new", name: "新 Mac", platform: "macos", pub: dev.pub, requested_at: 1,
                                  commit: try Core.sasCommit(pub: dev.pub, account: kp.pub, nonce: nb))
            func challenged(_ r: E2E.Request, _ mock: MockTransport, reveal: String) -> E2E.State {
                var x = r
                x.challenge = mock.calls.first { $0.path == "/v1/e2e/challenge" }?.body["nonce"] as? String ?? ""
                x.reveal = reveal
                var s = E2E.State()
                s.enabled = true
                s.requests = [x]
                return s
            }
            let mock = MockTransport { _, _, _ in (200, ["ok": true]) }
            let a = try await E2E.Approval.begin(E2E.API(mock), request: req, sk: kp.sk)
            check("批准：对方还没揭晓时等待", await a.handle(challenged(req, mock, reveal: ""), api: E2E.API(mock)) == .challenged, "")
            let ph = await a.handle(challenged(req, mock, reveal: try Core.random32()), api: E2E.API(mock))   // 和承诺对不上
            check("核对失败：显示 T52，并自动发送拒绝", ph == .failed(E2E.T.t52) && mock.calls.contains { $0.path == "/v1/e2e/deny" && $0.body["device_id"] as? String == "d_new" }, "\(ph)")
            // 服务器给新设备看了假的账号公钥：新设备的承诺里是假公钥，批准设备用自己私钥算出的公钥核对，对不上
            let fake = E2E.Request(device_id: "d_fake", name: "新 Mac", platform: "macos", pub: dev.pub, requested_at: 1,
                                   commit: try Core.sasCommit(pub: dev.pub, account: other.pub, nonce: nb))
            let mockF = MockTransport { _, _, _ in (200, ["ok": true]) }
            let f = try await E2E.Approval.begin(E2E.API(mockF), request: fake, sk: kp.sk)
            let phF = await f.handle(challenged(fake, mockF, reveal: nb), api: E2E.API(mockF))
            check("新设备看到的是假的账号公钥：承诺对不上，自动拒绝（T52）",
                  phF == .failed(E2E.T.t52) && mockF.calls.contains { $0.path == "/v1/e2e/deny" }, "\(phF)")
            // 正常揭晓：两边核对码一致（核对码包含账号公钥）
            let mock2 = MockTransport { _, _, _ in (200, ["ok": true]) }
            let b = try await E2E.Approval.begin(E2E.API(mock2), request: req, sk: kp.sk)
            let st2 = challenged(req, mock2, reveal: nb)
            let ph2 = await b.handle(st2, api: E2E.API(mock2))
            check("揭晓一致：显示核对码，和新设备算出的相同",
                  ph2 == .code(try Core.sasCode(pub: dev.pub, account: kp.pub, na: st2.requests[0].challenge, nb: nb)), "\(ph2)")
            // 接手 409 → T51
            let taken = MockTransport { _, _, _ in (409, ["error": "这台设备的请求已经在另一台设备上处理"]) }
            do { _ = try await E2E.Approval.begin(E2E.API(taken), request: req, sk: kp.sk); check("已被接手的请求", false, "") }
            catch { check("请求已被别的设备接手：T51", error.localizedDescription == E2E.T.t51, error.localizedDescription) }
        } catch {
            check("批准用例", false, "\(error)")
        }

        // 新设备一侧：揭晓之前的转交一律忽略；揭晓之后只接受和账号公钥配对的私钥；旧响应按请求序号丢弃
        do {
            let acc = try Core.keypair(), evil = try Core.keypair()
            var srv = E2E.State()
            srv.enabled = true
            srv.keys = [E2E.Key(kid: acc.kid, pub: acc.pub, active: true)]
            let served = srv
            let mock = MockTransport { _, path, _ -> (Int, Any) in
                if path == "/v1/e2e" {
                    let obj = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(served))) ?? [:]
                    return (200, obj)
                }
                return (200, ["ok": true])
            }
            let api = E2E.API(mock)
            let suite = "io.github.hongyile.huijian.e2e-selftest-grant"
            UserDefaults().removePersistentDomain(forName: suite)
            let ringB = E2E.KeyRing(secrets: E2E.MemorySecrets(), scope: "test#1", defaults: UserDefaults(suiteName: suite)!)
            let req = E2E.ApprovalRequest(ring: ringB)
            try await req.start(api)
            let devPub = mock.calls.last { $0.path == "/v1/e2e/device" }?.body["pub"] as? String ?? ""
            let commit = mock.calls.last { $0.path == "/v1/e2e/device" }?.body["commit"] as? String ?? ""
            check("新设备：承诺里用的是服务器唯一一把有效钥匙作为账号公钥", req.account == acc.pub && !commit.isEmpty, "")
            // 服务器伪造转交（加上自己的公钥），在揭晓之前
            var forged = srv
            forged.keys = [E2E.Key(kid: evil.kid, pub: evil.pub, active: true)]
            forged.device = E2E.DeviceInfo()
            forged.device.pub = devPub
            forged.device.requested = true
            forged.device.grant = try Core.grantSeal(sk: evil.sk, to: devPub)
            let p1 = await req.handle(forged, api: api, generation: req.generation)
            check("揭晓之前收到的转交一律忽略（伪造的 grant 不会被收下）", p1 == .waiting && ((try? ringB.accountKeys()) ?? ["x"]).isEmpty, "\(p1)")
            var stale = srv
            stale.device.pub = devPub
            stale.device.requested = false
            let p0 = await req.handle(stale, api: api, generation: req.generation - 1)
            check("登记之前发出、晚到的响应被丢弃（不会误判成被拒绝）", p0 == .waiting, "\(p0)")
            // 对方接手 → 先算核对码再揭晓
            var ch = srv
            ch.device.pub = devPub
            ch.device.requested = true
            ch.device.challenge = try Core.random32()
            let p2 = await req.handle(ch, api: api, generation: req.generation)
            var revealed = false
            if case .code = p2 { revealed = mock.calls.contains { $0.path == "/v1/e2e/reveal" } }
            check("对方接手后揭晓并显示核对码", revealed, "\(p2)")
            // 揭晓之后的伪造转交：私钥和账号公钥不配对 → T43
            var forged2 = forged
            forged2.device.challenge = ch.device.challenge
            let p3 = await req.handle(forged2, api: api, generation: req.generation)
            check("揭晓之后收到和账号公钥不配对的私钥：丢弃（T43）", p3 == .failed(E2E.T.t43) && ((try? ringB.accountKeys()) ?? ["x"]).isEmpty, "\(p3)")
            // 真的转交：收下、钉住
            let req2 = E2E.ApprovalRequest(ring: ringB)
            try await req2.start(api)
            ch.device.challenge = try Core.random32()
            _ = await req2.handle(ch, api: api, generation: req2.generation)
            var real = ch
            real.device.grant = try Core.grantSeal(sk: acc.sk, to: devPub)
            real.device.requested = false
            let p4 = await req2.handle(real, api: api, generation: req2.generation)
            check("揭晓之后收到账号私钥：核对后保存并钉住公钥", p4 == .granted && ((try? ringB.accountKeys()) ?? []) == [acc.sk] && ringB.pinned == acc.pub, "\(p4)")
        } catch {
            check("新设备批准用例", false, "\(error)")
        }

        // 进行中的开启（§4.1）：新钥匙对和恢复码从生成起存在 KeyRing.pendingSetup；响应丢失后每次刷新状态核对
        do {
            var setupPub = ""
            var stateFails = true
            var setupStatus = 502
            var served = E2E.State()
            let mock = MockTransport { _, path, body -> (Int, Any) in
                switch path {
                case "/v1/prelogin": return (200, good)
                case "/v1/e2e/setup":
                    setupPub = body["pub"] as? String ?? ""
                    return setupStatus == 200 ? (200, ["ok": true]) : (setupStatus, setupStatus == 403 ? ["error": "密码不对"] as Any : "bad gateway")
                case "/v1/e2e":
                    if stateFails { return (500, ["error": "暂时不可用"]) }
                    return (200, (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(served))) ?? [:])
                default: return (500, ["error": "x"])
                }
            }
            func enabledWith(_ pub: String) -> E2E.State {
                var x = E2E.State()
                x.enabled = true
                x.auth_key = true
                x.keys = [E2E.Key(kid: "k", pub: pub, active: true)]
                return x
            }
            let suite = "io.github.hongyile.huijian.e2e-selftest-setup"
            UserDefaults().removePersistentDomain(forName: suite)
            let setupMarks = freshMarks(suite + "-marks")
            let ring = E2E.KeyRing(secrets: E2E.MemorySecrets(), scope: "test#2", defaults: UserDefaults(suiteName: suite)!)
            let api = E2E.API(mock)
            func runSetup() async throws -> String {
                try await E2E.setup(api, ring: ring, server: server, username: "u", currentPassword: "old",
                                    newPassword: "Tq7#mZ2!pL9x-new", marks: setupMarks)
            }
            var pending: E2E.SetupAttempt?
            do {
                _ = try await runSetup()
                check("开启加密响应丢失、状态也取不到", false, "居然成功了")
            } catch let p as E2E.SetupPending {
                pending = p.attempt
                let stored = try ring.pendingSetup()
                check("响应丢失、状态也取不到：新钥匙对和恢复码已存进钥匙串（KeyRing.pendingSetup），账号私钥还没保存",
                      stored == p.attempt && p.attempt.pub == setupPub && ((try? ring.accountKeys()) ?? ["x"]).isEmpty && ring.pinned == nil, "")
            }
            // 刷新状态：服务端还没开启 → 保留
            stateFails = false
            check("核对：服务端还没开启 → 保留，提示重试",
                  try E2E.checkPendingSetup(E2E.State(), ring: ring, server: server, username: "u", marks: setupMarks) == .notEnabled(pending!)
                  && (try? ring.pendingSetup()) == pending, "")
            // 刷新状态：服务端其实已经用这把钥匙开启 → 完成（App 重启后也一样：pendingSetup 在钥匙串里）
            let afterRestart = E2E.KeyRing(secrets: ring.secrets, scope: "test#2", defaults: UserDefaults(suiteName: suite)!)
            let done = try E2E.checkPendingSetup(enabledWith(setupPub), ring: afterRestart, server: server, username: "u", marks: setupMarks)
            check("核对：服务端已用这把钥匙开启 → 保存私钥、钉住公钥、标记升级，返回恢复码；点「完成」之前进行中的开启不删",
                  done == .completed(pending!) && (try? afterRestart.accountKeys()) == [pending!.sk] && afterRestart.pinned == setupPub
                  && setupMarks.isUpgraded(server: server, username: "u") && (try? afterRestart.pendingSetup()) == pending, "")
            served = enabledWith(setupPub)
            let again = try await runSetup()
            check("再点「开启」也先核对：同一个恢复码，没有再提交", again == pending?.code && mock.calls.filter { $0.path == "/v1/e2e/setup" }.count == 1, "")
            check("重启后：已确认的开启（私钥已在钥匙串）直接回到恢复码页", E2E.confirmedSetup(ring: afterRestart) == pending, "")
            E2E.finishRecovery(ring: ring)
            check("点「完成」（finishRecovery）后删除进行中的开启", (try? ring.pendingSetup()) == nil && E2E.confirmedSetup(ring: ring) == nil
                  && ((try? ring.accountKeys()) ?? []) == [pending!.sk], "")

            // 服务端用的是别的钥匙 → 删除
            let ring2 = E2E.KeyRing(secrets: E2E.MemorySecrets(), scope: "test#3", defaults: UserDefaults(suiteName: suite)!)
            let stray = try Core.keypair()
            try ring2.savePendingSetup(E2E.SetupAttempt(sk: stray.sk, pub: stray.pub, code: "X"))
            check("还没确认的开启：不算已确认（不直接显示恢复码页）", E2E.confirmedSetup(ring: ring2) == nil, "")
            // 确认开启后私钥当时没存进钥匙串：点「完成」时补存、补钉再删除
            let ring4 = E2E.KeyRing(secrets: E2E.MemorySecrets(), scope: "test#7", defaults: UserDefaults(suiteName: suite)!)
            try ring4.savePendingSetup(E2E.SetupAttempt(sk: stray.sk, pub: stray.pub, code: "Y"))
            E2E.finishRecovery(ring: ring4)
            check("点「完成」时私钥不在钥匙串：补存、补钉，再删除进行中的开启",
                  ((try? ring4.accountKeys()) ?? []) == [stray.sk] && ring4.pinned == stray.pub && (try? ring4.pendingSetup()) == nil, "")
            check("核对：服务端开启了、但公钥不是这把 → 删除",
                  try E2E.checkPendingSetup(enabledWith(other.pub), ring: ring2, server: server, username: "u", marks: setupMarks) == .discarded
                  && (try? ring2.pendingSetup()) == nil && ((try? ring2.accountKeys()) ?? ["x"]).isEmpty, "")

            // 服务端明确拒绝（4xx）→ 删除；没开启时重试会丢掉旧的、重新生成
            let ring3 = E2E.KeyRing(secrets: E2E.MemorySecrets(), scope: "test#4", defaults: UserDefaults(suiteName: suite)!)
            let api3 = E2E.API(mock)
            served = E2E.State()
            setupStatus = 403
            do {
                _ = try await E2E.setup(api3, ring: ring3, server: server, username: "u3", currentPassword: "old", newPassword: "Tq7#mZ2!pL9x-new", marks: setupMarks)
                check("4xx", false, "")
            } catch { check("服务端明确拒绝（403）：T3，进行中的开启已删除", error.localizedDescription == E2E.T.t3 && (try? ring3.pendingSetup()) == nil, "") }
            try ring3.savePendingSetup(E2E.SetupAttempt(sk: stray.sk, pub: stray.pub, code: "OLD"))
            setupStatus = 200
            let fresh = try await E2E.setup(api3, ring: ring3, server: server, username: "u3", currentPassword: "old", newPassword: "Tq7#mZ2!pL9x-new", marks: setupMarks)
            let p3 = try ring3.pendingSetup()
            check("上次没开启成功：重试时丢掉旧钥匙、重新生成；成功后保存私钥、钉住，进行中的开启留到点「完成」",
                  fresh != "OLD" && p3?.code == fresh && p3?.pub == setupPub && p3?.pub != stray.pub
                  && (try? ring3.accountKeys()) == [p3?.sk ?? ""] && ring3.pinned == setupPub, "")
            try ring3.removeAll()
            check("退出登录（removeAll）也删除进行中的开启", (try? ring3.pendingSetup()) == nil, "")
        } catch {
            check("进行中的开启用例", false, "\(error)")
        }

        // 进行中的更换恢复码（§7 第 3 项）：发请求前存进钥匙串；4xx 删除；结果不确定时保留，刷新后 recovery_wrap 对上才算成功
        do {
            var putStatus = 502
            var stateFails = true
            var uploaded = ""
            var served = E2E.State()
            let mock = MockTransport { _, path, body -> (Int, Any) in
                switch path {
                case "/v1/prelogin": return (200, good)
                case "/v1/e2e/recovery":
                    uploaded = body["recovery_wrap"] as? String ?? ""
                    switch putStatus {
                    case 200: return (200, ["ok": true])
                    case 403: return (403, ["error": "密码不对"])
                    case 504:
                        served.recovery_wrap = uploaded     // 服务端其实换了，只是响应丢了
                        return (504, "gateway timeout")
                    default: return (putStatus, "bad gateway")
                    }
                case "/v1/e2e":
                    if stateFails { return (500, ["error": "暂时不可用"]) }
                    return (200, (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(served))) ?? [:])
                default: return (500, ["error": "x"])
                }
            }
            let suite = "io.github.hongyile.huijian.e2e-selftest-rotate"
            UserDefaults().removePersistentDomain(forName: suite)
            let ring = E2E.KeyRing(secrets: E2E.MemorySecrets(), scope: "test#8", defaults: UserDefaults(suiteName: suite)!)
            let api = E2E.API(mock)
            func rotate() async throws -> String {
                try await E2E.rotateRecovery(api, ring: ring, sk: kp.sk, server: server, username: "r", password: "pw", marks: marks)
            }
            var pending: E2E.RecoveryAttempt?
            do { _ = try await rotate(); check("更换恢复码响应丢失", false, "居然成功了") }
            catch let p as E2E.RecoveryPending {
                pending = p.attempt
                check("更换恢复码响应丢失、状态也取不到：新恢复码已存进钥匙串（未确认），提示稍后核对",
                      (try? ring.pendingRecovery()) == p.attempt && !p.attempt.confirmed && p.attempt.wrap == uploaded
                      && E2E.confirmedRecovery(ring: ring) == nil && p.localizedDescription == E2E.T.recoveryUncertain, "")
            }
            stateFails = false
            served.enabled = true
            served.recovery_wrap = "hjr1.旧的"
            check("刷新：服务端的 recovery_wrap 还是旧的 → 不显示、保留",
                  E2E.checkPendingRecovery(served, ring: ring) == nil && (try? ring.pendingRecovery()) == pending, "")
            served.recovery_wrap = uploaded
            let hit = E2E.checkPendingRecovery(served, ring: ring)
            check("刷新：服务端的 recovery_wrap 就是这次上传的 → 当作成功，显示同一个恢复码，记为已确认",
                  hit?.code == pending?.code && hit?.confirmed == true && E2E.confirmedRecovery(ring: ring)?.code == pending?.code, "")
            E2E.finishRotation(ring: ring)
            check("点「完成」后删除", (try? ring.pendingRecovery()) == nil && E2E.checkPendingRecovery(served, ring: ring) == nil, "")
            // 响应丢失，但重新读状态发现已经换了 → 直接成功
            putStatus = 504
            let c2 = try await rotate()
            check("响应丢失、重新读状态发现已换成这份：直接成功，已确认", (try? ring.pendingRecovery())?.code == c2
                  && (try? ring.pendingRecovery())?.confirmed == true, "")
            // 明确被拒（4xx）→ 删除
            E2E.finishRotation(ring: ring)
            putStatus = 403
            do { _ = try await rotate(); check("4xx", false, "") }
            catch { check("更换恢复码被拒（403 → T3）：删除这次的新恢复码", error.localizedDescription == E2E.T.t3 && (try? ring.pendingRecovery()) == nil, "") }
            // 正常成功 → 已确认，留到点「完成」；removeAll 也删
            putStatus = 200
            let c3 = try await rotate()
            check("更换成功：新恢复码留在钥匙串（已确认）直到点「完成」，重启后可回到恢复码页",
                  E2E.confirmedRecovery(ring: ring)?.code == c3, "")
            try ring.removeAll()
            check("退出登录（removeAll）也删除进行中的更换恢复码", (try? ring.pendingRecovery()) == nil, "")
        } catch {
            check("更换恢复码用例", false, "\(error)")
        }

        // §4.5 末尾：本机有私钥、没钉住公钥（重装后偏好设置清空）→ 核对通过就补钉
        do {
            let suite = "io.github.hongyile.huijian.e2e-selftest-repin"
            UserDefaults().removePersistentDomain(forName: suite)
            let ring = E2E.KeyRing(secrets: E2E.MemorySecrets(), scope: "test#5", defaults: UserDefaults(suiteName: suite)!)
            try ring.addAccountKey(other.sk)
            check("补钉：本机私钥不是服务器的有效钥匙 → 不钉", E2E.repinIfNeeded(st, ring: ring, localKeys: [other.sk]) == nil && ring.pinned == nil, "")
            try ring.addAccountKey(kp.sk)
            check("补钉：本机私钥核对通过 → 用它算出的公钥钉住",
                  E2E.repinIfNeeded(st, ring: ring, localKeys: [other.sk, kp.sk]) == kp.pub && ring.pinned == kp.pub, "")
            check("补钉：已经钉住的不改", E2E.repinIfNeeded(swapped, ring: ring, localKeys: [other.sk]) == nil && ring.pinned == kp.pub, "")
        } catch {
            check("补钉用例", false, "\(error)")
        }

        // §8：退出登录、换账号时先停下批准流程，之后不再登记、不再写钥匙串
        do {
            var srv = E2E.State()
            srv.enabled = true
            srv.keys = [E2E.Key(kid: kp.kid, pub: kp.pub, active: true)]
            let served = srv
            let mock = MockTransport { _, path, _ -> (Int, Any) in
                if path == "/v1/e2e" { return (200, (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(served))) ?? [:]) }
                return (200, ["ok": true])
            }
            let suite = "io.github.hongyile.huijian.e2e-selftest-stop"
            UserDefaults().removePersistentDomain(forName: suite)
            let ring = E2E.KeyRing(secrets: E2E.MemorySecrets(), scope: "test#6", defaults: UserDefaults(suiteName: suite)!)
            let req = E2E.ApprovalRequest(ring: ring)
            req.stop()
            var threw = false
            do { try await req.start(E2E.API(mock)) } catch { threw = true }
            check("请求已停止：不再登记，也不写设备钥匙对",
                  threw && (try? ring.deviceKeypair()) == nil && !mock.calls.contains { $0.path == "/v1/e2e/device" }, "")
            let req2 = E2E.ApprovalRequest(ring: ring)
            try await req2.start(E2E.API(mock))
            let devPub = mock.calls.last { $0.path == "/v1/e2e/device" }?.body["pub"] as? String ?? ""
            req2.stop()
            var other2 = srv
            other2.device.pub = "另一把"        // 平时会触发重新登记
            let before = mock.calls.count
            _ = await req2.handle(other2, api: E2E.API(mock), generation: req2.generation)
            check("请求进行中被停止：之后的状态不再处理（不重新登记）", mock.calls.count == before && !devPub.isEmpty, "")

            let dev = try Core.keypair()
            let nb = try Core.random32()
            let r = E2E.Request(device_id: "d_stop", name: "x", platform: "ios", pub: dev.pub, requested_at: 1,
                                commit: try Core.sasCommit(pub: dev.pub, account: kp.pub, nonce: nb))
            let a = try await E2E.Approval.begin(E2E.API(mock), request: r, sk: kp.sk)
            a.stop()
            var x = r
            x.challenge = mock.calls.last { $0.path == "/v1/e2e/challenge" }?.body["nonce"] as? String ?? ""
            x.reveal = nb
            var sx = E2E.State()
            sx.requests = [x]
            check("批准方点「取消」后：只停止本机的等待，不再显示核对码", await a.handle(sx, api: E2E.API(mock)) == .challenged, "")
        } catch {
            check("停止批准流程用例", false, "\(error)")
        }
        await offlineAuto(check)
    }

    // MARK: 默认自动加密（§11，服务端 0.8.0）离线用例

    static func stateObj(_ st: E2E.State) -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(st))) ?? [:] }

    static func enabledState(_ keys: [E2E.Key]) -> E2E.State {
        var s = E2E.State()
        s.enabled = keys.contains { $0.active }
        s.auth_key = true
        s.has_password_wrap = true
        s.server_seal = true
        s.keys = keys
        return s
    }

    static func offlineAuto(_ check: Check) async {
        let server = "http://127.0.0.1:2"
        let good: [String: Any] = ["kdf": "argon2id", "salt": String(repeating: "ab", count: 16), "time": 3, "memory_kib": 65536, "lanes": 1]
        var ringCount = 0
        func newRing() -> E2E.KeyRing {
            ringCount += 1
            let suite = "io.github.hongyile.huijian.e2e-selftest-auto-\(ringCount)"
            UserDefaults().removePersistentDomain(forName: suite)
            return E2E.KeyRing(secrets: E2E.MemorySecrets(), scope: "auto#\(ringCount)", defaults: UserDefaults(suiteName: suite)!)
        }
        let marks = freshMarks("io.github.hongyile.huijian.e2e-selftest-auto-marks")
        guard let k1 = try? Core.keypair(), let k2 = try? Core.keypair(), let unlock = try? Core.random32() else { check("生成钥匙", false, ""); return }
        let key1 = E2E.Key(kid: k1.kid, pub: k1.pub, active: true)
        let key1Old = E2E.Key(kid: k1.kid, pub: k1.pub, active: false)
        let key2 = E2E.Key(kid: k2.kid, pub: k2.pub, active: true)

        // 状态里的 0.8.0 字段
        let decoded = try? JSONDecoder().decode(E2E.State.self, from: Data(#"{"enabled":true,"server_seal":true,"plain_messages":3,"keys":[]}"#.utf8))
        check("GET /v1/e2e 的 server_seal、plain_messages（0.8.0）能读出", decoded?.server_seal == true && decoded?.plain_messages == 3, "")

        // §11.4 钉住公钥的更新规则
        do {
            let ring = newRing()
            try E2E.acceptKey(k1.sk, keys: [key1], ring: ring)
            let afterReset = enabledState([key1Old, key2])
            check("别的设备重置过加密：钉住的公钥不是服务器的有效钥匙 → T46，发送密钥不显示，本机旧钥匙解不了新消息",
                  E2E.keyChanged(afterReset, pinned: ring.pinned) && E2E.sendKey(pushkey: "PK", state: afterReset, pinned: ring.pinned) == .mismatch
                  && E2E.status(afterReset, localKeys: [k1.sk]) == .locked, "")
            do {
                try E2E.acceptKey(k2.sk, keys: afterReset.keys, ring: ring)
                check("批准转交来的新私钥不能替换钉住的公钥", false, "")
            } catch {
                check("批准转交来的新私钥不能替换钉住的公钥（T43），钉住的不变", error.localizedDescription == E2E.T.t43 && ring.pinned == k1.pub, "")
            }
            let req = E2E.ApprovalRequest(ring: ring)
            do {
                try await req.start(E2E.API(MockTransport { _, _, _ in (200, ["ok": true]) }), state: afterReset)
                check("钉住的公钥已停用时请求批准", false, "")
            } catch {
                check("钉住的公钥已停用时不能请求批准：T46（只能用密码或恢复码解锁）",
                      (error as? E2E.Failure)?.kind == .keyChanged && req.phase == .failed(E2E.T.t46), "")
            }
            try E2E.acceptOwnKey(k2.sk, keys: afterReset.keys, ring: ring)
            check("用密码 / 恢复码解锁拿到的新私钥：替换钉住的公钥，本机旧私钥保留",
                  ring.pinned == k2.pub && ((try? ring.accountKeys()) ?? []) == [k1.sk, k2.sk] && !E2E.keyChanged(afterReset, pinned: ring.pinned)
                  && E2E.sendKey(pushkey: "PK", state: afterReset, pinned: ring.pinned) == .key("PK.e2e.\(k2.pub)"), "")
            do {
                try E2E.acceptOwnKey(k1.sk, keys: afterReset.keys, ring: ring)
                check("已停用的旧私钥不能用来替换", false, "")
            } catch { check("已停用的旧私钥不能用来替换钉住的公钥（T43）", ring.pinned == k2.pub, "") }
        } catch { check("钉住公钥规则用例", false, "\(error)") }

        // §11.1 自动开启：复用这次登录的钥匙、不生成恢复码
        let pk = E2E.PasswordKeys(salt: String(repeating: "cd", count: 16), authKey: "AUTH_KEY_X", unlockKey: unlock, weak: true)
        do {
            var served = E2E.State()
            var setupBody: [String: Any] = [:]
            let mock = MockTransport { _, path, body -> (Int, Any) in
                switch path {
                case "/v1/e2e": return (200, stateObj(served))
                case "/v1/e2e/setup":
                    setupBody = body
                    served = enabledState([E2E.Key(kid: "kn", pub: body["pub"] as? String ?? "", active: true)])
                    return (200, ["kid": "kn"])
                default: return (500, ["error": "x"])
                }
            }
            let ring = newRing()
            let r = try await E2E.autoSetup(E2E.API(mock), ring: ring, server: server, username: "auto1", keys: pk, marks: marks)
            let pub = setupBody["pub"] as? String ?? ""
            let wrapped = (setupBody["password_wrap"] as? String).flatMap { try? Core.unwrap("hjp1", key: unlock, wrap: $0) }
            check("自动开启：成功；不生成恢复码、不换密码（auth_salt / auth_key / current_auth_key 都是这次登录的）",
                  r == .enabled && setupBody["recovery_wrap"] == nil && setupBody["auth_salt"] as? String == pk.salt
                  && setupBody["auth_key"] as? String == pk.authKey && setupBody["current_auth_key"] as? String == pk.authKey, "\(r)")
            check("自动开启：password_wrap 用这次的 unlock_key 锁住新私钥；私钥已保存、公钥已钉住、标记升级，没有留下进行中的开启",
                  wrapped.map { (try? Core.publicKey($0).pub) == pub } == true && ring.pinned == pub
                  && ((try? ring.accountKeys()) ?? []) == [wrapped ?? "-"] && (try? ring.pendingSetup()) == nil
                  && marks.isUpgraded(server: server, username: "auto1") && E2E.confirmedSetup(ring: ring) == nil, "")
            let again = try await E2E.autoSetup(E2E.API(mock), ring: ring, server: server, username: "auto1", keys: pk, marks: marks)
            check("已经开启、本机已解锁时再调用：什么都不做", again == .alreadyEnabled && mock.calls.filter { $0.path == "/v1/e2e/setup" }.count == 1, "\(again)")
        } catch { check("自动开启用例", false, "\(error)") }

        // §11.1 第 4 步：409（别的设备刚开启过）→ 用这个密码解锁
        do {
            var served = E2E.State()
            let wrap = try Core.wrap("hjp1", key: unlock, data: k1.sk)
            let mock = MockTransport { _, path, body -> (Int, Any) in
                switch path {
                case "/v1/e2e": return (200, stateObj(served))
                case "/v1/e2e/setup":
                    served = enabledState([key1])          // 另一台设备抢先开启了
                    return (409, ["error": "这个账号已经开启了端到端加密"])
                case "/v1/e2e/unlock":
                    return body["auth_key"] as? String == pk.authKey ? (200, ["password_wrap": wrap]) : (403, ["error": "密码不对"])
                default: return (500, ["error": "x"])
                }
            }
            let ring = newRing()
            let r = try await E2E.autoSetup(E2E.API(mock), ring: ring, server: server, username: "auto2", keys: pk, marks: marks)
            check("自动开启遇到 409：改为用这个密码解锁，拿到账号私钥并钉住，没有留下进行中的开启",
                  r == .unlocked && ((try? ring.accountKeys()) ?? []) == [k1.sk] && ring.pinned == k1.pub && (try? ring.pendingSetup()) == nil, "\(r)")
        } catch { check("自动开启 409 用例", false, "\(error)") }

        // 自动开启结果不确定：进行中的开启（没有恢复码）留在钥匙串，刷新时核对成功后直接删除，不显示恢复码页
        do {
            var setupPub = ""
            let mock = MockTransport { _, path, body -> (Int, Any) in
                switch path {
                case "/v1/e2e": return setupPub.isEmpty ? (200, stateObj(E2E.State())) : (503, ["error": "暂时不可用"])
                case "/v1/e2e/setup": setupPub = body["pub"] as? String ?? ""; return (502, "bad gateway")
                default: return (500, ["error": "x"])
                }
            }
            let ring = newRing()
            do {
                _ = try await E2E.autoSetup(E2E.API(mock), ring: ring, server: server, username: "auto3", keys: pk, marks: marks)
                check("自动开启响应丢失", false, "居然成功了")
            } catch let p as E2E.SetupPending {
                check("自动开启响应丢失、状态也取不到：新钥匙存进钥匙串（没有恢复码），提示稍后核对",
                      (try? ring.pendingSetup()) == p.attempt && p.attempt.code.isEmpty && p.attempt.pub == setupPub
                      && ((try? ring.accountKeys()) ?? ["x"]).isEmpty, "")
            }
            let r = try E2E.checkPendingSetup(enabledState([E2E.Key(kid: "k", pub: setupPub, active: true)]), ring: ring, server: server,
                                              username: "auto3", marks: marks)
            var done = false
            if case .completed(let a) = r { done = a.code.isEmpty }
            check("刷新时核对出已经开启：保存私钥、钉住公钥，进行中的开启直接删除（没有恢复码页）",
                  done && ring.pinned == setupPub && ((try? ring.accountKeys()) ?? []).count == 1 && (try? ring.pendingSetup()) == nil
                  && E2E.confirmedSetup(ring: ring) == nil, "\(r)")
        } catch { check("自动开启结果不确定用例", false, "\(error)") }

        // §11.3 重置加密：新钥匙替换钉住的，旧私钥保留；不生成恢复码；只发 reset 接口
        do {
            var served = enabledState([key1])
            var resetBody: [String: Any] = [:]
            var resetStatus = 200
            let mock = MockTransport { _, path, body -> (Int, Any) in
                switch path {
                case "/v1/prelogin": return (200, good)
                case "/v1/e2e": return (200, stateObj(served))
                case "/v1/e2e/reset":
                    resetBody = body
                    if resetStatus == 200 || resetStatus == 504 {
                        served = enabledState([key1Old, E2E.Key(kid: "kr", pub: body["pub"] as? String ?? "", active: true)])
                    }
                    if resetStatus == 409 { return (409, ["error": "账号的登录凭证刚被改过，请刷新后重试"]) }
                    return resetStatus == 200 ? (200, ["kid": "kr"]) : (resetStatus, "gateway timeout")
                default: return (500, ["error": "x"])
                }
            }
            let ring = newRing()
            try E2E.acceptKey(k1.sk, keys: [key1], ring: ring)
            try await E2E.resetE2E(E2E.API(mock), ring: ring, server: server, username: "reset1", password: "pw-weak", marks: marks)
            let newPub = resetBody["pub"] as? String ?? ""
            check("重置加密：新公钥替换钉住的，本机旧私钥保留（看旧消息），不发恢复码副本，用当前密码凭证核对",
                  ring.pinned == newPub && newPub != k1.pub && ((try? ring.accountKeys()) ?? []).first == k1.sk
                  && ((try? ring.accountKeys()) ?? []).count == 2 && resetBody["recovery_wrap"] == nil
                  && resetBody["current_auth_key"] != nil && resetBody["password_wrap"] != nil && (try? ring.pendingSetup()) == nil, "")
            // 结果不确定：服务端其实已经重置（响应丢了）→ 重新读状态确认成功
            resetStatus = 504
            try await E2E.resetE2E(E2E.API(mock), ring: ring, server: server, username: "reset1", password: "pw-weak", marks: marks)
            check("重置加密响应丢失、重新读状态发现已经换成这把：照样成功", ring.pinned == resetBody["pub"] as? String, "")
            // 结果不确定、服务端没换：保留进行中的重置，提示 T.resetUncertain
            resetStatus = 503
            do {
                try await E2E.resetE2E(E2E.API(mock), ring: ring, server: server, username: "reset1", password: "pw-weak", marks: marks)
                check("重置加密 503", false, "")
            } catch let p as E2E.SetupPending {
                check("重置加密结果不确定：新钥匙留在钥匙串，提示稍后核对", p.localizedDescription == E2E.T.resetUncertain
                      && (try? ring.pendingSetup()) == p.attempt, "")
                let r = try E2E.checkPendingSetup(served, ring: ring, server: server, username: "reset1", marks: marks)
                check("刷新时服务端还是原来的钥匙：不能断定失败，保留进行中的重置（审查 L7）",
                      r == .resetPending(p.attempt) && (try? ring.pendingSetup()) == p.attempt && p.attempt.isReset, "\(r)")
                // 之后发现其实生效了 → 完成：保存、替换钉住的公钥、删除记录
                served = enabledState(served.keys.map { E2E.Key(kid: $0.kid, pub: $0.pub, active: false) }
                                      + [E2E.Key(kid: "late", pub: p.attempt.pub, active: true)])
                let r2 = try E2E.checkPendingSetup(served, ring: ring, server: server, username: "reset1", marks: marks)
                var lateOK = false
                if case .completed = r2 { lateOK = true }
                check("晚到生效的重置：刷新时核对出来，换上新钥匙", lateOK && ring.pinned == p.attempt.pub && (try? ring.pendingSetup()) == nil
                      && ((try? ring.accountKeys()) ?? []).contains(p.attempt.sk), "\(r2)")
            }
            // 进行中的重置那把钥匙已经出现在停用列表里（生效过、又被别处重置）：私钥留着看那段时间的消息，记录删除
            let stray = try Core.keypair()
            try ring.savePendingSetup(E2E.SetupAttempt(sk: stray.sk, pub: stray.pub, code: "", reset: true))
            let r3 = try E2E.checkPendingSetup(enabledState([E2E.Key(kid: "s", pub: stray.pub, active: false), key2]), ring: ring,
                                               server: server, username: "reset1", marks: marks)
            check("进行中的重置那把钥匙已停用：私钥保留、记录删除", r3 == .discarded && (try? ring.pendingSetup()) == nil
                  && ((try? ring.accountKeys()) ?? []).contains(stray.sk), "\(r3)")
            // 再点重置时先核对上次的：已经生效就不再提交
            let x = try Core.keypair()
            try ring.savePendingSetup(E2E.SetupAttempt(sk: x.sk, pub: x.pub, code: "", reset: true))
            served = enabledState([E2E.Key(kid: "x", pub: x.pub, active: true)])
            let posts = mock.calls.filter { $0.path == "/v1/e2e/reset" }.count
            try await E2E.resetE2E(E2E.API(mock), ring: ring, server: server, username: "reset1", password: "pw-weak", marks: marks)
            check("再点重置：先核对出上次其实已经生效，不再提交", mock.calls.filter { $0.path == "/v1/e2e/reset" }.count == posts
                  && ring.pinned == x.pub && (try? ring.pendingSetup()) == nil, "")
            let oldRecord = try JSONDecoder().decode(E2E.SetupAttempt.self, from: Data(#"{"sk":"a","pub":"b","code":"c"}"#.utf8))
            check("以前存下的进行中开启（没有 reset 字段）照常读出", oldRecord.reset == nil && !oldRecord.isReset && oldRecord.createdAt == nil, "")
            // 复核 N5：结果不确定的重置 24 小时后按失败处理；用户也可以手动放弃。两种都是私钥保留、记录删除
            let notYet = enabledState([key2])
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            let y = try Core.keypair()
            try ring.savePendingSetup(E2E.SetupAttempt(sk: y.sk, pub: y.pub, code: "", reset: true))
            let r4 = try E2E.checkPendingSetup(notYet, ring: ring, server: server, username: "reset1", marks: marks, now: t0)
            let stamped = try? ring.pendingSetup()
            check("没有时间的旧重置记录：从第一次核对开始计时（补上时间存回去）",
                  stamped?.createdAt == t0.timeIntervalSince1970 && r4 == .resetPending(stamped!), "\(r4)")
            let r5 = try E2E.checkPendingSetup(notYet, ring: ring, server: server, username: "reset1", marks: marks,
                                               now: t0.addingTimeInterval(23 * 3600))
            check("不到 24 小时：继续等", r5 == .resetPending(stamped!) && (try? ring.pendingSetup()) != nil, "\(r5)")
            let r6 = try E2E.checkPendingSetup(notYet, ring: ring, server: server, username: "reset1", marks: marks,
                                               now: t0.addingTimeInterval(24 * 3600))
            check("满 24 小时还没换上：按失败处理，私钥保留、记录删除", r6 == .discarded && (try? ring.pendingSetup()) == nil
                  && ((try? ring.accountKeys()) ?? []).contains(y.sk), "\(r6)")
            let z = try Core.keypair()
            try ring.savePendingSetup(E2E.SetupAttempt(sk: z.sk, pub: z.pub, code: "", reset: true, createdAt: Date().timeIntervalSince1970))
            check("放弃这次重置：私钥保留、记录删除", E2E.abandonReset(ring: ring) && (try? ring.pendingSetup()) == nil
                  && ((try? ring.accountKeys()) ?? []).contains(z.sk), "")
            let notReset = try Core.keypair()
            try ring.savePendingSetup(E2E.SetupAttempt(sk: notReset.sk, pub: notReset.pub, code: "KEEP"))
            check("放弃重置不动普通开启的记录", !E2E.abandonReset(ring: ring) && (try? ring.pendingSetup())?.code == "KEEP"
                  && !((try? ring.accountKeys()) ?? []).contains(notReset.sk), "")
            try ring.deletePendingSetup()
            // 上次的重置还在等结果时再点重置：上次那把私钥保留，再提交新的
            let w = try Core.keypair()
            try ring.savePendingSetup(E2E.SetupAttempt(sk: w.sk, pub: w.pub, code: "", reset: true, createdAt: Date().timeIntervalSince1970))
            served = notYet
            resetStatus = 200
            try await E2E.resetE2E(E2E.API(mock), ring: ring, server: server, username: "reset1", password: "pw-weak", marks: marks)
            check("上次的重置没有结果时再点重置：上次那把私钥保留，这次照常完成", ((try? ring.accountKeys()) ?? []).contains(w.sk)
                  && ring.pinned == resetBody["pub"] as? String && ring.pinned != w.pub && (try? ring.pendingSetup()) == nil, "")
            resetStatus = 409
            do {
                try await E2E.resetE2E(E2E.API(mock), ring: ring, server: server, username: "reset1", password: "pw-weak", marks: marks)
                check("重置加密 409", false, "")
            } catch {
                check("重置加密 409（凭证刚被改过）：报错，不留进行中的重置", (error as? E2E.Failure)?.kind == .conflict && (try? ring.pendingSetup()) == nil, "")
            }
        } catch { check("重置加密用例", false, "\(error)") }

        // §11.5 上传锁住的副本带 kid；本机钥匙已停用时 409 → T46
        do {
            var stale = true
            let mock = MockTransport { _, path, _ -> (Int, Any) in
                switch path {
                case "/v1/prelogin": return (200, good)
                case "/v1/e2e": return (200, stateObj(stale ? enabledState([key1Old, key2]) : enabledState([key1])))
                case "/v1/account/auth", "/v1/e2e/recovery", "/v1/e2e/grant":
                    return (409, ["error": "这把钥匙已经停用"])
                case "/v1/e2e/challenge": return (200, ["ok": true])
                default: return (500, ["error": "x"])
                }
            }
            let api = E2E.API(mock)
            do {
                _ = try await E2E.changeCredentials(api, state: enabledState([key1]), sk: k1.sk, server: server, username: "zed", newUsername: "zed",
                                                    currentPassword: "old-pw", newPassword: "Tq7#mZ2!pL9x-new", marks: marks)
                check("改密码 409", false, "")
            } catch {
                let body = mock.calls.last { $0.path == "/v1/account/auth" }?.body ?? [:]
                check("改密码：password_wrap 带 kid；本机钥匙已停用时 409 → T46",
                      body["kid"] as? String == k1.kid && (error as? E2E.Failure)?.kind == .keyChanged && error.localizedDescription == E2E.T.t46, error.localizedDescription)
            }
            let ring = newRing()
            do {
                _ = try await E2E.rotateRecovery(api, ring: ring, sk: k1.sk, server: server, username: "zed", password: "old-pw", marks: marks)
                check("换恢复码 409", false, "")
            } catch {
                let body = mock.calls.last { $0.path == "/v1/e2e/recovery" }?.body ?? [:]
                check("换恢复码：带 kid；本机钥匙已停用时 409 → T46，新恢复码删除",
                      body["kid"] as? String == k1.kid && error.localizedDescription == E2E.T.t46 && (try? ring.pendingRecovery()) == nil, error.localizedDescription)
            }
            stale = false
            do {
                _ = try await E2E.rotateRecovery(api, ring: ring, sk: k1.sk, server: server, username: "zed", password: "old-pw", marks: marks)
            } catch {
                check("钥匙仍然有效时的 409：照样显示服务端的说明（不是 T46）", (error as? E2E.Failure)?.kind == .conflict && error.localizedDescription != E2E.T.t46, "")
            }
            stale = true
            let dev = try Core.keypair()
            let nb = try Core.random32()
            let rq = E2E.Request(device_id: "d_kid", name: "x", platform: "ios", pub: dev.pub, requested_at: 1,
                                 commit: try Core.sasCommit(pub: dev.pub, account: k1.pub, nonce: nb))
            let a = try await E2E.Approval.begin(api, request: rq, sk: k1.sk)
            var x = rq
            x.challenge = mock.calls.last { $0.path == "/v1/e2e/challenge" }?.body["nonce"] as? String ?? ""
            x.reveal = nb
            var sx = E2E.State()
            sx.requests = [x]
            _ = await a.handle(sx, api: api)
            do { try await a.approve(api, sk: k1.sk); check("批准 409", false, "") } catch {
                let body = mock.calls.last { $0.path == "/v1/e2e/grant" }?.body ?? [:]
                check("批准设备：grant 带 kid；本机钥匙已停用时 409 → T46", body["kid"] as? String == k1.kid && a.phase == .failed(E2E.T.t46), "\(a.phase)")
            }
        } catch { check("kid 用例", false, "\(error)") }

        // 审查 M2：有用户手动开启留下的记录（带恢复码）时不自动开启，也不删它
        do {
            let mock = MockTransport { _, path, _ -> (Int, Any) in path == "/v1/e2e" ? (200, stateObj(E2E.State())) : (500, ["error": "x"]) }
            let ring = newRing()
            let manual = E2E.SetupAttempt(sk: k2.sk, pub: k2.pub, code: "MANUAL-CODE")
            try ring.savePendingSetup(manual)
            let r = try await E2E.autoSetup(E2E.API(mock), ring: ring, server: server, username: "m2", keys: pk, marks: marks)
            check("有手动开启留下的记录：不自动开启（manualPending），记录和恢复码都保留，没有提交",
                  r == .manualPending && (try? ring.pendingSetup()) == manual && !mock.calls.contains { $0.path == "/v1/e2e/setup" }, "\(r)")
        } catch { check("手动记录用例", false, "\(error)") }

        // T67：输入一次当前密码换成自动开启用的钥匙（argon2id 直接算；PBKDF2 顺带升级；没有新登录协议报错）
        do {
            let argon = MockTransport { _, path, _ -> (Int, Any) in
                if path == "/v1/prelogin" { return (200, good as Any) }
                return (500, ["error": "x"] as Any)
            }
            let k = try await E2E.keysForPassword(E2E.API(argon), server: server, username: "t67", password: "123456", marks: marks)
            check("T67 密码 → 钥匙（argon2id）：盐用 prelogin 的，标出弱密码", k.salt == good["salt"] as? String && !k.authKey.isEmpty
                  && !k.unlockKey.isEmpty && k.weak, "")
            check("T67 密码 → 钥匙只请求一次 prelogin（按 IP 限流，复核 N7）",
                  argon.calls.filter { $0.path == "/v1/prelogin" }.count == 1, "\(argon.calls.map(\.path))")
            var putBody: [String: Any] = [:]
            var putStatus = 200
            let pb = MockTransport { _, path, body -> (Int, Any) in
                switch path {
                case "/v1/prelogin": return (200, ["kdf": "pbkdf2-sha256", "salt": String(repeating: "cd", count: 16), "iterations": 600000])
                case "/v1/account/auth": putBody = body; return putStatus == 200 ? (200, ["ok": true]) : (403, ["error": "密码不对"])
                default: return (500, ["error": "x"])
                }
            }
            let k2p = try await E2E.keysForPassword(E2E.API(pb), server: server, username: "t67pb", password: "Tq7#mZ2!pL9x-new", marks: marks)
            check("T67 密码 → 钥匙（PBKDF2 旧账号）：先升级到 Argon2id，返回新盐的钥匙，标记已升级",
                  putBody["current_password_key"] != nil && putBody["auth_salt"] as? String == k2p.salt && putBody["auth_key"] as? String == k2p.authKey
                  && !k2p.weak && marks.isUpgraded(server: server, username: "t67pb"), "")
            putStatus = 403
            do {
                _ = try await E2E.keysForPassword(E2E.API(pb), server: server, username: "t67pb2", password: "wrong-pw-xx", marks: freshMarks("io.github.hongyile.huijian.e2e-selftest-t67"))
                check("T67 密码不对", false, "")
            } catch { check("T67 密码不对（PBKDF2 升级被拒）：T3", error.localizedDescription == E2E.T.t3, error.localizedDescription) }
            let old = MockTransport { _, _, _ -> (Int, Any) in (404, "404 page not found") }
            do {
                _ = try await E2E.keysForPassword(E2E.API(old), server: server, username: "t67old", password: "x", marks: freshMarks("io.github.hongyile.huijian.e2e-selftest-t67b"))
                check("T67 旧服务端", false, "")
            } catch { check("T67 没有新登录协议的服务端：报错，不发密码原文", (error as? E2E.Failure)?.kind == .unsupported, "") }
        } catch { check("T67 用例", false, "\(error)") }

        // 审查 M2（iOS）：补加密的消息只在「本地明文 → 服务器代加密、id 一致」时替换本地记录
        struct FM: E2EMessageFacts { let id: Int64; let isE2E: Bool; let sealed: String? }
        let plainOld = FM(id: 7, isE2E: false, sealed: nil), resealed = FM(id: 7, isE2E: true, sealed: "server")
        check("补加密替换规则：本地明文 + 拉回服务器代加密、id 一致 → 替换", E2E.acceptResealed(old: plainOld, new: resealed, id: 7), "")
        check("补加密替换规则：本地是发送端加密 / 已解开的、已是代加密的、id 不对、没标 server、拉回来是明文 → 都不替换",
              !E2E.acceptResealed(old: FM(id: 7, isE2E: true, sealed: nil), new: resealed, id: 7)
              && !E2E.acceptResealed(old: FM(id: 7, isE2E: true, sealed: "server"), new: resealed, id: 7)
              && !E2E.acceptResealed(old: plainOld, new: FM(id: 8, isE2E: true, sealed: "server"), id: 7)
              && !E2E.acceptResealed(old: plainOld, new: resealed, id: 8)
              && !E2E.acceptResealed(old: plainOld, new: FM(id: 7, isE2E: true, sealed: nil), id: 7)
              && !E2E.acceptResealed(old: plainOld, new: FM(id: 7, isE2E: false, sealed: "server"), id: 7)
              && E2E.maxResealedRetries == 2, "")

        // 自动开启进行中退出登录 / 换了账号：完成时不再写这个账号的钥匙
        do {
            let flag = E2E.AliveFlag()
            let suite = "io.github.hongyile.huijian.e2e-selftest-alive"
            UserDefaults().removePersistentDomain(forName: suite)
            let ring = E2E.KeyRing(secrets: E2E.MemorySecrets(), scope: "alive#1", defaults: UserDefaults(suiteName: suite)!, alive: flag)
            var served = E2E.State()
            let mock = MockTransport { _, path, body -> (Int, Any) in
                switch path {
                case "/v1/e2e": return (200, stateObj(served))
                case "/v1/e2e/setup":
                    flag.kill()            // 请求在路上时用户退出了登录
                    served = enabledState([E2E.Key(kid: "a", pub: body["pub"] as? String ?? "", active: true)])
                    return (200, ["kid": "a"])
                default: return (500, ["error": "x"])
                }
            }
            _ = try? await E2E.autoSetup(E2E.API(mock), ring: ring, server: server, username: "alive", keys: pk, marks: marks)
            check("自动开启进行中退出登录：完成时私钥、钉住的公钥、进行中的开启都没有写进这个账号",
                  ((try? ring.accountKeys()) ?? ["x"]).isEmpty && ring.pinned == nil && (try? ring.pendingSetup()) == nil, "")
            var threw = false
            do { try ring.addAccountKey(k1.sk) } catch { threw = true }
            check("退出后这个账号的 KeyRing 不再写入（删除照常）", threw && (try? ring.deletePendingSetup()) != nil, "")
            check("kill() 等正在进行的写入结束才返回，之后不会再写（复核 N3）", aliveKillWaitsForWrite(), "")
        }

        // §11.5 下载附件 410：按 reason 区分
        let g1 = E2E.gone(Data(#"{"code":410,"error":"附件已加密，请刷新消息","reason":"sealed","message_id":42}"#.utf8))
        let g2 = E2E.gone(Data(#"{"code":410,"error":"附件文件已丢失","reason":"missing"}"#.utf8))
        let g3 = E2E.gone(Data(#"{"error":"附件已加密，请刷新消息"}"#.utf8))      // 没有 reason：不看文字，一律按丢失
        check("410 reason=sealed：重新拉取消息（带消息 id）；reason=missing：附件丢失；没有 reason 时一律按丢失（不比较说明文字）",
              g1.sealed && g1.messageID == 42 && !g2.sealed && g2.reason == "missing" && !g3.sealed && g3.reason == "missing", "")
    }

    // MARK: 默认自动加密（§11）联网用例：服务端 0.8.0，注册要开放

    /// 注册一个新账号（不设置恢复码），验证自动开启、服务器代加密、补加密的 sealed 变更、410 reason、重置加密与 T46、kid。
    /// username / password：新账号（会注册）；server 必须已开放注册
    static func onlineAuto(_ check: Check, server: URL, transport: @escaping (String?) -> E2ETransport,
                           username: String, password: String) async {
        let sid = server.absoluteString
        let marks = freshMarks("io.github.hongyile.huijian.e2e-selftest-online-auto")
        var n = 0
        func ring(_ aid: Int64) -> E2E.KeyRing {
            n += 1
            return E2E.KeyRing(secrets: E2E.MemorySecrets(), scope: E2E.scope(server: sid, accountID: aid),
                               defaults: freshMarks("io.github.hongyile.huijian.e2e-selftest-online-auto-\(n)").defaults)
        }
        func dev(_ name: String) -> E2E.Device { .init(name: name, platform: "macos", fingerprint: (try? Core.random32()) ?? name) }
        do {
            // 注册：服务端还没开启加密
            let reg = try await E2E.login(server: transport(nil), authed: transport, serverID: sid, username: username, password: password,
                                          device: dev("自动 R"), register: true, marks: marks, secrets: E2E.MemorySecrets())
            guard let aid = reg.accountID, let keys = reg.passwordKeys else { check("注册后拿到账号 id 和这次的密码钥匙", false, ""); return }
            let apiR = E2E.API(transport(reg.token))
            var st = try await apiR.state()
            check("注册后：账号还没开启加密，服务器代加密始终开启（server_seal）", !st.enabled && st.server_seal, "")
            // 开启以前收到的明文消息（带附件）
            struct K: Decodable { let key: String }
            let pk = try JSONDecoder().decode(K.self, from: try await apiR.call("POST", "/v1/keys", body: ["name": "auto"])).key
            let fileData = Data((0..<20_000).map { _ in UInt8.random(in: 0...255) })
            try await push(server: server, fields: ["pushkey": pk, "text": "开启前的明文", "desp": "**旧正文**"], file: (name: "旧附件.bin", data: fileData))
            guard let plain = try await messages(apiR, since: 0).last, let plainID = (plain["id"] as? NSNumber)?.int64Value else {
                check("开启前的明文消息", false, ""); return
            }
            let oldAtt = ((plain["attachments"] as? [[String: Any]])?.first?["id"] as? String) ?? ""
            st = try await apiR.state()
            check("还没有钥匙时收到的消息先存明文（plain_messages 计数）", plain["e2e"] == nil && !oldAtt.isEmpty && st.plain_messages >= 1, "\(st.plain_messages)")
            let stateData = try await apiR.call("GET", "/v1/messages/state")
            let cursor = ((try JSONSerialization.jsonObject(with: stateData) as? [String: Any])?["changes_next"] as? NSNumber)?.int64Value ?? 0

            // §11.1 自动开启
            let ringR = ring(aid)
            let r = try await E2E.autoSetup(apiR, ring: ringR, server: sid, username: username, keys: keys, marks: marks)
            st = try await apiR.state()
            let pub1 = st.activeKey?.pub ?? ""
            let keysR1 = try ringR.accountKeys()
            check("注册后自动开启：已开启、没有恢复码、本机已解锁并钉住公钥",
                  r == .enabled && st.enabled && !st.hasRecovery && E2E.status(st, localKeys: keysR1) == .unlocked
                  && ringR.pinned == pub1, "\(r)")

            // 补加密：长轮询变更里出现 kind "sealed"，GET /v1/messages/{id} 拿到 sealed: "server" 的加密消息
            var sealedSeen = false
            for _ in 0..<40 where !sealedSeen {
                let d = try await apiR.call("GET", "/v1/messages", query: [URLQueryItem(name: "since", value: String(plainID)),
                                                                          URLQueryItem(name: "changes_since", value: String(cursor))])
                let changes = ((try JSONSerialization.jsonObject(with: d) as? [String: Any])?["changes"] as? [[String: Any]]) ?? []
                sealedSeen = changes.contains { $0["kind"] as? String == "sealed" && ($0["id"] as? NSNumber)?.int64Value == plainID }
                if !sealedSeen { try await Task.sleep(nanoseconds: 100_000_000) }
            }
            check("开启后服务器补加密历史明文，变更里出现 kind \"sealed\"", sealedSeen, "")
            let one = try JSONSerialization.jsonObject(with: try await apiR.call("GET", "/v1/messages/\(plainID)")) as? [String: Any]
            let msg = one?["message"] as? [String: Any] ?? [:]
            let newAtt = ((msg["attachments"] as? [[String: Any]])?.first?["id"] as? String) ?? ""
            let opened = E2E.open(envelope: msg["e2e"] as? String ?? "", keys: try ringR.accountKeys(), serverAttachments: newAtt.isEmpty ? [] : [newAtt])
            var sameText = false
            if case .ok(let o) = opened { sameText = o.text == "开启前的明文" && o.desp == "**旧正文**" && o.atts.first?.name == "旧附件.bin" }
            check("GET /v1/messages/{id}：sealed=\"server\" 的加密消息，附件换了新 id，本机解开后和原文一致",
                  msg["sealed"] as? String == "server" && !newAtt.isEmpty && newAtt != oldAtt && sameText, "\(opened)")
            let gone = try await transport(reg.token).e2eSend("GET", "/v1/att/\(oldAtt)", query: [], body: nil)
            let g = E2E.gone(gone.data)
            check("用旧附件 id 下载：410 reason=sealed，带消息 id（重新拉取，不是附件丢失）",
                  gone.status == 410 && g.sealed && g.messageID == plainID, "\(gone.status) \(g)")
            do {
                let miss = try await transport(reg.token).e2eSend("GET", "/v1/att/a_not_exist_\(plainID)", query: [], body: nil)
                if miss.status == 410 { check("其他 410 是附件丢失", !E2E.gone(miss.data).sealed, "") }
            }

            // 服务器代加密：开启后用普通 pushkey 发明文
            try await push(server: server, fields: ["pushkey": pk, "text": "代加密的标题", "desp": "正文 *b*"], file: nil)
            if let m = try await messages(apiR, since: plainID).last {
                var ok = false
                if case .ok(let o) = E2E.open(envelope: m["e2e"] as? String ?? "", keys: try ringR.accountKeys(), serverAttachments: []) {
                    ok = o.text == "代加密的标题" && o.desp == "正文 *b*"
                }
                check("开启后普通 pushkey 发的明文：服务器立即加密（sealed=\"server\"），本机解开一致", m["sealed"] as? String == "server" && ok, "")
            } else { check("代加密的消息", false, "") }

            // 另一台设备用密码登录：自动解锁并钉住第一把公钥
            let lgL = try await E2E.login(server: transport(nil), authed: transport, serverID: sid, username: username, password: password,
                                          device: dev("自动 L"), register: false, marks: marks, secrets: E2E.MemorySecrets())
            let ringL = ring(aid)
            let apiL = E2E.API(transport(lgL.token))
            try await E2E.unlockWithPassword(apiL, ring: ringL, server: sid, username: username, password: password, marks: marks)
            check("另一台设备用密码解锁：钉住同一把公钥", ringL.pinned == pub1, "")
            let skOld = try ringL.accountKeys().first ?? ""

            // §11.3 R 重置加密
            try await E2E.resetE2E(apiR, ring: ringR, server: sid, username: username, password: password, marks: marks)
            st = try await apiR.state()
            let pub2 = st.activeKey?.pub ?? ""
            let keysR2 = try ringR.accountKeys()
            check("重置加密：服务器换成新钥匙（旧钥匙停用保留），R 钉住新公钥、保留旧私钥",
                  pub2 != pub1 && st.keys.contains { $0.pub == pub1 && !$0.active } && ringR.pinned == pub2
                  && keysR2.count == 2 && E2E.status(st, localKeys: keysR2) == .unlocked, "")

            // L 看到 T46；旧私钥上传副本被拒（kid）
            let stL = try await apiL.state()
            let keysL = try ringL.accountKeys()
            check("其他设备：服务器的有效钥匙不是钉住的 → T46，不显示发送密钥，已锁定",
                  E2E.keyChanged(stL, pinned: ringL.pinned) && E2E.sendKey(pushkey: pk, state: stL, pinned: ringL.pinned) == .mismatch
                  && E2E.status(stL, localKeys: keysL) == .locked, "")
            do {
                _ = try await E2E.rotateRecovery(apiL, ring: ringL, sk: skOld, server: sid, username: username, password: password, marks: marks)
                check("旧私钥换恢复码", false, "居然成功了")
            } catch {
                check("拿旧私钥换恢复码：服务端按 kid 拒绝（409）→ T46", error.localizedDescription == E2E.T.t46, error.localizedDescription)
            }
            try await E2E.unlockWithPassword(apiL, ring: ringL, server: sid, username: username, password: password, marks: marks)
            let stL2 = try await apiL.state()
            let keysL2 = try ringL.accountKeys()
            check("用密码解锁后：新公钥替换钉住的，T46 消失，旧私钥保留",
                  ringL.pinned == pub2 && !E2E.keyChanged(stL2, pinned: ringL.pinned) && keysL2.count == 2, "")
            // 恢复码可选：之后设置（同一个 PUT /v1/e2e/recovery，带新钥匙的 kid）
            let code = try await E2E.rotateRecovery(apiR, ring: ringR, sk: E2E.usableKey(st, localKeys: try ringR.accountKeys()) ?? "",
                                                    server: sid, username: username, password: password, marks: marks)
            let stR3 = try await apiR.state()
            check("之后设置恢复码：成功，状态里恢复码已设置", !code.isEmpty && stR3.hasRecovery, "")
            // 从没开启过才能用 setup
            do {
                _ = try await E2E.setup(apiR, ring: ring(aid), server: sid, username: username, currentPassword: password, newPassword: nil, marks: marks)
                check("重置后再 setup", false, "")
            } catch { check("开启过的账号不能再 setup（409），换钥匙用 reset", (error as? E2E.Failure)?.kind == .conflict, error.localizedDescription) }

            // T67（§11.1 末尾）：已经登录、内存里没有密码的设备——用户输入一次当前密码再开启
            let userB = username + "-b"
            let regB = try await E2E.login(server: transport(nil), authed: transport, serverID: sid, username: userB, password: password,
                                           device: dev("T67"), register: true, marks: marks, secrets: E2E.MemorySecrets())
            guard let aidB = regB.accountID else { check("T67 账号", false, ""); return }
            let apiB = E2E.API(transport(regB.token))
            let ringB = ring(aidB)
            let stB0 = try await apiB.state()
            check("T67 提示条的条件：账号没开启、server_seal 为 true", !stB0.enabled && stB0.server_seal, "")
            let wrongKeys = try await E2E.keysForPassword(apiB, server: sid, username: userB, password: password + "x", marks: marks)
            do {
                _ = try await E2E.autoSetup(apiB, ring: ringB, server: sid, username: userB, keys: wrongKeys, marks: marks)
                check("T67 输错密码", false, "居然开启了")
            } catch {
                check("T67 输错密码：服务端核对当前凭证拒绝（T3），不留进行中的开启",
                      error.localizedDescription == E2E.T.t3 && (try? ringB.pendingSetup()) == nil, error.localizedDescription)
            }
            let kB = try await E2E.keysForPassword(apiB, server: sid, username: userB, password: password, marks: marks)
            let rB = try await E2E.autoSetup(apiB, ring: ringB, server: sid, username: userB, keys: kB, marks: marks)
            let stB = try await apiB.state()
            let keysB = try ringB.accountKeys()
            check("T67 输入正确密码：开启成功（没有恢复码），本机解锁并钉住，提示条条件不再成立",
                  rB == .enabled && stB.enabled && !stB.hasRecovery && E2E.status(stB, localKeys: keysB) == .unlocked
                  && ringB.pinned == stB.activeKey?.pub, "\(rB)")
        } catch {
            check("默认自动加密联网流程", false, "\(error)")
        }
    }

    // MARK: 联网

    /// 对一个 0.7.0 以上的服务端跑完整流程。tokenA：账号里一台已登录设备（会在它上面开启加密）；
    /// password：账号当前密码（旧方式设置的，PBKDF2）；pushkey：账号的一把 pushkey。
    /// transport(token) 创建传输（token 为 nil 时不带凭证）。结束时 password 已改成返回的新密码
    @discardableResult
    static func online(_ check: Check, server: URL, transport: @escaping (String?) -> E2ETransport,
                       tokenA: String, username: String, password: String, pushkey: String) async -> String? {
        let sid = server.absoluteString
        let marks = freshMarks("io.github.hongyile.huijian.e2e-selftest-online")
        let apiA = E2E.API(transport(tokenA))
        let open = E2E.API(transport(nil))
        func fp() -> String { (0..<32).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined() }
        func dev(_ n: String) -> E2E.Device { .init(name: n, platform: "macos", fingerprint: fp()) }
        func err(_ e: Error) -> String { e.localizedDescription }
        let pinSuite = "io.github.hongyile.huijian.e2e-selftest-online-pins"
        var pinCount = 0
        /// 每台测试设备一份独立的偏好设置（钉住的公钥按设备记）
        func devDefaults() -> UserDefaults { pinCount += 1; return freshMarks(pinSuite + "-\(pinCount)").defaults }
        let newPW = "Hj-selftest-\(Int.random(in: 100000...999999))-Strong"
        do {
            guard let aidA = await E2E.accountID(apiA) else { check("取账号 id", false, ""); return nil }
            let ringA = E2E.KeyRing(secrets: E2E.MemorySecrets(), scope: E2E.scope(server: sid, accountID: aidA), defaults: freshMarks(pinSuite + "-A").defaults)

            // 1. PBKDF2 登录后自动升级
            let p0 = try await E2E.prelogin(open, username: username)
            check("prelogin：旧账号返回 pbkdf2-sha256（\(p0?.kdf ?? "无")）", p0?.kdf == "pbkdf2-sha256", "")
            let l1 = try await E2E.login(server: transport(nil), authed: transport, serverID: sid, username: username, password: password,
                                         device: dev("升级测试"), register: false, marks: marks, secrets: E2E.MemorySecrets())
            let p1 = try await E2E.prelogin(open, username: username)
            check("PBKDF2 登录后自动升级：标记已升级，之后 prelogin 是 argon2id",
                  l1.upgradedNow && marks.isUpgraded(server: sid, username: username) && p1?.kdf == "argon2id", "")
            do {
                _ = try await E2E.login(server: transport(nil), authed: transport, serverID: sid, username: username, password: password + "x",
                                        device: dev("错密码"), register: false, marks: marks, secrets: E2E.MemorySecrets())
                check("错密码被拒绝", false, "")
            } catch { check("Argon2id 登录：错密码被拒绝（\(err(error))）", (error as? E2E.Failure)?.status == 403, "") }

            // 2. 开启加密
            do {
                _ = try await E2E.setup(apiA, ring: ringA, server: sid, username: username, currentPassword: password + "x", newPassword: newPW, marks: marks)
                check("开启加密：当前密码错误", false, "")
            } catch { check("开启加密：当前密码错误 → T3", err(error) == E2E.T.t3, err(error)) }
            check("开启加密失败时没有留下钥匙", ((try? ringA.accountKeys()) ?? ["x"]).isEmpty, "")
            let code = try await E2E.setup(apiA, ring: ringA, server: sid, username: username, currentPassword: password, newPassword: newPW, marks: marks)
            var st = try await apiA.state()
            let keysA = try ringA.accountKeys()
            check("开启加密：服务端已开启、有恢复码副本，本机已解锁", st.enabled && st.hasRecovery && st.auth_key && st.has_password_wrap
                  && E2E.status(st, localKeys: keysA) == .unlocked, "")
            check("恢复码格式 XXXXX-XXXXX-XXXXX-XXXXX-XXXXXX", code.count == 30 && code.split(separator: "-").count == 5, "")
            check("开启成功：进行中的开启（含同一个恢复码）留在钥匙串，直到点「完成」", (try? ringA.pendingSetup())?.code == code, "")
            try ringA.deletePendingSetup()      // 相当于用户点了「完成」
            do {
                _ = try await E2E.setup(apiA, ring: ringA, server: sid, username: username, currentPassword: newPW, newPassword: nil, marks: marks)
                check("重复开启返回 409", false, "")
            } catch { check("已开启时再开启：409（\(err(error))）", (error as? E2E.Failure)?.kind == .conflict, "") }
            guard let skA = E2E.usableKey(st, localKeys: try ringA.accountKeys()) else { check("A 的私钥", false, ""); return nil }

            // 3. 账号密码登录自动解锁
            let ringB = E2E.MemorySecrets()
            let lb = try await E2E.login(server: transport(nil), authed: transport, serverID: sid, username: username, password: newPW,
                                         device: dev("新设备 B"), register: false, marks: marks, secrets: ringB)
            let keysB = try E2E.KeyRing(secrets: ringB, scope: E2E.scope(server: sid, accountID: aidA), defaults: marks.defaults).accountKeys()
            check("用密码登录：自动解锁（私钥核对后保存）", lb.unlocked && keysB == [skA], "")

            // 4. 配对码登录 → 用密码解锁
            func pairDevice(_ name: String) async throws -> (E2E.API, E2E.KeyRing) {
                struct PC: Decodable { let code: String }
                struct PR: Decodable { let token: String }
                // 配对接口按来源 IP 限速（突发 5 次）：碰到 429 等一会儿再试
                var attempt = 0
                while true {
                    do {
                        let pc = try JSONDecoder().decode(PC.self, from: try await apiA.call("POST", "/v1/pair-codes"))
                        let body: [String: Any] = ["code": pc.code, "name": name, "platform": "macos", "fingerprint": fp()]
                        let pr = try JSONDecoder().decode(PR.self, from: try await open.call("POST", "/v1/pair", body: body))
                        return (E2E.API(transport(pr.token)), E2E.KeyRing(secrets: E2E.MemorySecrets(), scope: E2E.scope(server: sid, accountID: aidA),
                                                                          defaults: devDefaults()))
                    } catch let f as E2E.Failure where f.status == 429 && attempt < 4 {
                        attempt += 1
                        try await Task.sleep(nanoseconds: 7_000_000_000)
                    }
                }
            }
            let (apiC, ringC) = try await pairDevice("配对设备 C")
            st = try await apiC.state()
            check("配对码登录的设备：已锁定", E2E.status(st, localKeys: try ringC.accountKeys()) == .locked, "")
            do {
                try await E2E.unlockWithPassword(apiC, ring: ringC, server: sid, username: username, password: "wrong-password-1", marks: marks)
                check("错误密码解锁", false, "")
            } catch { check("用密码解锁：密码错误 → T3", err(error) == E2E.T.t3, err(error)) }
            try await E2E.unlockWithPassword(apiC, ring: ringC, server: sid, username: username, password: newPW, marks: marks)
            check("用密码解锁：成功", E2E.status(try await apiC.state(), localKeys: try ringC.accountKeys()) == .unlocked, "")

            // 5. 恢复码解锁
            let (apiD, ringD) = try await pairDevice("配对设备 D")
            do { try await E2E.unlockWithRecovery(apiD, ring: ringD, code: "abc"); check("恢复码格式不对", false, "") }
            catch { check("恢复码格式不对：显示核心库的说明（\(err(error))）", (error as? E2E.Failure)?.kind == .badRecovery, "") }
            do {
                let other = try Core.recoveryNew().code
                try await E2E.unlockWithRecovery(apiD, ring: ringD, code: other)
                check("别的恢复码", false, "")
            } catch { check("恢复码不对 → T41", err(error) == E2E.T.t41, err(error)) }
            try await E2E.unlockWithRecovery(apiD, ring: ringD, code: code.lowercased().replacingOccurrences(of: "-", with: " "))
            check("用恢复码解锁（大小写、分隔符容错）", E2E.status(try await apiD.state(), localKeys: try ringD.accountKeys()) == .unlocked, "")

            // 6. 设备批准：两台设备核对码一致
            let (apiE, ringE) = try await pairDevice("配对设备 E")
            let req = E2E.ApprovalRequest(ring: ringE)
            try await req.start(apiE)
            st = try await apiA.state()
            guard let rq = st.requests.first(where: { $0.name == "配对设备 E" }) else { check("A 看到批准请求", false, ""); return nil }
            check("已解锁设备看到批准请求（设备名、平台、承诺）", rq.platform == "macos" && !rq.commit.isEmpty && rq.challenge.isEmpty, "")
            let ap = try await E2E.Approval.begin(apiA, request: rq, sk: skA)
            do { _ = try await E2E.Approval.begin(apiC, request: rq, sk: try ringC.accountKeys().first ?? ""); check("第二台设备接手同一请求", false, "") }
            catch { check("第二台设备再接手同一请求：T51", err(error) == E2E.T.t51, err(error)) }
            let phE = await req.handle(try await apiE.state(), api: apiE, generation: req.generation)
            let phA = await ap.handle(try await apiA.state(), api: apiA)
            if case .code(let ce) = phE, case .code(let ca) = phA {
                check("两台设备的核对码一致（\(E2E.formatCode(ce))）", ce == ca && ce.count == 6, "")
            } else { check("两台设备都显示核对码", false, "E=\(phE) A=\(phA)") }
            try await ap.approve(apiA, sk: skA)
            let phE2 = await req.handle(try await apiE.state(), api: apiE, generation: req.generation)
            let keysE = try ringE.accountKeys()
            check("批准后新设备拿到私钥（核对后保存、钉住公钥），设备钥匙对已删除",
                  phE2 == .granted && keysE == [skA] && ringE.pinned == (try? Core.publicKey(skA).pub) && (try? ringE.deviceKeypair()) == nil, "\(phE2)")

            // 7. 拒绝
            let (apiF, ringF) = try await pairDevice("配对设备 F")
            let reqF = E2E.ApprovalRequest(ring: ringF)
            try await reqF.start(apiF)
            if let rf = try await apiA.state().requests.first(where: { $0.name == "配对设备 F" }) {
                let apF = try await E2E.Approval.begin(apiA, request: rf, sk: skA)
                _ = await reqF.handle(try await apiF.state(), api: apiF, generation: reqF.generation)
                _ = await apF.handle(try await apiA.state(), api: apiA)
                try await apF.reject(apiA)
                let ph = await reqF.handle(try await apiF.state(), api: apiF, generation: reqF.generation)
                let keysF = try ringF.accountKeys()
                check("「不一致，拒绝」：新设备显示 T32", ph == .denied && keysF.isEmpty, "\(ph)")
            } else { check("F 的请求", false, "") }

            // 8. 收加密消息：和同样内容的明文消息一致
            st = try await apiA.state()
            guard let pub = st.activeKey?.pub else { check("有效公钥", false, ""); return nil }
            let desp = "## 评估\n\n| 指标 | 值 |\n|---|---|\n| loss | **0.12** |\n\n> [!NOTE]\n> 见附件 ![曲线](attachment:曲线.png)\n\n- [x] 完成"
            let fileData = Data((0..<150_000).map { _ in UInt8.random(in: 0...255) })
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hj-e2e-online-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let plainFile = dir.appendingPathComponent("p"), cipherFile = dir.appendingPathComponent("c")
            try fileData.write(to: plainFile)
            let fkey = try Core.random32()
            try Core.call("encrypt_file", ["key": fkey, "src": plainFile.path, "dst": cipherFile.path])
            let env = try sealPayload(pub: pub, text: "加密 exp44", desp: desp,
                                      atts: [["name": "曲线.png", "mime": "image/png", "size": fileData.count, "key": fkey]])
            let since = try await latestID(apiA)
            try await push(server: server, fields: ["pushkey": "\(pushkey).e2e.\(pub)", "e2e": env, "topic": "e2e", "priority": "4"],
                           file: (name: "encrypted-1.bin", data: try Data(contentsOf: cipherFile)))
            try await push(server: server, fields: ["pushkey": pushkey, "text": "加密 exp44", "desp": desp, "topic": "e2e"],
                           file: (name: "曲线.png", data: fileData))
            let msgs = try await messages(apiA, since: since)
            // 0.8.0 起普通 pushkey 发的明文由服务器代加密（sealed: "server"），0.7 服务端存明文
            guard let em = msgs.first(where: { ($0["e2e"] as? String)?.isEmpty == false && $0["sealed"] == nil }),
                  let pm = msgs.first(where: { $0["sealed"] as? String == "server" || ($0["e2e"] == nil && $0["text"] as? String == "加密 exp44") }) else {
                check("收到加密和明文两条消息", false, "\(msgs.count) 条"); return nil
            }
            let eAtts = (em["attachments"] as? [[String: Any]]) ?? [], pAtts = (pm["attachments"] as? [[String: Any]]) ?? []
            check("服务端只有密文：type=e2e，附件名是占位的", em["type"] as? String == "e2e" && (eAtts.first?["name"] as? String) == "encrypted-1.bin"
                  && (em["desp"] as? String ?? "").isEmpty, "")
            let eIDs = eAtts.compactMap { $0["id"] as? String }, pIDs = pAtts.compactMap { $0["id"] as? String }
            guard case .ok(let o) = E2E.open(envelope: em["e2e"] as! String, keys: try ringA.accountKeys(), serverAttachments: eIDs) else {
                check("解开收到的加密消息", false, ""); return nil
            }
            // 明文那条的内容：服务器代加密的在本机解开，旧服务端的直接读（doc / preview 是服务端解析的）
            var pText = pm["text"] as? String, pDesp = pm["desp"] as? String, pPreview = pm["preview"] as? String
            var pNames = pAtts.compactMap { $0["name"] as? String }, pSize = (pAtts.first?["size"] as? NSNumber)?.int64Value
            var pDoc = try JSONSerialization.data(withJSONObject: pm["doc"] ?? [:])
            if let penv = pm["e2e"] as? String {
                guard case .ok(let po) = E2E.open(envelope: penv, keys: try ringA.accountKeys(), serverAttachments: pIDs) else {
                    check("解开服务器代加密的消息", false, ""); return nil
                }
                check("0.8.0：普通 pushkey 发的明文由服务器代加密（sealed=server，附件是密文），本机解开",
                      pm["type"] as? String == "e2e" && (pAtts.first?["name"] as? String) == "encrypted-1.bin" && pm["doc"] == nil, "")
                pText = po.text; pDesp = po.desp; pPreview = po.preview
                pNames = po.atts.map(\.name); pSize = po.atts.first?.size
                pDoc = po.doc ?? Data()
            }
            check("解密后的标题、正文、附件名与明文消息一致",
                  o.text == pText && o.desp == pDesp && o.atts.map(\.name) == pNames && o.atts.first?.size == pSize, "")
            var normalized = String(decoding: pDoc, as: UTF8.self)
            for (p, e) in zip(pIDs, eIDs) { normalized = normalized.replacingOccurrences(of: p, with: e) }
            check("本地解析的 doc、preview 与同样内容的另一条一致",
                  canonical(o.doc ?? Data()) == canonical(Data(normalized.utf8)) && o.preview == pPreview, "")
            // 下载密文 → 校验密文的 sha256 → 解密
            if let a = eAtts.first, let id = a["id"] as? String, let sha = a["sha256"] as? String, let att = o.atts.first {
                let ct = try await apiA.call("GET", "/v1/att/\(id)")
                let ctFile = dir.appendingPathComponent("dl"), out = dir.appendingPathComponent(att.name)
                try ct.write(to: ctFile)
                check("附件密文的 sha256 与服务端一致", sha256Hex(ct) == sha, "")
                try await E2E.decryptAttachment(key: att.key, src: ctFile, dst: out)
                check("附件解密后与原文件一致，用真实文件名保存", (try? Data(contentsOf: out)) == fileData && out.lastPathComponent == "曲线.png", "")
            }
            check("锁定设备收到同一条：T60（解锁后可以重新解开）",
                  E2E.open(envelope: em["e2e"] as! String, keys: [], serverAttachments: eIDs) == .locked, "")

            // 9. 只接受加密消息
            try await E2E.setE2EOnly(apiA, true)
            do {
                try await push(server: server, fields: ["pushkey": pushkey, "text": "明文", "topic": "e2e"], file: nil)
                check("只接受加密消息时明文被拒", false, "")
            } catch { check("「只接受加密消息」打开后明文发送被拒（\(err(error))）", (error as? E2E.Failure)?.status == 403, "") }
            try await E2E.setE2EOnly(apiA, false)
            check("「只接受加密消息」可以关闭", !(try await apiA.state()).e2e_only, "")

            // 10. 更换恢复码：旧的立即失效
            let code2 = try await E2E.rotateRecovery(apiA, ring: ringA, sk: skA, server: sid, username: username, password: newPW, marks: marks)
            let pr = try ringA.pendingRecovery()
            let stR = try await apiA.state()
            check("更换恢复码：新恢复码存在钥匙串里且已确认，服务端的 recovery_wrap 就是这次上传的那份（刷新时据此核对）",
                  pr?.code == code2 && pr?.confirmed == true && stR.recovery_wrap == pr?.wrap
                  && E2E.checkPendingRecovery(stR, ring: ringA) == pr, "")
            E2E.finishRotation(ring: ringA)      // 相当于用户点了「完成」
            try ringD.removeAll()     // 复用设备 D：清掉钥匙后再用恢复码解锁
            do { try await E2E.unlockWithRecovery(apiD, ring: ringD, code: code); check("旧恢复码失效", false, "") }
            catch { check("更换恢复码后旧的失效（T41）", err(error) == E2E.T.t41, err(error)) }
            try await E2E.unlockWithRecovery(apiD, ring: ringD, code: code2)
            let keysD = try ringD.accountKeys()
            check("新恢复码可以解锁", keysD == [skA], "")

            // 11. 改密码（新协议）：锁定的设备不能改；已解锁的设备改完后新密码能登录并自动解锁
            let newPW2 = newPW + "-2"
            do {
                _ = try await E2E.changeCredentials(apiF, state: try await apiF.state(), sk: nil, server: sid, username: username, newUsername: username,
                                                    currentPassword: newPW, newPassword: newPW2, marks: marks)
                check("锁定的设备改密码", false, "")
            } catch { check("锁定的设备不能改密码，提示先解锁", (error as? E2E.Failure)?.kind == .locked, err(error)) }
            _ = try await E2E.changeCredentials(apiA, state: try await apiA.state(), sk: skA, server: sid, username: username, newUsername: username,
                                                currentPassword: newPW, newPassword: newPW2, marks: marks)
            let lh = try await E2E.login(server: transport(nil), authed: transport, serverID: sid, username: username, password: newPW2,
                                         device: dev("改密码后"), register: false, marks: marks, secrets: E2E.MemorySecrets())
            check("改密码后用新密码登录并自动解锁", lh.unlocked, "")

            // 12. 删除服务器上的明文消息：另一台设备拉变更收到 purge（不是 delete），据此保留本地副本（§7.4）
            struct MS: Decodable { let changes_next: Int64 }
            let cursor = try JSONDecoder().decode(MS.self, from: try await apiC.call("GET", "/v1/messages/state")).changes_next
            let plainIDs = Set(try await messages(apiC, since: 0).filter { ($0["e2e"] as? String ?? "").isEmpty }
                .compactMap { ($0["id"] as? NSNumber)?.int64Value })
            let n = try await E2E.deletePlain(apiA)
            let left = try await messages(apiA, since: 0)
            // 0.8.0 起服务器代加密 + 补加密，开启后服务器上通常已经没有明文：删掉的条数等于删除前剩的明文条数
            check("删除明文消息 \(n) 条（删除前服务器上有 \(plainIDs.count) 条明文），加密消息保留",
                  n == plainIDs.count && !left.isEmpty && left.allSatisfy { ($0["e2e"] as? String)?.isEmpty == false }, "")
            let page = try JSONSerialization.jsonObject(with: try await apiC.call("GET", "/v1/messages", query: [
                URLQueryItem(name: "since", value: String(Int64.max / 2)), URLQueryItem(name: "changes_since", value: String(cursor))])) as? [String: Any]
            let changes = (page?["changes"] as? [[String: Any]]) ?? []
            let purged = Set(changes.filter { $0["kind"] as? String == "purge" }.compactMap { ($0["id"] as? NSNumber)?.int64Value })
            check("另一台设备拉变更：删掉的明文消息记为 purge（\(purged.count) 条），没有 delete",
                  purged.count == n && purged == plainIDs && !changes.contains { $0["kind"] as? String == "delete" }, "purge=\(purged.count) plain=\(plainIDs.count)")

            // 13. 退出登录：删除本机全部私钥
            try ringE.removeAll()
            check("退出登录：本机私钥和设备钥匙对都删除", (try ringE.accountKeys()).isEmpty && (try? ringE.deviceKeypair()) == nil
                  && marks.isUpgraded(server: sid, username: username), "")
            return newPW2
        } catch {
            check("端到端加密联网流程", false, err(error))
            return nil
        }
    }

    // MARK: 工具

    static func canonical(_ d: Data) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: d),
              let c = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "" }
        return String(decoding: c, as: UTF8.self)
    }

    /// 只用来核对附件密文的校验值（和 Downloads.swift 一样用系统的 SHA-256）
    static func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func latestID(_ api: E2E.API) async throws -> Int64 {
        let d = try await api.call("GET", "/v1/messages", query: [URLQueryItem(name: "limit", value: "1")])
        let o = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        return ((o?["messages"] as? [[String: Any]])?.last?["id"] as? NSNumber)?.int64Value ?? 0
    }

    static func messages(_ api: E2E.API, since: Int64) async throws -> [[String: Any]] {
        let d = try await api.call("GET", "/v1/messages", query: [URLQueryItem(name: "since", value: String(since)), URLQueryItem(name: "limit", value: "500")])
        return ((try JSONSerialization.jsonObject(with: d) as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
    }

    /// multipart 发送；HTTP 错误抛 E2E.Failure（带状态码）
    static func push(server: URL, fields: [String: String], file: (name: String, data: Data)?) async throws {
        let boundary = "hj-\(UUID().uuidString)"
        var body = Data()
        for (k, v) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        if let file {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(file.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        var r = URLRequest(url: server.appendingPathComponent("message/push"))
        r.httpMethod = "POST"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: r, from: body)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(status) {
            throw E2E.Failure(.server, E2E.errorMessage(E2E.Response(status: status, data: data)), status: status)
        }
    }
}
