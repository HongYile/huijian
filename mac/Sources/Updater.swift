import AppKit
import CryptoKit
import Foundation
import Security

/// 只在 --selftest 模式下打开的测试口子（本地模拟 GitHub、http 下载地址）；正式运行时始终为 false
enum TestHooks {
    nonisolated(unsafe) static var enabled = false
}

/// 本应用的版本信息（来自 Info.plist，由 build.sh 写入）
enum AppInfo {
    static let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    static let build = Int((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "") ?? 0
    /// 更新包签名公钥（base64 的 32 字节 Ed25519 公钥）。为空时不支持应用内更新。
    static let updatePublicKey = ((Bundle.main.object(forInfoDictionaryKey: "HuijianUpdatePublicKey") as? String) ?? "")
        .trimmingCharacters(in: .whitespaces)
    static var clientLabel: String { "macos \(version) (\(build))" }
    /// 更新源：hub（自己的服务器）或 github:<owner>/<repo>（GitHub Releases）
    static let updateSource = UpdateSource.parse((Bundle.main.object(forInfoDictionaryKey: "HuijianUpdateSource") as? String) ?? "")
}

enum UpdateSource: Equatable {
    case hub
    case github(String)

    static func parse(_ s: String) -> UpdateSource {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("github:") {
            let repo = String(t.dropFirst("github:".count))
            if repo.split(separator: "/").count == 2 { return .github(repo) }
        }
        return .hub
    }

    var label: String {
        switch self {
        case .hub: return "你的回笺服务器"
        case .github(let r): return "GitHub（\(r)）"
        }
    }
}

/// GitHub Releases 更新源：每个 release 带 update-macos.json（签名清单）和对应的 zip。
/// 请求不带任何凭证（尤其不能带设备 token）；签名校验与 hub 源完全相同。
enum GitHubUpdates {
    static let manifestName = "update-macos.json"

    /// API 地址；只有自检模式下才允许用环境变量指向本地模拟服务
    static var apiBase: String {
        if TestHooks.enabled, let u = ProcessInfo.processInfo.environment["HUIJIAN_GITHUB_API"] { return u }
        return "https://api.github.com"
    }

    struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let assets: [Asset]
    }

    struct Manifest: Decodable {
        let version: String
        let build: Int
        let notes: String
        let size: Int64
        let sha256: String
        let signature: String
        let zip: String
    }

    static func latest(repo: String, session: URLSession) async throws -> UpdateInfo {
        var r = URLRequest(url: URL(string: "\(apiBase)/repos/\(repo)/releases/latest")!)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("huijian-mac/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw UpdateError.msg("GitHub 无响应") }
        if h.statusCode == 404 { throw UpdateError.msg("GitHub 上还没有发布版本") }
        guard h.statusCode == 200 else { throw UpdateError.msg("GitHub 返回 HTTP \(h.statusCode)") }
        let rel = try JSONDecoder().decode(Release.self, from: data)
        guard let m = rel.assets.first(where: { $0.name == manifestName }), let mu = URL(string: m.browser_download_url) else {
            throw UpdateError.msg("最新版本没有 \(manifestName)")
        }
        var mr = URLRequest(url: mu)
        mr.setValue("huijian-mac/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (md, mresp) = try await session.data(for: mr)
        guard (mresp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.msg("下载更新清单失败") }
        let man = try JSONDecoder().decode(Manifest.self, from: md)
        guard let z = rel.assets.first(where: { $0.name == man.zip }) else { throw UpdateError.msg("最新版本缺少 \(man.zip)") }
        return UpdateInfo(id: 0, version: man.version, build: man.build, notes: man.notes, size: man.size,
                          sha256: man.sha256, signature: man.signature, url: z.browser_download_url)
    }
}

struct UpdateInfo: Decodable, Equatable {
    let id: Int64
    let version: String
    let build: Int
    let notes: String
    let size: Int64
    let sha256: String
    let signature: String
    let url: String
}

enum UpdateError: LocalizedError {
    case msg(String)
    var errorDescription: String? { if case .msg(let m) = self { return m }; return nil }
}

/// 更新包校验。信任链：Ed25519 签名（私钥只在发布方开发机上）→ 文件 sha256 → 包内版本与 Bundle ID → 代码签名身份。
enum UpdateVerifier {
    /// 与服务端 releaseMessage 完全一致
    static func message(platform: String, build: Int, version: String, sha256: String, notes: String) -> Data {
        let notesHash = SHA256.hash(data: Data(notes.utf8)).map { String(format: "%02x", $0) }.joined()
        return Data("hongyan-update-v1\n\(platform)\n\(build)\n\(version)\n\(sha256)\n\(notesHash)".utf8)
    }

    static func verifySignature(_ info: UpdateInfo, publicKey: String, platform: String = "macos") throws {
        guard let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            throw UpdateError.msg("此版本没有内置有效的更新公钥，无法应用内更新")
        }
        guard let sig = Data(base64Encoded: info.signature), sig.count == 64 else { throw UpdateError.msg("更新包签名格式不对") }
        let ok = key.isValidSignature(sig, for: message(platform: platform, build: info.build, version: info.version,
                                                          sha256: info.sha256.lowercased(), notes: info.notes))
        guard ok else { throw UpdateError.msg("更新包签名校验失败，已拒绝安装") }
    }

    /// 解压后的 .app：Bundle ID 必须与当前一致，版本号与签名内容一致
    static func checkBundle(_ app: URL, info: UpdateInfo, bundleID: String) throws {
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.msg("更新包里没有有效的 Info.plist")
        }
        guard plist["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError.msg("更新包的 Bundle ID 与当前应用不一致") }
        guard plist["CFBundleVersion"] as? String == String(info.build),
              plist["CFBundleShortVersionString"] as? String == info.version else {
            throw UpdateError.msg("更新包内的版本号与发布信息不一致")
        }
    }

    /// 代码签名：新包必须完整有效；若当前应用用固定证书签名（而不是 ad-hoc），新包还必须满足当前应用的指定要求（同一证书）。
    static func checkCodeSignature(newApp: URL, currentApp: URL) throws {
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(newApp as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError.msg("无法读取更新包的代码签名")
        }
        var req: SecRequirement?
        if let dr = designatedRequirement(of: currentApp), !dr.text.contains("cdhash") {
            req = dr.req
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let st = SecStaticCodeCheckValidity(newCode, flags, req)
        guard st == errSecSuccess else {
            throw UpdateError.msg(req == nil ? "更新包的代码签名无效（\(st)）" : "更新包的签名证书与当前应用不一致（\(st)）")
        }
    }

    static func designatedRequirement(of app: URL) -> (req: SecRequirement, text: String)? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess, let req else { return nil }
        var text: CFString?
        SecRequirementCopyString(req, [], &text)
        return (req, (text as String?) ?? "")
    }

    /// 应用所在位置能否原地替换
    static func installTarget(_ bundle: URL = Bundle.main.bundleURL) throws -> URL {
        let path = bundle.path
        guard bundle.pathExtension == "app" else { throw UpdateError.msg("当前不是以 .app 方式运行，无法应用内更新") }
        if path.contains("/AppTranslocation/") {
            throw UpdateError.msg("应用正在隔离位置运行，请先把回笺拖进「应用程序」文件夹再更新")
        }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path), fm.isWritableFile(atPath: path) else {
            throw UpdateError.msg("没有权限替换 \(path)")
        }
        return bundle
    }
}

/// 下载、解压、校验，返回可以安装的 .app（位于 workDir 内）
enum UpdatePreparer {
    /// 下载请求由调用方构造：hub 源带设备 token，GitHub 源不带任何凭证
    static func downloadRequest(_ info: UpdateInfo, client: APIClient?) throws -> URLRequest {
        if info.url.hasPrefix("/") {
            guard let client else { throw UpdateError.msg("尚未配对，无法从服务器下载更新") }
            return client.request(info.url)
        }
        guard let u = URL(string: info.url), u.scheme == "https" || (TestHooks.enabled && u.host == "127.0.0.1") else {
            throw UpdateError.msg("更新包地址不安全：\(info.url)")
        }
        var r = URLRequest(url: u)
        r.setValue("huijian-mac/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        return r
    }

    static func prepare(_ info: UpdateInfo, request: URLRequest, engine: DownloadEngine, workDir: URL,
                        publicKey: String, currentApp: URL, bundleID: String,
                        onVerify: @escaping () -> Void = {},
                        progress: @escaping (Double) -> Void) async throws -> URL {
        try UpdateVerifier.verifySignature(info, publicKey: publicKey)   // 先验签，签名不对就不下载
        let fm = FileManager.default
        try? fm.removeItem(at: workDir)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let zip = workDir.appendingPathComponent("update.zip")
        var req = request
        req.timeoutInterval = 120
        _ = try await engine.download(req, expectedSize: info.size, to: zip, tag: "update-\(info.build)", progress: progress)
        onVerify()
        let size = (try? fm.attributesOfItem(atPath: zip.path)[.size] as? Int64) ?? -1
        guard size == info.size, try sha256OfFile(zip) == info.sha256.lowercased() else {
            throw UpdateError.msg("更新包校验失败：sha256 或大小不一致")
        }
        let stage = workDir.appendingPathComponent("stage")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, stage.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.msg("解压更新包失败") }
        let apps = (try fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil)).filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else { throw UpdateError.msg("更新包里应当只有一个 .app") }
        try UpdateVerifier.checkBundle(app, info: info, bundleID: bundleID)
        try UpdateVerifier.checkCodeSignature(newApp: app, currentApp: currentApp)
        return app
    }
}

/// 替换脚本：等当前进程退出 → 旧版本移到一边 → 新版本移入 → 删除旧版本（失败则恢复）→ 重新打开。
/// 由独立的 /bin/sh 进程执行，应用退出后继续运行。
enum UpdateInstaller {
    static let script = #"""
    PID="$1"; NEW="$2"; DST="$3"; LOG="$4"; RELAUNCH="$5"
    exec >>"$LOG" 2>&1
    echo "[$(date '+%F %T')] 更新开始：$NEW -> $DST"
    i=0
    while kill -0 "$PID" 2>/dev/null; do
      sleep 0.2; i=$((i+1))
      if [ $i -gt 300 ]; then echo "等待旧进程退出超时，放弃"; exit 1; fi
    done
    OLD="$(dirname "$DST")/.$(basename "$DST").old-$$"
    rm -rf "$OLD"
    if mv "$DST" "$OLD"; then
      if mv "$NEW" "$DST"; then
        rm -rf "$OLD"
        xattr -dr com.apple.quarantine "$DST" 2>/dev/null
        echo "替换完成"
      else
        echo "移入新版本失败，恢复旧版本"
        mv "$OLD" "$DST"
      fi
    else
      echo "移走旧版本失败，未做任何改动"
    fi
    [ "$RELAUNCH" = "1" ] && open "$DST"
    exit 0
    """#

    /// 启动替换进程。用 posix_spawn + POSIX_SPAWN_SETSID 放进新的会话和进程组，
    /// 这样即使 App 由 launchd 启动（例如登录项），App 退出时回收进程组也不会连带杀掉替换脚本。
    /// relaunch=false 仅供自检使用。
    @discardableResult
    static func launch(newApp: URL, target: URL, waitPID: Int32, log: URL, relaunch: Bool) throws -> pid_t {
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let argv = ["/bin/sh", "-c", script, "huijian-update", String(waitPID), newApp.path, target.path, log.path, relaunch ? "1" : "0"]
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        for fd: Int32 in [0, 1, 2] {
            posix_spawn_file_actions_addopen(&fa, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/sh", &fa, &attr, &cargs, environ)
        guard rc == 0 else { throw UpdateError.msg("启动替换脚本失败（\(rc)）") }
        return pid
    }
}

@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(Double)
        case verifying      // 下载完成，校验签名、sha256、代码签名
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var available: UpdateInfo?
    @Published private(set) var lastChecked: Date?
    @Published var autoCheck: Bool { didSet { defaults.set(autoCheck, forKey: AppModel.key("autoCheckUpdates")) } }

    private let defaults: UserDefaults
    private let engine: DownloadEngine
    private let clientProvider: () -> APIClient?
    private let workDir: URL
    private var timer: Timer?
    private var hintedBuild: Int?
    private var lastProgress = -1

    var supported: Bool { !AppInfo.updatePublicKey.isEmpty }
    let source: UpdateSource
    var busy: Bool {
        switch phase {
        case .checking, .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    init(defaults: UserDefaults, workDir: URL, engine: DownloadEngine, source: UpdateSource = AppInfo.updateSource,
         client: @escaping () -> APIClient?) {
        self.defaults = defaults
        self.source = source
        self.engine = engine
        self.workDir = workDir
        self.clientProvider = client
        autoCheck = defaults.object(forKey: AppModel.key("autoCheckUpdates")) as? Bool ?? true
    }

    /// 删除已经用不到的更新工作目录：构建号不大于当前版本的（已安装或已过时），以及超过一天的残留。
    func cleanupWorkDir(now: Date = Date()) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for u in items {
            let b = Int(u.lastPathComponent.replacingOccurrences(of: "build-", with: "")) ?? 0
            let mtime = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if b <= AppInfo.build || now.timeIntervalSince(mtime) > 24 * 3600 { try? fm.removeItem(at: u) }
        }
    }

    /// 启动后定时检查（每 6 小时）。真正的及时提醒靠长轮询响应头 X-Huijian-Latest-Build。
    func startSchedule() {
        cleanupWorkDir()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoCheck else { return }
                await self.check()
            }
        }
    }

    /// 长轮询响应头告知的最新构建号。
    /// - 同一个构建号只触发一次检查（检查失败也不反复重试，交给定时检查和手动检查）；
    /// - 服务端最新版本已经不比提示中的新（版本被删除）时，清掉过期的提示。
    func noteLatestBuild(_ b: Int?) {
        guard source == .hub else { return }   // 只有 hub 源的长轮询响应头才有意义
        if let info = available, (b ?? 0) < info.build, !busy {
            available = nil
            if case .failed = phase { phase = .idle }
        }
        guard let b, b > AppInfo.build, autoCheck, !busy, available?.build != b, hintedBuild != b else { return }
        hintedBuild = b
        Task { await check() }
    }

    func check(userInitiated: Bool = false) async {
        guard !busy else { return }
        guard supported else {
            if userInitiated { phase = .failed("此版本没有内置更新公钥，无法应用内更新") }
            return
        }
        let client = clientProvider()
        if source == .hub, client == nil {
            if userInitiated { phase = .failed("尚未配对，无法检查更新") }
            return
        }
        phase = .checking
        do {
            let info: UpdateInfo?
            switch source {
            case .hub: info = try await client!.update(build: AppInfo.build)
            case .github(let repo): info = try await GitHubUpdates.latest(repo: repo, session: APIClient.updateSession)
            }
            lastChecked = Date()
            if let info, info.build > AppInfo.build {
                try UpdateVerifier.verifySignature(info, publicKey: AppInfo.updatePublicKey)
                available = info
                phase = .idle
            } else {
                available = nil
                phase = .upToDate
            }
        } catch {
            phase = userInitiated || available != nil ? .failed(Self.describe(error)) : .idle
        }
    }

    /// 下载、校验，然后退出并由替换脚本完成安装和重启
    func installAvailable() async {
        guard let info = available, !busy else { return }
        do {
            let request = try UpdatePreparer.downloadRequest(info, client: clientProvider())
            let target = try UpdateVerifier.installTarget()
            phase = .downloading(0)
            lastProgress = 0
            for old in (try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent != "build-\(info.build)" { try? FileManager.default.removeItem(at: old) }
            // 更新包只有几 MB，局域网里零点几秒就下完；每个阶段至少停留一会儿，
            // 让进度条走满、校验和安装都看得见，而不是闪一下就重启
            var verifyStart = Date()
            let app = try await UpdatePreparer.prepare(
                info, request: request, engine: engine, workDir: workDir.appendingPathComponent("build-\(info.build)"),
                publicKey: AppInfo.updatePublicKey, currentApp: Bundle.main.bundleURL,
                bundleID: Bundle.main.bundleIdentifier ?? "",
                onVerify: { [weak self] in
                    Task { @MainActor in
                        guard let self, case .downloading = self.phase else { return }
                        verifyStart = Date()
                        self.phase = .verifying
                    }
                },
                progress: { [weak self] p in
                    Task { @MainActor in
                        guard let self, case .downloading = self.phase else { return }
                        let pct = Int(p * 100)
                        if pct != self.lastProgress { self.lastProgress = pct; self.phase = .downloading(p) }
                    }
                })
            if phase != .verifying { verifyStart = Date(); phase = .verifying }
            await Self.hold(since: verifyStart, seconds: 0.9)
            phase = .installing
            try? await Task.sleep(for: .milliseconds(700))
            let log = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/Huijian/update.log")
            try UpdateInstaller.launch(newApp: app, target: target, waitPID: getpid(), log: log, relaunch: true)
            AppModel.shared.save()
            NSApp.terminate(nil)
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// 仅 demo 截图用
    func demoShow(_ info: UpdateInfo) {
        available = info
        lastChecked = Date()
    }

    /// 仅截图用：直接显示某个更新阶段
    func demoPhase(_ p: Phase) { phase = p }

    func cancel() {
        if let b = available?.build { engine.cancel(tag: "update-\(b)") }
    }

    /// 从 since 起至少过去 seconds 秒
    static func hold(since: Date, seconds: Double) async {
        let left = seconds - Date().timeIntervalSince(since)
        if left > 0 { try? await Task.sleep(for: .milliseconds(Int(left * 1000))) }
    }

    static func describe(_ e: Error) -> String {
        if let u = e as? UpdateError { return u.localizedDescription }
        if let a = e as? APIError { return a.localizedDescription }
        return AppModel.shortError(e)
    }
}
