import UserNotifications

/// 本地通知。只在没配 Bark 时使用（配了 Bark 后锁屏提醒由 Bark 负责）。规则和安卓端一致：
/// - P5 每条单独通知（时效性中断级别 + 提示音；重签后多半没有 time-sensitive 权限，会降级为普通通知）；
/// - P3 / P4 单独通知最多保留 6 条，再来就撤掉已有的单独通知，合并成一条「N 条新消息」汇总；
///   汇总还在时，新消息继续并入（累加计数）；
/// - 打开某条消息：撤掉它的通知和汇总；全部已读：撤掉所有消息通知和汇总。
/// P4 有提示音，P3 静默横幅；P0–P2 不发通知。
@MainActor
enum Notifier {
    static let messageIDKey = "message_id"
    static let priorityKey = "priority"
    static let countKey = "count"
    static let summaryID = "summary"
    static let maxIndividual = 6

    static func identifier(_ id: Int64) -> String { "msg-\(id)" }

    /// 投递按顺序串行：每一批都要先读出通知中心里还在的通知再决定怎么合并
    private static var chain: Task<Void, Never>?

    struct Plan: Equatable {
        /// 单独发的消息 id
        var post: [Int64] = []
        /// 要撤掉的通知标识
        var remove: [String] = []
        /// 汇总条数，0 表示没有汇总
        var summary = 0
        /// 这一批是否有新消息并入汇总（需要重发汇总）
        var summaryChanged = false
    }

    /// 合并规则（纯函数，自检里测）。existing：通知中心里还在的单独通知（标识, 优先级）；summary：现有汇总的计数
    static func plan(existing: [(id: String, priority: Int)], summary: Int, incoming: [Message]) -> Plan {
        var p = Plan(summary: summary)
        var shown = existing.filter { $0.priority < 5 }.map(\.id)   // 已经在通知中心里的普通单独通知
        var pending: [Int64] = []                                   // 这一批准备单独发的普通消息
        for m in incoming {
            if m.priority >= 5 { p.post.append(m.id); continue }
            if p.summary > 0 { p.summary += 1; p.summaryChanged = true; continue }
            if shown.count + pending.count < maxIndividual { pending.append(m.id); continue }
            // 第 7 条：撤掉已有的单独通知（这一批还没发的就不发了），合并成汇总
            p.remove += shown
            p.summary = shown.count + pending.count + 1
            p.summaryChanged = true
            shown = []
            pending = []
        }
        p.post += pending
        p.post.sort()
        return p
    }

    /// valid：轮到投递时还该不该发（退出登录 / 换账号后返回 false）
    static func post(_ list: [Message], channelName: @escaping (String) -> String, valid: @escaping () -> Bool = { true }) {
        let prev = chain
        chain = Task { @MainActor in
            await prev?.value
            guard valid() else { return }
            await deliver(list, channelName: channelName, valid: valid)
        }
    }

    /// 等排队的投递都完成（自检用）
    static func flush() async { await chain?.value }

    private static func deliver(_ list: [Message], channelName: (String) -> String, valid: () -> Bool) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        guard valid() else { return }
        var existing: [(id: String, priority: Int)] = []
        var summary = 0
        var summaryTitles: [String] = []
        for n in delivered {
            let info = n.request.content.userInfo
            if n.request.identifier == summaryID {
                summary = (info[countKey] as? NSNumber)?.intValue ?? 0
                summaryTitles = n.request.content.body.components(separatedBy: "；")
            } else if n.request.identifier.hasPrefix("msg-") {
                existing.append((n.request.identifier, (info[priorityKey] as? NSNumber)?.intValue ?? 3))
            }
        }
        let p = plan(existing: existing, summary: summary, incoming: list)
        if !p.remove.isEmpty { center.removeDeliveredNotifications(withIdentifiers: p.remove) }
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in p.post {
            guard let m = byID[id] else { continue }
            let c = UNMutableNotificationContent()
            c.title = m.title
            c.subtitle = "# " + channelName(m.topic)
            // 服务端的 preview 保留换行（锁屏通知里比挤成一行好读）
            let body = m.type != "text" && !m.preview.isEmpty ? m.preview : plainSummary(m.desp, type: m.type, limit: 400)
            c.body = body.isEmpty ? (m.attachments.isEmpty ? Priority.label(m.priority) : "附件 \(m.attachments.count) 个") : body
            c.threadIdentifier = m.topic
            c.userInfo = [messageIDKey: NSNumber(value: m.id), priorityKey: NSNumber(value: m.priority)]
            apply(priority: m.priority, to: c)
            try? await center.add(UNNotificationRequest(identifier: identifier(m.id), content: c, trigger: nil))
        }
        if p.summaryChanged {
            let folded = list.filter { $0.priority < 5 && !p.post.contains($0.id) }
            let c = UNMutableNotificationContent()
            c.title = "\(p.summary) 条新消息"
            c.body = Array((summaryTitles + folded.map(\.title)).suffix(3)).joined(separator: "；")
            c.userInfo = [countKey: NSNumber(value: p.summary)]
            apply(priority: folded.map(\.priority).max() ?? 3, to: c)
            try? await center.add(UNNotificationRequest(identifier: summaryID, content: c, trigger: nil))
        }
    }

    private static func apply(priority p: Int, to c: UNMutableNotificationContent) {
        switch p {
        case 5...:
            c.sound = .default
            c.interruptionLevel = .timeSensitive
            c.relevanceScore = 1
        case 4:
            c.sound = .default
            c.interruptionLevel = .active
            c.relevanceScore = 0.7
        default:
            c.sound = nil
            c.interruptionLevel = .active
            c.relevanceScore = 0.4
        }
    }

    /// 打开了某条消息：撤掉它的通知和汇总
    static func opened(_ id: Int64) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier(id), summaryID])
    }

    /// 标为已读（左滑）、在别处删除：只撤这些消息的通知（一次调用）
    static func remove(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids.map(identifier))
    }

    /// 全部已读 / 退出登录 / 开启 Bark：撤掉所有消息通知和汇总
    static func removeAll() {
        let c = UNUserNotificationCenter.current()
        c.removeAllDeliveredNotifications()
        c.removeAllPendingNotificationRequests()
    }

    /// 上次设置的角标数：没变就不再调系统接口
    private static var lastBadge: Int?

    static func setBadge(_ n: Int) {
        guard n != lastBadge else { return }
        lastBadge = n
        UNUserNotificationCenter.current().setBadgeCount(n) { e in
            // 设置失败：忘掉记录，下次照常再设
            if e != nil { Task { @MainActor in if lastBadge == n { lastBadge = nil } } }
        }
    }
}
