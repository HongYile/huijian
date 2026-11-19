import Foundation
import Security

/// 只含值类型（消息、id 集合），可以安全地交给后台写盘队列
struct PersistedState: Codable, @unchecked Sendable {
    var messages: [Message] = []
    var read: Set<Int64> = []
    var starred: Set<Int64> = []
}

enum Persistence {
    static func load(_ url: URL) -> PersistedState {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONCoding.decoder.decode(PersistedState.self, from: data) else { return PersistedState() }
        return s
    }

    static func save(_ s: PersistedState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONCoding.encoder.encode(s)
        try data.write(to: url, options: .atomic)
    }
}

/// 设备 token 存 Keychain（通用密码项）。
enum Keychain {
    static let defaultService = "io.github.hongyile.huijian"
    static let account = "device-token"

    static func save(_ token: String, service: String = defaultService) -> Bool {
        delete(service: service)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func load(service: String = defaultService) -> String? {
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
    static func delete(service: String = defaultService) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let s = SecItemDelete(q as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }
}

/// 端到端加密的私钥存钥匙串（E2E.swift 的 E2ESecrets）：仅本机（ThisDeviceOnly），不同步 iCloud。
/// 和设备 token 分开放在 <service>.e2e 下，按名字（含服务器和账号 id）区分账号
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
