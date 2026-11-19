import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: Filter = .all
    @State private var topic: String?

    enum Filter: String, CaseIterable {
        case all = "全部", unread = "未读", important = "重要"
    }

    var body: some View {
        // inbox 由模型缓存（消息 / 已读 / 频道变了才重算）；没有筛选时直接用，不再过一遍
        let inbox = model.inbox
        // 账号开启了端到端加密：明文消息标「未加密」（docs/e2ee-client.md §6.3）
        let e2eOn = model.e2eAccountEnabled
        let shown = topic == nil && filter == .all ? inbox : inbox.filter { m in
            (topic == nil || m.topic == topic) && {
                switch filter {
                case .all: return true
                case .unread: return model.isUnread(m)
                case .important: return m.priority >= 4
                }
            }()
        }
        List {
            Section {
                if model.conn == .unauthorized {
                    Banner(text: "登录已失效（设备可能已被移除），请重新登录。本机的消息记录会保留", action: "重新登录", color: Theme.danger) {
                        model.relogin()
                    }
                } else if model.updateAvailable {
                    Banner(text: model.update.map { "回笺 \($0.version) 可以更新了" } ?? "回笺有新版本", action: "查看",
                           color: Theme.accent) { model.settingsAnchor = "about"; model.path = [.settings] }
                }
                // 账号已开启加密、这台设备还没有解锁（T10）：点开进入「端到端加密」页
                if model.e2eLocked && model.conn != .unauthorized { E2ELockedBanner() }
                if shown.isEmpty && !model.loaded {
                    ProgressView("正在加载消息…")
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.top, 40)
                } else if shown.isEmpty {
                    ContentUnavailableView(inbox.isEmpty ? "还没有消息" : "没有符合条件的消息",
                                           systemImage: inbox.isEmpty ? "tray" : "line.3.horizontal.decrease.circle",
                                           description: Text(inbox.isEmpty ? "在「设置」里可以给自己发一条测试推送" : "换一个筛选条件看看"))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .padding(.top, 40)
                }
                ForEach(shown) { m in
                    NavigationLink(value: Route.message(m.id)) {
                        MessageRow(m: m, unread: model.isUnread(m), channel: model.channelName(m.topic), e2eAccount: e2eOn)
                    }
                    .listRowBackground(Theme.bg)
                    .swipeActions(edge: .leading) {
                        if model.isUnread(m) {
                            Button { model.markRead([m.id]) } label: { Label("已读", systemImage: "envelope.open") }.tint(Theme.accent)
                        } else {
                            Button { model.markUnread(m.id) } label: { Label("未读", systemImage: "envelope.badge") }.tint(Theme.accent)
                        }
                    }
                }
            } header: {
                FilterBar(filter: $filter, topic: $topic, topics: topics())
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .refreshable { await model.refresh() }
        .navigationTitle("回笺")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnBadge(conn: model.conn, unread: model.unreadCount)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { model.markAllRead() } label: { Image(systemName: "checkmark.circle") }
                    .accessibilityLabel("全部标为已读")
                    .disabled(model.unreadCount == 0)
                NavigationLink(value: Route.settings) { Image(systemName: "gearshape") }
                    .accessibilityLabel("设置")
            }
        }
    }

    /// 频道：置顶的在前，再按手动顺序，其余按最近活跃（和 Mac 侧栏、设置 →「频道」一致；模型里缓存）
    private func topics() -> [String] {
        var all = model.inboxTopics
        // 选中的频道已经不在列表里（消息被删 / 归档、频道被隐藏）：仍保留它的标签，方便取消筛选
        if let t = topic, !all.contains(t) { all.insert(t, at: 0) }
        return all
    }
}

/// 左上角：连接状态小圆点 + 文字
private struct ConnBadge: View {
    let conn: ConnState
    let unread: Int

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(conn.color).frame(width: 7, height: 7)
            Text(unread > 0 ? "\(unread) 未读" : short).font(.caption).foregroundStyle(Theme.text2)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(conn.text)
    }

    private var short: String {
        switch conn {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .reconnecting: return "重连中"
        case .unauthorized: return "已失效"
        case .paused: return "已暂停"
        case .loggedOut: return "未登录"
        }
    }
}

private struct FilterBar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var filter: HomeView.Filter
    @Binding var topic: String?
    let topics: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .reconnecting = model.conn {
                Text(model.conn.text).font(.caption).foregroundStyle(Theme.danger).lineLimit(1)
                    .padding(.horizontal, 16)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HomeView.Filter.allCases, id: \.self) { f in
                        Chip(text: f.rawValue, selected: filter == f) { filter = f }
                    }
                    if !topics.isEmpty {
                        Divider().frame(height: 18)
                    }
                    ForEach(topics, id: \.self) { t in
                        Chip(text: "# " + model.channelName(t), selected: topic == t) { topic = topic == t ? nil : t }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .textCase(nil)
        .listRowInsets(EdgeInsets())
    }
}

private struct Chip: View {
    let text: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text).font(.subheadline.weight(selected ? .semibold : .regular)).lineLimit(1)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(selected ? Theme.accent : Theme.text2)
    }
}

struct MessageRow: View {
    let m: Message
    let unread: Bool
    let channel: String
    /// 账号开启了端到端加密：明文消息显示「未加密」小徽章
    var e2eAccount = false

    var body: some View {
        let style = PriorityStyle.of(m.priority)
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(unread ? style.color : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if m.isE2E {
                        // 加密消息：标题前一个小锁（只表示内容加密了，不表示来源可信）
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Theme.text3)
                            .accessibilityLabel("端到端加密")
                    }
                    Text(m.title)
                        .font(.body.weight(unread ? .semibold : .regular))
                        .foregroundStyle(m.priority >= 5 ? Theme.danger : Theme.text)
                        .lineLimit(1)
                    if !m.isE2E && e2eAccount {
                        Text("未加密").font(.caption2.weight(.medium)).foregroundStyle(Theme.text3)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.surface2))
                            .fixedSize()
                            .accessibilityLabel(E2E.T.t63)
                    }
                    Spacer(minLength: 4)
                    RelativeTime(date: m.createdAt).font(.caption).foregroundStyle(Theme.text3).fixedSize()
                }
                let preview = PreviewCache.summary(m)
                if !preview.isEmpty {
                    Text(preview).font(.subheadline).foregroundStyle(Theme.text2).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if m.priority >= 4 { PriorityBadge(priority: m.priority) }
                    Text("# " + channel + (m.thread.isEmpty ? "" : " · " + m.thread))
                        .lineLimit(1)
                    if !m.attachments.isEmpty {
                        Label("\(m.attachments.count)", systemImage: "paperclip").labelStyle(.titleAndIcon)
                    }
                    if m.silent { Image(systemName: "bell.slash").accessibilityLabel("静默") }
                }
                .font(.caption)
                .foregroundStyle(Theme.text3)
                .padding(.top, 1)
            }
        }
        .padding(.vertical, 3)
        .opacity(m.priority <= 1 && !unread ? 0.6 : 1)
    }
}

/// 列表里的相对时间（刚刚 / N 分钟前）：每 30 秒只刷新这一小段文字，不让整个首页重算
struct RelativeTime: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            Text(TimeText.relative(date, now: ctx.date))
        }
    }
}

struct Banner: View {
    let text: String
    let action: String
    var color: Color = Theme.accent
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(color)
            Text(text).font(.subheadline).foregroundStyle(Theme.text)
            Spacer(minLength: 4)
            Button(action, action: onTap).buttonStyle(.bordered).controlSize(.small).tint(color)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.1)))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
