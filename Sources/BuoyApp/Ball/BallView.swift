import SwiftUI

/// 浮标球：外环 = 最长窗口剩余比例；核心液面 = 当前窗口剩余比例；
/// 呼吸缩放 + 波形滚动（DESIGN.md §8.1）。右上角红点 = 隐藏 provider 告警（逃逸徽标）。
struct BallView: View {
    let ringRemaining: Double?   // 0...1
    let coreRemaining: Double?   // 0...1
    let health: Double?
    let coreLabel: String
    var hasError: Bool = false
    var showAlertBadge: Bool = false
    /// 呼吸紧迫度 0...1（由核心窗口 ETA 映射；越接近耗尽呼吸越急，DESIGN.md §8.4）
    var breathUrgency: Double = 0
    /// 数据过期（拉取失败/陈旧）-> 球面变暗（DESIGN.md §8.4 stale 降级）
    var isStale: Bool = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            // urgency 0 -> 周期 ~2.4s 平静；1 -> ~0.7s 急促，幅度亦加大
            let period = max(2.4 - 1.7 * breathUrgency, 0.5)
            let amplitude = 0.025 + 0.02 * breathUrgency
            let breathe = 1 + amplitude * sin(time * .pi / period)

            ZStack {
                // 外环轨道
                Circle()
                    .stroke(Color.primary.opacity(0.15), lineWidth: Theme.ringWidth)
                // 外环：剩余比例（从顶部顺时针递减）
                if let ringRemaining {
                    Circle()
                        .trim(from: 0, to: min(max(ringRemaining, 0), 1))
                        .stroke(Theme.healthColor(health),
                                style: StrokeStyle(lineWidth: Theme.ringWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                // 核心液面
                coreView(phase: time * 1.8)
                    .padding(Theme.coreInset)
                // 中央文字：核心剩余百分比（错误时显示 !）
                VStack(spacing: 0) {
                    Text(hasError ? "!" : corePercentText)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(hasError ? "error" : coreLabel)
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(Theme.coreInset)
                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }
            .scaleEffect(breathe)
            .opacity(isStale ? 0.55 : 1.0)
            .overlay(alignment: .topTrailing) {
                if showAlertBadge {
                    Circle()
                        .fill(.red)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .offset(x: -2, y: 2)
                }
            }
        }
        .frame(width: Theme.ballSize, height: Theme.ballSize)
    }

    private var corePercentText: String {
        guard let coreRemaining else { return "--" }
        return "\(Int((coreRemaining * 100).rounded()))%"
    }

    private func coreView(phase: Double) -> some View {
        ZStack {
            Circle().fill(.black.opacity(0.55))
            if let coreRemaining {
                LiquidShape(level: coreRemaining, phase: phase)
                    .fill(Theme.healthColor(health).gradient)
                    .clipShape(Circle())
            }
            Circle().stroke(.white.opacity(0.2), lineWidth: 1)
        }
    }
}
