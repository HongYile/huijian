import AVFoundation
import SwiftUI

/// 扫描配对码二维码（docs/e2ee-client.md §12.3）：用系统相机识别二维码，识别到第一个就交给 onCode 并停下。
/// 没有相机权限时显示说明；模拟器没有相机，显示「这台设备没有可用的相机」。
struct QRScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let problem {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill").font(.largeTitle)
                        Text(problem).multilineTextAlignment(.center)
                        if AVCaptureDevice.authorizationStatus(for: .video) == .denied,
                           let url = URL(string: UIApplication.openSettingsURLString) {
                            Button("打开设置") { UIApplication.shared.open(url) }.buttonStyle(.borderedProminent)
                        }
                    }
                    .foregroundStyle(.white).padding(32)
                } else {
                    QRCameraView(onCode: { code in
                        onCode(code)
                        dismiss()
                    }, onProblem: { problem = $0 })
                    .ignoresSafeArea()
                    RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.85), lineWidth: 3)
                        .frame(width: 240, height: 240)
                    VStack {
                        Spacer()
                        Text("对准已登录设备上「添加设备」里的二维码")
                            .font(.subheadline).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(.black.opacity(0.55)))
                            .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("扫描配对码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: break
            case .notDetermined:
                if !(await AVCaptureDevice.requestAccess(for: .video)) { problem = Self.denied }
            default: problem = Self.denied
            }
        }
    }

    static let denied = "回笺没有相机权限：请在「设置 → 回笺」里允许使用相机，或者在登录页手动输入长配对码。"
}

private struct QRCameraView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onProblem: (String) -> Void

    func makeUIViewController(context: Context) -> Controller {
        let c = Controller()
        c.onCode = onCode
        c.onProblem = onProblem
        return c
    }

    func updateUIViewController(_ c: Controller, context: Context) {}

    final class Controller: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        var onProblem: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var done = false
        private let queue = DispatchQueue(label: "huijian.qrscan")

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let cam = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: cam),
                  session.canAddInput(input) else {
                onProblem?("这台设备没有可用的相机，请在登录页手动输入长配对码。")
                return
            }
            session.addInput(input)
            let out = AVCaptureMetadataOutput()
            guard session.canAddOutput(out) else { onProblem?("相机暂时不能用，请在登录页手动输入长配对码。"); return }
            session.addOutput(out)
            out.setMetadataObjectsDelegate(self, queue: .main)
            out.metadataObjectTypes = [.qr]
            let p = AVCaptureVideoPreviewLayer(session: session)
            p.videoGravity = .resizeAspectFill
            view.layer.addSublayer(p)
            preview = p
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            let s = session
            queue.async { if !s.inputs.isEmpty && !s.isRunning { s.startRunning() } }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let s = session
            queue.async { if s.isRunning { s.stopRunning() } }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let s = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
            done = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let sess = session
            queue.async { sess.stopRunning() }
            onCode?(s)
        }
    }
}
