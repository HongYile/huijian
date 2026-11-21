import SwiftUI

/// agent 消息详情下方：快捷回复、回复框、已发出的回复和送达状态（docs/agent-mcp.md §5.1、§8）
struct AgentReplyPanel: View {
    @EnvironmentObject var model: AppModel
    let message: Message
    @State private var text = ""
    @State private var choice: String?
    @State private var replies: [Agent.ReplyView] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let canReply = model.agentCanReply(message)
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "回复 agent", trailing: message.ask && replies.isEmpty ? Agent.T.waitingReply : "")
            if !replies.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(replies) { r in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.text).font(.system(size: 14)).foregroundStyle(Theme.text).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                Text(r.label).foregroundStyle(r.state == .received ? Theme.success : Theme.text3)
                                if !r.device.isEmpty { Text("·"); Text(r.device) }
                                if let d = r.sentAt { Text("·"); Text(TimeFmt.full(d)).monospacedDigit() }
                            }
                            .font(.system(size: Theme.fMeta)).foregroundStyle(Theme.text3)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface2))
                    }
                }
            }
            if canReply {
                if replies.contains(where: { $0.state == .received }) {
                    Text(Agent.T.tookReply).font(.system(size: 12.5)).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !message.choices.isEmpty {
                    // 选项只是选中（再点取消），和补充文字一起点「发送」才发出
                    HStack(spacing: 8) {
                        ForEach(message.choices, id: \.self) { c in
                            Button(c) { choice = choice == c ? nil : c }.buttonStyle(SoftButtonStyle(selected: choice == c)).disabled(busy)
                        }
                    }
                    Text(Agent.T.choiceHint).font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("回复…（⌘↩ 发送）", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .lineLimit(1...8)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    Button(busy ? "发送中…" : "发送") { Task { await send() } }
                        .buttonStyle(SoftButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(busy || Agent.composeReply(choice: choice, text: text).isEmpty)
                }
            } else {
                Text(reason).font(.system(size: 12.5)).foregroundStyle(Theme.text3)
            }
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.danger) }
        }
        .task(id: "\(message.id)-\(model.agentRevision)") { await load() }
    }

    var reason: String {
        if message.e2eStatus != "ok" { return message.e2eStatus == "unverified" ? "来源无法核实，不能回复。" : "消息还没解开，不能回复。" }
        if model.e2eAccountKey == nil { return "本机还没有解锁加密，不能回复。" }
        if let sid = message.agentSession, model.agentVerified[sid]?.current == false { return "这个会话是重置加密前批准的，不能再回复。" }
        if message.agentSeq <= 0 { return "这条消息没有序号，不能回复。" }
        return Agent.T.ended
    }

    func load() async {
        guard message.e2eStatus == "ok" else { return }
        if let r = try? await model.agentReplies(message), r != replies { replies = r }
    }

    func send() async {
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
            self.error = (error as? LocalizedError)?.errorDescription ?? Updater.describe(error)
        }
    }
}
