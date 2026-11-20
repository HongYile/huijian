import CryptoKit
import Foundation
import Security
import UIKit

/// 设备 token 等敏感信息：钥匙串 + 一份受保护的私有文件（两处同时写）。
/// - 钥匙串用 AfterFirstUnlock：开机解锁过一次之后，锁屏状态下的后台刷新也能读到；
/// - GBox 换证书（Team 变了）重签后，旧的钥匙串项读不到；没有钥匙串权限的描述文件写不进（-34018）。
///   这两种情况都靠私有文件兜底，不会因为重签就掉登录、丢本地数据。
/// 读取顺序：钥匙串 → 私有文件。最近一次钥匙串写入的结果记在 UserDefaults（设置页显示）
enum Keychain {
    static let service = "io.github.hongyile.huijian"
    static var lastStatus: OSStatus { OSStatus(UserDefaults.standard.integer(forKey: "keychainStatus")) }

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        deleteKeychainOnly(account: account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let st = SecItemAdd(q as CFDictionary, nil)
        UserDefaults.standard.set(Int(st), forKey: "keychainStatus")
        let fileOK = FallbackSecret.save(value, account: account)
        return st == errSecSuccess || fileOK
    }

    static func load(account: String) -> String? {
        keychainValue(account: account) ?? FallbackSecret.load(account: account)
    }

    static func keychainValue(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        FallbackSecret.delete(account: account)
        return deleteKeychainOnly(account: account)
    }

    /// 只删钥匙串里的（自检用它模拟「重签后钥匙串读不到」）
    @discardableResult
    static func deleteKeychainOnly(account: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let s = SecItemDelete(q as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }

    /// 实际存放位置（设置页显示）
    static func backend(account: String) -> String {
        if keychainValue(account: account) != nil { return "钥匙串" }
        if FallbackSecret.exists(account: account) {
            return lastStatus == errSecSuccess ? "App 私有文件（钥匙串里的已读不到，可能换了签名证书）" : "App 私有文件（钥匙串不可用：\(lastStatus)）"
        }
        return "无"
    }
}

/// 钥匙串的备份：Application Support/secrets/<account>，文件保护 = 首次解锁后可读，不进 iCloud 备份
enum FallbackSecret {
    private static var dir: URL { AppPaths.supportDir.appendingPathComponent("secrets") }
    private static func file(_ account: String) -> URL { dir.appendingPathComponent(account) }

    static func save(_ value: String, account: String) -> Bool {
        do {
            var d = dir
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            try? d.setResourceValues(rv)
            try Data(value.utf8).write(to: file(account), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }

    static func load(account: String) -> String? {
        (try? Data(contentsOf: file(account))).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func exists(account: String) -> Bool { FileManager.default.fileExists(atPath: file(account).path) }

    static func delete(account: String) { try? FileManager.default.removeItem(at: file(account)) }
}

/// 本地设置（UserDefaults）。消息本身存在 messages.json，token 存 Keychain
struct Settings {
    private let d = UserDefaults.standard

    var server: String {
        get { d.string(forKey: "server") ?? "" }
        nonmutating set { d.set(newValue, forKey: "server") }
    }
    var deviceID: String {
        get { d.string(forKey: "deviceID") ?? "" }
        nonmutating set { d.set(newValue, forKey: "deviceID") }
    }
    var deviceName: String {
        get { d.string(forKey: "deviceName") ?? "" }
        nonmutating set { d.set(newValue, forKey: "deviceName") }
    }
    var username: String {
        get { d.string(forKey: "username") ?? "" }
        nonmutating set { d.set(newValue, forKey: "username") }
    }
    /// 服务端已经扫过的位置（next_since），下次从这里继续拉
    var cursor: Int64 {
        get { Int64(d.integer(forKey: "cursor")) }
        nonmutating set { d.set(Int(newValue), forKey: "cursor") }
    }
    /// 这个账号是否做过首次同步（首次只取最新 50 条且标为已读、不提醒）
    var initialSyncDone: Bool {
        get { d.bool(forKey: "initialSyncDone") }
        nonmutating set { d.set(newValue, forKey: "initialSyncDone") }
    }
    var lastContact: Date? {
        get { d.object(forKey: "lastContact") as? Date }
        nonmutating set { d.set(newValue, forKey: "lastContact") }
    }
    /// 账号已配置 Bark 转发：此时回笺不再发本地通知（锁屏提醒由 Bark 负责，避免重复）。
    /// 记在本地，后台刷新时不用再问服务器
    var barkOn: Bool {
        get { d.bool(forKey: "barkOn") }
        nonmutating set { d.set(newValue, forKey: "barkOn") }
    }
    /// Bark 地址里带着设备 key：和 token 一样存钥匙串 + 受保护文件，不放 UserDefaults（会进备份）
    var barkURL: String {
        get { Keychain.load(account: "bark-url") ?? "" }
        nonmutating set { if newValue.isEmpty { Keychain.delete(account: "bark-url") } else { Keychain.save(newValue, account: "bark-url") } }
    }
    var barkEncrypted: Bool {
        get { d.bool(forKey: "barkEncrypted") }
        nonmutating set { d.set(newValue, forKey: "barkEncrypted") }
    }
    /// 服务端功能清单（/v1/info 的 features id），nil 表示还没拉到
    var serverFeatures: [String]? {
        get { d.stringArray(forKey: "serverFeatures") }
        nonmutating set { d.set(newValue, forKey: "serverFeatures") }
    }
    var serverVersion: String {
        get { d.string(forKey: "serverVersion") ?? "" }
        nonmutating set { d.set(newValue, forKey: "serverVersion") }
    }

    /// 删除 / 归档变更流的游标（nil = 还没对账或游标作废，下一轮先对账）
    var changesCursor: Int64? {
        get { (d.object(forKey: "changesCursor") as? NSNumber)?.int64Value }
        nonmutating set { if let newValue { d.set(NSNumber(value: newValue), forKey: "changesCursor") } else { d.removeObject(forKey: "changesCursor") } }
    }
    /// 上一次对账时服务端的数据纪元（服务端重建 / 从备份恢复后会变）
    var changesEpoch: String? {
        get { d.string(forKey: "changesEpoch") }
        nonmutating set { d.set(newValue, forKey: "changesEpoch") }
    }

    /// 账号 id（GET /v1/me）：端到端加密的钥匙按「服务器 + 账号 id」存，启动时还没请求 /v1/me 也要能先读出钥匙
    var accountID: Int64? {
        get { (d.object(forKey: "accountID") as? NSNumber)?.int64Value }
        nonmutating set { if let newValue { d.set(NSNumber(value: newValue), forKey: "accountID") } else { d.removeObject(forKey: "accountID") } }
    }
    /// 账号开启了端到端加密（上次 GET /v1/e2e 的结果）：离线时明文消息也能标「未加密」
    var e2eEnabled: Bool {
        get { d.bool(forKey: "e2eEnabled") }
        nonmutating set { if newValue { d.set(true, forKey: "e2eEnabled") } else { d.removeObject(forKey: "e2eEnabled") } }
    }
    /// 「仅本机保留」的消息：服务器的「删除明文消息」删掉了（收到 purge 变更），本机保留副本（docs/e2ee-client.md §7.4）。
    /// 对账时不当作「别处删除」；之后的 delete 变更或本机删除照常删（同时移出这个集合）
    var e2ePlainKept: Set<Int64> {
        get { Set((d.array(forKey: "e2ePlainKept") as? [NSNumber])?.map(\.int64Value) ?? []) }
        nonmutating set {
            if newValue.isEmpty { d.removeObject(forKey: "e2ePlainKept") } else { d.set(newValue.map { NSNumber(value: $0) }, forKey: "e2ePlainKept") }
        }
    }
    /// 被服务器补加密、重新拉取时网络出错的消息 id（§11.5）：下次刷新时重试，成功或 404 后移出
    var e2eSealedRetry: Set<Int64> {
        get { Set((d.array(forKey: "e2eSealedRetry") as? [NSNumber])?.map(\.int64Value) ?? []) }
        nonmutating set {
            if newValue.isEmpty { d.removeObject(forKey: "e2eSealedRetry") } else { d.set(newValue.map { NSNumber(value: $0) }, forKey: "e2eSealedRetry") }
        }
    }
    /// 上面每个 id 连续失败的次数（到 5 次丢弃）
    var e2eSealedRetryCounts: [Int64: Int] {
        get {
            let raw = d.dictionary(forKey: "e2eSealedRetryCounts") as? [String: Int] ?? [:]
            return Dictionary(raw.compactMap { k, v in Int64(k).map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
        }
        nonmutating set {
            if newValue.isEmpty { d.removeObject(forKey: "e2eSealedRetryCounts") }
            else { d.set(Dictionary(newValue.map { (String($0.key), $0.value) }, uniquingKeysWith: { a, _ in a }), forKey: "e2eSealedRetryCounts") }
        }
    }
    /// 密码偏弱（docs/e2ee-client.md §11.1 第 5 步）：照样自动开启加密，加密页显示 T24。改密码后按新密码重算
    /// 按账号记（「服务器#账号 id」，见 AppModel.e2eWeakPassword），本机下次输入这个账号的密码时重新计算
    var e2eWeakAccounts: [String] {
        get { d.stringArray(forKey: "e2eWeakAccounts") ?? [] }
        nonmutating set { if newValue.isEmpty { d.removeObject(forKey: "e2eWeakAccounts") } else { d.set(Array(newValue.suffix(20)), forKey: "e2eWeakAccounts") } }
    }
    /// 已经通知过的设备批准请求（T50，同一个请求只通知一次）
    var e2eNotified: [String] {
        get { d.stringArray(forKey: "e2eNotified") ?? [] }
        nonmutating set { d.set(Array(newValue.suffix(50)), forKey: "e2eNotified") }
    }

    var token: String? {
        get { Keychain.load(account: "device-token") }
        nonmutating set {
            if let newValue { Keychain.save(newValue, account: "device-token") } else { Keychain.delete(account: "device-token") }
        }
    }

    /// 退出登录 / 换账号：清掉和账号有关的状态（保留服务器地址和用户名，方便重新登录）
    func resetAccountState() {
        for k in ["cursor", "initialSyncDone", "lastContact", "barkOn", "barkURL", "barkEncrypted", "deviceID", "deviceName",
                  "changesCursor", "changesEpoch", "serverFeatures", "serverVersion", "accountID", "e2eEnabled", "e2ePlainKept", "e2eSealedRetry", "e2eSealedRetryCounts"] {
            d.removeObject(forKey: k)
        }
        Keychain.delete(account: "bark-cipher")
        Keychain.delete(account: "bark-url")
        d.removeObject(forKey: "channels")
    }

    /// 频道设置（显示名、隐藏、置顶）也落盘：后台冷启动时角标、通知副标题要用
    var channels: [ChannelSetting] {
        get { (d.data(forKey: "channels")).flatMap { try? JSONDecoder().decode([ChannelSetting].self, from: $0) } ?? [] }
        nonmutating set { d.set(try? JSONEncoder().encode(newValue), forKey: "channels") }
    }
}

/// Bark 端到端加密的 Key / IV：只存在本机 Keychain（服务端只告诉我们「是否加密」，不回传密钥）
enum BarkCipherStore {
    static func load() -> (key: String, iv: String)? {
        guard let s = Keychain.load(account: "bark-cipher") else { return nil }
        let parts = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    static func save(key: String, iv: String) {
        if key.isEmpty && iv.isEmpty { Keychain.delete(account: "bark-cipher") } else { Keychain.save(key + "\n" + iv, account: "bark-cipher") }
    }

    /// 随机字母数字串（Bark 的 AES256 要 32 位 Key、16 位 IV）。拒绝采样，没有取模偏差
    static func random(_ n: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var out = ""
        while out.count < n {
            var b = [UInt8](repeating: 0, count: 64)
            guard SecRandomCopyBytes(kSecRandomDefault, b.count, &b) == errSecSuccess else { continue }
            for x in b where x < 248 && out.count < n { out.append(alphabet[Int(x) % 62]) }   // 248 = 62 × 4
        }
        return out
    }
}

/// 端到端加密的私钥存钥匙串（E2E.swift 的 E2ESecrets）：仅本机（AfterFirstUnlockThisDeviceOnly），不同步 iCloud，
/// 也不像登录 token 那样写一份私有文件兜底（私钥只放钥匙串）。和设备 token 分开放在 <service>.e2e 下，按名字（含服务器和账号 id）区分账号。
/// 读写失败时抛错：界面当作「未解锁」并在加密页显示原因（重签换了证书后旧的钥匙串项读不到，重新解锁一次即可）
struct KeychainSecrets: E2ESecrets {
    let service: String

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? ""
            return "钥匙串读写失败（\(status)）" + (msg.isEmpty ? "" : "：\(msg)")
        }
    }

    private func base(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: name]
    }

    func read(_ name: String) throws -> Data? {
        var q = base(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess else { throw Failure(status: s) }
        return out as? Data
    }

    func write(_ name: String, _ value: Data) throws {
        let s = SecItemUpdate(base(name) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if s == errSecSuccess { return }
        guard s == errSecItemNotFound else { throw Failure(status: s) }
        var q = base(name)
        q[kSecValueData as String] = value
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false
        let a = SecItemAdd(q as CFDictionary, nil)
        guard a == errSecSuccess else { throw Failure(status: a) }
    }

    func remove(_ name: String) throws {
        let s = SecItemDelete(base(name) as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw Failure(status: s) }
    }
}

/// 本地文件位置
enum AppPaths {
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Huijian")
    }
    static var messagesFile: URL { supportDir.appendingPathComponent("messages.json") }
    static var attDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("att")
    }

    /// 附件在缓存里的位置：att/<附件 id>/<文件名>（文件名去掉路径分隔符和控制字符）
    static func attachmentFile(_ a: Attachment) -> URL {
        var safe = String(a.name.unicodeScalars.map { s -> Character in
            (s == "/" || s == "\\" || s == ":" || s.value < 0x20) ? "_" : Character(s)
        }).trimmingCharacters(in: .whitespaces)
        if safe.isEmpty || safe.allSatisfy({ $0 == "." }) { safe = "file" }
        return attDir.appendingPathComponent(attachmentDirName(a.id)).appendingPathComponent(safe)
    }

    /// 附件目录名：附件 id 里字母数字、_、- 以外的字符换成 _
    static func attachmentDirName(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
    }
}

/// 附件缓存（Caches/att/<附件 id>/<文件名>）的总量控制。只用 FileManager，可以在后台线程调用
enum AttCache {
    /// 打开、显示附件时调用：更新所在目录的修改时间，当作「最近使用」（系统不一定记录访问时间）
    static func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.deletingLastPathComponent().path)
    }

    /// 总量超过 limit 时，按最近使用时间（目录和文件的修改 / 访问时间取最新）从旧到新整个目录删，
    /// 直到不超过 limit；protect 里的目录名不删。返回删掉的目录名
    static func trim(limit: Int64, protect: Set<String>, root: URL = AppPaths.attDir) -> [String] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                      .contentModificationDateKey, .contentAccessDateKey]
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        func info(_ u: URL) -> (size: Int64, used: Date) {
            let v = try? u.resourceValues(forKeys: Set(keys))
            let size = v?.isRegularFile == true ? Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0) : 0
            return (size, max(v?.contentModificationDate ?? .distantPast, v?.contentAccessDate ?? .distantPast))
        }
        var items: [(url: URL, size: Int64, used: Date)] = []
        var total: Int64 = 0
        for e in entries {
            var (size, used) = info(e)
            if (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
               let it = fm.enumerator(at: e, includingPropertiesForKeys: keys) {
                for case let f as URL in it {
                    let x = info(f)
                    size += x.size
                    used = max(used, x.used)
                }
            }
            total += size
            items.append((e, size, used))
        }
        guard total > limit else { return [] }
        var removed: [String] = []
        for it in items.sorted(by: { $0.used < $1.used }) {
            if total <= limit { break }
            let name = it.url.lastPathComponent
            guard !protect.contains(name), (try? fm.removeItem(at: it.url)) != nil else { continue }
            total -= it.size
            removed.append(name)
        }
        return removed
    }
}

struct PersistedState: Codable {
    var messages: [Message] = []
    var read: Set<Int64> = []
}

enum Persistence {
    static let maxKeep = 3000

    static func load() -> PersistedState { (try? loadChecked()) ?? PersistedState() }

    enum LoadError: Error { case corrupt }

    /// 读取消息文件。文件存在却解不开时抛 corrupt（并把坏文件改名留作排查），调用方要清掉游标重新首次同步，
    /// 否则游标之前的消息再也拉不回来
    static func loadChecked(_ url: URL = AppPaths.messagesFile) throws -> PersistedState {
        guard let data = try? Data(contentsOf: url) else { return PersistedState() }
        if let s = try? JSONCoding.decoder.decode(PersistedState.self, from: data) { return s }
        let bad = url.deletingPathExtension().appendingPathExtension("bad.json")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: url, to: bad)
        throw LoadError.corrupt
    }

    /// 原子写入（先写临时文件再改名），只保留最新 maxKeep 条
    static func save(_ s: PersistedState) throws {
        var s = s
        if s.messages.count > maxKeep { s.messages = Array(s.messages.suffix(maxKeep)) }
        let keep = Set(s.messages.map(\.id))
        s.read = s.read.filter { keep.contains($0) }
        var dir = AppPaths.supportDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 消息、凭证备份都在这个目录里：不进 iCloud / 电脑备份（换机后重新登录、重新同步即可）
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)
        let data = try JSONCoding.encoder.encode(s)
        // completeUntilFirstUserAuthentication：锁屏时的后台刷新也能读写
        try data.write(to: AppPaths.messagesFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func clear() {
        try? FileManager.default.removeItem(at: AppPaths.messagesFile)
        try? FileManager.default.removeItem(at: AppPaths.attDir)
    }
}

/// 设备指纹：sha256("hongyan-ios:" + identifierForVendor)。同一台手机重新登录时，服务端沿用原来的设备记录。
/// 前缀是改名前定下的内部常量，保持不变：从「鸿雁」换装「回笺」后登录，仍然接管原来的设备记录（接收规则、Bark 转发都带过来）。
/// identifierForVendor 取不到时（极少见）用一个随机 ID，存在 Keychain 里（卸载重装也不变）
enum DeviceFingerprint {
    @MainActor static var value: String {
        let raw = UIDevice.current.identifierForVendor?.uuidString ?? fallbackID()
        return SHA256.hash(data: Data("hongyan-ios:\(raw)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func fallbackID() -> String {
        if let v = Keychain.load(account: "fallback-device-id") { return v }
        let v = UUID().uuidString
        Keychain.save(v, account: "fallback-device-id")
        return v
    }
}
