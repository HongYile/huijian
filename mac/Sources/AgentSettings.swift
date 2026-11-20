import AppKit
import SwiftUI

/// 设置 → Agent（docs/agent-mcp.md §8）：Agent key、批准 agent 登录、会话列表
struct AgentSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var newKey: Agent.NewKey?
    @State private var keyMsg: String?
    @State private var busy: String?
    @State private var error: String?
    @State private var confirmRevoke: Agent.KeyInfo?
    @State private var confirmEnd: Agent.Session?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.token == nil {
                SettingsCard {
                    SettingsRow(label: "还没有登录", divider: false) {
                        Button("打开回笺登录") { AppDelegate.shared?.showMainWindow(select: nil) }.buttonStyle(SoftButtonStyle())
                    }
                }
            } else if model.support("agent") == .needsServerUpdate {
                ServerTooOld(feature: "agent 双向", since: "0.10.0", alternative: nil)
            } else {
                requests
                keyCard
                sessionsCard
                usageCard
            }
        }
        .task {
            try? await model.refreshAgentKeys()
            await model.refreshAgent()
        }
        .confirmationDialog("吊销这把 Agent key？", isPresented: Binding(get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } })) {
            Button("吊销", role: .destructive) { if let k = confirmRevoke { act("key") { try await model.revokeAgentKey(k.id) } } }
        } message: {
            Text("用它登录的 agent 会话全部结束，之后要用新的 key 重新登录。")
        }
        .confirmationDialog("结束这个 agent 会话？", isPresented: Binding(get: { confirmEnd != nil }, set: { if !$0 { confirmEnd = nil } })) {
            Button("结束", role: .destructive) { if let s = confirmEnd { act(s.id) { try await model.endAgentSession(s.id) } } }
        } message: {
            Text("「\(confirmEnd.map(name) ?? "")」不能再发消息、收回复；还没取走的回复一起删除。")
        }
    }

    // MARK: 登录请求

    @ViewBuilder var requests: some View {
        let reqs = model.agentSessions.filter(\.pending)
        let finished = model.agentPhases.keys.filter { id in !reqs.contains { $0.id == id } }.sorted()
        if !reqs.isEmpty || !finished.isEmpty {
            SettingsCard(title: "请求登录的 agent", footer: error ?? "批准前先核对两边的 6 位核对码是否一致；不一致说明可能有人冒充，请拒绝。") {
                ForEach(Array(reqs.enumerated()), id: \.element.id) { i, s in
                    requestRow(s, last: i == reqs.count - 1 && finished.isEmpty)
                }
                ForEach(finished, id: \.self) { id in
                    finishedRow(id).padding(.vertical, 11)
                }
            }
            .padding(.bottom, 18)
        }
    }

    func requestRow(_ s: Agent.Session, last: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "terminal").font(.system(size: 15)).foregroundStyle(Theme.text2).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name.isEmpty ? "agent" : s.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                    Text("请求于 \(time(s.created_at))").font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
                Spacer()
                if model.agentPhases[s.id] == nil {
                    Button(busy == s.id ? "处理中…" : "批准") { act(s.id) { try await model.agentBeginApproval(s) } }
                        .buttonStyle(SoftButtonStyle()).disabled(busy != nil || model.e2eAccountKey == nil)
                    Button("拒绝") { act(s.id) { try await model.agentDeny(s.id) } }
                        .buttonStyle(SoftButtonStyle(destructive: true)).disabled(busy != nil)
                }
            }
            switch model.agentPhases[s.id] {
            case .challenged:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("等待 agent 显示核对码…").font(.system(size: 12.5)).foregroundStyle(Theme.text3)
                    Spacer()
                    Button("拒绝") { act(s.id) { try await model.agentDeny(s.id) } }
                        .buttonStyle(SoftButtonStyle(destructive: true)).disabled(busy != nil)
                }
                .padding(.leading, 31)
            case .code(let c):
                VStack(alignment: .leading, spacing: 8) {
                    SASCodeView(code: c)
                    Text(Agent.T.codeHint(s.name)).font(.system(size: 13)).foregroundStyle(Theme.text2)
                    HStack(spacing: 8) {
                        Button("一致，批准") { act(s.id) { try await model.agentApprove(s.id) } }
                            .buttonStyle(SoftButtonStyle()).disabled(busy != nil)
                        Button("不一致，拒绝") { act(s.id) { try await model.agentDeny(s.id) } }
                            .buttonStyle(SoftButtonStyle(destructive: true)).disabled(busy != nil)
                    }
                }
                .padding(.leading, 31)
            case .failed(let m):
                result(s.id, m, Theme.danger)
            default:
                EmptyView()
            }
            if model.agentPhases[s.id] == nil, model.e2eAccountKey == nil {
                Text("本机还没有解锁加密，不能批准（批准要用账号私钥写会话证明）。").font(.system(size: 12)).foregroundStyle(Theme.text3).padding(.leading, 31)
            }
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1) } }
    }

    func finishedRow(_ id: String) -> some View {
        let n = model.agentApprovals[id]?.session.name ?? "agent"
        let (text, color): (String, Color) = {
            switch model.agentPhases[id] {
            case .approved: return ("已批准「\(n)」，它现在可以给你发消息、收你的回复", Theme.success)
            case .rejected: return ("已拒绝「\(n)」", Theme.text2)
            case .failed(let m): return ("「\(n)」：\(m)", Theme.danger)
            default: return ("「\(n)」的请求已结束", Theme.text2)
            }
        }()
        return result(id, text, color)
    }

    func result(_ id: String, _ text: String, _ color: Color) -> some View {
        HStack {
            Text(text).font(.system(size: 13)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("关闭") { model.agentForgetApproval(id) }.buttonStyle(SoftButtonStyle())
        }
    }

    // MARK: Agent key

    var keyCard: some View {
        SettingsCard(title: "Agent key", footer: keyMsg ?? "agent 用它发起登录，每次登录都要在已解锁的设备上核对批准。key 只显示一次，请放进 agent 所在机器的环境变量 HUIJIAN_AGENT_KEY。") {
            if let k = newKey {
                VStack(alignment: .leading, spacing: 8) {
                    Text(k.key).font(.system(size: 13.5, design: .monospaced)).foregroundStyle(Theme.text).textSelection(.enabled)
                    HStack(spacing: 8) {
                        Button("复制") { copySecret(k.key) }.buttonStyle(SoftButtonStyle())
                        Button("我已保存") { newKey = nil; keyMsg = nil }.buttonStyle(SoftButtonStyle())
                    }
                }
                .padding(.vertical, 12)
            } else if model.agentKeys.isEmpty {
                SettingsRow(label: "还没有 Agent key", divider: false) {
                    Button(busy == "key" ? "生成中…" : "新建") {
                        act("key") { newKey = try await model.createAgentKey() }
                    }
                    .buttonStyle(SoftButtonStyle()).disabled(busy != nil)
                }
            } else {
                ForEach(model.agentKeys) { k in
                    SettingsRow(label: "\(k.prefix)…", divider: false) {
                        Text(k.last_used.map { "上次使用 \(time($0))" } ?? "还没用过").font(.system(size: 12)).foregroundStyle(Theme.text3)
                        Button("吊销") { confirmRevoke = k }.buttonStyle(SoftButtonStyle(destructive: true)).disabled(busy != nil)
                    }
                }
            }
        }
        .padding(.bottom, 18)
    }

    /// 复制 key：标成敏感内容，3 分钟后剪贴板没被覆盖就清空
    func copySecret(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let mark = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            if pb.changeCount == mark { pb.clearContents() }
        }
        keyMsg = "已复制（3 分钟后自动清除）。"
    }

    // MARK: 会话

    @ViewBuilder var sessionsCard: some View {
        let list = model.agentSessions.filter(\.active)
        SettingsCard(title: "已登录的 agent", footer: list.isEmpty ? "还没有已登录的 agent。" : "最近 90 秒内取过回复的显示为在线；同时在线最多 3 个。") {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                SettingsRow(label: name(s), divider: i < list.count - 1) {
                    Circle().fill(s.online ? Theme.success : Theme.text3.opacity(0.5)).frame(width: 7, height: 7)
                    Text(s.online ? "在线" : (s.last_seen.map { "上次在线 \(time($0))" } ?? "还没上线")).font(.system(size: 12)).foregroundStyle(Theme.text3)
                    Button(busy == s.id ? "处理中…" : "结束") { confirmEnd = s }.buttonStyle(SoftButtonStyle(destructive: true)).disabled(busy != nil)
                }
            }
        }
        .padding(.bottom, 18)
    }

    /// 名称取自会话证明；核实不了的标出来
    func name(_ s: Agent.Session) -> String {
        if let v = model.agentVerified[s.id] { return v.name }
        return "\(s.name)（来源无法核实）"
    }

    var usageCard: some View {
        SettingsCard(title: "用法", footer: "MCP 工具：notify（发消息）、ask（提问并等回复）、check_replies（取之后才到的回复）。") {
            Text("""
            export HUIJIAN_URL=\(model.server)
            export HUIJIAN_AGENT_KEY=AK_…
            huijian agent login -name "家里 Claude Code"
            claude mcp add huijian -- huijian mcp
            """)
            .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.text2).textSelection(.enabled)
            .padding(.vertical, 12)
        }
    }

    func act(_ id: String, _ f: @escaping () async throws -> Void) {
        Task {
            busy = id; error = nil; keyMsg = nil
            defer { busy = nil }
            do { try await f() } catch {
                let m = (error as? LocalizedError)?.errorDescription ?? Updater.describe(error)
                if id == "key" { keyMsg = m } else { self.error = m }
            }
        }
    }

    func time(_ s: String?) -> String {
        guard let s, let d = ISO8601DateFormatter().date(from: s) else { return "—" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "MM-dd HH:mm"
        return f.string(from: d)
    }
}
