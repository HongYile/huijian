import CryptoKit
import SwiftUI
import UIKit
import UserNotifications

/// 应用内自检（-selfTest YES）：纯逻辑测试 + 连本地 hub 的集成测试，结果打印到控制台并写入 Documents/selftest.txt，跑完退出。
/// 集成部分需要 -demoServer / -demoUser / -demoPass；可选 -demoBarkURL（本机接收 Bark 请求的小服务器）。
struct SelfTestView: View {
    @EnvironmentObject private var model: AppModel
    @State private var lines: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in Text(l).font(.caption.monospaced()) }
            }
            .padding()
        }
        .task {
            let r = SelfTest(model: model) { line in lines.append(line) }
            let ok = await r.run()
            exit(ok ? 0 : 1)
        }
    }
}

@MainActor
final class SelfTest {
    let model: AppModel
    let emit: (String) -> Void
    private var pass = 0
    private var fail = 0
    private var log = ""

    init(model: AppModel, emit: @escaping (String) -> Void) {
        self.model = model
        self.emit = emit
    }

    private func out(_ s: String) {
        print(s)
        fflush(stdout)
        log += s + "\n"
        emit(s)
    }

    private func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
        if cond { pass += 1; out("✅ \(name)") } else { fail += 1; out("❌ \(name)  \(detail())") }
    }

    func run() async -> Bool {
        model.skipNotifyPermission = true
        out("回笺 iOS 自检 \(AppInfo.clientLabel)")
        unitTests()
        updateVerifyUnitTests()
        await MDSelfTest.runAsync { check($0, $1, $2) }
        // 端到端加密（离线部分：参数核对、防降级、状态、§4.5、消息与附件解密、核对失败自动拒绝；和 Mac 共用 E2ESelfTest.swift）
        out("— 端到端加密（离线）")
        await E2ESelfTest.offline { check($0, $1, $2) }
        if Demo.server != nil { await integration() }
        out("SELFTEST \(fail == 0 ? "PASS" : "FAIL") \(pass)/\(pass + fail)")
        let f = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("selftest.txt")
        try? log.write(to: f, atomically: true, encoding: .utf8)
        return fail == 0
    }

    // MARK: 纯逻辑

    private func unitTests() {
        // Markdown
        let blocks = parseMarkdownBlocks("## 结果\n- a\n- b\n\n1. x\n2. y\n\n> 引用\n\n```python\nprint(1)\n```\n\n---\n普通段落")
        check("Markdown 块级解析", blocks == [.heading(2, "结果"), .bullet(["a", "b"]), .ordered(["x", "y"]), .quote("引用"),
                                         .code("python", "print(1)"), .rule, .paragraph("普通段落")], "\(blocks)")
        let a = renderInline("[a](javascript:alert(1)) [b](https://x.com) [c](mailto:a@b.c) [d](file:///etc/passwd) [e](huijian://message/1) [f](tel:123)")
        let links = a.runs.compactMap { $0.link?.absoluteString }
        check("链接只放行 http/https/mailto", links == ["https://x.com", "mailto:a@b.c"], "\(links)")
        check("去掉链接后文字保留", String(a.characters).contains("a b c d e f"), String(a.characters))
        check("plainSummary 去掉标记", plainSummary("## 标题\n- **粗** `代码`") == "标题 粗 代码", plainSummary("## 标题\n- **粗** `代码`"))

        // 回笺 Markdown（服务端 doc）：解码、旧缓存兼容、绘制逻辑、整篇绘制（和 Mac 共用 MDSelfTest.swift）
        MDSelfTest.run({ check($0, $1, $2) }, render: { doc, atts in
            let v = DocView(doc: doc)
                .environment(\.mdActions, MDActions(attachments: atts))
                .environmentObject(model)
                .padding(18)
                .frame(width: 393)
                .background(Theme.bg)
            let r = ImageRenderer(content: v)
            r.scale = 1
            return r.uiImage?.size
        })
        let pm = try? JSONCoding.decoder.decode(Message.self, from: Data(MDSelfTest.message(#","preview":"第一行\n第二行""#).utf8))
        check("列表摘要优先用服务端 preview（压成一行）", pm.map { messageSummary($0) } == "第一行 第二行", pm.map { messageSummary($0) } ?? "nil")

        // 服务器地址
        let cases: [(String, String)] = [("push.example.com/", "https://push.example.com"), ("192.168.1.2:8790", "http://192.168.1.2:8790"),
                                         ("localhost:8790", "http://localhost:8790"), (" http://h.local:1/ ", "http://h.local:1"),
                                         ("nas.local", "http://nas.local")]
        for (i, o) in cases { check("地址规范化 \(i)", API.normalize(i) == o, API.normalize(i)) }

        // 设备指纹
        let fp = DeviceFingerprint.value
        let idfv = UIDevice.current.identifierForVendor?.uuidString ?? ""
        let want = SHA256.hash(data: Data("hongyan-ios:\(idfv)".utf8)).map { String(format: "%02x", $0) }.joined()
        check("设备指纹 = sha256(hongyan-ios:IDFV)", fp == want && fp.count == 64 && fp == DeviceFingerprint.value, fp)

        // Bark 密钥
        let k1 = BarkCipherStore.random(32), k2 = BarkCipherStore.random(32), iv = BarkCipherStore.random(16)
        check("Bark Key 32 位字母数字、每次不同", k1.count == 32 && k1 != k2 && k1.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }, k1)
        check("Bark IV 16 位", iv.count == 16 && iv.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }, iv)

        // 本地通知规则
        func msg(_ p: Int, silent: Bool = false) -> Message {
            let j = #"{"id":1,"priority":\#(p),"text":"t","created_at":"2026-11-17T06:32:05Z","silent":\#(silent)}"#
            return try! JSONCoding.decoder.decode(Message.self, from: Data(j.utf8))
        }
        check("通知：P3 没配 Bark → 发", AppModel.shouldNotify(msg(3), barkOn: false, hidden: false))
        check("通知：P5 配了 Bark → 不发", !AppModel.shouldNotify(msg(5), barkOn: true, hidden: false))
        check("通知：P2 → 不发", !AppModel.shouldNotify(msg(2), barkOn: false, hidden: false))
        check("通知：服务端标静默 → 不发", !AppModel.shouldNotify(msg(4, silent: true), barkOn: false, hidden: false))
        check("通知：隐藏频道 → 不发", !AppModel.shouldNotify(msg(5), barkOn: false, hidden: true))

        // 本地通知合并规则（和安卓一致）
        func m(_ id: Int64, _ p: Int) -> Message {
            try! JSONCoding.decoder.decode(Message.self, from: Data(#"{"id":\#(id),"priority":\#(p),"text":"m\#(id)","created_at":"2026-11-17T06:32:05Z"}"#.utf8))
        }
        var plan = Notifier.plan(existing: [], summary: 0, incoming: (1...6).map { m($0, 3) })
        check("通知合并：6 条普通消息各发一条", plan == Notifier.Plan(post: [1, 2, 3, 4, 5, 6]), "\(plan)")
        let six = (1...6).map { (id: Notifier.identifier(Int64($0)), priority: 3) }
        plan = Notifier.plan(existing: six, summary: 0, incoming: [m(7, 4)])
        check("通知合并：第 7 条撤掉 6 条单独通知、合并成「7 条新消息」",
              plan == Notifier.Plan(post: [], remove: six.map(\.id), summary: 7, summaryChanged: true), "\(plan)")
        plan = Notifier.plan(existing: [(id: "msg-9", priority: 5)], summary: 7, incoming: [m(10, 3), m(11, 5), m(12, 4)])
        check("通知合并：汇总还在时新消息并入（累加），P5 仍单独发", plan == Notifier.Plan(post: [11], summary: 9, summaryChanged: true), "\(plan)")
        plan = Notifier.plan(existing: [(id: "msg-1", priority: 3), (id: "msg-2", priority: 5)], summary: 0, incoming: (3...9).map { m($0, 3) })
        check("通知合并：一批里超过上限时这一批也并入汇总，P5 不受影响",
              plan == Notifier.Plan(post: [], remove: ["msg-1"], summary: 8, summaryChanged: true), "\(plan)")

        // 消息模型
        let j = #"{"id":7,"topic":"","priority":4,"text":"","desp":"d","created_at":"2026-11-17T06:32:05.123Z","silent":true,"silent_reason":"key","archive":2,"attachments":[{"id":"a_1","name":"x.png","mime":"image/png","size":3,"sha256":"ab"}]}"#
        if let m = try? JSONCoding.decoder.decode(Message.self, from: Data(j.utf8)),
           let back = try? JSONCoding.decoder.decode(Message.self, from: JSONCoding.encoder.encode(m)) {
            check("消息解析（空 topic → default、无标题用附件名、静默字段）",
                  m.topic == "default" && m.title == "x.png" && m.silent && m.silentReason == "key" && m.archive == 2 && m.attachments[0].isImage)
            check("消息编码再解码一致", back.id == 7 && back.silentReason == "key" && back.attachments == m.attachments && back.archive == 2)
        } else {
            check("消息解析", false, "解码失败")
        }

        // huijian:// 链接
        check("huijian://message/123 → 123", AppModel.messageID(from: URL(string: "huijian://message/123")!) == 123)
        check("huijian://message/abc → nil", AppModel.messageID(from: URL(string: "huijian://message/abc")!) == nil)
        check("https://x/message/1 → nil", AppModel.messageID(from: URL(string: "https://x/message/1")!) == nil)

        // 附件文件名（不能跳出缓存目录）
        let f1 = AppPaths.attachmentFile(Attachment(id: "a_../x", name: "../../etc/passwd", mime: "", size: 0, sha256: ""))
        check("附件路径不能跳出缓存目录", f1.path.hasPrefix(AppPaths.attDir.path + "/") && !f1.path.contains("/../") && f1.lastPathComponent == ".._.._etc_passwd", f1.path)
        check("附件名为 .. 时改用 file", AppPaths.attachmentFile(Attachment(id: "a", name: "..", mime: "", size: 0, sha256: "")).lastPathComponent == "file")

        // 响应检查
        let u = URL(string: "http://x/v1/me")!
        func resp(_ c: Int, _ ct: String = "text/plain") -> HTTPURLResponse {
            HTTPURLResponse(url: u, statusCode: c, httpVersion: nil, headerFields: ["Content-Type": ct])!
        }
        func err(_ r: HTTPURLResponse, _ body: String, authed: Bool = true) -> APIError? {
            do { _ = try API.check(r, Data(body.utf8), authed: authed); return nil } catch { return error as? APIError }
        }
        check("401（已登录请求）→ 登录失效", err(resp(401), "{}") == .unauthorized)
        check("401（登录请求）→ 普通错误", err(resp(401), #"{"error":"x"}"#, authed: false) == .http(401, "x"))
        check("纯文本 404 → 服务端版本较旧", err(resp(404), "404 page not found") == .unsupported)
        check("JSON 404 → 业务错误", err(resp(404, "application/json"), #"{"error":"消息不存在"}"#) == .http(404, "消息不存在"))
        check("Bark 502 显示服务端说明", APIError.http(502, "Bark 返回：invalid key").errorDescription == "Bark 返回：invalid key")

        // sha256
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sha-test")
        try? Data("huijian".utf8).write(to: tmp)
        let attURL = API(server: URL(string: "http://h:1")!, token: nil).request("/v1/att/a b%").url?.absoluteString ?? ""
        check("附件 id 只转义一次（a b% → a%20b%25）", attURL == "http://h:1/v1/att/a%20b%25", attURL)
        let badFile = FileManager.default.temporaryDirectory.appendingPathComponent("bad-messages.json")
        try? Data("{not json".utf8).write(to: badFile)
        var corrupt = false
        do { _ = try Persistence.loadChecked(badFile) } catch { corrupt = true }
        check("消息文件损坏：报错并把坏文件改名留存", corrupt && !FileManager.default.fileExists(atPath: badFile.path)
              && FileManager.default.fileExists(atPath: badFile.deletingPathExtension().appendingPathExtension("bad.json").path))
        check("文件 sha256", (try? API.sha256(of: tmp)) == SHA256.hash(data: Data("huijian".utf8)).map { String(format: "%02x", $0) }.joined())
    }

    // MARK: 应用内更新

    /// 校验逻辑（不联网）：本地生成一把 Ed25519 密钥，签一个假包，再逐项篡改
    private func updateVerifyUnitTests() {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("update-verify-test")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.ipa")
        try? Data("fake ipa \(Date())".utf8).write(to: file)
        let sha = (try? API.sha256(of: file)) ?? ""
        func info(build: Int = 30, version: String = "0.2.1", sha256: String? = nil, notes: String = "说明", sig: String? = nil) -> UpdateInfo {
            let s = sha256 ?? sha
            let signature = sig ?? (try? key.signature(for: UpdatePackage.message(platform: "ios", build: 30, version: "0.2.1", sha256: sha, notes: "说明")))?.base64EncodedString()
            return UpdateInfo(id: 1, version: version, build: build, notes: notes, size: nil, sha256: s, signature: signature, url: "/v1/update/1")
        }
        func reason(_ u: UpdateInfo, pk: String? = nil, platform: String = "ios", current: Int = 29) -> String? {
            do { try UpdatePackage.verify(file: file, info: u, publicKey: pk ?? pub, currentBuild: current, platform: platform); return nil }
            catch { return shortError(error) }
        }
        check("更新包校验：sha256 和签名都对 → 通过", reason(info()) == nil, reason(info()) ?? "")
        check("更新包校验：sha256 不一致 → 拒绝", reason(info(sha256: String(repeating: "0", count: 64)))?.contains("sha256 不一致") == true)
        check("更新包校验：缺 sha256 → 拒绝", reason(info(sha256: "")) != nil)
        check("更新包校验：改了说明 → 签名不符", reason(info(notes: "被改过的说明"))?.contains("签名校验失败") == true)
        check("更新包校验：改了 build（冒充更新的版本）→ 签名不符", reason(info(build: 31))?.contains("签名校验失败") == true)
        check("更新包校验：改了版本号 → 签名不符", reason(info(version: "9.9.9"))?.contains("签名校验失败") == true)
        check("更新包校验：别的平台的签名（mac 包冒充）→ 拒绝", reason(info(), platform: "macos")?.contains("签名校验失败") == true)
        check("更新包校验：别的密钥签的 → 拒绝",
              reason(info(), pk: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())?.contains("签名校验失败") == true)
        check("更新包校验：签名格式不对 → 拒绝", reason(info(sig: "abc"))?.contains("签名格式") == true)
        check("更新包校验：App 没内置公钥 → 拒绝（提示用 GBox 软件源）", reason(info(), pk: "")?.contains("GBox 软件源") == true)
        check("更新包校验：签名是真的、但 build 和当前一样 → 拒绝（防降级）", reason(info(), current: 30)?.contains("不比当前") == true, reason(info(), current: 30) ?? "")
        check("更新包校验：签名是真的、但比当前旧 → 拒绝（防降级）", reason(info(), current: 31)?.contains("不比当前") == true)
        let u = UpdateInfo(id: 3, version: "0.2.1", build: 30, notes: nil, size: nil)
        check("更新包文件名 Huijian-<版本>-<build>.ipa", UpdatePackage.fileName(u) == "Huijian-0.2.1-30.ipa", UpdatePackage.fileName(u))
        let evil = UpdatePackage.fileName(UpdateInfo(id: 3, version: "../../x/0.2", build: 30, notes: nil, size: nil))
        check("更新包文件名去掉路径字符", evil == "Huijian-....x0.2-30.ipa" && !evil.contains("/"), evil)
        check("更新包临时目录在 tmp/huijian-update", UpdatePackage.dir.path.hasSuffix("/huijian-update"))
        // 每次下载一个子目录，只删自己的
        let fm = FileManager.default
        let a = UpdatePackage.newFile(u), b = UpdatePackage.newFile(u)
        for f in [a, b] {
            try? fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("x".utf8).write(to: f)
        }
        UpdatePackage.remove(a)
        check("更新包：每次下载独立子目录，删旧的不影响新的",
              a.deletingLastPathComponent() != b.deletingLastPathComponent()
              && a.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == UpdatePackage.dir.standardizedFileURL
              && !fm.fileExists(atPath: a.deletingLastPathComponent().path) && fm.fileExists(atPath: b.path))
        UpdatePackage.remove(file)   // 不在 huijian-update 下面：不删
        check("更新包：remove 只删 huijian-update 下面的子目录", fm.fileExists(atPath: file.path))
        UpdatePackage.remove(b)
        // API 会话的跳转规则：跨源（协议 / 主机 / 端口）一律拒绝
        let o = { (x: String, y: String) in API.sameOrigin(URL(string: x), URL(string: y)) }
        check("API 跳转：同源放行（含默认端口写法）", o("https://h.example/v1/a", "https://h.example/v1/b")
              && o("https://h.example/a", "https://H.example:443/b") && o("http://10.0.0.2:8080/a", "http://10.0.0.2:8080/b"))
        check("API 跳转：换主机、换端口、换协议都拒绝", !o("https://h.example/a", "https://evil.example/a")
              && !o("http://10.0.0.2:8080/a", "http://10.0.0.2:9090/a") && !o("https://h.example/a", "http://h.example/a")
              && !o("https://h.example/a", "https://h.example.evil.example/a"))
        let r302 = HTTPURLResponse(url: URL(string: "http://h.example/v1/me")!, statusCode: 302, httpVersion: nil,
                                   headerFields: ["Location": "https://h.example/v1/me"])!
        var why = ""
        do { _ = try API.check(r302, Data()) } catch { why = shortError(error) }
        check("API 跳转：被拒绝的跳转报清楚的错（带目标地址）", why.contains("https://h.example") && why.contains("跳转"), why)
    }

    /// 连本地 hub：下载 selftest.sh 发布的假新版本，校验通过；篡改 sha256 / 说明 / build 后都拒绝且不留文件
    private func updateDownloadTests(_ api: API, want: Int) async {
        guard let u = try? await api.update(build: AppInfo.build) else { check("应用内更新：查询新版本", false, "失败"); return }
        check("应用内更新：服务器上有 build \(want)，带 sha256 / 签名 / 下载地址", u.build == want && u.sha256?.count == 64
              && u.signature?.isEmpty == false && u.url == "/v1/update/\(u.id ?? -1)", "\(u)")
        check("应用内更新：App 内置了更新公钥（构建时 UPDATE_PUBKEY）", !AppInfo.updatePublicKey.isEmpty)
        var steps: [Double] = []
        do {
            let f = try await model.fetchVerifiedUpdate(u) { steps.append($0) }
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            check("应用内更新：下载并校验通过 \(f.lastPathComponent)", f.lastPathComponent == "Huijian-\(u.version)-\(u.build).ipa"
                  && f.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == UpdatePackage.dir.standardizedFileURL
                  && size == u.size, "\(f.path) \(size ?? -1)")
            try? await Task.sleep(nanoseconds: 200_000_000)
            check("应用内更新：报告了下载进度（最后是 100%）", steps.last == 1, "\(steps.suffix(3))")
            UpdatePackage.remove(f)
        } catch {
            check("应用内更新：下载并校验", false, shortError(error))
        }
        // 防降级：服务器给的 build 不比当前新，不下载
        do {
            _ = try await model.fetchVerifiedUpdate(UpdateInfo(id: u.id, version: u.version, build: AppInfo.build, notes: u.notes, size: u.size,
                                                               sha256: u.sha256, signature: u.signature, url: u.url))
            check("应用内更新：build 不比当前新 → 拒绝（防降级）", false, "竟然通过")
        } catch {
            check("应用内更新：build 不比当前新 → 拒绝（防降级）", shortError(error).contains("不比当前"), shortError(error))
        }
        // 下载中途重新登录 / 退出：取消下载、回到初始状态，不留文件
        await model.checkUpdate()
        if model.update?.build == u.build {
            model.downloadUpdate()
            let started = model.updateDownload == .downloading(0)
            model.resetUpdateDownload()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let left = (try? FileManager.default.contentsOfDirectory(atPath: UpdatePackage.dir.path)) ?? []
            check("应用内更新：下载中途重置 → 取消，状态回到初始，不留文件", started && model.updateDownload == .idle && left.isEmpty,
                  "\(model.updateDownload) 剩下 \(left)")
        } else {
            check("应用内更新：查到新版本（用于取消测试）", false, "\(String(describing: model.update))")
        }
        func rejected(_ bad: UpdateInfo, _ word: String) async -> (Bool, String) {
            do { _ = try await model.fetchVerifiedUpdate(bad); return (false, "竟然通过") } catch {
                let left = (try? FileManager.default.contentsOfDirectory(atPath: UpdatePackage.dir.path)) ?? []
                return (shortError(error).contains(word) && left.isEmpty, shortError(error) + " 剩下 \(left)")
            }
        }
        var badSha = u
        badSha.sha256 = String(repeating: "a", count: 64)
        var r = await rejected(badSha, "sha256 不一致")
        check("应用内更新：sha256 对不上 → 拒绝，不留文件", r.0, r.1)
        r = await rejected(UpdateInfo(id: u.id, version: u.version, build: u.build, notes: "被改过的说明", size: u.size,
                                      sha256: u.sha256, signature: u.signature, url: u.url), "签名校验失败")
        check("应用内更新：说明被改 → 签名不符，拒绝，不留文件", r.0, r.1)
        r = await rejected(UpdateInfo(id: u.id, version: u.version, build: u.build + 100, notes: u.notes, size: u.size,
                                      sha256: u.sha256, signature: u.signature, url: u.url), "签名校验失败")
        check("应用内更新：build 被改 → 签名不符，拒绝，不留文件", r.0, r.1)
        UpdatePackage.clear()
    }

    // MARK: 管理

    private func manageTests(_ api: API, server: String, user: String, pass: String) async {
        out("— 管理：pushkey、账户、频道、注册")
        // 规则（Mac 上的 mgmtcheck 测得更全，这里确认 App 里用的是同一套）
        check("管理规则：自定义 key 16–64 位、随机 key 合规、用户名和密码规则",
              ManageRules.keyProblem("short") != nil && ManageRules.keyProblem(ManageRules.randomKey()) == nil
              && ManageRules.usernameProblem("demo user") == nil && ManageRules.usernameProblem("bad!") != nil
              && ManageRules.passwordProblem("1234567") != nil)
        await model.refreshAccount()
        check("管理：/v1/me 的 can_admin（本机没有管理权限）和账号有密码", model.canAdmin == false && model.accountHasPassword == true,
              "\(String(describing: model.canAdmin)) \(String(describing: model.accountHasPassword))")
        check("管理：服务端功能清单里有 keys / account / channels / pair.status",
              ["keys", "account", "channels", "pair.status"].allSatisfy { model.supports($0) == true })

        // pushkey：自定义 key 新建 → 用它给自己发测试消息 → 吊销 → 删除
        do {
            let custom = "ios_selftest_" + String(ManageRules.randomKey().dropFirst(3).prefix(12)).replacingOccurrences(of: "-", with: "x")
            let k = try await api.createKey(name: "自检 key", key: custom)
            try await model.sendTestPush(with: k)
            try await model.catchUp(api, model.session)
            let got = model.messages.last { $0.desp.contains("用 pushkey「自检 key」") }
            check("管理：新建自定义 key，用它给自己发测试消息并收到", k.key == custom && got != nil)
            let r = try await api.revokeKey(id: k.id)
            try await api.deleteKey(id: k.id)
            let left = try await api.keys()
            check("管理：吊销、删除这把 key", r.isRevoked && !left.contains { $0.id == k.id })
        } catch { check("管理：pushkey", false, shortError(error)) }

        // 账户：当前密码不对 → 服务端说明，用户名不变；没有管理权限不能移除有管理权限的设备
        // 登录时账号已自动升级到新登录协议：改用户名用当前密码派生的凭证核对，服务端 403 显示 T3
        do {
            _ = try await model.changeCredentials(username: user + "x", password: "", current: pass + "wrong")
            check("管理：当前密码不对应失败", false)
        } catch {
            check("管理：当前密码不对 → 「\(shortError(error))」，用户名不变",
                  [E2E.T.t3, "当前密码不对"].contains(shortError(error)) && model.settings.username == user)
        }
        do {
            let d = try await api.account()
            check("管理：设备列表标出本机", d.devices.contains { $0.current && $0.id == model.settings.deviceID })
            if let mac = d.devices.first(where: { $0.name == "我的 MacBook" && !$0.revoked }) {
                do { try await api.revokeDevice(mac.id); check("管理：移除有管理权限的设备应失败", false) }
                catch { check("管理：没有管理权限不能移除有管理权限的设备 → 服务端说明", shortError(error).contains("管理权限"), shortError(error)) }
            }
            let pc = try await api.createPairCode()
            let st = try await api.pairCodeStatus(pc.code)
            check("管理：生成配对码（3 分钟）并能查状态", pc.code.count == 6 && st.state == "waiting")
        } catch { check("管理：账户", false, shortError(error)) }

        // 频道：改名、排序、删除（先改本地，服务端确认后保留）
        do {
            try await model.updateChannel("crawler", alias: "采集")
            check("管理：频道改名 → 列表用显示名", model.channelName("crawler") == "采集")
            try await model.setChannelOrder(["crawler", "report"])
            let order = model.allTopics.filter { !model.channel($0).hidden }
            check("管理：频道排序（置顶的 train 仍在最前，然后是 crawler、report）", Array(order.prefix(3)) == ["train", "crawler", "report"], "\(order)")
            try await model.setChannelOrder([])
            try await model.updateChannel("crawler", alias: "")
            check("管理：恢复按最近活跃排序、恢复原名", !model.hasManualChannelOrder && model.channelName("crawler") == "crawler")
            let k = try await api.createKey(name: "自检频道", key: "")
            try await api.push(pushkey: k.key, text: "要删除的频道", desp: "", priority: 3, topic: "selftest-del")
            try await model.catchUp(api, model.session)
            let had = model.messages.contains { $0.topic == "selftest-del" }
            let n = try await model.deleteChannel("selftest-del")
            check("管理：删除频道 → 服务器删除 \(n) 条，本机也清掉", had && n == 1 && !model.messages.contains { $0.topic == "selftest-del" })
            _ = try await api.revokeKey(id: k.id)
        } catch { check("管理：频道", false, shortError(error)) }

        // 注册：服务端没开放时显示服务端说明，本机登录状态不变
        do {
            // 注册的密码强度在本机检查（新登录协议），这里用一个合格的密码，看服务端的说明
            try await model.register(server: server, username: "selftest-new", password: "Selftest-Register-Strong-9", name: "x")
            check("管理：没开放注册应失败", false)
        } catch {
            check("管理：没开放注册 → 服务端说明，仍保持登录（\(shortError(error))）", shortError(error).contains("没有开放注册") && model.loggedIn)
        }
        let info = try? await api.info()
        check("管理：/v1/info 带 register_open", info?.register_open == false)

        // 设置实时同步（服务端 0.6.1 起）：keys / devices / account 变更 → 后台重新拉取，连续多条合并成一次；不认识的 kind 忽略
        out("— 设置实时同步")
        check("设置同步：服务端功能 sync.settings", model.supports("sync.settings") == true)
        let mk = { (k: String) in MsgChange(seq: nil, id: 0, kind: k, state: nil) }
        do {
            let fresh = try await api.createKey(name: "别处新建的 key", key: "")
            _ = try await api.renameMe("自检 iPhone 改名")
            let before = model.settingsRefreshCount
            let changed = model.applyChanges([mk("keys"), mk("keys"), mk("devices"), mk("account"), mk("future-kind")])
            for _ in 0..<30 where model.settingsRefreshCount.account == before.account { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            check("设置同步：keys×2、devices、account 合并成一次 key 刷新和一次账户刷新",
                  !changed && model.settingsRefreshCount.keys == before.keys + 1 && model.settingsRefreshCount.account == before.account + 1,
                  "\(before) → \(model.settingsRefreshCount)")
            check("设置同步：重新拉取后 key 列表里有别处新建的 key", model.keys?.contains { $0.id == fresh.id } == true)
            check("设置同步：设备列表和本机名称更新（\(model.settings.deviceName)）",
                  model.accountDetail?.devices.contains { $0.current && $0.name == "自检 iPhone 改名" } == true
                  && model.settings.deviceName == "自检 iPhone 改名" && model.conn != .unauthorized)
            let b2 = model.settingsRefreshCount
            let c2 = model.applyChanges([mk("future-kind"), mk("another")])
            try? await Task.sleep(nanoseconds: 600_000_000)
            check("设置同步：不认识的 kind 忽略", !c2 && model.settingsRefreshCount == b2)
            _ = try await api.revokeKey(id: fresh.id)
            try await api.deleteKey(id: fresh.id)
            _ = try await api.renameMe("自检 iPhone")
        } catch { check("设置同步", false, shortError(error)) }
        // 本机被移除：设备列表里没有本机（或标为已移除）→ 按登录失效处理
        let j = #"{"account":{"id":1,"username":"me","has_password":true},"devices":[{"id":"d_me","revoked":true},{"id":"d_other"}],"register_open":false}"#
        if let d = try? JSONCoding.decoder.decode(AccountDetail.self, from: Data(j.utf8)) {
            check("设置同步：本机被移除的判断", AppModel.selfRemoved(d, deviceID: "d_me") && AppModel.selfRemoved(d, deviceID: "d_x")
                  && !AppModel.selfRemoved(d, deviceID: "d_other"))
        } else { check("设置同步：设备列表解码", false) }
    }

    // MARK: 集成（本地 hub）

    private func integration() async {
        let d = UserDefaults.standard
        guard let server = Demo.server, let user = d.string(forKey: "demoUser"), let pass = d.string(forKey: "demoPass") else { return }
        out("— 集成测试：\(server)")
        if model.loggedIn { model.logout(notifyServer: false) }

        // 错误密码：显示服务端说明，不是「登录已失效」
        do {
            try await model.login(server: server, username: user, password: pass + "x", code: "", usePair: false, name: "自检")
            check("错误密码应失败", false)
        } catch {
            check("错误密码 → 服务端说明", !(shortError(error).contains("登录已失效")) && !model.loggedIn, shortError(error))
        }

        do {
            try await model.login(server: server, username: user, password: pass, code: "", usePair: false, name: "自检 iPhone")
        } catch {
            check("登录", false, shortError(error))
            return
        }
        check("登录成功、token 已保存（\(Keychain.backend(account: "device-token"))）",
              model.loggedIn && model.settings.token != nil && !model.settings.deviceID.isEmpty)
        check("token 存在钥匙串里（不是退路文件）", Keychain.backend(account: "device-token") == "钥匙串", Keychain.backend(account: "device-token"))
        guard var api = model.api() else { return }
        var token = model.settings.token ?? ""

        // ATS：http://域名 不能被拦（-1022）。.invalid 域名解析必然失败，只看错误是不是 ATS
        do {
            _ = try await API(server: URL(string: "http://huijian-ats-check.invalid:8790")!, token: nil).info()
            check("ATS：http 域名", false, "不应成功")
        } catch {
            let code = (error as? URLError)?.code
            check("ATS：http://域名 放行（错误是 \(code.map { "\($0.rawValue)" } ?? "\(error)")，不是 -1022）",
                  code != nil && code != .appTransportSecurityRequiresSecureConnection)
        }
        // 重签换证书后钥匙串读不到：token 从受保护的私有文件读
        Keychain.deleteKeychainOnly(account: "device-token")
        check("钥匙串读不到时 token 从私有文件读（\(Keychain.backend(account: "device-token"))）", model.settings.token == token)
        model.settings.token = token

        // 自检模式下不走前台循环，手动做首次同步
        do { try await model.catchUp(api, model.session) } catch { check("首次同步", false, shortError(error)) }
        await model.refreshAux(api, model.session, force: true)
        let first = model.messages
        check("首次同步：最多 50 条且全部已读", !first.isEmpty && first.count <= 50 && first.allSatisfy { model.read.contains($0.id) },
              "\(first.count) 条")
        check("首次同步：游标推进、标记完成", model.settings.cursor >= (first.last?.id ?? 1) && model.settings.initialSyncDone)
        let onDisk = Persistence.load()
        check("首次同步：已落盘", onDisk.messages.count == first.count)
        check("登录：旧账号（PBKDF2）登录后自动升级到新登录协议，记下「已升级」",
              E2E.UpgradeMarks(defaults: .standard).isUpgraded(server: model.settings.server, username: user)
              && model.settings.accountID != nil, "accountID=\(String(describing: model.settings.accountID))")
        // §11.1：密码登录后，账号还没开启加密时在后台自动开启（不生成恢复码、不弹恢复码页），本机随即解锁
        if model.supports("e2e.auto") == true {
            for _ in 0..<60 where model.e2eStatus != .unlocked { try? await Task.sleep(nanoseconds: 250_000_000) }
            check("登录：自动开启加密并解锁，没有恢复码、不弹恢复码页（T23）",
                  model.e2eStatus == .unlocked && model.e2eRecovery == nil && model.e2eState?.hasRecovery == false
                  && model.e2ePasswordKeys == nil && model.e2eRing?.pinned != nil,
                  "\(String(describing: model.e2eStatus))")
        }
        check("频道显示名（train → 训练）", model.channelName("train") == "训练", model.channelName("train"))
        check("频道设置已落盘（后台冷启动可用）", model.settings.channels.contains { $0.topic == "train" && $0.alias == "训练" }
              && model.settings.channels.contains { $0.topic == "debug" && $0.hidden })
        check("隐藏频道不进收件箱", !model.inbox.contains { $0.topic == "debug" })

        // 服务端 0.6.0 的 doc / preview（tests/hub.sh 发了一条覆盖全部语法的演示消息）
        if let md = model.messages.last(where: { $0.title == "exp43 训练报告" }) {
            let blocks = md.renderDoc?.blocks ?? []
            let types = Set(blocks.map(\.type))
            let want: Set<String> = ["heading", "paragraph", "progress", "table", "image", "callout", "list", "quote", "rule", "code", "file", "footnotes"]
            check("服务端 doc：演示消息按 doc 绘制（\(blocks.count) 块、\(types.count) 种）", want.isSubset(of: types), "\(types)")
            check("doc 里的块都认识", blocks.allSatisfy(\.known), "\(types)")
            let ids = Set(md.attachments.map(\.id))
            let refs = blocks.compactMap(\.att)
            check("正文引用的附件（图片、PDF）都在这条消息的附件里", refs.count >= 2 && refs.allSatisfy { ids.contains($0) }, "\(refs)")
            check("外部图片保留 src（默认不加载）", blocks.contains { $0.type == "image" && $0.src?.hasPrefix("https://") == true })
            check("huijian://message 链接指向 exp42 完成", blocks.flatMap { $0.runs ?? [] }.contains {
                $0.href.flatMap { URL(string: $0) }.flatMap(MDLogic.messageID).flatMap { model.message($0) }?.title == "exp42 完成" })
            check("列表摘要用服务端 preview", !md.preview.isEmpty && PreviewCache.summary(md).hasPrefix("结论：val_loss"), PreviewCache.summary(md))
            check("doc / preview 已存进本地缓存", Persistence.load().messages.first { $0.id == md.id }.map { $0.doc == md.doc && $0.preview == md.preview } == true)
            let e42 = model.messages.last { $0.title == "exp42 完成" }?.id ?? 0
            model.path = [.message(md.id)]
            model.openMessage(e42, push: true)
            check("正文里点 huijian://message/<id>：在当前页上打开（返回回到原消息）", model.path == [.message(md.id), .message(e42)], "\(model.path)")
            model.openMessage(e42)
            check("通知 / 深链打开：替换导航栈", model.path == [.message(e42)], "\(model.path)")
            model.path = []
        } else {
            check("演示消息 exp43 训练报告", false, "首次同步里没有")
        }

        // 测试推送 + 补拉：新消息未读、先落盘再推进游标
        let before = model.settings.cursor
        do {
            try await model.sendTestPush()
            try await model.catchUp(api, model.session)
            let t = model.messages.last
            check("测试推送 → 补拉到新消息（P4 未读）", t?.title.hasPrefix("测试推送") == true && t?.priority == 4 && model.isUnread(t!), t?.title ?? "无")
            check("游标推进", model.settings.cursor > before)
            check("新消息已落盘", Persistence.load().messages.last?.id == t?.id)
        } catch { check("测试推送", false, shortError(error)) }

        // 长轮询：挂起等待，新消息到了立即返回
        do {
            let since = model.settings.cursor
            let start = Date()
            async let page = api.messages(since: since, limit: 200, wait: 20)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            try await model.sendTestPush()
            let p = try await page
            let dt = Date().timeIntervalSince(start)
            check("长轮询：新消息到达即返回（\(String(format: "%.1f", dt)) 秒）", p.messages.count == 1 && dt < 6, "\(p.messages.count) 条，\(dt) 秒")
        } catch { check("长轮询", false, shortError(error)) }

        // 长轮询超时：没有消息时等到 wait 秒后返回空列表
        do {
            try await model.catchUp(api, model.session)
            let start = Date()
            let p = try await api.messages(since: model.settings.cursor, limit: 200, wait: 2)
            let dt = Date().timeIntervalSince(start)
            check("长轮询：没有消息时等待后返回空", p.messages.isEmpty && dt >= 1.5, "\(p.messages.count) 条，\(dt) 秒")
        } catch { check("长轮询超时", false, shortError(error)) }

        // 附件下载 + sha256 校验
        if let m = model.messages.last(where: { $0.attachments.contains { $0.isImage } }), let idx = m.attachments.firstIndex(where: \.isImage) {
            let a = m.attachments[idx]
            await model.download(a)
            // 服务端 0.8 登录后自动开启加密，会把演示账号的历史明文补加密、换新的附件 id（§11.5）：旧 id 下载返回 410 sealed，
            // App 重新拉取这条消息，再下载新 id 的同一个附件（解密成原文件）。按「消息 id + 附件序号」找替换后的附件
            let cur = model.message(m.id).flatMap { $0.attachments.indices.contains(idx) ? $0.attachments[idx] : nil } ?? a
            let f = AppPaths.attachmentFile(cur)
            let ok: Bool
            if cur.key != nil {
                // 加密附件：服务端的 sha256 是密文的（下载时已校验），落盘的是解密后的原文件
                ok = model.attState(cur) == .done && FileManager.default.fileExists(atPath: f.path)
            } else {
                ok = model.attState(cur) == .done && (try? API.sha256(of: f)) == cur.sha256.lowercased()
            }
            check("附件下载并校验（\(cur.name)\(cur.id != a.id ? "，补加密后换成新 id 重新下载" : "")）", ok,
                  "\(model.attState(cur))，旧 id \(a.id) → \(cur.id)")
            if cur.id != a.id { check("补加密：旧附件 id 不再记状态（不显示「附件已丢失」）", model.attState(a) == .idle, "\(model.attState(a))") }
            check("图片缩略图可解码", Thumbnail.load(f) != nil)
        } else {
            check("演示数据里有图片附件", false)
        }

        // 端到端加密接到 AppModel 上（内存存储，不碰钥匙串）
        await e2eModelTests()

        // 更新检查（服务端还没有 iOS 版本时返回 null，不报错）
        do {
            let u = try await api.update(build: AppInfo.build)
            check("更新检查（\(u.map { "有新版本 \($0.version)" } ?? "没有新版本")）", true)
        } catch { check("更新检查", false, shortError(error)) }

        // 应用内下载新版 IPA（tests/selftest.sh 用测试密钥发布了一个假的新版本，构建时把测试公钥写进了 App）
        if let want = Int(d.string(forKey: "demoUpdateBuild") ?? "") {
            await updateDownloadTests(api, want: want)
        }

        // Bark
        await barkTests(api)

        // 管理：pushkey、账户、频道、注册（和 Mac 客户端对齐）
        await manageTests(api, server: server, user: user, pass: pass)

        // 写盘失败：消息照常进内存，游标不前进；恢复后补写并推进
        do {
            try await model.catchUp(api, model.session)
            let before = model.settings.cursor
            let file = AppPaths.messagesFile
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)   // 占住文件名，写盘必然失败
            try await model.sendTestPush()
            var failed = false
            do { try await model.catchUp(api, model.session) } catch { failed = true }
            let inMem = model.messages.last?.title.hasPrefix("测试推送") == true && (model.messages.last?.id ?? 0) > before
            check("写盘失败：抛错退避、游标不前进、消息已进内存", failed && model.settings.cursor == before && inMem,
                  "failed=\(failed) cursor \(before)→\(model.settings.cursor)")
            try FileManager.default.removeItem(at: file)
            try await model.catchUp(api, model.session)
            check("写盘恢复后补写并推进游标", model.settings.cursor > before && Persistence.load().messages.last?.id == model.messages.last?.id)
        } catch { check("写盘失败测试", false, shortError(error)) }

        // 多设备同步：删除 / 归档（变更流 + 对账）
        await changesTests(api)

        // 本地通知真实投递（临时授权：不弹框，通知静默进通知中心）
        await notifyDeliveryTests()

        // 后台刷新逻辑
        let ok = await model.backgroundFetch()
        check("后台刷新：补拉一次成功", ok)

        // 无效 token → 登录失效
        do {
            _ = try await API(server: api.server, token: "DT_invalid").messages(since: nil, limit: 1)
            check("无效 token 应 401", false)
        } catch { check("无效 token → 登录失效", (error as? APIError) == .unauthorized, "\(error)") }

        // 一次 401 不算数：状态被判为失效后，下拉刷新先用 /v1/me 复核，成功就恢复
        model._testForceUnauthorized()
        await model.refresh()
        check("登录失效复核：/v1/me 成功 → 恢复（\(model.conn.text)）", model.conn != .unauthorized && model.loggedIn)

        // 对账只删请求前已同步到的消息：模拟一条快照请求期间并发合并进来的新消息（id 大于游标），不能被当成已删除
        do {
            let ghostID = model.settings.cursor + 100_000
            let j = #"{"id":\#(ghostID),"priority":3,"text":"并发合并的新消息","created_at":"2026-11-17T06:32:05Z"}"#
            model.merge([try JSONCoding.decoder.decode(Message.self, from: Data(j.utf8))])
            model.settings.changesCursor = nil
            try await model.catchUp(api, model.session)
            check("对账：游标之后的本地消息不被误删", model.message(ghostID) != nil && model.settings.changesCursor != nil)
            model._testRemove([ghostID])
        } catch { check("对账边界", false, shortError(error)) }

        // 重新登录（登录失效后）：本地消息、已读、游标都保留
        let keep = (model.messages.count, model.read.count, model.settings.cursor)
        model.relogin()
        check("重新登录：回到登录页、数据保留", !model.loggedIn && model.messages.count == keep.0 && model.settings.token == nil)
        do {
            try await model.login(server: server, username: user, password: pass, code: "", usePair: false, name: "自检 iPhone")
            check("重新登录同一服务器同一设备：消息 \(keep.0) 条、已读、游标都保留",
                  model.loggedIn && model.messages.count == keep.0 && model.read.count == keep.1 && model.settings.cursor == keep.2,
                  "\(model.messages.count)/\(model.read.count)/\(model.settings.cursor) vs \(keep)")
        } catch { check("重新登录", false, shortError(error)) }
        if let a = model.api() { api = a }
        token = model.settings.token ?? ""

        // 前台长轮询循环：回到前台 → 连上 → 新消息实时到达 → 切后台 → 循环停止
        model.scenePhaseChanged(.active)
        for _ in 0..<50 where model.conn != .connected { try? await Task.sleep(nanoseconds: 100_000_000) }
        check("前台：循环启动并连上", model.conn == .connected && model.syncRunning, model.conn.text)
        do {
            try await Task.sleep(nanoseconds: 500_000_000)
            let before = model.messages.last?.id ?? 0
            let t0 = Date()
            try await model.sendTestPush()
            for _ in 0..<50 where (model.messages.last?.id ?? 0) == before { try? await Task.sleep(nanoseconds: 100_000_000) }
            let dt = Date().timeIntervalSince(t0)
            check("前台：长轮询实时收到新消息（\(String(format: "%.1f", dt)) 秒）", (model.messages.last?.id ?? 0) > before && dt < 3)
        } catch { check("前台实时接收", false, shortError(error)) }
        // 设置实时同步：别处新建 key → 挂起的长轮询带着 keys 变更返回 → 本机重新拉取
        do {
            let t0 = Date()
            let k = try await api.createKey(name: "长轮询同步测试", key: "")
            for _ in 0..<50 where model.keys?.contains(where: { $0.id == k.id }) != true { try? await Task.sleep(nanoseconds: 100_000_000) }
            let dt = Date().timeIntervalSince(t0)
            check("设置同步：别处新建 key，长轮询收到变更后本机列表更新（\(String(format: "%.1f", dt)) 秒）",
                  model.keys?.contains { $0.id == k.id } == true && dt < 5)
            _ = try await api.revokeKey(id: k.id)
            try await api.deleteKey(id: k.id)
        } catch { check("设置同步：长轮询", false, shortError(error)) }
        model.scenePhaseChanged(.background)
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("切到后台：循环停止、状态为已暂停", !model.syncRunning && model.conn == .paused, model.conn.text)

        if let first = model.messages.first { _ = PreviewCache.summary(first) }
        let firstID = model.messages.first?.id ?? 0
        // 退出登录：清本地数据、通知服务器。退出时有一个大附件正在下载：下载完成后核对会话、删掉文件
        let big = model.messages.flatMap(\.attachments).first { $0.name.hasSuffix(".zip") }
        if let big { Task { await model.download(big) } }
        try? await Task.sleep(nanoseconds: 50_000_000)
        model.logout(notifyServer: true)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        check("退出登录：本地清空", !model.loggedIn && model.messages.isEmpty && model.settings.token == nil
              && !FileManager.default.fileExists(atPath: AppPaths.messagesFile.path) && model.settings.cursor == 0
              && model.settings.changesCursor == nil)
        check("退出登录：列表预览缓存清空（新服务器 id 会重新从 1 开始）", !PreviewCache.cached(firstID))
        check("退出登录：清掉服务端功能清单和版本", model.serverFeatures == nil && model.serverVersion.isEmpty && model.settings.serverFeatures == nil)
        let leftover = (try? FileManager.default.subpathsOfDirectory(atPath: AppPaths.attDir.path)) ?? []
        check("退出登录：附件缓存删除，退出时还在下载的附件也不留下（\(big?.name ?? "无")）",
              big != nil && leftover.isEmpty && model.attState(big!) == .idle, "\(leftover)")
        do {
            _ = try await API(server: api.server, token: token).me()
            check("退出后旧 token 失效", false)
        } catch { check("退出后旧 token 失效", (error as? APIError) == .unauthorized, "\(error)") }

        // 端到端加密联网流程：用 tests/hub.sh 另建的账号（旧方式设置的密码），会改掉它的密码、删掉它服务器上的明文消息，不影响上面的演示账号
        await e2eOnlineTests(server: server)
    }

    // MARK: 端到端加密

    /// 端到端加密接到 AppModel 上：锁定期间收到的消息显示 T60、解锁后自动解开（含附件映射和本地 doc）、写盘读回、
    /// 加密附件解密失败不留文件、删除明文后本机保留、退出登录删除钥匙。钥匙放内存（不碰钥匙串），测完恢复
    private func e2eModelTests() async {
        out("— 端到端加密：接到 AppModel 上")
        guard model.settings.accountID != nil else { check("端到端加密：取到账号 id", false, "/v1/me 没有账号 id"); return }
        let savedSecrets = model.e2eSecrets
        // 登录时账号可能已经自动开启了加密（§11.1）并钉住了真实公钥：先记下、清掉（这里要测「从没钉住过」），结束后原样恢复
        let pinsKey = "huijian.e2e.pinned"
        let pinScope = model.e2eRing?.scope
        let savedPin = model.e2eRing?.pinned
        func setPin(_ pub: String?) {
            guard let pinScope else { return }
            var pins = (UserDefaults.standard.dictionary(forKey: pinsKey) as? [String: String]) ?? [:]
            pins[pinScope] = pub
            UserDefaults.standard.set(pins, forKey: pinsKey)
        }
        setPin(nil)
        model.e2eSecrets = E2E.MemorySecrets()
        let base = model.settings.cursor + 300_000
        let ids = [base + 1, base + 2, base + 4, base + 5]
        do {
            model.loadE2EKeys()
            let kp = try Core.keypair()
            var st = E2E.State()
            st.enabled = true
            st.auth_key = true
            st.has_password_wrap = true
            st.keys = [E2E.Key(kid: kp.kid, pub: kp.pub, active: true)]
            model.e2eState = st
            check("账号已开启加密、本机没有私钥：已锁定（列表顶部显示 T10）", model.e2eLocked && model.e2eAccountEnabled)
            let fileKey = try Core.random32()
            let env = try E2ESelfTest.sealPayload(pub: kp.pub, text: "加密标题", desp: "**正文** ![图](attachment:曲线.png)",
                                                  atts: [["name": "曲线.png", "mime": "image/png", "size": 321, "key": fileKey]])
            // withAttachment：服务端是否带一个附件（密文）。载荷里的附件数必须和它一致，否则按已损坏处理（T62）
            func msg(_ id: Int64, _ env: String, withAttachment: Bool = true) throws -> Message {
                let atts = withAttachment
                    ? #"[{"id": "a_e2e_\#(id)", "name": "encrypted-1.bin", "mime": "application/octet-stream", "size": 400, "sha256": "ab"}]"#
                    : "[]"
                let json = """
                {"id": \(id), "topic": "e2e", "priority": 4, "type": "e2e", "text": "🔒 加密消息（请把回笺更新到最新版查看）", "desp": "",
                 "created_at": "2026-11-19T08:00:00Z", "e2e": "\(env)", "attachments": \(atts)}
                """
                return try JSONCoding.decoder.decode(Message.self, from: Data(json.utf8))
            }
            let m1 = try msg(ids[0], env)
            check("解码服务端的加密消息：保留信封 e2e", m1.isE2E && m1.e2eStatus == nil)
            // §11.5 服务器代加密：sealed "server" 识别出来（详情页显示 T64）；发送端加密的没有这个字段
            let sealedJSON = #"{"id": 1, "type": "e2e", "text": "x", "e2e": "hje1.x", "sealed": "server", "created_at": "2026-11-20T08:00:00Z"}"#
            let sm = try JSONCoding.decoder.decode(Message.self, from: Data(sealedJSON.utf8))
            check("服务器代加密的消息：sealed == server", sm.isServerSealed && !m1.isServerSealed)
            check("写盘读回仍是服务器代加密", (try? JSONCoding.decoder.decode(Message.self, from: JSONCoding.encoder.encode(sm)))?.isServerSealed == true)
            // 附件 410：reason sealed → 重新拉消息；missing 或没有 reason → 附件丢失
            // 补加密重新拉取（审查 M2）：只接受「本地明文 → 服务器代加密的同一条」，不能改写发送端加密的或换成别的 id
            let plainOld = try JSONCoding.decoder.decode(Message.self, from: Data(#"{"id": 1, "text": "明文", "created_at": "2026-11-20T08:00:00Z"}"#.utf8))
            let notSealed = try JSONCoding.decoder.decode(Message.self, from: Data(#"{"id": 1, "type": "e2e", "e2e": "hje1.x", "created_at": "2026-11-20T08:00:00Z"}"#.utf8))
            let otherID = try JSONCoding.decoder.decode(Message.self, from: Data(#"{"id": 2, "type": "e2e", "e2e": "hje1.x", "sealed": "server", "created_at": "2026-11-20T08:00:00Z"}"#.utf8))
            check("补加密替换：明文 → 服务器代加密，接受", AppModel.acceptsSealedReplacement(old: plainOld, fresh: sm, id: 1))
            check("补加密替换：发送端加密的不能被改写、新记录不是代加密的不接受、id 对不上不接受",
                  !AppModel.acceptsSealedReplacement(old: sm, fresh: sm, id: 1)
                  && !AppModel.acceptsSealedReplacement(old: plainOld, fresh: notSealed, id: 1)
                  && !AppModel.acceptsSealedReplacement(old: plainOld, fresh: otherID, id: 1)
                  && !AppModel.acceptsSealedReplacement(old: plainOld, fresh: plainOld, id: 1))
            check("附件 410 sealed：重新拉取这条消息",
                  AttachmentSealed.parse(status: 410, body: Data(#"{"code":410,"error":"附件已加密，请刷新消息","reason":"sealed","message_id":42}"#.utf8))
                      == AttachmentSealed(messageID: 42))
            check("附件 410 missing / 其他状态：不是补加密",
                  AttachmentSealed.parse(status: 410, body: Data(#"{"code":410,"error":"附件文件已丢失","reason":"missing"}"#.utf8)) == nil
                  && AttachmentSealed.parse(status: 404, body: Data(#"{"reason":"sealed"}"#.utf8)) == nil)
            model.merge(await model.prepareE2E([m1]))
            var got = model.message(ids[0])
            check("锁定期间收到：标题 T60、正文为空，附件仍是密文", got?.text == E2E.T.t60 && got?.desp == "" && got?.e2eStatus == "locked"
                  && got?.attachments.first?.key == nil, "\(String(describing: got?.text))")
            if let g = got { _ = PreviewCache.summary(g) }     // 先缓存锁定时的摘要，解开后应当作废
            check("从没解锁过（没有钉住的公钥）：加密发送密钥显示 T73", model.e2eSendKey("PK_selftest") == .needsUnlock)
            guard let ring = model.e2eRing else { throw E2E.Failure(.server, "没有 KeyRing") }
            // 进行中的开启（§4.1）：新钥匙对和恢复码存在钥匙串里，每次刷新状态都核对
            let stranger = try Core.keypair()
            try ring.savePendingSetup(E2E.SetupAttempt(sk: stranger.sk, pub: stranger.pub, code: "X"))
            model.checkE2ESetup(st, ring: ring)
            check("进行中的开启、服务端用的是别的钥匙：删除", (try? ring.pendingSetup()) == nil && model.e2eRecovery == nil)
            try ring.savePendingSetup(E2E.SetupAttempt(sk: kp.sk, pub: kp.pub, code: "SELFTEST-CODE"))
            var notOn = st
            notOn.enabled = false
            model.checkE2ESetup(notOn, ring: ring)
            check("进行中的开启、服务端还没开启：保留，开启页提示重试",
                  model.e2ePendingSetup?.pub == kp.pub && (try? ring.pendingSetup()) != nil && model.e2eRecovery == nil)
            let savedPath = model.path
            model.checkE2ESetup(st, ring: ring)      // §4.5 核对后保存私钥，并钉住公钥
            check("服务端已用这把钥匙开启：保存私钥、钉住公钥、显示恢复码页",
                  model.e2eRecovery?.code == "SELFTEST-CODE" && model.e2eKeys == [kp.sk] && ring.pinned == kp.pub && model.e2ePendingSetup == nil)
            model.e2eRecovery = nil
            model.checkE2ESetup(st, ring: ring)
            check("没点「完成」就被关掉：再刷新（相当于重启）仍回到恢复码页", model.e2eRecovery?.code == "SELFTEST-CODE")
            model.e2eFinishRecovery()
            check("点「完成」：恢复码从 App 状态和钥匙串里删除", model.e2eRecovery == nil && (try? ring.pendingSetup()) == nil)
            // 更换恢复码（§7 第 3 项）：还没确认的不显示；已确认、没点「完成」→ 读钥匙时（相当于重启）回到恢复码页；「完成」后删除
            try ring.savePendingRecovery(E2E.RecoveryAttempt(code: "ROTATE-CODE", wrap: "hjr1.x", confirmed: false))
            model.loadE2EKeys()
            check("更换恢复码还没确认：不显示恢复码页", model.e2eRecovery == nil)
            try ring.savePendingRecovery(E2E.RecoveryAttempt(code: "ROTATE-CODE", wrap: "hjr1.x", confirmed: true))
            model.loadE2EKeys()
            check("更换恢复码已确认、没点「完成」：重启后回到恢复码页", model.e2eRecovery?.code == "ROTATE-CODE" && model.e2eRecovery?.fromSetup == false)
            model.e2eFinishRecovery()
            check("点「完成」：更换的恢复码从钥匙串删除", model.e2eRecovery == nil && (try? ring.pendingRecovery()) == nil)
            model.path = savedPath
            model.loadE2EKeys()
            check("本机有了私钥：已解锁", model.e2eStatus == .unlocked && !model.e2eLocked)
            await model.decryptPending()
            got = model.message(ids[0])
            check("解锁后自动重新解密：标题、正文", got?.text == "加密标题" && got?.desp.hasPrefix("**正文**") == true && got?.e2eStatus == "ok"
                  && got?.type == "markdown", "\(String(describing: got?.text))")
            check("附件：显示载荷里的名字和大小，下载仍用服务端 id 和密文校验值，附件钥匙和消息一起保存",
                  got?.attachments.first.map { $0.id == "a_e2e_\(ids[0])" && $0.name == "曲线.png" && $0.size == 321 && $0.key == fileKey && $0.sha256 == "ab" } == true)
            check("本地解析的 doc 引用服务端附件 id，列表摘要换成解开后的（旧摘要缓存作废）",
                  got?.renderDoc?.blocks.contains { $0.att == "a_e2e_\(ids[0])" || $0.runs?.contains { $0.att == "a_e2e_\(ids[0])" } == true } == true
                  && got.map { PreviewCache.summary($0).contains("正文") } == true, got.map { PreviewCache.summary($0) } ?? "nil")
            try await model.persistNow()
            let saved = Persistence.load().messages.first { $0.id == ids[0] }
            check("写盘读回：信封原文、解密后的内容、附件钥匙都在", saved?.e2e == env && saved?.text == "加密标题" && saved?.e2eStatus == "ok"
                  && saved?.attachments.first?.key == fileKey)
            // 直接 merge（没经过 prepareE2E）的也会在后台解开
            let m2 = try msg(ids[1], try E2ESelfTest.sealPayload(pub: kp.pub, text: "第二条", desp: ""), withAttachment: false)
            model.merge([m2])
            for _ in 0..<20 where model.message(ids[1])?.e2eStatus != "ok" { try? await Task.sleep(nanoseconds: 50_000_000) }
            check("直接合并的加密消息在后台解开", model.message(ids[1])?.text == "第二条")
            // 解密进行中又合并进来的加密消息：这一轮结束后补解，不会漏（§6.1）
            var m4 = try msg(base + 4, try E2ESelfTest.sealPayload(pub: kp.pub, text: "第四条", desp: ""), withAttachment: false)
            m4.applyE2E(.locked)
            model.merge([m4])
            let running = Task { await model.decryptPending() }
            await Task.yield()
            model.merge([try msg(base + 5, try E2ESelfTest.sealPayload(pub: kp.pub, text: "第五条", desp: ""), withAttachment: false)])
            await running.value
            for _ in 0..<20 where model.message(base + 5)?.e2eStatus != "ok" { try? await Task.sleep(nanoseconds: 50_000_000) }
            check("解密进行中合并进来的加密消息：本轮结束后补解，不会漏", model.message(base + 4)?.text == "第四条"
                  && model.message(base + 5)?.text == "第五条" && !model.e2eDecryptAgain)
            check("Pushkey 页的加密发送密钥（用钉住的公钥）", model.e2eSendKey("PK_selftest") == .key("PK_selftest.e2e.\(kp.pub)"))
            var st2 = st
            st2.keys = [E2E.Key(kid: "x", pub: try Core.keypair().pub, active: true)]
            model.e2eState = st2
            check("服务器的有效钥匙和钉住的不同：不显示密钥，显示 T43", model.e2eSendKey("PK_selftest") == .mismatch)
            model.e2eState = st
            // 别的钥匙加密的
            let other = try Core.keypair()
            let m3 = try msg(base + 3, try E2ESelfTest.sealPayload(pub: other.pub, text: "x", desp: ""))
            check("别的钥匙加密的消息：T61", await model.prepareE2E([m3]).first?.text == E2E.T.t61)
            // 载荷里没有附件、服务端却多出一个：按已损坏处理（T62），不把服务端的附件当明文显示
            let m6 = try msg(base + 6, try E2ESelfTest.sealPayload(pub: kp.pub, text: "y", desp: ""))
            let got6 = await model.prepareE2E([m6]).first
            check("载荷和服务端附件数不一致：T62", got6?.e2eStatus == "format" && got6?.text == E2E.T.t62, "\(String(describing: got6?.e2eStatus))")
            // 加密附件下载：拿一个服务器上真实存在的附件，配一把不对的附件钥匙，解密必然失败：卡片显示「解密失败」，不留文件。
            // 服务端 0.8 会补加密演示账号的历史消息、换新附件 id（旧 id 410）：优先用已经补加密好的消息；还没有的先按补加密重拉一次
            // （服务器没有补加密时返回明文、不替换，附件照样能下载）
            var target = model.messages.first { $0.isServerSealed && !$0.attachments.isEmpty }
            if target == nil, let m = model.messages.first(where: { $0.attachments.contains { $0.name == "metrics.xlsx" } }) {
                await model.refetchSealedBatch([m.id])
                target = model.message(m.id)
            }
            if var a = target?.attachments.first {
                a.key = fileKey         // 这条消息的附件钥匙不是它：HJF1 解密失败（明文附件同样失败）
                await model.download(a)
                check("加密附件解密失败：显示「解密失败」，不留文件", model.attState(a) == .failed("解密失败")
                      && !FileManager.default.fileExists(atPath: AppPaths.attachmentFile(a).path), "\(model.attState(a))")
            } else {
                check("演示数据里有带附件的消息", false)
            }
            // 删除服务器上的明文（§7.4）：收到 purge 变更时本机保留副本，记为「仅本机保留」；对账跳过；之后 delete 变更照常删除
            func plain(_ id: Int64) throws -> Message {
                try JSONCoding.decoder.decode(Message.self, from: Data(#"{"id":\#(id),"priority":3,"text":"明文 \#(id)","created_at":"2026-11-19T08:00:00Z"}"#.utf8))
            }
            let (p1, p2) = (base + 11, base + 12)
            model.merge([try plain(p1), try plain(p2)])
            let ch = { (id: Int64, kind: String) in MsgChange(seq: nil, id: id, kind: kind, state: nil) }
            _ = model.applyChanges([ch(p1, "purge"), ch(p2, "purge"), ch(base + 99, "purge")])
            check("收到 purge：本地副本保留，记为仅本机保留（本地没有的不记）",
                  model.message(p1) != nil && model.message(p2) != nil && model.settings.e2ePlainKept == [p1, p2], "\(model.settings.e2ePlainKept)")
            check("对账时跳过仅本机保留的消息", AppModel.withoutKept([p1, p2, 5], kept: model.settings.e2ePlainKept) == [5])
            // 离线超过 90 天收不到 purge（§7.4）：账号开了加密时，对账发现本地明文消息不在服务器上 → 记入保留；加密消息照常删除
            let (q1, q2) = (try plain(base + 13), try msg(base + 14, "hje1.x"))
            let on = AppModel.reconcileMissing([q1, q2, try plain(p1)], e2eAccount: true, kept: [p1])
            check("对账（已开启加密）：明文记入仅本机保留、加密照删、已保留的跳过",
                  on.remove == [q2.id] && on.keep == [q1.id], "\(on)")
            let off = AppModel.reconcileMissing([q1, q2], e2eAccount: false, kept: [])
            check("对账（没开启加密）：服务器上没有的都删", off.remove == [q1.id, q2.id] && off.keep.isEmpty, "\(off)")
            _ = model.applyChanges([ch(p1, "delete")])
            check("之后的 delete 变更照常删除，并移出保留集合", model.message(p1) == nil && model.settings.e2ePlainKept == [p2])
            model._testRemove([p2])
            check("本机删除后移出保留集合", model.settings.e2ePlainKept.isEmpty)
            // 退出登录：删除本机钥匙
            model.e2eWipe()
            check("退出登录：本机私钥全部删除", model.e2eKeys.isEmpty && ((try? model.e2eRing?.accountKeys()) ?? ["x"])?.isEmpty == true
                  && model.e2eState == nil && !model.settings.e2eEnabled)
            check("退出登录不影响本机已解开的消息", model.message(ids[0])?.text == "加密标题")
        } catch {
            check("端到端加密模型测试", false, "\(error)")
        }
        model._testRemove(ids)
        model.e2eWipe()
        // 测试钉住的假公钥不留下，恢复测试前真实账号钉住的公钥（钉住的公钥退出登录也不删，这里是自检自己清理）
        setPin(savedPin)
        model.e2eSecrets = savedSecrets
        model.loadE2EKeys()
        await model.refreshE2E()
        try? await model.persistNow()
    }

    /// 对本地 hub 跑完整的端到端加密流程（和 Mac 共用 E2ESelfTest.online）：自动升级、开启加密、三种解锁、设备批准、
    /// 收加密消息（含附件）、设置项。需要 -demoE2EUser / -demoE2EPass（tests/hub.sh 用管理后台建的账号，旧方式设置的密码）
    private func e2eOnlineTests(server: String) async {
        let d = UserDefaults.standard
        guard let user = d.string(forKey: "demoE2EUser"), let pass = d.string(forKey: "demoE2EPass"), let url = URL(string: server) else {
            out("（跳过端到端加密联网测试：没有 -demoE2EUser / -demoE2EPass）")
            return
        }
        let open = API(server: url, token: nil)
        guard (try? await open.info())?.features?.contains(where: { $0.id == "e2e" }) == true else {
            out("（服务端没有 e2e 功能，跳过端到端加密联网测试）")
            return
        }
        out("— 端到端加密（联网）")
        do {
            // 旧方式登录（这个账号还没升级），拿一台设备的 token 和一把 pushkey；之后的流程全部走新协议
            let fp = (0..<32).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
            let r = try await open.login(username: user, password: pass, name: "自检 e2e 设备 A", fingerprint: fp)
            let k = try await API(server: url, token: r.token).createKey(name: "e2e 自检")
            await E2ESelfTest.online({ check($0, $1, $2) }, server: url, transport: { API(server: url, token: $0) },
                                     tokenA: r.token, username: user, password: pass, pushkey: k.key)
        } catch {
            check("端到端加密联网测试：准备账号", false, shortError(error))
        }
    }

    private func changesTests(_ api: API) async {
        func manage(_ path: String, _ body: [String: Any]) async throws { try await api.send(path, method: "POST", json: body) }
        do {
            try await model.catchUp(api, model.session)   // 第一次：先对账拿到变更游标
            check("对账后拿到变更游标", model.settings.changesCursor != nil, "\(String(describing: model.settings.changesCursor))")
            let inbox = model.inbox
            guard inbox.count >= 4 else { check("变更测试需要至少 4 条消息", false); return }
            let (a, b, c, d) = (inbox[0].id, inbox[1].id, inbox[2].id, inbox[3].id)
            // 别的设备删除 a、归档 b
            try await manage("/v1/messages/delete", ["ids": [a]])
            try await manage("/v1/messages/archive", ["ids": [b], "state": 1])
            try await model.catchUp(api, model.session)
            check("变更流：别处删除的消息本机移除", model.message(a) == nil)
            check("变更流：别处归档的消息不进收件箱", model.message(b)?.archive == 1 && !model.inbox.contains { $0.id == b })
            check("变更流：已落盘", Persistence.load().messages.first { $0.id == b }?.archive == 1 && !Persistence.load().messages.contains { $0.id == a })
            // 长轮询被变更唤醒：挂起中有人归档 c，立即返回
            let start = Date()
            let since = model.settings.cursor
            let cs = model.settings.changesCursor
            async let page = api.messages(since: since, limit: 200, wait: 20, changesSince: cs)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try await manage("/v1/messages/archive", ["ids": [c], "state": 1])
            let p = try await page
            check("长轮询：有变更时立即返回（\(String(format: "%.1f", Date().timeIntervalSince(start))) 秒）",
                  p.changes.contains { $0.id == c && $0.kind == "archive" } && Date().timeIntervalSince(start) < 6)
            try await model.catchUp(api, model.session)
            // 对账：游标作废（离线太久）期间删除的消息，重新对账后移除
            model.settings.changesCursor = nil
            try await manage("/v1/messages/delete", ["ids": [d]])
            try await model.catchUp(api, model.session)
            check("对账：游标作废期间删除的消息被移除", model.message(d) == nil && model.settings.changesCursor != nil)
            // 打开早于已同步位置、又不在本机的消息：直接显示「找不到」，不会一直转圈
            check("已删除的旧消息 id ≤ 游标（详情页不转圈）", d <= model.settings.cursor)
        } catch { check("删除 / 归档同步", false, shortError(error)) }
    }

    private func notifyDeliveryTests() async {
        let c = UNUserNotificationCenter.current()
        _ = try? await c.requestAuthorization(options: [.alert, .sound, .badge, .provisional])
        let st = await c.notificationSettings().authorizationStatus
        guard st == .provisional || st == .authorized else { out("（跳过通知投递测试：授权状态 \(st.rawValue)）"); return }
        Notifier.removeAll()
        func m(_ id: Int64, _ p: Int) -> Message {
            try! JSONCoding.decoder.decode(Message.self, from: Data(#"{"id":\#(id),"priority":\#(p),"text":"通知测试 \#(id)","topic":"test","created_at":"2026-11-17T06:32:05Z"}"#.utf8))
        }
        func ids() async -> [String] {
            try? await Task.sleep(nanoseconds: 400_000_000)
            return await c.deliveredNotifications().map(\.request.identifier).sorted()
        }
        let name: (String) -> String = { $0 }
        Notifier.post((9001...9003).map { m($0, 3) }, channelName: name)
        Notifier.post((9004...9006).map { m($0, 4) }, channelName: name)
        Notifier.post([m(9007, 5)], channelName: name)
        await Notifier.flush()
        var got = await ids()
        check("投递：6 条普通 + 1 条 P5 各自单独通知", got == (9001...9007).map { "msg-\($0)" }, "\(got)")
        Notifier.post([m(9008, 3)], channelName: name)
        await Notifier.flush()
        got = await ids()
        let summary = await c.deliveredNotifications().first { $0.request.identifier == Notifier.summaryID }?.request.content.title
        check("投递：第 7 条普通消息 → 撤掉单独通知、汇总「\(summary ?? "")」，P5 保留", got == ["msg-9007", "summary"] && summary == "7 条新消息", "\(got) \(summary ?? "")")
        Notifier.post([m(9009, 4), m(9010, 3)], channelName: name)
        await Notifier.flush()
        let s2 = await ids().contains("summary") ? await c.deliveredNotifications().first { $0.request.identifier == Notifier.summaryID }?.request.content.title : nil
        check("投递：汇总还在时继续并入（\(s2 ?? "无")）", s2 == "9 条新消息", s2 ?? "无")
        Notifier.opened(9007)
        got = await ids()
        check("投递：打开消息撤掉它的通知和汇总", got.isEmpty, "\(got)")
        Notifier.post([m(9011, 3), m(9012, 5)], channelName: name)
        await Notifier.flush()
        model.markAllRead()
        got = await ids()
        check("投递：全部已读撤掉所有通知", got.isEmpty, "\(got)")
        Notifier.post([m(9013, 5)], channelName: name, valid: { false })
        await Notifier.flush()
        got = await ids()
        check("投递：排队期间退出了登录（会话失效）→ 不补发", got.isEmpty, "\(got)")
    }

    private func barkTests(_ api: API) async {
        let d = UserDefaults.standard
        if model.barkSupported != true {
            do {
                _ = try await api.putBark(url: "https://api.day.app/x/", cipherKey: "", cipherIV: "")
                check("Bark（服务端不支持）", false, "应报错")
            } catch {
                check("Bark：服务端不支持时报「版本较旧」", (error as? APIError) == .unsupported, "\(error)")
            }
            return
        }
        guard let barkURL = d.string(forKey: "demoBarkURL") else { out("（跳过 Bark：没有 -demoBarkURL）"); return }
        do {
            try await model.saveBark(url: "ftp://x", encrypt: false, key: "", iv: "")
            check("Bark：非 http 地址应拒绝", false)
        } catch { check("Bark：非 http 地址本地拒绝", true) }
        // 失败路径：Bark 返回错误时显示服务端转述的说明
        do {
            let bad = barkURL.replacingOccurrences(of: URL(string: barkURL)!.lastPathComponent, with: "badkey")
            try await model.saveBark(url: bad, encrypt: false, key: "", iv: "")
            try await model.testBark()
            check("Bark：key 不对时测试应失败", false)
        } catch { check("Bark：key 不对 → 「\(shortError(error))」", shortError(error).hasPrefix("Bark 返回"), shortError(error)) }
        // 固定 Key / IV（-demoBarkKey / -demoBarkIV），测试脚本用 openssl 解密模拟 Bark 收到的密文
        let key = d.string(forKey: "demoBarkKey") ?? BarkCipherStore.random(32)
        let iv = d.string(forKey: "demoBarkIV") ?? BarkCipherStore.random(16)
        do {
            try await model.saveBark(url: barkURL + "/", encrypt: true, key: key, iv: iv)
            check("Bark：保存（加密）", model.bark?.encrypted == true && model.settings.barkOn && model.bark?.url == barkURL, "\(String(describing: model.bark))")
            let me = try await api.me()
            check("Bark：/v1/me 返回配置", me.bark?.url.isEmpty == false && me.bark?.encrypted == true, "\(String(describing: me.bark))")
            check("Bark 地址不在 UserDefaults（含设备 key，会进备份）", UserDefaults.standard.string(forKey: "barkURL") == nil
                  && model.settings.barkURL == barkURL)
            check("Bark：Key/IV 存在本机", BarkCipherStore.load()?.key == key && BarkCipherStore.load()?.iv == iv)
            check("Bark：开启后不发本地通知", !AppModel.shouldNotify(model.messages.last!, barkOn: model.settings.barkOn, hidden: false))
            try await model.testBark()
            check("Bark：发送测试成功", true)
            // 新消息由服务端转发给 Bark（脚本检查 level、url=huijian://message/<id>、密文）
            try await model.sendTestPush()
            try await Task.sleep(nanoseconds: 1_500_000_000)
            try await model.catchUp(api, model.session)
            out("BARK_FORWARDED_ID \(model.messages.last?.id ?? 0)")
        } catch { check("Bark：保存 / 测试", false, shortError(error)) }
        do {
            try await model.saveBark(url: "", encrypt: false, key: "", iv: "")
            let me = try await api.me()
            check("Bark：关闭", model.bark == nil && !model.settings.barkOn && me.bark == nil && BarkCipherStore.load() == nil)
        } catch { check("Bark：关闭", false, shortError(error)) }
        // 服务端拒绝的地址：显示服务端说明
        do {
            try await model.saveBark(url: "https://", encrypt: false, key: "", iv: "")
            check("Bark：错误地址应 400", false)
        } catch { check("Bark：错误地址 → 服务端说明（\(shortError(error))）", (error as? APIError).map { if case .http(400, _) = $0 { return true }; return false } ?? false) }
    }
}
