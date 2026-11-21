import SwiftUI
import UIKit

/// agent 双向（docs/agent-mcp.md §8）：设置 → 账户 →「Agent」页、消息详情里的回复区。逻辑在共用的 Agent.swift

private func describeError(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? e.localizedDescription }

private func agentTime(_ s: String?) -> String {
    guard let s, let d = ISO8601DateFormatter().date(from: s) else { return "—" }
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "MM-dd HH:mm"
    return f.string(from: d)
}

/// Pushkey 页里的 agent 部分（docs/agent-mcp.md §8）：Agent key 和 pushkey 一样是交给程序的钥匙，放在一起。
/// part = .requests：页面最上方的「请求登录的 agent」（有请求时才显示）；part = .main：页面底部的 Agent key、已登录的 agent、用法
struct AgentSections: View {
    enum Part { case requests, main }
    let part: Part
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var newKey: Agent.NewKey?
    @State private var keyMsg: String?
    @State private var busy: String?
    @State private var error: String?
    @State private var confirmRevoke: Agent.KeyInfo?
    @State private var confirmRegen: Agent.KeyInfo?
    @State private var confirmEnd: Agent.Session?

    var body: some View {
        if part == .requests {
            requests
        } else {
            keySection
                .confirmationDialog("吊销这把 Agent key？", isPresented: Binding(get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } }),
                                    titleVisibility: .visible) {
                    Button("吊销", role: .destructive) { if let k = confirmRevoke { act("key") { try await model.revokeAgentKey(k.id) } } }
                } message: {
                    Text("用它登录的 agent 会话全部结束，之后要用新的 key 重新登录。")
                }
                // key 只显示一次、每个账号只能有 1 把：没保存好时用「重新生成」换一把（吊销旧的 + 新建，新 key 显示出来可复制）
                .confirmationDialog("重新生成 Agent key？", isPresented: Binding(get: { confirmRegen != nil }, set: { if !$0 { confirmRegen = nil } }),
                                    titleVisibility: .visible) {
                    Button("重新生成", role: .destructive) {
                        if let k = confirmRegen { act("key") { try await model.revokeAgentKey(k.id); newKey = try await model.createAgentKey() } }
                    }
                } message: {
                    Text("旧 key 立即作废，用它登录的 agent 会话全部结束，要用新 key 重新登录。新 key 只显示一次，记得复制。")
                }
            sessionsSection
                .confirmationDialog("结束这个 agent 会话？", isPresented: Binding(get: { confirmEnd != nil }, set: { if !$0 { confirmEnd = nil } }),
                                    titleVisibility: .visible) {
                    Button("结束", role: .destructive) { if let s = confirmEnd { act(s.id) { try await model.endAgentSession(s.id) } } }
                } message: {
                    Text("「\(confirmEnd.map(name) ?? "")」不能再发消息、收回复；还没取走的回复一起删除。")
                }
            Section {
                Text("""
                export HUIJIAN_URL=\(model.settings.server)
                export HUIJIAN_AGENT_KEY=AK_…
                huijian agent login -name "家里 Claude Code"
                claude mcp add huijian -- huijian mcp
                """)
                .font(.caption.monospaced()).foregroundStyle(Theme.text2).textSelection(.enabled)
            } header: {
                Text("Agent 用法")
            } footer: {
                Text("MCP 工具：notify（发消息）、ask（提问并等回复）、check_replies（取之后才到的回复）。")
            }
        }
    }

    // MARK: 登录请求

    @ViewBuilder private var requests: some View {
        let reqs = model.agentSessions.filter(\.pending)
        let finished = model.agentPhases.keys.filter { id in !reqs.contains { $0.id == id } }.sorted()
        if !reqs.isEmpty || !finished.isEmpty {
            Section {
                ForEach(reqs) { s in requestRow(s) }
                ForEach(finished, id: \.self) { id in finishedRow(id) }
            } header: {
                Text("请求登录的 agent")
            } footer: {
                Text(error ?? "批准前先核对两边的 6 位核对码是否一致；不一致说明可能有人冒充，请拒绝。")
                    .foregroundStyle(error == nil ? Theme.text2 : Theme.danger)
            }
        }
    }

    private func requestRow(_ s: Agent.Session) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "terminal").font(.title3).foregroundStyle(Theme.text2).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name.isEmpty ? "agent" : s.name).font(.body.weight(.medium)).foregroundStyle(Theme.text)
                    Text("请求于 \(agentTime(s.created_at))").font(.caption).foregroundStyle(Theme.text3)
                }
            }
            switch model.agentPhases[s.id] {
            case nil:
                if model.e2eAccountKey == nil {
                    Text("本机还没有解锁加密，不能批准（批准要用账号私钥写会话证明）。").font(.caption).foregroundStyle(Theme.text3)
                }
                HStack(spacing: 10) {
                    Button(busy == s.id ? "处理中…" : "批准") { act(s.id) { try await model.agentBeginApproval(s) } }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(busy != nil || model.e2eAccountKey == nil)
                    Button("拒绝", role: .destructive) { act(s.id) { try await model.agentDeny(s.id) } }
                        .buttonStyle(.bordered).controlSize(.small).disabled(busy != nil)
                }
            case .challenged:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("等待 agent 显示核对码…").font(.subheadline).foregroundStyle(Theme.text3)
                }
                Button("拒绝", role: .destructive) { act(s.id) { try await model.agentDeny(s.id) } }
                    .buttonStyle(.bordered).controlSize(.small).disabled(busy != nil)
            case .code(let c):
                SASCodeView(code: c)
                Text(Agent.T.codeHint(s.name)).font(.subheadline).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("一致，批准") { act(s.id) { try await model.agentApprove(s.id) } }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(busy != nil)
                    Button("不一致，拒绝", role: .destructive) { act(s.id) { try await model.agentDeny(s.id) } }
                        .buttonStyle(.bordered).controlSize(.small).disabled(busy != nil)
                }
            case .failed(let m):
                result(s.id, m, Theme.danger)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }

    private func finishedRow(_ id: String) -> some View {
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

    private func result(_ id: String, _ text: String, _ color: Color) -> some View {
        HStack {
            Text(text).font(.subheadline).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button("关闭") { model.agentForgetApproval(id) }.buttonStyle(.bordered).controlSize(.small)
        }
    }

    // MARK: Agent key

    private var keySection: some View {
        Section {
            if let k = newKey {
                // 只显示一次；App 不在前台时（切换器截图）盖住
                Text(scenePhase == .active ? k.key : String(repeating: "•", count: 20))
                    .font(.callout.monospaced()).textSelection(.enabled)
                Button("复制") {
                    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: k.key]],
                                                  options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(180)])
                    keyMsg = "已复制（3 分钟后自动清除）。"
                }
                Button("我已保存") { newKey = nil; keyMsg = nil }
            } else if model.agentKeys.isEmpty {
                Button(busy == "key" ? "生成中…" : "新建 Agent key") { act("key") { newKey = try await model.createAgentKey() } }
                    .disabled(busy != nil)
            } else {
                ForEach(model.agentKeys) { k in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(k.prefix)…").font(.body.monospaced())
                            Text(k.last_used.map { "上次使用 \(agentTime($0))" } ?? "还没用过").font(.caption).foregroundStyle(Theme.text3)
                        }
                        Spacer()
                        Button(busy == "key" ? "生成中…" : "重新生成") { confirmRegen = k }.buttonStyle(.bordered).controlSize(.small).disabled(busy != nil)
                        Button("吊销", role: .destructive) { confirmRevoke = k }.buttonStyle(.bordered).controlSize(.small).disabled(busy != nil)
                    }
                }
            }
        } header: {
            Text("Agent key（给 agent 用）")
        } footer: {
            Text(keyMsg ?? "agent 用它发起登录，每次登录都要在已解锁的设备上核对批准。key 只显示一次，请放进 agent 所在机器的环境变量 HUIJIAN_AGENT_KEY；没保存好就点「重新生成」。")
        }
    }

    // MARK: 会话

    private var sessionsSection: some View {
        let list = model.agentSessions.filter(\.active)
        return Section {
            ForEach(list) { s in
                HStack(spacing: 10) {
                    Circle().fill(s.online ? Theme.success : Theme.text3.opacity(0.5)).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name(s)).foregroundStyle(Theme.text)
                        Text(s.online ? "在线" : (s.last_seen.map { "上次在线 \(agentTime($0))" } ?? "还没上线")).font(.caption).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    Button(busy == s.id ? "处理中…" : "结束", role: .destructive) { confirmEnd = s }
                        .buttonStyle(.bordered).controlSize(.small).disabled(busy != nil)
                }
            }
        } header: {
            Text("已登录的 agent")
        } footer: {
            Text(list.isEmpty ? "还没有已登录的 agent。" : "最近 90 秒内取过回复的显示为在线；同时在线最多 3 个。")
        }
    }

    /// 名称取自会话证明；核实不了的标出来
    private func name(_ s: Agent.Session) -> String {
        if let v = model.agentVerified[s.id] { return v.name }
        return "\(s.name)（来源无法核实）"
    }

    private func act(_ id: String, _ f: @escaping () async throws -> Void) {
        Task {
            busy = id; error = nil; keyMsg = nil
            defer { busy = nil }
            do { try await f() } catch {
                if id == "key" { keyMsg = describeError(error) } else { self.error = describeError(error) }
            }
        }
    }
}

/// 消息详情下方：已发出的回复和送达状态、快捷回复、回复框（docs/agent-mcp.md §5.1、§8）
struct AgentReplySection: View {
    @EnvironmentObject private var model: AppModel
    let message: Message
    @State private var text = ""
    @State private var choice: String?
    @State private var replies: [Agent.ReplyView] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let canReply = model.agentCanReply(message)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("回复 agent").font(.footnote.weight(.medium)).foregroundStyle(Theme.text2)
                if message.ask && replies.isEmpty { Text(Agent.T.waitingReply).font(.caption).foregroundStyle(Theme.accent) }
            }
            ForEach(replies) { r in
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.text).foregroundStyle(Theme.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(([r.label, r.device] + (r.sentAt.map { [TimeText.full($0)] } ?? [])).filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(r.state == .received ? Theme.success : Theme.text3)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface2))
            }
            if canReply {
                if replies.contains(where: { $0.state == .received }) {
                    Text(Agent.T.tookReply).font(.caption).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
                if !message.choices.isEmpty {
                    // 快捷选项只是选中（再点取消），和补充文字一起点「发送」才发出
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(message.choices, id: \.self) { c in
                                if choice == c {
                                    Button(c) { choice = nil }.buttonStyle(.borderedProminent).disabled(busy)
                                } else {
                                    Button(c) { choice = c }.buttonStyle(.bordered).disabled(busy)
                                }
                            }
                        }
                    }
                    Text(Agent.T.choiceHint).font(.caption).foregroundStyle(Theme.text3)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("回复…", text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                    Button(busy ? "发送中…" : "发送") { Task { await send() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || Agent.composeReply(choice: choice, text: text).isEmpty)
                }
            } else {
                Text(reason).font(.caption).foregroundStyle(Theme.text3)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
        }
        .padding(.top, 10)
        .task(id: "\(message.id)-\(model.agentRevision)") { await load() }
    }

    private var reason: String {
        if message.e2eStatus != "ok" { return message.e2eStatus == "unverified" ? "来源无法核实，不能回复。" : "消息还没解开，不能回复。" }
        if model.e2eAccountKey == nil { return "本机还没有解锁加密，不能回复。" }
        if let sid = message.agentSession, model.agentVerified[sid]?.current == false { return "这个会话是重置加密前批准的，不能再回复。" }
        if message.agentSeq <= 0 { return "这条消息没有序号，不能回复。" }
        return Agent.T.ended
    }

    private func load() async {
        guard message.e2eStatus == "ok" else { return }
        if let r = try? await model.agentReplies(message), r != replies { replies = r }
    }

    private func send() async {
        let sentText = text, sentChoice = choice
        let t = Agent.composeReply(choice: sentChoice, text: sentText)
        guard !t.isEmpty else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await model.agentReply(message, text: t)
            // 发送期间又改过的不清
            if text == sentText { text = "" }
            if choice == sentChoice { choice = nil }
            await load()
        } catch {
            self.error = describeError(error)
        }
    }
}
