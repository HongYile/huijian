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
