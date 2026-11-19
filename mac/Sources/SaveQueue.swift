import Foundation

/// 合并写盘：在后台串行队列上执行，同一个 key（文件）排队中只保留最新的一次。
/// 连续来十次 save()，队列里只有一个任务，执行时写的是最后一次的状态；flush() 等排队中的都写完。
final class CoalescingWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [String: () -> Void] = [:]

    init(label: String) { queue = DispatchQueue(label: label, qos: .utility) }

    /// 替换这个 key 待写的内容；没有排队中的任务时才新排一个
    func submit(key: String, _ work: @escaping () -> Void) {
        lock.lock()
        let queued = pending[key] != nil
        pending[key] = work
        lock.unlock()
        guard !queued else { return }
        queue.async { [self] in
            lock.lock()
            let w = pending.removeValue(forKey: key)
            lock.unlock()
            w?()
        }
    }

    /// 等排队中的写盘做完
    func flush() { queue.sync {} }
}
