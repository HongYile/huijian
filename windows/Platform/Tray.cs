using System.Runtime.InteropServices;

namespace Huijian;

/// 托盘图标（Shell_NotifyIcon）：左键打开主窗口，右键弹出系统菜单。
/// 用一个隐藏的消息窗口接收托盘消息；资源管理器重启（TaskbarCreated）后自动重新添加。
public sealed partial class Tray : IDisposable
{
    const int WM_APP_TRAY = 0x8000 + 1;
    const int WM_LBUTTONUP = 0x0202, WM_RBUTTONUP = 0x0205, WM_COMMAND = 0x0111, WM_NULL = 0;
    const int NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2;
    const int NIF_MESSAGE = 1, NIF_ICON = 2, NIF_TIP = 4;
    const uint MF_STRING = 0, MF_SEPARATOR = 0x800, MF_GRAYED = 1, MF_CHECKED = 8;
    const uint TPM_RIGHTBUTTON = 2, TPM_RETURNCMD = 0x100, TPM_NONOTIFY = 0x80;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct NOTIFYICONDATA
    {
        public int cbSize; public IntPtr hWnd; public int uID; public int uFlags; public int uCallbackMessage; public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public int dwState; public int dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public int uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public int dwInfoFlags; public Guid guidItem; public IntPtr hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSEX
    {
        public int cbSize; public int style; public IntPtr lpfnWndProc; public int cbClsExtra; public int cbWndExtra;
        public IntPtr hInstance; public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground;
        public string? lpszMenuName; public string lpszClassName; public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

    delegate IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern bool Shell_NotifyIcon(int msg, ref NOTIFYICONDATA data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClassEx(ref WNDCLASSEX c);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowEx(int ex, string cls, string name, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterWindowMessage(string s);
    [DllImport("user32.dll")] static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool AppendMenu(IntPtr m, uint flags, UIntPtr id, string? text);
    [DllImport("user32.dll")] static extern int TrackPopupMenuEx(IntPtr m, uint flags, int x, int y, IntPtr hwnd, IntPtr p);
    [DllImport("user32.dll")] static extern bool DestroyMenu(IntPtr m);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadImage(IntPtr inst, string name, uint type, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string? name);

    public sealed record Item(string Text, Action? Run, bool Checked = false, bool Enabled = true)
    {
        public static readonly Item Separator = new("", null);
    }

    readonly WndProc proc;   // 保持引用，免得被 GC 回收
    readonly IntPtr hwnd;
    readonly uint taskbarCreated;
    IntPtr icon;
    string tip;
    readonly Action onClick;
    readonly Func<IReadOnlyList<Item>> menu;

    public Tray(string iconPath, string tip, Action onClick, Func<IReadOnlyList<Item>> menu)
    {
        this.tip = tip; this.onClick = onClick; this.menu = menu;
        proc = Proc;
        var wc = new WNDCLASSEX
        {
            cbSize = Marshal.SizeOf<WNDCLASSEX>(), lpfnWndProc = Marshal.GetFunctionPointerForDelegate(proc),
            hInstance = GetModuleHandle(null), lpszClassName = "HuijianTrayWindow",
        };
        RegisterClassEx(ref wc);
        hwnd = CreateWindowEx(0, wc.lpszClassName, "回笺托盘", 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
        taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        SetIcon(iconPath);
        Notify(NIM_ADD);
    }

    /// 换图标（例如有未读紧急消息时换成带红点的）
    public void SetIcon(string path)
    {
        var old = icon;
        icon = LoadImage(IntPtr.Zero, path, 1 /*IMAGE_ICON*/, GetSystemMetrics(49 /*SM_CXSMICON*/), GetSystemMetrics(50), 0x10 /*LR_LOADFROMFILE*/);
        if (old != IntPtr.Zero) { Notify(NIM_MODIFY); DestroyIcon(old); }
    }

    public void SetTip(string text) { tip = text; Notify(NIM_MODIFY); }

    void Notify(int op)
    {
        var d = new NOTIFYICONDATA
        {
            cbSize = Marshal.SizeOf<NOTIFYICONDATA>(), hWnd = hwnd, uID = 1, uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP,
            uCallbackMessage = WM_APP_TRAY, hIcon = icon, szTip = tip.Length > 127 ? tip[..127] : tip,
            szInfo = "", szInfoTitle = "",
        };
        Shell_NotifyIcon(op, ref d);
    }

    IntPtr Proc(IntPtr h, uint msg, IntPtr w, IntPtr l)
    {
        if (msg == WM_APP_TRAY)
        {
            switch ((int)l)
            {
                case WM_LBUTTONUP: onClick(); break;
                case WM_RBUTTONUP: ShowMenu(); break;
            }
            return IntPtr.Zero;
        }
        if (msg == taskbarCreated) Notify(NIM_ADD);
        return DefWindowProc(h, msg, w, l);
    }

    void ShowMenu()
    {
        var items = menu();
        var m = CreatePopupMenu();
        for (var i = 0; i < items.Count; i++)
        {
            var it = items[i];
            if (it == Item.Separator) AppendMenu(m, MF_SEPARATOR, UIntPtr.Zero, null);
            else AppendMenu(m, MF_STRING | (it.Checked ? MF_CHECKED : 0) | (it.Enabled ? 0 : MF_GRAYED), (UIntPtr)(i + 1), it.Text);
        }
        GetCursorPos(out var p);
        SetForegroundWindow(hwnd);   // 否则点别处菜单不消失
        var cmd = TrackPopupMenuEx(m, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY, p.X, p.Y, hwnd, IntPtr.Zero);
        PostMessage(hwnd, WM_NULL, IntPtr.Zero, IntPtr.Zero);
        DestroyMenu(m);
        if (cmd > 0 && cmd <= items.Count) items[cmd - 1].Run?.Invoke();
    }

    public void Dispose()
    {
        Notify(NIM_DELETE);
        if (icon != IntPtr.Zero) DestroyIcon(icon);
        DestroyWindow(hwnd);
    }
}
