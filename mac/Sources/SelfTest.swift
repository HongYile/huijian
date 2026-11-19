import AppKit
import CryptoKit
import Foundation
import SwiftUI
import UserNotifications

/// 命令行自检：Huijian --selftest <server> <pairCode> <pushkey> [--workdir <dir>]
/// 不弹 GUI，不写真实的钥匙串项（只用独立 service 做一次读写往返后删除），不发系统通知。
enum SelfTest {
    static func launch(_ args: [String]) {
        TestHooks.enabled = true
        Task { @MainActor in
            let code = await run(args)
            exit(code)
        }
        dispatchMain()
    }

    @MainActor static var pass = 0
    @MainActor static var fail = 0

    @MainActor static func ok(_ s: String) { pass += 1; print("  ✅ \(s)"); fflush(stdout) }
    @MainActor static func ng(_ s: String) { fail += 1; print("  ❌ \(s)"); fflush(stdout) }
    @MainActor static func check(_ cond: Bool, _ s: String) { cond ? ok(s) : ng(s) }
    static func step(_ s: String) { print("[\(s)]"); fflush(stdout) }

    @MainActor static func run(_ argv: [String]) async -> Int32 {
        var args = argv
        var workdir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("huijian-selftest-\(getpid())")
        if let i = args.firstIndex(of: "--workdir"), i + 1 < args.count {
            workdir = URL(fileURLWithPath: args[i + 1])
            args.removeSubrange(i...(i + 1))
        }
        var adminCode: String?
        if let i = args.firstIndex(of: "--admin-code"), i + 1 < args.count {
            adminCode = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        var opts: [String: String] = [:]
        for k in ["--mock-gh-port", "--mock-proxy-port", "--mock-log", "--gh-pub", "--gh-build", "--keys-code"] {
            if let i = args.firstIndex(of: k), i + 1 < args.count {
                opts[k] = args[i + 1]
                args.removeSubrange(i...(i + 1))
            }
        }
        var updatePub: String?, installTarget: String?
        if let i = args.firstIndex(of: "--update-pub"), i + 1 < args.count {
            updatePub = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        if let i = args.firstIndex(of: "--install-target"), i + 1 < args.count {
            installTarget = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        guard args.count >= 3, let server = URL(string: args[0]) else {
            print("用法: Huijian --selftest <server> <pairCode> <pushkey> [--workdir <dir>]")
            return 2
        }
        let code = args[1], pushkey = args[2]
        currentPushkey = pushkey
        try? FileManager.default.removeItem(at: workdir)
        let paths = AppPaths(supportDir: workdir.appendingPathComponent("support"), cacheDir: workdir.appendingPathComponent("cache"))
        print("Huijian selftest  server=\(server.absoluteString)  workdir=\(workdir.path)")

        step("0 服务器地址规范化")
        check(AppModel.normalizeServer(" push.example.com/ ") == "https://push.example.com", "无协议自动补 https://，去掉末尾斜杠")
        check(AppModel.normalizeServer("http://10.0.0.2:8790") == "http://10.0.0.2:8790", "保留 http 和端口")
        check(AppModel.normalizeServer("   ") == "", "空白视为未填写")
        check(AppModel.normalizeServer("1.2.3.4:8790") == "http://1.2.3.4:8790", "公网 IP:端口 默认 http")
        check(AppModel.normalizeServer("1.2.3.4") == "http://1.2.3.4", "纯 IP 默认 http")
        check(AppModel.normalizeServer("push.example.com:8443") == "https://push.example.com:8443", "域名带端口仍默认 https")
        check(AppModel.normalizeServer("localhost:8790") == "http://localhost:8790", "localhost 默认 http")
        check(AppModel.insecureNotice("1.2.3.4:8790") != nil, "公网 http 给出明文提示")
        check(AppModel.insecureNotice("http://192.168.1.5:8790") == nil && AppModel.insecureNotice("http://10.0.0.5:8790") == nil
              && AppModel.insecureNotice("http://172.20.0.2:8790") == nil, "内网 http 不提示")
        check(AppModel.insecureNotice("push.example.com") == nil, "https 不提示")

        // 1. SSE 解析器单元测试
        step("1 SSE 解析器")
        do {
            var p = SSEParser()
            var evs: [SSEEvent] = []
            let sample = ["retry: 3000", "event: hello", "data: {\"since\":0}", "", ": ping", "",
                          "id: 7", "event: message",
                          "data: {\"id\":7,\"topic\":\"t\",\"thread\":\"\",\"priority\":4,\"type\":\"markdown\",\"text\":\"hi\",\"desp\":\"\",\"source\":\"s\",\"created_at\":\"2026-11-17T03:00:00Z\",\"attachments\":[]}",
                          ""]
            for l in sample { if let e = try p.feed(line: l) { evs.append(e) } }
            var kinds: [String] = []
            for e in evs {
                switch e {
                case .hello: kinds.append("hello")
                case .ping: kinds.append("ping")
                case .message(let m): kinds.append("message:\(m.id):\(m.text)")
                }
            }
            check(kinds == ["hello", "ping", "message:7:hi"], "事件序列 \(kinds)")
            check(p.lastID == "7", "记录 Last-Event-ID")
        } catch {
            ng("SSE 解析异常 \(error)")
        }

        // 回笺 Markdown（服务端 doc）：解码、旧缓存兼容、绘制逻辑、整篇绘制（和 iPhone 共用 MDSelfTest.swift）。
        // 放在联网测试之前、用单独的模型：放在第 10 步时 ImageRenderer 卡在 SwiftUI 的 _MovableLockSyncMain 上不返回
        // （单独的进程里同样的代码正常，具体是前面哪一步引起的没有查明）
        step("1b 回笺 Markdown（doc）")
        let mdModel = AppModel(paths: AppPaths(supportDir: workdir.appendingPathComponent("md/support"), cacheDir: workdir.appendingPathComponent("md/cache")),
                               keychainService: "io.github.hongyile.huijian.selftest-md", loadToken: false,
                               defaults: UserDefaults(suiteName: "io.github.hongyile.huijian.selftest-md")!)
        MDSelfTest.run({ name, good, detail in check(good, good ? name : "\(name)  \(detail)") }, render: { doc, atts in
            let v = DocView(doc: doc)
                .environment(\.mdActions, MDActions(attachments: atts))
                .environmentObject(mdModel)
                .padding(24)
                .frame(width: 720)
                .background(Theme.surface)
            let r = ImageRenderer(content: v)
            r.scale = 1
            return r.nsImage?.size
        })
        await MDSelfTest.runAsync { name, good, detail in check(good, good ? name : "\(name)  \(detail)") }
        if let pm = try? JSONCoding.decoder.decode(Message.self, from: Data(MDSelfTest.message(#","preview":"第一行\n第二行""#).utf8)) {
            check(messageSummary(pm) == "第一行 第二行", "列表摘要优先用服务端 preview（压成一行）")
        }
        check(MDLogic.messageID(URL(string: "huijian://message/9")!) == 9, "App 认 huijian://message/<id> 深链")

        // 2. 配对
        step("2 配对")
        let token: String
        do {
            let r = try await APIClient.pair(server: server, code: code, name: "selftest-mac")
            check(r.token.hasPrefix("DT_"), "配对成功，设备 \(r.device_id)")
            token = r.token
        } catch {
            ng("配对失败：\(error.localizedDescription)")
            return finish()
        }
        do {
            _ = try await APIClient.pair(server: server, code: code, name: "again")
            ng("配对码被重复使用")
        } catch {
            ok("配对码不能重复使用（\(error.localizedDescription)）")
        }

        // 3. 钥匙串往返（独立 service，测完删除）
        step("3 钥匙串")
        let ksvc = "io.github.hongyile.huijian.selftest"
        check(Keychain.save(token, service: ksvc), "写入钥匙串")
        check(Keychain.load(service: ksvc) == token, "读回一致")
        Keychain.delete(service: ksvc)
        check(Keychain.load(service: ksvc) == nil, "删除后读不到")

        let suite = "io.github.hongyile.huijian.selftest"
        UserDefaults().removePersistentDomain(forName: suite)
        let model = AppModel(paths: paths, keychainService: ksvc, loadToken: false, defaults: UserDefaults(suiteName: suite)!)
        model.notificationsEnabled = false
        model.useToken(token, server: server.absoluteString)
        let client = APIClient(server: server, token: token)

        // 4. 拉历史 + 本地持久化
        step("4 历史消息与持久化")
        do {
            let hist = try await client.allMessages(since: 0)
            model.merge(hist, notify: false)
            check(!hist.isEmpty, "拉到历史消息 \(hist.count) 条，最大 id \(model.maxID)")
            if let m = hist.first(where: { !$0.attachments.isEmpty }) {
                print("    示例: #\(m.id) P\(m.priority) \(m.topic) “\(m.text)” 附件 \(m.attachments.map { "\($0.name)(\(humanSize($0.size)))" })")
            }
            model.markRead(hist.first?.id ?? 0)
            AppModel.flushSaves()
            let reloaded = Persistence.load(paths.messagesFile)
            check(reloaded.messages.count == model.messages.count && reloaded.read == model.read,
                  "messages.json 写入并读回一致（\(reloaded.messages.count) 条）")
            check(model.merge(hist, notify: false).isEmpty, "重复合并不产生新消息")
            // 服务端 0.6.0 的 doc / preview（tests/selftest.sh 发了一条覆盖全部语法的消息）
            if let md = model.messages.last(where: { $0.text == "exp43 训练报告" }) {
                let blocks = md.renderDoc?.blocks ?? []
                let types = Set(blocks.map(\.type))
                let want: Set<String> = ["heading", "paragraph", "progress", "table", "image", "callout", "list", "quote", "rule", "code", "file", "footnotes"]
                check(want.isSubset(of: types) && blocks.allSatisfy(\.known), "服务端 doc：按 doc 绘制（\(blocks.count) 块、\(types.count) 种）")
                let ids = Set(md.attachments.map(\.id))
                let refs = blocks.compactMap(\.att)
                check(refs.count >= 2 && refs.allSatisfy { ids.contains($0) }, "正文引用的附件（图片、PDF）都在这条消息的附件里 \(refs.count) 处")
                check(blocks.contains { $0.type == "image" && $0.src?.hasPrefix("https://") == true }, "外部图片保留 src（默认不加载）")
                check(messageSummary(md).hasPrefix("结论：val_loss"), "列表摘要用服务端 preview（不重复标题）：“\(messageSummary(md, limit: 30))”")
                check(reloaded.messages.first { $0.id == md.id }.map { $0.doc == md.doc && $0.preview == md.preview } == true,
                      "doc / preview 存进 messages.json 并读回一致")
            } else {
                ng("没拉到演示消息 exp43 训练报告")
            }
        } catch {
            ng("拉历史失败：\(error.localizedDescription)")
        }

        // 5. 401
        step("5 无效 token")
        do {
            _ = try await APIClient(server: server, token: "DT_invalid").messages(since: 0)
            ng("无效 token 居然成功")
        } catch let e as APIError {
            if case .unauthorized = e { ok("无效 token 返回 unauthorized") } else { ng("错误类型不对：\(e)") }
        } catch {
            ng("错误类型不对：\(error)")
        }

        // 6. 长轮询（主用传输）
        step("6 长轮询")
        // 6a 没有新消息：挂起约 wait 秒后返回空列表
        do {
            let t = Date()
            let empty = try await client.messages(since: model.maxID, limit: 200, wait: 2)
            let dt = Date().timeIntervalSince(t)
            check(empty.isEmpty && dt >= 1.5 && dt < 6, String(format: "无新消息时挂起 %.1f 秒后返回空列表", dt))
        } catch {
            ng("长轮询超时测试失败：\(error.localizedDescription)")
        }
        // 6b 挂起期间到达新消息：立即返回
        let marker = "selftest-realtime-\(Int.random(in: 100000...999999))"
        var received: Message?
        let since = model.maxID
        let pollStart = Date()
        let poll = Task { @MainActor () -> [Message] in
            (try? await client.messages(since: since, limit: 200, wait: 50)) ?? []
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        let payload = Data((0..<1_500_000).map { _ in UInt8.random(in: 0...255) })
        let t0 = Date()
        do {
            try await pushMultipart(server: server, pushkey: pushkey, text: marker, desp: "**粗体** 与 `代码`",
                                    priority: 4, fileName: "实时附件.bin", fileData: payload)
            ok("通过 /message/push 发出带附件消息")
        } catch {
            ng("发送失败：\(error.localizedDescription)")
        }
        let got = await poll.value
        let total = Date().timeIntervalSince(pollStart)
        model.merge(got, notify: false)
        received = got.first { $0.text == marker }
        if let m = received {
            ok(String(format: "长轮询在 %.2f 秒时返回新消息 #%lld（发出后 %.0f ms），附件 %d 个", total, m.id,
                      Date().timeIntervalSince(t0) * 1000, m.attachments.count))
        } else {
            ng("长轮询没有拿到新消息（返回 \(got.count) 条，用时 \(String(format: "%.1f", total)) 秒）")
        }
        // 6c 连续发 3 条：下一次长轮询一次拿全
        do {
            for i in 1...3 {
                try await pushMultipart(server: server, pushkey: pushkey, text: "batch-\(i)", desp: "", priority: 2,
                                        fileName: nil, fileData: nil)
            }
            let batch = try await client.messages(since: model.maxID, limit: 200, wait: 50)
            model.merge(batch, notify: false)
            check(batch.map(\.text) == ["batch-1", "batch-2", "batch-3"], "积压的 3 条一次取回且有序")
        } catch {
            ng("批量测试失败：\(error.localizedDescription)")
        }

        // 7. 附件下载：进度 + sha256
        step("7 附件下载")
        var realtimeAtt: Attachment?
        if let m = received, let a = m.attachments.first {
            realtimeAtt = a
            var progressValues: [Double] = []
            do {
                let url = try await model.cache.fetch(a, client: client, engine: model.engine) { p in
                    Task { @MainActor in progressValues.append(p) }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                let actual = try sha256OfFile(url)
                check(actual == a.sha256, "sha256 一致 \(actual.prefix(12))…")
                check(FileManager.default.fileExists(atPath: url.path) && url.lastPathComponent == "实时附件.bin",
                      "保存为 att/\(a.id)/\(url.lastPathComponent)")
                check(!progressValues.isEmpty && (progressValues.last ?? 0) >= 0.99,
                      "进度回调 \(progressValues.count) 次，最终 \(Int((progressValues.last ?? 0) * 100))%")
                model.refreshLocalFiles()
                check(model.localFiles[a.id] != nil, "localFiles 已登记")
            } catch {
                ng("下载失败：\(error.localizedDescription)")
            }
            // 篡改 sha256：应拒绝
            let bad = Attachment(id: a.id, name: "bad.bin", mime: a.mime, size: a.size, sha256: String(repeating: "0", count: 64))
            do {
                _ = try await model.cache.fetch(bad, client: client, engine: model.engine) { _ in }
                ng("sha256 不一致却没有报错")
            } catch {
                ok("sha256 不一致被拒绝（\(error.localizedDescription)）")
            }
            let missing = Attachment(id: "a_doesnotexist", name: "x", mime: "x", size: 1, sha256: "")
            do {
                _ = try await model.cache.fetch(missing, client: client, engine: model.engine) { _ in }
                ng("不存在的附件居然下载成功")
            } catch {
                ok("不存在的附件报错（\(error.localizedDescription)）")
            }
        }

        // 8. 图片附件走 AppModel.download，生成缩略图
        step("8 图片附件与缩略图")
        let imgMsg = model.messages.first { $0.attachments.contains { $0.mime.hasPrefix("image/") } }
        let imgAtt = imgMsg?.attachments.first { $0.mime.hasPrefix("image/") }
        if let imgMsg, let imgAtt {
            await model.download(imgAtt)
            check(model.localFiles[imgAtt.id] != nil && model.downloadErrors[imgAtt.id] == nil, "图片 \(imgAtt.name) 下载完成")
            for _ in 0..<30 where model.thumbnails[imgAtt.id] == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            if let t = model.thumbnails[imgAtt.id] {
                ok("QuickLook 缩略图生成 \(Int(t.size.width))x\(Int(t.size.height))")
            } else {
                ng("缩略图未生成")
            }

            // 9. 每日清理：两份附件都改成 25 小时前下载，收藏图片所在消息
            step("9 每日清理")
            if let a = realtimeAtt, model.localFiles[a.id] != nil {
                let old = Date().addingTimeInterval(-25 * 3600)
                model.cache.setDownloadedAt(a.id, old)
                model.cache.setDownloadedAt(imgAtt.id, old)
                model.toggleStar(imgMsg.id)
                let removed = model.runCleanup()
                check(removed == [a.id], "清理了超过 24h 的未收藏附件 \(removed)")
                check(model.localFiles[a.id] == nil && !FileManager.default.fileExists(atPath: model.cache.baseDir.appendingPathComponent(a.id).path),
                      "文件已删除，占位恢复为「点击查看」")
                check(model.localFiles[imgAtt.id] != nil, "收藏消息的附件保留")
                check(model.messages.contains { $0.id == received?.id }, "文字消息保留")
                model.toggleStar(imgMsg.id)
                let removed2 = model.runCleanup()
                check(removed2 == [imgAtt.id], "取消收藏后再次清理会删除")
                let fresh = model.runCleanup()
                check(fresh.isEmpty, "无过期附件时不删除")
            } else {
                ng("缺少实时附件，跳过清理测试")
            }
        } else {
            ng("历史中没有图片附件（测试脚本应先发送一张 PNG）")
        }

        // 10. Markdown
        step("10 Markdown 渲染")
        let md = renderMarkdown("**粗体** 与 `代码`", plain: false)
        check(String(md.characters) == "粗体 与 代码", "Markdown 解析为 “\(String(md.characters))”")
        check(String(renderMarkdown("**原样**", plain: true).characters) == "**原样**", "type=text 时不解析")

        // 12. 界面逻辑
        step("12 界面逻辑（线程/摘要/Markdown/文件类型/通知规则/时间）")
        uiLogicTests()

        // 13. 账户与管理后台一键登录
        step("13 账户与管理后台")
        await accountTests(server: server, token: token, adminCode: adminCode)

        // 16. 代理、自动下载、GitHub 更新源
        step("16 代理 / 自动下载 / GitHub 更新源")
        await networkTests(server: server, token: token, model: model, opts: opts,
                           workDir: workdir.appendingPathComponent("gh-update"))

        // 17. 设备自助管理：改名、pushkey
        step("17 设备自助管理（改名 / pushkey）")
        let adminClient = await selfServiceTests(client: client, model: model, server: server, keysCode: opts["--keys-code"])
        step("18 版本协商 / 服务端存储与备份 / 附件位置 / 配置迁移")
        await compatStorageTests(normal: client, admin: adminClient, model: model, workdir: workdir)

        // 14. 应用内更新
        if let updatePub, let installTarget {
            step("14 应用内更新")
            await updateTests(client: client, engine: model.engine, publicKey: updatePub,
                              workDir: workdir.appendingPathComponent("update"), target: URL(fileURLWithPath: installTarget))
        }

        // 20. 删除与归档
        step("20 删除与归档（多设备同步）")
        await messageManageTests(client: client, model: model, server: server, pushkey: pushkey)

        // 21. 频道设置
        step("21 频道设置（改名 / 静音 / 隐藏 / 置顶 / 排序 / 删除频道）")
        await channelTests(client: client, model: model, server: server, pushkey: pushkey)

        // 19. 账号（放在最后：同一台 Mac 登录会沿用本机设备记录，让之前的 token 失效）
        step("19 账号 / 设备身份 / 本机接收规则 / 在用设备")
        await accountTests(normal: client, other: adminClient, model: model, server: server, pushkey: pushkey)

        // 11. 通知权限（只读，不弹窗）
        step("11 通知权限（仅查询）")
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let names: [UNAuthorizationStatus: String] = [.notDetermined: "未决定", .denied: "已拒绝", .authorized: "已允许", .provisional: "临时允许"]
        print("    当前通知授权状态：\(names[settings.authorizationStatus] ?? "\(settings.authorizationStatus.rawValue)")（GUI 首次启动会请求）")

        return finish()
    }

    static func msg(_ id: Int64, _ topic: String, _ thread: String, _ p: Int, _ text: String, _ desp: String = "",
                    att: Int = 0) -> Message {
        let atts = (0..<att).map { i in "{\"id\":\"a\(id)_\(i)\",\"name\":\"f\(i).png\",\"mime\":\"image/png\",\"size\":10,\"sha256\":\"x\"}" }
        let json = "{\"id\":\(id),\"topic\":\"\(topic)\",\"thread\":\"\(thread)\",\"priority\":\(p),\"type\":\"markdown\",\"text\":\"\(text)\",\"desp\":\"\(desp)\",\"source\":\"t\",\"created_at\":\"2026-11-17T03:00:00Z\",\"attachments\":[\(atts.joined(separator: ","))]}"
        return try! JSONCoding.decoder.decode(Message.self, from: Data(json.utf8))
    }

    @MainActor static func messageManageTests(client: APIClient, model: AppModel, server: URL, pushkey: String) async {
        // 归档规则（纯逻辑）
        let base = msg(1, "t", "", 3, "x").createdAt
        var old = msg(9_000_001, "t", "", 3, "旧")
        let later = base.addingTimeInterval(40 * 86400)
        model.archiveDays = 30
        check(model.isArchived(old, now: later) && !model.isArchived(old, now: base.addingTimeInterval(20 * 86400)),
              "超过 30 天自动归档，20 天的不归档")
        old.archive = ArchiveState.keep
        check(!model.isArchived(old, now: later), "移回收件箱的不再自动归档")
        old.archive = ArchiveState.archived
        check(model.isArchived(old, now: base), "手动归档的立即归档")
        model.archiveDays = 0
        check(!model.isArchived(msg(9_000_002, "t", "", 3, "x"), now: later), "不自动归档时只看手动归档")
        model.archiveDays = 30

        // 对账：本地有、服务端没有的消息被删掉
        let fakes = [msg(9_000_011, "fake", "th", 3, "旧线程"), msg(9_000_012, "fake", "th", 3, "旧线程 2"), msg(9_000_013, "fake", "", 3, "单条")]
        model.merge(fakes, notify: false)
        model.toggleStar(9_000_013)
        let starredOld = model.isArchived(fakes[2], now: later)
        check(!starredOld, "收藏的消息不自动归档")
        check(model.archivedThreads(now: later).contains(threadKey(fakes[0])), "整个线程都超期时线程归档")
        let realCount = model.messages.count - fakes.count
        do {
            try await model.reconcile(client)
            check(model.messages.count == realCount && !model.starred.contains(9_000_013), "对账：服务端没有的消息从本机删除（收藏标记一起清掉）")
        } catch {
            ng("对账失败：\(error.localizedDescription)")
        }

        // 服务端纪元变了（重建或从备份恢复）：服务端没有的消息不能当作被删除
        let suite = UserDefaults(suiteName: "io.github.hongyile.huijian.selftest")!
        let realEpoch = suite.string(forKey: AppModel.key("changesEpoch"))
        check(realEpoch?.isEmpty == false, "对账后记下服务端变更纪元")
        suite.set("other-server", forKey: AppModel.key("changesEpoch"))
        model.merge([msg(9_000_031, "fake", "", 3, "旧服务器的消息")], notify: false)
        do {
            try await model.reconcile(client)
            check(model.messages.contains { $0.id == 9_000_031 } && suite.string(forKey: AppModel.key("changesEpoch")) == realEpoch,
                  "纪元不同：不删除本地消息，改用新纪元")
        } catch {
            ng("对账失败：\(error.localizedDescription)")
        }
        model.removeLocal([9_000_031])

        // 发 3 条：A 归档、B 本机删除、C 另一台设备删除
        var ids: [Int64] = []
        do {
            let since = model.maxID
            try await pushMultipart(server: server, pushkey: pushkey, text: "manage-A", desp: "", priority: 3, fileName: nil, fileData: nil)
            try await pushMultipart(server: server, pushkey: pushkey, text: "manage-B", desp: "", priority: 3,
                                    fileName: "b.bin", fileData: Data(repeating: 7, count: 2048))
            try await pushMultipart(server: server, pushkey: pushkey, text: "manage-C", desp: "", priority: 3, fileName: nil, fileData: nil)
            let got = try await client.allMessages(since: since)
            model.merge(got, notify: false)
            ids = ["manage-A", "manage-B", "manage-C"].compactMap { t in got.first { $0.text == t }?.id }
        } catch {
            ng("发送测试消息失败：\(error.localizedDescription)")
        }
        guard ids.count == 3 else { ng("没拿到 3 条测试消息"); return }
        let (a, b, c) = (ids[0], ids[1], ids[2])
        let attB = model.messages.first { $0.id == b }?.attachments.first
        guard let startStates = try? await client.messageStates() else { ng("对账接口不可用"); return }
        let cursor = startStates.changesNext
        check(startStates.items[a] == 0 && startStates.items[c] != nil, "对账接口返回这个账号的消息和归档状态")

        check(await model.setArchive([a], state: ArchiveState.archived), "归档 A")
        check(model.messages.first { $0.id == a }?.archive == ArchiveState.archived && model.archivedThreads.contains(threadKey(model.messages.first { $0.id == a }!)),
              "A 在本机立即进入归档")
        check(model.count(.archived) >= 1 && !model.inbox.contains { $0.id == a }, "归档的不在收件箱里，未读数不算它")
        model.markRead(b)
        model.toggleStar(b)
        check(await model.deleteMessages([b]), "删除 B")
        check(!model.messages.contains { $0.id == b } && !model.read.contains(b) && !model.starred.contains(b), "B 从本机删除，已读 / 收藏标记一起清掉")
        if let attB {
            let code = ((try? await URLSession.shared.data(for: client.request("/v1/att/\(attB.id)")))?.1 as? HTTPURLResponse)?.statusCode
            check(code == 404, "删除后服务端附件不能再下载（HTTP \(code.map(String.init) ?? "无响应")）")
        }

        // 另一台设备（同账号）删除 C：变更游标拿到删除，本机应用
        do {
            let n = try await client.deleteMessages([c, 999_999_999])
            check(n == 1, "接口删除：只删除存在且属于本账号的（\(n) 条）")
            let page = try await client.messagesPage(since: model.maxID, limit: 200, wait: 0, changesSince: cursor)
            let kinds = page.changes.map { "\($0.id):\($0.kind)" }
            check(kinds == ["\(a):archive", "\(b):delete", "\(c):delete"] && page.changes.first?.state == 1,
                  "变更记录按顺序返回：\(kinds.joined(separator: ", "))")
            model.applyChanges(page.changes)
            check(!model.messages.contains { $0.id == c }, "应用变更后 C 从本机消失")

            // 长轮询挂起时，其他设备的操作立即唤醒
            let next = page.changesNext ?? cursor
            let t0 = Date()
            let poll = Task { try await client.messagesPage(since: model.maxID, limit: 200, wait: 30, changesSince: next) }
            try? await Task.sleep(nanoseconds: 600_000_000)
            _ = try await client.archiveMessages([a], state: ArchiveState.keep)
            let woke = try await poll.value
            let dt = Date().timeIntervalSince(t0)
            check(woke.changes.map(\.id) == [a] && woke.changes.first?.state == ArchiveState.keep && dt < 5,
                  String(format: "长轮询 %.1f 秒被归档变更唤醒", dt))
            model.applyChanges(woke.changes)
            check(model.messages.first { $0.id == a }?.archive == ArchiveState.keep, "A 移回收件箱（来自变更）")

            let far = try await client.messagesPage(since: model.maxID, limit: 1, wait: 0, changesSince: Int64.max / 4)
            check(far.changesReset, "游标超出服务端记录时返回 changes_reset（客户端重新对账）")
        } catch {
            ng("变更同步测试失败：\(error.localizedDescription)")
        }

        // 设置实时同步（服务端 0.6.1 起）：keys / devices / account 变更 → 重新拉取（连续多条合并成一次），不认识的 kind 忽略
        if model.support("sync.settings") != .needsServerUpdate {
            let mk = { (k: String) in APIClient.MsgChange(seq: 0, id: 0, kind: k, state: nil) }
            let before = model.settingsRefreshCount, kr = model.keysRevision, ar = model.accountRevision
            model.applyChanges([mk("keys"), mk("keys"), mk("devices"), mk("account"), mk("future-kind")])
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            check(model.settingsRefreshCount.keys == before.keys + 1 && model.settingsRefreshCount.account == before.account + 1
                  && model.keysRevision == kr + 1 && model.accountRevision == ar + 1 && model.state != .unauthorized,
                  "设置同步：keys×2、devices、account 合并成一次 key 刷新和一次账户刷新")
            let b2 = model.settingsRefreshCount
            model.applyChanges([mk("future-kind")])
            try? await Task.sleep(nanoseconds: 600_000_000)
            check(model.settingsRefreshCount == b2 && model.keysRevision == kr + 1, "设置同步：不认识的 kind 忽略")
            do {
                let cursor = try await client.messageStates().changesNext
                let k = try await client.createKey(name: "同步测试", key: "")
                _ = try await client.revokeKey(id: k.id)
                try await client.deleteKey(id: k.id)
                let page = try await client.messagesPage(since: model.maxID, limit: 1, wait: 0, changesSince: cursor)
                check(page.changes.contains { $0.kind == "keys" && $0.id == 0 }, "设置同步：服务端新建 / 吊销 / 删除 key 后变更里有 keys（\(page.changes.map(\.kind))）")
            } catch {
                ng("设置同步：服务端变更失败：\(error.localizedDescription)")
            }
        }

        // 按条件清理：只选中频道 + 时间范围内、未收藏的
        model.merge([msg(9_000_021, "cleanup", "", 2, "旧日志"), msg(9_000_022, "cleanup", "", 4, "旧重要"), msg(9_000_023, "keep", "", 2, "别的频道")], notify: false)
        model.toggleStar(9_000_022)
        var rule = AppModel.CleanupRule()
        rule.topic = "cleanup"
        rule.olderThanDays = 30
        check(model.cleanupTargets(rule, now: later).map(\.id) == [9_000_021], "清理：按频道 + 时间，收藏的跳过")
        rule.includeStarred = true
        rule.maxPriority = 2
        check(model.cleanupTargets(rule, now: later).map(\.id) == [9_000_021], "清理：按优先级上限筛选")
        check(model.cleanupTargets(rule, now: base).isEmpty, "清理：未到时间的不选")
        model.removeLocal([9_000_021, 9_000_022, 9_000_023])
        check(!model.messages.contains { $0.id > 9_000_000 }, "本地移除测试消息")
    }

    @MainActor static func channelTests(client: APIClient, model: AppModel, server: URL, pushkey: String) async {
        // 排序规则（纯逻辑）：置顶 → 手动顺序 → 最近活跃
        var st: [String: APIClient.ChannelSetting] = [:]
        st["c"] = .init(topic: "c", pinned: true)
        st["b"] = .init(topic: "b", sort: 1)
        let last: [String: Int64] = ["a": 30, "b": 10, "c": 5, "d": 20]
        check(AppModel.orderChannels(["a", "b", "c", "d"], settings: st, last: last) == ["c", "b", "a", "d"], "频道顺序：置顶、手动顺序、最近活跃")
        check(AppModel.moved(["a", "b", "c"], "a", to: "c") == ["b", "c", "a"] && AppModel.moved(["a", "b", "c"], "c", to: "a") == ["c", "a", "b"],
              "拖动：往下拖排在目标后面，往上拖排在目标前面")
        var ms: [String: APIClient.ChannelSetting] = [:]
        for (i, t) in ["x", "hid", "y", "z"].enumerated() { ms[t] = .init(topic: t, sort: i + 1) }
        check(AppModel.mergedOrder(["z", "x", "y", "new"], settings: ms) == ["z", "hid", "x", "y", "new"],
              "排序时看不到的频道（隐藏的）保留原位置")

        guard model.canManageChannels else { ng("服务端不支持频道设置"); return }
        do {
            for (t, p) in [("ch-a", 3), ("ch-b", 3), ("ch-c", 3), ("ch-c", 5)] {
                try await pushMultipart(server: server, pushkey: pushkey, text: "频道 \(t)", desp: "", priority: p, fileName: nil, fileData: nil, topic: t)
            }
            model.merge(try await client.allMessages(since: model.maxID), notify: false)
        } catch {
            ng("发送频道测试消息失败：\(error.localizedDescription)")
            return
        }
        check(await model.updateChannel("ch-a", alias: "  训练  任务 "), "改显示名")
        check(model.channelName("ch-a") == "训练 任务" && model.channelName("ch-b") == "ch-b", "显示名生效（空白规范化），没改的用原名")
        model.searchText = "训练 任务"
        check(model.groups.contains { $0.latest.topic == "ch-a" }, "按显示名能搜到")
        model.searchText = ""
        check(await model.updateChannel("ch-b", pinned: true), "置顶")
        check(model.topics.first?.name == "ch-b", "置顶的频道排在最前")
        await model.setChannelOrder(["ch-b", "ch-c", "ch-a"])
        let order = model.topics.map(\.name).filter { $0.hasPrefix("ch-") }
        check(order == ["ch-b", "ch-c", "ch-a"], "手动排序：\(order.joined(separator: " "))")
        check(await model.updateChannel("ch-c", hidden: true), "隐藏")
        check(!model.topics.contains { $0.name == "ch-c" } && model.hiddenChannels.contains { $0.name == "ch-c" }
              && !model.inbox.contains { $0.topic == "ch-c" }, "隐藏的频道不在列表和收件箱里，在「已隐藏」里")
        model.filter = .topic("ch-c")
        check(model.groups.count == 2, "点开隐藏的频道能看到它的消息")
        model.filter = .all
        check(await model.updateChannel("ch-a", muted: true), "静音")
        // 服务端也按频道标静默
        if let page = try? await client.messagesPage(since: model.maxID - 4, limit: 10) {
            let reasons = page.messages.map { "\($0.topic):\($0.priority):\($0.silent)" }
            check(page.messages.first { $0.topic == "ch-c" && $0.priority == 5 }?.silent == true, "服务端：隐藏频道的紧急消息也静默（\(reasons.joined(separator: " "))）")
        }
        // 另一台设备（同账号）看到同样的设置
        await model.refreshChannels()
        check(model.channel("ch-a").muted && model.channel("ch-a").alias == "训练 任务" && model.channel("ch-c").hidden && model.channel("ch-b").pinned,
              "重新拉取后设置一致")
        await model.setChannelOrder([])
        check(!model.hasManualChannelOrder, "恢复按最近活跃排序")
        let cIDs = model.messages.filter { $0.topic == "ch-c" }.map(\.id)
        check(await model.deleteChannel("ch-c"), "删除频道")
        check(!model.messages.contains { $0.topic == "ch-c" } && model.channelSettings["ch-c"] == nil, "频道的消息和设置都删掉了")
        if let states = try? await client.messageStates().items {
            check(cIDs.count == 2 && cIDs.allSatisfy { states[$0] == nil }, "服务端也没有这个频道的消息了")
        } else {
            ng("对账接口不可用")
        }
        await model.deleteChannel("ch-a")
        await model.deleteChannel("ch-b")
        check(!model.messages.contains { $0.topic.hasPrefix("ch-") } && model.channelSettings.isEmpty, "清理测试频道")
    }

    @MainActor static func uiLogicTests() {
        // 线程折叠
        let ms = [msg(1, "train", "exp42", 4, "开始"), msg(2, "infra", "", 5, "磁盘"),
                  msg(3, "train", "exp42", 2, "epoch 10"), msg(4, "train", "exp42", 3, "评估", att: 2),
                  msg(5, "train", "exp43", 4, "开始")]
        let read: Set<Int64> = [1, 2]
        let g = groupThreads(ms, all: ms, read: read)
        check(g.map(\.id) == ["t:train\u{1}exp43", "t:train\u{1}exp42", "m:2"], "线程折叠为 3 组且按最新排序")
        let e42 = g[1]
        check(e42.total == 3 && e42.messages.count == 3 && e42.latest.id == 4, "exp42 共 3 条，最新 #4")
        check(e42.unread == 2 && e42.displayPriority == 3, "未读 2 条，视觉优先级取未读中最高 P3")
        check(e42.attachmentCount == 2, "线程附件计数 2")
        let filtered = groupThreads(ms.filter { $0.priority >= 4 }, all: ms, read: read)
        check(filtered.first { $0.id == "t:train\u{1}exp42" }?.total == 3, "筛选后线程总数仍为 3")

        // 摘要
        let sum = plainSummary("## 结果\n**粗体** 与 `代码`\n\n- a\n- b\n\n```\nprint(1)\n```")
        check(sum == "结果 粗体 与 代码 a；b print(1)", "摘要去掉 Markdown：“\(sum)”")
        check(plainSummary(String(repeating: "长", count: 200), limit: 10).count == 11, "摘要按长度截断并加省略号")

        // Markdown 块
        let blocks = parseMarkdownBlocks("# 标题\n第一段\n续行\n\n- x\n- y\n\n1. 一\n2. 二\n\n> 引用\n\n```python\nprint(1)\n```\n---")
        check(blocks == [.heading(1, "标题"), .paragraph("第一段\n续行"), .bullet(["x", "y"]), .ordered(["一", "二"]),
                         .quote("引用"), .code("python", "print(1)"), .rule], "Markdown 块解析 \(blocks.count) 块")

        // 文件类型
        let kinds = [("loss.png", "image/png", FileKind.image), ("report.pdf", "application/pdf", .pdf),
                     ("周报.docx", "application/octet-stream", .word), ("metrics.xlsx", "", .excel), ("a.csv", "text/csv", .excel),
                     ("ckpt.zip", "application/zip", .archive), ("train.log", "text/plain", .text), ("x.bin", "application/octet-stream", .other),
                     ("slides.pptx", "", .ppt)]
        let bad = kinds.filter { FileKind.of(name: $0.0, mime: $0.1) != $0.2 }.map(\.0)
        check(bad.isEmpty, "文件类型判定 \(kinds.count) 例\(bad.isEmpty ? "" : "，错误：\(bad)")")

        // 通知规则
        var p = NotifyPrefs()
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let night = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: Date())!
        check(p.decide(priority: 3, now: noon, pausedUntil: nil) == (true, false), "默认 P3 弹出不响")
        check(p.decide(priority: 4, now: noon, pausedUntil: nil) == (true, true), "默认 P4 弹出且响")
        check(p.decide(priority: 2, now: noon, pausedUntil: nil) == (false, false), "默认 P2 不弹")
        let paused = noon.addingTimeInterval(3600)
        check(p.decide(priority: 4, now: noon, pausedUntil: paused) == (false, false)
              && p.decide(priority: 5, now: noon, pausedUntil: paused) == (true, true), "暂停期间只放行 P5")
        p.quietEnabled = true
        check(p.decide(priority: 4, now: night, pausedUntil: nil) == (false, false)
              && p.decide(priority: 5, now: night, pausedUntil: nil) == (true, true)
              && p.decide(priority: 4, now: noon, pausedUntil: nil) == (true, true), "免打扰 23:00–08:00：02:00 只放行 P5，中午正常")

        // 时间
        let now = Date()
        check(TimeFmt.relative(now.addingTimeInterval(-20), now: now) == "刚刚"
              && TimeFmt.relative(now.addingTimeInterval(-300), now: now) == "5 分钟前", "相对时间：刚刚 / 5 分钟前")
    }

    @MainActor static func accountTests(server: URL, token: String, adminCode: String?) async {
        let c = APIClient(server: server, token: token)
        do {
            let me = try await c.me()
            check(me.can_admin == false && (me.admin_url ?? "").hasPrefix("http"), "/v1/me：普通设备 can_admin=false，admin_url=\(me.admin_url ?? "")")
        } catch { ng("/v1/me 失败：\(error.localizedDescription)") }
        do {
            _ = try await c.adminLink()
            ng("未授权设备居然拿到了管理链接")
        } catch APIError.http(403, let m) {
            ok("未授权设备申请管理链接返回 403（\(m)）")
        } catch { ng("错误类型不对：\(error)") }

        guard let adminCode else { print("    （未提供 --admin-code，跳过授权设备测试）"); return }
        do {
            let r = try await APIClient.pair(server: server, code: adminCode, name: "selftest-admin", fingerprint: String(repeating: "cd", count: 32))
            let ac = APIClient(server: server, token: r.token)
            let me = try await ac.me()
            check(me.can_admin == true, "带 can_admin 的配对码配出的设备 can_admin=true")
            let url = try await ac.adminLink()
            check(url.absoluteString.contains("/auth/link?t=L_"), "拿到一次性链接 \(url.absoluteString.prefix(48))…")
            let (code1, cookie1) = await fetchNoRedirect(url)
            if code1 == 404 {
                print("    （服务端管理页暂未实现 /auth/link，跳过链接登录验证）")
            } else {
                check(code1 == 303 && cookie1.contains("huijian_admin="), "打开链接：HTTP \(code1)，设置了登录 Cookie")
                let (code2, cookie2) = await fetchNoRedirect(url)
                check(!cookie2.contains("huijian_admin=") || code2 != 303, "同一链接第二次使用无效（HTTP \(code2)）")
            }
        } catch { ng("授权设备测试失败：\(error.localizedDescription)") }
    }

    final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func fetchNoRedirect(_ url: URL) async -> (Int, String) {
        let s = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        guard let (_, resp) = try? await s.data(from: url), let h = resp as? HTTPURLResponse else { return (0, "") }
        return (h.statusCode, h.value(forHTTPHeaderField: "Set-Cookie") ?? "")
    }

    /// 前提（由 tests/selftest.sh 准备）：hub 上已发布 build = 当前+1 的测试包，用测试私钥签名；
    /// target 是当前 App 的一份副本。最后会启动替换脚本，等本进程退出后把 target 换成新版本，由 selftest.sh 检查结果。
    @MainActor static func updateTests(client: APIClient, engine: DownloadEngine, publicKey: String, workDir: URL, target: URL) async {
        let cur = AppInfo.build
        guard let info = try? await client.update(build: cur) else { ng("查询更新失败"); return }
        check(info.build == cur + 1, "查到新版本 build \(info.build)（当前 \(cur)）")
        do {
            let none = try await client.update(build: info.build)
            check(none == nil, "已是最新版本时返回 nil")
        } catch {
            ng("已是最新版本时查询出错：\(error)")
        }
        let page = try? await client.messagesPage(since: Int64.max / 2, limit: 1)
        check(page?.latestBuild == info.build, "长轮询响应头带最新构建号 \(page?.latestBuild ?? -1)")

        check((try? UpdateVerifier.verifySignature(info, publicKey: publicKey)) != nil, "Ed25519 签名校验通过（与 Go 端签名格式一致）")
        let forged = UpdateInfo(id: info.id, version: "9.9.9", build: info.build, notes: "", size: info.size,
                                sha256: info.sha256, signature: info.signature, url: info.url)
        check((try? UpdateVerifier.verifySignature(forged, publicKey: publicKey)) == nil, "篡改版本号后签名校验失败")
        let forgedNotes = UpdateInfo(id: info.id, version: info.version, build: info.build, notes: "请到 xxx 手动下载", size: info.size,
                                     sha256: info.sha256, signature: info.signature, url: info.url)
        check((try? UpdateVerifier.verifySignature(forgedNotes, publicKey: publicKey)) == nil, "篡改更新说明后签名校验失败")
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        check((try? UpdateVerifier.verifySignature(info, publicKey: otherKey)) == nil, "换一把公钥校验失败")
        check((try? UpdateVerifier.verifySignature(info, publicKey: "")) == nil, "未内置公钥时拒绝更新")

        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let app: URL
        do {
            var last = 0.0
            var lastAtVerify = -1.0
            let t0 = Date()
            app = try await UpdatePreparer.prepare(info, request: try UpdatePreparer.downloadRequest(info, client: client), engine: engine, workDir: workDir, publicKey: publicKey,
                                                   currentApp: Bundle.main.bundleURL, bundleID: bundleID,
                                                   onVerify: { lastAtVerify = last }) { last = $0 }
            check(lastAtVerify >= 0.99, String(format: "下载完成（进度 %.0f%%）后才进入「校验」阶段；下载 + 校验共 %.2f 秒", lastAtVerify * 100, Date().timeIntervalSince(t0)))
            ok("下载、sha256、解压、Bundle 与代码签名校验全部通过（进度 \(Int(last * 100))%）")
        } catch {
            ng("准备更新失败：\(Updater.describe(error))")
            return
        }
        let mismatched = UpdateInfo(id: info.id, version: info.version, build: info.build + 1, notes: "", size: info.size,
                                    sha256: info.sha256, signature: info.signature, url: info.url)
        check((try? UpdateVerifier.checkBundle(app, info: mismatched, bundleID: bundleID)) == nil, "包内版本号与发布信息不符时拒绝")
        check((try? UpdateVerifier.checkBundle(app, info: info, bundleID: "com.example.other")) == nil, "Bundle ID 不同时拒绝")

        // 代码签名身份：当前 App 用固定证书签名时，ad-hoc 签名的包必须被拒绝
        let dr = UpdateVerifier.designatedRequirement(of: Bundle.main.bundleURL)?.text ?? ""
        if dr.contains("certificate leaf") {
            let adhoc = workDir.appendingPathComponent("adhoc/Huijian.app")
            try? FileManager.default.createDirectory(at: adhoc.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: app, to: adhoc)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            p.arguments = ["--force", "--deep", "-s", "-", "--identifier", bundleID, adhoc.path]
            p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            check((try? UpdateVerifier.checkCodeSignature(newApp: adhoc, currentApp: Bundle.main.bundleURL)) == nil,
                  "签名证书不同（ad-hoc）的包被拒绝")
        } else {
            print("    当前为 ad-hoc 签名，跳过证书一致性检查（配置 SIGN_IDENTITY 后会检查）")
        }
        check((try? UpdateVerifier.installTarget(target)) != nil, "安装位置可写")
        check((try? UpdateVerifier.installTarget(URL(fileURLWithPath: "/System/Applications/Calculator.app"))) == nil, "不可写位置被拒绝")

        // 启动替换脚本：等本进程退出后替换 target（不重新打开），由 selftest.sh 验证
        do {
            try UpdateInstaller.launch(newApp: app, target: target, waitPID: getpid(),
                                       log: workDir.appendingPathComponent("install.log"), relaunch: false)
            ok("替换脚本已启动，等待自检进程退出后执行")
        } catch {
            ng("启动替换脚本失败：\(error)")
        }
    }

    @MainActor static func networkTests(server: URL, token: String, model: AppModel, opts: [String: String], workDir: URL) async {
        // 纯逻辑
        var c = ProxyConfig(enabled: true, kind: .http, host: "127.0.0.1", port: 7890, forUpdates: true, forServer: false)
        let du = c.dictionary(for: .updates) ?? [:], ds = c.dictionary(for: .server)
        check(du[kCFNetworkProxiesHTTPSProxy as String] as? String == "127.0.0.1" && du[kCFNetworkProxiesHTTPSPort as String] as? Int == 7890,
              "HTTP 代理：更新范围生效（含 HTTPS）")
        check(ds == nil, "未勾选服务器连接时，服务器连接按系统网络设置")
        c.kind = .socks5
        check(c.dictionary(for: .updates)?[kCFNetworkProxiesSOCKSProxy as String] as? String == "127.0.0.1", "SOCKS5 代理字典")
        c.enabled = false
        check(c.dictionary(for: .updates) == nil, "关闭代理后按系统网络设置（不强制直连）")
        check(!ProxyConfig(enabled: true, host: " ", port: 7890).valid && !ProxyConfig(enabled: true, port: 0).valid, "空地址 / 端口 0 视为无效")

        let att = Attachment(id: "a", name: "x.png", mime: "image/png", size: 9 << 20, sha256: "")
        let big = Attachment(id: "b", name: "y.zip", mime: "application/zip", size: 11 << 20, sha256: "")
        let now = Date()
        check(AutoDownload.should(att, messageDate: now, limitMB: 10, retentionHours: 24, alreadyLocal: false, now: now), "9MB ≤ 10MB 自动下载")
        check(!AutoDownload.should(big, messageDate: now, limitMB: 10, retentionHours: 24, alreadyLocal: false, now: now), "11MB > 10MB 需要点击")
        check(AutoDownload.should(big, messageDate: now, limitMB: -1, retentionHours: 24, alreadyLocal: false, now: now), "不限时大文件也自动下载")
        check(!AutoDownload.should(att, messageDate: now, limitMB: 0, retentionHours: 24, alreadyLocal: false, now: now), "关闭时不自动下载")
        check(!AutoDownload.should(att, messageDate: now.addingTimeInterval(-25 * 3600), limitMB: 10, retentionHours: 24, alreadyLocal: false, now: now),
              "超过保留期的旧消息不自动下载")
        check(!AutoDownload.should(att, messageDate: now, limitMB: 10, retentionHours: 24, alreadyLocal: true, now: now), "已下载的不重复下载")

        // 自动下载：真实发一条带小附件的消息，确认收到后自动落地
        model.autoDownloadLimitMB = 10
        let since = model.maxID
        try? await pushMultipart(server: server, pushkey: currentPushkey, text: "auto-dl", desp: "", priority: 3,
                                 fileName: "auto.bin", fileData: Data(repeating: 7, count: 300_000))
        let client = APIClient(server: server, token: token)
        if let fresh = try? await client.messages(since: since, limit: 10, wait: 5), let m = fresh.last, let a = m.attachments.first {
            model.autoDownload(model.merge(fresh, notify: false))
            for _ in 0..<50 where model.localFiles[a.id] == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            check(model.localFiles[a.id] != nil, "新消息的 300KB 附件已自动下载")
        } else {
            ng("没有收到自动下载测试消息")
        }
        model.autoDownloadLimitMB = 0

        guard let ghPort = opts["--mock-gh-port"], let pxPort = Int(opts["--mock-proxy-port"] ?? ""), let logPath = opts["--mock-log"],
              let ghPub = opts["--gh-pub"], let ghBuild = Int(opts["--gh-build"] ?? "") else {
            print("    未提供模拟服务参数，跳过代理与 GitHub 联网测试")
            return
        }
        func logLines() -> [String] { ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

        // 服务器连接走代理
        let before = logLines().count
        NetSessions.shared.update(ProxyConfig(enabled: true, kind: .http, host: "127.0.0.1", port: pxPort, forUpdates: false, forServer: true))
        let me1 = try? await client.me()
        let viaProxy = logLines().dropFirst(before).contains { $0.hasPrefix("PROXY ") && $0.contains("/v1/me") }
        check(me1 != nil && viaProxy, "勾选「服务器连接」后，API 请求经过代理")
        let eng = DownloadEngine(scope: .server)
        let dl = workDir.appendingPathComponent("healthz.txt")
        _ = try? await eng.download(URLRequest(url: client.url("/healthz")), expectedSize: 3, to: dl) { _ in }
        check(logLines().dropFirst(before).contains { $0.hasPrefix("PROXY ") && $0.contains("/healthz") }, "附件下载引擎也经过代理")
        NetSessions.shared.update(ProxyConfig(enabled: true, kind: .http, host: "127.0.0.1", port: pxPort, forUpdates: true, forServer: false))
        let mid = logLines().count
        _ = try? await client.me()
        check(!logLines().dropFirst(mid).contains { $0.contains("/v1/me") }, "取消勾选后，服务器连接不再经过代理")

        // GitHub 更新源（经代理）
        let ghBase = "http://127.0.0.1:\(ghPort)"
        setenv("HUIJIAN_GITHUB_API", ghBase, 1)
        let g0 = logLines().count
        do {
            let info = try await GitHubUpdates.latest(repo: "test/huijian", session: APIClient.updateSession)
            check(info.build == ghBuild && info.url.hasPrefix(ghBase), "从 GitHub Releases 读到 build \(info.build) 的签名清单")
            check((try? UpdateVerifier.verifySignature(info, publicKey: ghPub)) != nil, "GitHub 清单签名校验通过")
            let req = try UpdatePreparer.downloadRequest(info, client: client)
            check(req.value(forHTTPHeaderField: "Authorization") == nil, "发往 GitHub 的下载请求不带设备 token")
            let upEng = DownloadEngine(scope: .updates)
            let app = try await UpdatePreparer.prepare(info, request: req, engine: upEng, workDir: workDir, publicKey: ghPub,
                                                       currentApp: Bundle.main.bundleURL, bundleID: Bundle.main.bundleIdentifier ?? "") { _ in }
            check(FileManager.default.fileExists(atPath: app.path), "GitHub 更新包下载、校验、解压通过")
            let lines = logLines().dropFirst(g0)
            check(lines.contains { $0.hasPrefix("PROXY ") && $0.contains("/releases/latest") }
                  && lines.contains { $0.hasPrefix("PROXY ") && $0.contains("/dl/") }, "更新检查和下载都经过代理")
            check(!lines.contains { $0.hasPrefix("GH AUTH") }, "GitHub 侧没有收到任何 Authorization 头")
        } catch {
            ng("GitHub 更新源测试失败：\(Updater.describe(error))")
        }
        let unsafe = UpdateInfo(id: 0, version: "1", build: 1, notes: "", size: 1, sha256: "", signature: "", url: "http://example.com/x.zip")
        check((try? UpdatePreparer.downloadRequest(unsafe, client: client)) == nil, "非 https 的外部更新地址被拒绝")
        unsetenv("HUIJIAN_GITHUB_API")
        NetSessions.shared.update(ProxyConfig())
    }

    @MainActor static var currentPushkey = ""

    @discardableResult
    @MainActor static func selfServiceTests(client normal: APIClient, model: AppModel, server: URL, keysCode: String?) async -> APIClient? {
        do {
            _ = try await normal.listKeys()
            ok("0.5.0 起本账号的设备都能管理 pushkey（不需要服务器管理权限）")
        } catch { ng("列出 pushkey 失败：\(error)") }
        // 用不同的设备指纹，模拟另一台设备（同一台 Mac 的指纹会沿用本机的设备记录，让本机旧 token 失效）
        let otherFP = String(repeating: "ab", count: 32)
        guard let keysCode, let pr = try? await APIClient.pair(server: server, code: keysCode, name: "自检管理设备", fingerprint: otherFP) else {
            ng("没有提供 / 无法使用允许管理的配对码，跳过 pushkey 测试")
            return nil
        }

        let client = APIClient(server: server, token: pr.token)
        do {
            try await model.renameDevice("  自检 Mac 改名  ")
            let me = try await normal.me()
            check(me.name == "自检 Mac 改名" && model.deviceName == me.name, "本机改名同步到服务器：\(me.name)")
            check(me.device_id.wholeMatch(of: #/d_[0-9]{14}_[0-9a-f]{4}/#) != nil, "设备 ID 为时间戳格式：\(me.device_id)")
        } catch { ng("改名失败：\(Updater.describe(error))") }

        let custom = "selftest-key-\(Int(Date().timeIntervalSince1970))"
        do {
            let before = try await client.listKeys()
            check(!before.isEmpty, "列出 pushkey \(before.count) 把")
            let auto = try await client.createKey(name: "自动生成", key: "")
            check(auto.key.hasPrefix("PK_"), "留空时服务端自动生成 key")
            let k = try await client.createKey(name: "自定义", key: custom)
            check(k.key == custom, "新建自定义 key")
            let upd = try await client.updateKey(id: k.id, name: "自定义改名", key: custom + "-v2")
            let after = try await client.listKeys().first { $0.id == k.id }
            check(upd.name == "自定义改名" && upd.key == custom + "-v2" && after == upd, "改名并更换 key（返回值与列表一致）")
            do {
                _ = try await client.createKey(name: "x", key: "short")
                ng("太短的 key 应被拒绝")
            } catch { ok("太短的 key 被服务端拒绝（\(Updater.describe(error))）") }
            let rv = try await client.revokeKey(id: k.id)
            try await client.revokeKey(id: auto.id)
            let listed = try await client.listKeys().first { $0.id == k.id }
            check(rv.revoked && listed?.revoked == true, "吊销后状态为已吊销")
        } catch { ng("pushkey 管理失败：\(Updater.describe(error))") }

        // 草稿校验（界面逻辑）
        var d = KeyDraft.new()
        check(d.validationError == nil && d.dirty, "新建草稿：key 留空 = 自动生成")
        d.key = "short"
        check(d.validationError != nil, "草稿：太短的 key 标出错误")
        d.key = "valid_key-1234567890"
        d.name = " "
        check(d.validationError != nil, "草稿：空名称标出错误")
        let srv = APIClient.PushKey(id: 1, name: "a", key: "PK_aaaaaaaaaaaaaaaa", created_at: Date(), last_used: nil, revoked: false)
        var e = KeyDraft(server: srv)
        check(!e.dirty && !e.replacesKey, "服务器上的 key 未修改时不算改动")
        e.key = "PK_bbbbbbbbbbbbbbbb"
        check(e.dirty && e.replacesKey, "改了 key 内容会提示旧 key 失效")
        return client
    }

    @MainActor static func compatStorageTests(normal: APIClient, admin: APIClient?, model: AppModel, workdir: URL) async {
        // 版本协商
        do {
            let info = try await normal.info()
            check(info.name == "huijian" && !info.version.isEmpty && info.features.contains { $0.id == "storage" },
                  "/v1/info：服务端 \(info.version)，\(info.features.count) 项功能")
            check(ServerVersionSeen.current == info.version, "响应头 X-Huijian-Server 已记录")
        } catch { ng("/v1/info 失败：\(Updater.describe(error))") }
        model.refreshServerInfo()
        for _ in 0..<30 where model.serverInfo == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        check(model.support("storage") == .yes && model.support("keys") == .yes, "功能清单：storage / keys 可用")
        check(model.featuresNeedingServerUpdate.isEmpty && model.featuresNeedingClientUpdate.isEmpty, "客户端与服务端功能一致")

        // 接口不存在的判断（旧服务端）
        do {
            let (d, r) = try await APIClient.apiSession.data(for: normal.request("/v1/no-such-feature"))
            try APIClient.check(r, d)
            ng("不存在的接口没有报错")
        } catch APIError.unsupported { ok("服务端没有的接口识别为「更新服务端后可用」") } catch { ng("预期 unsupported，实际 \(error)") }
        func resp(_ code: Int, _ ct: String = "text/plain; charset=utf-8") -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "http://x")!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": ct])!
        }
        check((try? APIClient.check(resp(405), Data())) == nil, "405 视为接口不存在")
        do { try APIClient.check(resp(404, "text/html"), Data("<html>404</html>".utf8)); ng("HTML 404 没有报错") }
        catch APIError.unsupported { ng("反向代理 / 填错地址的 HTML 404 不应判成服务端较旧") } catch { ok("HTML 404 按普通错误处理（地址问题，不是版本问题）") }
        do { try APIClient.check(resp(404), Data(#"{"error":"附件不存在"}"#.utf8)); ng("业务 404 没有报错") }
        catch APIError.http(404, let m) { check(m == "附件不存在", "业务上的 404（带 JSON）不算接口不存在") } catch { ng("业务 404：\(error)") }
        check((try? APIClient.check(resp(202), Data())) != nil, "202 视为成功")
        let legacyInfo: APIClient.ServerInfo? = nil
        check(AppModel.support("storage", info: legacyInfo, legacy: true) == .needsServerUpdate
              && AppModel.support("keys", info: nil, legacy: true) == .unknown, "旧服务端：存储需更新服务端，pushkey 先尝试")
        let future = APIClient.ServerInfo(name: "huijian", version: "9.0.0", api: 9,
                                          features: [.init(id: "push", title: "发送", since: "0.1.0"), .init(id: "future.x", title: "未来功能", since: "9.0.0")])
        check(AppModel.support("keys", info: future, legacy: false) == .needsServerUpdate, "服务端功能清单里没有的功能：需更新服务端")
        check(future.features.filter { AppModel.knownFeatures[$0.id] == nil }.map(\.id) == ["future.x"], "客户端不认识的功能：提示更新客户端")

        // 服务端存储与备份
        do {
            _ = try await normal.storage()
            ng("没有管理权限的设备不应能查看存储")
        } catch APIError.http(403, _) { ok("没有管理权限查看存储返回 403") } catch { ng("预期 403：\(error)") }
        if let admin {
            do {
                let s = try await admin.storage(fresh: true)
                check(s.files_ok && s.backup_enabled, "存储状态：附件目录可用，备份已开启（\(s.files_dir)）")
                let started = try await admin.startBackup()
                check(started.running || started.last != nil, "开始备份")
                var last = started
                for _ in 0..<50 where last.running { try? await Task.sleep(nanoseconds: 200_000_000); last = try await admin.storage() }
                check(!last.running && last.last?.ok == true && (last.last?.db ?? "").hasPrefix("huijian-"),
                      "备份完成：\(last.last?.db ?? "-")，\(last.last?.reason ?? "")")
            } catch { ng("存储 / 备份失败：\(Updater.describe(error))") }
        } else {
            ng("没有允许管理的设备，跳过存储测试")
        }

        // 附件保存位置：按日期分目录、更换位置并搬移
        let cdir = workdir.appendingPathComponent("cache-test")
        let c = AttachmentCache(baseDir: cdir.appendingPathComponent("a"), indexFile: cdir.appendingPathComponent("idx.json"))
        let d1 = c.destination(for: "图.png")
        let ymd = DateFormatter(); ymd.locale = Locale(identifier: "en_US_POSIX"); ymd.dateFormat = "yyyy/MM/dd"
        check(d1.path.hasSuffix("/a/\(ymd.string(from: Date()))/图.png"), "新附件按 年/月/日 保存")
        try? FileManager.default.createDirectory(at: d1.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: d1.path, contents: Data("x".utf8))
        check(c.destination(for: "图.png").lastPathComponent == "图 (2).png", "重名时加序号")
        check(AttachmentCache.safeName(".hidden") == "_.hidden", "不生成隐藏文件")

        let att = model.messages.flatMap(\.attachments).first { $0.size < 1 << 20 }
        if let att {
            await model.download(att)
            let before = model.localFiles[att.id]
            check(before != nil, "下载一个附件用于搬移测试")
            let newDir = workdir.appendingPathComponent("nas-sim/回笺附件")
            let msg = await model.setAttachmentDir(newDir, move: true)
            let after = model.localFiles[att.id]
            check(after?.path.hasPrefix(newDir.standardizedFileURL.path) == true && FileManager.default.fileExists(atPath: after?.path ?? "")
                  && !FileManager.default.fileExists(atPath: before?.path ?? "/nonexistent-x"), "更换位置并搬移：\(msg)")
            check(!model.attachmentDirIsDefault && model.defaults.string(forKey: AppModel.key("attachmentDir")) == newDir.standardizedFileURL.path, "新位置已保存")
            model.retentionHours = -1
            model.cache.setDownloadedAt(att.id, Date().addingTimeInterval(-400 * 24 * 3600))
            check(model.runCleanup().isEmpty && model.localFiles[att.id] != nil, "永久保留：一年前的附件也不清理")
            model.retentionHours = 24
            _ = await model.setAttachmentDir(nil, move: true)
            check(model.attachmentDirIsDefault && model.localFiles[att.id]?.path.hasPrefix(model.paths.attDir.standardizedFileURL.path) == true,
                  "恢复默认位置，附件搬回")
            model.removeLocal(att.id)
        } else {
            ng("没有可用于搬移测试的附件")
        }

        // 配置导出 / 导入
        do {
            var cfg = model.exportConfig()
            let data = try { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return try e.encode(cfg) }()
            let back = try AppModel.decodeConfig(data)
            check(back.server == model.server && back.retentionHours == 24 && back.notify == model.prefs, "导出配置可以原样读回（不含 token：\(!String(decoding: data, as: UTF8.self).contains(model.token ?? "##")))")
            cfg.retentionHours = 72
            cfg.autoDownloadMB = 50
            cfg.server = "http://9.9.9.9:8790"
            cfg.attachmentDir = "/nonexistent/回笺"
            let items = await model.importConfig(cfg)
            var bad = cfg
            bad.notify?.show = [true]
            bad.autoDownloadMB = 12345
            _ = await model.importConfig(bad)
            check(model.prefs.show.count == 6 && model.autoDownloadLimitMB == 50, "导入不完整 / 越界的配置项会被跳过（不会崩溃）")
            check(model.retentionHours == 72 && model.autoDownloadLimitMB == 50, "导入：保留时长、自动下载上限已应用")
            check(model.server != "http://9.9.9.9:8790" && items.contains { $0.contains("未修改") && $0.contains("服务器") }, "已配对时不改服务器地址")
            check(items.contains { $0.contains("不存在") } && model.attachmentDirIsDefault, "导入的附件位置不存在时不切换")
            check((try? AppModel.decodeConfig(Data(#"{"format":"other"}"#.utf8))) == nil, "拒绝不是回笺的配置文件")
            model.retentionHours = 24
            model.autoDownloadLimitMB = AutoDownload.defaultLimitMB
        } catch { ng("配置导出导入失败：\(error)") }
    }

    @MainActor static func accountTests(normal: APIClient, other: APIClient?, model: AppModel, server: URL, pushkey: String) async {
        do {
            await model.refreshMe()
            check(model.account != nil && model.account?.has_password == false, "账号信息：第一个账号还没有密码")
            check(model.needsAccountSetup, "账号没有密码：主窗口显示「完成账号设置」，不进入消息界面")
            // 用户名规则与服务端 account_name_test.go 用同一组用例
            let okNames = ["me", "Alex Chen", "  Alex   Chen ", "张三", "张 三", "a.b-c_d", "Mary Jane Watson", "Alex\u{3000}Chen", "〇号", "第①组"]
            let badNames = ["a", "a/b", "a@b", "x\ty\nz!", "123456789012345678901234567890123", "Alex\u{3164}Chen", "\u{3164}\u{3164}", "a\u{200B}b", "e\u{301}x"]
            let wrongOK = okNames.filter { AppModel.usernameProblem($0) != nil }
            let wrongBad = badNames.filter { AppModel.usernameProblem($0) == nil }
            check(wrongOK.isEmpty && wrongBad.isEmpty && AppModel.normalizeUsername("  Alex   Chen ") == "Alex Chen",
                  "客户端用户名规则与服务端一致" + (wrongOK.isEmpty && wrongBad.isEmpty ? "" : "（误拒 \(wrongOK)，误放 \(wrongBad)）"))
            do {
                _ = try await normal.setCredentials(username: "自检用户", password: "selftest-pass-1", current: "")
                ng("没有管理权限的设备却设置了初始密码")
            } catch APIError.http(403, _) { ok("没有管理权限的设备不能设置初始密码") }
            guard let other else { ng("缺少允许管理的设备（--keys-code），无法继续账号测试"); return }
            let a = try await other.setCredentials(username: "自检用户", password: "selftest-pass-1", current: "")
            check(a.username == "自检用户" && a.has_password, "允许管理的设备设置用户名和密码")
            await model.refreshMe()
            check(!model.needsAccountSetup && model.accountName == "自检用户", "账号设置完成后放行，左下角显示用户名「\(model.accountName)」")
            do {
                _ = try await normal.setCredentials(username: "自检用户", password: "another-pass-2", current: "wrong")
                ng("已有密码时没提供正确的当前密码却改成功了")
            } catch APIError.http(403, _) { ok("修改密码需要当前密码") }
            do {
                _ = try await APIClient.login(server: server, username: "自检用户", password: "wrong-pass", name: "x", register: false)
                ng("密码错误却登录成功")
            } catch APIError.http(403, let m) { ok("密码错误被拒绝（\(m)）") }
            do {
                _ = try await APIClient.login(server: server, username: "新人", password: "newbie-pass", name: "x", register: true)
                ng("未开放注册却注册成功")
            } catch APIError.http(403, _) { ok("服务器未开放注册时不能注册") }

            let me = try await normal.me()
            let r = try await APIClient.login(server: server, username: "自检用户", password: "selftest-pass-1", name: "重装后的 Mac", register: false)
            check(r.reused == true && r.device_id == me.device_id && r.name == me.name, "同一台 Mac 用密码登录：沿用原设备记录（\(r.device_id)，名称仍是「\(r.name)」）")
            do { _ = try await normal.me(); ng("旧 token 应失效") } catch APIError.unauthorized { ok("旧 token 失效") }
            let c = APIClient(server: server, token: r.token)
            let d = try await c.account()
            let mine = d.devices.first { $0.current }
            check(mine?.pair_count ?? 0 >= 2 && mine?.pairings.first?.method == "password", "配对记录：\(mine?.pair_count ?? 0) 次，最近一次是密码登录")
            check(d.devices.contains { !$0.current && !$0.revoked }, "我的设备里能看到同账号的另一台设备")
            let pc = try await c.createPairCode()
            check(pc.count == 6, "为本账号生成配对码 \(pc)")

            // 本机接收规则：把发送用的 key 设为静默
            let keys = try await c.listKeys()
            guard let k = keys.first(where: { $0.key == pushkey }) else { ng("找不到发送用的 pushkey"); return }
            let subs = try await c.subscriptions()
            check(subs.items.contains { $0.pushkey_id == k.id && $0.mode == "notify" } && subs.awaySilent, "接收规则默认：提醒；在用设备优先默认开启")
            try await c.setSubscription(keyID: k.id, mode: "silent")
            let since = try await c.messagesPage(since: -1, limit: 1).messages.last?.id ?? 0
            try await pushMultipart(server: server, pushkey: pushkey, text: "静默测试", desp: "", priority: 4, fileName: nil, fileData: nil)
            try await pushMultipart(server: server, pushkey: pushkey, text: "紧急不静默", desp: "", priority: 5, fileName: nil, fileData: nil)
            let got = try await c.messages(since: since)
            check(got.map(\.text) == ["静默测试", "紧急不静默"] && got.map(\.silent) == [true, false] && got.first?.pushkeyID == k.id,
                  "本机设为静默：普通消息标记静默、紧急照常；消息带 pushkey_id")
            try await c.setSubscription(keyID: k.id, mode: "off")
            try await pushMultipart(server: server, pushkey: pushkey, text: "不接收测试", desp: "", priority: 4, fileName: nil, fileData: nil)
            let got2 = try await c.messages(since: got.last?.id ?? since)
            check(got2.isEmpty, "本机设为不接收：看不到这把 key 的新消息")
            try await c.setSubscription(keyID: k.id, mode: "notify")

            // 删除 pushkey：未吊销时拒绝（409），吊销后可以删除
            let tmp = try await c.createKey(name: "临时 key", key: "")
            do { try await c.deleteKey(id: tmp.id); ng("未吊销的 key 却删除成功") } catch APIError.http(409, _) { ok("未吊销的 key 不能删除") }
            try await c.revokeKey(id: tmp.id)
            try await c.deleteKey(id: tmp.id)
            check(!(try await c.listKeys()).contains { $0.id == tmp.id }, "吊销后删除：列表里不再出现")

            // 在用设备优先：另一台设备上报在用 → 本机普通消息静默
            do {
                try await other.presence()
                try await pushMultipart(server: server, pushkey: pushkey, text: "另一台在用", desp: "", priority: 3, fileName: nil, fileData: nil)
                let got3 = try await c.messages(since: got.last?.id ?? since).filter { $0.text == "另一台在用" }
                check(got3.first?.silent == true, "另一台设备正在使用：本机普通消息静默")
                try await c.setAwaySilent(false)
                let got4 = try await c.messages(since: got.last?.id ?? since).filter { $0.text == "另一台在用" }
                check(got4.first?.silent == false, "关掉「在用设备优先」后照常提醒")
            }

            // 静默消息不弹通知（界面逻辑）
            var m = got[0]
            m.silent = true
            check(m.silent && got[1].priority == 5, "静默标记会传到通知判断（merge 里跳过）")

            try await c.logout()
            do { _ = try await c.me(); ng("退出登录后 token 应失效") } catch APIError.unauthorized { ok("退出登录：token 立即失效") }
        } catch {
            ng("账号测试失败：\(Updater.describe(error))")
        }
    }

    @MainActor static func finish() -> Int32 {
        print("\n结果：通过 \(pass)，失败 \(fail)")
        return fail == 0 ? 0 : 1
    }

    static func pushMultipart(server: URL, pushkey: String, text: String, desp: String, priority: Int,
                              fileName: String?, fileData: Data?, topic: String? = nil) async throws {
        let boundary = "huijian-\(UUID().uuidString)"
        var body = Data()
        func field(_ k: String, _ v: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        field("pushkey", pushkey)
        field("text", text)
        field("desp", desp)
        field("priority", String(priority))
        if let topic { field("topic", topic) }
        field("topic", "selftest")
        if let fileName, let fileData {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        var r = URLRequest(url: APIClient(server: server, token: nil).url("/message/push"))
        r.httpMethod = "POST"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: r, from: body)
        try APIClient.check(resp, data)
    }
}
