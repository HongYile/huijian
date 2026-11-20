import Foundation
import IOKit
import CryptoKit

/// 设备指纹：本机硬件 UUID 加盐后的 SHA-256（不上传硬件 UUID 原值）。
/// 服务端用它识别「同一台设备」：删掉 App 重装、用新的配对码再配对或重新登录时，沿用原来的设备记录，不会在列表里重复。
enum DeviceFingerprint {
    static let value: String = {
        // 加上系统用户名：同一台 Mac 上不同的 macOS 用户算不同的设备，不会互相顶掉凭证
        let raw = (platformUUID() ?? fallbackID()) + ":" + NSUserName()
        // 前缀是改名前定下的内部常量，保持不变：换装「回笺」后登录仍接管原来的设备记录
        let digest = SHA256.hash(data: Data("hongyan-device-v1:\(raw)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }()

    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    /// 取不到硬件 UUID 时（极少见）：生成一个随机 ID 存在偏好里，至少同一个用户账户下稳定
    private static func fallbackID() -> String {
        let k = "huijian.fallbackDeviceID"
        if let v = DemoMode.defaults.string(forKey: k) { return v }   // 演示模式用独立偏好域
        let v = UUID().uuidString
        DemoMode.defaults.set(v, forKey: k)
        return v
    }
}
