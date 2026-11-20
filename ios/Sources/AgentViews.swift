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

/// 「账户与设备」页里的入口
struct AgentEntrySection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let pending = model.agentSessions.filter(\.pending).count
        let active = model.agentSessions.filter(\.active).count
        Section {
            NavigationLink(value: Route.agent) {
                LabeledContent {
                    Text(pending > 0 ? "\(pending) 个请求" : (active > 0 ? "\(active) 个已登录" : ""))
                        .foregroundStyle(pending > 0 ? Theme.accent : Theme.text3)
                } label: {
                    Label("Agent", systemImage: "terminal")
                }
            }
        } footer: {
            Text("让 Claude Code 等 agent 给你发加密消息、向你提问，你在这里直接回复。")
        }
    }
}

struct AgentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var newKey: Agent.NewKey?
    @State private var keyMsg: String?
    @State private var busy: String?
    @State private var error: String?
    @State private var confirmRevoke: Agent.KeyInfo?
    @State private var confirmEnd: Agent.Session?

    var body: some View {
        List {
            requests
            keySection
            sessionsSection
            Section {
                Text("""
                export HUIJIAN_URL=\(model.settings.server)
                export HUIJIAN_AGENT_KEY=AK_…
                huijian agent login -name "家里 Claude Code"
                claude mcp add huijian -- huijian mcp
                """)
                .font(.caption.monospaced()).foregroundStyle(Theme.text2).textSelection(.enabled)
            } header: {
                Text("用法")
            } footer: {
                Text("MCP 工具：notify（发消息）、ask（提问并等回复）、check_replies（取之后才到的回复）。")
            }
        }
        .navigationTitle("Agent")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            try? await model.refreshAgentKeys()
            await model.refreshAgent()
        }
        .task {
            try? await model.refreshAgentKeys()
            await model.refreshAgent()
        }
        .confirmationDialog("吊销这把 Agent key？", isPresented: Binding(get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } }),
                            titleVisibility: .visible) {
            Button("吊销", role: .destructive) { if let k = confirmRevoke { act("key") { try await model.revokeAgentKey(k.id) } } }
        } message: {
            Text("用它登录的 agent 会话全部结束，之后要用新的 key 重新登录。")
        }
        .confirmationDialog("结束这个 agent 会话？", isPresented: Binding(get: { confirmEnd != nil }, set: { if !$0 { confirmEnd = nil } }),
                            titleVisibility: .visible) {
            Button("结束", role: .destructive) { if let s = confirmEnd { act(s.id) { try await model.endAgentSession(s.id) } } }
        } message: {
            Text("「\(confirmEnd.map(name) ?? "")」不能再发消息、收回复；还没取走的回复一起删除。")
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
                        Button("吊销", role: .destructive) { confirmRevoke = k }.buttonStyle(.bordered).controlSize(.small).disabled(busy != nil)
                    }
                }
            }
        } header: {
            Text("Agent key")
        } footer: {
            Text(keyMsg ?? "agent 用它发起登录，每次登录都要在已解锁的设备上核对批准。key 只显示一次，请放进 agent 所在机器的环境变量 HUIJIAN_AGENT_KEY。")
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
                if !message.choices.isEmpty {
                    // 快捷回复：点一下即发出
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(message.choices, id: \.self) { c in
                                Button(c) { Task { await send(c) } }.buttonStyle(.bordered).disabled(busy)
                            }
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("回复…", text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                    Button(busy ? "发送中…" : "发送") { Task { await send(text) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        return Agent.T.ended
    }

    private func load() async {
        guard message.e2eStatus == "ok" else { return }
        if let r = try? await model.agentReplies(message), r != replies { replies = r }
    }

    private func send(_ t: String) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await model.agentReply(message, text: t)
            if t == text { text = "" }
            await load()
        } catch {
            self.error = describeError(error)
        }
    }
}
