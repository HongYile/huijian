import AppKit
import SwiftUI

// 账户：不放在设置里，放在主窗口左下角（头像 + 用户名）和菜单栏面板，点开是单独的「账户」窗口。
// 配对成功后如果账号还没有用户名密码，主窗口只显示「完成账号设置」，设置完才能使用。


struct Avatar: View {
    let name: String
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(name.isEmpty ? Theme.surface2 : Theme.accent)
            if let c = name.first {
                Text(String(c).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(Theme.surface)
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(Theme.text3)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Theme.border, lineWidth: name.isEmpty ? 1 : 0))
    }
}

// MARK: 完成账号设置（配对后、使用前）

struct AccountSetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var username = ""
    @State private var password = ""
    @State private var password2 = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirmLogout = false
    /// 这台设备加入的账号里已有的 pushkey 数和设备数（配对码加入的是已有账号，不是新建）
    @State private var existing: (keys: Int, devices: Int)?

    var canSubmit: Bool {
        AppModel.normalizeUsername(username).count >= 2 && AppModel.usernameProblem(username) == nil
            && password.count >= 8 && password == password2 && strengthProblem == nil
    }

    /// 服务端支持新登录协议时，密码强度只能由客户端检查（docs/e2ee-client.md §2.2）
    var strengthProblem: String? {
        model.e2eSupported && !password.isEmpty ? Core.passwordProblem(password, username: AppModel.normalizeUsername(username)) : nil
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                Text("完成账号设置").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text).padding(.top, 14)
                Label("已连接到 \(model.serverHost) · 本机「\(model.deviceName)」", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.success).padding(.top, 8)
                Text(existingText + "设置用户名和密码后就可以开始使用；以后换电脑、重装 App 时用它登录，pushkey 和历史消息都会回来。")
                    .font(.system(size: 13)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 10)

                // 0.9.0 起本账号任何设备都能设置初始密码（不再要求「允许管理」的设备）
                form

                HStack {
                    Button("用其他账号登录") { confirmLogout = true }
                        .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                    Spacer()
                    Button("退出") { confirmLogout = true }
                        .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.text3)
                }
                .padding(.top, 18)
            }
            .padding(34)
            .frame(width: 440)
            .card(radius: 14, lifted: true)
        }
        .confirmationDialog("退出后回到登录页，可以用配对码或其他账号重新登录。", isPresented: $confirmLogout) {
            Button("退出", role: .destructive) { Task { await model.logout() } }
        }
        .task { await loadExisting() }
        .onChange(of: model.accountRevision) { _, _ in Task { await loadExisting() } }
        .onChange(of: model.keysRevision) { _, _ in Task { await loadExisting() } }
        // 账号可能在别的设备上设置好：定时检查，设置好后自动进入
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                await model.refreshMe()
            }
        }
    }

    var existingText: String {
        guard let e = existing else { return "" }
        if e.keys == 0 && e.devices <= 1 { return "这台设备加入的是一个新账号。" }
        return "配对码属于一个已有账号（已有 \(e.keys) 把 pushkey、\(e.devices) 台设备），这里是给这个账号设置用户名和密码，不会新建账号。"
    }

    func loadExisting() async {
        guard let client = model.client else { return }
        let keys = (try? await client.listKeys())?.filter { !$0.revoked }.count
        let devs = (try? await client.account())?.devices.filter { !$0.revoked }.count
        if let keys, let devs { existing = (keys, devs) }
    }

    var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("用户名") {
                VStack(alignment: .leading, spacing: 5) {
                    WarmField(placeholder: "登录时使用，例如 Alex Chen", text: $username)
                    Text(AppModel.usernameProblem(username) ?? AppModel.usernameRule)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppModel.usernameProblem(username) == nil ? Theme.text3 : Theme.danger)
                }
            }
            field("密码") { WarmField(placeholder: model.e2eSupported ? "至少 10 位，不要用常见密码" : "至少 8 位", text: $password, secure: true) }
            field("再输入一次密码") { WarmField(placeholder: "确认密码", text: $password2, secure: true) }
            if let p = strengthProblem {
                Text(p).font(.system(size: 12)).foregroundStyle(Theme.danger)
            } else if !password2.isEmpty && password != password2 {
                Text("两次输入的密码不一样").font(.system(size: 12)).foregroundStyle(Theme.danger)
            }
            if let error {
                Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(busy ? "保存中…" : "完成，开始使用")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(busy || !canSubmit)
            .padding(.top, 4)
        }
        .padding(.top, 22)
    }


    func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text2)
            c()
        }
    }

    func save() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let u = AppModel.normalizeUsername(username)
            // 初始密码只能以原文设置（服务端没有别的接口）：先查「已升级」标记，设置后马上升级到新登录协议
            _ = try await model.setInitialCredentials(username: u, password: password)
            password = ""; password2 = ""
        } catch APIError.http(403, let m) {
            // 可能是没有管理权限，也可能账号刚在别处设好了密码：刷新后按实际状态显示
            await model.refreshMe()
            error = "无法设置：\(m)"
        } catch {
            self.error = "保存失败：\(Updater.describe(error))"
        }
    }
}

// MARK: 主窗口左下角：账户（点开弹出账户菜单，类似 Claude / Codex 客户端）

struct AccountFooter: View {
    @EnvironmentObject var model: AppModel
    @State private var hover = false

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1)
            // 直接打开统一的「账户与设置」窗口（账户在第一页，Pushkey 第二页）
            Button { AppDelegate.shared?.showSettings(tab: .account) } label: {
                HStack(spacing: 10) {
                    Avatar(name: model.accountName, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.accountName.isEmpty ? "账户" : model.accountName)
                            .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        HStack(spacing: 5) {
                            StatusDot(state: model.state)
                            Text(model.deviceName)
                                .font(.system(size: 11.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                    if model.isPaused {
                        Image(systemName: "bell.slash.fill").font(.system(size: 12)).foregroundStyle(Theme.warning)
                            .help("通知已暂停")
                    }
                    Image(systemName: "gearshape").font(.system(size: 12.5)).foregroundStyle(Theme.text3)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Theme.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help("\(model.state.label)。点击打开账户与设置")
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Theme.sidebar)
    }
}

@MainActor
enum AccountMenu {
    static func confirmLogout(_ model: AppModel) {
        let a = NSAlert()
        a.messageText = "退出登录？"
        a.informativeText = "退出后需要重新登录或配对；本地消息会保留。再次登录时仍是同一台设备。"
        a.addButton(withTitle: "退出登录")
        a.addButton(withTitle: "取消")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task {
            if !(await model.logout()) {
                let b = NSAlert()
                b.messageText = "已在本机退出"
                b.informativeText = "服务端没有确认作废本机凭证（服务端版本较旧或连不上）。如需彻底作废，请在本账号另一台设备的「账户」页移除这台设备。"
                b.runModal()
            }
        }
    }
}

struct AccountView: View {
    @EnvironmentObject var model: AppModel
    @State private var detail: APIClient.AccountDetail?
    @State private var loading = false
    @State private var message: String?
    @State private var unsupported = false

    // 修改用户名 / 密码
    @State private var editing = false
    @State private var username = ""
    @State private var password = ""
    @State private var password2 = ""
    @State private var current = ""
    @State private var saving = false
    @State private var credMsg: String?

    // 配对码
    @State private var code: String?
    @State private var codeExpires: Date?
    /// 配对码已被哪台设备使用（服务端 0.5.6 起能查到）；nil = 还没用
    @State private var codeUsedBy: String?
    @State private var codeDead = false
    @State private var revokeTarget: APIClient.DeviceInfo?
    @State private var codeBusy = false
    @State private var codeMsg: String?
    /// 带钥匙的配对码（§12.2）：长配对码和配对链接（二维码内容）。一次性钥匙只在这里（内存），用掉、过期、重新生成、离开页面都清掉
    @State private var codeText: String?
    @State private var codeLink: String?

    private static var demoCodeMade = false

    // 本机
    @State private var nameDraft = ""
    @State private var nameMsg: String?
    @State private var savingName = false
    @State private var confirmLogout = false

    /// 嵌在统一设置窗口的「账户」页里（外层负责滚动和边距）
    var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                if model.token == nil {
                    SettingsCard {
                        SettingsRow(label: "还没有登录", divider: false) {
                            Button("打开回笺登录") { AppDelegate.shared?.showMainWindow(select: nil) }.buttonStyle(SoftButtonStyle())
                        }
                    }
                } else {
                    header
                    if unsupported || model.support("account") == .needsServerUpdate {
                        ServerTooOld(feature: "账号登录、设备列表与配对记录", since: "0.5.0", alternative: nil)
                    } else {
                        addDeviceCard
                        devicesCard
                    }
                    thisDeviceCard
                    HStack {
                        Button("重新连接") { model.startSync() }.buttonStyle(SoftButtonStyle())
                        Spacer()
                        Button("退出登录…") { confirmLogout = true }.buttonStyle(SoftButtonStyle(destructive: true))
                    }
                    .padding(.horizontal, 4)
                }
            }
        // 打开窗口、登录、退出、换账号时都重新加载，不显示上一个账号的设备和配对码
        .task(id: "\(model.token != nil)#\(model.account?.id ?? -1)") {
            detail = nil; code = nil; codeExpires = nil; codeMsg = nil; codeUsedBy = nil; codeDead = false; codeText = nil; codeLink = nil
            message = nil; credMsg = nil; nameMsg = nil; unsupported = false
            resetForm()
            nameDraft = model.deviceName
            await load()
            // 仅截图演示：自动生成一个配对码，并把码写到标准输出供测试脚本去配对
            if model.isDemo, ProcessInfo.processInfo.environment["HUIJIAN_DEMO_PAIRCODE"] != nil, !Self.demoCodeMade, model.account != nil {
                Self.demoCodeMade = true
                await makeCode()
                if let code { print("DEMO_PAIRCODE=\(code)"); fflush(stdout) }
            }
        }
        // 其他设备或管理后台改了设备 / 账户（服务端 0.6.1 起的设置实时同步）：重新拉取设备列表
        .onChange(of: model.accountRevision) { _, _ in Task { await load() } }
        .confirmationDialog("移除「\(revokeTarget?.name ?? "")」后，它需要重新配对或登录才能接收消息。", isPresented: Binding(
            get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } })) {
            Button("移除", role: .destructive) { if let t = revokeTarget { Task { await revoke(t) } } }
        }
        .confirmationDialog("退出后需要重新登录或配对；本地消息会保留。再次登录时仍是同一台设备。", isPresented: $confirmLogout) {
            Button("退出登录", role: .destructive) {
                Task {
                    if !(await model.logout()) {
                        let a = NSAlert()
                        a.messageText = "已在本机退出"
                        a.informativeText = "服务端没有确认作废本机凭证（服务端版本较旧或连不上）。如需彻底作废，请在本账号另一台设备的「账户」页移除这台设备。"
                        a.runModal()
                    }
                }
            }
        }
    }

    // MARK: 头部：头像、用户名、改密码

    var header: some View {
        let a = model.account
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Avatar(name: model.accountName, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.accountName.isEmpty ? "未设置用户名" : model.accountName)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(model.accountName.isEmpty ? Theme.warning : Theme.text)
                    Text(model.serverHost + (detail.map { " · 本账号 \($0.devices.filter { !$0.revoked }.count) 台设备" } ?? ""))
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text2).textSelection(.enabled)
                }
                Spacer()
                if let a, !editing {
                    if a.has_password {
                        Button("修改用户名 / 密码") { username = a.username; editing = true }.buttonStyle(SoftButtonStyle())
                    } else {
                        Button("设置用户名和密码") { username = a.username; editing = true }.buttonStyle(SoftButtonStyle())
                    }
                }
            }
            .padding(16)
            if editing {
                Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1)
                credentialForm.padding(16)
            }
            if let credMsg {
                Text(credMsg).font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .card(radius: 12)
        .padding(.bottom, 18)
    }

    var credentialForm: some View {
        // 账号有密码时，改密码、改用户名一律用当前密码核对（§2.4，管理员设备也不例外：凭证由 prelogin 决定怎么算）
        let admin = false
        let hasPassword = model.account?.has_password == true
        let strength = model.e2eSupported && !password.isEmpty ? Core.passwordProblem(password, username: AppModel.normalizeUsername(username)) : nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                WarmField(placeholder: "用户名（2–32 位）", text: $username)
                if hasPassword && !admin { WarmField(placeholder: "当前密码", text: $current, secure: true) }
            }
            HStack(spacing: 10) {
                WarmField(placeholder: hasPassword ? "新密码（留空只改用户名）" : "密码，至少 8 位", text: $password, secure: true)
                WarmField(placeholder: "再输入一次", text: $password2, secure: true)
            }
            HStack {
                if let p = AppModel.usernameProblem(username) {
                    Text(p).font(.system(size: 12)).foregroundStyle(Theme.danger)
                } else if let strength {
                    Text(strength).font(.system(size: 12)).foregroundStyle(Theme.danger)
                } else if !password2.isEmpty && password != password2 {
                    Text("两次输入的密码不一样").font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
                Spacer()
                Button("取消") { resetForm() }.buttonStyle(SoftButtonStyle())
                Button(saving ? "保存中…" : "保存") { Task { await saveCredentials() } }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(saving || AppModel.normalizeUsername(username).count < 2 || AppModel.usernameProblem(username) != nil || password != password2
                              || (!password.isEmpty && password.count < 8) || (!hasPassword && password.isEmpty) || strength != nil
                              || (hasPassword && !admin && current.isEmpty))
            }
        }
    }

    func resetForm() {
        editing = false
        password = ""; password2 = ""; current = ""
    }

    func saveCredentials() async {
        saving = true
        defer { saving = false }
        do {
            let u = AppModel.normalizeUsername(username)
            _ = try await model.changeCredentials(username: u, password: password, current: current)
            credMsg = password.isEmpty ? "用户名已保存" : "已保存，新密码立即生效（已登录的设备不受影响）"
            resetForm()
            await load()
        } catch APIError.unsupported {
            unsupported = true
        } catch {
            credMsg = "保存失败：\(Updater.describe(error))"
        }
    }

    // MARK: 添加设备

    var addDeviceCard: some View {
        SettingsCard(title: "添加设备到这个账号", footer: codeMsg ?? addDeviceFooter) {
            SettingsRow(label: code == nil ? "生成一个配对码（3 分钟内有效，只能用一次）" : "配对码", divider: false) {
                if let code {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let left = max(0, Int((codeExpires ?? ctx.date).timeIntervalSince(ctx.date).rounded()))
                        let dead = codeUsedBy != nil || codeDead || left == 0
                        HStack(spacing: 10) {
                            Text(code).font(.system(size: 24, weight: .semibold, design: .monospaced))
                                .foregroundStyle(dead ? Theme.text3 : Theme.accent)
                                .strikethrough(dead, color: Theme.text3)
                                .textSelection(.enabled)
                            Group {
                                if let by = codeUsedBy {
                                    Label("已被「\(by)」使用", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                                } else if dead {
                                    Text("已失效").foregroundStyle(Theme.text3)
                                } else {
                                    Text(String(format: "%d:%02d 后失效", left / 60, left % 60)).monospacedDigit()
                                        .foregroundStyle(left <= 30 ? Theme.warning : Theme.text3)
                                }
                            }
                            .font(.system(size: 12))
                        }
                    }
                }
                Button(codeBusy ? "生成中…" : (code == nil ? "生成配对码" : "重新生成")) { Task { await makeCode() } }
                    .buttonStyle(SoftButtonStyle()).disabled(codeBusy)
            }
            pairKeyBlock
        }
        // 每 2 秒查一次配对码状态：被用掉后立即显示是哪台设备，并刷新设备列表
        .task(id: code) { await watchCode() }
        .onDisappear { codeText = nil; codeLink = nil }
    }

    var addDeviceFooter: String {
        if code != nil { return codeLink != nil ? E2E.T.t80 : (model.e2eState?.enabled == true ? E2E.T.t81 : "新设备在登录页选「配对码」输入这 6 位数字，直接进入这个账号。") }
        return "新设备在登录页选「配对码」输入，直接进入这个账号；也可以用用户名密码登录。本机已解锁时生成的二维码 / 长配对码，新设备登录后直接解锁加密消息。重新生成后，之前的配对码立即作废。"
    }

    /// 二维码和长配对码（还没用掉、没过期时显示）
    @ViewBuilder var pairKeyBlock: some View {
        if let link = codeLink, let text = codeText, codeUsedBy == nil, !codeDead {
            HStack(alignment: .top, spacing: 16) {
                QRCodeView(text: link).frame(width: 176, height: 176)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
                VStack(alignment: .leading, spacing: 8) {
                    Text("长配对码").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
                    Text(text).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("复制配对码") { copyPair(text) }.buttonStyle(SoftButtonStyle())
                        Button("复制链接") { copyPair(link) }.buttonStyle(SoftButtonStyle())
                    }
                    Text("iPhone、安卓：在回笺登录页点「扫码」，或用系统相机扫。Mac：在登录页粘贴长配对码或链接。")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
        }
    }

    func copyPair(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        codeMsg = "已复制。只粘贴到自己的设备上，3 分钟内有效。"
    }

    func makeCode() async {
        guard let api = model.e2eAPI, !codeBusy else { return }
        codeBusy = true
        defer { codeBusy = false }
        codeText = nil; codeLink = nil
        do {
            // 本机已解锁、服务端支持时带钥匙（§12.2）：新设备扫码 / 输入长配对码后直接解锁
            let sk = E2E.activeSecretKey(model.e2eKeys, state: model.e2eState)
            let r = try await E2E.createPairCode(api, sk: sk, supportsKey: model.support("pair.key") == .yes)
            if let secret = r.secret {
                let f = try E2E.coreCall { try Core.pairFormat(server: model.server, code: r.code, secret: secret) }
                codeText = f.text
                codeLink = f.link
            }
            code = r.code
            codeExpires = Date().addingTimeInterval(TimeInterval(r.expiresIn))
            codeUsedBy = nil
            codeDead = false
            codeMsg = nil
        } catch let f as E2E.Failure where f.kind == .unsupported {
            unsupported = true
        } catch {
            codeMsg = "生成失败：\(Updater.describe(error))"
        }
    }

    func watchCode() async {
        // 功能清单可能还没加载完：只有明确知道服务端太旧时才不查；查询时服务端说没有这个接口也停下
        guard let c = code, let client = model.client, model.support("pair.status") != .needsServerUpdate else { return }
        while !Task.isCancelled, code == c, codeUsedBy == nil, !codeDead {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, code == c else { return }
            // 过期 30 秒后还查不到结果（例如一直断网）：按失效处理，不再轮询
            if let exp = codeExpires, Date().timeIntervalSince(exp) > 30 { codeDead = true; codeText = nil; codeLink = nil; return }
            let s: APIClient.PairCodeStatus
            do { s = try await client.pairCodeStatus(c) }
            catch APIError.unsupported { return }
            catch APIError.http(404, _) { codeDead = true; codeText = nil; codeLink = nil; return }    // 已过期的码保留 1 小时后被清理
            catch { continue }
            switch s.state {
            case "used":
                codeUsedBy = s.used_by ?? "新设备"
                codeText = nil; codeLink = nil
                await load()
            case "expired":
                codeDead = true
                codeText = nil; codeLink = nil
            default:
                if let left = s.expires_in { codeExpires = Date().addingTimeInterval(TimeInterval(left)) }
            }
        }
    }

    // MARK: 我的设备

    var devicesCard: some View {
        let devs = (detail?.devices ?? []).filter { !$0.revoked }
        return SettingsCard(title: "我的设备", footer: message ?? "同一台设备重新配对或登录时沿用原来的记录，不会重复出现。点配对次数可以展开配对记录。") {
            if devs.isEmpty {
                SettingsRow(label: loading ? "加载中…" : "暂无数据", divider: false) {
                    Button("刷新") { Task { await load() } }.buttonStyle(SoftButtonStyle())
                }
            }
            ForEach(Array(devs.enumerated()), id: \.element.id) { i, d in
                DeviceRow(device: d, last: i == devs.count - 1, onRevoke: { revokeTarget = d })
            }
        }
    }

    func load() async {
        guard let client = model.client, model.support("account") != .needsServerUpdate else { return }
        loading = true
        defer { loading = false }
        do {
            detail = try await client.account()
            model.account = detail?.account
        } catch APIError.unsupported {
            model.noteUnsupported("account")
            unsupported = true
        } catch {
            message = "加载失败：\(Updater.describe(error))"
        }
    }

    func revoke(_ d: APIClient.DeviceInfo) async {
        guard let client = model.client else { return }
        do {
            try await client.revokeDevice(d.id)
            message = "已移除「\(d.name)」"
            await load()
        } catch {
            message = "移除失败：\(Updater.describe(error))"
        }
    }

    // MARK: 本机

    var thisDeviceCard: some View {
        SettingsCard(title: "本机", footer: nameMsg ?? (model.support("me.rename") == .needsServerUpdate
                                                    ? "修改名称需要服务端 0.4.2 以上，更新服务端后可用。"
                                                    : "名称可以随时修改、可以重名；设备 ID 是唯一的，排查问题时用。")) {
            SettingsRow(label: "设备名称") {
                WarmField(placeholder: "设备名称", text: $nameDraft).frame(width: 220)
                Button(savingName ? "保存中…" : "保存") { Task { await saveName() } }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(savingName || nameDraft.trimmingCharacters(in: .whitespaces).isEmpty
                              || nameDraft == model.deviceName || model.support("me.rename") == .needsServerUpdate)
            }
            SettingsRow(label: "设备 ID") {
                value(model.deviceID.isEmpty ? "—" : model.deviceID).font(.system(size: 13, design: .monospaced))
                if !model.deviceID.isEmpty {
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.deviceID, forType: .string)
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            }
            SettingsRow(label: "服务器") { value(model.server) }
            SettingsRow(label: "连接状态", divider: false) {
                StatusDot(state: model.state)
                value(model.state.label)
            }
        }
    }

    func saveName() async {
        savingName = true
        defer { savingName = false }
        do {
            try await model.renameDevice(nameDraft)
            nameDraft = model.deviceName
            nameMsg = "已保存，本账号的其他设备上也会显示新名称"
            await load()
        } catch APIError.unsupported {
            model.noteUnsupported("me.rename")
            nameMsg = "修改名称需要服务端 0.4.2 以上，更新服务端后可用。"
        } catch {
            nameMsg = "保存失败：\(Updater.describe(error))"
        }
    }

    func value(_ s: String) -> some View {
        Text(s).font(.system(size: 13.5)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
    }
}

struct DeviceRow: View {
    let device: APIClient.DeviceInfo
    let last: Bool
    let onRevoke: () -> Void
    @State private var showPairings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: device.platform == "macos" ? "laptopcomputer" : (device.platform == "ios" ? "iphone" : "desktopcomputer"))
                    .font(.system(size: 15)).foregroundStyle(Theme.text2).frame(width: 22)
                Text(device.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                if device.current { tag("本机", Theme.accent) }
                if device.online { tag("在线", Theme.success) }
                Spacer(minLength: 4)
                if !device.current {
                    Button("移除", action: onRevoke).buttonStyle(SoftButtonStyle(destructive: true))
                }
            }
            HStack(spacing: 6) {
                Text(device.id).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text3).textSelection(.enabled)
                if !device.client.isEmpty { Text("· \(device.client)").font(.system(size: 12)).foregroundStyle(Theme.text3) }
            }
            .padding(.leading, 31)
            Button {
                showPairings.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text("首次配对 \(date(device.created_at)) · 配对 \(device.pair_count) 次\(device.pair_count > 1 ? "，最近 \(date(device.last_paired))" : "")")
                    Image(systemName: showPairings ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.leading, 31)
            if showPairings {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(device.pairings, id: \.self) { p in
                        Text("\(date(p.at)) · \(p.methodLabel)\(p.ip.isEmpty ? "" : " · \(p.ip)")\(p.client.isEmpty ? "" : " · \(p.client)")")
                            .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    }
                }
                .padding(.leading, 31)
            }
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1) }
        }
    }

    func date(_ t: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }

    func tag(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 11, weight: .medium)).foregroundStyle(c)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.12)))
    }
}
