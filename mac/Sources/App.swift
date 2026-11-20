import AppKit
import SwiftUI
import UserNotifications

@main
enum Entry {
    static func main() {
        // 最先检查：演示构建没带 --demo、正式构建带了 --demo、--demo 参数不完整，都直接退出，
        // 绝不退回正常模式去读写真实的回笺数据（DemoMode.swift）
        DemoMode.exitIfInvalid()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") {
            SelfTest.launch(Array(args[(i + 1)...]))
            return
        }
        if DemoMode.requested {
            // 演示模式的网络响应只缓存在内存里，不写 ~/Library/Caches/<Bundle ID>
            URLCache.shared = URLCache(memoryCapacity: 16 << 20, diskCapacity: 0, directory: nil)
        }
        HuijianApp.main()
    }
}

struct HuijianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            MenuLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    static weak var shared: AppDelegate?
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var extraWindow: NSWindow?

    /// 是否作为登录项在开机时自动启动（这种情况下只待在菜单栏，不弹窗口）
    private var launchedAtLogin = false

    /// 在 didFinishLaunching 里读取启动事件（willFinishLaunching 时 oapp 事件还没分发）。
    /// SMAppService 登录项不一定带「作为登录项启动」标记，所以再加一个兜底：开启了登录时启动、且开机不到 3 分钟。
    private func detectLaunchedAtLogin() -> Bool {
        let ev = NSAppleEventManager.shared().currentAppleEvent
        if ev?.eventID == kAEOpenApplication,
           ev?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        return AppModel.shared.launchAtLogin && ProcessInfo.processInfo.systemUptime < 180
    }

    /// 退出前把排队中的写盘做完（消息、已读、收藏在后台队列里写 messages.json）
    func applicationWillTerminate(_ notification: Notification) {
        AppModel.flushSaves()
    }

    /// 应用已经在运行时，再从启动台 / 访达 / Dock 打开它：显示主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(select: nil)
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 上次查看外部图片留下的临时文件（演示模式不清：那是正在运行的正式 App 的文件）
        if !DemoMode.requested { MDExternalImage.clearTempFiles() }
        AppDelegate.shared = self
        launchedAtLogin = detectLaunchedAtLogin()
        NSApp.setActivationPolicy(.accessory)
        // 演示模式不接管通知中心的回调（也不发、不撤通知，见 Notifier）
        if !DemoMode.requested { UNUserNotificationCenter.current().delegate = self }
        let model = AppModel.shared
        let env = ProcessInfo.processInfo.environment
        if model.isDemo, env["HUIJIAN_DEMO_DARK"] != nil { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if model.isDemo, env["HUIJIAN_DEMO_LIGHT"] != nil { NSApp.appearance = NSAppearance(named: .aqua) }
        if !model.isDemo { Notifier.requestAuthorization() }
        model.start()
        if model.isDemo {
            NSApp.setActivationPolicy(.regular)
            // 截图用：反复前置窗口（不激活 App，不抢键盘焦点；截图按窗口 id 截，不需要在最前）。
            // HUIJIAN_DEMO_ACTIVATE=1 时才激活（右键菜单之类需要 App 在前台的截图）
            for i in 1...8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.7) {
                    if Self.demoActivate { NSApp.activate(ignoringOtherApps: true) }
                    for w in NSApp.windows where w.isVisible && (w.level == .normal || w.level == .floating) { w.orderFrontRegardless() }
                }
            }
            switch env["HUIJIAN_DEMO_SHOW"] ?? "main" {
            case "panel": showStandalone(MenuPanel(model: model), title: "回笺 菜单栏面板", chromeless: true)
            case "settings": showSettings(tab: SettingsTab(rawValue: env["HUIJIAN_DEMO_TAB"] ?? "general") ?? .general)
            case "account": showAccount()
            case "setup": showStandalone(AccountSetupView().environmentObject(model).frame(width: 600, height: 700), title: "完成账号设置")
            case "pair": showStandalone(PairView().environmentObject(model).frame(width: 560, height: 600), title: "配对")
            default: showMainWindow(select: nil)
            }
        } else if model.token == nil || !launchedAtLogin {
            // 未配对，或者是用户手动打开的：显示主窗口；开机自动启动时只待在菜单栏
            showMainWindow(select: nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(url) }
    }

    /// huijian://message/<id>（Bark、iPhone、正文链接用的写法）和早期的 huijian://msg/<id>；改名前的 hongyan:// 也认
    func handle(_ url: URL) {
        guard url.scheme == "huijian" || url.scheme == "hongyan" else { return }
        // huijian://pair?server=…&code=…（配对码二维码，§12.3）：没登录 → 登录页填好；已登录 → T84，不做任何事
        if url.scheme == "huijian", url.host?.lowercased() == "pair" {
            let model = AppModel.shared
            if model.token == nil {
                model.pendingPairLink = url.absoluteString
                showMainWindow(select: nil)
            } else {
                showMainWindow(select: nil)
                let a = NSAlert()
                a.messageText = E2E.T.t84
                a.runModal()
            }
            return
        }
        if let id = MDLogic.messageID(url) {
            showMainWindow(select: id)
        } else {
            showMainWindow(select: nil)
        }
    }

    /// 演示模式默认不激活 App（截图期间用户可能在别处打字，不能把键盘焦点抢过来）
    static var demoActivate: Bool { ProcessInfo.processInfo.environment["HUIJIAN_DEMO_ACTIVATE"] == "1" }

    private func activate() {
        NSApp.setActivationPolicy(.regular)
        if AppModel.shared.isDemo && !Self.demoActivate { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 前置窗口。演示模式不激活 App 时：窗口放到浮动层并强制前置（不成为当前输入的窗口）
    private func bringFront(_ w: NSWindow?) {
        guard let w else { return }
        if AppModel.shared.isDemo && !Self.demoActivate {
            w.level = .floating
            w.orderFrontRegardless()
        } else {
            w.makeKeyAndOrderFront(nil)
        }
    }

    func showMainWindow(select id: Int64?) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = appDisplayName
            w.backgroundColor = Theme.nsBg
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MainView().environmentObject(AppModel.shared))
            w.minSize = NSSize(width: 900, height: 560)
            w.center()
            if !AppModel.shared.isDemo { w.setFrameAutosaveName("HuijianMain") }
            w.delegate = self
            window = w
        }
        if let id { AppModel.shared.select(id) }
        activate()
        bringFront(window)
    }

    /// 统一的「账户与设置」窗口。tab 为 nil 时保持当前页（新开时是「账户」）；指定 tab 时即使窗口已打开也切过去
    func showSettings(tab: SettingsTab? = nil) {
        if let tab, let w = settingsWindow {
            if w.isVisible {
                NotificationCenter.default.post(name: .huijianSelectSettingsTab, object: tab)
            } else {
                w.contentView = NSHostingView(rootView: SettingsView(tab: tab).environmentObject(AppModel.shared))
            }
        }
        if settingsWindow == nil {
            let vf = NSScreen.main?.visibleFrame
            let size = NSSize(width: min(920, (vf?.width ?? 1000) - 40), height: min(760, (vf?.height ?? 800) - 40))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = settingsWindowTitle
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.backgroundColor = Theme.nsBg
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 820, height: 560)
            w.contentView = NSHostingView(rootView: SettingsView(tab: tab ?? .account).environmentObject(AppModel.shared))
            w.center()
            w.delegate = self
            settingsWindow = w
        } else if let w = settingsWindow, !w.isVisible, tab == nil {
            // 关掉后重新打开：重新加载（账户页的设备列表、配对记录）
            w.contentView = NSHostingView(rootView: SettingsView(tab: .account).environmentObject(AppModel.shared))
        }
        activate()
        bringFront(settingsWindow)
    }

    /// 账户：统一设置窗口的第一页
    func showAccount() { showSettings(tab: .account) }

    /// 仅 demo 截图用：把菜单栏面板 / 配对页放进普通窗口
    private func showStandalone<V: View>(_ view: V, title: String, chromeless: Bool = false) {
        let host = NSHostingView(rootView: view)
        if chromeless { host.safeAreaRegions = [] }   // 面板截图不留标题栏空白
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize == .zero ? NSSize(width: 560, height: 600) : host.fittingSize),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = Theme.nsBg
        if chromeless { [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { w.standardWindowButton($0)?.isHidden = true } }
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.center()
        extraWindow = w
        activate()
        bringFront(w)
    }

    func windowWillClose(_ notification: Notification) {
        let others = [window, settingsWindow].compactMap { $0 }.filter { $0 !== notification.object as? NSWindow && $0.isVisible }
        if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    // 前台也显示通知
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = (info["id"] as? NSNumber)?.int64Value
        let e2e = info["e2e"] as? Bool == true
        Task { @MainActor in
            // 设备请求解锁加密消息（T50）：打开设置的「加密」页核对后批准
            if e2e { AppDelegate.shared?.showSettings(tab: .e2e) } else { AppDelegate.shared?.showMainWindow(select: id) }
            completionHandler()
        }
    }
}
