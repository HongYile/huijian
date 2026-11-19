import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var testMsg: String?
    @State private var testing = false
    @State private var confirmLogout = false
    @State private var checking = false
    /// 登录凭证存放位置（查钥匙串是同步调用）：进入页面时在后台查一次
    @State private var credBackend: String?

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                BarkSection().id("bark")
                manageSection.id("manage")
                connectionSection.id("connection")
                notifySection.id("notify")
                accountSection.id("account")
                aboutSection.id("about")
            }
            .task {
                // 首页「可以更新了」横幅点进来：滚到「关于」；演示模式：直接滚到某一节（截图用）
                if let to = model.settingsAnchor ?? UserDefaults.standard.string(forKey: "demoScroll") {
                    model.settingsAnchor = nil
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    withAnimation { proxy.scrollTo(to, anchor: .top) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refreshAccount() }
        .task { credBackend = await Task.detached(priority: .utility) { Keychain.backend(account: "device-token") }.value }
        .confirmationDialog("退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { model.logout(notifyServer: true) }
        } message: {
            Text("这台手机将不再接收消息，本地消息记录和附件缓存会清除。")
        }
    }

    // MARK: 管理（和 Mac 客户端对齐：只用手机也能建 key、管设备和频道）

    private var manageSection: some View {
        Section {
            NavigationLink(value: Route.keys) {
                Label("Pushkey", systemImage: "key")
            }
            NavigationLink(value: Route.account) {
                LabeledContent {
                    Text(model.settings.username.isEmpty ? "未设置用户名" : model.settings.username).lineLimit(1)
                } label: {
                    Label("账户与设备", systemImage: "person.crop.circle")
                }
            }
            NavigationLink(value: Route.channels) {
                Label("频道", systemImage: "number")
            }
        } header: {
            Text("管理")
        } footer: {
            Text("新建、吊销 pushkey，修改用户名和密码，生成配对码添加设备、移除设备，频道改名、排序和删除。所有设备同步。")
        }
    }

    // MARK: 连接

    private var connectionSection: some View {
        Section {
            LabeledContent("连接状态") {
                Text(model.conn.text).foregroundStyle(model.conn.color)
            }
            LastContactRow(lastContact: model.lastContact)
            if !model.serverVersion.isEmpty { LabeledContent("服务端版本", value: model.serverVersion) }
            HStack {
                Text(testMsg ?? "给自己发一条 P4 测试推送，看多久能收到")
                    .font(.footnote)
                    .foregroundStyle(testMsg?.hasPrefix("发送失败") == true ? Theme.danger : Theme.text2)
                Spacer(minLength: 8)
                Button {
                    testing = true
                    testMsg = "发送中…"
                    Task {
                        do {
                            try await model.sendTestPush()
                            let f = DateFormatter()
                            f.dateFormat = "HH:mm:ss"
                            testMsg = "已发送 \(f.string(from: Date()))" + (model.bark != nil ? "，等 Bark 通知" : "，等它出现在列表里")
                        } catch {
                            testMsg = "发送失败：" + shortError(error)
                        }
                        testing = false
                    }
                } label: { Text("测试推送") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(testing)
            }
        } header: {
            Text("连接")
        } footer: {
            Text("App 在前台时实时接收；切到后台后由系统安排后台刷新，时间不固定。锁屏及时提醒请开启上面的 Bark 转发。")
        }
    }

    // MARK: 通知

    private var notifySection: some View {
        Section {
            LabeledContent("本地通知") {
                switch model.notifyAuth {
                case .authorized, .provisional, .ephemeral: Text("已允许").foregroundStyle(Theme.success)
                case .denied: Text("已关闭").foregroundStyle(Theme.danger)
                default: Text("未设置").foregroundStyle(Theme.text3)
                }
            }
            if model.notifyAuth == .notDetermined {
                Button("允许通知") { Task { await model.requestNotifyPermission() } }
            } else if model.notifyAuth == .denied {
                Button("去系统设置打开") {
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                }
            }
        } header: {
            Text("通知")
        } footer: {
            Text(model.bark != nil
                 ? "已开启 Bark 转发：锁屏提醒由 Bark 负责，回笺不再发本地通知（避免重复）。应用角标仍显示未读数。"
                 : "没开 Bark 时，回笺收到 P3 以上的新消息会发本地通知，但只有 App 在前台或系统安排后台刷新时才收得到。")
        }
    }

    // MARK: 账号

    private var accountSection: some View {
        Section("账号") {
            LabeledContent("用户", value: model.settings.username.isEmpty ? "（配对码登录）" : model.settings.username)
            LabeledContent("服务器") { Text(model.settings.server).lineLimit(1).truncationMode(.middle) }
            LabeledContent("本机", value: model.settings.deviceName)
            LabeledContent("设备 ID") { Text(model.settings.deviceID).font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle) }
            if let b = credBackend, b != "钥匙串" {
                LabeledContent("登录凭证存放") {
                    Text(b).font(.footnote).foregroundStyle(Theme.warning)
                }
            }
            Button("退出登录", role: .destructive) { confirmLogout = true }
        }
    }

    // MARK: 关于 / 更新

    private var aboutSection: some View {
        Section {
            LabeledContent("版本", value: "\(AppInfo.version) (build \(AppInfo.build))")
            if let u = model.update {
                VStack(alignment: .leading, spacing: 6) {
                    Label("新版本 \(u.version)（build \(u.build)）", systemImage: "arrow.down.circle.fill")
                        .font(.headline).foregroundStyle(Theme.accent)
                    if let n = u.notes, !n.isEmpty {
                        Text(n).font(.footnote).foregroundStyle(Theme.text2)
                    }
                }
                .padding(.vertical, 4)
            } else if model.latestBuild > AppInfo.build {
                Label("服务器上有新版本（build \(model.latestBuild)）", systemImage: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
            }
            if let u = model.update {
                UpdateDownloadRow(update: u)
            }
            if model.gboxSourceAvailable {
                if AppInfo.updatePublicKey.isEmpty {
                    // 没有内置更新公钥的构建（公开构建）：只能靠 GBox 软件源更新，直接展开
                    GBoxSteps(url: model.gboxSourceURL)
                } else if model.updateAvailable {
                    // 次要方式：GBox 软件源刷新不可靠（可能一天以上都不显示新版本），折叠起来
                    DisclosureGroup("也可以用 GBox 软件源（可能有延迟）") {
                        GBoxSteps(url: model.gboxSourceURL)
                    }
                    .font(.subheadline)
                    .tint(Theme.text2)
                }
            }
            Button {
                checking = true
                Task { await model.checkUpdate(); checking = false }
            } label: {
                HStack {
                    Text(model.updateAvailable ? "重新检查" : "检查更新")
                    if checking { Spacer(); ProgressView() }
                }
            }
            .disabled(checking)
            LabeledContent("许可", value: "AGPL-3.0")
        } header: {
            Text("关于")
        } footer: {
            if !model.updateAvailable {
                if AppInfo.updatePublicKey.isEmpty {
                    Text(model.gboxSourceAvailable
                         ? "这个版本通过 GBox 软件源更新：在 GBox → 软件源里添加一次上面的地址，有新版本时在 GBox 里点更新。"
                         : "这个版本不能在应用内更新，有新版本时请手动下载 IPA 用 GBox 安装。")
                } else {
                    Text("有新版本时，这里会出现「下载并用 GBox 安装」：回笺下载并校验安装包，然后交给 GBox 重签安装。")
                }
            }
        }
    }
}

/// 「最后一次和服务器通信」：每 5 秒只刷新这一行，不让整个设置页重算
private struct LastContactRow: View {
    let lastContact: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            LabeledContent("最后一次和服务器通信", value: TimeText.ago(lastContact, now: ctx.date))
        }
    }
}

/// 「下载并用 GBox 安装」：下载新版 IPA、校验 sha256 和签名，然后弹出「打开方式」，用户选 GBox 导入安装
private struct UpdateDownloadRow: View {
    @EnvironmentObject private var model: AppModel
    let update: UpdateInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.updateDownload {
            case .downloading(let p):
                ProgressView(value: p) {
                    Text("正在下载 \(UpdatePackage.fileName(update))").font(.subheadline)
                } currentValueLabel: {
                    Text("\(Int(p * 100))%" + (update.size.map { " · \(humanSize($0))" } ?? "")).font(.caption.monospacedDigit())
                }
            case .verifying:
                HStack(spacing: 8) { ProgressView(); Text("正在校验安装包（sha256 和签名）…").font(.subheadline) }
            case .ready:
                // 文件还在就直接再弹菜单，不在了（被系统清掉）就重新下载
                Button { model.downloadUpdate() } label: {
                    Label("用 GBox 打开", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text("安装包已下载并校验通过。在弹出的菜单里选 GBox，导入后在 GBox 里安装。")
                    .font(.footnote).foregroundStyle(Theme.text2)
            case .handedOff(_, true):
                Label("已交给 GBox", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success).font(.subheadline)
                Text("请到 GBox 里完成安装。没看到的话，可以再下载一次。").font(.footnote).foregroundStyle(Theme.text2)
                downloadButton(title: "重新下载")
            case .handedOff:
                // 系统分享面板：用户选的不一定是 GBox（可能是「存储到文件」等）
                Label("已分享", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success).font(.subheadline)
                Text("如果分享给了 GBox，请到 GBox 里完成安装；存到了「文件」的话，可以在 GBox 里导入这个文件。也可以再下载一次。")
                    .font(.footnote).foregroundStyle(Theme.text2)
                downloadButton(title: "重新下载")
            case .failed(let e):
                Text(e).font(.footnote).foregroundStyle(Theme.danger)
                downloadButton(title: "重试")
            case .idle:
                downloadButton(title: "下载并用 GBox 安装")
                if !AppInfo.updatePublicKey.isEmpty {
                    Text("回笺会下载安装包并校验，然后在弹出的菜单里选 GBox，导入后在 GBox 里安装。")
                        .font(.footnote).foregroundStyle(Theme.text2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func downloadButton(title: String) -> some View {
        Button { model.downloadUpdate() } label: {
            Label(title, systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(AppInfo.updatePublicKey.isEmpty)
        if AppInfo.updatePublicKey.isEmpty {
            // 构建时没有 UPDATE_PUBKEY：没法校验签名，不提供应用内下载
            Text("这个版本没有内置更新公钥，不能在应用内下载更新，请用下面的 GBox 软件源。")
                .font(.footnote).foregroundStyle(Theme.warning)
        }
    }
}

/// GBox 软件源地址 + 复制按钮 + 步骤
private struct GBoxSteps: View {
    let url: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GBox 软件源").font(.subheadline.weight(.medium))
            HStack {
                Text(url).font(.footnote.monospaced()).foregroundStyle(Theme.text2).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 6)
                Button(copied ? "已复制" : "复制") {
                    UIPasteboard.general.string = url
                    copied = true
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            Text("在 GBox → 软件源里添加一次这个地址，以后在 GBox 里点更新即可。")
                .font(.footnote).foregroundStyle(Theme.text2)
        }
        .padding(.vertical, 4)
    }
}

// MARK: Bark

/// 「锁屏推送（Bark）」：服务器把消息转发给 App Store 的免费 App Bark，点 Bark 通知回到回笺看详情
struct BarkSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var url = ""
    @State private var encrypt = false
    @State private var key = ""
    @State private var iv = ""
    @State private var busy = false
    @State private var result: (ok: Bool, text: String)?
    @State private var loaded = false

    var body: some View {
        Section {
            if model.barkSupported == false {
                Label("需要更新服务端：当前服务端（\(model.serverVersion.isEmpty ? "旧版本" : model.serverVersion)）还不支持 Bark 转发",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).foregroundStyle(Theme.warning)
            }
            status
            VStack(alignment: .leading, spacing: 6) {
                Text("怎么开启").font(.subheadline.weight(.medium))
                step(1, "在 App Store 安装免费的「Bark」，打开它并允许通知")
                step(2, "在 Bark 首页复制推送地址，形如 https://api.day.app/xxxx/")
                step(3, "粘贴到下面，点「保存」，再点「发送测试」")
            }
            .padding(.vertical, 2)
            HStack {
                TextField(text: $url, prompt: Text(verbatim: "https://api.day.app/xxxx/")) { Text("Bark 推送地址") }
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout)
                Button {
                    if let s = UIPasteboard.general.string { url = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                } label: { Image(systemName: "doc.on.clipboard") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("粘贴")
            }
            Toggle("端到端加密（可选）", isOn: $encrypt)
            if encrypt {
                cipherField("Key（32 位）", text: $key, length: 32, allowed: [16, 24, 32])
                cipherField("IV（16 位）", text: $iv, length: 16, allowed: [16])
                Text("在 Bark 首页 → 加密设置里选 AES256、CBC、pkcs7，填入同样的 Key，点「完成」后回到 Bark 首页一次让设置生效（Key 是 16 / 24 位时对应选 AES128 / AES192）。IV 会随每条推送一起发送，Bark 里不用填。加密后 Bark 的服务器看不到标题、正文和频道名。")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
            HStack(spacing: 10) {
                Button("保存") { run { try await model.saveBark(url: url, encrypt: encrypt, key: key, iv: iv); return url.isEmpty ? "已关闭 Bark 转发" : "已保存" } }
                    .buttonStyle(.borderedProminent)
                Button("发送测试") { run { try await model.testBark(); return "已发出，看看 Bark 有没有收到" } }
                    .buttonStyle(.bordered)
                    .disabled(model.bark == nil)
                Spacer()
                if busy { ProgressView() }
            }
            .disabled(busy || model.barkSupported == false)
            if let r = result {
                Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.footnote).foregroundStyle(r.ok ? Theme.success : Theme.danger)
            }
            if model.bark != nil {
                Button("关闭 Bark 转发", role: .destructive) {
                    run { try await model.saveBark(url: "", encrypt: false, key: "", iv: ""); url = ""; encrypt = false; return "已关闭 Bark 转发" }
                }
                .disabled(busy)
            }
        } header: {
            Text("锁屏推送（Bark）")
        } footer: {
            Text("自签安装的回笺用不了苹果推送，锁屏提醒交给 Bark：服务器收到消息后转发给 Bark（P5 紧急、P4 时效性、P3 普通，P0–P2 不转发），点通知回到回笺看详情和附件。开启后回笺不再发本地通知。")
        }
        .headerProminence(.increased)
        .onAppear(perform: load)
        .onChange(of: model.bark) { _, _ in load() }
    }

    private var status: some View {
        LabeledContent("状态") {
            if let b = model.bark {
                Text(b.encrypted ? "已开启 · 加密" : "已开启").foregroundStyle(Theme.success)
            } else {
                Text("未开启").foregroundStyle(Theme.text3)
            }
        }
    }

    private func step(_ n: Int, _ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n).").font(.footnote.monospacedDigit()).foregroundStyle(Theme.text3)
            Text(s).font(.footnote).foregroundStyle(Theme.text2)
        }
    }

    private func cipherField(_ title: String, text: Binding<String>, length: Int, allowed: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(Theme.text3)
            HStack(spacing: 8) {
                TextField(String(repeating: "•", count: 8), text: text)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("生成") { text.wrappedValue = BarkCipherStore.random(length) }
                    .buttonStyle(.bordered).controlSize(.small)
                Button { UIPasteboard.general.string = text.wrappedValue } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(text.wrappedValue.isEmpty)
                    .accessibilityLabel("复制")
            }
            if !text.wrappedValue.isEmpty && !allowed.contains(text.wrappedValue.count) {
                Text("需要 \(length) 位，现在 \(text.wrappedValue.count) 位").font(.caption).foregroundStyle(Theme.danger)
            }
        }
    }

    private func load() {
        if let b = model.bark { url = b.url; encrypt = b.encrypted } else if !loaded { url = "" }
        if let c = BarkCipherStore.load() { key = c.key; iv = c.iv }
        loaded = true
    }

    private func run(_ op: @escaping () async throws -> String) {
        busy = true
        result = nil
        Task {
            do { result = (true, try await op()) } catch { result = (false, shortError(error)) }
            busy = false
        }
    }
}
