import SwiftUI
import UIKit
import UniformTypeIdentifiers

// 设置 →「管理」：Pushkey、账户与设备、频道。和 Mac 客户端的「Pushkey」「账户」页、侧栏频道菜单对齐。
// 权限以服务端为准：操作失败时直接显示服务端返回的说明（例如没有「允许管理」时不能设置初始密码、不能移除有管理权限的设备）；
// 旧服务端没有某个接口时显示「需要服务端 x 以上」。危险操作（吊销、删除、移除设备）都要二次确认。

/// 操作结果提示（页面顶部）
struct ManageNotice: Equatable {
    let text: String
    var ok = true

    static func failed(_ what: String, _ e: Error) -> ManageNotice { ManageNotice(text: "\(what)：\(shortError(e))", ok: false) }
}

private struct NoticeSection: View {
    let notice: ManageNotice?

    var body: some View {
        if let notice {
            Section {
                Label(notice.text, systemImage: notice.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(notice.ok ? Theme.success : Theme.danger)
            }
        }
    }
}

/// 服务端太旧、没有这个功能
private struct TooOldSection: View {
    let text: String
    var alternative: String?

    var body: some View {
        Section {
            Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).font(.subheadline)
        } footer: {
            if let alternative { Text(alternative) }
        }
    }
}

/// 等宽文字 + 复制按钮
private struct CopyField: View {
    let text: String
    var lines = 1
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text).font(.footnote.monospaced()).foregroundStyle(Theme.text).lineLimit(lines).truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "已复制" : "复制") {
                copySecret(text)
                copied = true
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }
}

/// 复制 key、发送示例：只留在本机剪贴板（不经通用剪贴板同步到其他苹果设备），5 分钟后自动清掉
func copySecret(_ text: String) {
    UIPasteboard.general.setItems([[UTType.plainText.identifier: text]],
                                  options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
}

private func statusTag(_ t: String, _ c: Color) -> some View {
    Text(t).font(.caption2.weight(.medium)).foregroundStyle(c)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(c.opacity(0.12)))
}

private func dateText(_ t: Int64) -> String {
    t > 0 ? TimeText.full(Date(timeIntervalSince1970: TimeInterval(t))) : "—"
}

// MARK: - Pushkey

struct KeysView: View {
    @EnvironmentObject private var model: AppModel
    @State private var loading = false
    @State private var unsupported = false
    @State private var notice: ManageNotice?
    @State private var showNew = false
    /// 刚新建的 key：进入它的详情页（优先显示加密发送密钥，docs/e2ee-client.md §11.6）
    @State private var created: PushKey?
    @State private var revokeTarget: PushKey?
    @State private var deleteTarget: PushKey?

    /// 列表放在 AppModel 里：别的设备或管理后台改了 key（变更流里的 keys），这里立刻显示新数据
    private var keys: [PushKey] { model.keys ?? [] }
    private var modes: [Int64: String]? { model.keyModes }
    private var loaded: Bool { model.keys != nil }
    private var active: [PushKey] { keys.filter { !$0.isRevoked } }
    private var revoked: [PushKey] { keys.filter(\.isRevoked) }
    private var canDelete: Bool { model.supports("keys.delete") != false }

    var body: some View {
        List {
            if unsupported {
                TooOldSection(text: APIError.unsupported.errorDescription ?? "", alternative: "现在可以先在服务器管理后台的「Pushkey」页管理。")
            } else if let old = model.tooOld("keys", since: "0.4.2") {
                TooOldSection(text: old, alternative: "现在可以先在服务器管理后台的「Pushkey」页管理。")
            } else {
                NoticeSection(notice: notice)
                Section {
                    if active.isEmpty {
                        Text(loading && !loaded ? "正在加载…" : "还没有有效的 pushkey，点右上角「+」新建")
                            .foregroundStyle(Theme.text2)
                    }
                    ForEach(active) { k in
                        NavigationLink {
                            KeyDetailView(key: k)
                        } label: { KeyRow(key: k, mode: modes?[k.id], sendKey: model.e2eSendKey(k.key)) }
                        .swipeActions(edge: .trailing) {
                            Button("吊销") { revokeTarget = k }.tint(Theme.danger)
                        }
                        // 默认复制加密发送密钥（§11.6）；账号没开启加密、本机还没解锁过时复制普通 key
                        .swipeActions(edge: .leading) {
                            Button("复制") { copyDefault(k) }.tint(Theme.accent)
                        }
                        .contextMenu {
                            if case .key(let sk) = model.e2eSendKey(k.key) {
                                Button { copySecret(sk); notice = .init(text: "已复制「\(k.name)」的加密发送密钥（只在本机，5 分钟后清除）") } label: {
                                    Label("复制加密发送密钥", systemImage: "lock")
                                }
                                Button { copySecret(k.key); notice = .init(text: "已复制「\(k.name)」的普通 pushkey（只在本机，5 分钟后清除）") } label: {
                                    Label("复制普通 pushkey", systemImage: "doc.on.doc")
                                }
                            } else {
                                Button { copySecret(k.key) } label: { Label("复制 key", systemImage: "doc.on.doc") }
                            }
                            Button(role: .destructive) { revokeTarget = k } label: { Label("吊销…", systemImage: "nosign") }
                        }
                    }
                } header: {
                    // 不要自动转大写（用户名、Pushkey 保持原样）
                    Text(model.settings.username.isEmpty ? "Pushkey" : "账号「\(model.settings.username)」的 Pushkey").textCase(nil)
                } footer: {
                    Text("pushkey 属于账号：这个账号的所有设备看到的是同一组。发送方用 pushkey 把消息发给你。建议每台机器、每个项目各用一把，泄露时只吊销那一把。左滑吊销，右滑复制（有加密发送密钥时复制它），点进去可以改名、换 key、看发送示例和普通 pushkey。")
                }
                if !revoked.isEmpty {
                    Section {
                        ForEach(revoked) { k in
                            KeyRow(key: k, mode: nil)
                                .swipeActions(edge: .trailing) {
                                    if canDelete { Button("删除") { deleteTarget = k }.tint(Theme.danger) }
                                }
                                .contextMenu {
                                    if canDelete {
                                        Button(role: .destructive) { deleteTarget = k } label: { Label("删除…", systemImage: "trash") }
                                    }
                                }
                        }
                    } header: {
                        Text("已吊销")
                    } footer: {
                        Text(canDelete ? "已吊销的 key 不能再发送。左滑可以彻底删除，历史消息保留。" : "已吊销的 key 不能再发送。删除需要服务端 0.5.2 以上。")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Pushkey")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "plus") }
                    .disabled(unsupported || model.tooOld("keys", since: "0.4.2") != nil)
                    .accessibilityLabel("新建 pushkey")
            }
        }
        .refreshable { await reload() }
        .task {
            // 每次打开都拉一次（之前拉过的先显示着）
            async let e2e: Void = model.refreshE2E()      // 加密发送密钥要用账号的公钥
            await reload()
            await e2e
            if UserDefaults.standard.bool(forKey: "demoNewKey") { showNew = true }
        }
        .sheet(isPresented: $showNew) {
            NewKeySheet(defaultName: active.isEmpty ? "default" : "") { k, gen in
                model.noteKey(k, session: gen)
                notice = .init(text: "已新建「\(k.name)」")
                created = k
            }
        }
        .navigationDestination(item: $created) { k in KeyDetailView(key: k) }
        .confirmationDialog("吊销「\(revokeTarget?.name ?? "")」？", isPresented: Binding(get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } }),
                            titleVisibility: .visible) {
            Button("吊销", role: .destructive) { if let t = revokeTarget { Task { await revoke(t) } } }
        } message: {
            Text("吊销后，使用它的脚本和服务将无法再发送，不能恢复。")
        }
        .confirmationDialog("彻底删除「\(deleteTarget?.name ?? "")」？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let t = deleteTarget { Task { await delete(t) } } }
        } message: {
            Text("删除后列表里不再显示，历史消息会保留。这个 key 字符串以后也不能再用。")
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            try await model.reloadKeys()
        } catch APIError.unsupported {
            unsupported = true
        } catch {
            notice = .failed("加载失败", error)
        }
    }

    /// 右滑「复制」：有加密发送密钥时复制它（§11.6），否则复制普通 key
    private func copyDefault(_ k: PushKey) {
        if case .key(let sk) = model.e2eSendKey(k.key) {
            copySecret(sk)
            notice = .init(text: "已复制「\(k.name)」的加密发送密钥（只在本机，5 分钟后清除）")
        } else {
            copySecret(k.key)
            notice = .init(text: "已复制「\(k.name)」的 key（只在本机，5 分钟后清除）")
        }
    }

    private func revoke(_ k: PushKey) async {
        let gen = model.session
        do {
            model.noteKey(try await model.requireAPI().revokeKey(id: k.id), session: gen)
            notice = .init(text: "已吊销「\(k.name)」")
        } catch {
            notice = .failed("吊销失败", error)
        }
    }

    private func delete(_ k: PushKey) async {
        let gen = model.session
        do {
            try await model.requireAPI().deleteKey(id: k.id)
            model.noteKeyRemoved(k.id, session: gen)
            notice = .init(text: "已删除「\(k.name)」")
        } catch APIError.http(404, _) {
            model.noteKeyRemoved(k.id, session: gen)
            notice = .init(text: "「\(k.name)」已不存在（可能在别的设备上删除了）")
        } catch APIError.unsupported {
            notice = .init(text: "删除需要服务端 0.5.2 以上，更新服务端后可用", ok: false)
        } catch {
            notice = .failed("删除失败", error)
        }
    }
}

private struct KeyRow: View {
    let key: PushKey
    let mode: String?
    /// 加密发送密钥 <pushkey>.e2e.<钉住的公钥>（账号开启了端到端加密才有；没钉住 / 对不上时只显示说明）
    var sendKey: E2E.SendKey = .hidden

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(key.name).font(.body.weight(.medium)).foregroundStyle(key.isRevoked ? Theme.text3 : Theme.text).lineLimit(1)
                if key.isRevoked { statusTag("已吊销", Theme.danger) }
                if let m = mode, m != "notify" { statusTag(m == "silent" ? "本机静默" : "本机不接收", Theme.warning) }
            }
            // 有加密发送密钥时只显示它（默认用它发送，§11.6）；普通 key 收在详情页的「显示普通 pushkey」里
            if !key.isRevoked, case .key(let k) = sendKey {
                Label {
                    Text(k).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                } icon: { Image(systemName: "lock.fill") }
                    .font(.caption).foregroundStyle(Theme.text2)
                    .accessibilityLabel("加密发送密钥")
            } else {
                Text(key.key).font(.caption.monospaced()).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                    .strikethrough(key.isRevoked)
                if !key.isRevoked, sendKey != .hidden {
                    Label {
                        switch sendKey {
                        case .mismatch: Text(E2E.T.t46).font(.caption).foregroundStyle(Theme.danger).lineLimit(2)
                        default: Text("加密发送密钥：" + E2E.T.t73).font(.caption).lineLimit(2)
                        }
                    } icon: { Image(systemName: "lock.fill") }
                        .font(.caption).foregroundStyle(Theme.text2)
                        .accessibilityLabel("加密发送密钥")
                }
            }
            if !key.isRevoked {
                Text(key.last_used.map { "最近使用 " + TimeText.relative($0) } ?? "从未使用").font(.caption).foregroundStyle(Theme.text2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 新建 pushkey：名称 + 可选自定义 key（留空自动生成）
private struct NewKeySheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let defaultName: String
    /// (新建的 key, 发请求前的 session)
    let onCreated: (PushKey, Int) -> Void
    @State private var name = ""
    @State private var key = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称，例如 训练服务器", text: $name)
                } header: { Text("名称") } footer: { Text("只是给自己看的备注，最多 \(ManageRules.keyNameMax) 个字，以后可以改。") }
                Section {
                    TextField("留空自动生成", text: $key)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("随机生成一个") { key = ManageRules.randomKey() }
                } header: { Text("自定义 key（可选）") } footer: {
                    Text(ManageRules.keyProblem(key) ?? "\(ManageRules.keyRule)。留空由服务器生成；不能和任何已有的 key（包括已吊销的）重复。")
                        .foregroundStyle(ManageRules.keyProblem(key) == nil ? Theme.text2 : Theme.danger)
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger).font(.subheadline) }
                }
            }
            .navigationTitle("新建 Pushkey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("新建") { Task { await create() } }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || ManageRules.keyProblem(key) != nil)
                    }
                }
            }
            .onAppear { if name.isEmpty { name = defaultName } }
        }
    }

    private func create() async {
        busy = true
        error = nil
        defer { busy = false }
        let gen = model.session
        do {
            let k = try await model.requireAPI().createKey(name: ManageRules.clip(name, ManageRules.keyNameMax),
                                                           key: key.trimmingCharacters(in: .whitespaces))
            onCreated(k, gen)
            dismiss()
        } catch {
            self.error = shortError(error)
        }
    }
}

/// 一把 pushkey 的详情：改名、复制、换 key、发送示例、测试消息、本机接收方式、吊销
struct KeyDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// 打开时的数据；之后以 AppModel 里的列表为准（别的设备改名、换 key、吊销会立刻显示）
    let initial: PushKey

    @State private var name = ""
    @State private var notice: ManageNotice?
    @State private var busy = false
    @State private var showRekey = false
    @State private var newKey = ""
    @State private var confirmRekey = false
    @State private var confirmRevoke = false
    @State private var testing = false
    @State private var showPlain = false

    init(key: PushKey) { initial = key }

    private var hasSendKey: Bool {
        if !key.isRevoked, !gone, case .key = model.e2eSendKey(key.key) { return true }
        return false
    }

    @ViewBuilder private var plainKeyRows: some View {
        CopyField(text: key.key, lines: 2)
        if !key.isRevoked && !gone {
            Button("换一个 key…") { newKey = ManageRules.randomKey(); showRekey = true }
        }
    }

    private var key: PushKey { model.keys?.first { $0.id == initial.id } ?? initial }
    /// 在别的设备上被删除了
    private var gone: Bool { model.keys.map { list in !list.contains { $0.id == initial.id } } ?? false }
    private var mode: String? { model.keyModes.map { $0[initial.id] ?? "notify" } }

    var body: some View {
        let ex = ManageRules.sendExamples(server: model.settings.server, key: key.key)
        Form {
            if gone {
                Section { Label("这把 key 已在其他设备或管理后台删除", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning) }
            } else if key.isRevoked {
                Section { Label("这把 key 已吊销，不能再发送", systemImage: "nosign").foregroundStyle(Theme.danger) }
            }
            NoticeSection(notice: notice)
            Section("名称") {
                HStack {
                    TextField("名称", text: $name)
                    if name != key.name {
                        Button("保存") { Task { await save(name: name, key: "") } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            // 账号开启了端到端加密：默认用加密发送密钥 <pushkey>.e2e.<钉住的公钥>（§7 第 1 项、§11.6），放在最前面
            if !key.isRevoked && !gone {
                E2ESendKeySection(sendKey: model.e2eSendKey(key.key)) { CopyField(text: $0, lines: 3) }
            }
            Section {
                if hasSendKey {
                    // 普通 key 收进折叠项（T66）
                    DisclosureGroup("显示普通 pushkey", isExpanded: $showPlain) { plainKeyRows }
                } else {
                    plainKeyRows
                }
            } header: { Text(hasSendKey ? "普通 pushkey" : "Key") } footer: {
                Text((hasSendKey ? E2E.T.t66 + "\n" : "") + "创建于 \(key.created_at.map { TimeText.full($0) } ?? "—")；"
                     + (key.last_used.map { "最近使用 \(TimeText.full($0))" } ?? "从未使用"))
            }
            if let m = mode, !key.isRevoked, !gone {
                Section {
                    Picker("本机", selection: Binding(get: { m }, set: { v in Task { await setMode(v) } })) {
                        Text("提醒").tag("notify")
                        Text("静默").tag("silent")
                        Text("不接收").tag("off")
                    }
                } header: { Text("这台手机怎么接收") } footer: {
                    Text("提醒 = 按通知设置提醒；静默 = 只进列表；不接收 = 本机看不到。每台设备分别设置，例如告警只让手机响。")
                }
            }
            Section {
                Text("浏览器或脚本里打开：").font(.footnote).foregroundStyle(Theme.text2)
                CopyField(text: ex.url, lines: 3)
                Text("curl（带正文和优先级）：").font(.footnote).foregroundStyle(Theme.text2)
                CopyField(text: ex.curl, lines: 4)
                if !key.isRevoked && !gone {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Label("用这把 key 给自己发一条测试消息", systemImage: "paperplane")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing)
                }
            } header: { Text("发送示例") } footer: {
                Text("参数见文档：text 标题、desp 正文（回笺 Markdown）、priority 0–5、topic 频道，也可以带附件。")
            }
            if !key.isRevoked && !gone {
                Section {
                    Button("吊销这把 key…", role: .destructive) { confirmRevoke = true }
                } footer: {
                    Text("吊销后，使用它的脚本和服务将无法再发送。")
                }
            }
        }
        .disabled(gone)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(key.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if name.isEmpty { name = key.name } }
        // 别的设备改了名：输入框里没改过的话跟着更新
        .onChange(of: key.name) { old, new in if name == old { name = new } }
        .sheet(isPresented: $showRekey) {
            NavigationStack {
                Form {
                    Section {
                        TextField("新 key", text: $newKey).font(.body.monospaced())
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("重新随机生成") { newKey = ManageRules.randomKey() }
                    } footer: {
                        Text(ManageRules.keyProblem(newKey) ?? "换 key 后旧 key「\(key.key)」立即失效，正在使用它的脚本需要改成新 key。")
                            .foregroundStyle(ManageRules.keyProblem(newKey) == nil ? Theme.warning : Theme.danger)
                    }
                }
                .navigationTitle("换一个 key")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { showRekey = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("更换") { confirmRekey = true }
                            .disabled(newKey.isEmpty || newKey == key.key || ManageRules.keyProblem(newKey) != nil)
                    }
                }
                .confirmationDialog("确定更换？", isPresented: $confirmRekey, titleVisibility: .visible) {
                    Button("更换，旧 key 立即失效", role: .destructive) {
                        showRekey = false
                        Task { await save(name: "", key: newKey.trimmingCharacters(in: .whitespaces)) }
                    }
                } message: {
                    Text("旧 key 立即失效，正在使用它的脚本需要改成新 key。")
                }
            }
        }
        .confirmationDialog("吊销「\(key.name)」？", isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button("吊销", role: .destructive) { Task { await revoke() } }
        } message: {
            Text("吊销后，使用它的脚本和服务将无法再发送，不能恢复。")
        }
    }

    private func save(name n: String, key k: String) async {
        busy = true
        defer { busy = false }
        let gen = model.session
        do {
            let saved = try await model.requireAPI().updateKey(id: key.id, name: n == key.name ? "" : ManageRules.clip(n, ManageRules.keyNameMax),
                                                              key: k)
            model.noteKey(saved, session: gen)
            name = saved.name
            notice = .init(text: k.isEmpty ? "名称已保存" : "已换成新 key，旧 key 已失效")
        } catch {
            notice = .failed("保存失败", error)
        }
    }

    private func setMode(_ m: String) async {
        let old = mode ?? "notify"
        let gen = model.session
        model.noteKeyMode(key.id, m, session: gen)
        do {
            try await model.requireAPI().setSubscription(keyID: key.id, mode: m)
        } catch {
            model.noteKeyMode(key.id, old, session: gen)
            notice = .failed("保存失败", error)
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            try await model.sendTestPush(with: key)
            notice = .init(text: mode == "off" ? "已发送（这把 key 在本机设为不接收，列表里不会出现）" : "已发送，等它出现在列表里")
        } catch {
            notice = .failed("发送失败", error)
        }
    }

    private func revoke() async {
        let gen = model.session
        do {
            let r = try await model.requireAPI().revokeKey(id: key.id)
            model.noteKey(r, session: gen)
            dismiss()
        } catch {
            notice = .failed("吊销失败", error)
        }
    }
}

// MARK: - 账户与设备

struct AccountManageView: View {
    @EnvironmentObject private var model: AppModel
    @State private var loading = false
    @State private var unsupported = false
    @State private var notice: ManageNotice?
    @State private var revokeTarget: DeviceInfo?
    @State private var nameDraft = ""
    @State private var savingName = false

    /// 账号详情放在 AppModel 里：别的设备加入、改名、被移除，用户名在别处改了（变更流里的 devices / account），这里立刻显示
    private var detail: AccountDetail? { model.accountDetail }
    private var devices: [DeviceInfo] { (detail?.devices ?? []).filter { !$0.revoked } }
    /// 本机名称：以服务端设备列表为准
    private var currentName: String { devices.first { $0.current }?.name ?? model.settings.deviceName }

    var body: some View {
        List {
            if unsupported {
                TooOldSection(text: APIError.unsupported.errorDescription ?? "")
            } else if let old = model.tooOld("account", since: "0.5.0") {
                TooOldSection(text: old)
            } else {
                NoticeSection(notice: notice)
                accountSection
                if model.loggedIn { E2EEntrySection() }
                PairCodeSection(onUsed: { Task { await load() } })
                devicesSection
            }
            thisDeviceSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("账户与设备")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            if nameDraft.isEmpty { nameDraft = model.settings.deviceName }
            async let e2e: Void = model.refreshE2E()
            await load()
            await e2e
        }
        // 本机名在别处改了（设备列表随变更流刷新）：输入框里没改过的话跟着更新
        .onChange(of: currentName) { old, new in if nameDraft == old { nameDraft = new } }
        .confirmationDialog("移除「\(revokeTarget?.name ?? "")」？", isPresented: Binding(get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } }),
                            titleVisibility: .visible) {
            Button("移除", role: .destructive) { if let t = revokeTarget { Task { await revoke(t) } } }
        } message: {
            Text("移除后，它需要重新配对或登录才能接收消息。")
        }
    }

    private var accountSection: some View {
        let hasPassword = detail?.account.has_password ?? model.accountHasPassword
        let name = detail?.account.username ?? model.settings.username
        return Section {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(name.isEmpty ? Theme.surface2 : Theme.accent)
                    if let c = name.first {
                        Text(String(c).uppercased()).font(.title3.weight(.semibold)).foregroundStyle(.white)
                    } else {
                        Image(systemName: "person.fill").foregroundStyle(Theme.text3)
                    }
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? "未设置用户名" : name).font(.headline).foregroundStyle(name.isEmpty ? Theme.warning : Theme.text)
                    Text(serverHost + (detail.map { _ in " · \(devices.count) 台设备" } ?? ""))
                        .font(.footnote).foregroundStyle(Theme.text2).lineLimit(1)
                }
            }
            .padding(.vertical, 2)
            if hasPassword == nil {
                // 还不知道账号有没有密码（/v1/me、账号详情都还没返回）：不能当成「设置初始密码」，先禁用（审查 M1）
                HStack {
                    Text("修改用户名和密码").foregroundStyle(Theme.text3)
                    Spacer()
                    ProgressView()
                }
                .accessibilityLabel("正在读取账号信息")
            } else if hasPassword == true || model.canAdmin != false {
                NavigationLink {
                    CredentialsView(hasPassword: hasPassword == true, initialName: name) { a in
                        notice = .init(text: "已保存")
                        model.noteAccount(a)
                        Task { await load() }
                    }
                } label: {
                    Text(hasPassword == true ? "修改用户名和密码" : "设置用户名和密码")
                }
            }
        } header: {
            Text("账号")
        } footer: {
            if hasPassword == false && model.canAdmin == false {
                Text("这个账号还没有密码。为了安全，初始密码只能在开启了「允许管理」的设备上设置，或由管理员在管理网页的「账号」页设置。")
            } else {
                Text("用户名和密码用来在新设备上登录，pushkey 和历史消息都在账号里。")
            }
        }
    }

    private var devicesSection: some View {
        Section {
            if devices.isEmpty {
                Text(loading ? "正在加载…" : "暂无数据，下拉刷新").foregroundStyle(Theme.text2)
            }
            ForEach(devices) { d in
                NavigationLink {
                    DeviceDetailView(device: d, onRevoke: { Task { await revoke(d) } })
                } label: { DeviceRow(device: d) }
                .swipeActions(edge: .trailing) {
                    if !d.current { Button("移除") { revokeTarget = d }.tint(Theme.danger) }
                }
                .contextMenu {
                    Button { UIPasteboard.general.string = d.id } label: { Label("复制设备 ID", systemImage: "doc.on.doc") }
                    if !d.current {
                        Button(role: .destructive) { revokeTarget = d } label: { Label("移除…", systemImage: "minus.circle") }
                    }
                }
            }
        } header: {
            Text("我的设备")
        } footer: {
            Text("同一台设备重新配对或登录时沿用原来的记录，不会重复出现。左滑可以移除其他设备；没有「允许管理」的设备不能移除有管理权限的设备。")
        }
    }

    private var thisDeviceSection: some View {
        Section {
            HStack {
                TextField("设备名称", text: $nameDraft)
                if nameDraft != currentName {
                    Button(savingName ? "保存中…" : "保存") { Task { await saveName() } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(savingName || nameDraft.trimmingCharacters(in: .whitespaces).isEmpty || model.supports("me.rename") == false)
                }
            }
            LabeledContent("设备 ID") {
                Text(model.settings.deviceID).font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            LabeledContent("允许管理服务器") {
                switch model.canAdmin {
                case .some(true): Label("已开启", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                case .some(false): Text("未开启").foregroundStyle(Theme.text2)
                case .none: Text("未知").foregroundStyle(Theme.text3)
                }
            }
        } header: {
            Text("本机")
        } footer: {
            Text(model.supports("me.rename") == false ? "修改名称需要服务端 0.4.2 以上。"
                 : "名称可以随时修改、可以重名。「允许管理」是服务器级权限，在管理网页的「设备」页开启；管理自己账号的 pushkey、频道不需要它。")
        }
    }

    private var serverHost: String {
        guard let u = URL(string: model.settings.server), let h = u.host else { return model.settings.server }
        return u.port.map { "\(h):\($0)" } ?? h
    }

    private func load() async {
        guard model.supports("account") != false else { return }
        loading = true
        defer { loading = false }
        do {
            try await model.reloadAccount()
        } catch APIError.unsupported {
            unsupported = true
        } catch {
            notice = .failed("加载失败", error)
        }
    }

    private func revoke(_ d: DeviceInfo) async {
        do {
            try await model.requireAPI().revokeDevice(d.id)
            notice = .init(text: "已移除「\(d.name)」")
            await load()
        } catch {
            notice = .failed("移除失败", error)
        }
    }

    private func saveName() async {
        savingName = true
        defer { savingName = false }
        do {
            try await model.renameDevice(nameDraft)
            nameDraft = model.settings.deviceName
            notice = .init(text: "本机名称已保存，其他设备和管理后台里也会显示新名称")
            await load()
        } catch {
            notice = .failed("保存失败", error)
        }
    }
}

private struct DeviceRow: View {
    let device: DeviceInfo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.icon).font(.title3).foregroundStyle(Theme.text2).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name).font(.body.weight(.medium)).lineLimit(1)
                    if device.current { statusTag("本机", Theme.accent) }
                    if device.online { statusTag("在线", Theme.success) }
                }
                Text(device.client.isEmpty ? device.id : device.client).font(.caption).foregroundStyle(Theme.text3).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DeviceDetailView: View {
    @EnvironmentObject private var model: AppModel
    let initial: DeviceInfo
    let onRevoke: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var confirmRevoke = false

    /// onRevoke：确认后真正执行移除（详情页里自己弹确认框）
    init(device: DeviceInfo, onRevoke: @escaping () -> Void) {
        initial = device
        self.onRevoke = onRevoke
    }

    /// 以 AppModel 里的设备列表为准（别处改名、移除会立刻显示）
    private var device: DeviceInfo { model.accountDetail?.devices.first { $0.id == initial.id } ?? initial }

    var body: some View {
        Form {
            if device.revoked {
                Section { Label("这台设备已被移除", systemImage: "minus.circle.fill").foregroundStyle(Theme.danger) }
            }
            Section {
                LabeledContent("名称", value: device.name)
                LabeledContent("设备 ID") { Text(device.id).font(.footnote.monospaced()).textSelection(.enabled) }
                if !device.client.isEmpty { LabeledContent("客户端", value: device.client) }
                LabeledContent("状态", value: device.current ? "本机" : (device.online ? "在线" : "离线"))
                LabeledContent("首次配对", value: dateText(device.created_at))
                if let s = device.last_seen { LabeledContent("最近在线", value: dateText(s)) }
            }
            Section("配对记录（\(device.pair_count) 次）") {
                if device.pairings.isEmpty { Text("没有记录").foregroundStyle(Theme.text3) }
                ForEach(device.pairings, id: \.self) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(dateText(p.at)) · \(p.methodLabel)").font(.subheadline)
                        let extra = [p.ip, p.client].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !extra.isEmpty { Text(extra).font(.caption).foregroundStyle(Theme.text3) }
                    }
                }
            }
            if !device.current && !device.revoked {
                Section {
                    Button("移除这台设备…", role: .destructive) { confirmRevoke = true }
                } footer: {
                    Text("移除后，它需要重新配对或登录才能接收消息。")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("移除「\(device.name)」？", isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button("移除", role: .destructive) { onRevoke(); dismiss() }
        } message: {
            Text("移除后，它需要重新配对或登录才能接收消息。")
        }
    }
}

/// 设置 / 修改用户名和密码（POST /v1/account/credentials）
/// 设置 / 修改用户名和密码。首页 T67 提示条在账号还没有密码时也用它（设置成功后自动开启加密）
struct CredentialsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let hasPassword: Bool
    let initialName: String
    let onSaved: (AccountInfo) -> Void
    @State private var username = ""
    @State private var current = ""
    @State private var password = ""
    @State private var password2 = ""
    @State private var busy = false
    @State private var error: String?

    /// 账号已有密码时一律要当前密码：改密码、改用户名都用当前密码派生的凭证核对（管理权限也不能免，docs/e2ee-client.md §2.4）
    private var needCurrent: Bool { hasPassword }

    /// 服务端支持新登录协议时，密码强度只能由客户端检查（服务器拿不到密码，docs/e2ee-client.md §2.2）
    private var strengthProblem: String? {
        guard !password.isEmpty else { return nil }
        if model.e2eSupported { return Core.passwordProblem(password, username: ManageRules.normalizeUsername(username)) }
        return ManageRules.passwordProblem(password)
    }

    private var problem: String? {
        if let p = ManageRules.usernameProblem(username) { return p }
        if ManageRules.normalizeUsername(username).isEmpty { return "请填写用户名" }
        if !hasPassword && password.isEmpty { return model.e2eSupported ? "请设置密码（至少 10 位，不要用常见密码）" : "请设置密码（至少 8 位）" }
        if let p = strengthProblem { return p }
        if password != password2 { return "两次输入的密码不一样" }
        if needCurrent && current.isEmpty { return "请输入当前密码" }
        return nil
    }

    var body: some View {
        Form {
            Section {
                TextField("用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textContentType(.username)
            } header: { Text("用户名") } footer: { Text(ManageRules.usernameRule + "。登录时不区分大小写。") }
            if needCurrent {
                Section("当前密码") {
                    SecureField("当前密码", text: $current).textContentType(.password)
                }
            }
            Section {
                SecureField(hasPassword ? "新密码（留空只改用户名）" : (model.e2eSupported ? "密码，至少 10 位，不要用常见密码" : "密码，至少 8 位"),
                            text: $password).textContentType(.newPassword)
                SecureField("再输入一次", text: $password2).textContentType(.newPassword)
            } header: { Text(hasPassword ? "新密码" : "密码") } footer: {
                if let p = strengthProblem {
                    Text(p).foregroundStyle(Theme.danger)
                } else {
                    Text(hasPassword ? (model.e2eAccountEnabled ? "改密码后，已经登录的设备不受影响；已开启加密时，新密码会重新锁住本机的钥匙。" : "改密码后，已经登录的设备不受影响。")
                         : "设置后可以在新设备上用用户名和密码登录。")
                }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger).font(.subheadline) }
            } else if let p = problem, !username.isEmpty || !password.isEmpty {
                Section { Text(p).font(.footnote).foregroundStyle(Theme.text2) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(hasPassword ? "修改用户名和密码" : "设置用户名和密码")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if busy { ProgressView() } else {
                    Button("保存") { Task { await save() } }.disabled(problem != nil)
                }
            }
        }
        .onAppear { if username.isEmpty { username = initialName } }
    }

    private func save() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let a: AccountInfo
            if hasPassword {
                // 服务端支持新登录协议时：不发密码原文，已开启加密时用新密码重新锁住本机的钥匙
                a = try await model.changeCredentials(username: username, password: password, current: current)
            } else {
                // 初始密码只能以原文设置（服务端没有别的接口）：本机标记过「已升级」时拒绝（T1），否则设置后马上升级到新登录协议
                a = try await model.setInitialCredentials(username: username, password: password)
            }
            onSaved(a)
            dismiss()
        } catch {
            // 服务端的说明直接显示：当前密码不对、用户名已被使用、没有管理权限不能设置初始密码……
            self.error = shortError(error)
        }
    }
}

/// 生成配对码：6 位数字、3 分钟倒计时；每 2 秒查一次状态，被用掉后显示是哪台设备（服务端 0.5.6 起）
private struct PairCodeSection: View {
    @EnvironmentObject private var model: AppModel
    let onUsed: () -> Void
    @State private var code: String?
    @State private var expires: Date?
    @State private var usedBy: String?
    @State private var dead = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Section {
            if let code {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int((expires ?? ctx.date).timeIntervalSince(ctx.date).rounded()))
                    let gone = usedBy != nil || dead || left == 0
                    VStack(alignment: .leading, spacing: 6) {
                        Text(code.map { String($0) }.joined(separator: " "))
                            .font(.system(size: 34, weight: .semibold, design: .monospaced))
                            .foregroundStyle(gone ? Theme.text3 : Theme.accent)
                            .strikethrough(gone, color: Theme.text3)
                            .textSelection(.enabled)
                        Group {
                            if let by = usedBy {
                                Label("已被「\(by)」使用", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                            } else if gone {
                                Text("已失效，可以重新生成").foregroundStyle(Theme.text3)
                            } else {
                                Text(String(format: "%d:%02d 后失效", left / 60, left % 60)).monospacedDigit()
                                    .foregroundStyle(left <= 30 ? Theme.warning : Theme.text2)
                            }
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }
            }
            Button {
                Task { await make() }
            } label: {
                HStack {
                    Text(code == nil ? "生成配对码" : "重新生成")
                    if busy { Spacer(); ProgressView() }
                }
            }
            .disabled(busy)
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
        } header: {
            Text("添加设备到这个账号")
        } footer: {
            Text("新设备在登录页选「配对码」输入这 6 位数字，直接进入这个账号（3 分钟内有效，只能用一次，新设备没有服务器管理权限）。重新生成后，之前的配对码立即作废。")
        }
        .task(id: code) { await watch() }
        .task {
            // 截图用：自动生成一个配对码
            if code == nil, UserDefaults.standard.bool(forKey: "demoPairCode") { await make() }
        }
    }

    private func make() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let r = try await model.requireAPI().createPairCode()
            code = r.code
            expires = Date().addingTimeInterval(TimeInterval(r.expires_in ?? 180))
            usedBy = nil
            dead = false
            error = nil
        } catch {
            self.error = "生成失败：" + shortError(error)
        }
    }

    private func watch() async {
        // 功能清单可能还没加载完：只有明确知道服务端太旧时才不查；查询时服务端说没有这个接口也停下
        guard let c = code, let api = model.api(), model.supports("pair.status") != false else { return }
        while !Task.isCancelled, code == c, usedBy == nil, !dead {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, code == c else { return }
            // 过期 30 秒后还查不到结果（例如一直断网）：按失效处理，不再轮询
            if let e = expires, Date().timeIntervalSince(e) > 30 { dead = true; return }
            let s: PairCodeStatus
            do { s = try await api.pairCodeStatus(c) }
            catch APIError.unsupported { return }
            catch APIError.http(404, _) { dead = true; return }   // 已用或过期的码保留一小时后被清理
            catch { continue }
            switch s.state {
            case "used":
                usedBy = s.used_by ?? "新设备"
                onUsed()
            case "expired":
                dead = true
            default:
                if let left = s.expires_in { expires = Date().addingTimeInterval(TimeInterval(left)) }
            }
        }
    }
}

// MARK: - 频道

struct ChannelsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var notice: ManageNotice?
    @State private var renaming: String?
    @State private var aliasText = ""
    @State private var deleteTarget: String?
    @State private var confirmResetOrder = false

    private var counts: [String: Int] {
        var c: [String: Int] = [:]
        for m in model.messages { c[m.topic, default: 0] += 1 }
        return c
    }

    var body: some View {
        let all = model.allTopics
        let pinned = all.filter { model.channel($0).pinned && !model.channel($0).hidden }
        let others = all.filter { !model.channel($0).pinned && !model.channel($0).hidden }
        let hidden = all.filter { model.channel($0).hidden }
        let counts = self.counts
        List {
            if let old = model.tooOld("channels", since: "0.5.5") {
                TooOldSection(text: old)
            } else {
                NoticeSection(notice: notice)
                if all.isEmpty {
                    Section { Text("还没有频道。发送消息时带上 topic 参数，就会出现在这里。").foregroundStyle(Theme.text2) }
                }
                if !pinned.isEmpty {
                    Section("置顶") {
                        ForEach(pinned, id: \.self) { row($0, count: counts[$0] ?? 0) }
                            .onMove { from, to in move(pinned, from, to, others: others, pinnedGroup: true) }
                    }
                }
                if !others.isEmpty {
                    Section {
                        ForEach(others, id: \.self) { row($0, count: counts[$0] ?? 0) }
                            .onMove { from, to in move(others, from, to, others: pinned, pinnedGroup: false) }
                    } header: {
                        Text("频道")
                    } footer: {
                        Text("点右上角「编辑」拖动排序；左滑删除，右滑置顶，长按有更多操作。改名、静音、隐藏后所有设备同步。")
                    }
                }
                if !hidden.isEmpty {
                    Section {
                        ForEach(hidden, id: \.self) { row($0, count: counts[$0] ?? 0) }
                    } header: {
                        Text("已隐藏")
                    } footer: {
                        Text("隐藏的频道不进收件箱、不计未读、不提醒。")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("频道")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    if model.hasManualChannelOrder {
                        Menu {
                            Button("恢复按最近活跃排序…") { confirmResetOrder = true }
                        } label: { Image(systemName: "arrow.up.arrow.down") }
                    }
                    EditButton()
                }
            }
        }
        .refreshable { await model.refreshAccount() }
        .alert("频道显示名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("显示名", text: $aliasText)
            Button("保存") {
                if let t = renaming {
                    let a = ManageRules.clip(aliasText, ManageRules.aliasMax)
                    run("改名") { try await model.updateChannel(t, alias: a) }
                }
            }
            if let t = renaming, !model.channel(t).alias.isEmpty {
                Button("恢复原名") { run("恢复原名") { try await model.updateChannel(t, alias: "") } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只改显示的名字（最多 \(ManageRules.aliasMax) 个字），所有设备同步。发送消息时仍用原来的 topic「\(renaming ?? "")」。")
        }
        .confirmationDialog("恢复按最近活跃排序？", isPresented: $confirmResetOrder, titleVisibility: .visible) {
            Button("恢复排序") { run("恢复排序") { try await model.setChannelOrder([]) } }
        } message: {
            Text("会清掉手动拖出来的频道顺序，所有设备同步（置顶不受影响）。")
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("删除频道和全部消息", role: .destructive) {
                if let t = deleteTarget {
                    let name = model.channelName(t)
                    Task {
                        do {
                            let n = try await model.deleteChannel(t)
                            notice = .init(text: "已删除频道「\(name)」（服务器上 \(n) 条消息）")
                        } catch { notice = .failed("删除频道失败", error) }
                    }
                }
            }
        } message: {
            Text("服务器上这个频道的全部消息和附件都会删除，所有设备同步，不能恢复。之后再有这个 topic 的消息发来，频道会重新出现。")
        }
        .task {
            // 截图用：打开改名弹窗
            if let t = UserDefaults.standard.string(forKey: "demoRenameChannel"), renaming == nil {
                try? await Task.sleep(nanoseconds: 800_000_000)
                aliasText = model.channelName(t)
                renaming = t
            }
        }
    }

    private var deleteTitle: String {
        guard let t = deleteTarget else { return "" }
        return "删除频道「\(model.channelName(t))」（本机 \(counts[t] ?? 0) 条消息）？"
    }

    @ViewBuilder
    private func row(_ t: String, count: Int) -> some View {
        let c = model.channel(t)
        NavigationLink {
            ChannelDetailView(topic: t)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: c.hidden ? "eye.slash" : (c.pinned ? "pin.fill" : "number"))
                    .foregroundStyle(c.pinned && !c.hidden ? Theme.accent : Theme.text3).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(model.channelName(t)).lineLimit(1)
                        if c.muted { Image(systemName: "bell.slash").font(.caption).foregroundStyle(Theme.text3) }
                    }
                    if !c.alias.isEmpty { Text("原名 \(t)").font(.caption).foregroundStyle(Theme.text3).lineLimit(1) }
                }
                Spacer()
                if count > 0 { Text("\(count)").font(.footnote.monospacedDigit()).foregroundStyle(Theme.text3) }
            }
        }
        .swipeActions(edge: .trailing) {
            Button("删除") { deleteTarget = t }.tint(Theme.danger)
        }
        .swipeActions(edge: .leading) {
            if !c.hidden {
                Button(c.pinned ? "取消置顶" : "置顶") { run(c.pinned ? "取消置顶" : "置顶") { try await model.updateChannel(t, pinned: !c.pinned) } }
                    .tint(Theme.accent)
            }
        }
        .contextMenu {
            if !c.hidden {
                Button { run(c.pinned ? "取消置顶" : "置顶") { try await model.updateChannel(t, pinned: !c.pinned) } } label: {
                    Label(c.pinned ? "取消置顶" : "置顶", systemImage: c.pinned ? "pin.slash" : "pin")
                }
            }
            Button { aliasText = model.channelName(t); renaming = t } label: { Label("重命名…", systemImage: "pencil") }
            Button { run(c.muted ? "取消静音" : "静音") { try await model.updateChannel(t, muted: !c.muted) } } label: {
                Label(c.muted ? "取消静音" : "静音（不提醒，紧急消息除外）", systemImage: c.muted ? "bell" : "bell.slash")
            }
            Button { run(c.hidden ? "取消隐藏" : "隐藏") { try await model.updateChannel(t, hidden: !c.hidden) } } label: {
                Label(c.hidden ? "取消隐藏" : "隐藏频道", systemImage: c.hidden ? "eye" : "eye.slash")
            }
            if model.hasManualChannelOrder && !c.hidden {
                Button { confirmResetOrder = true } label: {
                    Label("恢复按最近活跃排序…", systemImage: "arrow.up.arrow.down")
                }
            }
            Divider()
            Button(role: .destructive) { deleteTarget = t } label: { Label("删除频道…", systemImage: "trash") }
        }
    }

    /// 只在同一组里拖（置顶的和置顶的、其他的和其他的）；新顺序 = 置顶组 + 其他组
    private func move(_ group: [String], _ from: IndexSet, _ to: Int, others: [String], pinnedGroup: Bool) {
        var g = group
        g.move(fromOffsets: from, toOffset: to)
        guard g != group else { return }
        let order = pinnedGroup ? g + others : others + g
        run("保存顺序") { try await model.setChannelOrder(order) }
    }

    private func run(_ what: String, _ op: @escaping () async throws -> Void) {
        Task {
            do { try await op(); notice = nil } catch { notice = .failed("\(what)失败", error) }
        }
    }
}

/// 一个频道的设置：显示名、置顶、静音、隐藏、删除
private struct ChannelDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let topic: String
    @State private var alias = ""
    @State private var notice: ManageNotice?
    @State private var confirmDelete = false

    var body: some View {
        let c = model.channel(topic)
        let count = model.messages.filter { $0.topic == topic }.count
        Form {
            NoticeSection(notice: notice)
            Section {
                HStack {
                    TextField("显示名（留空用原名）", text: $alias)
                    if alias != c.alias {
                        Button("保存") {
                            let a = ManageRules.clip(alias, ManageRules.aliasMax)
                            run("改名") { try await model.updateChannel(topic, alias: a) }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
                if !c.alias.isEmpty {
                    Button("恢复原名") { alias = ""; run("恢复原名") { try await model.updateChannel(topic, alias: "") } }
                }
            } header: { Text("显示名") } footer: {
                Text("原名（发送时的 topic）：\(topic)。显示名最多 \(ManageRules.aliasMax) 个字，所有设备同步。")
            }
            Section {
                if !c.hidden {
                    Toggle("置顶", isOn: Binding(get: { c.pinned }, set: { v in run("置顶") { try await model.updateChannel(topic, pinned: v) } }))
                }
                Toggle("静音", isOn: Binding(get: { c.muted }, set: { v in run("静音") { try await model.updateChannel(topic, muted: v) } }))
                Toggle("隐藏", isOn: Binding(get: { c.hidden }, set: { v in run("隐藏") { try await model.updateChannel(topic, hidden: v) } }))
            } footer: {
                Text("静音：照常显示，不提醒（紧急消息除外）。隐藏：不进收件箱、不计未读、不提醒。")
            }
            Section {
                Button("删除频道…", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("本机有 \(count) 条这个频道的消息。删除会清掉服务器上这个频道的全部消息和附件，所有设备同步。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(model.channelName(topic))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { alias = c.alias }
        // 别处改了显示名：输入框里没改过的话跟着更新
        .onChange(of: model.channel(topic).alias) { old, new in if alias == old { alias = new } }
        .confirmationDialog("删除频道「\(model.channelName(topic))」（本机 \(count) 条消息）？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除频道和全部消息", role: .destructive) {
                Task {
                    do { try await model.deleteChannel(topic); dismiss() } catch { notice = .failed("删除频道失败", error) }
                }
            }
        } message: {
            Text("服务器上这个频道的全部消息和附件都会删除，所有设备同步，不能恢复。")
        }
    }

    private func run(_ what: String, _ op: @escaping () async throws -> Void) {
        Task {
            do { try await op(); notice = .init(text: "已保存") } catch { notice = .failed("\(what)失败", error) }
        }
    }
}
