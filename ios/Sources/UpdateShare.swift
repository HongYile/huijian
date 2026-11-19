import Foundation
import UIKit

/// 「打开方式」菜单：只列能打开 .ipa 的 App（GBox）。没有能打开的 App 时退回系统分享面板。
/// 交出去以后不删临时 IPA（GBox 可能还在拷贝），App 下次启动时清理；没选就关掉时文件也保留，可以再点一次
@MainActor
final class OpenInPresenter: NSObject, UIDocumentInteractionControllerDelegate {
    static let shared = OpenInPresenter()
    private var controller: UIDocumentInteractionController?
    /// 每弹一次加一：延迟释放 controller 时核对，不会释放掉后来新弹的
    private var token = 0
    private var finish: ((_ app: String, _ viaOpenIn: Bool) -> Void)?

    /// finish(交给了哪个 App / 分享方式, 是否从「打开方式」菜单交出)。没选就关掉时不回调
    func present(_ file: URL, finish: @escaping (_ app: String, _ viaOpenIn: Bool) -> Void) {
        guard let root = Self.topController(), let view = root.view else { return }
        token += 1
        self.finish = finish
        let c = UIDocumentInteractionController(url: file)
        c.uti = "com.apple.itunes.ipa"
        c.delegate = self
        controller = c
        let rect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 80, width: 1, height: 1)
        if !c.presentOpenInMenu(from: rect, in: view, animated: true) {
            // 没有声明能打开 .ipa 的 App：用系统分享面板（里面也能找到「拷贝到 GBox」，但用户也可能选「存储到文件」等）
            controller = nil
            let mine = token
            let av = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            av.popoverPresentationController?.sourceView = view
            av.popoverPresentationController?.sourceRect = rect
            av.completionWithItemsHandler = { [weak self] type, done, _, _ in
                guard let self, done, mine == self.token else { return }
                let f = self.finish
                self.finish = nil
                f?(type?.rawValue ?? "", false)
            }
            root.present(av, animated: true)
        }
    }

    /// 菜单关掉以后过一段时间再释放 controller：选了 App 时 didEndSending 可能晚于菜单关闭才到
    private func releaseLater(_ mine: Int, after seconds: Double) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, mine == self.token else { return }
            self.controller = nil
            self.finish = nil
        }
    }

    nonisolated func documentInteractionController(_ controller: UIDocumentInteractionController, didEndSendingToApplication application: String?) {
        MainActor.assumeIsolated {
            guard controller === self.controller else { return }
            let f = finish
            finish = nil
            f?(application ?? "", true)
            releaseLater(token, after: 5)
        }
    }

    nonisolated func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
        // 选了 App 时也会先走这里，再收到 didEndSending：不在这里收尾，留 2 分钟等交接完成再释放
        MainActor.assumeIsolated {
            guard controller === self.controller else { return }
            releaseLater(token, after: 120)
        }
    }

    private static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }
}
