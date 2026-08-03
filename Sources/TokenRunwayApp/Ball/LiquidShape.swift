import SwiftUI

/// 液面波形：从底部填充到 level，顶部叠加一条正弦波（DESIGN.md §8.1 液面）。
struct LiquidShape: Shape {
    /// 填充比例 0...1（剩余比例）
    var level: Double
    /// 波形相位（外部用 TimelineView 驱动）
    var phase: Double

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(level, 0), 1)
        let surfaceY = rect.height * (1 - clamped)
        let wavelength = rect.width / 1.4
        let amplitude: CGFloat = 2.5

        return Path { path in
            path.move(to: CGPoint(x: 0, y: surfaceY))
            var x: CGFloat = 0
            while x <= rect.width {
                let angle = Double(x / wavelength) * 2 * .pi + phase
                let y = surfaceY + amplitude * sin(angle)
                path.addLine(to: CGPoint(x: x, y: y))
                x += 2
            }
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: rect.height))
            path.closeSubpath()
        }
    }
}
