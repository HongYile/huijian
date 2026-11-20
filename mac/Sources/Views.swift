import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// 布局与样式见 ../DESIGN.md（v2「宣纸与墨」）。所有底色都用 Theme 的暖色，不出现系统默认白底。

let appDisplayName = "回笺"
let settingsWindowTitle = "回笺 账户与设置"
let serverPlaceholder = "https://push.example.com"

// MARK: 主窗口

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            switch model.state {
            case .unpaired, .unauthorized:
                PairView()
            default:
                if model.needsAccountSetup {
                    AccountSetupView()
                } else {
                    mainSplit
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(Theme.bg)
        .tint(Theme.accent)
        .quickLookPreview($model.previewURL)
    }

    var mainSplit: some View {
        Group {
                NavigationSplitView(columnVisibility: $columns) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
                } content: {
                    ThreadListView()
                        .navigationSplitViewColumnWidth(min: 290, ideal: 330, max: 440)
                } detail: {
                    DetailView()
                }
                .searchable(text: $model.searchText, placement: .toolbar, prompt: "搜索标题、正文、附件名")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        PriorityFilterMenu()
                        Button { model.markAllRead() } label: {
                            Label("全部已读", systemImage: "checkmark.circle")
                        }
                        .help("全部标为已读")
                        .disabled(model.visibleUnreadCount == 0)
                        Button { model.openCleanup(topic: model.filter.topicName) } label: {
                            Label("清理消息", systemImage: "trash.slash")
                        }
                        .help("按频道、时间批量删除或归档消息")
                    }
                }
        }
        .alert(model.deleteRequest?.title ?? "", isPresented: Binding(get: { model.deleteRequest != nil },
                                                                     set: { if !$0 { model.deleteRequest = nil } }),
               presenting: model.deleteRequest) { r in
            Button("删除", role: .destructive) {
                Task { if let t = r.topic { await model.deleteChannel(t, ids: r.ids) } else { await model.deleteMessages(r.ids) } }
            }
            Button("取消", role: .cancel) {}
        } message: { r in
            Text(r.detail)
        }
        .alert("操作没有完成", isPresented: Binding(get: { model.manageError != nil }, set: { if !$0 { model.manageError = nil } })) {
            Button("好") {}
        } message: {
            Text(model.manageError ?? "")
        }
        .sheet(isPresented: Binding(get: { model.cleanupRule != nil }, set: { if !$0 { model.cleanupRule = nil } })) {
            CleanupSheet(rule: model.cleanupRule ?? .init())
        }
    }
}

extension Filter {
    var topicName: String? { if case .topic(let t) = self { return t } else { return nil } }
}

struct PriorityFilterMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            Picker("优先级", selection: $model.minPriority) {
                Text("全部级别").tag(Int?.none)
                Divider()
                Text("只看 P5 紧急").tag(Int?.some(5))
                Text("P4 重要及以上").tag(Int?.some(4))
                Text("P3 普通及以上").tag(Int?.some(3))
                Text("P2 低及以上（隐藏日志）").tag(Int?.some(2))
            }
            .pickerStyle(.inline)
        } label: {
            Label("优先级", systemImage: model.minPriority == nil ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .help("按优先级筛选")
    }
}

// MARK: 侧边栏（自绘，避免系统蓝色选中条）

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var showHidden = false
    @State private var renaming: String?
    @State private var confirmResetOrder = false
    @State private var aliasText = ""
    @State private var dragging: String?
    @State private var dropTarget: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                header("收件箱")
                SidebarItem(title: "全部", icon: "tray.full", count: model.count(.all), filter: .all)
                SidebarItem(title: "未读", icon: "circle.inset.filled", count: model.count(.unread), filter: .unread, highlightCount: true)
                SidebarItem(title: "重要", icon: "bell.badge", count: model.count(.important), filter: .important)
                SidebarItem(title: "收藏", icon: "star", count: model.count(.starred), filter: .starred)
                SidebarItem(title: "有附件", icon: "paperclip", count: model.count(.attachments), filter: .attachments)
                SidebarItem(title: "归档", icon: "archivebox", count: model.count(.archived), filter: .archived)
                let topics = model.topics
                if !topics.isEmpty {
                    header("频道").padding(.top, 14)
                    let order = topics.map(\.name)
                    ForEach(topics, id: \.name) { t in
                        channelItem(t.name, count: t.unread, order: order)
                    }
                }
                let hidden = model.hiddenChannels
                if !hidden.isEmpty {
                    Button { withAnimation(.easeOut(duration: 0.15)) { showHidden.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text("已隐藏 \(hidden.count) 个频道")
                            Image(systemName: showHidden ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            Spacer()
                        }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 14)
                    .help("隐藏的频道不进收件箱、不计未读、不提醒；右键可以取消隐藏")
                    if showHidden {
                        ForEach(hidden, id: \.name) { h in
                            SidebarItem(title: model.channelName(h.name), icon: "eye.slash", count: h.total, filter: .topic(h.name), mutedIcon: true)
                                .contextMenu { channelMenu(h.name) }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                UpdateBanner(updater: model.updater)
                AccountFooter()
            }
            .background(Theme.sidebar)
        }
        .task {
            // 截图用：等演示数据和频道设置加载后打开改名弹窗
            if let t = ProcessInfo.processInfo.environment["HUIJIAN_DEMO_RENAME"], model.isDemo {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                aliasText = model.channelName(t)
                renaming = t
            }
        }
        .confirmationDialog("恢复按最近活跃排序？", isPresented: $confirmResetOrder, titleVisibility: .visible) {
            Button("恢复排序") { Task { await model.setChannelOrder([]) } }
        } message: {
            Text("会清掉手动拖出来的频道顺序，所有设备同步（置顶不受影响）。")
        }
        .alert("频道显示名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("显示名", text: $aliasText)
            Button("保存") {
                if let t = renaming { let a = aliasText; Task { await model.updateChannel(t, alias: a) } }
            }
            if let t = renaming, !model.channel(t).alias.isEmpty {
                Button("恢复原名") { Task { await model.updateChannel(t, alias: "") } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只改显示的名字（最多 32 个字），所有设备同步。发送消息时仍用原来的 topic「\(renaming ?? "")」。")
        }
    }

    func channelItem(_ name: String, count: Int, order: [String]) -> some View {
        let c = model.channel(name)
        // 拖动时的落点提示：往下拖排在目标后面（线在下方），往上拖排在前面（线在上方）
        let below = (order.firstIndex(of: dragging ?? "") ?? 0) < (order.firstIndex(of: name) ?? 0)
        return SidebarItem(title: model.channelName(name), icon: c.pinned ? "pin" : "number", count: count, filter: .topic(name),
                           highlightCount: true, mutedIcon: true, muted: c.muted)
            .help(c.alias.isEmpty ? "拖动可以排序，右键可以改名、置顶、静音、隐藏" : "原名（发送时的 topic）：\(name)")
            .overlay(alignment: below ? .bottom : .top) {
                if dropTarget == name, let d = dragging, d != name {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(height: 2).padding(.horizontal, 6)
                }
            }
            .onDrag {
                dragging = name
                return NSItemProvider(object: name as NSString)
            }
            .onDrop(of: [.text], delegate: ChannelDrop(target: name, dragging: $dragging, dropTarget: $dropTarget, model: model))
            .contextMenu { channelMenu(name) }
    }

    @ViewBuilder
    func channelMenu(_ name: String) -> some View {
        let c = model.channel(name)
        if !c.hidden {
            Button(c.pinned ? "取消置顶" : "置顶") { Task { await model.updateChannel(name, pinned: !c.pinned) } }
        }
        Button("重命名…") { aliasText = model.channelName(name); renaming = name }
        Button(c.muted ? "取消静音" : "静音（不弹通知，紧急消息除外）") { Task { await model.updateChannel(name, muted: !c.muted) } }
        Button(c.hidden ? "取消隐藏" : "隐藏频道") {
            Task {
                await model.updateChannel(name, hidden: !c.hidden)
                if c.hidden { showHidden = false }
            }
        }
        if model.hasManualChannelOrder && !c.hidden {
            Button("恢复按最近活跃排序…") { confirmResetOrder = true }
        }
        Divider()
        Button("清理「\(model.channelName(name))」的消息…") { model.openCleanup(topic: name) }
        Button("删除频道…") { model.requestDeleteChannel(name) }
    }

    func header(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
            .padding(.horizontal, 10).padding(.bottom, 4).padding(.top, 4)
    }
}

/// 侧栏频道拖动排序
struct ChannelDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    @Binding var dropTarget: String?
    let model: AppModel

    /// 只在同一组里拖（置顶的和置顶的、其他的和其他的），拖到另一组的结果和落点提示对不上
    private var allowed: Bool {
        guard let d = dragging, d != target, model.topics.contains(where: { $0.name == d }) else { return false }
        return model.channel(d).pinned == model.channel(target).pinned
    }

    func validateDrop(info: DropInfo) -> Bool { allowed }
    func dropEntered(info: DropInfo) { if allowed { dropTarget = target } }
    func dropExited(info: DropInfo) { if dropTarget == target { dropTarget = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: allowed ? .move : .forbidden) }
    func performDrop(info: DropInfo) -> Bool {
        let d = dragging
        dropTarget = nil
        guard let d, allowed, let p = info.itemProviders(for: [.text]).first else { dragging = nil; return false }
        dragging = nil
        let t = target, m = model
        // 拖到侧栏外取消时 dragging 不会被清掉：核对拖进来的内容确实是这个频道，避免别的 App 拖来的文字触发排序
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            let s = obj as? String
            Task { @MainActor in if s == d { await m.moveChannel(d, to: t) } }
        }
        return true
    }
}

struct SidebarItem: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let icon: String
    let count: Int
    let filter: Filter
    var highlightCount = false
    var mutedIcon = false
    /// 频道已静音：标题后显示小铃铛
    var muted = false
    @State private var hover = false

    var body: some View {
        let selected = model.filter == filter
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(selected ? Theme.accent : (mutedIcon ? Theme.text3 : Theme.text2))
                .frame(width: 18)
            Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accent : Theme.text)
                .lineLimit(1)
            if muted {
                Image(systemName: "bell.slash").font(.system(size: 10)).foregroundStyle(Theme.text3).help("已静音")
            }
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)").font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(selected ? Theme.accent : (highlightCount ? Theme.text2 : Theme.text3))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.accentSoft : (hover ? Theme.hover : .clear)))
        .contentShape(Rectangle())
        .onTapGesture { model.filter = filter }
        .onHover { hover = $0 }
    }
}

// MARK: 列表

struct ThreadListView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool
    /// 多选（⌘ 点击逐个选，⇧ 点击连续选）
    @State private var multi: Set<String> = []
    @State private var anchor: String?

    var title: String {
        switch model.filter {
        case .all: return "全部"
        case .unread: return "未读"
        case .important: return "重要"
        case .starred: return "收藏"
        case .attachments: return "有附件"
        case .archived: return "归档"
        case .topic(let t): return "# \(model.channelName(t))"
        }
    }

    func tap(_ g: ThreadGroup, _ groups: [ThreadGroup]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if multi.isEmpty, let cur = model.selectedThread, cur != g.id, groups.contains(where: { $0.id == cur }) { multi.insert(cur) }
            if multi.contains(g.id) { multi.remove(g.id) } else { multi.insert(g.id) }
            anchor = g.id
        } else if flags.contains(.shift), let a = anchor ?? model.selectedThread,
                  let i = groups.firstIndex(where: { $0.id == a }), let j = groups.firstIndex(where: { $0.id == g.id }) {
            multi = Set(groups[min(i, j)...max(i, j)].map(\.id))
        } else {
            multi = []
            anchor = g.id
            model.selectThread(g.id)
        }
        focused = true
    }

    /// 右键菜单 / 删除键作用的会话：点在多选里时作用于全部选中的
    func targets(_ g: ThreadGroup?) -> [String] {
        if let g, !multi.contains(g.id) { return [g.id] }
        if !multi.isEmpty { return Array(multi) }
        return g.map { [$0.id] } ?? model.selectedThread.map { [$0] } ?? []
    }

    var body: some View {
        let groups = model.groups
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(groups) { g in
                        ThreadRow(group: g, selected: multi.isEmpty ? model.selectedThread == g.id : multi.contains(g.id))
                            .id(g.id)
                            .onTapGesture { tap(g, groups) }
                            .contextMenu { rowMenu(g) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(groups, 1, proxy); return .handled }
            .onKeyPress(.upArrow) { move(groups, -1, proxy); return .handled }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                let t = targets(nil)
                guard !t.isEmpty else { return .ignored }
                model.requestDelete(threads: t)
                return .handled
            }
            .onKeyPress(.escape) {
                guard !multi.isEmpty else { return .ignored }
                multi = []
                return .handled
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !multi.isEmpty { selectionBar(groups) }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.e2eNeedsEnable { E2EEnableBanner() } else if model.e2eLocked { E2ELockedBanner() }
                else if model.e2eSuggestRecovery { E2ERecoveryHintBanner() }
            }
            .onChange(of: model.filter) { _, _ in multi = [] }
            // 搜索、筛选、其他设备的操作、自动归档都会让会话从列表里消失：多选只保留还看得见的
            .onChange(of: groups.map(\.id)) { _, ids in
                if !multi.isEmpty { multi.formIntersection(ids) }
            }
            .overlay {
                if groups.isEmpty {
                    if model.messages.isEmpty { FirstRunEmpty() }
                    else if model.filter == .archived && !model.isFiltering(ignoringFilter: true) { ArchiveEmpty() }
                    else { NoMatchEmpty() }
                }
            }
            .onChange(of: model.scrollTarget) { _, target in
                if let target {
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                    model.scrollTarget = nil
                }
            }
            .onAppear {
                if let t = model.scrollTarget { proxy.scrollTo(t, anchor: .center); model.scrollTarget = nil }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(groups.isEmpty ? "" : "\(groups.count) 个会话")
    }

    func move(_ groups: [ThreadGroup], _ d: Int, _ proxy: ScrollViewProxy) {
        guard !groups.isEmpty else { return }
        let idx = groups.firstIndex { $0.id == model.selectedThread } ?? (d > 0 ? -1 : groups.count)
        let n = max(0, min(groups.count - 1, idx + d))
        multi = []
        model.selectThread(groups[n].id)
        proxy.scrollTo(groups[n].id)
    }

    func selectionBar(_ groups: [ThreadGroup]) -> some View {
        let inArchive = model.filter == .archived
        return HStack(spacing: 8) {
            Text("已选 \(multi.count) 个会话").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
            Button("全选") { multi = Set(groups.map(\.id)) }
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.accent)
                .disabled(multi.count == groups.count)
            Spacer(minLength: 4)
            Button(inArchive ? "移回收件箱" : "归档") {
                let t = Array(multi)
                Task { if await model.archiveThreads(t, archive: !inArchive) { multi = [] } }
            }
            .buttonStyle(SoftButtonStyle())
            Button("删除…") { model.requestDelete(threads: Array(multi)) }
                .buttonStyle(SoftButtonStyle())
            Button { multi = [] } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(Theme.text3).help("取消选择（Esc）")
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder
    func rowMenu(_ g: ThreadGroup) -> some View {
        if g.unread > 0 {
            Button("标为已读") { model.markRead(thread: g.id) }
        } else {
            Button("标为未读") { model.markUnread(g.latest.id) }
        }
        Button(model.starred.contains(g.latest.id) ? "取消收藏" : "收藏") { model.toggleStar(g.latest.id) }
        Divider()
        Button("复制标题") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(g.latest.text, forType: .string)
        }
        Button("只看频道 #\(model.channelName(g.latest.topic))") { model.filter = .topic(g.latest.topic) }
        Divider()
        let t = targets(g)
        let fromMulti = multi.contains(g.id)
        let suffix = t.count > 1 ? "（\(t.count) 个会话）" : ""
        if model.archivedThreads.contains(g.id) {
            Button("移回收件箱" + suffix) { Task { if await model.archiveThreads(t, archive: false), fromMulti { multi = [] } } }
        } else {
            Button("归档" + suffix) { Task { if await model.archiveThreads(t, archive: true), fromMulti { multi = [] } } }
        }
        Button((t.count > 1 || g.total > 1 ? "删除会话" : "删除") + suffix + "…") { model.requestDelete(threads: t) }
    }
}

struct ThreadRow: View {
    @EnvironmentObject var model: AppModel
    let group: ThreadGroup
    let selected: Bool
    @State private var hover = false

    var body: some View {
        let m = group.latest
        let style = PriorityStyle.of(group.displayPriority)
        let unread = group.unread > 0
        let summary = messageSummary(m, limit: 90)
        let titleColor: Color = selected ? Theme.accent : (style.level == 5 ? style.color : (style.muted ? Theme.text2 : Theme.text))

        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(style.hasBar ? style.color : .clear)
                .frame(width: 3)
                .padding(.vertical, 7)
            HStack(alignment: .top, spacing: 8) {
                indicator(style).frame(width: 12, height: 16)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if m.isE2E && !m.serverSealed {
                            // 发送端加密的消息：标题前一个小锁（只表示内容加密了，不表示来源可信）。
                            // 服务器代加密的（普通 pushkey 明文发送）不显示小锁，标题后显示「明文发送」（§11.5）
                            Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Theme.text3)
                                .help("端到端加密")
                        }
                        Text(m.text)
                            .font(.system(size: Theme.fRowTitle, weight: unread ? .semibold : .regular))
                            .foregroundStyle(titleColor)
                            .lineLimit(1)
                        if m.serverSealed {
                            Text(E2E.T.plainSentTag).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.text3)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.surface2))
                                .fixedSize()
                                .help(E2E.T.t64)
                        } else if !m.isE2E, model.e2eAccountEnabled {
                            Text("未加密").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.text3)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.surface2))
                                .fixedSize()
                                .help(E2E.T.t63)
                        }
                        Spacer(minLength: 4)
                        Text(TimeFmt.relative(m.createdAt))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(unread ? Theme.text2 : Theme.text3)
                            .fixedSize()
                    }
                    if !summary.isEmpty {
                        Text(summary).font(.system(size: 12.5)).foregroundStyle(Theme.text2).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text("# \(model.channelName(m.topic))").lineLimit(1)
                        if group.isThread {
                            Text("·")
                            Text(m.thread).lineLimit(1).truncationMode(.middle)
                            Text("共 \(group.total) 条").fixedSize()
                        }
                        if group.attachmentCount > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "paperclip")
                                Text("\(group.attachmentCount)")
                            }
                            .fixedSize()
                        }
                        if model.starred.contains(m.id) {
                            Image(systemName: "star.fill").foregroundStyle(Theme.star)
                        }
                        Spacer(minLength: 0)
                        if group.unread > 1 {
                            Text("\(group.unread)")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.surface)
                                .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 15)
                                .background(Capsule().fill(Theme.accent))
                        } else if unread {
                            Circle().fill(Theme.accent).frame(width: 7, height: 7)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                }
            }
            .padding(.leading, 7)
            .padding(.trailing, 10)
            .padding(.vertical, 9)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Theme.accentSoft : (hover ? Theme.hover : .clear))
        )
        .opacity(style.muted && !selected ? 0.75 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    @ViewBuilder
    func indicator(_ s: PriorityStyle) -> some View {
        if s.hasBar {
            Image(systemName: s.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(s.color)
        } else if s.hasDot {
            PriorityDot(priority: s.level, size: 7)
        } else {
            Color.clear
        }
    }
}

// MARK: 空状态

struct FirstRunEmpty: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let base = model.server.isEmpty ? serverPlaceholder : model.server
        let cmd = "curl \"\(base)/message/push?pushkey=PK_xxx&text=hello\""
        VStack(spacing: 12) {
            EmptyMark().frame(width: 44, height: 44)
            Text("还没有消息").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text("在任意机器上执行下面的命令，给自己发第一条：")
                .font(.system(size: 12.5)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
            CopyableCode(text: cmd)
            Text("pushkey 在「设置 → Pushkey」页创建。")
                .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
        }
        .padding(24)
        .frame(maxWidth: 300)
    }
}

struct NoMatchEmpty: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // 在收件箱里搜不到时，看看归档里有没有
        let inArchive = model.filter != .archived && !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? model.archiveMatchCount : 0
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.text3)
            Text("没有符合条件的消息").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            Text(inArchive > 0 ? "归档里有 \(inArchive) 条匹配的消息。" : "换个关键词，或清除筛选条件。")
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
            HStack {
                if inArchive > 0 { Button("在归档中查看") { model.filter = .archived }.controlSize(.small) }
                Button("清除筛选") { model.clearFilters() }.controlSize(.small)
            }
        }
        .padding(24)
    }
}

struct ArchiveEmpty: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "archivebox").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.text3)
            Text("归档里没有消息").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            Text(model.archiveDays > 0
                 ? "超过 \(model.archiveDays) 天的会话会自动移到这里（收藏的除外），也可以在列表里右键「归档」。"
                 : "在列表里右键「归档」的会话会放到这里。自动归档可以在设置里打开。")
                .font(.system(size: 12)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: 300)
    }
}

struct CopyableCode: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                    .foregroundStyle(copied ? Theme.success : Theme.text2)
            }
            .buttonStyle(.plain)
            .help("复制")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface2))
    }
}

struct EmptyDetail: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.text3)
            Text("选择一条消息").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text2)
            Text("用 ↑ ↓ 在列表中切换").font(.system(size: 12)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }
}

// MARK: 详情

struct DetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let key = model.selectedThread {
            let thread = model.threadMessages(key)
            if let focus = thread.first(where: { $0.id == model.focusedMessage }) ?? thread.last {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MessageHeader(message: focus)
                        MessageBody(message: focus, scrollTo: { anchor in withAnimation { proxy.scrollTo(anchor, anchor: .top) } })
                        if !focus.attachments.isEmpty && !focus.e2eUnreadable {
                            SectionTitle(title: "附件", trailing: "\(focus.attachments.count) 个 · \(humanSize(focus.attachments.reduce(0) { $0 + $1.size }))")
                                .padding(.top, 26).padding(.bottom, 12)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 160), spacing: 14, alignment: .leading)],
                                      alignment: .leading, spacing: 14) {
                                ForEach(focus.attachments) { AttachmentCard(att: $0) }
                            }
                        }
                        if thread.count > 1 {
                            ThreadTimeline(thread: thread, focusID: focus.id)
                                .padding(.top, 30)
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 22)
                    .padding(.bottom, 30)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.top)
                .scrollContentBackground(.hidden)
                .background(Theme.surface)
                .task(id: focus.id) {
                    // 演示截图：滚到正文里某种块第一次出现的位置（HUIJIAN_DEMO_SCROLL_BLOCK=progress / image …，锚点见 DocView）
                    if model.isDemo, let t = ProcessInfo.processInfo.environment["HUIJIAN_DEMO_SCROLL_BLOCK"] {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        proxy.scrollTo("md-first-" + t, anchor: .top)
                    }
                }
                }
                .id(focus.id)
            } else {
                EmptyDetail()
            }
        } else {
            EmptyDetail()
        }
    }
}

struct SectionTitle: View {
    let title: String
    var trailing: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
            if !trailing.isEmpty { Text(trailing).font(.system(size: 11.5)).foregroundStyle(Theme.text3) }
            Spacer()
        }
    }
}

struct MessageHeader: View {
    @EnvironmentObject var model: AppModel
    let message: Message

    var body: some View {
        let starred = model.starred.contains(message.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                PriorityBadge(priority: message.priority)
                TopicChip(topic: model.channelName(message.topic))
                    .help(model.channelName(message.topic) == message.topic ? "" : "原名（topic）：\(message.topic)")
                if !message.thread.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5))
                        Text(message.thread).lineLimit(1)
                    }
                    .font(.system(size: Theme.fBadge, weight: .medium))
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
                }
                Spacer()
                Button { model.toggleStar(message.id) } label: {
                    Image(systemName: starred ? "star.fill" : "star")
                        .font(.system(size: 13))
                        .foregroundStyle(starred ? Theme.star : Theme.text3)
                }
                .buttonStyle(.plain)
                .help(starred ? "取消收藏" : "收藏（收藏的附件不会被自动清理）")
                Menu {
                    Button("复制标题和正文") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.desp.isEmpty ? message.text : "\(message.text)\n\n\(message.desp)", forType: .string)
                    }
                    Button("标为未读") { model.markUnread(message.id) }
                    Divider()
                    let key = threadKey(message)
                    let count = model.threadMessages(key).count
                    if model.archivedThreads.contains(key) {
                        Button(count > 1 ? "会话移回收件箱" : "移回收件箱") { Task { await model.archiveThreads([key], archive: false) } }
                    } else {
                        Button(count > 1 ? "归档会话" : "归档") { Task { await model.archiveThreads([key], archive: true) } }
                    }
                    Button("删除这条消息…") { model.requestDelete(message: message.id) }
                    if count > 1 {
                        Button("删除整个会话（\(count) 条）…") { model.requestDelete(threads: [key]) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 13)).foregroundStyle(Theme.text3)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Text(message.text)
                .font(.system(size: Theme.fTitle, weight: .semibold))
                .foregroundStyle(message.priority >= 5 ? PriorityStyle.of(5).color : Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            HStack(spacing: 6) {
                if !message.source.isEmpty {
                    Image(systemName: "paperplane").font(.system(size: 10))
                    Text(message.source)
                    Text("·")
                }
                Text(TimeFmt.full(message.createdAt)).monospacedDigit()
                Text("·")
                Text("#\(message.id)").monospacedDigit()
                if message.serverSealed {
                    Text("·")
                    Text(E2E.T.plainSentTag).help(E2E.T.t64)
                } else if message.isE2E {
                    Text("·")
                    Text("🔒 端到端加密").help("内容在发送端加密，只有你的设备能解开（不表示来源一定可信）")
                } else if model.e2eAccountEnabled {
                    Text("·")
                    Text(E2E.T.t63)
                }
            }
            .font(.system(size: Theme.fMeta))
            .foregroundStyle(Theme.text3)
            .padding(.top, 6)
            if message.serverSealed {
                // §11.5：明文发送的消息在元信息下面显示完整的 T64（各端一致；太长，不挤在同一行里）
                Text(E2E.T.t64)
                    .font(.system(size: Theme.fMeta)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 18).padding(.bottom, 18)
        }
    }
}

struct MessageBody: View {
    @EnvironmentObject var model: AppModel
    let message: Message
    var scrollTo: (String) -> Void = { _ in }
    /// 正文里 huijian://message/<id> 指向本机没有的消息
    @State private var missingLink = false

    var body: some View {
        if message.e2eUnreadable {
            E2ELockedBody(message: message)
        } else if let doc = message.renderDoc {
            // 服务端 0.6.0 起：按解析好的 doc 绘制（表格、提示框、正文里的附件图片……）
            DocView(doc: doc).environment(\.mdActions, actions)
                .alert("消息不存在或已被删除", isPresented: $missingLink) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text("本机没有这条消息（可能已被删除，或者早于本机保存的范围）。")
                }
        } else if !message.desp.isEmpty {
            MarkdownView(source: message.desp, plain: message.type == "text")
        } else if message.attachments.isEmpty {
            Text("没有正文").font(.system(size: 12.5)).foregroundStyle(Theme.text3)
        }
        if message.type == "image", let u = URL(string: message.text), u.scheme?.hasPrefix("http") == true {
            Link(destination: u) { Label("打开图片链接", systemImage: "arrow.up.right.square") }
                .font(.system(size: 12.5)).padding(.top, 8)
        }
    }
}

extension MessageBody {
    /// 正文里的链接、附件、脚注要用的动作
    var actions: MDActions {
        let model = self.model
        let missingLink = $missingLink
        return MDActions(attachments: message.attachments,
                         openMessage: { id in
                             // 本机没有就提示，不单独向服务端请求（docs/markdown.md「客户端绘制要求」）
                             if model.messages.contains(where: { $0.id == id }) { model.select(id) } else { missingLink.wrappedValue = true }
                         },
                         openAttachment: { a in
                             if model.localFiles[a.id] != nil { model.preview(a.id); return }
                             let mid = message.id
                             Task {
                                 // 正在下载（自动下载或附件卡片点的）：等它下完再打开；否则开始下载
                                 if model.progress[a.id] != nil {
                                     while model.progress[a.id] != nil { try? await Task.sleep(nanoseconds: 200_000_000) }
                                 } else {
                                     await model.download(a)
                                 }
                                 // 下完时用户已经切到别的消息：不再弹预览
                                 // （没有 focusedMessage 时详情页显示的是会话最后一条）
                                 let key = threadKey(message)
                                 let showing = model.focusedMessage.map { $0 == mid }
                                     ?? (model.selectedThread == key && model.threadMessages(key).last?.id == mid)
                                 if showing { model.preview(a.id) }
                             }
                         },
                         scrollTo: scrollTo,
                         previewFile: { model.previewURL = $0 })
    }
}

// MARK: 附件卡片

struct AttachmentCard: View {
    @EnvironmentObject var model: AppModel
    let att: Attachment
    @State private var hover = false

    var kind: FileKind { FileKind.of(name: att.name, mime: att.mime) }

    var body: some View {
        let local = model.localFiles[att.id]
        let p = model.progress[att.id]
        let err = model.downloadErrors[att.id]
        VStack(spacing: 0) {
            ZStack {
                Theme.surface2
                if let p {
                    VStack(spacing: 6) {
                        ProgressRing(progress: p).frame(width: 34, height: 34)
                        Text("下载中").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                    }
                } else if local != nil, let thumb = model.thumbnails[att.id] {
                    if kind == .image {
                        Image(nsImage: thumb).resizable().scaledToFill()
                            .frame(width: 160, height: 88).clipped()
                    } else {
                        Image(nsImage: thumb).resizable().scaledToFit()
                            .shadow(color: Color(red: 60 / 255, green: 48 / 255, blue: 30 / 255).opacity(0.15), radius: 1.5, y: 0.5)
                            .padding(.vertical, 8)
                    }
                } else {
                    KindIcon(kind: kind, ext: (att.name as NSString).pathExtension)
                }
                if p != nil {
                    VStack {
                        HStack {
                            Spacer()
                            Button { model.cancelDownload(att.id) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                                    .foregroundStyle(Theme.text3)
                            }
                            .buttonStyle(.plain)
                            .help("取消下载")
                        }
                        Spacer()
                    }
                    .padding(6)
                }
            }
            .frame(width: 160, height: 88)
            .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(att.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    if let err {
                        Text(err).foregroundStyle(Theme.danger).lineLimit(1)
                    } else {
                        Text("\(kind.label) · \(humanSize(att.size))").foregroundStyle(Theme.text3).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    stateGlyph(local: local, p: p, err: err)
                }
                .font(.system(size: 11))
            }
            .padding(.horizontal, 10)
            .frame(width: 160, height: 44, alignment: .leading)
        }
        .frame(width: 160, height: 132)
        .card(radius: 10, lifted: hover)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(hover ? Theme.accent.opacity(0.45) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hover = $0 }
        .onTapGesture { tap() }
        .contextMenu { menu(local) }
        .help(err ?? (local == nil ? "点击下载 \(att.name)" : "点击预览原文件"))
        .animation(.easeOut(duration: 0.15), value: hover)
    }

    @ViewBuilder
    func stateGlyph(local: URL?, p: Double?, err: String?) -> some View {
        if let p {
            Text("\(Int(p * 100))%").font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.accent)
        } else if local != nil {
            Image(systemName: "eye").foregroundStyle(Theme.text3)
        } else if err != nil {
            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(Theme.danger)
        } else {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
        }
    }

    @ViewBuilder
    func menu(_ local: URL?) -> some View {
        if let local {
            Button("QuickLook 预览") { model.preview(att.id) }
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([local]) }
            Button("用默认应用打开") { NSWorkspace.shared.open(local) }
            Button("另存为…") { saveAs(local) }
            Divider()
            Button("删除本地副本") { model.removeLocal(att.id) }
        } else if model.progress[att.id] != nil {
            Button("取消下载") { model.cancelDownload(att.id) }
        } else {
            Button("下载") { tap() }
        }
    }

    func tap() {
        if model.localFiles[att.id] != nil {
            model.preview(att.id)
        } else if model.progress[att.id] == nil {
            Task { await model.download(att) }
        }
    }

    func saveAs(_ src: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = att.name
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let dst = panel.url {
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
    }
}

struct KindIcon: View {
    let kind: FileKind
    var ext: String = ""

    var body: some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 10)
                .fill(kind.color.opacity(0.12))
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: kind.symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(kind.color))
            if !ext.isEmpty {
                Text(ext.uppercased()).font(.system(size: 9.5, weight: .bold)).foregroundStyle(kind.color.opacity(0.85))
            }
        }
    }
}

struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Theme.border, lineWidth: 3)
            Circle().trim(from: 0, to: max(0.02, progress))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: progress)
            Text("\(Int(progress * 100))").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text2)
        }
    }
}

// MARK: 线程时间线

struct ThreadTimeline: View {
    @EnvironmentObject var model: AppModel
    let thread: [Message]
    let focusID: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "线程 · \(thread.first?.thread ?? "")", trailing: "共 \(thread.count) 条")
                .padding(.bottom, 8)
            ForEach(Array(thread.enumerated()), id: \.element.id) { i, m in
                TimelineRow(message: m, first: i == 0, last: i == thread.count - 1, focused: m.id == focusID)
                    .onTapGesture { model.focusedMessage = m.id; model.markRead(m.id) }
            }
        }
    }
}

struct TimelineRow: View {
    let message: Message
    let first: Bool
    let last: Bool
    let focused: Bool
    @State private var hover = false

    var body: some View {
        let s = PriorityStyle.of(message.priority)
        let summary = messageSummary(message, limit: 80)
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Rectangle().fill(first ? .clear : Theme.border).frame(width: 1.5, height: 11)
                Circle().fill(s.color).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
                Rectangle().fill(last ? .clear : Theme.border).frame(width: 1.5).frame(maxHeight: .infinity)
            }
            .frame(width: 12)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.text)
                        .font(.system(size: 13, weight: focused ? .semibold : .regular))
                        .foregroundStyle(focused ? Theme.accent : (s.muted ? Theme.text2 : Theme.text))
                        .lineLimit(1)
                    if !message.attachments.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "paperclip")
                            Text("\(message.attachments.count)")
                        }
                        .font(.system(size: 10.5)).foregroundStyle(Theme.text3).fixedSize()
                    }
                    Spacer(minLength: 6)
                    Text(TimeFmt.compact(message.createdAt)).font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Theme.text3).fixedSize()
                }
                if !summary.isEmpty {
                    Text(summary).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
                }
            }
            .padding(.vertical, 7)
        }
        .padding(.horizontal, 10)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 7).fill(focused ? Theme.accentSoft : (hover ? Theme.hover : .clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: 暖色输入框 / 按钮

struct WarmField: View {
    let placeholder: String
    @Binding var text: String
    var large = false
    var mono = false
    var secure = false

    @FocusState private var focused: Bool

    // macOS 的 TextField prompt 不跟随 multilineTextAlignment 居中，且获得焦点后仍显示，
    // 所以占位文字自己画：与输入文字同字体、同对齐，聚焦或有内容时隐藏。
    var body: some View {
        ZStack {
            if text.isEmpty && !focused {
                Text(placeholder)
                    .font(large ? .system(size: 15, weight: .regular) : .system(size: 14))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, alignment: large ? .center : .leading)
                    .allowsHitTesting(false)
            }
            Group {
                if secure { SecureField("", text: $text) } else { TextField("", text: $text) }
            }
                .textFieldStyle(.plain)
                .focused($focused)
                .font(large ? .system(size: 22, weight: .semibold, design: .monospaced)
                      : .system(size: mono ? 13 : 14, design: mono ? .monospaced : .default))
                .multilineTextAlignment(large ? .center : .leading)
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 10)
        .frame(height: large ? 44 : 34)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(focused ? Theme.accent : Theme.border, lineWidth: focused ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(enabled ? Theme.surface : Theme.text3)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(enabled ? Theme.accent.opacity(configuration.isPressed ? 0.85 : 1) : Theme.surface2))
    }
}

struct SoftButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(!enabled ? Theme.text3 : (destructive ? Theme.danger : Theme.text))
            .padding(.horizontal, 14)
            .frame(minWidth: 44, minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? Theme.border : Theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: 配对

enum PairMode: String, CaseIterable {
    case code = "配对码", login = "账号登录", register = "注册"
}

struct PairView: View {
    @EnvironmentObject var model: AppModel
    @State private var server = ""
    @State private var code = ""
    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var password2 = ""
    @State private var mode: PairMode = .code
    @State private var busy = false
    @State private var error: String?
    @State private var invite = ""
    /// 上次注册结果不确定的「服务器 + 用户名」：同一个再注册被拒（409 / 403）时提示改去登录。
    /// 只在注册 / 登录成功、或改了服务器 / 用户名时清掉；中间的 429、本地校验错误（密码太短、两次不一致）都不清（三端一致）
    @State private var uncertainRegister: String?
    /// 这个服务器的注册方式（/v1/info）："closed" / "invite" / "open"；没取到时 nil，照旧显示注册
    @State private var registerMode: String?
    /// 配对链接里的服务器地址和地址栏不同、又不能直接替换时：等用户确认（§12.5）
    @State private var linkServer: String?

    var subtitle: String {
        switch mode {
        case .code: return "输入已登录设备「账户」页生成的配对码，或粘贴配对链接。用扫码得到的长配对码登录，加密消息直接解锁。"
        case .login: return "用账号的用户名和密码登录，pushkey 和历史消息会自动同步过来。"
        case .register:
            switch registerMode {
            case "closed": return "这个服务器没有开放注册，请联系管理员。"
            case "invite": return "在这个服务器上注册新账号，需要管理员给你的邀请码。"
            case "open": return "在这个服务器上注册新账号。"
            default: return "在这个服务器上注册新账号（需要管理员开放注册）。"
            }
        }
    }

    /// 服务器不开放注册：「注册」页只显示提示，不能提交
    var registerClosed: Bool { mode == .register && registerMode == "closed" }
    var needsInvite: Bool { mode == .register && registerMode == "invite" }

    var canSubmit: Bool {
        switch mode {
        case .code: return parsedCode != nil && linkServer == nil
        case .login: return !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        case .register: return !registerClosed && AppModel.normalizeUsername(username).count >= 2 && AppModel.usernameProblem(username) == nil
            && password.count >= 8 && password == password2 && registerProblem == nil
            && (!needsInvite || !invite.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// 配对码输入框的解析结果（6 位、长配对码、配对链接，docs/e2ee-client.md §12.3）；格式不对时 nil
    var parsedCode: (code: String, secret: String?, server: String?)? {
        code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try? Core.pairParse(code)
    }

    /// 注册时的密码强度（服务器拿不到密码，只能在客户端检查，docs/e2ee-client.md §2.2）
    var registerProblem: String? {
        mode == .register && !password.isEmpty ? Core.passwordProblem(password, username: AppModel.normalizeUsername(username)) : nil
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 68, height: 68)
                Text("连接到回笺").font(.system(size: 21, weight: .semibold)).foregroundStyle(Theme.text).padding(.top, 14)
                Picker("", selection: $mode) {
                    ForEach(PairMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.top, 12)
                .onChange(of: mode) { _, m in
                    error = nil
                    if m == .register { Task { _ = await loadRegisterMode() } }      // 进入注册页时重新取注册方式
                }
                Text(subtitle)
                    .font(.system(size: 12.5)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                if model.state == .unauthorized {
                    Label("此设备已被吊销或凭证失效，请重新配对。", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.danger)
                        .padding(10).frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.danger.opacity(0.1)))
                        .padding(.top, 14)
                }
                VStack(alignment: .leading, spacing: 14) {
                    field("服务器地址") {
                        VStack(alignment: .leading, spacing: 5) {
                            WarmField(placeholder: "例如 1.2.3.4:8790 或 push.example.com", text: $server)
                            if let warn = AppModel.insecureNotice(server) {
                                Label(warn, systemImage: "exclamationmark.shield")
                                    .font(.system(size: 11)).foregroundStyle(Theme.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if mode == .code {
                        field("配对码") {
                            VStack(alignment: .leading, spacing: 5) {
                                WarmField(placeholder: "6 位数字，或粘贴长配对码 / 配对链接", text: $code, large: code.count <= 8)
                                    .onChange(of: code) { _, _ in
                                        // 配对链接里带服务器地址：地址栏空着 / 是默认的时直接填；不同时要用户确认（防钓鱼）
                                        linkServer = nil
                                        guard let sv = parsedCode?.server, AppModel.normalizeServer(sv) != AppModel.normalizeServer(server) else { return }
                                        if E2E.pairServerAutoFill(current: server, link: sv, defaultServer: AppModel.defaultServer) { server = sv } else { linkServer = sv }
                                    }
                                if let sv = linkServer {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Label("这个配对码来自另一台服务器：\(E2E.hostOf(sv))", systemImage: "exclamationmark.triangle.fill")
                                            .font(.system(size: 11.5)).foregroundStyle(Theme.warning)
                                        Text("不是你自己生成的配对码不要用。确认是你自己的服务器后再切换。")
                                            .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                                        Button("改用 \(E2E.hostOf(sv))") { server = sv; linkServer = nil }.buttonStyle(SoftButtonStyle())
                                    }
                                }
                                if let p = parsedCode {
                                    if p.secret != nil {
                                        Label("带钥匙的配对码（服务器 \(E2E.hostOf(p.server ?? server))）：登录后直接解锁加密消息", systemImage: "key.fill")
                                            .font(.system(size: 11.5)).foregroundStyle(Theme.success)
                                    } else {
                                        Text("只输 6 位时，登录后需要输入密码解锁加密消息").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                                    }
                                } else if code.trimmingCharacters(in: .whitespaces).count > 6 {
                                    Text("配对码格式不对").font(.system(size: 11.5)).foregroundStyle(Theme.danger)
                                }
                            }
                        }
                    } else if !registerClosed {
                        if needsInvite {
                            field("邀请码") { WarmField(placeholder: "管理员给你的邀请码", text: $invite) }
                        }
                        field("用户名") {
                            VStack(alignment: .leading, spacing: 5) {
                                WarmField(placeholder: "用户名", text: $username)
                                if mode == .register {
                                    Text(AppModel.usernameProblem(username) ?? AppModel.usernameRule).font(.system(size: 11.5))
                                        .foregroundStyle(AppModel.usernameProblem(username) == nil ? Theme.text3 : Theme.danger)
                                }
                            }
                        }
                        field("密码") {
                            VStack(alignment: .leading, spacing: 5) {
                                WarmField(placeholder: mode == .register ? "至少 10 位，不要用常见密码" : "密码", text: $password, secure: true)
                                if let p = registerProblem {
                                    Text(p).font(.system(size: 11.5)).foregroundStyle(Theme.danger)
                                }
                            }
                        }
                        if mode == .register {
                            field("再输入一次密码") { WarmField(placeholder: "确认密码", text: $password2, secure: true) }
                            if !password2.isEmpty && password != password2 {
                                Text("两次输入的密码不一样").font(.system(size: 11)).foregroundStyle(Theme.danger)
                            }
                        }
                    }
                    field("设备名称") { WarmField(placeholder: "我的 MacBook", text: $name) }
                }
                .padding(.top, 22)
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                }
                Button {
                    Task { await doPair() }
                } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(busy ? "连接中…" : ["配对码": "配对", "账号登录": "登录", "注册": "注册并登录"][mode.rawValue]!)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(busy || !canSubmit)
                .padding(.top, 20)
                Label("设备凭证只保存在本机钥匙串中；同一台 Mac 重新配对或登录不会在设备列表里重复", systemImage: "lock.fill")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 11)).foregroundStyle(Theme.text3).padding(.top, 14)
            }
            .padding(32)
            .frame(width: 400)
            .card(radius: 14, lifted: true)
        }
        .onAppear {
            if server.isEmpty { server = model.server.isEmpty ? AppModel.defaultServer : model.server }
            if name.isEmpty { name = model.deviceName }
            takePairLink()
        }
        .onChange(of: model.pendingPairLink) { _, _ in takePairLink() }
        .onChange(of: server) { _, _ in uncertainRegister = nil }
        .onChange(of: username) { _, _ in uncertainRegister = nil }
        // 服务器地址变了（停止输入 0.5 秒后）：取 /v1/info 看注册方式（不开放 / 要邀请码 / 开放）
        .task(id: server) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            registerMode = nil       // 换了服务器：旧的注册方式作废，取到新的再说
            _ = await loadRegisterMode()
        }
    }

    /// 系统打开的 huijian://pair 链接（扫码、点链接）：切到「配对码」并填好，等用户确认后再点「配对」
    func takePairLink() {
        guard let link = model.pendingPairLink else { return }
        model.pendingPairLink = nil
        mode = .code
        error = nil
        code = link
    }

    func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
            c()
        }
    }

    /// 取一次这个服务器的注册方式（/v1/info）。取到了（包括没有 /v1/info 的旧服务端）返回 true；
    /// 连不上返回 false，registerMode 不动——不猜（三端一致，审查 M1）
    func loadRegisterMode() async -> Bool {
        let s = AppModel.normalizeServer(server)
        guard let url = URL(string: s), url.scheme == "http" || url.scheme == "https", url.host != nil else { return false }
        do {
            registerMode = try await APIClient(server: url, token: nil).info().registerMode
            return true
        } catch APIError.unsupported {
            registerMode = nil
            return true
        } catch {
            return false
        }
    }

    func doPair() async {
        busy = true
        error = nil
        defer { busy = false }
        if mode == .register {
            // 提交前重新取一次注册方式：取不到就不提交；刚变成要邀请码 / 不开放时先让用户看到
            guard await loadRegisterMode() else { error = E2E.T.serverUnreachable; return }
            if registerClosed { error = "这个服务器没有开放注册，请联系管理员。"; return }
            if needsInvite && invite.trimmingCharacters(in: .whitespaces).isEmpty { error = "请填写邀请码"; return }
        }
        do {
            let n = name.isEmpty ? model.deviceName : name
            switch mode {
            case .code:
                guard let p = parsedCode else { error = "配对码格式不对"; return }
                try await model.pair(server: server, code: p.code, secret: p.secret, name: n)
                code = ""
            case .login: try await model.login(server: server, username: username, password: password, name: n, register: false)
            case .register: try await model.login(server: server, username: username, password: password, name: n, register: true,
                                                  inviteCode: needsInvite ? invite : nil)
            }
            password = ""; password2 = ""; invite = ""
            uncertainRegister = nil
        } catch {
            let who = AppModel.normalizeServer(server) + "|" + AppModel.normalizeUsername(username).lowercased()
            if mode == .register, (error as? E2E.Failure)?.kind == .uncertain {
                uncertainRegister = who
            }
            if mode == .register, uncertainRegister == who, let hint = E2E.registerAfterUncertain(error) {
                self.error = hint
            } else {
                self.error = (error as? APIError)?.localizedDescription ?? AppModel.shortError(error)
            }
            // 403（可能是这期间改成了要邀请码 / 不开放）：刷新注册方式，邀请码框该出现就出现
            if mode == .register, (error as? E2E.Failure)?.status == 403 { _ = await loadRegisterMode() }
        }
    }
}

// MARK: 设置（自绘卡片，不用系统 Form 的白色分组底）

enum SettingsTab: String, CaseIterable {
    // 账户第一、Pushkey 第二：最常用的放最前面
    case account, keys, e2e, general, notify, server, network
    var title: String { ["account": "账户", "general": "通用", "notify": "通知", "keys": "Pushkey", "e2e": "加密", "server": "服务器", "network": "网络"][rawValue]! }
    var icon: String { ["account": "person.crop.circle", "general": "gearshape", "notify": "bell.badge", "keys": "key", "e2e": "lock.shield", "server": "server.rack", "network": "network"][rawValue]! }
}

/// 统一的「账户与设置」窗口：左侧边栏（账户在上），右侧内容。点主窗口左下角的头像直接打开「账户」页。
extension Notification.Name {
    /// 设置窗口已打开时切换到指定页（object 是 SettingsTab）
    static let huijianSelectSettingsTab = Notification.Name("huijianSelectSettingsTab")
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State var tab: SettingsTab = .account

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.border).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 28).padding(.top, 44).padding(.bottom, 10)
                ScrollView {
                    Group {
                        switch tab {
                        case .account: AccountView()
                        case .general: GeneralSettings()
                        case .notify: NotifySettings()
                        case .network: NetworkSettings()
                        case .keys: KeysSettings()
                        case .e2e: E2ESettings()
                        case .server: ServerSettings()
                        }
                    }
                    .frame(maxWidth: 700, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollContentBackground(.hidden)
                .id(tab)   // 切换页面时回到顶部
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(edges: .top)   // 侧边栏和内容一直延伸到标题栏（红绿灯）区域
        .onReceive(NotificationCenter.default.publisher(for: .huijianSelectSettingsTab)) { n in
            if let t = n.object as? SettingsTab { tab = t }
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Theme.bg)
        .tint(Theme.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Avatar(name: model.accountName, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.token == nil ? "未登录" : (model.accountName.isEmpty ? "账户" : model.accountName))
                        .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    HStack(spacing: 5) {
                        StatusDot(state: model.state)
                        Text(model.serverHost).font(.system(size: 11)).foregroundStyle(Theme.text3)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.top, 46).padding(.bottom, 14)
            ForEach(SettingsTab.allCases, id: \.self) { t in
                SidebarTabButton(tab: t, selected: tab == t) { tab = t }
            }
            Spacer()
            if model.token != nil {
                Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 6)
                SidebarActionButton(title: "退出登录…", icon: "rectangle.portrait.and.arrow.right", destructive: true) {
                    AccountMenu.confirmLogout(model)
                }
            }
        }
        .padding(10)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }
}

private struct SidebarTabButton: View {
    let tab: SettingsTab
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: tab.icon).font(.system(size: 14)).frame(width: 20)
                Text(tab.title).font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Theme.accent : Theme.text)
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.accentSoft : (hover ? Theme.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct SidebarActionButton: View {
    let title: String
    let icon: String
    var destructive = false
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 20)
                Text(title).font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(!enabled ? Theme.text3 : (destructive ? Theme.danger : Theme.text2))
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(hover && enabled ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct SettingsCard<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2).padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .padding(.horizontal, 16)
                .card(radius: 10)
            if let footer {
                Text(footer).font(.system(size: 12.5)).foregroundStyle(Theme.text3).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 18)
    }
}

struct SettingsRow<Trailing: View>: View {
    let label: String
    var divider = true
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(label).font(.system(size: 14)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                trailing
            }
            .padding(.vertical, 6)
            .frame(minHeight: 48)
            if divider { Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1) }
        }
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var loginError: String?
    @State private var tick = 0
    @State private var attMsg: String?
    @State private var cfgMsg: String?
    @State private var pendingDir: URL?
    @State private var askMove = false

    var body: some View {
        let usage = model.cacheUsage
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(footer: loginError) {
                SettingsRow(label: "登录时启动回笺", divider: false) {
                    Toggle("", isOn: Binding(get: { _ = tick; return model.launchAtLogin }, set: { on in
                        do { try model.setLaunchAtLogin(on); loginError = nil } catch {
                            loginError = "无法设置：\(error.localizedDescription)。请先把回笺拖进「应用程序」再试。"
                        }
                        tick += 1
                    }))
                    .toggleStyle(.switch).labelsHidden()
                }
            }
            UpdateSettingsCard(updater: model.updater)
            SettingsCard(title: "消息", footer: "超过设定天数的会话移到「归档」，收藏的不会自动归档；归档里的消息可以搜索、移回收件箱或删除。删除是从账号删除，所有设备上都会消失。要批量删除，在主窗口工具栏点「清理消息」。") {
                SettingsRow(label: "自动归档", divider: false) {
                    Picker("", selection: $model.archiveDays) {
                        ForEach(AppModel.archiveOptions, id: \.self) { d in
                            Text(AppModel.archiveLabel(d)).tag(d)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
            }
            SettingsCard(title: "附件", footer: "收到消息时，不超过上限的附件会自动下载，更大的点击后再下载。超过保留时长的附件会被删除，文字消息永久保留；收藏消息的附件不会被自动清理。附件按 年/月/日 分文件夹保存，可以放到 NAS 等任意位置。" + (attMsg.map { "\n" + $0 } ?? "")) {
                SettingsRow(label: "保存位置") {
                    Text(model.relocateProgress.map { "正在搬移 \($0.0)/\($0.1)…" } ?? (model.attachmentDirIsDefault ? "默认（缓存目录）" : model.attachmentDir.path))
                        .font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                        .help(model.attachmentDir.path)
                    Button("更改…") {
                        if let u = model.chooseAttachmentDir() { pendingDir = u; askMove = true }
                    }.buttonStyle(SoftButtonStyle())
                    Button { NSWorkspace.shared.open(model.attachmentDir) } label: { Image(systemName: "folder") }
                        .buttonStyle(SoftButtonStyle()).help("在 Finder 中打开")
                    if !model.attachmentDirIsDefault {
                        Button("恢复默认") { pendingDir = nil; askMove = true }.buttonStyle(SoftButtonStyle())
                    }
                }
                SettingsRow(label: "自动下载附件") {
                    Picker("", selection: $model.autoDownloadLimitMB) {
                        ForEach(AutoDownload.options, id: \.0) { o in
                            Text(o.0 > 0 ? "不超过 \(o.1)" : o.1).tag(o.0)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                SettingsRow(label: "已下载附件保留") {
                    Picker("", selection: $model.retentionHours) {
                        Text("24 小时").tag(24)
                        Text("3 天").tag(72)
                        Text("7 天").tag(168)
                        Text("永久").tag(-1)
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                SettingsRow(label: "本地缓存", divider: false) {
                    Text(usage.0 == 0 ? "无" : "\(usage.0) 个文件 · \(humanSize(usage.1))")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                    Button("立即清理") { model.clearAllCache() }.buttonStyle(SoftButtonStyle()).disabled(usage.0 == 0)
                }
            }
            SettingsCard(title: "配置迁移", footer: cfgMsg ?? "把服务器地址、通知、附件、代理等设置导出成一个文件，换电脑或重装后导入即可；不包含设备凭证，新电脑需要重新配对。") {
                SettingsRow(label: "本机设置", divider: false) {
                    Button("导出配置…") { if let m = model.exportConfigWithPanel() { cfgMsg = m } }.buttonStyle(SoftButtonStyle())
                    Button("导入配置…") { Task { if let m = await model.importConfigWithPanel() { cfgMsg = m } } }.buttonStyle(SoftButtonStyle())
                }
            }
        }
        .confirmationDialog(pendingDir == nil ? "恢复默认保存位置" : "附件保存到「\(pendingDir?.lastPathComponent ?? "")」", isPresented: $askMove) {
            Button("把已下载的附件一起搬过去") { let d = pendingDir; Task { attMsg = await model.setAttachmentDir(d, move: true) } }
            Button("只保存新附件") { let d = pendingDir; Task { attMsg = await model.setAttachmentDir(d, move: false) } }
        } message: {
            Text("已下载的附件可以一起搬到新位置；不搬的话它们留在原处，照常可以打开。")
        }
    }
}

struct NotifySettings: View {
    @EnvironmentObject var model: AppModel
    @State private var awayMsg: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.token != nil, model.support("presence") == .yes {
                SettingsCard(title: "多台设备", footer: awayMsg ?? "打开后，你正在用同一账号的另一台设备时（例如正在用另一台 Mac），本机对普通消息只进列表、不弹不响，避免几台设备一起响；紧急（P5）消息照常提醒。某个 pushkey 只想在特定设备上响，在「Pushkey」页设置「本机」接收方式。") {
                    SettingsRow(label: "我在用其他设备时，本机不响", divider: false) {
                        Toggle("", isOn: Binding(get: { model.awaySilent }, set: { on in
                            Task {
                                do { try await model.setAwaySilent(on); awayMsg = nil } catch { awayMsg = "保存失败：\(Updater.describe(error))" }
                            }
                        }))
                        .toggleStyle(.switch).labelsHidden()
                    }
                }
            }
            SettingsCard(title: "按优先级") {
                ForEach((0...5).reversed(), id: \.self) { p in
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            PriorityBadge(priority: p).frame(width: 64, alignment: .leading)
                            Text(example(p)).font(.system(size: 12)).foregroundStyle(Theme.text3)
                            Spacer()
                            Toggle("弹出", isOn: Binding(get: { model.prefs.show[p] }, set: { model.prefs.show[p] = $0 }))
                            Toggle("声音", isOn: Binding(get: { model.prefs.sound[p] }, set: { model.prefs.sound[p] = $0 }))
                                .disabled(!model.prefs.show[p])
                                .padding(.leading, 10)
                        }
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.text)
                        .frame(height: 46)
                        if p > 0 { Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1) }
                    }
                }
            }
            SettingsCard(title: "免打扰", footer: "免打扰时段和暂停期间，只有 P5 紧急消息会弹出。") {
                SettingsRow(label: "启用免打扰时段") {
                    Toggle("", isOn: $model.prefs.quietEnabled).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(label: "时段") {
                    HStack(spacing: 8) {
                        hourPicker($model.prefs.quietStart)
                        Text("至").foregroundStyle(Theme.text2)
                        hourPicker($model.prefs.quietEnd)
                        if model.prefs.quietEnd <= model.prefs.quietStart {
                            Text("次日").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                        }
                    }
                    .disabled(!model.prefs.quietEnabled)
                    .opacity(model.prefs.quietEnabled ? 1 : 0.5)
                }
                if model.isPaused, let u = model.pausedUntil {
                    SettingsRow(label: "通知已暂停至 \(TimeFmt.compact(u))", divider: false) {
                        Button("恢复") { model.pausedUntil = nil }.buttonStyle(SoftButtonStyle())
                    }
                } else {
                    SettingsRow(label: "临时暂停", divider: false) {
                        Button("1 小时") { model.pause(hours: 1) }.buttonStyle(SoftButtonStyle())
                        Button("到明早 8 点") { model.pauseUntilMorning() }.buttonStyle(SoftButtonStyle())
                    }
                }
            }
        }
    }

    func hourPicker(_ b: Binding<Int>) -> some View {
        Picker("", selection: b) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
            .labelsHidden().fixedSize()
    }

    func example(_ p: Int) -> String {
        ["调试信息", "过程日志", "一般进度", "阶段里程碑", "开始 / 结束", "崩溃 / 失联"][p]
    }
}

// MARK: 菜单栏

enum MenuIcon {
    /// 菜单栏图标：回笺标志的单色简化版（模板图标，随菜单栏明暗变色）；断线时变淡；有未读 P5 时朱砂色
    static func image(connected: Bool, critical: Bool) -> NSImage {
        let color = critical ? HuijianMark.rgb(0xD44C3D) : CGColor(gray: 0, alpha: connected ? 1 : 0.4)
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { r in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            HuijianMark.draw(in: cg, rect: r.insetBy(dx: -1.5, dy: -1.5), simple: true, mono: color)
            return true
        }
        img.accessibilityDescription = appDisplayName
        img.isTemplate = !critical
        return img
    }
}

struct MenuLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let n = model.unreadCount
        HStack(spacing: 3) {
            Image(nsImage: MenuIcon.image(connected: model.state == .connected, critical: model.hasUnreadCritical))
                .opacity(model.state == .connected ? 1 : 0.5)
            if n > 0 { Text(n > 99 ? "99+" : "\(n)").monospacedDigit() }
        }
    }
}

func closeMenuPanel() {
    for w in NSApp.windows where w.className.contains("MenuBarExtra") { w.orderOut(nil) }
}

struct MenuPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let recent = Array(model.inbox.filter { $0.priority >= 2 }.suffix(6).reversed())
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 18, height: 18)
                Text(appDisplayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                if model.unreadCount > 0 {
                    Text("\(model.unreadCount) 未读").font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                Spacer()
                HStack(spacing: 6) {
                    StatusDot(state: model.state)
                    Text(model.state.shortLabel).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                }
                .help(model.state.label)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Rectangle().fill(Theme.border).frame(height: 1)
            if model.isPaused, let u = model.pausedUntil {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash.fill").foregroundStyle(Theme.warning)
                    Text("通知已暂停至 \(TimeFmt.compact(u))，仅放行 P5").foregroundStyle(Theme.text2)
                    Spacer()
                    Button("恢复") { model.pausedUntil = nil }.buttonStyle(.link)
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.warning.opacity(0.09))
            }
            if model.needsAccountSetup {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark").font(.system(size: 26)).foregroundStyle(Theme.warning)
                    Text("配对成功，请先完成账号设置").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    Button("去设置") {
                        closeMenuPanel()
                        AppDelegate.shared?.showMainWindow(select: nil)
                    }
                    .buttonStyle(SoftButtonStyle())
                }
                .padding(.vertical, 22)
            } else if recent.isEmpty {
                Text("暂无消息").font(.system(size: 12)).foregroundStyle(Theme.text3).padding(.vertical, 26)
            } else {
                VStack(spacing: 1) {
                    ForEach(recent) { m in
                        PanelMessageRow(message: m, unread: !model.read.contains(m.id), topicName: model.channelName(m.topic))
                            .onTapGesture {
                                closeMenuPanel()
                                AppDelegate.shared?.showMainWindow(select: m.id)
                            }
                    }
                }
                .padding(6)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            VStack(spacing: 1) {
                PanelAction(icon: "macwindow", title: "打开回笺", trailing: "⌘O") {
                    closeMenuPanel()
                    AppDelegate.shared?.showMainWindow(select: nil)
                }
                PanelAction(icon: "person.crop.circle", title: "账户…",
                            subtitle: model.needsAccountSetup ? "请先完成账号设置" : (model.accountName.isEmpty ? nil : model.accountName)) {
                    closeMenuPanel()
                    if model.needsAccountSetup || model.token == nil { AppDelegate.shared?.showMainWindow(select: nil) } else { AppDelegate.shared?.showAccount() }
                }
                PauseRow(model: model)
                PanelUpdateRow(updater: model.updater)
                PanelAction(icon: "gearshape", title: "设置…", trailing: "⌘,") {
                    closeMenuPanel()
                    AppDelegate.shared?.showSettings()
                }
                Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 8)
                PanelAction(icon: "power", title: "退出回笺", trailing: "⌘Q") { NSApp.terminate(nil) }
            }
            .padding(6)
        }
        .frame(width: 340)
        .background(Theme.bg)
        .tint(Theme.accent)
    }
}

struct PanelMessageRow: View {
    let message: Message
    let unread: Bool
    var topicName: String? = nil
    @State private var hover = false

    var body: some View {
        let s = PriorityStyle.of(message.priority)
        let summary = messageSummary(message, limit: 60)
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(unread ? s.color : s.color.opacity(0.35)).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.text).font(.system(size: 12.5, weight: unread ? .semibold : .regular))
                        .foregroundStyle(s.level == 5 ? s.color : Theme.text).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(TimeFmt.relative(message.createdAt)).font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(Theme.text3).fixedSize()
                }
                Text(summary.isEmpty ? "#\(topicName ?? message.topic)" : summary)
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct PanelAction: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var trailing: String? = nil
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12.5)).foregroundStyle(Theme.text2).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).foregroundStyle(Theme.text)
                    if let subtitle { Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(2) }
                }
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 11.5)).foregroundStyle(Theme.text3) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover && !disabled ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { hover = $0 }
    }
}

struct PauseRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.isPaused {
            PanelAction(icon: "bell", title: "恢复通知") { model.pausedUntil = nil }
        } else {
            HStack(spacing: 9) {
                Image(systemName: "bell.slash").font(.system(size: 12.5)).foregroundStyle(Theme.text2).frame(width: 16)
                Text("暂停通知").font(.system(size: 13)).foregroundStyle(Theme.text)
                Spacer()
                pill("1 小时") { model.pause(hours: 1) }
                pill("到明早 8 点") { model.pauseUntilMorning() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    func pill(_ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text2)
                .padding(.horizontal, 8).frame(height: 20)
                .background(Capsule().fill(Theme.surface2))
                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// 菜单栏面板里的更新入口（直接观察 Updater，不经过 AppModel）
struct PanelUpdateRow: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if let info = updater.available {
            PanelAction(icon: "arrow.down.circle", title: "更新到 \(info.version)", subtitle: "下载、校验后自动重启") {
                closeMenuPanel()
                AppDelegate.shared?.showSettings(tab: .general)   // 进度和错误显示在设置 → 通用
                Task { await updater.installAvailable() }
            }
        }
    }
}

// MARK: 清理消息

struct CleanupSheet: View {
    @EnvironmentObject var model: AppModel
    @State var rule: AppModel.CleanupRule
    @State private var busy = false
    @State private var confirm: AppModel.DeleteRequest?
    /// 面板开着时主窗口的错误弹窗出不来，错误显示在面板里
    @State private var error: String?

    static let ages: [(Int, String)] = [(7, "早于 7 天"), (30, "早于 30 天"), (90, "早于 90 天"), (365, "早于 1 年"), (0, "不限时间")]
    static let prios: [(Int?, String)] = [(nil, "所有级别"), (3, "P3 普通及以下"), (2, "P2 低及以下"), (1, "只有 P1 日志")]

    func finish(_ ok: Bool) {
        busy = false
        if ok { model.cleanupRule = nil } else { error = model.manageError; model.manageError = nil }
    }

    var body: some View {
        let targets = model.cleanupTargets(rule)
        let atts = targets.reduce(0) { $0 + $1.attachments.count }
        VStack(alignment: .leading, spacing: 0) {
            Text("清理消息").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            Text("按条件批量删除或归档。删除是从账号删除，所有设备上都会消失。归档按会话显示：会话里还有较新的消息时，它仍留在收件箱。")
                .fixedSize(horizontal: false, vertical: true)
                .font(.system(size: 12.5)).foregroundStyle(Theme.text2).padding(.top, 4)
            VStack(spacing: 0) {
                SettingsRow(label: "频道") {
                    Picker("", selection: $rule.topic) {
                        Text("全部频道").tag(String?.none)
                        Divider()
                        ForEach(model.allTopicNames, id: \.self) { Text("# \(model.channelName($0))").tag(String?.some($0)) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                SettingsRow(label: "时间") {
                    Picker("", selection: $rule.olderThanDays) {
                        ForEach(Self.ages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                SettingsRow(label: "优先级") {
                    Picker("", selection: $rule.maxPriority) {
                        ForEach(Self.prios, id: \.1) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                SettingsRow(label: "包括收藏的消息", divider: false) {
                    Toggle("", isOn: $rule.includeStarred).toggleStyle(.switch).labelsHidden()
                }
            }
            .padding(.horizontal, 16)
            .card(radius: 10)
            .padding(.top, 16)
            Text(targets.isEmpty ? "没有符合条件的消息" : "符合条件：\(targets.count) 条消息" + (atts > 0 ? "，\(atts) 个附件" : ""))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(targets.isEmpty ? Theme.text3 : Theme.text)
                .padding(.top, 14)
            if let error {
                Text(error).font(.system(size: 12.5)).foregroundStyle(PriorityStyle.of(5).color)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { model.cleanupRule = nil }.keyboardShortcut(.cancelAction)
                Button("归档") {
                    busy = true
                    let ids = targets.map(\.id)
                    error = nil
                    Task { await finish(model.setArchive(ids, state: ArchiveState.archived)) }
                }
                .disabled(targets.isEmpty || busy)
                Button("删除…", role: .destructive) {
                    confirm = AppModel.DeleteRequest(title: "删除 \(targets.count) 条消息？", ids: targets.map(\.id), attachments: atts)
                }
                .disabled(targets.isEmpty || busy)
            }
            .padding(.top, 18)
        }
        .alert(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
               presenting: confirm) { r in
            Button("删除", role: .destructive) {
                busy = true
                error = nil
                Task { await finish(model.deleteMessages(r.ids)) }
            }
            Button("取消", role: .cancel) {}
        } message: { r in
            Text(r.detail)
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.bg)
        .tint(Theme.accent)
    }
}

/// 空列表占位：回笺标志的灰色剪影
struct EmptyMark: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, size in
            let c = HuijianMark.rgb(scheme == .dark ? 0x77716A : 0x9D978C)
            ctx.withCGContext { HuijianMark.draw(in: $0, rect: CGRect(origin: .zero, size: size), mono: c) }
        }
        .accessibilityHidden(true)
    }
}

// MARK: 端到端加密：锁定横幅、解不开的消息

/// 消息列表顶部：本机还没解锁加密消息（T10），点开进入设置的「加密」页
struct E2ELockedBanner: View {
    @State private var hover = false

    var body: some View {
        Button { AppDelegate.shared?.showSettings(tab: .e2e) } label: {
            HStack(spacing: 6) {
                Text(E2E.T.t10).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warning.opacity(hover ? 0.18 : 0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.horizontal, 8).padding(.top, 6)
        .background(Theme.bg)
    }
}

/// 消息列表顶部：建议设置恢复码（T23，§11.2）。不打断：可以「以后再说」，设置好后自动消失
struct E2ERecoveryHintBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key").font(.system(size: 12)).foregroundStyle(Theme.accent)
            Text(E2E.T.t23).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("去设置") { AppDelegate.shared?.showSettings(tab: .e2e) }.buttonStyle(SoftButtonStyle())
            Button("以后再说") { model.e2eDismissRecoveryHint() }.buttonStyle(.plain)
                .font(.system(size: 12)).foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.08)))
        .padding(.horizontal, 8).padding(.top, 6)
        .background(Theme.bg)
    }
}

/// 消息列表顶部：账号还没开启加密、服务端支持自动开启（§11.1 末尾，T67），不能关闭。
/// 有密码：弹出只输当前密码的小窗；没有密码：进「完成账号设置」设置初始密码，设置后自动开启。开启后（本机或别的设备）自动消失
struct E2EEnableBanner: View {
    @EnvironmentObject var model: AppModel
    @State private var hover = false
    @State private var asking = false

    var body: some View {
        Button {
            // 没有密码：直接进「完成账号设置」（账号没有密码时主窗口就是这一页，本账号任何设备都能设置初始密码），
            // 设置好后自动开启加密。账号信息还没取到时先取一次，取到后主窗口自动切过去
            if model.account?.has_password == true {
                asking = true
            } else {
                AppDelegate.shared?.showMainWindow(select: nil)
                if model.account == nil { Task { await model.refreshMe() } }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").font(.system(size: 12)).foregroundStyle(Theme.accent)
                Text(E2E.T.t67).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                if model.e2eAutoSetupRunning { ProgressView().controlSize(.small) }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(hover ? 0.16 : 0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.e2eAutoSetupRunning)
        .onHover { hover = $0 }
        .padding(.horizontal, 8).padding(.top, 6)
        .background(Theme.bg)
        .sheet(isPresented: $asking) { E2EEnableSheet().environmentObject(model) }
    }
}

/// T67 的小窗：只输当前密码。密码和算出的钥匙都不留在内存里
struct E2EEnableSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("开启端到端加密").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text(E2E.T.t67).font(.system(size: 13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            SecureField("当前密码", text: $password).textFieldStyle(.roundedBorder).onSubmit { Task { await submit() } }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("取消") { password = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "正在开启…" : "开启") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction).disabled(busy || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    func submit() async {
        guard !password.isEmpty, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await model.e2eEnableWithPassword(password)
            password = ""
            dismiss()
        } catch {
            password = ""
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// 详情页：解不开的加密消息（标题已是 T60 / T61 / T62，正文为空）
struct E2ELockedBody: View {
    @EnvironmentObject var model: AppModel
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch message.e2eStatus {
            case "wrong_key":
                Text("这条消息是用别的钥匙加密的（可能换过钥匙，这台设备没有那把旧钥匙），无法解开。")
            case "format":
                Text("这条加密消息的内容格式不对或已被篡改，无法解开。")
            default:
                Text("这条消息是端到端加密的。这台设备解锁后会自动解开，附件也要解锁后才能下载。")
                if model.e2eLocked {
                    Button("去解锁") { AppDelegate.shared?.showSettings(tab: .e2e) }.buttonStyle(SoftButtonStyle())
                }
            }
        }
        .font(.system(size: 13)).foregroundStyle(Theme.text2)
        .fixedSize(horizontal: false, vertical: true)
    }
}
