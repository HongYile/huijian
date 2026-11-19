import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var server = ""
    @State private var mode: Mode = .password
    /// 服务端开放了注册（GET /v1/info 的 register_open）；nil = 还不知道
    @State private var registerOpen: Bool?
    @State private var password2 = ""
    @State private var pendingRegister = false
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var name = UIDevice.current.name
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case server, username, password, password2, code, name }
    private enum Mode: Hashable { case password, pair, register }
    private var usePair: Bool { mode == .pair }

    /// 注册时的密码强度：服务器拿不到密码，只能在本机检查（docs/e2ee-client.md §2.2）
    private var registerProblem: String? {
        mode == .register && !password.isEmpty ? Core.passwordProblem(password, username: ManageRules.normalizeUsername(username)) : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        AppMark(size: 56)
                        Text("回笺").font(.largeTitle.bold()).foregroundStyle(Theme.text)
                        Text("登录你自己的回笺服务器，接收分级推送。").font(.subheadline).foregroundStyle(Theme.text2)
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                }

                Section("服务器") {
                    TextField(text: $server, prompt: Text(verbatim: "https://push.example.com")) { Text("服务器地址") }
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .server)
                        .submitLabel(.next)
                        .onSubmit { focus = usePair ? .code : .username }
                }

                Section {
                    Picker("登录方式", selection: $mode) {
                        Text("账号登录").tag(Mode.password)
                        Text("配对码").tag(Mode.pair)
                        if registerOpen == true { Text("注册").tag(Mode.register) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if usePair {
                    Section {
                        TextField("6 位配对码", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .font(.title3.monospacedDigit())
                            .focused($focus, equals: .code)
                            .onChange(of: code) { _, v in
                                let d = String(v.filter(\.isNumber).prefix(6))
                                if d != v { code = d }
                            }
                    } footer: {
                        Text("在已登录的设备上生成：iPhone「设置 → 账户与设备」、Mac「账户」→「生成配对码」，或管理后台「设备」页。3 分钟内有效，只能用一次。")
                    }
                } else if mode == .register {
                    Section {
                        TextField("用户名", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .username)
                            .submitLabel(.next)
                            .onSubmit { focus = .password }
                        SecureField("密码，至少 10 位，不要用常见密码", text: $password)
                            .textContentType(.newPassword)
                            .focused($focus, equals: .password)
                            .submitLabel(.next)
                            .onSubmit { focus = .password2 }
                        SecureField("再输入一次密码", text: $password2)
                            .textContentType(.newPassword)
                            .focused($focus, equals: .password2)
                            .submitLabel(.go)
                            .onSubmit(submit)
                    } header: {
                        Text("注册新账号")
                    } footer: {
                        if let p = registerProblem {
                            Text(p).foregroundStyle(Theme.danger)
                        } else {
                            Text((ManageRules.usernameProblem(username) ?? "用户名" + ManageRules.usernameRule)
                                 + "。注册后在「设置 → Pushkey」新建 pushkey，就可以开始发消息。")
                                .foregroundStyle(ManageRules.usernameProblem(username) == nil ? Theme.text2 : Theme.danger)
                        }
                    }
                } else {
                    Section {
                        TextField("用户名", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .username)
                            .submitLabel(.next)
                            .onSubmit { focus = .password }
                        SecureField("密码", text: $password)
                            .textContentType(.password)
                            .focused($focus, equals: .password)
                            .submitLabel(.go)
                            .onSubmit(submit)
                    }
                }

                Section {
                    TextField("这台设备的名称", text: $name)
                        .focused($focus, equals: .name)
                } header: {
                    Text("设备名称")
                } footer: {
                    Text("显示在其他设备和管理后台的设备列表里。")
                }

                if !model.settings.deviceID.isEmpty && !model.messages.isEmpty {
                    Section {
                        Label("重新登录同一服务器后，本机的 \(model.messages.count) 条消息记录会保留", systemImage: "tray.full")
                            .font(.footnote).foregroundStyle(Theme.text2)
                    }
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
                            .font(.subheadline)
                    }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text(mode == .pair ? "配对" : mode == .register ? "注册并登录" : "登录").bold() }
                            Spacer()
                        }
                    }
                    .disabled(busy)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            if server.isEmpty { server = model.settings.server.isEmpty ? AppInfo.defaultServer : model.settings.server }
            if username.isEmpty { username = model.settings.username }
            // 截图用：预填服务器地址、选中「注册」
            let d = UserDefaults.standard
            if let s = d.string(forKey: "demoLoginServer") { server = s }
            if d.string(forKey: "demoLoginMode") == "register" { pendingRegister = true }
        }
        // 服务器地址变了：停顿一下再查这个服务器是否开放注册（只查 /v1/info，不需要登录）
        .task(id: server) {
            registerOpen = nil
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            let s = API.normalize(server)
            guard let url = URL(string: s), url.host?.isEmpty == false else { return }
            let open = (try? await API(server: url, token: nil).info())?.register_open ?? false
            guard !Task.isCancelled else { return }
            registerOpen = open
            if !open && mode == .register { mode = .password }
            if open && pendingRegister { pendingRegister = false; mode = .register; username = "demo user" }
        }
    }

    private func submit() {
        let url = API.normalize(server)
        if url.isEmpty { error = "请填写服务器地址"; return }
        if usePair && code.count != 6 { error = "配对码是 6 位数字"; return }
        if !usePair && (username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty) { error = "请填写用户名和密码"; return }
        if mode == .register {
            if let p = ManageRules.usernameProblem(username) ?? registerProblem { error = p; return }
            if password != password2 { error = "两次输入的密码不一样"; return }
        }
        let deviceName = name.trimmingCharacters(in: .whitespaces).isEmpty ? UIDevice.current.name : name.trimmingCharacters(in: .whitespaces)
        busy = true
        error = nil
        focus = nil
        Task {
            defer { busy = false }
            do {
                if mode == .register {
                    try await model.register(server: server, username: username, password: password, name: String(deviceName.prefix(40)))
                } else {
                    try await model.login(server: server, username: username.trimmingCharacters(in: .whitespaces),
                                          password: password, code: code, usePair: usePair, name: String(deviceName.prefix(40)))
                }
                password = ""
                password2 = ""
                code = ""
            } catch {
                self.error = shortError(error)
            }
        }
    }
}

/// 应用标志：和 App 图标同一图形（HuijianMark），随深浅色切换
struct AppMark: View {
    var size: CGFloat = 48
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, sz in
            ctx.withCGContext {
                HuijianMark.draw(in: $0, rect: CGRect(origin: .zero, size: sz), palette: scheme == .dark ? HuijianMark.dark : HuijianMark.light, simple: size <= 40)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .accessibilityHidden(true)
    }
}
