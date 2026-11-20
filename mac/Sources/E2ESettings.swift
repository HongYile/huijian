import AppKit
import SwiftUI

// 设置 →「加密」：开启端到端加密、保存恢复码、三种解锁方式、重新设置密码、批准其他设备、加密相关的设置项。
// 规格见 docs/e2ee-client.md §3–§7；文案 T20…T72 来自 E2E.T，各端一致。

struct E2ESettings: View {
    @EnvironmentObject var model: AppModel
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.token == nil {
                SettingsCard {
                    SettingsRow(label: "还没有登录", divider: false) {
                        Button("打开回笺登录") { AppDelegate.shared?.showMainWindow(select: nil) }.buttonStyle(SoftButtonStyle())
                    }
                }
            } else if model.support("e2e") == .needsServerUpdate {
                ServerTooOld(feature: "端到端加密", since: "0.7.0", alternative: nil)
            } else if let code = model.e2eRecoveryCode {
                // 恢复码在 App 状态里（关掉窗口再打开还在），点「完成」才清除
                RecoveryCodeCard(code: code) {
                    notice = model.e2eRecoveryFromSetup ? E2E.T.t22 : "已更换恢复码，旧的恢复码已失效。"
                    model.e2eRecoveryDone()
                }
            } else {
                notices
                switch model.e2eStatus {
                case nil:
                    SettingsCard {
                        SettingsRow(label: "正在读取加密状态…", divider: false) {
                            ProgressView().controlSize(.small)
                            Button("刷新") { Task { await model.refreshE2E() } }.buttonStyle(SoftButtonStyle())
                        }
                    }
                case .off:
                    // §11.1：账号一有密码就自动开启；手动开启页只作为自动开启失败时的出口
                    if model.e2eAutoSetupRunning {
                        SettingsCard {
                            SettingsRow(label: E2E.T.autoSetupRunning, divider: false) { ProgressView().controlSize(.small) }
                        }
                    } else if model.e2eAutoSetupFailed {
                        E2ENote(text: E2E.T.autoSetupFailed)
                    }
                    E2ESetupCard()
                case .locked:
                    E2EUnlockCards()
                    E2EResetCard(locked: true)
                case .unlocked:
                    if model.e2eResetDone {
                        // §11.3：换了钥匙，发送端要换成新的加密发送密钥
                        SettingsCard {
                            FormBlock {
                                Label(E2E.T.resetDone, systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 13)).foregroundStyle(Theme.success).fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Spacer()
                                    Button("知道了") { model.e2eResetDone = false }.buttonStyle(SoftButtonStyle())
                                    Button("去 Pushkey 页") {
                                        model.e2eResetDone = false
                                        AppDelegate.shared?.showSettings(tab: .keys)
                                    }
                                    .buttonStyle(SoftButtonStyle())
                                }
                            }
                        }
                    }
                    if model.e2eNeedsPasswordReset { E2EResetPasswordCard() }
                    if model.e2eWeakPassword { E2ENote(text: E2E.T.t24) }
                    if model.e2eState?.hasRecovery == false { E2ERecoveryCard() }
                    E2EStatusCard()
                    E2ERequestsCard()
                    E2EOptionsCard()
                    E2EResetCard(locked: false)
                }
            }
        }
        .task { await model.refreshE2E() }
        // 等待批准、等待核对时每 3 秒刷新一次（长轮询的 e2e 变更也会触发刷新）
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                if model.e2eFastPoll { await model.refreshE2E() }
            }
        }
    }

    @ViewBuilder var notices: some View {
        ForEach([model.e2eStorageError, model.e2eLoginNote, model.e2eSetupNote, model.e2eRecoveryNote, notice].compactMap { $0 }, id: \.self) { t in
            E2ENote(text: t, color: t == notice ? Theme.success : Theme.warning)
        }
    }
}

/// 一行提示（卡片上方）
struct E2ENote: View {
    let text: String
    var color: Color = Theme.warning

    var body: some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.1)))
            .padding(.bottom, 14)
    }
}

/// 卡片里的一段表单（上下留白、左对齐）
private struct FormBlock<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor private func errorText(_ s: String?) -> some View {
    Group {
        if let s { Text(s).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
    }
}

@MainActor private func describe(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? Updater.describe(e) }

/// 大字核对码（3+3）
struct SASCodeView: View {
    let code: String
    var body: some View {
        Text(E2E.formatCode(code))
            .font(.system(size: 30, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.accent)
            .textSelection(.enabled)
    }
}

// MARK: 开启加密（§4.1）

struct E2ESetupCard: View {
    @EnvironmentObject var model: AppModel
    @State private var current = ""
    @State private var changePassword = true
    @State private var new1 = ""
    @State private var new2 = ""
    @State private var busy = false
    @State private var error: String?

    var newProblem: String? {
        guard changePassword, !new1.isEmpty else { return nil }
        return Core.passwordProblem(new1, username: model.accountName)
    }

    var canSubmit: Bool {
        !current.isEmpty && (!changePassword || (!new1.isEmpty && new1 == new2 && newProblem == nil))
    }

    var body: some View {
        SettingsCard(title: E2E.T.t20Title, footer: E2E.T.t20) {
            FormBlock {
                if model.account?.has_password == false {
                    Text("这个账号还没有密码：先在「账户」页设置用户名和密码，再开启加密。").font(.system(size: 12.5)).foregroundStyle(Theme.warning)
                }
                WarmField(placeholder: "当前密码", text: $current, secure: true)
                Toggle("同时换一个新密码（推荐）", isOn: $changePassword).toggleStyle(.checkbox).font(.system(size: 13))
                if changePassword {
                    HStack(spacing: 10) {
                        WarmField(placeholder: "新密码", text: $new1, secure: true)
                        WarmField(placeholder: "确认新密码", text: $new2, secure: true)
                    }
                    if let p = newProblem {
                        Text(p).font(.system(size: 12)).foregroundStyle(Theme.danger)
                    } else if !new2.isEmpty && new1 != new2 {
                        Text("两次输入的新密码不一样").font(.system(size: 12)).foregroundStyle(Theme.danger)
                    } else {
                        Text("旧密码以前以原文发给过服务器，换一个新密码更安全。至少 10 位，不要用常见密码。")
                            .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    }
                }
                errorText(error)
                HStack {
                    Spacer()
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack(spacing: 6) {
                            if busy { ProgressView().controlSize(.small) }
                            Text(busy ? "正在生成钥匙…" : "开启端到端加密")
                        }
                    }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(busy || !canSubmit || model.e2eAutoSetupRunning)      // 自动开启进行中不能手动开启
                }
            }
        }
    }

    func submit() async {
        error = nil
        // 当前密码不合格又没勾选换密码：提示并自动勾选
        if !changePassword, Core.passwordProblem(current, username: model.accountName) != nil {
            error = E2E.T.weakCurrent
            changePassword = true
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await model.e2eSetup(current: current, newPassword: changePassword ? new1 : nil)
            current = ""; new1 = ""; new2 = ""
        } catch let f as E2E.Failure where f.kind == .conflict {
            error = "别的设备刚开启了加密：\(f.message)"
            await model.refreshE2E()
        } catch {
            self.error = describe(error)
        }
    }
}

// MARK: 保存恢复码（T21）

struct RecoveryCodeCard: View {
    let code: String
    let onDone: () -> Void
    @State private var saved = false
    @State private var copied = false
    /// 窗口不是当前窗口（失去焦点、App 进入后台）时遮住恢复码（§4.1），防止被截屏、录屏或旁人看到
    @Environment(\.controlActiveState) private var activeState
    private var masked: Bool { activeState != .key }

    var body: some View {
        SettingsCard(title: E2E.T.t21Title) {
            FormBlock {
                Text(E2E.T.t21).font(.system(size: 13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    if masked {
                        // 不是模糊，而是整个换掉：界面上根本没有恢复码的字
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(code.map { $0 == "-" ? "-" : "•" }))
                                .font(.system(size: 22, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text3)
                            Text("窗口不在前台时遮住，回到这个窗口后显示").font(.system(size: 12)).foregroundStyle(Theme.text3)
                        }
                    } else {
                        Text(code).font(.system(size: 22, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button(copied ? "已复制" : "复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        copied = true
                    }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(masked)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface2))
                Toggle(E2E.T.t21Check, isOn: $saved).toggleStyle(.checkbox).font(.system(size: 13))
                HStack {
                    Spacer()
                    Button("完成", action: onDone).buttonStyle(SoftButtonStyle()).disabled(!saved)
                }
            }
        }
    }
}

// MARK: 已锁定：三种解锁方式（§4.2–§4.4）

struct E2EUnlockCards: View {
    @EnvironmentObject var model: AppModel
    @State private var password = ""
    @State private var recovery = ""
    @State private var busy: String?
    @State private var passwordError: String?
    @State private var recoveryError: String?
    @State private var requestError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 钥匙已更换（别的设备重置过，§11.4）：说明换成 T46，不说「还没有解锁」
            E2ENote(text: model.e2eKeyChanged ? E2E.T.t46
                    : "这个账号已开启端到端加密，这台设备还没有解锁，加密消息暂时只显示「\(E2E.T.t60)」。任选一种方式解锁：")
            SettingsCard(title: "用密码解锁", footer: "输入账号密码，在本机解开服务器上用密码锁住的钥匙（密码不会发给服务器）。") {
                FormBlock {
                    HStack(spacing: 10) {
                        WarmField(placeholder: "账号密码", text: $password, secure: true)
                        Button(busy == "pw" ? "解锁中…" : "解锁") { Task { await unlockPassword() } }
                            .buttonStyle(SoftButtonStyle()).disabled(busy != nil || password.isEmpty)
                    }
                    errorText(passwordError)
                }
            }
            requestCard
            SettingsCard(title: E2E.T.t40Title, footer: "忘记密码、又没有其他设备可以批准时使用。") {
                FormBlock {
                    HStack(spacing: 10) {
                        WarmField(placeholder: E2E.T.t40Placeholder, text: $recovery, mono: true)
                        Button(busy == "rc" ? "解锁中…" : "解锁") { Task { await unlockRecovery() } }
                            .buttonStyle(SoftButtonStyle()).disabled(busy != nil || recovery.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    errorText(recoveryError)
                }
            }
        }
    }

    var requestCard: some View {
        SettingsCard(title: E2E.T.t30Title) {
            FormBlock {
                switch model.e2eRequestPhase {
                case nil:
                    Text(E2E.T.t30).font(.system(size: 13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button(busy == "rq" ? "发送中…" : "发送请求") { Task { await startRequest() } }
                            .buttonStyle(SoftButtonStyle()).disabled(busy != nil)
                    }
                case .waiting:
                    Text(E2E.T.t30).font(.system(size: 13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("等待另一台设备接手…").font(.system(size: 12.5)).foregroundStyle(Theme.text3)
                        Spacer()
                        Button("取消") { Task { await model.e2eCancelRequest() } }.buttonStyle(SoftButtonStyle())
                    }
                case .code(let c):
                    SASCodeView(code: c)
                    Text(E2E.T.t31(c)).font(.system(size: 13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("取消") { Task { await model.e2eCancelRequest() } }.buttonStyle(SoftButtonStyle())
                    }
                case .granted:
                    Label("已解锁", systemImage: "checkmark.circle.fill").font(.system(size: 13.5)).foregroundStyle(Theme.success)
                case .denied:
                    Text(E2E.T.t32).font(.system(size: 13)).foregroundStyle(Theme.danger)
                    HStack {
                        Spacer()
                        Button("重新请求") { Task { await startRequest() } }.buttonStyle(SoftButtonStyle()).disabled(busy != nil)
                    }
                case .failed(let m):
                    Text(m).font(.system(size: 13)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("关闭") { model.e2eDismissRequest() }.buttonStyle(SoftButtonStyle())
                        Button("重新请求") { Task { model.e2eDismissRequest(); await startRequest() } }.buttonStyle(SoftButtonStyle()).disabled(busy != nil)
                    }
                }
                errorText(requestError)
            }
        }
    }

    func unlockPassword() async {
        busy = "pw"; passwordError = nil
        defer { busy = nil }
        do { try await model.e2eUnlock(password: password); password = "" } catch { passwordError = describe(error) }
    }

    func unlockRecovery() async {
        busy = "rc"; recoveryError = nil
        defer { busy = nil }
        do { try await model.e2eUnlock(recovery: recovery); recovery = "" } catch { recoveryError = describe(error) }
    }

    func startRequest() async {
        busy = "rq"; requestError = nil
        defer { busy = nil }
        do { try await model.e2eStartRequest() } catch { requestError = describe(error) }
    }
}

// MARK: 重新设置密码（§4.4.4，T42）

struct E2EResetPasswordCard: View {
    @EnvironmentObject var model: AppModel
    @State private var current = ""
    @State private var new1 = ""
    @State private var new2 = ""
    @State private var busy = false
    @State private var error: String?

    var problem: String? { new1.isEmpty ? nil : Core.passwordProblem(new1, username: model.accountName) }

    var body: some View {
        SettingsCard(title: E2E.T.t42Title, footer: E2E.T.t42) {
            FormBlock {
                WarmField(placeholder: "当前密码（管理员给你的临时密码）", text: $current, secure: true)
                Text(E2E.T.t42Field).font(.system(size: 12)).foregroundStyle(Theme.warning)
                HStack(spacing: 10) {
                    WarmField(placeholder: "新密码", text: $new1, secure: true)
                    WarmField(placeholder: "确认新密码", text: $new2, secure: true)
                }
                if let problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(Theme.danger)
                } else if !new2.isEmpty && new1 != new2 {
                    Text("两次输入的新密码不一样").font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
                errorText(error)
                HStack {
                    Spacer()
                    Button(busy ? "保存中…" : "设置新密码") { Task { await submit() } }
                        .buttonStyle(SoftButtonStyle())
                        .disabled(busy || current.isEmpty || new1.isEmpty || new1 != new2 || problem != nil)
                }
            }
        }
    }

    func submit() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await model.e2eResetPassword(current: current, newPassword: new1)
            current = ""; new1 = ""; new2 = ""
        } catch { self.error = describe(error) }
    }
}

// MARK: 状态（§7.6）

struct E2EStatusCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let st = model.e2eState
        SettingsCard(title: "端到端加密") {
            SettingsRow(label: "状态") {
                Label("已开启 · 钥匙 \(String((st?.activeKey?.kid ?? "").prefix(8)))", systemImage: "lock.fill")
                    .font(.system(size: 13.5)).foregroundStyle(Theme.success).textSelection(.enabled)
            }
            SettingsRow(label: "本机") {
                Text("已解锁，可以查看加密消息").font(.system(size: 13.5)).foregroundStyle(Theme.text2)
            }
            SettingsRow(label: "恢复码", divider: !(st?.server_seal ?? false)) {
                Text(st?.hasRecovery == true ? "已设置" : "未设置")
                    .font(.system(size: 13.5)).foregroundStyle(st?.hasRecovery == true ? Theme.text2 : Theme.warning)
            }
            if st?.server_seal == true {
                // §11.5：服务器代加密始终开启，没有开关，只读说明 T65
                SettingsRow(label: "服务器代加密", divider: false) {
                    Text("始终开启")
                        .font(.system(size: 13.5)).foregroundStyle(Theme.text2)
                }
                Text(E2E.T.t65).font(.system(size: 12)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
            }
        }
    }
}

// MARK: 恢复码可选（§11.2）

struct E2ERecoveryCard: View {
    @EnvironmentObject var model: AppModel
    @State private var open = false
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        SettingsCard(title: "恢复码") {
            FormBlock {
                Text(E2E.T.t23).font(.system(size: 13)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                if open {
                    HStack(spacing: 10) {
                        WarmField(placeholder: "先输入当前密码", text: $password, secure: true)
                        Button("取消") { open = false; password = ""; error = nil }.buttonStyle(SoftButtonStyle())
                        Button(busy ? "生成中…" : "生成恢复码") { Task { await submit() } }
                            .buttonStyle(SoftButtonStyle()).disabled(busy || password.isEmpty)
                    }
                } else {
                    HStack {
                        Spacer()
                        Button("设置恢复码") { open = true }.buttonStyle(SoftButtonStyle())
                    }
                }
                errorText(error)
            }
        }
    }

    func submit() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await model.e2eRotateRecovery(password: password)      // 和更换恢复码同一个接口（§7 第 3 项）
            password = ""; open = false
        } catch { self.error = describe(error) }
    }
}

// MARK: 重置加密 / 更换加密钥匙（§11.3）

struct E2EResetCard: View {
    @EnvironmentObject var model: AppModel
    /// 锁定时是「都不行？重置加密」，已解锁时是「更换加密钥匙」
    let locked: Bool
    @State private var open = false
    @State private var password = ""
    @State private var confirm = false
    @State private var busy = false
    @State private var error: String?
    @State private var confirmAbandon = false

    var body: some View {
        SettingsCard(title: locked ? "都不行？重置加密" : "更换加密钥匙",
                     footer: locked ? "忘了密码、没有其他已解锁的设备、也没有恢复码时，用当前密码换一把新的加密钥匙。以前的加密消息在这台设备上解不开。"
                                    : "换一把新的加密钥匙：以后的新消息用新钥匙加密，本机仍保留旧钥匙，能看以前的消息。") {
            FormBlock {
                // 上次的重置结果不确定（提示在页面上方）：可以不等了，放弃这次重置
                if model.e2eResetPending && !open {
                    HStack {
                        Text("上次的重置还没有结果").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                        Spacer()
                        Button("放弃这次重置…") { confirmAbandon = true }.buttonStyle(SoftButtonStyle())
                    }
                }
                if open {
                    HStack(spacing: 10) {
                        WarmField(placeholder: "当前密码", text: $password, secure: true)
                        Button("取消") { open = false; password = ""; error = nil }.buttonStyle(SoftButtonStyle())
                        Button(busy ? "正在生成钥匙…" : (locked ? "重置加密" : "更换")) { confirm = true }
                            .buttonStyle(SoftButtonStyle(destructive: true)).disabled(busy || password.isEmpty)
                    }
                } else {
                    HStack {
                        Spacer()
                        Button(locked ? "重置加密…" : "更换…") { open = true; error = nil }.buttonStyle(SoftButtonStyle(destructive: true))
                    }
                }
                errorText(error)
            }
        }
        .confirmationDialog(E2E.T.t45, isPresented: $confirm) {
            Button(locked ? "重置" : "更换", role: .destructive) { Task { await submit() } }
        }
        .confirmationDialog("放弃这次重置？", isPresented: $confirmAbandon) {
            Button("放弃这次重置", role: .destructive) { Task { await model.e2eAbandonReset() } }
        } message: {
            Text("不再等这次重置的结果。这次生成的钥匙仍留在本机；之后可以重新重置。")
        }
    }

    func submit() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await model.e2eReset(password: password)
            password = ""; open = false
        } catch { self.error = describe(error) }
    }
}

// MARK: 等待批准的设备（§5）

struct E2ERequestsCard: View {
    @EnvironmentObject var model: AppModel
    @State private var error: String?
    @State private var busy: String?
    /// 处理完、已从请求列表消失的设备名（显示结果用）
    @State private var names: [String: String] = [:]

    var body: some View {
        let reqs = model.e2eState?.requests ?? []
        let finished = model.e2eApprovalPhases.keys.filter { id in !reqs.contains { $0.device_id == id } }.sorted()
        if !reqs.isEmpty || !finished.isEmpty {
            SettingsCard(title: "等待批准的设备", footer: error ?? "批准前先核对两台设备上的 6 位核对码是否一致；不一致说明可能有人冒充，请拒绝。") {
                ForEach(Array(reqs.enumerated()), id: \.element.device_id) { i, r in
                    row(r, last: i == reqs.count - 1 && finished.isEmpty)
                }
                ForEach(finished, id: \.self) { id in
                    finishedRow(id, last: id == finished.last)
                }
            }
            .onAppear { for r in reqs { names[r.device_id] = r.name } }
            .onChange(of: reqs) { _, v in for r in v { names[r.device_id] = r.name } }
        }
    }

    func row(_ r: E2E.Request, last: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: r.platform == "macos" ? "laptopcomputer" : (r.platform == "ios" ? "iphone" : "desktopcomputer"))
                    .font(.system(size: 15)).foregroundStyle(Theme.text2).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name.isEmpty ? "新设备" : r.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                    Text("\(r.platform) · 请求于 \(date(r.requested_at))").font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
                Spacer()
                if model.e2eApprovalPhases[r.device_id] == nil {
                    Button(busy == r.device_id ? "处理中…" : "批准") { act(r.device_id) { try await model.e2eBeginApproval(r) } }
                        .buttonStyle(SoftButtonStyle()).disabled(busy != nil)
                    Button("拒绝") { act(r.device_id) { try await model.e2eDeny(r.device_id) } }
                        .buttonStyle(SoftButtonStyle(destructive: true)).disabled(busy != nil)
                }
            }
            switch model.e2eApprovalPhases[r.device_id] {
            case .challenged:
                // §5 第 2 步：等待期间可以拒绝（发 deny），也可以只停止本机的等待
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("等待新设备显示核对码…").font(.system(size: 12.5)).foregroundStyle(Theme.text3)
                    Spacer()
                    Button("拒绝") { act(r.device_id) { try await model.e2eDeny(r.device_id) } }
                        .buttonStyle(SoftButtonStyle(destructive: true)).disabled(busy != nil)
                    Button("取消") { model.e2eCancelApproval(r.device_id) }
                        .buttonStyle(SoftButtonStyle()).disabled(busy != nil)
                }
                .padding(.leading, 31)
            case .code(let c):
                VStack(alignment: .leading, spacing: 8) {
                    SASCodeView(code: c)
                    Text(E2E.T.t53(c)).font(.system(size: 13)).foregroundStyle(Theme.text2)
                    HStack(spacing: 8) {
                        Button("一致，批准") { act(r.device_id) { try await model.e2eApprove(r.device_id) } }
                            .buttonStyle(SoftButtonStyle()).disabled(busy != nil)
                        Button("不一致，拒绝") { act(r.device_id) { try await model.e2eDeny(r.device_id) } }
                            .buttonStyle(SoftButtonStyle(destructive: true)).disabled(busy != nil)
                    }
                }
                .padding(.leading, 31)
            case .failed(let m):
                result(r.device_id, m, Theme.danger)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1) } }
    }

    func finishedRow(_ id: String, last: Bool) -> some View {
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
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1) } }
    }

    func result(_ id: String, _ text: String, _ color: Color) -> some View {
        HStack {
            Text(text).font(.system(size: 13)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("关闭") { model.e2eForgetApproval(id) }.buttonStyle(SoftButtonStyle())
        }
    }

    func act(_ id: String, _ f: @escaping () async throws -> Void) {
        Task {
            busy = id; error = nil
            defer { busy = nil }
            do { try await f() } catch { self.error = describe(error) }
        }
    }

    func date(_ t: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }
}

// MARK: 设置项（§7.3）

struct E2EOptionsCard: View {
    @EnvironmentObject var model: AppModel
    @State private var rotating = false
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?

    // 0.9.0 起没有「只接受加密消息」和「删除服务器上的明文消息」（所有消息都加密，§7 第 2、4 项）
    var body: some View {
        SettingsCard(title: "设置", footer: message ?? "改密码在「账户」页：已开启加密时，新密码会重新锁住本机的钥匙。") {
            SettingsRow(label: model.e2eState?.hasRecovery == false ? "设置恢复码" : "更换恢复码", divider: rotating) {
                if !rotating {
                    Button("更换…") { rotating = true; message = nil }.buttonStyle(SoftButtonStyle())
                }
            }
            if rotating {
                HStack(spacing: 10) {
                    WarmField(placeholder: "先输入当前密码", text: $password, secure: true)
                    Button("取消") { rotating = false; password = "" }.buttonStyle(SoftButtonStyle())
                    Button(busy ? "生成中…" : "生成新的恢复码") { Task { await rotate() } }
                        .buttonStyle(SoftButtonStyle()).disabled(busy || password.isEmpty)
                }
                .padding(.bottom, 12)
            }
        }
    }

    func rotate() async {
        busy = true; message = nil
        defer { busy = false }
        do {
            try await model.e2eRotateRecovery(password: password)
            password = ""
            rotating = false
        } catch { message = describe(error) }
    }
}
