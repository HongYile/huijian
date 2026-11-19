import SwiftUI

/// 设置 → Pushkey：在 Mac 上查看、新建、改名、自定义 key 内容、吊销。
/// 修改先保存在本地草稿里，点「同步到服务器」后统一提交，不必再登录管理后台。
struct KeysSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var drafts: [KeyDraft] = []
    @State private var loading = false
    @State private var syncing = false
    @State private var message: String?
    @State private var confirmReplace = false
    @State private var revokeTarget: KeyDraft?
    @State private var deleteTarget: KeyDraft?
    @State private var loaded = false
    @State private var unsupported = false
    /// 本机对每把 key 的接收方式（pushkey id → notify / silent / off）；服务端不支持时为 nil
    @State private var modes: [Int64: String]?

    static let keyPattern = #/^[A-Za-z0-9_-]{16,64}$/#

    var dirtyCount: Int { drafts.filter(\.dirty).count }
    var invalid: Bool { drafts.contains { $0.dirty && $0.validationError != nil } }

    var body: some View {
        if unsupported || model.support("keys") == .needsServerUpdate {
            ServerTooOld(feature: "在客户端管理 pushkey", since: "0.4.2",
                         alternative: "现在可以先在服务器管理后台的「Pushkey」页管理。")
        } else {
            editor
        }
    }

    var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(title: model.accountName.isEmpty ? "Pushkey" : "账号「\(model.accountName)」的 Pushkey",
                         footer: "pushkey 属于账号：这个账号的所有设备看到的是同一组，换设备登录后照样在。发送方用 pushkey 把消息发给你。建议每台机器、每个项目各用一把，泄露时只吊销那一把。自定义 key 需 16–64 位字母、数字、下划线或短横线；新建时留空则自动生成。"
                         + (modes == nil ? "" : "\n「本机」决定这把 key 发来的消息在这台 Mac 上提醒、静默（只进列表）还是不接收；每台设备分别设置，例如告警只让手机响。")) {
                if model.token == nil {
                    SettingsRow(label: "尚未配对，配对后可以在这里管理 pushkey", divider: false) { EmptyView() }
                } else if drafts.isEmpty {
                    SettingsRow(label: loading ? "正在加载…" : "还没有 pushkey，点下方「新建」", divider: false) {
                        if loading { ProgressView().controlSize(.small) }
                    }
                } else {
                    ForEach($drafts) { $d in
                        KeyRow(draft: $d, last: d.id == drafts.last?.id,
                               mode: d.original.flatMap { o in modes.map { $0[o.id] ?? "notify" } },
                               sendKey: d.original.map { o in o.revoked ? .hidden : model.e2eSendKey(o.key) } ?? .hidden,
                               onMode: { m in if let o = d.original { Task { await setMode(o.id, m) } } },
                               onRevoke: { revokeTarget = d },
                               onDelete: model.support("keys.delete") == .yes ? { deleteTarget = d } : nil,
                               onDiscard: { drafts.removeAll { $0.id == d.id } })
                    }
                }
            }
            HStack(spacing: 8) {
                // 还没有有效的 key 时，新建的第一把默认叫 default（可以改）
                Button { drafts.append(KeyDraft.new(name: drafts.contains { !$0.revoked } ? "新的 pushkey" : "default")) } label: { Label("新建", systemImage: "plus") }
                    .buttonStyle(SoftButtonStyle()).disabled(model.token == nil)
                Button("从服务器刷新") { Task { await reload() } }
                    .buttonStyle(SoftButtonStyle()).disabled(model.token == nil || loading || syncing)
                Spacer()
                if let message {
                    Text(message).font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineLimit(2)
                }
                Button(syncing ? "同步中…" : (dirtyCount > 0 ? "同步到服务器（\(dirtyCount)）" : "同步到服务器")) {
                    if drafts.contains(where: \.replacesKey) { confirmReplace = true } else { Task { await sync() } }
                }
                .buttonStyle(SoftButtonStyle())
                .disabled(dirtyCount == 0 || invalid || syncing)
            }
            .padding(.bottom, 14)
            if let k = drafts.compactMap(\.original).first(where: { !$0.revoked }), !model.server.isEmpty {
                SettingsCard(title: "试一下：用「\(k.name)」发一条") {
                    CopyableCode(text: "curl \"\(model.server)/message/push?pushkey=\(k.key)&text=hello\"")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            Task { await reload() }
            Task { await model.refreshE2E() }     // 加密发送密钥要用账号的公钥
        }
        // 其他设备或管理后台改了 pushkey（服务端 0.6.1 起的设置实时同步）：重新拉取，本地没同步的草稿保留
        .onChange(of: model.keysRevision) { _, _ in
            guard loaded, !syncing else { return }
            Task { await reload(keepMessage: true) }
        }
        .confirmationDialog("更换 key 后，旧 key 立即失效，正在使用它的脚本需要改成新 key。确定同步吗？", isPresented: $confirmReplace) {
            Button("同步") { Task { await sync() } }
        }
        .confirmationDialog("彻底删除「\(deleteTarget?.name ?? "")」？删除后列表里不再显示，历史消息会保留。", isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("删除", role: .destructive) {
                if let t = deleteTarget { Task { await delete(t) } }
            }
        }
        .confirmationDialog("吊销「\(revokeTarget?.name ?? "")」后，使用它的发送方将无法再发送。", isPresented: Binding(
            get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } })) {
            Button("吊销", role: .destructive) {
                if let t = revokeTarget { Task { await revoke(t) } }
            }
        }
    }

    /// keepMessage：变更流触发的后台刷新，不清掉刚才操作的结果提示
    func reload(keepMessage: Bool = false) async {
        guard let client = model.client else { return }
        loading = true
        defer { loading = false }
        do {
            drafts = merged(server: try await client.listKeys())
            if !keepMessage { message = nil }
            if model.support("subscriptions") != .needsServerUpdate, let s = try? await client.subscriptions() {
                modes = Dictionary(uniqueKeysWithValues: s.items.map { ($0.pushkey_id, $0.mode) })
            }
        } catch APIError.unsupported {
            model.noteUnsupported("keys")
            unsupported = true
        } catch APIError.http(403, let m) {
            message = m
        } catch {
            message = "加载失败：\(Updater.describe(error))"
        }
    }

    /// 用服务器列表重建草稿，同时保留本地还没同步的修改和新建
    func merged(server keys: [APIClient.PushKey]) -> [KeyDraft] {
        var out = keys.map(KeyDraft.init(server:))
        for d in drafts where d.dirty {
            if let o = d.original {
                if let i = out.firstIndex(where: { $0.original?.id == o.id }), out[i].original?.revoked == false {
                    var keep = d
                    keep.original = out[i].original
                    out[i] = keep
                }
            } else {
                out.append(d)
            }
        }
        return out
    }

    /// 依次提交新建和修改：每成功一项立刻用服务端返回的结果替换本地草稿（即使之后刷新失败，也不会重复提交）；
    /// 失败的保留草稿并标出原因
    func sync() async {
        guard let client = model.client else { return }
        syncing = true
        defer { syncing = false }
        var ok = 0, failed = 0
        for d in drafts where d.dirty {
            do {
                let saved: APIClient.PushKey
                if let o = d.original {
                    saved = try await client.updateKey(id: o.id, name: d.name == o.name ? "" : d.name, key: d.key == o.key ? "" : d.key)
                } else {
                    saved = try await client.createKey(name: d.name, key: d.key)
                }
                if let i = drafts.firstIndex(where: { $0.id == d.id }) { drafts[i] = KeyDraft(server: saved) }
                ok += 1
            } catch {
                if let i = drafts.firstIndex(where: { $0.id == d.id }) { drafts[i].error = Updater.describe(error) }
                failed += 1
            }
        }
        var msg = failed == 0 ? "已同步 \(ok) 项" : "已同步 \(ok) 项，\(failed) 项失败"
        do {
            drafts = merged(server: try await client.listKeys())
        } catch {
            msg += "（刷新列表失败：\(Updater.describe(error))）"
        }
        message = msg
    }

    func setMode(_ id: Int64, _ m: String) async {
        guard let client = model.client else { return }
        let old = modes?[id]
        modes?[id] = m
        do {
            try await client.setSubscription(keyID: id, mode: m)
        } catch {
            modes?[id] = old
            message = "保存失败：\(Updater.describe(error))"
        }
    }

    func revoke(_ d: KeyDraft) async {
        guard let client = model.client, let o = d.original else { return }
        do {
            let r = try await client.revokeKey(id: o.id)
            if let i = drafts.firstIndex(where: { $0.id == d.id }) { drafts[i] = KeyDraft(server: r) }   // 只更新这一行，其他行的编辑保留
            message = "已吊销「\(o.name)」"
        } catch {
            message = "吊销失败：\(Updater.describe(error))"
        }
    }

    func delete(_ d: KeyDraft) async {
        guard let client = model.client, let o = d.original else { return }
        do {
            try await client.deleteKey(id: o.id)
            drafts.removeAll { $0.id == d.id }
            message = "已删除「\(o.name)」"
        } catch APIError.http(404, _) {
            drafts.removeAll { $0.id == d.id }   // 已在别的设备上删除
            message = "「\(o.name)」已不存在（可能在别的设备上删除了）"
        } catch APIError.unsupported {
            model.noteUnsupported("keys.delete")
            message = "删除需要服务端 0.5.2 以上，更新服务端后可用"
        } catch {
            message = "删除失败：\(Updater.describe(error))"
        }
    }
}

struct KeyDraft: Identifiable, Equatable {
    let id: String
    var original: APIClient.PushKey?
    var name: String
    var key: String
    var error: String?

    init(server k: APIClient.PushKey) {
        id = "s\(k.id)"
        original = k
        name = k.name
        key = k.key
    }

    private init(newID: String, name: String) {
        id = newID
        self.name = name
        key = ""
    }

    static func new(name: String = "新的 pushkey") -> KeyDraft { KeyDraft(newID: "n" + UUID().uuidString, name: name) }

    var revoked: Bool { original?.revoked ?? false }
    var dirty: Bool {
        guard let o = original else { return true }
        return !o.revoked && (name != o.name || key != o.key)
    }
    /// 已有的 key 被改了内容（旧 key 会失效）
    var replacesKey: Bool { original.map { !$0.revoked && $0.key != key } ?? false }

    var validationError: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "名称不能为空" }
        if original == nil && key.isEmpty { return nil }              // 新建留空 = 自动生成
        if key.wholeMatch(of: KeysSettings.keyPattern) == nil { return "key 需 16–64 位字母、数字、_ 或 -" }
        return nil
    }
}

struct KeyRow: View {
    @Binding var draft: KeyDraft
    let last: Bool
    var mode: String? = nil
    /// 加密发送密钥 <pushkey>.e2e.<钉住的公钥>（账号开启了端到端加密才显示这一行）
    var sendKey: E2E.SendKey = .hidden
    var onMode: (String) -> Void = { _ in }
    let onRevoke: () -> Void
    var onDelete: (() -> Void)? = nil
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if draft.revoked {
                    Text(draft.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text3)
                } else {
                    WarmField(placeholder: "名称", text: $draft.name).frame(width: 170)
                }
                status
                Spacer(minLength: 4)
                if let used = draft.original?.last_used {
                    Text("最近使用 \(TimeFmt.compact(used))").font(.system(size: 11)).foregroundStyle(Theme.text3)
                } else if draft.original != nil && !draft.revoked {
                    Text("从未使用").font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                if draft.revoked, let onDelete {
                    Button("删除", action: onDelete).buttonStyle(SoftButtonStyle(destructive: true))
                        .help("彻底删除这把已吊销的 key，历史消息保留")
                }
                if !draft.revoked {
                    if draft.original != nil {
                        Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(draft.key, forType: .string) }
                            .buttonStyle(SoftButtonStyle())
                        Button("吊销", action: onRevoke).buttonStyle(SoftButtonStyle(destructive: true))
                    } else {
                        Button("放弃", action: onDiscard).buttonStyle(SoftButtonStyle())
                    }
                }
            }
            if draft.revoked {
                Text(draft.key).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text3).strikethrough()
            } else {
                HStack(spacing: 8) {
                    WarmField(placeholder: draft.original == nil ? "留空自动生成，或填 16–64 位自定义 key" : "key", text: $draft.key, mono: true)
                    if let mode {
                        Picker("本机", selection: Binding(get: { mode }, set: { onMode($0) })) {
                            Text("提醒").tag("notify")
                            Text("静默").tag("silent")
                            Text("不接收").tag("off")
                        }
                        .pickerStyle(.menu).fixedSize()
                        .help("这把 key 发来的消息在本机：提醒 = 按通知设置弹出；静默 = 只进列表；不接收 = 本机看不到")
                    }
                }
            }
            if sendKey != .hidden, !draft.revoked {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Label("加密发送密钥", systemImage: "lock.fill")
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text2).fixedSize()
                        switch sendKey {
                        case .key(let k):
                            Text(k).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text2)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer(minLength: 4)
                            Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(k, forType: .string) }
                                .buttonStyle(SoftButtonStyle())
                        case .mismatch:
                            Text(E2E.T.t43).font(.system(size: 11.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                        default:
                            Text(E2E.T.t73).font(.system(size: 11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                        }
                    }
                    if case .key = sendKey {
                        Text(E2E.T.t70).font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }
            if let e = draft.error ?? (draft.dirty ? draft.validationError : nil) {
                Text(e).font(.system(size: 11)).foregroundStyle(Theme.danger)
            } else if draft.replacesKey {
                Text("同步后旧 key 立即失效").font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
        }
        .padding(.vertical, 10)
        .onChange(of: draft.name) { _, _ in draft.error = nil }
        .onChange(of: draft.key) { _, _ in draft.error = nil }
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1) }
        }
    }

    @ViewBuilder var status: some View {
        if draft.revoked {
            chip("已吊销", Theme.danger)
        } else if draft.original == nil {
            chip("未同步", Theme.accent)
        } else if draft.dirty {
            chip("已修改", Theme.warning)
        } else {
            chip("有效", Theme.success)
        }
    }

    func chip(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 10.5, weight: .medium)).foregroundStyle(c)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.12)))
    }
}
