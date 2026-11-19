import AppKit
import UniformTypeIdentifiers

/// 客户端配置导出 / 导入：换电脑或重装时，一个 JSON 文件带走所有设置。
/// 不包含设备 token（每台设备单独配对，token 留在钥匙串里），也不包含消息本身。
struct MacConfig: Codable {
    var format = "huijian-mac-config"
    var version: Int? = 1
    var exportedAt: Date? = Date()
    var appVersion: String? = AppInfo.version
    var server: String?
    var notify: NotifyPrefs?
    var retentionHours: Int?
    /// 自动归档天数（0 = 不自动归档）
    var archiveDays: Int?
    var autoDownloadMB: Int?
    var proxy: ProxyConfig?
    /// 附件保存位置；nil = 默认位置
    var attachmentDir: String?
    var launchAtLogin: Bool?
    var autoCheckUpdates: Bool?
}

extension AppModel {
    func exportConfig() -> MacConfig {
        var c = MacConfig()
        c.server = server.isEmpty ? nil : server
        c.notify = prefs
        c.retentionHours = retentionHours
        c.archiveDays = archiveDays
        c.autoDownloadMB = autoDownloadLimitMB
        c.proxy = proxy
        c.attachmentDir = attachmentDirIsDefault ? nil : attachmentDir.path
        c.launchAtLogin = launchAtLogin
        c.autoCheckUpdates = updater.autoCheck
        return c
    }

    /// 应用导入的配置，返回逐项说明。已配对到别的服务器时不改服务器地址（避免断开当前连接）。
    func importConfig(_ c: MacConfig) async -> [String] {
        var out: [String] = []
        if let s = c.server, !s.isEmpty {
            let n = Self.normalizeServer(s)
            if token == nil {
                server = n
                defaults.set(n, forKey: Self.key("server"))
                out.append("服务器地址：\(n)（配对时已预填）")
            } else if n != server {
                out.append("服务器地址未修改：本机已配对到 \(server)，要换服务器请先在「账户」里解除配对")
            }
        }
        // 手工改过的文件可能不完整：数组长度不对、数值越界的项跳过，避免越界崩溃
        if let p = c.notify, p.show.count == 6, p.sound.count == 6, (0...23).contains(p.quietStart), (0...23).contains(p.quietEnd) {
            prefs = p; out.append("通知偏好")
        }
        if let r = c.retentionHours, r == -1 || (1...24 * 365).contains(r) { retentionHours = r; out.append("附件保留时长") }
        if let d = c.archiveDays, AppModel.archiveOptions.contains(d) { archiveDays = d; out.append("自动归档") }
        if let a = c.autoDownloadMB, AutoDownload.options.contains(where: { $0.0 == a }) { autoDownloadLimitMB = a; out.append("自动下载上限") }
        if let p = c.proxy { setProxy(p); out.append("下载代理") }
        if let d = c.attachmentDir {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: d, isDirectory: &isDir), isDir.boolValue {
                out.append("附件保存位置：" + (await setAttachmentDir(URL(fileURLWithPath: d, isDirectory: true), move: false)))
            } else {
                out.append("附件保存位置未修改：\(d) 在这台电脑上不存在（NAS 没有连接？），连接后在「通用」里重新选择")
            }
        } else if !attachmentDirIsDefault {
            out.append("附件保存位置：" + (await setAttachmentDir(nil, move: false)))
        }
        if let l = c.launchAtLogin, l != launchAtLogin {
            if (try? setLaunchAtLogin(l)) != nil { out.append("登录时启动") } else { out.append("登录时启动未修改：请先把回笺拖进「应用程序」") }
        }
        if let u = c.autoCheckUpdates { updater.autoCheck = u; out.append("自动检查更新") }
        return out
    }

    /// 弹出保存面板导出
    func exportConfigWithPanel() -> String? {
        let panel = NSSavePanel()
        panel.title = "导出回笺配置"
        panel.nameFieldStringValue = "回笺配置.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(exportConfig()).write(to: url, options: .atomic)
            return "已导出到 \(url.path)（不含设备凭证）"
        } catch {
            return "导出失败：\(error.localizedDescription)"
        }
    }

    /// 弹出打开面板导入
    func importConfigWithPanel() async -> String? {
        let panel = NSOpenPanel()
        panel.title = "导入回笺配置"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let c = try Self.decodeConfig(try Data(contentsOf: url))
            let items = await importConfig(c)
            return items.isEmpty ? "文件里没有可导入的设置" : "已导入：" + items.joined(separator: "；")
        } catch {
            return "导入失败：\(error.localizedDescription)"
        }
    }

    nonisolated static func decodeConfig(_ data: Data) throws -> MacConfig {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let c = try dec.decode(MacConfig.self, from: data)
        guard c.format == "huijian-mac-config" else { throw APIError.invalid("不是回笺的配置文件") }
        return c
    }

    /// 弹出文件夹选择面板，选择附件保存位置
    func chooseAttachmentDir() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择附件保存位置"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = attachmentDir
        return panel.runModal() == .OK ? panel.url : nil
    }
}
