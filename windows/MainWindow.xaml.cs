using System.Diagnostics;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace Huijian;

public sealed partial class MainWindow : Window
{
    static readonly Stopwatch Startup = Stopwatch.StartNew();

    public MainWindow()
    {
        InitializeComponent();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(900, 640));
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "huijian.ico"));
        // 关窗口 = 收到托盘，不退出（和 Mac 关窗口后留在菜单栏一致）
        AppWindow.Closing += (_, e) => { if (!App.Quitting) { e.Cancel = true; AppWindow.Hide(); } };
        Activated += FirstActivated;
        RunChecks();
    }

    void FirstActivated(object sender, WindowActivatedEventArgs e)
    {
        Activated -= FirstActivated;
        Mem.Text = MemText($"启动到窗口出现 {Startup.ElapsedMilliseconds} ms（进程起算 {(DateTime.Now - Process.GetCurrentProcess().StartTime).TotalMilliseconds:F0} ms）。");
        Log(CoreInfo.Text); Log(Argon.Text); Log(Md.Text); Log(Mem.Text.Replace("\n", " "));
        _ = Task.Delay(5000).ContinueWith(_ => DispatcherQueue.TryEnqueue(() => Log("5 秒后" + MemText("").Replace("\n", " "))));
    }

    void RunChecks()
    {
        try
        {
            CoreInfo.Text = $"共用核心 huijian_core {Core.Version()} 已加载。";
            var salt = Core.Call("new_salt")["salt"]!.GetValue<string>();
            var sw = Stopwatch.StartNew();
            Core.Call("password_keys", new JsonObject { ["password"] = "correct horse battery", ["salt"] = salt });
            Argon.Text = $"Argon2id（登录凭证 + 解锁钥匙）耗时 {sw.ElapsedMilliseconds} ms。";
            var doc = Core.Call("md_build", new JsonObject { ["text"] = "标题", ["desp"] = "> [!SUCCESS] 完成\n**加粗** 和 `代码`\n![进度](progress:3/4)" });
            var s = doc.ToJsonString();
            Md.Text = "md_build：" + (s.Length > 300 ? s[..300] + "…" : s);
        }
        catch (Exception ex) { CoreInfo.Text = "核心库出错：" + ex.Message; }
    }

    /// 原型检测结果同时写到 %LOCALAPPDATA%\Huijian\proto.log，方便远程查看
    static void Log(string line)
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Huijian");
        Directory.CreateDirectory(dir);
        File.AppendAllText(Path.Combine(dir, "proto.log"), $"{DateTime.Now:HH:mm:ss} {line}\n");
    }

    static string MemText(string prefix)
    {
        var p = Process.GetCurrentProcess();
        p.Refresh();
        return $"{prefix}\n内存：工作集 {p.WorkingSet64 / 1048576} MB，专用 {p.PrivateMemorySize64 / 1048576} MB。";
    }

    void OnMem(object sender, RoutedEventArgs e) => Mem.Text = MemText("");

    void OnTestNotify(object sender, RoutedEventArgs e) => SendTestNotification();

    public void SendTestNotification()
    {
        var n = new AppNotificationBuilder()
            .AddArgument("msg", "42")
            .AddText("【重要】agent 问你：继续吗？")
            .AddText("#agent · 家里 Claude Code")
            .AddTextBox("reply", "写补充（可选）", "回复")
            .AddButton(new AppNotificationButton("继续").AddArgument("choice", "继续"))
            .AddButton(new AppNotificationButton("发送").AddArgument("choice", "").SetInputId("reply"))
            .BuildNotification();
        n.Tag = "msg-42";
        n.Group = "agent";
        AppNotificationManager.Default.Show(n);
        Log("已发出测试通知，Id " + n.Id);
    }

    public void OnNotification(IDictionary<string, string> args, IDictionary<string, string> input)
    {
        App.ShowMain();
        args.TryGetValue("choice", out var c);
        args.TryGetValue("msg", out var m);
        input.TryGetValue("reply", out var t);
        Reply.Text = $"收到通知操作：消息 {m}，选项「{c}」，补充「{t}」";
        Log(Reply.Text);
    }
}
