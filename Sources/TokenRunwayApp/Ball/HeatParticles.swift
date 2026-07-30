import SwiftUI

/// 热气粒子（DESIGN.md §8.4 fast-burn "球边热气粒子"，§8.6 Canvas + 简易粒子系统）。
/// 确定性粒子（无随机数，仅按 index + phase 推导），由 `TimelineView` 的 phase 驱动；
/// 从球底缘上升、淡入淡出，营造"烧得急"的能量感。
struct HeatParticles: View {
    let phase: Double

    private let count = 18
    /// 单次上升耗时（秒）
    private let riseDuration: Double = 1.4

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = size.width / 2
            let riseHeight = radius * 0.95

            for i in 0..<count {
                let seed = Double(i)
                // 错峰起步：每个粒子进度相位不同
                let offset = seed * 0.317
                let progress = (phase / riseDuration + offset)
                    .truncatingRemainder(dividingBy: 1.0)
                guard progress > 0 else { continue }

                // 起点：球底缘附近，沿底部弧散开（确定性"伪随机"x 偏移）
                let xJitter = sin(seed * 12.9) * radius * 0.5
                let startX = center.x + CGFloat(xJitter)
                let startY = center.y + radius * 0.6
                let y = startY - CGFloat(progress) * riseHeight
                let alpha = sin(progress * .pi)            // 0 -> 1 -> 0
                let dotR = max(1.0, 2.2 - progress * 1.2)

                let rect = CGRect(x: startX - dotR, y: y - dotR,
                                  width: dotR * 2, height: dotR * 2)
                ctx.fill(Path(ellipseIn: rect),
                         with: .color(.orange.opacity(alpha * 0.75)))
            }
        }
    }
}
