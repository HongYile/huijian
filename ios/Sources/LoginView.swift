import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var server = ""
    @State private var mode: Mode = .password
    /// 服务端的注册方式（GET /v1/info：0.9.0 起 register = closed / invite / open，旧服务端看 register_open）；nil = 还不知道
    @State private var registerMode: String?
    @State private var inviteCode = ""
    /// 上次注册结果不确定（共用 E2E 的 Failure.uncertain：请求发出后网络出错 / 超时）的「服务器|用户名」：
    /// 再注册被拒（409 / 403）时提示改去登录（E2E.registerAfterUncertain）。只在内存里，不持久化
    @State private var registerUnsureFor: String?
    @State private var password2 = ""
    @State private var pendingRegister = false
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var name = UIDevice.current.name
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case server, username, password, password2, invite, code, name }
    private var needsInvite: Bool { registerMode == "invite" }
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
                        if registerMode == "open" || registerMode == "invite" { Text("注册").tag(Mode.register) }
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
                        Text("在已登录的设备上生成：iPhone「设置 → 账户与设备」、Mac「账户」→「生成配对码」。3 分钟内有效，只能用一次。")
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
                            .submitLabel(needsInvite ? .next : .go)
                            .onSubmit { if needsInvite { focus = .invite } else { submit() } }
                        // 这个服务器只接受邀请注册：邀请码必填（向服务器管理员要）
                        if needsInvite {
                            TextField("邀请码", text: $inviteCode)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .invite)
                                .submitLabel(.go)
                                .onSubmit(submit)
                        }
                    } header: {
                        Text("注册新账号")
                    } footer: {
                        if let p = registerProblem {
                            Text(p).foregroundStyle(Theme.danger)
                        } else {
                            Text((ManageRules.usernameProblem(username) ?? "用户名" + ManageRules.usernameRule)
                                 + (needsInvite ? "。这个服务器需要邀请码才能注册，请向服务器管理员索取" : "")
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
                    } footer: {
                        // 账号只能注册产生（服务端 0.9.0）：这个服务器不开放注册时不显示「注册」，在这里说明原因
                        if registerMode == "closed" { Text("这个服务器没有开放注册，请联系管理员。") }
                    }
                }

                Section {
                    TextField("这台设备的名称", text: $name)
                        .focused($focus, equals: .name)
                } header: {
                    Text("设备名称")
                } footer: {
                    Text("显示在你其他设备的设备列表里。")
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
                        // 注册结果不确定：账号可能已经建好，直接换成登录（用户名、密码保留）
                        if mode == .register && registerUnsureFor == registerKey {
                            Button("去登录") { mode = .password; self.error = nil }
                                .font(.subheadline.weight(.medium))
                        }
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
        // 「上次注册结果不确定」只在换了服务器或用户名、或者注册 / 登录成功时清掉；中间的 429、本地校验错误（密码太短、两次不一致）都保留
        .onChange(of: registerKey) { _, k in
            if let u = registerUnsureFor, u != k { registerUnsureFor = nil }
        }
        // 进入「注册」时重新取一次注册方式（三端一致：取不到不猜，提示连不上）
        .onChange(of: mode) { _, m in
            guard m == .register else { return }
            Task {
                if await reloadRegisterMode() == nil, mode == .register { error = E2E.T.serverUnreachable }
            }
        }
        // 服务器地址变了：停顿一下再查这个服务器是否开放注册（只查 /v1/info，不需要登录）
        .task(id: server) {
            registerMode = nil
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            let s = API.normalize(server)
            guard let url = URL(string: s), url.host?.isEmpty == false else { return }
            // 连不上 / 取不到：当作还不知道（不显示注册入口，也不提示「没有开放注册」）
            let info = try? await API(server: url, token: nil).info()
            guard !Task.isCancelled else { return }
            let m = info?.registerMode ?? "closed"
            registerMode = info?.registerMode
            let open = m != "closed"
            // 不开放注册：不显示注册入口
            if !open && mode == .register { mode = .password }
            if open && pendingRegister { pendingRegister = false; mode = .register; username = "demo user" }
        }
    }

    /// 重新取一次 /v1/info 的注册方式（三端一致：取不到时不猜）。取到时更新 registerMode（closed 时退回账号登录）并返回；
    /// 取不到返回 nil，registerMode 保持原样
    private func reloadRegisterMode() async -> String? {
        let s = API.normalize(server)
        guard let url = URL(string: s), url.host?.isEmpty == false,
              let info = try? await API(server: url, token: nil).info() else { return nil }
        guard API.normalize(server) == s else { return nil }   // 取的过程中改了地址：作废
        let m = info.registerMode
        registerMode = m
        if m == "closed" && mode == .register { mode = .password }
        return m
    }

    private var registerKey: String { API.normalize(server) + "|" + ManageRules.normalizeUsername(username).lowercased() }

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
        let regKey = registerKey, isRegister = mode == .register
        busy = true
        error = nil
        focus = nil
        Task {
            defer { busy = false }
            do {
                if isRegister {
                    // 提交前重新取一次注册方式：取不到不猜、不提交；不开放注册了就退回登录；改成要邀请码了就先让用户填
                    guard let m = await reloadRegisterMode() else { error = E2E.T.serverUnreachable; return }
                    if m == "closed" { error = "这个服务器没有开放注册，请联系管理员。"; return }
                    let invite = inviteCode.trimmingCharacters(in: .whitespaces)
                    if m == "invite" && invite.isEmpty { error = "请填写邀请码"; focus = .invite; return }
                    try await model.register(server: server, username: username, password: password, name: String(deviceName.prefix(40)),
                                             inviteCode: m == "invite" ? invite : nil)
                } else {
                    try await model.login(server: server, username: username.trimmingCharacters(in: .whitespaces),
                                          password: password, code: code, usePair: usePair, name: String(deviceName.prefix(40)))
                }
                password = ""
                password2 = ""
                code = ""
                inviteCode = ""
                registerUnsureFor = nil
            } catch {
                if isRegister {
                    let m = AppModel.registerMessage(error, unsureBefore: registerUnsureFor == regKey)
                    // 只在结果不确定时记下；其他任何报错都不动它（清掉只在成功、换服务器 / 用户名时）
                    if m.unsure { registerUnsureFor = regKey }
                    self.error = m.text
                    // 403（没开放注册、要邀请码、邀请码不对……）：重新取一次注册方式，刷新界面（取不到就保持原样）
                    if (error as? E2E.Failure)?.status == 403 { _ = await reloadRegisterMode() }
                } else {
                    self.error = shortError(error)
                }
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
