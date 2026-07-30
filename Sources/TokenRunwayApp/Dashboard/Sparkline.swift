import SwiftUI

/// Mini sparkline (DESIGN.md §8.2). Plots `used` samples — rising curve = sustained consumption.
/// Renders nothing for <2 points; caller sets the frame (e.g. 60×16).
struct Sparkline: View {
    let values: [Double]
    var color: Color = .secondary

    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2 else { return }
            let lo = values.min() ?? 0
            let hi = values.max() ?? 1
            let range = hi - lo
            let stepX = size.width / CGFloat(values.count - 1)
            var path = Path()
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * stepX
                // 无波动时居中，避免贴底
                let norm = range < 1e-9 ? 0.5 : (v - lo) / range
                let y = size.height - CGFloat(norm) * size.height
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(color), lineWidth: 1.2)
        }
    }
}

/// ETA formatting (DESIGN.md §7). nil/cold-start -> "--"; <1m -> "<1m";
/// <1h -> "≈Nm"; <1d -> "≈N.Nh"; else "≈N.Nd".
func formatETA(_ eta: TimeInterval?) -> String {
    guard let eta, eta > 0 else { return "--" }
    if eta < 60 { return "<1m" }
    if eta < 3600 { return "≈\(Int(eta / 60))m" }
    if eta < 86_400 { return "≈\(String(format: "%.1f", eta / 3600))h" }
    return "≈\(String(format: "%.1f", eta / 86_400))d"
}
