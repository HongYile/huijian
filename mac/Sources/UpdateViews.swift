import SwiftUI

// MARK: 应用内更新的界面：侧栏提示条、设置页「软件更新」卡片、菜单栏面板入口

/// 侧栏底部的新版本提示（有可用更新、正在下载或安装失败时显示）
struct UpdateBanner: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if let info = updater.available {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.accent)
                    Text("回笺 \(info.version) 可用").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                UpdateAction(updater: updater, compact: true)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accentSoft))
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }
}

/// 「更新并重启」按钮 / 下载进度 / 失败重试
struct UpdateAction: View {
    @ObservedObject var updater: Updater
    var compact = false

    var body: some View {
        switch updater.phase {
        case .downloading, .verifying, .installing:
            // 三个阶段共用同一个进度条（同一个视图），下载完成时平滑走满，而不是换成另一个控件
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: progress).progressViewStyle(.linear).tint(Theme.accent)
                    .animation(.easeOut(duration: 0.35), value: progress)
                HStack(spacing: 6) {
                    if !isDownloading {
                        Image(systemName: updater.phase == .installing ? "checkmark.circle.fill" : "checkmark.shield")
                            .font(.system(size: 11)).foregroundStyle(Theme.success)
                    }
                    Text(stageText).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if isDownloading {
                        Button("取消") { updater.cancel() }.buttonStyle(.link).font(.system(size: 11))
                    }
                }
            }
        default:
            VStack(alignment: .leading, spacing: 5) {
                if case .failed(let m) = updater.phase {
                    Text(m).font(.system(size: 11)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await updater.installAvailable() }
                } label: {
                    Text(compact ? "更新并重启" : "更新并重启回笺")
                }
                .buttonStyle(compact ? AnyButtonStyle(SoftButtonStyle()) : AnyButtonStyle(PrimaryButtonStyle()))
            }
        }
    }
}

extension UpdateAction {
    var isDownloading: Bool {
        if case .downloading = updater.phase { return true }
        return false
    }

    var progress: Double {
        if case .downloading(let p) = updater.phase { return p }
        return 1
    }

    var stageText: String {
        switch updater.phase {
        case .downloading(let p): return "下载中 \(Int(p * 100))%"
        case .verifying: return "下载完成，正在校验签名和完整性…"
        default: return "校验通过，正在安装，回笺将自动重启…"
        }
    }
}

/// 让两个不同的 ButtonStyle 能在三元表达式里互换
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// 设置 → 通用 → 软件更新
struct UpdateSettingsCard: View {
    @ObservedObject var updater: Updater

    var body: some View {
        SettingsCard(title: "软件更新", footer: footer) {
            SettingsRow(label: "当前版本") {
                Text("\(AppInfo.version)（build \(AppInfo.build)）").font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(Theme.text2)
            }
            SettingsRow(label: "自动检查更新") {
                Toggle("", isOn: $updater.autoCheck).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .disabled(!updater.supported)
            }
            SettingsRow(label: statusText, divider: updater.available != nil) {
                if updater.phase == .checking { ProgressView().controlSize(.small) }
                Button("检查更新") { Task { await updater.check(userInitiated: true) } }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(updater.busy || !updater.supported)
            }
            if let info = updater.available {
                VStack(alignment: .leading, spacing: 8) {
                    Text("新版本 \(info.version)（build \(info.build)）· \(humanSize(info.size))")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    if !info.notes.isEmpty {
                        Text(info.notes).font(.system(size: 12)).foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    UpdateAction(updater: updater)
                }
                .padding(.vertical, 12)
            }
        }
    }

    var statusText: String {
        switch updater.phase {
        case .checking: return "正在检查…"
        case .upToDate: return "已是最新版本"
        case .failed(let m) where updater.available == nil: return m
        default:
            if updater.available != nil { return "发现新版本" }
            if let d = updater.lastChecked { return "上次检查：\(TimeFmt.compact(d))" }
            return "尚未检查"
        }
    }

    var footer: String {
        updater.supported
            ? "更新源：\(updater.source.label)。更新包由发布者签名，下载后校验签名、sha256 和代码签名，全部通过才会安装；可在「网络」里让更新走代理。"
            : "这个版本构建时没有配置更新公钥（UPDATE_PUBKEY），不支持应用内更新。"
    }
}
