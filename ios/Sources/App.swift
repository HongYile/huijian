import BackgroundTasks
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // 上次查看外部图片、下载更新包留下的临时文件
        MDExternalImage.clearTempFiles()
        UpdatePackage.clear()
        // 后台刷新任务必须在启动完成前注册
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppModel.refreshTaskID, using: nil) { task in
            guard let t = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in AppModel.shared.handleRefresh(t) }
        }
        return true
    }

    /// App 在前台时也显示横幅
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// 点通知：打开那条消息；设备请求解锁加密消息（T50）的通知打开「端到端加密」页核对后批准
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = (info[Notifier.messageIDKey] as? NSNumber)?.int64Value
        let e2e = info[Notifier.e2eKey] as? Bool == true
        let agent = info[Notifier.agentKey] as? Bool == true
        Task { @MainActor in
            if e2e { AppModel.shared.openE2E() }
            else if agent { AppModel.shared.openAgent() }
            else if let id { AppModel.shared.openMessage(id) }
            completionHandler()
        }
    }
}

@main
struct HuijianApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if Demo.selfTest {
                    SelfTestView()
                } else {
                    RootView()
                }
            }
            .environmentObject(model)
            .tint(Theme.accent)
            .onOpenURL { model.open(url: $0) }
            .alert(model.pairLinkNotice ?? "", isPresented: Binding(get: { model.pairLinkNotice != nil }, set: { if !$0 { model.pairLinkNotice = nil } })) {
                Button("好") { model.pairLinkNotice = nil }
            }
            .task { await Demo.runIfNeeded(model) }
        }
        .onChange(of: phase) { _, p in
            if !Demo.selfTest { model.scenePhaseChanged(p) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.loggedIn {
            NavigationStack(path: $model.path) {
                HomeView()
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .message(let id): DetailView(id: id)
                        case .settings: SettingsView()
                        case .keys: KeysView()
                        case .account: AccountManageView()
                        case .channels: ChannelsView()
                        case .e2e: E2EView()
                        }
                    }
            }
        } else {
            LoginView()
        }
    }
}
