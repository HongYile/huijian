import Foundation

/// 演示模式（GUI 截图，tests/gui_shots.sh）：`--demo <服务器地址> <设备 token> <工作目录>`。
///
/// 只要命令行里出现 `--demo`，App 就绝不读写用户真实的回笺数据：
/// - 偏好：全部用独立的偏好域 `suite`（AppModel、更新器、心跳记录、设备指纹兜底 ID 都走这里），每次启动先清空；
/// - 钥匙串：不读也不写。设备 token 由参数注入，Keychain 在演示模式下只用进程内存；加密私钥用 E2E.MemorySecrets；
/// - 数据和附件缓存：放在参数给的工作目录里（不能是正常模式的数据目录或它的上级目录）。
/// 参数不完整或不合法时直接退出（Entry.main），绝不退回正常模式。
///
/// 演示构建（build.sh 带 DEMO_ONLY=1，Info.plist 里 HuijianDemoOnly=true，Bundle ID 不能是正式的）和 --demo 必须同时出现：
/// - 演示构建不带 --demo（比如从启动台、访达、huijian:// 链接被打开）：退出，不会以正常模式去用真实数据；
/// - 正式 / 开发构建带 --demo：也退出。和正式版同一个 Bundle ID 时，通知中心、URL 缓存、AppKit 自己写的偏好都隔不开。
/// 演示模式下通知一概不发、不撤（Notifier），也不接管通知中心的回调。
enum DemoMode {
    static let flag = "--demo"
    static let suite = "io.github.hongyile.huijian.demo"
    static let keychainService = "io.github.hongyile.huijian.demo"

    /// 命令行里有 --demo（不论参数是否完整；--demo=… 之类以 --demo 开头的写法也算，按不合法处理）
    static let requested = isRequested(CommandLine.arguments)

    static func isRequested(_ a: [String]) -> Bool { a.dropFirst().contains { $0.hasPrefix(flag) } }

    /// 这是只能用于演示的构建（gui_shots.sh 构建的那份）
    static let demoOnlyBuild = Bundle.main.object(forInfoDictionaryKey: "HuijianDemoOnly") as? Bool == true

    struct Args {
        let server: String
        let token: String
        let workdir: URL
    }

    /// 解析好的参数；requested 为 true 而这里是 nil 时不能启动
    static let args: Args? = parse(CommandLine.arguments)

    static func parse(_ a: [String]) -> Args? {
        guard let i = a.firstIndex(of: flag), i + 3 < a.count else { return nil }
        let server = a[i + 1], token = a[i + 2], dir = a[i + 3]
        guard let u = URL(string: server), u.scheme == "http" || u.scheme == "https", u.host != nil else { return nil }
        guard !token.isEmpty, !token.hasPrefix("-"), !token.contains(where: { $0.isWhitespace }) else { return nil }
        guard dir.hasPrefix("/") else { return nil }
        // 先解析符号链接、规范化（.. 和 //），再判断是不是根目录；比较时不区分大小写（APFS 默认不区分）
        let wd = canonical(dir)
        guard wd != "/" else { return nil }
        // 工作目录不能是正常模式的数据 / 缓存目录，也不能在它们里面或包含它们（比如整个用户目录）
        let real = AppPaths.standard
        let w = wd.lowercased()
        for r in [canonical(real.supportDir.path), canonical(real.cacheDir.path)].map({ $0.lowercased() })
        where w == r || w.hasPrefix(r + "/") || r.hasPrefix(w + "/") {
            return nil
        }
        return Args(server: server, token: token, workdir: URL(fileURLWithPath: wd, isDirectory: true))
    }

    /// 规范化路径：去掉 . 和 ..、合并多余的 /，并把已存在的那一段祖先目录按 realpath 解析符号链接
    /// （工作目录本身通常还不存在，所以从最近的已存在祖先开始解析，再接上后面的部分）
    static func canonical(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).standardizedFileURL.path
        var tail: [String] = []
        while true {
            if let r = realpath(p, nil) {
                var out = String(cString: r)
                free(r)
                for c in tail.reversed() { out = (out as NSString).appendingPathComponent(c) }
                return URL(fileURLWithPath: out).standardizedFileURL.path
            }
            if p == "/" || p.isEmpty { return URL(fileURLWithPath: path).standardizedFileURL.path }
            tail.append((p as NSString).lastPathComponent)
            p = (p as NSString).deletingLastPathComponent
        }
    }

    /// 演示模式用独立偏好域，正常模式用标准偏好
    static let defaults: UserDefaults = requested ? (UserDefaults(suiteName: suite) ?? fatalDefaults()) : .standard

    private static func fatalDefaults() -> UserDefaults {
        FileHandle.standardError.write(Data("演示模式：无法打开独立的偏好域，不启动\n".utf8))
        exit(2)
    }

    /// 演示模式的心跳记录（Heartbeat.shared 固定写标准偏好，演示模式不用它）
    @MainActor static let heartbeat = Heartbeat(
        load: { k in defaults.data(forKey: "hb.\(k)").flatMap { try? JSONDecoder().decode(Heartbeat.State.self, from: $0) } },
        save: { k, s in defaults.set(try? JSONEncoder().encode(s), forKey: "hb.\(k)") })

    /// 演示模式下 Keychain 的替身：只在进程内存里
    nonisolated(unsafe) static var memoryKeychain: [String: String] = [:]
    static let memoryLock = NSLock()

    /// 能不能启动：返回 nil 表示可以，否则是不启动的原因
    static func refusal(arguments a: [String], demoOnlyBuild: Bool) -> String? {
        let req = isRequested(a)
        if demoOnlyBuild && !req {
            return "这是只用于截图的演示构建，只能带 --demo 启动（以免用本机真实的回笺数据）。"
        }
        if req && !demoOnlyBuild {
            return "--demo 只能用演示构建（tests/gui_shots.sh 构建的那份）；正式版和开发构建不能进入演示模式。"
        }
        if req && parse(a) == nil {
            return "--demo 参数不完整或不合法，不启动（以免读写本机真实的回笺设置和钥匙串）。\n"
                + "用法：Huijian --demo <http(s) 服务器地址> <设备 token> <工作目录绝对路径>"
        }
        return nil
    }

    /// 不能启动时打印原因并以退出码 2 退出（Entry.main 里最先调用，在任何界面、偏好、钥匙串读写之前）
    static func exitIfInvalid() {
        guard let why = refusal(arguments: CommandLine.arguments, demoOnlyBuild: demoOnlyBuild) else { return }
        FileHandle.standardError.write(Data((why + "\n").utf8))
        exit(2)
    }
}
