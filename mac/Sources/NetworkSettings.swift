import SwiftUI

/// 设置 → 网络：代理（HTTP / SOCKS5），可分别用于应用更新和服务器连接
struct NetworkSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = ProxyConfig()
    @State private var portText = ""
    @State private var loaded = false
    @State private var testing = false
    @State private var results: [(String, Bool, String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(title: "代理", footer: "本机开了代理软件时（例如 127.0.0.1:7890），可以让更新下载或连接境外服务器走代理。关闭或未勾选的部分按系统网络设置连接（系统代理照常生效）。") {
                SettingsRow(label: "使用代理") {
                    Toggle("", isOn: $draft.enabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                SettingsRow(label: "类型") {
                    Picker("", selection: $draft.kind) {
                        ForEach(ProxyConfig.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                .disabled(!draft.enabled)
                SettingsRow(label: "地址") {
                    WarmField(placeholder: "127.0.0.1", text: $draft.host).frame(width: 170)
                    Text(":").foregroundStyle(Theme.text3)
                    WarmField(placeholder: "7890", text: $portText).frame(width: 74)
                        .onChange(of: portText) { _, v in
                            let d = String(v.filter(\.isNumber).prefix(5))
                            if d != v { portText = d }
                            draft.port = Int(d) ?? 0
                        }
                }
                .disabled(!draft.enabled)
                SettingsRow(label: "应用于", divider: false) {
                    Toggle("应用更新", isOn: $draft.forUpdates).toggleStyle(.checkbox)
                    Toggle("服务器连接（消息与附件）", isOn: $draft.forServer).toggleStyle(.checkbox)
                }
                .disabled(!draft.enabled)
            }
            HStack(spacing: 8) {
                if !draft.valid && draft.enabled {
                    Text("请填写有效的地址和端口").font(.system(size: 11.5)).foregroundStyle(Theme.danger)
                }
                Spacer()
                Button(testing ? "测试中…" : "测试连接") { Task { await runTest() } }
                    .buttonStyle(SoftButtonStyle()).disabled(testing || (draft.enabled && !draft.valid))
                Button("应用") { model.setProxy(draft) }
                    .buttonStyle(SoftButtonStyle()).disabled(draft == model.proxy || (draft.enabled && !draft.valid))
            }
            .padding(.bottom, 12)
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(results, id: \.0) { r in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: r.1 ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(r.1 ? Theme.success : Theme.danger)
                            Text("\(r.0)：\(r.2)").font(.system(size: 12)).foregroundStyle(Theme.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .card(radius: 10)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = model.proxy
            portText = String(model.proxy.port)
        }
    }

    /// 用「当前编辑中」的设置测试：服务器 /healthz 和更新源
    func runTest() async {
        testing = true
        results = []
        var out: [(String, Bool, String)] = []
        if let u = URL(string: model.server), !model.server.isEmpty {
            out.append(await probe("服务器（\(draft.applies(to: .server) ? "经代理" : "系统网络")）",
                                   APIClient(server: u, token: nil).url("/healthz"), scope: .server))
        }
        let updURL: URL? = {
            switch AppInfo.updateSource {
            case .github: return URL(string: "\(GitHubUpdates.apiBase)/zen")
            case .hub: return URL(string: model.server).map { APIClient(server: $0, token: nil).url("/healthz") }
            }
        }()
        if let updURL {
            out.append(await probe("更新源 \(AppInfo.updateSource.label)（\(draft.applies(to: .updates) ? "经代理" : "系统网络")）", updURL, scope: .updates))
        }
        results = out
        testing = false
    }

    func probe(_ name: String, _ url: URL, scope: NetScope) async -> (String, Bool, String) {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.connectionProxyDictionary = draft.dictionary(for: scope)
        let s = URLSession(configuration: c)
        defer { s.invalidateAndCancel() }
        let t0 = Date()
        do {
            let (_, resp) = try await s.data(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            return (name, code == 200, code == 200 ? "连接正常，\(ms) ms" : "HTTP \(code)")
        } catch {
            return (name, false, AppModel.shortError(error))
        }
    }
}
