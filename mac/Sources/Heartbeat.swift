import Foundation
import Network

/// 实时接收的长轮询等待时长：按所在网络自适应（服务端 0.6.4 起支持超过 55 秒，见 /v1/info 的 long_poll_max）。
///
/// 等待越久，网络被唤醒的次数越少（手机、笔记本更省电）；但等太久会被运营商 NAT、路由器或反向代理悄悄断开，
/// 消息就要等到发现断开才能收到。做法类似 TCP 的「慢慢加、快速减」：
/// - 从 2 分钟起步；连续 3 轮正常等满就加 1 分钟，最多 10 分钟（且不超过服务端上限）；
/// - 被中途切断（代理超时返回 502/504、连接被关闭）：退到切断点前 15 秒，并把切断点记为上限；
/// - 到点没有任何响应（静默断开）：减半，并把这次的时长记为上限；
/// - 上限 6 小时后失效，重新试探（网络情况会变）；
/// - 请求刚发出 20 秒内就失败（多半是切换网络）、或者耗时远超等待时长（电脑睡眠、App 被挂起）：不算数。
/// Wi-Fi、蜂窝、VPN、有线各记各的。规则和安卓的 Heartbeat.kt 一致（两边的测试用例也一致）。
/// 调用方只在「请求开始时已经知道网络状态、失败时网络没变过」的情况下记录失败（换网络、断网不算这条网络的断开）。
/// Mac 和 iPhone 共用这个文件（内容逐字节相同）。
@MainActor
final class Heartbeat {
    struct State: Codable, Equatable {
        var cur: Int
        var ceil = 0
        var ceilAt: Double = 0
        var streak = 0
    }

    enum Outcome { case ok, failed }

    static let oldServerMax = 55
    /// 旧服务端（上限 55）时沿用的固定等待
    static let legacyWait = 50
    static let minWait = 50
    static let start = 120
    static let step = 60
    static let maxWait = 600
    static let probeStreak = 3
    static let neutralEarly = 20
    static let neutralLate = 90
    static let ceilTTL: Double = 6 * 3600

    static let shared = Heartbeat(
        load: { k in UserDefaults.standard.data(forKey: "hb.\(k)").flatMap { try? JSONDecoder().decode(State.self, from: $0) } },
        save: { k, s in UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: "hb.\(k)") })

    private let load: (String) -> State?
    private let save: (String, State) -> Void
    private let now: () -> Double

    /// 服务端允许的最长等待（旧服务端 55）
    var serverMax = Heartbeat.oldServerMax

    init(load: @escaping (String) -> State?, save: @escaping (String, State) -> Void,
         now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.load = load
        self.save = save
        self.now = now
    }

    private var limit: Int { serverMax <= Self.oldServerMax ? Self.legacyWait : min(serverMax, Self.maxWait) }

    private func state(_ kind: String) -> State {
        let s = load(kind) ?? State(cur: Self.start)
        if s.ceil > 0 && now() - s.ceilAt > Self.ceilTTL { return State(cur: s.cur, streak: s.streak) }
        return s
    }

    /// 这一轮要等多少秒
    func wait(for kind: String) -> Int {
        let lim = limit
        if lim <= Self.legacyWait { return lim }
        return min(max(state(kind).cur, Self.minWait), lim)
    }

    /// 记录一轮结果。wait：这一轮请求的等待秒数；elapsed：从发出到结束（返回或失败）的秒数；
    /// gotData：返回了消息或变更（提前返回，说明不了能等多久）。返回调整后的下一轮等待秒数。
    @discardableResult
    func record(_ kind: String, wait: Int, elapsed: Double, outcome: Outcome, gotData: Bool = false) -> Int {
        let lim = limit
        if lim <= Self.legacyWait { return lim }
        let s = state(kind)
        let e = Int(elapsed)
        var next = s
        switch outcome {
        case .ok:
            if gotData || e < wait - 5 { break }      // 有数据提前返回 / 服务端重启等提前返回：不算数
            let streak = s.streak + 1
            if streak < Self.probeStreak {
                next = State(cur: max(wait, Self.minWait), ceil: s.ceil, ceilAt: s.ceilAt, streak: streak)
            } else {
                var up = min(wait + Self.step, lim)
                if s.ceil > 0 { up = min(up, s.ceil - 30) }
                next = State(cur: max(wait, up, Self.minWait), ceil: s.ceil, ceilAt: s.ceilAt, streak: 0)
            }
        case .failed:
            if e < Self.neutralEarly || e > wait + Self.neutralLate { break }   // 切换网络 / 睡眠挂起：不算数
            if e >= wait - 5 {
                next = State(cur: max(Self.minWait, wait / 2), ceil: wait, ceilAt: now())         // 静默断开
            } else {
                next = State(cur: max(Self.minWait, e - 15), ceil: max(Self.minWait, e), ceilAt: now())   // 被中途切断
            }
        }
        if next != s { save(kind, next) }
        return self.wait(for: kind)
    }

    /// 这种失败是不是「连接被断开」：网络错误、超时，或反向代理 / CDN 因读超时返回的状态码
    /// （408、502、503、504，Cloudflare 的 520–524，例如 100 秒超时返回 524）。服务端自己的错误（500 等）、主动取消不算
    nonisolated static func countsAsDrop(_ e: Error) -> Bool {
        if let a = e as? APIError, case .http(let code, _) = a { return dropStatus(code) }
        if let u = e as? URLError { return u.code != .cancelled && u.code != .notConnectedToInternet }
        return false
    }

    nonisolated static func dropStatus(_ code: Int) -> Bool {
        code == 408 || (502...504).contains(code) || (520...524).contains(code)
    }
}

/// 当前网络的种类（wifi / cell / eth / vpn / other）：不同网络的 NAT 超时差别很大，等待时长分开记。
/// App 启动时就访问一次 shared，让监听尽早拿到第一次网络状态。
final class NetKind: @unchecked Sendable {
    /// kind：网络种类；gen：网络变化代数（每次网络状态更新加一）；ready：已经拿到过网络状态
    struct Snapshot: Equatable {
        let kind: String
        let gen: Int
        let ready: Bool
    }

    static let shared = NetKind()
    private let lock = NSLock()
    private var value = Snapshot(kind: "other", gen: 0, ready: false)
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] p in
            let k = NetKind.kind(of: p)
            guard let self else { return }
            self.lock.lock()
            self.value = Snapshot(kind: k, gen: self.value.gen + 1, ready: true)
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "huijian.netkind"))
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    static func kind(of p: NWPath) -> String {
        if p.usesInterfaceType(.other) { return "vpn" }      // utun 等隧道接口
        if p.usesInterfaceType(.wifi) { return "wifi" }
        if p.usesInterfaceType(.cellular) { return "cell" }
        if p.usesInterfaceType(.wiredEthernet) { return "eth" }
        return "other"
    }
}
