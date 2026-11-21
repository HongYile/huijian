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

        // 0.9.0 注册即开启加密（register.e2e）：钥匙随注册一起提交，成功后本机已解锁、钉住本机生成的公钥，不再调 setup；
        // 旧服务端（没有这个功能）照旧只注册，留下 passwordKeys 给调用方自动开启
        for withFeature in [true, false] {
            var regBody: [String: Any] = [:]
            let suite = "io.github.hongyile.huijian.e2e-selftest-rege2e"
            let m = freshMarks(suite)
            let secrets = E2E.MemorySecrets()
            let mock = MockTransport { _, path, body -> (Int, Any) in
                switch path {
                case "/v1/info": return (200, ["name": "huijian", "version": withFeature ? "0.9.0" : "0.8.0", "api": 1,
                                                "features": withFeature ? [["id": "e2e.auto"], ["id": "register.e2e"]] : [["id": "e2e.auto"]]] as Any)
                case "/v1/prelogin": return (200, good as Any)
                case "/v1/me": return (200, ["account": ["id": 7]] as Any)
                case "/v1/register":
                    regBody = body
                    var r: [String: Any] = ["device_id": "d1", "name": "注册", "token": "T_reg", "reused": false]
                    if let pub = body["pub"] as? String {
                        r["e2e"] = ["enabled": true, "keys": [["kid": "kreg", "pub": pub, "active": true]],
                                    "password_wrap": body["password_wrap"] as? String ?? ""]
                    }
                    return (200, r as Any)
                case "/v1/e2e/setup": return (409, ["error": "已经开启"] as Any)
                default: return (500, ["error": "x"] as Any)
                }
            }
            do {
                let r = try await E2E.login(server: mock, authed: { _ in mock }, serverID: server, username: "rege2e",
                                            password: "Tq7#mZ2!pL9x-new", device: E2E.Device(name: "注册", platform: "macos", fingerprint: String(repeating: "cd", count: 32)),
                                            register: true, marks: m, secrets: secrets, inviteCode: "ABCDE23456")
                let ring = E2E.KeyRing(secrets: secrets, scope: E2E.scope(server: server, accountID: 7), defaults: m.defaults)
                let keys = (try? ring.accountKeys()) ?? []
                if withFeature {
                    let pub = regBody["pub"] as? String ?? ""
                    let unwrapped = try? Core.unwrap("hjp1", key: r.passwordKeys?.unlockKey ?? "", wrap: regBody["password_wrap"] as? String ?? "")
                    check("注册即开启加密：随注册提交 pub / password_wrap / auth_salt / auth_key / invite_code（不带恢复码、不发密码原文），不调 setup",
                          !pub.isEmpty && regBody["auth_salt"] != nil && regBody["auth_key"] != nil && regBody["recovery_wrap"] == nil
                          && regBody["password"] == nil && regBody["invite_code"] as? String == "ABCDE23456"
                          && !mock.calls.contains { $0.path == "/v1/e2e/setup" }, "")
                    check("注册即开启加密：成功后本机已解锁，私钥存好、钉住本机生成的公钥，password_wrap 用密码能解开",
                          r.unlocked && keys.count == 1 && ring.pinned == pub && unwrapped == keys.first
                          && m.isUpgraded(server: server, username: "rege2e"), "")
                } else {
                    check("旧服务端（没有 register.e2e）：只注册不带钥匙，未解锁，留下 passwordKeys 给调用方自动开启",
                          regBody["pub"] == nil && regBody["password_wrap"] == nil && regBody["auth_key"] != nil
                          && !r.unlocked && keys.isEmpty && r.passwordKeys != nil, "")
                }
            } catch { check("注册即开启加密用例（\(withFeature)）", false, "\(error)") }
        }

        // 审查 0.9 M1 / L1 / L2 / L4：取不到 /v1/info 不猜（不提交）；200 之后的失败按结果不确定；
        // 服务器给的有效钥匙不是本机那把 → T43、不保存；取不到账号 id → 私钥留在 pendingKey，之后保存并钉住
        do {
            var regMode = "mismatch"
            var posts = 0
            let other = try Core.keypair()
            let mock = MockTransport { _, path, body -> (Int, Any) in
                switch path {
                case "/v1/info":
                    if regMode == "noinfo" { return (503, "service unavailable" as Any) }
                    return (200, ["name": "huijian", "version": "0.9.0", "api": 1, "features": [["id": "register.e2e"]]] as Any)
                case "/v1/prelogin": return (200, good as Any)
                case "/v1/me": return regMode == "noaid" ? (500, ["error": "x"] as Any) : (200, ["account": ["id": 9]] as Any)
                case "/v1/register":
                    posts += 1
                    if regMode == "notoken" { return (200, ["device_id": "d"] as Any) }
                    let pub = regMode == "mismatch" ? other.pub : (body["pub"] as? String ?? "")
                    return (200, ["device_id": "d", "name": "n", "token": "T_x", "reused": false,
                                  "e2e": ["enabled": true, "keys": [["kid": "k", "pub": pub, "active": true]], "password_wrap": "hjp1.x"]] as Any)
                default: return (500, ["error": "x"] as Any)
                }
            }
            func reg(_ secrets: E2ESecrets, _ m: E2E.UpgradeMarks) async throws -> E2E.LoginResult {
                try await E2E.login(server: mock, authed: { _ in mock }, serverID: server, username: "l4user", password: "Tq7#mZ2!pL9x-new",
                                    device: E2E.Device(name: "x", platform: "macos", fingerprint: String(repeating: "cd", count: 32)),
                                    register: true, marks: m, secrets: secrets)
            }
            let m1 = freshMarks("io.github.hongyile.huijian.e2e-selftest-l4")
            let sec1 = E2E.MemorySecrets()
            let r1 = try await reg(sec1, m1)
            let ring1 = E2E.KeyRing(secrets: sec1, scope: E2E.scope(server: server, accountID: 9), defaults: m1.defaults)
            check("注册后服务器给的有效钥匙不是本机生成的那把：T43，不保存、不钉住，留着 passwordKeys 之后用密码解锁",
                  r1.note == E2E.T.t43 && !r1.unlocked && ((try? ring1.accountKeys()) ?? ["x"]).isEmpty && ring1.pinned == nil
                  && r1.passwordKeys != nil && r1.pendingKey == nil, "\(r1.note ?? "-")")
            regMode = "noaid"
            let m2 = freshMarks("io.github.hongyile.huijian.e2e-selftest-l4b")
            let sec2 = E2E.MemorySecrets()
            let r2 = try await reg(sec2, m2)
            var later = false
            if let pk = r2.pendingKey {
                let ring2 = E2E.KeyRing(secrets: sec2, scope: E2E.scope(server: server, accountID: 9), defaults: m2.defaults)
                let nothingYet = ((try? ring2.accountKeys()) ?? ["x"]).isEmpty
                try E2E.acceptOwnKey(pk.sk, keys: pk.keys, ring: ring2)      // 拿到账号 id 后调用方这样保存（Mac loadE2EKeys）
                later = nothingYet && ((try? ring2.accountKeys()) ?? []) == [pk.sk] && ring2.pinned == pk.keys.first?.pub
            }
            check("注册后取不到账号 id：私钥核对后留在 pendingKey（还没保存），拿到账号 id 后保存并钉住", r2.accountID == nil && !r2.unlocked && later, "")
            regMode = "noinfo"
            let before = posts
            do { _ = try await reg(E2E.MemorySecrets(), freshMarks("io.github.hongyile.huijian.e2e-selftest-l4c")); check("取不到 info 却注册了", false, "") }
            catch { check("注册前取不到 /v1/info：不猜新旧，提示连不上服务器，不提交注册", error.localizedDescription == E2E.T.serverUnreachable && posts == before, error.localizedDescription) }
            regMode = "notoken"
            do { _ = try await reg(E2E.MemorySecrets(), freshMarks("io.github.hongyile.huijian.e2e-selftest-l4d")); check("200 但没有 token", false, "") }
            catch { check("注册返回 200 但响应不对：账号可能已建好，按结果不确定处理", (error as? E2E.Failure)?.kind == .uncertain, "\(error)") }
        } catch { check("审查 0.9 L4 用例", false, "\(error)") }

        // 三端一致：注册结果不确定（网络出错、网关 5xx）→ T.registerUncertain；之后同一个用户名再注册被拒（409 / 403）→ 提示改去登录。
        // 注册一律不发密码原文：没有新登录协议的旧服务端直接报 T.registerServerTooOld
        do {
            final class Flaky: E2ETransport {
                var mode = 0      // 0 网络出错、1 网关 502、2 服务端 500、3 旧服务端（没有 prelogin）
                var posted = 0
                func e2eSend(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> E2E.Response {
                    func json(_ st: Int, _ o: Any) -> E2E.Response {
                        E2E.Response(status: st, data: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), contentType: "application/json")
                    }
                    switch path {
                    case "/v1/info": return json(200, ["name": "huijian", "version": "0.8.0", "api": 1, "features": [["id": "e2e.auto"]]])
                    case "/v1/prelogin":
                        if mode == 3 { return E2E.Response(status: 404, data: Data("404 page not found".utf8), contentType: "text/plain") }
                        return json(200, ["kdf": "argon2id", "salt": String(repeating: "ab", count: 16), "time": 3, "memory_kib": 65536, "lanes": 1])
                    case "/v1/register":
                        posted += 1
                        switch mode {
                        case 0: throw URLError(.timedOut)
                        case 1: return E2E.Response(status: 502, data: Data("bad gateway".utf8), contentType: "text/plain")
                        default: return json(500, ["code": 500, "error": "注册失败"])
                        }
                    default: return json(500, ["error": "x"])
                    }
                }
            }
            let t = Flaky()
            var kinds: [String] = []
            for mode in 0...3 {
                t.mode = mode
                do {
                    _ = try await E2E.login(server: t, authed: { _ in t }, serverID: server, username: "flaky", password: "Tq7#mZ2!pL9x-new",
                                            device: E2E.Device(name: "x", platform: "macos", fingerprint: String(repeating: "cd", count: 32)),
                                            register: true, marks: freshMarks("io.github.hongyile.huijian.e2e-selftest-flaky"), secrets: E2E.MemorySecrets())
                    kinds.append("ok")
                } catch let f as E2E.Failure { kinds.append("\(f.kind.rawValue):\(f.message)") } catch { kinds.append("other") }
            }
            check("注册网络出错、网关 502：结果不确定（提示先去登录）；服务端 500：明确失败；旧服务端：不发原文，提示升级服务端",
                  kinds == ["uncertain:" + E2E.T.registerUncertain, "uncertain:" + E2E.T.registerUncertain, "server:注册失败",
                            "unsupported:" + E2E.T.registerServerTooOld] && t.posted == 3, "\(kinds)")
            let after409 = E2E.registerAfterUncertain(E2E.Failure(.conflict, "这个用户名已被使用", status: 409))
            let after403 = E2E.registerAfterUncertain(E2E.Failure(.server, "邀请码已用完。", status: 403))
            check("上次结果不确定、这次被拒（409 / 403）：提示改去登录；其他错误照常",
                  after409 == "这个用户名已被使用。" + E2E.T.registerTryLogin && after403 == "邀请码已用完。" + E2E.T.registerTryLogin
                  && E2E.registerAfterUncertain(E2E.Failure(.server, "x", status: 400)) == nil, "")
        }

        // 0.9.0 注册邀请码：填了就带 invite_code（去掉首尾空白），没填不带；邀请码不对时服务端 403 的说明原样给用户
        do {
            var bodies: [[String: Any]] = []
            let reg = MockTransport { _, path, body -> (Int, Any) in
                switch path {
                case "/v1/info": return (200, ["name": "huijian", "version": "0.8.0", "api": 1, "features": [["id": "e2e.auto"]]] as Any)
                case "/v1/prelogin": return (200, good as Any)
                case "/v1/register": bodies.append(body); return (403, ["error": "邀请码不对或已经用完"] as Any)
                default: return (500, ["error": "x"] as Any)
                }
            }
            let d = E2E.Device(name: "邀请", platform: "macos", fingerprint: String(repeating: "ab", count: 32))
            var msgs: [String] = []
            for code in [" INV-123 ", nil] {
                do {
                    _ = try await E2E.login(server: reg, authed: { _ in reg }, serverID: server, username: "invitee",
                                            password: "Tq7#mZ2!pL9x-new", device: d, register: true, marks: freshMarks("io.github.hongyile.huijian.e2e-selftest-invite"),
                                            secrets: E2E.MemorySecrets(), inviteCode: code)
                } catch { msgs.append(error.localizedDescription) }
            }
            check("注册邀请码：填了带 invite_code（去掉空白），没填不带；403 的说明原样显示",
                  bodies.count == 2 && bodies[0]["invite_code"] as? String == "INV-123" && bodies[1]["invite_code"] == nil
                  && msgs == ["邀请码不对或已经用完", "邀请码不对或已经用完"], "\(msgs)")
        }

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

    // MARK: 默认自动加密（§11）联网用例：服务端 0.9.0（注册即开启加密）

    /// 0.9.0 以前存下的明文历史（测试脚本停服后直接写进数据库，启动时服务端补加密）：
    /// 那个账号的用户名、密码，它一台设备的 token，补加密以前的变更游标，旧附件 id，原文
    struct SealFixture {
        var username: String
        var password: String
        var token: String
        var cursor: Int64
        var oldAttachment: String
        var text: String
        var desp: String
        var attachmentName: String
        var attachmentData: Data
    }

    /// 注册一个新账号（注册即开启加密，没有恢复码），验证服务器代加密、重置加密与 T46、kid；
    /// seal 不为空时验证补加密历史的 sealed 变更和 410 reason；noKeyPushkey 是一个还没有钥匙的旧账号的 pushkey（明文推送应 403）
    static func onlineAuto(_ check: Check, server: URL, transport: @escaping (String?) -> E2ETransport, invite: String,
                           username: String, password: String, seal: SealFixture?, noKeyPushkey: String?) async {
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
            // 0.9.0 以前留下的明文历史：启动时补加密，变更里出现 kind "sealed"，GET /v1/messages/{id} 拿到 sealed: "server" 的加密消息
            if let seal {
                let lg = try await E2E.login(server: transport(nil), authed: transport, serverID: sid, username: seal.username, password: seal.password,
                                             device: dev("补加密 L"), register: false, marks: marks, secrets: E2E.MemorySecrets())
                guard let aid = lg.accountID else { check("补加密账号的 id", false, ""); return }
                let ringS = ring(aid)
                let apiS = E2E.API(transport(seal.token))
                try await E2E.unlockWithPassword(apiS, ring: ringS, server: sid, username: seal.username, password: seal.password, marks: marks)
                var sealedID: Int64?
                for _ in 0..<50 where sealedID == nil {
                    let d = try await apiS.call("GET", "/v1/messages", query: [URLQueryItem(name: "since", value: String(Int64.max / 2)),
                                                                              URLQueryItem(name: "changes_since", value: String(seal.cursor))])
                    let changes = ((try JSONSerialization.jsonObject(with: d) as? [String: Any])?["changes"] as? [[String: Any]]) ?? []
                    sealedID = changes.first { $0["kind"] as? String == "sealed" }.flatMap { ($0["id"] as? NSNumber)?.int64Value }
                    if sealedID == nil { try await Task.sleep(nanoseconds: 100_000_000) }
                }
                check("启动时补加密 0.9.0 以前的明文历史，变更里出现 kind \"sealed\"", sealedID != nil, "")
                if let id = sealedID {
                    let one = try JSONSerialization.jsonObject(with: try await apiS.call("GET", "/v1/messages/\(id)")) as? [String: Any]
                    let msg = one?["message"] as? [String: Any] ?? [:]
                    let newAtt = ((msg["attachments"] as? [[String: Any]])?.first?["id"] as? String) ?? ""
                    let opened = E2E.open(envelope: msg["e2e"] as? String ?? "", keys: try ringS.accountKeys(), serverAttachments: newAtt.isEmpty ? [] : [newAtt])
                    var same = false
                    if case .ok(let o) = opened {
                        same = o.text == seal.text && o.desp == seal.desp && o.atts.first?.name == seal.attachmentName
                            && o.atts.first?.size == Int64(seal.attachmentData.count)
                        if let a = o.atts.first, same {
                            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hj-seal-\(UUID().uuidString)")
                            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                            defer { try? FileManager.default.removeItem(at: dir) }
                            let ct = dir.appendingPathComponent("c"), out = dir.appendingPathComponent("p")
                            try await apiS.call("GET", "/v1/att/\(newAtt)").write(to: ct)
                            try await E2E.decryptAttachment(key: a.key, src: ct, dst: out)
                            same = (try? Data(contentsOf: out)) == seal.attachmentData
                        }
                    }
                    check("GET /v1/messages/{id}：sealed=\"server\" 的加密消息，附件换了新 id，本机解开后标题、正文、附件都和原文一致",
                          msg["sealed"] as? String == "server" && !newAtt.isEmpty && newAtt != seal.oldAttachment && same, "\(opened)")
                    let gone = try await transport(seal.token).e2eSend("GET", "/v1/att/\(seal.oldAttachment)", query: [], body: nil)
                    let g = E2E.gone(gone.data)
                    check("用旧附件 id 下载：410 reason=sealed，带消息 id（重新拉取，不是附件丢失）",
                          gone.status == 410 && g.sealed && g.messageID == id, "\(gone.status) \(g)")
                }
            }
            if let pk = noKeyPushkey {
                do {
                    try await push(server: server, fields: ["pushkey": pk, "text": "没有钥匙的账号"], file: nil)
                    check("还没有钥匙的账号收明文", false, "居然收下了")
                } catch {
                    check("还没有钥匙的账号：明文推送 403（服务器不保存明文）", (error as? E2E.Failure)?.status == 403, error.localizedDescription)
                }
            }

            // 注册即开启加密（没有恢复码）
            let secretsR = E2E.MemorySecrets()
            let reg = try await E2E.login(server: transport(nil), authed: transport, serverID: sid, username: username, password: password,
                                          device: dev("自动 R"), register: true, marks: marks, secrets: secretsR, inviteCode: invite)
            guard let aid = reg.accountID else { check("注册后拿到账号 id", false, ""); return }
            let apiR = E2E.API(transport(reg.token))
            let ringR = E2E.KeyRing(secrets: secretsR, scope: E2E.scope(server: sid, accountID: aid), defaults: marks.defaults)
            var st = try await apiR.state()
            let pub1 = st.activeKey?.pub ?? ""
            let keysR1 = try ringR.accountKeys()
            check("注册即开启：已开启、没有恢复码、服务器代加密始终开启，本机已解锁并钉住公钥",
                  reg.unlocked && st.enabled && !st.hasRecovery && st.server_seal && E2E.status(st, localKeys: keysR1) == .unlocked
                  && ringR.pinned == pub1 && !pub1.isEmpty, "")

            // 服务器代加密：普通 pushkey 发的明文（带附件）
            struct K: Decodable { let key: String }
            let pk = try JSONDecoder().decode(K.self, from: try await apiR.call("POST", "/v1/keys", body: ["name": "auto"])).key
            let fileData = Data((0..<20_000).map { _ in UInt8.random(in: 0...255) })
            try await push(server: server, fields: ["pushkey": pk, "text": "代加密的标题", "desp": "正文 *b*"], file: (name: "明文附件.bin", data: fileData))
            if let m = try await messages(apiR, since: 0).last {
                var ok = false
                let ids = ((m["attachments"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
                if case .ok(let o) = E2E.open(envelope: m["e2e"] as? String ?? "", keys: try ringR.accountKeys(), serverAttachments: ids) {
                    ok = o.text == "代加密的标题" && o.desp == "正文 *b*" && o.atts.first?.name == "明文附件.bin"
                }
                check("普通 pushkey 发的明文：服务器立即加密（sealed=\"server\"，接收端标「明文发送」），本机解开一致",
                      m["sealed"] as? String == "server" && m["type"] as? String == "e2e" && ok, "")
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
        } catch {
            check("默认自动加密联网流程", false, "\(error)")
        }
    }

    // MARK: 联网

    /// 对一个 0.9.0 以上的服务端跑完整流程（账号只能注册产生，注册即开启加密）。invite：可用多次的邀请码；
    /// username / password：要注册的新账号。transport(token) 创建传输（token 为 nil 时不带凭证）。结束时密码已改成返回的新密码
    @discardableResult
    static func online(_ check: Check, server: URL, transport: @escaping (String?) -> E2ETransport,
                       invite: String, username: String, password: String) async -> String? {
        let sid = server.absoluteString
        let marks = freshMarks("io.github.hongyile.huijian.e2e-selftest-online")
        let open = E2E.API(transport(nil))
        func fp() -> String { (0..<32).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined() }
        func dev(_ n: String) -> E2E.Device { .init(name: n, platform: "macos", fingerprint: fp()) }
        func err(_ e: Error) -> String { e.localizedDescription }
        let pinSuite = "io.github.hongyile.huijian.e2e-selftest-online-pins"
        var pinCount = 0
        /// 每台测试设备一份独立的偏好设置（钉住的公钥按设备记）
        func devDefaults() -> UserDefaults { pinCount += 1; return freshMarks(pinSuite + "-\(pinCount)").defaults }
        let newPW = password
        do {
            // 1. 邀请码：没带 / 不对都是 403，说明原样给用户；什么都不建
            for code in [nil, "ZZZZZZZZZZ"] as [String?] {
                do {
                    _ = try await E2E.login(server: transport(nil), authed: transport, serverID: sid, username: username, password: password,
                                            device: dev("没邀请码"), register: true, marks: freshMarks("io.github.hongyile.huijian.e2e-selftest-online-x"),
                                            secrets: E2E.MemorySecrets(), inviteCode: code)
                    check("注册没带对邀请码", false, "居然成功了")
                } catch {
                    check("注册\(code == nil ? "没带" : "带错")邀请码：403，显示服务端说明（\(err(error))）",
                          (error as? E2E.Failure)?.status == 403 && !err(error).isEmpty, "")
                }
            }

            // 2. 注册即开启加密：钥匙随注册提交，本机已解锁、钉住本机生成的公钥，没有恢复码
            let secretsA = E2E.MemorySecrets()
            let regA = try await E2E.login(server: transport(nil), authed: transport, serverID: sid, username: username, password: password,
                                           device: dev("设备 A"), register: true, marks: marks, secrets: secretsA, inviteCode: invite)
            guard let aidA = regA.accountID else { check("注册后取账号 id", false, ""); return nil }
            let apiA = E2E.API(transport(regA.token))
            let ringA = E2E.KeyRing(secrets: secretsA, scope: E2E.scope(server: sid, accountID: aidA), defaults: marks.defaults)
            var st = try await apiA.state()
            let keysA = try ringA.accountKeys()
            check("注册即开启加密：服务端已开启（有用密码锁住的副本、没有恢复码），本机已解锁并钉住",
                  regA.unlocked && st.enabled && st.auth_key && st.has_password_wrap && !st.hasRecovery && st.server_seal
                  && E2E.status(st, localKeys: keysA) == .unlocked && ringA.pinned == st.activeKey?.pub, "")
            let p1 = try await E2E.prelogin(open, username: username)
            check("注册后 prelogin 是 argon2id，本机记为已升级", p1?.kdf == "argon2id" && marks.isUpgraded(server: sid, username: username), "")
            do {
                _ = try await E2E.login(server: transport(nil), authed: transport, serverID: sid, username: username, password: password + "x",
                                        device: dev("错密码"), register: false, marks: marks, secrets: E2E.MemorySecrets())
                check("错密码被拒绝", false, "")
            } catch { check("Argon2id 登录：错密码被拒绝（\(err(error))）", (error as? E2E.Failure)?.status == 403, "") }
            do {
                _ = try await E2E.setup(apiA, ring: ringA, server: sid, username: username, currentPassword: password, newPassword: nil, marks: marks)
                check("注册后再 setup", false, "")
            } catch { check("注册即开启后不能再 setup（409）", (error as? E2E.Failure)?.kind == .conflict, err(error)) }
            guard let skA = E2E.usableKey(st, localKeys: keysA) else { check("A 的私钥", false, ""); return nil }
            // 恢复码可选：注册时不生成，之后设置（PUT /v1/e2e/recovery，带 kid）
            let code = try await E2E.rotateRecovery(apiA, ring: ringA, sk: skA, server: sid, username: username, password: password, marks: marks)
            E2E.finishRotation(ring: ringA)      // 相当于用户点了「完成」
            st = try await apiA.state()
            check("之后设置恢复码：成功，格式 XXXXX-XXXXX-XXXXX-XXXXX-XXXXXX", st.hasRecovery && code.count == 30
                  && code.split(separator: "-").count == 5, "")
            // pushkey 由账号自己新建（管理后台不再管 pushkey）
            struct K: Decodable { let key: String }
            let pushkey = try JSONDecoder().decode(K.self, from: try await apiA.call("POST", "/v1/keys", body: ["name": "e2e"])).key

            // 3. 账号密码登录自动解锁
            let ringB = E2E.MemorySecrets()
            let lb = try await E2E.login(server: transport(nil), authed: transport, serverID: sid, username: username, password: newPW,
                                         device: dev("新设备 B"), register: false, marks: marks, secrets: ringB)
            let keysB = try E2E.KeyRing(secrets: ringB, scope: E2E.scope(server: sid, accountID: aidA), defaults: marks.defaults).accountKeys()
            check("用密码登录：自动解锁（私钥核对后保存）", lb.unlocked && keysB == [skA], "")

            // 3b. 配对码带钥匙（§12，服务端 0.10.0）：扫码 / 长配对码登录后直接解锁；钥匙不对 T82、没带钥匙 T83、只输 6 位照旧锁定
            do {
                /// 配对接口按来源 IP 限速（突发 5 次）：碰到 429 等一会儿再试
                func retry<R>(_ f: () async throws -> R) async throws -> R {
                    var attempt = 0
                    while true {
                        do { return try await f() } catch let e as E2E.Failure where e.status == 429 && attempt < 4 {
                            attempt += 1
                            try await Task.sleep(nanoseconds: 7_000_000_000)
                        }
                    }
                }
                func pairWith(_ code: String, _ secret: String?, _ name: String) async throws -> (E2E.LoginResult, E2E.KeyRing) {
                    let m = freshMarks("io.github.hongyile.huijian.e2e-selftest-online-pk-\(name.hashValue)")
                    let sec = E2E.MemorySecrets()
                    let r = try await retry { try await E2E.pair(server: transport(nil), authed: transport, serverID: sid, code: code, secret: secret,
                                                                  device: dev(name), marks: m, secrets: sec) }
                    return (r, E2E.KeyRing(secrets: sec, scope: E2E.scope(server: sid, accountID: aidA), defaults: m.defaults))
                }
                let stK = try await apiA.state()
                let active = E2E.activeSecretKey(keysA, state: stK, pinned: ringA.pinned)
                check("配对码带钥匙：本机找到账号 active 钥匙的私钥", active == skA, "")
                let strayKey = try Core.keypair().sk
                let strayPub = try Core.publicKey(strayKey).pub
                check("配对码带钥匙：本机没解锁（没有私钥）、钉住的公钥和服务器说的 active 不同（T46）时不带钥匙",
                      E2E.activeSecretKey([], state: stK, pinned: nil) == nil && E2E.activeSecretKey([strayKey], state: stK, pinned: nil) == nil
                      && E2E.activeSecretKey(keysA, state: stK, pinned: strayPub) == nil, "")
                check("配对链接的服务器地址：空的、默认的、相同的直接填，不同的要确认",
                      E2E.pairServerAutoFill(current: "", link: "https://a.example", defaultServer: "https://d.example")
                      && E2E.pairServerAutoFill(current: "https://d.example/", link: "https://a.example", defaultServer: "https://d.example")
                      && E2E.pairServerAutoFill(current: "https://A.example:443", link: "https://a.example", defaultServer: "")
                      && !E2E.pairServerAutoFill(current: "https://mine.example", link: "https://evil.example", defaultServer: "https://d.example"), "")
                let pc = try await retry { try await E2E.createPairCode(apiA, sk: active, supportsKey: true) }
                guard let secret = pc.secret else { check("带钥匙的配对码：返回一次性钥匙", false, ""); throw E2E.Failure(.server, "没有一次性钥匙") }
                let f = try Core.pairFormat(server: sid, code: pc.code, secret: secret)
                let parsed = try Core.pairParse(f.link)
                check("配对链接：解析出 6 位配对码、一次性钥匙和服务器地址", parsed.code == pc.code && parsed.secret == secret
                      && parsed.server.map(E2E.normalizeServer) == E2E.normalizeServer(sid) && f.text.hasPrefix(pc.code + "-"), f.link)
                let (rK, ringK) = try await pairWith(parsed.code, parsed.secret, "扫码设备")
                check("扫码登录：直接解锁，私钥就是账号私钥，并钉住账号公钥", rK.unlocked && rK.note == nil
                      && (try? ringK.accountKeys()) == [skA] && ringK.pinned == stK.activeKey?.pub, rK.note ?? "")
                do {
                    _ = try await pairWith(parsed.code, parsed.secret, "再用一次")
                    check("带钥匙的配对码只能用一次", false, "居然成功了")
                } catch { check("带钥匙的配对码只能用一次（\(err(error))）", (error as? E2E.Failure)?.status == 403, "") }

                // 一次性钥匙不对（别的码的钥匙）：登录成功、没解锁、T82
                let pc2 = try await retry { try await E2E.createPairCode(apiA, sk: active, supportsKey: true) }
                let other = try Core.pairKeyNew(sk: skA).secret
                let (r2, ring2) = try await pairWith(pc2.code, other, "钥匙不对")
                check("一次性钥匙不对：登录成功但不解锁，提示 T82", !r2.unlocked && r2.note == E2E.T.t82 && (try? ring2.accountKeys())?.isEmpty == true, r2.note ?? "")
                // 只输 6 位：照旧锁定，不提示
                let pc3 = try await retry { try await E2E.createPairCode(apiA, sk: active, supportsKey: true) }
                let (r3, _) = try await pairWith(pc3.code, nil, "只输六位")
                check("只输 6 位配对码：登录成功、已锁定、不提示", !r3.unlocked && r3.note == nil && r3.pendingKey == nil, "")
                // 配对码没带钥匙（生成它的设备没解锁 / 旧服务端），新设备却有一次性钥匙：T83
                let pc4 = try await retry { try await E2E.createPairCode(apiA, sk: nil, supportsKey: true) }
                check("本机没解锁时生成的配对码不带钥匙", pc4.secret == nil, "")
                let (r4, _) = try await pairWith(pc4.code, secret, "没带钥匙")
                check("配对码没带钥匙：登录成功、已锁定，提示 T83", !r4.unlocked && r4.note == E2E.T.t83, r4.note ?? "")
            }

            // 3c. agent 双向（docs/agent-mcp.md，服务端 0.10.0）：核对批准 agent 登录、解开 agent 消息、回复、回执
            do {
                struct NewS: Decodable { let session_id: String }
                struct LS: Decodable { let state: String; let challenge: String?; let token: String? }
                struct Pushed: Decodable { let id: Int64 }
                check("回复正文：选项和补充一起发（第一行选项）",
                      Agent.composeReply(choice: "继续", text: "") == "继续" && Agent.composeReply(choice: nil, text: " 你好 ") == "你好"
                      && Agent.composeReply(choice: "继续", text: "先别删") == "继续\n先别删" && Agent.composeReply(choice: nil, text: " \n").isEmpty, "")
                let ak = try JSONDecoder().decode(Agent.NewKey.self, from: try await apiA.call("POST", "/v1/agent/keys")).key
                let apiK = E2E.API(transport(ak))
                let acctPub = try Core.publicKey(skA).pub
                // agent 发起登录（会话钥匙、承诺）
                func agentLogin(_ name: String, account: String) async throws -> (sid: String, sk: String, pub: String, nb: String) {
                    let kp = try Core.keypair()
                    let nb = try Core.random32()
                    let commit = try Core.agentCommit(pub: kp.pub, account: account, nonce: nb, name: name)
                    let r = try JSONDecoder().decode(NewS.self, from: try await apiK.call("POST", "/v1/agent/sessions", body: ["name": name, "pub": kp.pub, "commit": commit]))
                    return (r.session_id, kp.sk, kp.pub, nb)
                }
                let ag = try await agentLogin("自检 agent", account: acctPub)
                guard let req = try await Agent.sessions(apiA).first(where: { $0.id == ag.sid && $0.pending }) else {
                    check("设备看到 agent 的登录请求", false, ""); return nil
                }
                let ap = try await Agent.Approval.begin(apiA, session: req, sk: skA)
                let ph0 = await ap.handle(try await Agent.sessions(apiA), api: apiA)
                check("批准 agent：出 na 后等 agent 揭晓", ph0 == .challenged, "\(ph0)")
                let ls = try JSONDecoder().decode(LS.self, from: try await apiK.call("GET", "/v1/agent/sessions/\(ag.sid)"))
                let agentCode = try Core.agentSAS(pub: ag.pub, account: acctPub, na: ls.challenge ?? "", nb: ag.nb)
                try await apiK.call("POST", "/v1/agent/sessions/\(ag.sid)/reveal", body: ["nonce": ag.nb])
                let ph1 = await ap.handle(try await Agent.sessions(apiA), api: apiA)
                check("批准 agent：两边的核对码一致", ph1 == .code(agentCode), "\(ph1)")
                try await ap.approve(apiA, sk: skA)
                let ls2 = try JSONDecoder().decode(LS.self, from: try await apiK.call("GET", "/v1/agent/sessions/\(ag.sid)"))
                guard ap.phase == .approved, ls2.state == "approved", let stoken = ls2.token else { check("批准后 agent 拿到会话令牌", false, "\(ls2)"); return nil }
                let apiS = E2E.API(transport(stoken))
                var list = try await Agent.sessions(apiA)
                let ver = Agent.verify(list, keys: [try Core.keypair().sk, skA], current: skA)
                check("会话证明能核实，名称取自证明", ver[ag.sid] == Agent.Verified(name: "自检 agent", pub: ag.pub), "\(ver)")
                let oldKey = Agent.verify(list, keys: [skA], current: try Core.keypair().sk)
                check("不是当前钥匙写的证明：只算历史，不能回复", oldKey[ag.sid]?.current == false, "\(oldKey)")

                // agent 用假的账号公钥登录：承诺对不上 → 自动拒绝
                let fake = try await agentLogin("冒充", account: try Core.keypair().pub)
                if let r2 = try await Agent.sessions(apiA).first(where: { $0.id == fake.sid }) {
                    let a2 = try await Agent.Approval.begin(apiA, session: r2, sk: skA)
                    try await apiK.call("POST", "/v1/agent/sessions/\(fake.sid)/reveal", body: ["nonce": fake.nb])
                    let p2 = await a2.handle(try await Agent.sessions(apiA), api: apiA)
                    let st2 = try JSONDecoder().decode(LS.self, from: try await apiK.call("GET", "/v1/agent/sessions/\(fake.sid)")).state
                    check("agent 看到的不是本账号公钥：核对失败并自动拒绝", p2 == .failed(Agent.T.commitMismatch) && st2 == "denied", "\(p2) \(st2)")
                }

                // agent 发提问 → 设备解开（快捷回复里超过 20 字的丢掉）
                let payload = #"{"v":1,"kind":"message","text":"继续吗？","desp":"**3** 个样本","ask":true,"choices":["继续","停","这一项超过二十个字的选项应该被丢掉才对啊啊"],"seq":1,"sent_at":1}"#
                let env = try Core.agentSeal(account: acctPub, sk: ag.sk, sessionID: ag.sid, payload: payload)
                let mid = try JSONDecoder().decode(Pushed.self, from: try await apiS.call("POST", "/v1/agent/push", body: ["e2e": env, "priority": 4, "ask": true])).id
                guard let m = try await messages(apiA, since: mid - 1).first(where: { ($0["id"] as? NSNumber)?.int64Value == mid }) else {
                    check("设备收到 agent 消息", false, ""); return nil
                }
                check("agent 消息带 agent_session、ask，正文不是明文", m["agent_session"] as? String == ag.sid && m["ask"] as? Bool == true
                      && (m["e2e"] as? String)?.hasPrefix("hje2.") == true && !"\(m)".contains("继续吗"), "")
                let o = Agent.open(envelope: m["e2e"] as? String ?? "", sessionID: ag.sid, keys: [skA], verified: ver)
                if case .ok(let x) = o {
                    check("解开 agent 消息：标题、正文、快捷回复、名称、seq", x.text == "继续吗？" && x.ask && x.choices == ["继续", "停"]
                          && x.agentName == "自检 agent" && x.doc != nil && x.agentSeq == 1, "\(x)")
                } else { check("解开 agent 消息", false, "\(o)") }
                check("会话没核实：来源无法核实", Agent.open(envelope: m["e2e"] as? String ?? "", sessionID: ag.sid, keys: [skA], verified: [:]) == .unverified, "")
                check("换成别的会话公钥：解不开", Agent.open(envelope: m["e2e"] as? String ?? "", sessionID: ag.sid, keys: [skA],
                                                           verified: [ag.sid: .init(name: "x", pub: fake.pub)]) == .broken, "")

                // 设备回复 → agent 解开、发回执 → 设备核对回执显示 ✓✓
                guard let v = ver[ag.sid] else { return nil }
                let rid = try await Agent.reply(apiA, msgID: mid, seq: 1, sessionID: ag.sid, verified: v, sk: skA, text: "继续", device: "设备 A")
                var views = try await Agent.replies(apiA, msgID: mid, sessionID: ag.sid, keys: [skA], verified: v)
                check("回复后显示「已发出」", views.map(\.text) == ["继续"] && views.first?.state == .sent, "\(views)")
                let fd = try await apiS.call("GET", "/v1/agent/replies", query: [URLQueryItem(name: "wait", value: "0")])
                let got = ((try JSONSerialization.jsonObject(with: fd) as? [String: Any])?["replies"] as? [[String: Any]]) ?? []
                guard let g = got.first, let renv = g["e2e"] as? String else { check("agent 取到回复", false, "\(got)"); return nil }
                let rp = try Core.agentReplyOpen(sk: ag.sk, account: acctPub, envelope: renv, msgID: mid)
                check("agent 解开回复（发送方核对为账号公钥，带被回复消息的 seq）", rp["text"] as? String == "继续" && rp["device"] as? String == "设备 A"
                      && (rp["re_seq"] as? NSNumber)?.int64Value == 1, "\(rp)")
                let receipt = #"{"v":1,"kind":"receipt","reply_id":\#(rid),"n":"\#(rp["n"] as? String ?? "")","received_at":2}"#
                try await apiS.call("POST", "/v1/agent/replies/ack", body: ["receipts": [["reply_id": rid, "e2e": try Core.agentSeal(account: acctPub, sk: ag.sk, sessionID: ag.sid, payload: receipt)]]])
                views = try await Agent.replies(apiA, msgID: mid, sessionID: ag.sid, keys: [skA], verified: v)
                check("回执核对通过：✓✓ agent 已收到", views.first?.state == .received && views.first?.receivedAt != nil, "\(views)")
                // 回执里的 n 对不上（服务器拿别的回执冒充）：不显示已收到
                let bad = Agent.replyViews(try JSONDecoder().decode([Agent.ReplyStatus].self, from: JSONSerialization.data(withJSONObject: [[
                    "reply_id": rid + 1, "session_id": ag.sid, "state": "received",
                    "copy": try Core.agentReplySeal(sk: skA, sessionPub: ag.pub, sessionID: ag.sid, msgID: mid, payload: #"{"v":1,"text":"x","n":"AAAAAAAAAAAAAAAAAAAAAA","sent_at":1}"#).copy,
                    "receipt": try Core.agentSeal(account: acctPub, sk: ag.sk, sessionID: ag.sid, payload: receipt)]])), sessionID: ag.sid, keys: [skA], verified: v)
                check("回执对不上这条回复：仍显示「已发出」", bad.first?.state == .sent, "\(bad)")

                // 结束会话：不能再回复（409 → 文字说明）
                try await Agent.end(apiA, sessionID: ag.sid)
                list = try await Agent.sessions(apiA)
                do {
                    try await Agent.reply(apiA, msgID: mid, seq: 1, sessionID: ag.sid, verified: v, sk: skA, text: "再回", device: "设备 A")
                    check("会话结束后不能回复", false, "")
                } catch { check("会话结束后不能回复（\(err(error))）", err(error) == Agent.T.ended, "") }
                check("结束后会话状态为 ended", list.first { $0.id == ag.sid }?.state == "ended", "")
            }

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

            // 9.（0.9.0 起取消「只接受加密消息」：普通 pushkey 的消息一律由服务器代加密）

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

            // 12.（0.9.0 起取消「删除服务器上的明文消息」：服务器上已经没有明文）

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
