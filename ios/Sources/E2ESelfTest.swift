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

        // 开启加密时响应丢失（§4.1 第 4 步）：重新读取状态，确认已开启就照常显示恢复码
        do {
            var setupPub = ""
            var stateFails = true
            let mock = MockTransport { _, path, body -> (Int, Any) in
                switch path {
                case "/v1/prelogin": return (200, good)
                case "/v1/e2e/setup":
                    setupPub = body["pub"] as? String ?? ""
                    return (502, "bad gateway")
                case "/v1/e2e":
                    if stateFails { return (500, ["error": "暂时不可用"]) }
                    var x = E2E.State()
                    x.enabled = true
                    x.keys = [E2E.Key(kid: "k", pub: setupPub, active: true)]
                    return (200, (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(x))) ?? [:])
                default: return (500, ["error": "x"])
                }
            }
            let suite = "io.github.hongyile.huijian.e2e-selftest-setup"
            UserDefaults().removePersistentDomain(forName: suite)
            let ring = E2E.KeyRing(secrets: E2E.MemorySecrets(), scope: "test#2", defaults: UserDefaults(suiteName: suite)!)
            var pending: E2E.SetupAttempt?
            do {
                _ = try await E2E.setup(E2E.API(mock), ring: ring, server: server, username: "u", currentPassword: "old",
                                        newPassword: "Tq7#mZ2!pL9x-new", marks: marks)
                check("开启加密响应丢失、状态也取不到", false, "居然成功了")
            } catch let p as E2E.SetupPending {
                pending = p.attempt
                check("响应丢失、状态也取不到：钥匙和恢复码留在内存里，提示稍后重试", ((try? ring.accountKeys()) ?? []).count == 1 && p.attempt.pub == setupPub, "")
            }
            stateFails = false
            let code = try await E2E.setup(E2E.API(mock), ring: ring, server: server, username: "u", currentPassword: "old",
                                           newPassword: "Tq7#mZ2!pL9x-new", marks: marks, previous: pending)
            check("重试时先核对：服务端其实已开启（公钥就是这次的），照常显示同一个恢复码并钉住公钥",
                  code == pending?.code && ring.pinned == setupPub && mock.calls.filter { $0.path == "/v1/e2e/setup" }.count == 1, "")
        } catch {
            check("开启加密响应丢失用例", false, "\(error)")
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
            guard let em = msgs.first(where: { ($0["e2e"] as? String)?.isEmpty == false }),
                  let pm = msgs.first(where: { $0["e2e"] == nil && $0["text"] as? String == "加密 exp44" }) else {
                check("收到加密和明文两条消息", false, "\(msgs.count) 条"); return nil
            }
            let eAtts = (em["attachments"] as? [[String: Any]]) ?? [], pAtts = (pm["attachments"] as? [[String: Any]]) ?? []
            check("服务端只有密文：type=e2e，附件名是占位的", em["type"] as? String == "e2e" && (eAtts.first?["name"] as? String) == "encrypted-1.bin"
                  && (em["desp"] as? String ?? "").isEmpty, "")
            let eIDs = eAtts.compactMap { $0["id"] as? String }, pIDs = pAtts.compactMap { $0["id"] as? String }
            guard case .ok(let o) = E2E.open(envelope: em["e2e"] as! String, keys: try ringA.accountKeys(), serverAttachments: eIDs) else {
                check("解开收到的加密消息", false, ""); return nil
            }
            check("解密后的标题、正文、附件名与明文消息一致",
                  o.text == pm["text"] as? String && o.desp == pm["desp"] as? String && o.atts.map(\.name) == pAtts.compactMap { $0["name"] as? String }
                  && o.atts.first?.size == (pAtts.first?["size"] as? NSNumber)?.int64Value, "")
            let serverDoc = try JSONSerialization.data(withJSONObject: pm["doc"] ?? [:])
            var normalized = String(decoding: serverDoc, as: UTF8.self)
            for (p, e) in zip(pIDs, eIDs) { normalized = normalized.replacingOccurrences(of: p, with: e) }
            check("本地解析的 doc、preview 与服务端解析的明文消息一致",
                  canonical(o.doc ?? Data()) == canonical(Data(normalized.utf8)) && o.preview == pm["preview"] as? String, "")
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
            let code2 = try await E2E.rotateRecovery(apiA, sk: skA, server: sid, username: username, password: newPW, marks: marks)
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
            check("删除明文消息 \(n) 条，加密消息保留", n >= 1 && !left.isEmpty && left.allSatisfy { ($0["e2e"] as? String)?.isEmpty == false }, "")
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
