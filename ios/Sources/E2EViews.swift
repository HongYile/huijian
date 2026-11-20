import SwiftUI
import UIKit

// 设置 → 账户 →「端到端加密」：开启端到端加密、保存恢复码、三种解锁方式、重新设置密码、批准其他设备、加密相关的设置项；
// 还有消息列表顶部的锁定横幅（T10）、详情页里解不开的加密消息。
// 规格见 docs/e2ee-client.md §3–§7；文案 T1…T72 来自 E2E.T（和 Mac、安卓一致）。和 Mac 的 E2ESettings.swift 一一对应，
// 只是换成 iPhone 的表单和导航。

struct E2EView: View {
    @EnvironmentObject private var model: AppModel
    @State private var notice: String?

    var body: some View {
        Form {
            if let old = model.tooOld("e2e", since: "0.7.0") {
                Section {
                    Label(old, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).font(.subheadline)
                } footer: {
                    Text("端到端加密需要服务端 0.7.0 以上。")
                }
            } else if let r = model.e2eRecovery {
                // 恢复码在 App 状态里（离开页面再回来还在），点「完成」才清除
                RecoveryCodeSection(code: r.code) {
                    notice = r.fromSetup ? E2E.T.t22 : "已更换恢复码，旧的恢复码已失效。"
                    model.e2eFinishRecovery()
                }
            } else {
                notices
                switch model.e2eStatus {
                case nil:
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在读取加密状态…").foregroundStyle(Theme.text2)
                            Spacer()
                            Button("刷新") { Task { await load() } }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                case .off:
                    // §11.1：有密码的账号在后台自动开启；手动开启（§4.1）只作为出口保留
                    if model.e2eAutoSetupPending {
                        Section {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(E2E.T.autoSetupRunning).foregroundStyle(Theme.text2)
                            }
                        }
                    } else if model.e2eAutoSetupFailed {
                        Section {
                            Label(E2E.T.autoSetupFailed, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline).foregroundStyle(Theme.warning)
                        }
                    }
                    E2ESetupSection()
                case .locked:
                    if model.e2eKeyChanged { E2EKeyChangedSection() }
                    E2EUnlockSections()
                    E2EResetSection(locked: true) { notice = E2E.T.resetDone }
                case .unlocked:
                    if model.e2eKeyChanged { E2EKeyChangedSection() }
                    if model.e2eNeedsPasswordReset { E2EResetPasswordSection() }
                    if model.e2eWeakPassword { E2EWeakPasswordSection() }
                    E2EStatusSection()
                    E2ERecoverySection()
                    E2ERequestsSection()
                    E2EOptionsSections()
                    E2EResetSection(locked: false) { notice = E2E.T.resetDone }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg)
        .navigationTitle("端到端加密")
        .navigationBarTitleDisplayMode(.inline)
        // 恢复码只显示这一次：勾选「已保存」并点「完成」之前不让返回（返回了也不丢，再进来还在）
        .navigationBarBackButtonHidden(model.e2eRecovery != nil)
        .refreshable { await load() }
        .task { await load() }
        // 等待批准、等待核对时每 3 秒刷新一次（长轮询的 e2e 变更也会触发刷新）
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                if model.e2eFastPoll { await model.refreshE2E() }
            }
        }
    }

    /// 还没拉到服务端功能清单时先拉（拉到后会自动刷新加密状态）
    private func load() async {
        if model.serverFeatures == nil { await model.refreshAccount() }
        await model.refreshE2E()
    }

    @ViewBuilder private var notices: some View {
        ForEach([model.e2eStorageError, model.e2eLoginNote, model.e2eRecoveryNote, model.e2eResetNote, notice].compactMap { $0 }, id: \.self) { t in
            Section {
                Label(t, systemImage: t == notice ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(t == notice ? Theme.success : Theme.warning)
                if t == E2E.T.t22 || t == E2E.T.resetDone {
                    Button("打开 Pushkey 页") { model.path = [.settings, .keys] }
                }
            }
        }
    }
}

/// 一行错误说明
@MainActor private func errorText(_ s: String?) -> some View {
    Group {
        if let s { Text(s).font(.footnote).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
    }
}

@MainActor private func describe(_ e: Error) -> String { shortError(e) }

/// 当前账号的用户名（检查密码强度：不能和用户名太像）
@MainActor private func accountName(_ model: AppModel) -> String {
    model.accountDetail?.account.username ?? model.settings.username
}

/// 大字核对码（3+3）
struct SASCodeView: View {
    let code: String
    var body: some View {
        Text(E2E.formatCode(code))
            .font(.system(size: 34, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.accent)
            .textSelection(.enabled)
    }
}

/// 按钮文字 + 忙碌时的转圈
private struct BusyLabel: View {
    let text: String
    let busy: Bool
    var body: some View {
        HStack {
            Text(text)
            if busy { Spacer(); ProgressView() }
        }
    }
}

// MARK: 开启加密（§4.1）

struct E2ESetupSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var current = ""
    @State private var changePassword = true
    @State private var new1 = ""
    @State private var new2 = ""
    @State private var busy = false
    @State private var error: String?

    private var newProblem: String? {
        guard changePassword, !new1.isEmpty else { return nil }
        return Core.passwordProblem(new1, username: accountName(model))
    }

    private var canSubmit: Bool {
        !current.isEmpty && (!changePassword || (!new1.isEmpty && new1 == new2 && newProblem == nil))
    }

    var body: some View {
        Section {
            if model.accountHasPassword == false {
                Text("这个账号还没有密码：先在「账户与设备」里设置用户名和密码，再开启加密。").font(.footnote).foregroundStyle(Theme.warning)
            }
            // 上次开启的结果后来确认是没开启（钥匙还存着，再点「开启」会先核对再重新生成，§4.1）
            if model.e2ePendingSetup != nil, error == nil, !busy {
                Text(E2E.T.setupNotDone).font(.footnote).foregroundStyle(Theme.warning)
            }
            SecureField("当前密码", text: $current).textContentType(.password)
            Toggle("同时换一个新密码（推荐）", isOn: $changePassword)
            if changePassword {
                SecureField("新密码", text: $new1).textContentType(.newPassword)
                SecureField("确认新密码", text: $new2).textContentType(.newPassword)
                if let p = newProblem {
                    Text(p).font(.footnote).foregroundStyle(Theme.danger)
                } else if !new2.isEmpty && new1 != new2 {
                    Text("两次输入的新密码不一样").font(.footnote).foregroundStyle(Theme.danger)
                } else {
                    Text("旧密码以前以原文发给过服务器，换一个新密码更安全。至少 10 位，不要用常见密码。")
                        .font(.footnote).foregroundStyle(Theme.text3)
                }
            }
            errorText(error)
            Button {
                Task { await submit() }
            } label: {
                BusyLabel(text: busy ? "正在生成钥匙…" : "开启端到端加密", busy: busy)
            }
            // 后台正在自动开启时不能同时手动开启（两次 setup 并发，手动那次会拿到 409）
            .disabled(busy || !canSubmit || model.e2eAutoSetupRunning)
        } header: {
            Text(E2E.T.t20Title)
        } footer: {
            Text(E2E.T.t20)
        }
    }

    private func submit() async {
        error = nil
        // 当前密码不合格又没勾选换密码：提示并自动勾选
        if !changePassword, Core.passwordProblem(current, username: accountName(model)) != nil {
            error = E2E.T.weakCurrent
            changePassword = true
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await model.e2eSetup(current: current, newPassword: changePassword ? new1 : nil)   // 恢复码在 model.e2eRecovery
            current = ""; new1 = ""; new2 = ""
        } catch let f as E2E.Failure where f.kind == .conflict {
            error = f.message
            await model.refreshE2E()
        } catch {
            self.error = describe(error)
        }
    }
}

// MARK: 保存恢复码（T21）

struct RecoveryCodeSection: View {
    let code: String
    let onDone: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var saved = false
    @State private var copied = false

    /// 不在前台（进入多任务切换、后台）时遮住恢复码，系统截下的快照里看不到（§4.1）
    private var hidden: Bool { scenePhase != .active }

    var body: some View {
        Section {
            Text(E2E.T.t21).font(.subheadline).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Group {
                    if hidden {
                        Text("•••••-•••••-•••••-•••••-••••••")
                            .accessibilityLabel("恢复码已隐藏")
                    } else {
                        Text(code).textSelection(.enabled)
                    }
                }
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                // 只放本机剪贴板（不经通用剪贴板同步到其他苹果设备），5 分钟后自动清掉
                Button(copied ? "已复制（5 分钟后从剪贴板清除）" : "复制") {
                    copySecret(code)
                    copied = true
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.vertical, 6)
            Toggle(E2E.T.t21Check, isOn: $saved)
            Button("完成", action: onDone).disabled(!saved)
        } header: {
            Text(E2E.T.t21Title)
        }
    }
}

// MARK: 已锁定：三种解锁方式（§4.2–§4.4）

struct E2EUnlockSections: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var recovery = ""
    @State private var busy: String?
    @State private var passwordError: String?
    @State private var recoveryError: String?
    @State private var requestError: String?

    var body: some View {
        Section {
            Label("这个账号已开启端到端加密，这台设备还没有解锁，加密消息暂时只显示「\(E2E.T.t60)」。任选一种方式解锁：", systemImage: "lock.fill")
                .font(.subheadline).foregroundStyle(Theme.text)
        }
        Section {
            SecureField("账号密码", text: $password).textContentType(.password)
            Button { Task { await unlockPassword() } } label: { BusyLabel(text: busy == "pw" ? "解锁中…" : "解锁", busy: busy == "pw") }
                .disabled(busy != nil || password.isEmpty)
            errorText(passwordError)
        } header: {
            Text("用密码解锁")
        } footer: {
            Text("输入账号密码，在本机解开服务器上用密码锁住的钥匙（密码不会发给服务器）。")
        }
        requestSection
        Section {
            TextField(E2E.T.t40Placeholder, text: $recovery)
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button { Task { await unlockRecovery() } } label: { BusyLabel(text: busy == "rc" ? "解锁中…" : "解锁", busy: busy == "rc") }
                .disabled(busy != nil || recovery.trimmingCharacters(in: .whitespaces).isEmpty)
            errorText(recoveryError)
        } header: {
            Text(E2E.T.t40Title)
        } footer: {
            Text("忘记密码、又没有其他设备可以批准时使用。")
        }
    }

    private var requestSection: some View {
        Section {
            switch model.e2eRequestPhase {
            case nil:
                Text(E2E.T.t30).font(.subheadline).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                Button { Task { await startRequest() } } label: { BusyLabel(text: busy == "rq" ? "发送中…" : "发送请求", busy: busy == "rq") }
                    .disabled(busy != nil)
            case .waiting:
                Text(E2E.T.t30).font(.subheadline).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ProgressView()
                    Text("等待另一台设备接手…").font(.subheadline).foregroundStyle(Theme.text3)
                }
                Button("取消", role: .destructive) { Task { await model.e2eCancelRequest() } }
            case .code(let c):
                SASCodeView(code: c)
                Text(E2E.T.t31(c)).font(.subheadline).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                Button("取消", role: .destructive) { Task { await model.e2eCancelRequest() } }
            case .granted:
                Label("已解锁", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
            case .denied:
                Text(E2E.T.t32).font(.subheadline).foregroundStyle(Theme.danger)
                Button("重新请求") { Task { await startRequest() } }.disabled(busy != nil)
            case .failed(let m):
                Text(m).font(.subheadline).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                Button("重新请求") { Task { model.e2eDismissRequest(); await startRequest() } }.disabled(busy != nil)
                Button("关闭") { model.e2eDismissRequest() }
            }
            errorText(requestError)
        } header: {
            Text(E2E.T.t30Title)
        }
    }

    private func unlockPassword() async {
        busy = "pw"; passwordError = nil
        defer { busy = nil }
        do { try await model.e2eUnlock(password: password); password = "" } catch { passwordError = describe(error) }
    }

    private func unlockRecovery() async {
        busy = "rc"; recoveryError = nil
        defer { busy = nil }
        do { try await model.e2eUnlock(recovery: recovery); recovery = "" } catch { recoveryError = describe(error) }
    }

    private func startRequest() async {
        busy = "rq"; requestError = nil
        defer { busy = nil }
        do { try await model.e2eStartRequest() } catch { requestError = describe(error) }
    }
}

// MARK: 重新设置密码（§4.4.4，T42）

struct E2EResetPasswordSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var current = ""
    @State private var new1 = ""
    @State private var new2 = ""
    @State private var busy = false
    @State private var error: String?

    private var problem: String? { new1.isEmpty ? nil : Core.passwordProblem(new1, username: accountName(model)) }

    var body: some View {
        Section {
            SecureField("当前密码（管理员重设后的密码）", text: $current).textContentType(.password)
            Text(E2E.T.t42Field).font(.footnote).foregroundStyle(Theme.warning)
            SecureField("新密码", text: $new1).textContentType(.newPassword)
            SecureField("确认新密码", text: $new2).textContentType(.newPassword)
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(Theme.danger)
            } else if !new2.isEmpty && new1 != new2 {
                Text("两次输入的新密码不一样").font(.footnote).foregroundStyle(Theme.danger)
            }
            errorText(error)
            Button { Task { await submit() } } label: { BusyLabel(text: busy ? "保存中…" : "设置新密码", busy: busy) }
                .disabled(busy || current.isEmpty || new1.isEmpty || new1 != new2 || problem != nil)
        } header: {
            Text(E2E.T.t42Title)
        } footer: {
            Text(E2E.T.t42)
        }
    }

    private func submit() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await model.e2eResetPassword(current: current, newPassword: new1)
            current = ""; new1 = ""; new2 = ""
        } catch { self.error = describe(error) }
    }
}

// MARK: 状态（§7.6）

struct E2EStatusSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let st = model.e2eState
        Section("端到端加密") {
            LabeledContent("状态") {
                Label("已开启 · 钥匙 \(String((st?.activeKey?.kid ?? "").prefix(8)))", systemImage: "lock.fill")
                    .foregroundStyle(Theme.success).textSelection(.enabled)
            }
            LabeledContent("本机") {
                Text("已解锁，可以查看加密消息").foregroundStyle(Theme.text2)
            }
            LabeledContent("恢复码") {
                Text(st?.hasRecovery == true ? "已设置" : "未设置").foregroundStyle(st?.hasRecovery == true ? Theme.text2 : Theme.warning)
            }
        }
    }
}

// MARK: 等待批准的设备（§5）

struct E2ERequestsSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var error: String?
    @State private var busy: String?
    /// 处理完、已从请求列表消失的设备名（显示结果用）
    @State private var names: [String: String] = [:]

    var body: some View {
        let reqs = model.e2eState?.requests ?? []
        let finished = model.e2eApprovalPhases.keys.filter { id in !reqs.contains { $0.device_id == id } }.sorted()
        if !reqs.isEmpty || !finished.isEmpty {
            Section {
                ForEach(reqs) { r in row(r) }
                ForEach(finished, id: \.self) { id in finishedRow(id) }
            } header: {
                Text("等待批准的设备")
            } footer: {
                Text(error ?? "批准前先核对两台设备上的 6 位核对码是否一致；不一致说明可能有人冒充，请拒绝。")
                    .foregroundStyle(error == nil ? Theme.text2 : Theme.danger)
            }
            .onAppear { for r in reqs { names[r.device_id] = r.name } }
            .onChange(of: reqs) { _, v in for r in v { names[r.device_id] = r.name } }
        }
    }

    private func icon(_ platform: String) -> String {
        switch platform {
        case "macos": return "laptopcomputer"
        case "ios": return "iphone"
        case "android": return "candybarphone"
        default: return "desktopcomputer"
        }
    }

    private func row(_ r: E2E.Request) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon(r.platform)).font(.title3).foregroundStyle(Theme.text2).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name.isEmpty ? "新设备" : r.name).font(.body.weight(.medium)).foregroundStyle(Theme.text)
                    Text("\(r.platform) · 请求于 \(date(r.requested_at))").font(.caption).foregroundStyle(Theme.text3)
                }
            }
            switch model.e2eApprovalPhases[r.device_id] {
            case nil:
                HStack(spacing: 10) {
                    Button(busy == r.device_id ? "处理中…" : "批准") { act(r.device_id) { try await model.e2eBeginApproval(r) } }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(busy != nil)
                    Button("拒绝", role: .destructive) { act(r.device_id) { try await model.e2eDeny(r.device_id) } }
                        .buttonStyle(.bordered).controlSize(.small).disabled(busy != nil)
                }
            case .challenged:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("等待新设备显示核对码…").font(.subheadline).foregroundStyle(Theme.text3)
                }
                // §5 第 2 步：「拒绝」发送 deny；「取消」只停止本机的等待（请求留着，可以重新批准或在别的设备上处理）
                HStack(spacing: 10) {
                    Button("拒绝", role: .destructive) { act(r.device_id) { try await model.e2eDeny(r.device_id) } }
                        .buttonStyle(.bordered).controlSize(.small).disabled(busy != nil)
                    Button("取消") { model.e2eForgetApproval(r.device_id) }
                        .buttonStyle(.bordered).controlSize(.small).disabled(busy != nil)
                }
            case .code(let c):
                SASCodeView(code: c)
                Text(E2E.T.t53(c)).font(.subheadline).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("一致，批准") { act(r.device_id) { try await model.e2eApprove(r.device_id) } }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(busy != nil)
                    Button("不一致，拒绝", role: .destructive) { act(r.device_id) { try await model.e2eDeny(r.device_id) } }
                        .buttonStyle(.bordered).controlSize(.small).disabled(busy != nil)
                }
            case .failed(let m):
                result(r.device_id, m, Theme.danger)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }

    private func finishedRow(_ id: String) -> some View {
        let name = names[id] ?? "新设备"
        let (text, color): (String, Color) = {
            switch model.e2eApprovalPhases[id] {
            case .approved: return ("已批准「\(name)」，它现在可以查看加密消息", Theme.success)
            case .rejected: return ("已拒绝「\(name)」", Theme.text2)
            case .failed(let m): return ("「\(name)」：\(m)", Theme.danger)
            default: return ("「\(name)」的请求已结束", Theme.text2)
            }
        }()
        return result(id, text, color)
    }

    private func result(_ id: String, _ text: String, _ color: Color) -> some View {
        HStack {
            Text(text).font(.subheadline).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button("关闭") { model.e2eForgetApproval(id) }.buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func act(_ id: String, _ f: @escaping () async throws -> Void) {
        Task {
            busy = id; error = nil
            defer { busy = nil }
            do { try await f() } catch { self.error = describe(error) }
        }
    }

    private func date(_ t: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }
}

// MARK: 设置项（§7.2–§7.4）

struct E2EOptionsSections: View {
    @EnvironmentObject private var model: AppModel
    @State private var busy = false
    @State private var message: String?
    @State private var confirmDelete = false

    var body: some View {
        Section {
            Toggle("只接受加密消息", isOn: Binding(get: { model.e2eState?.e2e_only ?? false }, set: { v in
                Task {
                    do { try await model.e2eSetOnly(v) } catch { message = "保存失败：\(describe(error))" }
                }
            }))
        } header: {
            Text("设置")
        } footer: {
            Text(E2E.T.t71)
        }
        // 服务器代加密（§11.5）：始终开启、没有开关，只显示说明 T65
        Section {
            LabeledContent("服务器代加密") { Text("始终开启").foregroundStyle(Theme.text2) }
        } footer: {
            Text(E2E.T.t65)
        }
        Section {
            Button("删除服务器上的明文消息…", role: .destructive) { confirmDelete = true }
                .disabled(busy)
                .confirmationDialog("删除服务器上的明文消息", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("删除", role: .destructive) { Task { await deletePlain() } }
                } message: {
                    Text(E2E.T.t72)
                }
        } footer: {
            Text(message ?? "改密码在「账户与设备」→「修改用户名和密码」：已开启加密时，新密码会重新锁住本机的钥匙。")
        }
    }

    private func deletePlain() async {
        busy = true
        defer { busy = false }
        do {
            let n = try await model.e2eDeletePlain()
            message = "已删除服务器上的 \(n) 条明文消息（本机已同步的保留）。"
        } catch { message = "删除失败：\(describe(error))" }
    }
}

/// 恢复码（§7 第 3 项、§11.2）：自动开启的账号没有恢复码，显示 T23 和「设置恢复码」；已设置时可以更换
struct E2ERecoverySection: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing = false
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        let has = model.e2eState?.hasRecovery == true
        Section {
            if !has {
                Label(E2E.T.t23, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
            if editing {
                SecureField("先输入当前密码", text: $password).textContentType(.password)
                Button { Task { await generate() } } label: { BusyLabel(text: busy ? "生成中…" : "生成新的恢复码", busy: busy) }
                    .disabled(busy || password.isEmpty)
                Button("取消") { editing = false; password = "" }.disabled(busy)
            } else {
                Button(has ? "更换恢复码…" : "设置恢复码…") { editing = true; message = nil }
            }
            errorText(message)
        } header: {
            Text("恢复码")
        } footer: {
            if has { Text("更换后旧的恢复码立即失效。") }
        }
    }

    private func generate() async {
        busy = true; message = nil
        defer { busy = false }
        do {
            try await model.e2eRotateRecovery(password: password)      // 恢复码在 model.e2eRecovery，显示「保存恢复码」页
            password = ""
            editing = false
        } catch { message = describe(error) }
    }
}

// MARK: 默认自动加密（§11）

/// 账号的钥匙已经更换（别的设备重置过加密，§11.3 第 6 步）：T46，引导用密码或恢复码解锁
struct E2EKeyChangedSection: View {
    var body: some View {
        Section {
            Label(E2E.T.t46, systemImage: "key.fill")
                .font(.subheadline).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 密码偏弱（§11.1 第 5 步）：加密已照常开启，T24 引导去改密码
struct E2EWeakPasswordSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            Label(E2E.T.t24, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            Button("去改密码") { model.path = [.settings, .account] }
        }
    }
}

/// 重置加密（已锁定：「都不行？重置加密」）/ 更换加密钥匙（已解锁），§11.3：当前密码 + 二次确认 T45
struct E2EResetSection: View {
    @EnvironmentObject private var model: AppModel
    let locked: Bool
    @State private var expanded = false
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirm = false
    @State private var confirmAbandon = false
    /// 成功后由加密页显示 T.resetDone（带「打开 Pushkey 页」）：锁定时重置成功后这一节会换成「更换加密钥匙」，提示不能放在这里
    var onDone: () -> Void = {}

    var body: some View {
        Section {
            if expanded {
                SecureField("当前密码", text: $password).textContentType(.password)
                errorText(error)
                Button(role: .destructive) { confirm = true } label: {
                    BusyLabel(text: busy ? "正在生成新钥匙…" : (locked ? "重置加密" : "更换加密钥匙"), busy: busy)
                }
                .disabled(busy || password.isEmpty)
                Button("取消") { expanded = false; password = ""; error = nil }.disabled(busy)
            } else {
                // 上次的重置结果不确定（提示在页面上方）：可以不等了，放弃这次重置
                if model.e2eResetPending {
                    Button("放弃这次重置…") { confirmAbandon = true }
                }
                Button(locked ? "都不行？重置加密…" : "更换加密钥匙…", role: .destructive) { expanded = true }
            }
        } footer: {
            Text(locked ? "上面几种方式都用不了（没有别的已解锁设备、也没有恢复码）时，输入当前密码换一把新的加密钥匙。以前的加密消息只有还留着旧钥匙的设备能看。"
                        : "换一把新的加密钥匙，本机的旧钥匙保留，以前的消息照常能看。其他设备要用密码或恢复码重新解锁。")
        }
        .confirmationDialog(locked ? "重置加密" : "更换加密钥匙", isPresented: $confirm, titleVisibility: .visible) {
            Button(locked ? "重置" : "更换", role: .destructive) { Task { await submit() } }
        } message: {
            Text(E2E.T.t45)
        }
        .confirmationDialog("放弃这次重置？", isPresented: $confirmAbandon, titleVisibility: .visible) {
            Button("放弃这次重置", role: .destructive) { Task { await model.e2eAbandonReset() } }
        } message: {
            Text("不再等这次重置的结果。这次生成的钥匙仍留在本机；之后可以重新重置。")
        }
    }

    private func submit() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await model.e2eReset(password: password)
            password = ""
            expanded = false
            onDone()
        } catch {
            self.error = describe(error)
        }
    }
}

// MARK: 加密发送密钥（§7 第 1 项）

/// Pushkey 详情页的「加密发送密钥」一节：只用本机钉住的账号公钥；没钉住显示 T73，和服务器的对不上显示 T43
struct E2ESendKeySection<Field: View>: View {
    let sendKey: E2E.SendKey
    /// 显示密钥 + 复制按钮（用 Pushkey 页的 CopyField）
    @ViewBuilder let field: (String) -> Field

    var body: some View {
        if sendKey != .hidden {
            Section {
                switch sendKey {
                case .key(let k): field(k)
                case .needsUnlock: Text(E2E.T.t73).font(.footnote).foregroundStyle(Theme.text2)
                case .mismatch: Label(E2E.T.t46, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Theme.danger)
                case .hidden: EmptyView()
                }
            } header: {
                Label("加密发送密钥", systemImage: "lock.fill")
            } footer: {
                if case .key = sendKey { Text(E2E.T.t70) }
            }
        }
    }
}

// MARK: 入口（设置 → 账户与设备）

/// 「账户与设备」页里的入口：显示加密状态，点进去是 E2EView
struct E2EEntrySection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            NavigationLink(value: Route.e2e) {
                LabeledContent {
                    Text(status.text).foregroundStyle(status.color)
                } label: {
                    Label("端到端加密", systemImage: "lock.shield")
                }
            }
        } footer: {
            Text("开启后，新消息的标题、正文和附件只有你登录过的设备能解开，服务器和备份里只有密文。")
        }
    }

    private var status: (text: String, color: Color) {
        if model.supports("e2e") == false { return ("需要服务端 0.7.0", Theme.text3) }
        switch model.e2eStatus {
        case nil: return ("", Theme.text3)
        case .off: return ("未开启", Theme.text2)
        case .locked: return ("这台设备未解锁", Theme.warning)
        case .unlocked: return ("已开启", Theme.success)
        }
    }
}

// MARK: 消息列表、详情页

/// 消息列表顶部：本机还没解锁加密消息（T10），点开进入「端到端加密」页
struct E2ELockedBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button { model.openE2E() } label: {
            HStack(spacing: 8) {
                Text(E2E.T.t10).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.text3)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.warning.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

/// 首页顶部：账号还没开启加密、服务端支持自动开启（§11.1 末尾，T67），不能关闭。
/// 账号有密码：弹出只输当前密码的小窗；没有密码：设置密码（成功后自动开启）。开启后（本机或别的设备）自动消失
struct E2EEnableBanner: View {
    @EnvironmentObject private var model: AppModel
    @State private var sheet: Sheet?

    enum Sheet: String, Identifiable {
        case password, setPassword
        var id: String { rawValue }
    }

    var body: some View {
        Button {
            if model.accountHasPassword == true {
                sheet = .password
            } else if model.accountHasPassword == false && model.canAdmin != false {
                sheet = .setPassword
            } else {
                // 还不知道有没有密码，或者这台设备不能设置初始密码：去「账户与设备」页（那里有说明和入口）
                model.path = [.settings, .account]
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(Theme.accent)
                Text(E2E.T.t67).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if model.e2eAutoSetupRunning { ProgressView() }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.text3)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.e2eAutoSetupRunning)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .sheet(item: $sheet) { s in
            switch s {
            case .password:
                E2EEnableSheet()
            case .setPassword:
                NavigationStack {
                    CredentialsView(hasPassword: false, initialName: model.accountDetail?.account.username ?? model.settings.username) { a in
                        model.noteAccount(a)      // setInitialCredentials 成功后会在后台自动开启（§11.1）
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { sheet = nil } } }
                }
            }
        }
    }
}

/// T67 的小窗：只输当前密码。密码和算出的钥匙都不留在内存里
struct E2EEnableSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("当前密码", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit { Task { await submit() } }
                    errorText(error)
                } footer: {
                    Text(E2E.T.t67)
                }
                Section {
                    Button { Task { await submit() } } label: { BusyLabel(text: busy ? "正在开启…" : "开启", busy: busy) }
                        .disabled(busy || password.isEmpty)
                }
            }
            .navigationTitle("开启端到端加密")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { password = ""; dismiss() }.disabled(busy) } }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(busy)
    }

    private func submit() async {
        guard !password.isEmpty, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await model.e2eEnableWithPassword(password)
            password = ""
            dismiss()
        } catch {
            password = ""
            self.error = describe(error)
        }
    }
}

/// 详情页：解不开的加密消息（标题已是 T60 / T61 / T62，正文为空）
struct E2ELockedBody: View {
    @EnvironmentObject private var model: AppModel
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch message.e2eStatus {
            case "wrong_key":
                Text("这条消息是用别的钥匙加密的（可能换过钥匙，这台设备没有那把旧钥匙），无法解开。")
            case "format":
                Text("这条加密消息的内容格式不对或已被篡改，无法解开。")
            default:
                Text("这条消息是端到端加密的。这台设备解锁后会自动解开，附件也要解锁后才能下载。")
                if model.e2eLocked {
                    Button("去解锁") { model.openE2E() }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .font(.subheadline).foregroundStyle(Theme.text2)
        .fixedSize(horizontal: false, vertical: true)
    }
}
