import CoreGraphics
import Foundation
// 打印指定 PID 面积最大的普通窗口 ID（避免拿到菜单栏或辅助小窗口）；第二个参数为 bounds 时打印 x,y,w,h
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var best: (Int, Double)? = nil
var bestBounds = ""
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let area = (b["Width"] ?? 0) * (b["Height"] ?? 0)
    if best == nil || area > best!.1 {
        best = (w[kCGWindowNumber as String] as! Int, area)
        bestBounds = "\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)),\(Int(b["Width"] ?? 0)),\(Int(b["Height"] ?? 0))"
    }
}
if let best { print(CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "bounds" ? bestBounds : String(best.0)) }
