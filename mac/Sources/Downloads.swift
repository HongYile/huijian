import Foundation
import CryptoKit

/// 基于 URLSessionDownloadDelegate 的下载器，提供进度回调。
final class DownloadEngine: NSObject, URLSessionDownloadDelegate {
    private struct Pending {
        let dest: URL
        let expected: Int64
        let progress: (Double) -> Void
        let completion: (Result<URL, Error>) -> Void
        var result: Result<URL, Error>?
    }

    private var session: URLSession!
    private var pending: [ObjectIdentifier: Pending] = [:]   // 按任务对象区分：重建会话后不同会话的 taskIdentifier 会重复
    private var tasks: [String: URLSessionTask] = [:]
    private let lock = NSLock()

    let scope: NetScope

    init(scope: NetScope = .server) {
        self.scope = scope
        super.init()
        session = URLSession(configuration: NetSessions.shared.downloadConfiguration(scope), delegate: self, delegateQueue: nil)
    }

    /// 代理设置变化后重建会话；正在进行的下载在旧会话上继续完成
    func reloadProxy() {
        let fresh = URLSession(configuration: NetSessions.shared.downloadConfiguration(scope), delegate: self, delegateQueue: nil)
        lock.lock()
        let old = session
        session = fresh
        lock.unlock()
        old?.finishTasksAndInvalidate()
    }

    /// 下载到 dest（覆盖），返回 dest。
    func download(_ request: URLRequest, expectedSize: Int64, to dest: URL, tag: String = UUID().uuidString,
                  progress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            let task = session.downloadTask(with: request)
            pending[ObjectIdentifier(task)] = Pending(dest: dest, expected: expectedSize, progress: progress,
                                                   completion: { [weak self] r in
                                                       self?.lock.lock(); self?.tasks[tag] = nil; self?.lock.unlock()
                                                       cont.resume(with: r)
                                                   })
            tasks[tag] = task
            lock.unlock()
            task.resume()
        }
    }

    /// 取消下载（回调以 URLError.cancelled 结束）
    func cancel(tag: String) {
        lock.lock()
        let t = tasks[tag]
        lock.unlock()
        t?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let p = pending[ObjectIdentifier(downloadTask)]
        lock.unlock()
        guard let p else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : p.expected
        if total > 0 { p.progress(min(1, Double(totalBytesWritten) / Double(total))) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard var p = pending[ObjectIdentifier(downloadTask)] else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            let body = (try? Data(contentsOf: location)) ?? Data()
            let msg = APIClient.errorMessage(body)
            p.result = .failure(status == 401 ? APIError.unauthorized(msg) : APIError.http(status, msg))
        } else {
            do {
                let fm = FileManager.default
                try? fm.removeItem(at: p.dest)
                try fm.createDirectory(at: p.dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: location, to: p.dest)
                p.result = .success(p.dest)
            } catch {
                p.result = .failure(error)
            }
        }
        pending[ObjectIdentifier(downloadTask)] = p
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let p = pending.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()
        guard let p else { return }
        if let error {
            p.completion(.failure(error))
        } else {
            p.completion(p.result ?? .failure(APIError.invalid("下载结果为空")))
        }
    }
}

func sha256OfFile(_ url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var hasher = SHA256()
    while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// 附件本地保存。
/// 位置默认在 Caches/Huijian/att，可以在设置里改到任意文件夹（例如 NAS）；按下载日期分目录，直接打开就能浏览：
///   <位置>/2026/11/17/loss.png
/// 索引（附件 id → 路径、下载时间）固定存在本机的缓存目录，附件放在 NAS 上时，NAS 暂时断开也不会丢索引。
/// 0.5.0 以前的附件在 <位置>/<att_id>/<文件名>，照常可用。
@MainActor
final class AttachmentCache {
    struct Entry: Codable {
        var path: String
        var downloadedAt: Date
    }

    private(set) var baseDir: URL
    private(set) var index: [String: Entry] = [:]
    private let indexFile: URL

    init(baseDir: URL, indexFile: URL) {
        self.baseDir = baseDir
        self.indexFile = indexFile
        let fm = FileManager.default
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: indexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = baseDir.appendingPathComponent("index.json")   // 旧版本把索引放在附件目录里
        let src = fm.fileExists(atPath: indexFile.path) ? indexFile : legacy
        if let data = try? Data(contentsOf: src),
           let idx = try? JSONCoding.decoder.decode([String: Entry].self, from: data) {
            index = idx
            if src == legacy, save() { try? fm.removeItem(at: legacy) }   // 新索引写成功后才删旧的
        }
    }

    func localURL(_ attID: String) -> URL? {
        guard let e = index[attID], FileManager.default.fileExists(atPath: e.path) else { return nil }
        return URL(fileURLWithPath: e.path)
    }

    static func safeName(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "." || s == ".." { s = "file" }
        if s.hasPrefix(".") { s = "_" + s }   // 不生成隐藏文件
        return s
    }

    /// 新附件的保存路径：<位置>/年/月/日/文件名，重名时加 (2)、(3)…
    /// 同时避开磁盘上已有的文件和索引里登记过的路径（文件可能被手动删了，但索引还指着它）
    func destination(for name: String, date: Date = Date(), in base: URL? = nil) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd"
        return Self.unique(in: (base ?? baseDir).appendingPathComponent(f.string(from: date), isDirectory: true),
                           name: Self.safeName(name), taken: Set(index.values.map(\.path)))
    }

    nonisolated static func unique(in dir: URL, name: String, taken: Set<String>) -> URL {
        var dest = dir.appendingPathComponent(name)
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) || taken.contains(dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            n += 1
        }
        return dest
    }

    func fetch(_ att: Attachment, client: APIClient, engine: DownloadEngine, progress: @escaping (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let tmpDir = baseDir.appendingPathComponent(".downloading", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmp = tmpDir.appendingPathComponent(att.id)
        let req = client.request("/v1/att/\(att.id)")
        _ = try await engine.download(req, expectedSize: att.size, to: tmp, tag: att.id, progress: progress)
        let actual = try sha256OfFile(tmp)
        guard actual == att.sha256 else {
            try? fm.removeItem(at: tmp)
            throw APIError.invalid("校验失败：sha256 不一致")
        }
        if let old = localURL(att.id) { try? fm.removeItem(at: old) }   // 重新下载：替换旧文件
        let dest = destination(for: att.name)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: tmp, to: dest)
        index[att.id] = Entry(path: dest.path, downloadedAt: Date())
        save()
        return dest
    }

    /// 删除下载超过 maxAge 的附件（keep 中的除外），返回被删除的附件 id。maxAge 为 nil 表示永久保留。
    @discardableResult
    func cleanup(now: Date = Date(), keep: Set<String>, maxAge: TimeInterval?) -> [String] {
        guard let maxAge else { return [] }
        let expired = index.filter { !keep.contains($0.key) && now.timeIntervalSince($0.value.downloadedAt) > maxAge }.map(\.key)
        for id in expired { deleteFile(id) }
        if !expired.isEmpty { save() }
        return expired
    }

    func remove(_ attID: String) {
        deleteFile(attID)
        save()
    }

    private func deleteFile(_ attID: String) {
        guard let e = index.removeValue(forKey: attID) else { return }
        // 还有别的附件登记在同一路径（旧索引条目和新文件重名）时不删文件
        if index.values.contains(where: { $0.path == e.path }) { return }
        let url = URL(fileURLWithPath: e.path)
        try? FileManager.default.removeItem(at: url)
        pruneEmptyParents(of: url)
    }

    /// 删掉文件后，向上清理空目录（不超出附件位置）
    private func pruneEmptyParents(of url: URL, base baseURL: URL? = nil) {
        let fm = FileManager.default
        var dir = url.deletingLastPathComponent().standardizedFileURL
        let base = (baseURL ?? baseDir).standardizedFileURL.path
        while dir.path.hasPrefix(base + "/"), dir.path != base {
            let items = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["?"]
            guard items.allSatisfy({ $0 == ".DS_Store" }) else { break }
            try? fm.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }

    /// 两个位置是否其实是同一个目录（解析软链接后比较，例如 /tmp 和 /private/tmp）
    nonisolated static func samePlace(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 更换保存位置。move=true 时把旧位置里的已下载附件搬过去（保持相对路径；目标已有同名文件时加编号，不覆盖），
    /// 文件操作在后台线程进行（搬到 NAS 可能很慢），返回 (搬了几个, 失败几个)。
    func relocate(to newBase: URL, move: Bool, progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }) async -> (moved: Int, failed: Int) {
        let oldBase = baseDir
        baseDir = newBase       // 新下载立即用新位置
        save()
        guard move, !Self.samePlace(oldBase, newBase) else { return (0, 0) }
        let oldPath = oldBase.resolvingSymlinksInPath().standardizedFileURL.path
        let jobs: [(id: String, src: String)] = index.compactMap { id, e in
            let p = URL(fileURLWithPath: e.path).resolvingSymlinksInPath().standardizedFileURL.path
            return p.hasPrefix(oldPath + "/") ? (id, p) : nil
        }
        var taken = Set(index.values.map(\.path))
        var moved = 0, failed = 0
        for (i, job) in jobs.enumerated() {
            let rel = String(job.src.dropFirst(oldPath.count + 1))
            let wanted = newBase.appendingPathComponent(rel)
            let dest = Self.unique(in: wanted.deletingLastPathComponent(), name: wanted.lastPathComponent, taken: taken)
            let ok = await Task.detached(priority: .utility) { () -> Bool in
                let fm = FileManager.default
                guard fm.fileExists(atPath: job.src) else { return false }
                do {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: URL(fileURLWithPath: job.src), to: dest)   // 跨磁盘时 FileManager 会复制后删除
                    return true
                } catch {
                    return false
                }
            }.value
            if ok {
                index[job.id]?.path = dest.path
                taken.insert(dest.path)
                pruneEmptyParents(of: URL(fileURLWithPath: job.src), base: oldBase)
                moved += 1
            } else {
                failed += 1
            }
            progress(i + 1, jobs.count)
        }
        save()
        return (moved, failed)
    }

    /// 仅供自检：修改下载时间
    func setDownloadedAt(_ attID: String, _ date: Date) {
        index[attID]?.downloadedAt = date
        save()
    }

    @discardableResult
    private func save() -> Bool {
        guard let data = try? JSONCoding.encoder.encode(index) else { return false }
        return (try? data.write(to: indexFile, options: .atomic)) != nil
    }
}
