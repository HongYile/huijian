import SwiftUI

/// 设置 → 服务器：版本与兼容性、服务端存储与备份。
struct ServerSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var storage: APIClient.StorageInfo?
    @State private var loading = false
    @State private var message: String?
    @State private var storageUnsupported = false
    @State private var poll: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(title: "版本", footer: versionFooter) {
                SettingsRow(label: "服务器") { value(model.server.isEmpty ? "未设置" : model.server) }
                SettingsRow(label: "服务端版本") { value(model.serverVersionText) }
                SettingsRow(label: "本客户端版本") { value("\(AppInfo.version)（build \(AppInfo.build)）") }
                SettingsRow(label: "", divider: false) {
                    Button("重新检测") {
                        model.refreshServerInfo()
                        Task { await loadStorage(fresh: true) }
                    }
                    .buttonStyle(SoftButtonStyle()).disabled(model.token == nil)
                }
            }
            let needServer = model.featuresNeedingServerUpdate
            if !needServer.isEmpty {
                SettingsCard(title: "更新服务端后可用", footer: "在服务器的部署目录执行 git pull && docker compose up -d --build 升级服务端，数据会保留。") {
                    ForEach(Array(needServer.enumerated()), id: \.element.id) { i, f in
                        SettingsRow(label: f.title, divider: i < needServer.count - 1) { chip("需要更新服务端", Theme.warning) }
                    }
                }
            }
            let needClient = model.featuresNeedingClientUpdate
            if !needClient.isEmpty {
                SettingsCard(title: "更新客户端后可用", footer: "服务端已经支持这些功能，当前客户端还用不了。在「通用」里检查更新。") {
                    ForEach(Array(needClient.enumerated()), id: \.element.id) { i, f in
                        SettingsRow(label: f.title, divider: i < needClient.count - 1) { chip("服务端 \(f.since) 起支持", Theme.accent) }
                    }
                }
            }
            storageCard
        }
        .onAppear { Task { await loadStorage(fresh: false) } }
        .onDisappear { poll?.cancel() }
    }

    var versionFooter: String {
        if model.token == nil { return "配对后显示服务端版本。" }
        if model.serverLegacy { return "服务端版本较旧（没有功能清单），部分新功能不可用，下面列出了需要更新服务端的功能。" }
        if model.serverInfo != nil, model.featuresNeedingServerUpdate.isEmpty, model.featuresNeedingClientUpdate.isEmpty {
            return "客户端和服务端的功能一致。客户端和服务端可以分别升级，用不了的功能会注明原因。"
        }
        return "客户端和服务端可以分别升级，用不了的功能会注明原因。"
    }

    // MARK: 存储与备份

    @ViewBuilder var storageCard: some View {
        if storageUnsupported || model.support("storage") == .needsServerUpdate {
            ServerTooOld(feature: "在客户端查看服务端存储与备份", since: "0.5.0", alternative: nil)
        } else if model.canAdmin == false {
            SettingsCard(title: "服务端存储与备份", footer: "需要在管理网页的「设备」页为本机打开「允许管理」。") {
                SettingsRow(label: "没有权限查看", divider: false) { EmptyView() }
            }
        } else if let s = storage {
            SettingsCard(title: "服务端存储与备份", footer: message ?? "目录在服务端的配置文件 / .env 里修改：HUIJIAN_FILES（附件，可以放 NAS）、HUIJIAN_BACKUP_DIR（备份）。") {
                SettingsRow(label: "数据库") { value("\(humanSize(s.db_size)) · \(s.data_dir)") }
                SettingsRow(label: "附件目录") {
                    if s.files_ok {
                        value("\(s.files_count) 个 · \(humanSize(s.files_size))\(s.files_free >= 0 ? " · 剩余 \(humanSize(s.files_free))" : "") · \(s.files_dir)")
                    } else {
                        chip("不可用", Theme.danger).help(s.files_error ?? "")
                        value(s.files_dir)
                    }
                }
                if s.pending > 0 {
                    SettingsRow(label: "暂存在本地") { value("\(s.pending) 个附件，附件目录恢复后自动搬回") }
                }
                SettingsRow(label: "备份目录") {
                    if !s.backup_enabled {
                        value("已关闭")
                    } else if s.backup_ok {
                        value("\(s.backup_free >= 0 ? "剩余 \(humanSize(s.backup_free)) · " : "")\(s.backup_dir ?? "")")
                    } else {
                        chip("不可用", Theme.danger).help(s.backup_error ?? "")
                        value(s.backup_dir ?? "")
                    }
                }
                if s.backup_enabled {
                    SettingsRow(label: "备份计划") {
                        value("每天 \(s.backup_at ?? "")，保留 \(s.backup_keep ?? 0) 份\(s.backup_files == true ? "，镜像附件" : "")")
                    }
                }
                SettingsRow(label: "上次备份") { lastBackup(s.last) }
                SettingsRow(label: "", divider: false) {
                    if loading { ProgressView().controlSize(.small) }
                    Button("刷新") { Task { await loadStorage(fresh: true) } }.buttonStyle(SoftButtonStyle()).disabled(loading)
                    Button(s.running ? "备份中…" : "立即备份") { Task { await startBackup() } }
                        .buttonStyle(SoftButtonStyle()).disabled(s.running || !s.backup_enabled)
                }
            }
        } else {
            SettingsCard(title: "服务端存储与备份", footer: message) {
                SettingsRow(label: loading ? "正在加载…" : (model.token == nil ? "尚未配对" : "暂无数据"), divider: false) {
                    if loading { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    @ViewBuilder func lastBackup(_ b: APIClient.BackupStatus?) -> some View {
        if let b {
            let when = TimeFmt.compact(Date(timeIntervalSince1970: TimeInterval(b.at)))
            if b.ok {
                chip("成功", Theme.success)
                value("\(when) · \(b.reason ?? "")\(b.files == true ? " · 新增附件 \(b.copied ?? 0) 个" : "")")
                    .help(b.warning ?? (b.db ?? ""))
            } else {
                chip("失败", Theme.danger)
                value("\(when) · \(b.error ?? "")").help(b.error ?? "")
            }
        } else {
            value("还没有备份过")
        }
    }

    func loadStorage(fresh: Bool) async {
        guard let client = model.client, model.support("storage") != .needsServerUpdate, model.canAdmin != false else { return }
        loading = true
        defer { loading = false }
        do {
            storage = try await client.storage(fresh: fresh)
            storageUnsupported = false
            if storage?.running == true { startPolling() }
        } catch APIError.unsupported {
            model.noteUnsupported("storage")
            storageUnsupported = true
        } catch APIError.http(403, let m) {
            message = m
        } catch {
            message = "加载失败：\(Updater.describe(error))"
        }
    }

    func startBackup() async {
        guard let client = model.client else { return }
        do {
            storage = try await client.startBackup()
            message = "已开始备份…"
            startPolling()
        } catch {
            message = "无法开始备份：\(Updater.describe(error))"
        }
    }

    /// 备份进行中：每 2 秒刷新一次，结束后显示结果
    func startPolling() {
        poll?.cancel()
        poll = Task {
            for _ in 0..<300 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                guard let client = model.client, let s = try? await client.storage() else { continue }
                storage = s
                if !s.running {
                    if let l = s.last { message = l.ok ? "备份完成" : "备份失败：\(l.error ?? "")" }
                    return
                }
            }
        }
    }

    func value(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
    }

    func chip(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 10.5, weight: .medium)).foregroundStyle(c)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.12)))
    }
}

/// 服务端太旧、功能不可用时的统一提示
struct ServerTooOld: View {
    let feature: String
    let since: String
    let alternative: String?

    var body: some View {
        SettingsCard(title: "更新服务端后可用", footer: "在服务器的部署目录执行 git pull && docker compose up -d --build 升级服务端，数据会保留。" + (alternative.map { "\n" + $0 } ?? "")) {
            SettingsRow(label: feature, divider: false) {
                Text("需要服务端 \(since) 以上").font(.system(size: 12)).foregroundStyle(Theme.warning)
            }
        }
    }
}
