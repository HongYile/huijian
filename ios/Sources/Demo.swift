import SwiftUI

/// 演示 / 测试模式（tests/sim_shots.sh、tests/selftest.sh 用）。参数通过启动参数传入，例如
///   xcrun simctl launch <设备> io.github.hongyile.huijian -demoServer http://127.0.0.1:28790 -demoUser me -demoPass xxx \
///     -demoReset YES -demoUnread 4 -demoOpen "exp42 完成"
/// 这些参数进入 UserDefaults 的参数域，不会写进持久设置。正常启动时不带这些参数，什么都不做。
enum Demo {
    private static var d: UserDefaults { .standard }

    static var server: String? { d.string(forKey: "demoServer") }
    static var selfTest: Bool { d.bool(forKey: "selfTest") }

    @MainActor
    static func runIfNeeded(_ model: AppModel) async {
        // 模拟点 Bark 通知冷启动（模拟器上 simctl openurl 会先弹系统确认框，脚本点不了）：和 onOpenURL 走同一个函数
        if let s = d.string(forKey: "demoOpenURL"), let u = URL(string: s) {
            model.open(url: u)
            return
        }
        guard let server, !selfTest else { return }
        model.skipNotifyPermission = true
        let user = d.string(forKey: "demoUser") ?? ""
        let pass = d.string(forKey: "demoPass") ?? ""
        if d.bool(forKey: "demoReset") || !model.loggedIn {
            if model.loggedIn { model.logout(notifyServer: false) }
            do {
                try await model.login(server: server, username: user, password: pass, code: "", usePair: false,
                                      name: d.string(forKey: "demoDeviceName") ?? "我的 iPhone")
            } catch {
                print("演示登录失败：\(shortError(error))")
                return
            }
        }
        await model.waitLoaded()      // 本地消息在后台读取，读完再演示标未读、打开消息
        // 等首次同步完成（首次同步会把消息全部标为已读）
        for _ in 0..<100 where !model.settings.initialSyncDone { try? await Task.sleep(nanoseconds: 200_000_000) }
        let unread = d.integer(forKey: "demoUnread")
        if unread > 0 { model.demoMarkUnread(unread) }
        // 等频道、Bark 配置等辅助信息拉完
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        // 演示 Bark 卡片：保存一个 Bark 地址（只保存，不发送）
        if let bark = d.string(forKey: "demoSetBark") {
            let key = d.string(forKey: "demoBarkKey") ?? BarkCipherStore.random(32)
            let iv = d.string(forKey: "demoBarkIV") ?? BarkCipherStore.random(16)
            do { try await model.saveBark(url: bark, encrypt: true, key: key, iv: iv) } catch { print("演示 Bark 设置失败：\(shortError(error))") }
        }
        if let t = d.string(forKey: "demoOpen"), let m = model.inbox.first(where: { $0.title.contains(t) }) {
            model.path = [.message(m.id)]
        } else if let page = d.string(forKey: "demoPage") {
            switch page {
            case "settings": model.path = [.settings]
            case "keys": model.path = [.settings, .keys]
            case "account": model.path = [.settings, .account]
            case "channels": model.path = [.settings, .channels]
            case "e2e": model.path = [.settings, .account, .e2e]
            default: break
            }
        }
    }
}
