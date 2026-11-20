import SwiftUI

/// 设置 → 服务器：版本与兼容性。
/// 服务端 0.9.0 起客户端不能进入管理后台、不能查看存储与备份（只能在服务器上管理），这里不再有这些内容
struct ServerSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(title: "版本", footer: versionFooter) {
                SettingsRow(label: "服务器") { value(model.server.isEmpty ? "未设置" : model.server) }
                SettingsRow(label: "服务端版本") { value(model.serverVersionText) }
                SettingsRow(label: "本客户端版本") { value("\(AppInfo.version)（build \(AppInfo.build)）") }
                SettingsRow(label: "", divider: false) {
                    Button("重新检测") { model.refreshServerInfo() }
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
        }
    }

    var versionFooter: String {
        if model.token == nil { return "配对后显示服务端版本。" }
        if model.serverLegacy { return "服务端版本较旧（没有功能清单），部分新功能不可用，下面列出了需要更新服务端的功能。" }
        if model.serverInfo != nil, model.featuresNeedingServerUpdate.isEmpty, model.featuresNeedingClientUpdate.isEmpty {
            return "客户端和服务端的功能一致。客户端和服务端可以分别升级，用不了的功能会注明原因。"
        }
        return "客户端和服务端可以分别升级，用不了的功能会注明原因。"
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
