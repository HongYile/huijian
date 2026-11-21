using Microsoft.UI.Xaml;
using Microsoft.Windows.AppNotifications;

namespace Huijian;

public partial class App : Application
{
    public static MainWindow? Main { get; private set; }
    Tray? tray;
    public static bool Quitting;

    public App() { InitializeComponent(); }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // 通知：点击 / 快捷回复回到这里（未打包应用，Windows App SDK 负责注册 AppUserModelID）
        AppNotificationManager.Default.NotificationInvoked += (_, e) =>
            Main?.DispatcherQueue.TryEnqueue(() => Main.OnNotification(e.Arguments, e.UserInput));
        AppNotificationManager.Default.Register();

        Main = new MainWindow();
        Main.Activate();
        CreateTray();
    }

    void CreateTray()
    {
        tray = new Tray(Path.Combine(AppContext.BaseDirectory, "Assets", "huijian.ico"), "回笺", ShowMain, () =>
        [
            new("打开回笺", ShowMain),
            new("发一条测试通知", () => Main?.SendTestNotification()),
            Tray.Item.Separator,
            new("退出", Quit),
        ]);
    }

    public static void ShowMain()
    {
        if (Main == null) return;
        Main.AppWindow.Show();
        Main.Activate();
    }

    void Quit()
    {
        Quitting = true;
        tray?.Dispose();
        AppNotificationManager.Default.Unregister();
        Main?.Close();
        Exit();
    }

}
