# Windows 客户端设计

Windows 客户端和 Mac、iPhone、安卓客户端功能一致，不做简化版。界面用 Windows 原生控件。端到端加密和 Markdown 解析调用共用 Rust 核心，和其他客户端是同一份代码。端到端加密的客户端规格见 [e2ee-client.md](e2ee-client.md)。

## 1. 技术选型

| 项 | 选择 | 说明 |
|:--|:--|:--|
| 界面 | WinUI 3（Windows App SDK 2.7），C#，.NET 10 | 微软当前的原生界面框架：Fluent 风格、Mica 背景、自动跟随深浅色 |
| 共用核心 | `huijian_core.dll`（Rust，`core/`） | 通过 P/Invoke 调用 `hj_call` / `hj_free`，JSON 进 JSON 出，和 `Core.swift`、`Core.kt` 对应 |
| 打包 | 未打包（unpackaged）、自包含 | .NET 运行时和 Windows App SDK 都打进包里，用户不需要另外安装。zip 约 34 MB，解压后约 88 MB |
| 系统要求 | Windows 10 2004（19041）及以上，x64 / ARM64 | |
| 编译 | `dotnet` 命令行 + Rust | 不需要 Visual Studio。核心库用 `x86_64-pc-windows-gnu` 工具链（自带链接器）编译 |

原型的实测数据（Ryzen 7 9800X3D，Windows 11 25H2，Release）：

- 冷启动约 1 秒，热启动约 0.35 秒。
- 工作集 118 MB，专用内存 92 MB。
- Argon2id 54 ms。

不用的方案：

- WPF：控件风格老，深色模式和 Mica 都要自己做。
- Tauri / Electron：界面不原生；Electron 体积和内存都更大。
- MSIX 打包：需要代码签名证书，侧载也麻烦。

### 体积控制

- 只引用用得到的 Windows App SDK 组件：Base、Runtime、Foundation、InteractiveExperiences、WinUI、DWrite。总包 `Microsoft.WindowsAppSDK` 会带上 AI / ML（onnxruntime、DirectML）、搜索和小组件，多出约 60 MB。
- 发布时裁剪（`PublishTrimmed`，`TrimMode=partial`），只保留中英文资源。
- 托盘图标直接调用 `Shell_NotifyIcon`，不引入第三方库。`H.NotifyIcon` 会把旧版 Windows App SDK 1.6 带进来，和 2.7 冲突。
- 必须打开 `EnableMsixTooling`。否则发布目录里没有 `Huijian.pri`（编译好的 XAML），程序一启动就崩溃。

## 2. 和 Mac 版的对应

### 2.1 平台功能

| Mac | Windows |
|:--|:--|
| 菜单栏图标（MenuBarExtra）和未读数 | 托盘图标。未读数画进图标，并显示在提示文字里；有未读 P5 时图标变朱砂色；断线时变淡 |
| 菜单栏面板（最近 6 条、暂停、设置、退出） | 左键打开主窗口；右键弹出菜单：最近消息、暂停通知、设置、退出 |
| 关窗口留在菜单栏 | 关窗口缩到托盘，不退出；隐藏期间释放窗口以节省内存 |
| Keychain（ThisDeviceOnly） | DPAPI（`CurrentUser`）加密后存放在 `%LOCALAPPDATA%\Huijian\secrets\`；只有本机、本用户能解开，不随漫游配置同步 |
| UNUserNotificationCenter | Windows App SDK 的 `AppNotificationManager`（toast）。按 thread 分组（Group / Tag），删除消息时撤掉对应通知 |
| 通知点击打开消息 | 同样支持。另外 agent 提问的通知直接带选项按钮和输入框，可以在通知里回复（Mac 目前没有，之后补齐到各端） |
| SMAppService 登录项 | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，带 `--autostart` 参数；开机自启时只放在托盘，不弹窗口 |
| `huijian://` URL scheme | 注册在 `HKCU\Software\Classes\huijian`；单实例运行，第二个实例把参数转给已经在运行的那个 |
| IOPlatformUUID 指纹 | `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid` + 用户名，前缀 `hongyan-device-v1:` 不变 |
| CGEventSource 空闲时间（在用设备上报） | `GetLastInputInfo` |
| NWPathMonitor（按网络调整长轮询时长） | `NetworkInformation`：区分 Wi-Fi、有线、蜂窝、VPN |
| QuickLook 预览和缩略图 | Shell 缩略图（`IShellItemImageFactory`）；用默认程序打开；「在资源管理器中显示」 |
| NSSavePanel / NSOpenPanel | 系统文件对话框 |
| 敏感剪贴板，3 分钟后清除 | 剪贴板设置 `ExcludeClipboardContentFromMonitorProcessing` / `CanIncludeInClipboardHistory=0`，3 分钟后清除 |
| 应用内更新（Ed25519 + 代码签名 + 替换脚本） | Ed25519 签名校验相同（平台名 `windows`），GitHub 源用 `update-windows.json`；由独立的更新程序等主程序退出后替换文件、重新启动，失败时回滚。没有代码签名证书时不做 Authenticode 校验，只靠 Ed25519 |
| `~/Library/Application Support`、`Caches` | `%APPDATA%\Huijian`（数据、设置）、`%LOCALAPPDATA%\Huijian`（附件缓存、更新包、日志、秘密） |

请求头：`platform: "windows"`、`User-Agent: huijian-windows/<版本>`、`X-Huijian-Client: windows <版本> (<build>)`。

### 2.2 功能清单

以下功能全部和 Mac 版一致（细节见 Mac 源码）。

- **账号**
  - 配对码、带钥匙的配对码、二维码链接、账号登录、注册（邀请码）；新登录协议（Argon2id），密码不出本机。
  - 修改用户名和密码；设备列表；生成配对码（倒计时、使用状态、二维码）；退出登录。
- **加密**
  - 开启、解锁：密码、恢复码、另一台设备批准（6 位核对码）。
  - 批准其他设备；设置和更换恢复码；更换钥匙；重置。
- **消息**
  - 长轮询同步：`since`、`changes_since`、对账，按网络自适应等待时长。
  - 解密和 Markdown 渲染：服务端 doc，加密消息在本机用 `md_build` 生成。
  - 附件下载、校验、解密、缓存和清理；正文内嵌图片；外部图片点按才加载。
  - 线程折叠、搜索、优先级筛选；固定分组：全部、未读、重要、收藏、有附件、归档。
  - 多选归档或删除，清理消息，键盘操作。
- **频道**：置顶、改名、静音、隐藏、拖动排序、删除。
- **通知**
  - P0–P5 各自设置是否弹出、是否响铃。
  - 免打扰时段、临时暂停、「我在用其他设备时本机不响」、静音频道只放行 P5。
  - 一批超过 5 条时合并成一条汇总。
- **Pushkey**：草稿式编辑后同步到服务器；本机接收方式；加密发送密钥。
- **Agent**
  - 登录请求批准（核对码）；回复面板：选项和补充一起发送，显示回执状态。
  - Agent key；连接码；已登录的 agent 列表。
- **设置**：账户、Pushkey、加密、通用（开机启动、更新、自动归档、附件位置和缓存、配置导入导出）、通知、服务器（功能对比）、网络（HTTP / SOCKS5 代理）。

## 3. 代码结构

```
windows/
  Huijian.csproj, app.manifest, App.xaml(.cs)
  Core/        Core.cs（hj_call 封装）、E2E.cs、Agent.cs —— 协议逻辑，对应 Mac 的 Core / E2E / Agent.swift
  Net/         Api.cs（REST）、Sync.cs（长轮询、变更、对账）、Heartbeat.cs、Downloads.cs、Proxy.cs
  Model/       AppModel.cs（状态）、Message.cs、Store.cs（messages.json、设置）、Secrets.cs（DPAPI）
  Platform/    Tray.cs、Notifier.cs、AutoStart.cs、UrlScheme.cs、SingleInstance.cs、Fingerprint.cs、Idle.cs、Updater.cs
  Views/       MainWindow、侧栏、列表、详情、DocView（doc 渲染）、AttachmentCard、ReplyPanel、PairPage、设置各页
  Assets/      图标
  tests/       selftest：在本机起 hub，跑和 Mac selftest 相同的联网用例
```

用词和提示文字照抄 Mac 版。E2E 文案按 e2ee-client.md 的 T 编号保持一致。

## 4. 测试

- `Huijian.exe --selftest`：对照 Mac 的 SelfTest / E2ESelfTest，分离线用例和联网用例（在本机起 `huijian hub`）。覆盖配对、登录、解锁、同步、附件、通知规则、agent 全流程、两台设备互相批准等。
- 和 Mac / iPhone / 安卓互通的实测：同一账号在 Windows 和 Mac 上互相批准；agent 提问在 Windows 通知里回复。
- 在 PC 实机上测（开发版用计划任务启动到桌面会话）。

## 5. 阶段

1. **基础**
   - 登录、配对、注册、加密解锁；消息同步和本地存储。
   - 列表和详情（含 doc 渲染、附件）；托盘；通知（含 agent 快捷回复）；DPAPI 秘密存储。
2. **设置和管理**
   - 全部设置页；Pushkey；频道管理；批准设备和 agent；连接码；清理消息；配置导入导出。
3. **发布**
   - 应用内更新（Ed25519）、开机启动、`huijian://`、单实例；selftest。
   - 发布脚本（zip + `update-windows.json`）；README 和截图。

每个阶段完成后提交并推送，同步更新记录。

## 6. 已知限制

- 没有代码签名证书：第一次运行时 SmartScreen 会提示「未知发布者」，需要点「仍要运行」。应用内更新靠 Ed25519 签名防篡改。
- 编译用 Rust 的 GNU 工具链；以后装了 MSVC Build Tools 也可以换成 MSVC，接口不变。
