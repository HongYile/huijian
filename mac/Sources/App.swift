import AppKit
import SwiftUI
import UserNotifications

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") {
            SelfTest.launch(Array(args[(i + 1)...]))
            return
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
        // 上次查看外部图片留下的临时文件
        MDExternalImage.clearTempFiles()
        AppDelegate.shared = self
        launchedAtLogin = detectLaunchedAtLogin()
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        let model = AppModel.shared
        let env = ProcessInfo.processInfo.environment
        if model.isDemo, env["HUIJIAN_DEMO_DARK"] != nil { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if model.isDemo, env["HUIJIAN_DEMO_LIGHT"] != nil { NSApp.appearance = NSAppearance(named: .aqua) }
        if !model.isDemo { Notifier.requestAuthorization() }
        model.start()
        if model.isDemo {
            NSApp.setActivationPolicy(.regular)
            // 截图用：反复激活并前置窗口，避免被台前调度收进侧边缩略图
            for i in 1...8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.7) {
                    NSApp.activate(ignoringOtherApps: true)
                    for w in NSApp.windows where w.isVisible && w.level == .normal { w.orderFrontRegardless() }
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
        if let id = MDLogic.messageID(url) {
            showMainWindow(select: id)
        } else {
            showMainWindow(select: nil)
        }
    }

    private func activate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
        window?.makeKeyAndOrderFront(nil)
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
        settingsWindow?.makeKeyAndOrderFront(nil)
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
        w.makeKeyAndOrderFront(nil)
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
        let id = (response.notification.request.content.userInfo["id"] as? NSNumber)?.int64Value
        Task { @MainActor in
            AppDelegate.shared?.showMainWindow(select: id)
            completionHandler()
        }
    }
}
