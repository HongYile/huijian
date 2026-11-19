import CryptoKit
import Foundation

// 应用内下载新版 IPA，校验后交给 GBox 安装（GBox 软件源刷新不可靠，可能延迟一天以上，所以改成这条主路径）：
//   GET /v1/update/<id>（带登录 token）→ 临时目录 Huijian-<版本>-<build>.ipa → 校验 sha256 → 校验 Ed25519 签名
//   → 系统「打开方式」菜单，用户选 GBox 导入、在 GBox 里重签安装。
// 签名内容和服务端 server/release.go 的 releaseMessage、Mac 端 Updater 完全一致；公钥由 build.sh 写进 Info.plist。
// 校验不通过时报错、删掉文件，不交给任何 App。每次下载用独立的子目录，只删自己的文件；
// 交给 GBox 以后不立刻删（GBox 可能还在拷贝），App 下次启动时整个目录清空。
// 这个文件只用 Foundation / CryptoKit（「打开方式」菜单在 UpdateShare.swift），方便在 Mac 上单独测试校验逻辑。

enum UpdateError: LocalizedError, Equatable {
    case msg(String)
    var errorDescription: String? { if case .msg(let s) = self { return s }; return nil }
}

enum UpdatePackage {
    /// 被签名的内容（与服务端 releaseMessage 完全一致）
    static func message(platform: String, build: Int, version: String, sha256: String, notes: String) -> Data {
        let notesHash = SHA256.hash(data: Data(notes.utf8)).map { String(format: "%02x", $0) }.joined()
        return Data("hongyan-update-v1\n\(platform)\n\(build)\n\(version)\n\(sha256)\n\(notesHash)".utf8)
    }

    /// 下载到这里（tmp/huijian-update/<每次下载一个子目录>），App 启动、退出登录时整个清空
    static var dir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("huijian-update") }

    static func clear() { try? FileManager.default.removeItem(at: dir) }

    /// 这次下载的目标文件：独立子目录，旧下载收尾时删自己的目录，不会误删新下载
    static func newFile(_ u: UpdateInfo) -> URL {
        dir.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(fileName(u))
    }

    /// 删掉一次下载（文件所在的子目录）。只删 huijian-update 下面的子目录
    static func remove(_ file: URL) {
        let sub = file.deletingLastPathComponent().standardizedFileURL
        guard sub.deletingLastPathComponent().path == dir.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: sub)
    }

    /// 文件名 Huijian-<版本>-<build>.ipa（版本号里只留数字、字母、点、横线，防止路径注入）
    static func fileName(_ u: UpdateInfo) -> String {
        let v = String(u.version.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" }.map(Character.init))
        return "Huijian-\(v.isEmpty ? "0" : v)-\(u.build).ipa"
    }

    /// 流式计算文件的 sha256
    static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 防降级：只接受比当前版本新的 build（签名是真的也不行，否则能用旧的、有漏洞的签名包降级）
    static func checkNewer(_ info: UpdateInfo, than current: Int) throws {
        guard info.build > current else {
            throw UpdateError.msg("服务器给的版本（build \(info.build)）不比当前（build \(current)）新，不安装旧版本")
        }
    }

    /// 校验下载好的文件：比当前版本新、sha256 和更新信息一致、签名用内置公钥验证通过。任何一项不通过都抛错
    static func verify(file: URL, info: UpdateInfo, publicKey: String, currentBuild: Int, platform: String = "ios") throws {
        try checkNewer(info, than: currentBuild)
        let want = (info.sha256 ?? "").lowercased()
        guard want.count == 64 else { throw UpdateError.msg("服务器没有给出更新包的 sha256，不能校验") }
        let got = try sha256(of: file)
        guard got == want else { throw UpdateError.msg("更新包校验失败：sha256 不一致（文件可能下载不完整或被篡改）") }
        let pk = publicKey.trimmingCharacters(in: .whitespaces)
        guard !pk.isEmpty else {
            throw UpdateError.msg("这个版本没有内置更新公钥（构建时没有设置 UPDATE_PUBKEY），不能校验签名。请改用 GBox 软件源更新")
        }
        guard let raw = Data(base64Encoded: pk), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            throw UpdateError.msg("内置的更新公钥格式不对，不能校验签名")
        }
        guard let sig = Data(base64Encoded: info.signature ?? ""), sig.count == 64 else {
            throw UpdateError.msg("更新包签名格式不对")
        }
        let msg = message(platform: platform, build: info.build, version: info.version, sha256: got, notes: info.notes ?? "")
        guard key.isValidSignature(sig, for: msg) else {
            throw UpdateError.msg("更新包签名校验失败（不是用发布密钥签的，或者版本信息被改过）")
        }
    }
}

/// 下载状态（设置 →「关于」显示）
enum UpdateDownloadState: Equatable {
    case idle
    case downloading(Double)
    case verifying
    /// 校验通过，等用户在「打开方式」里选 GBox
    case ready(URL)
    /// 已经交出去：viaOpenIn = 从「打开方式」菜单交给了能打开 .ipa 的 App（GBox）；false = 从系统分享面板分享（可能是「存储到文件」等）
    case handedOff(app: String, viaOpenIn: Bool)
    case failed(String)
}

