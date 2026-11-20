import SwiftUI

/// 二维码（共用核心生成矩阵，这里只负责画）。白底黑码、四周留 4 格白边：深色模式下也一样，扫码软件只认这种。
/// Mac 和 iPhone 共用同一份文件。
struct QRCodeView: View {
    let text: String
    private let q: (size: Int, modules: [Bool])?

    init(text: String) {
        self.text = text
        q = try? Core.qr(text)
    }

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            guard let q else { return }
            let n = q.size + 8
            // 每格取整数个点，避免格子之间出现发丝缝；多出来的边距平均分到四周
            let cell = max(1, (min(size.width, size.height) / CGFloat(n)).rounded(.down))
            let ox = ((size.width - cell * CGFloat(q.size)) / 2).rounded(.down)
            let oy = ((size.height - cell * CGFloat(q.size)) / 2).rounded(.down)
            var path = Path()
            for y in 0..<q.size {
                for x in 0..<q.size where q.modules[y * q.size + x] {
                    path.addRect(CGRect(x: ox + CGFloat(x) * cell, y: oy + CGFloat(y) * cell, width: cell, height: cell))
                }
            }
            ctx.fill(path, with: .color(.black))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("配对二维码")
    }
}
