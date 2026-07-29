import SwiftUI
import BuoyCore

/// 浮标球：从 BallModel 渲染（DESIGN.md §8.3 形态 / §8.4 视觉编码 / §8.6 动画原语）。
/// 外环 = 最长窗口剩余（月度 ambient）；核心液面 = 活跃窗口剩余 / 余额 ETA 健康度；
/// 状态驱动动画：呼吸 / 抖动 / 慢闪 / 虚线脉冲 / 热气粒子。
struct BallView: View {
    let model: BallModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            // urgency 0 -> 周期 ~2.4s 平静；1 -> ~0.7s 急促，幅度亦加大
            let period = max(2.4 - 1.7 * model.breathUrgency, 0.5)
            let amplitude = 0.025 + 0.02 * model.breathUrgency
            let breathe = 1 + amplitude * sin(time * .pi / period)

            ZStack {
                ringLayer(time: time)
                coreLayer(phase: time * 1.8)
                centerTextLayer
                badgeLayer(time: time)
                if model.state == .fastBurn {
                    HeatParticles(phase: time)
                }
            }
            .scaleEffect(breathe)
            .offset(shakeOffset(time))
            .opacity(displayOpacity(time))
        }
        .frame(width: Theme.ballSize, height: Theme.ballSize)
        .overlay(alignment: .topTrailing) {
            if let badge = model.currencyBadge {
                Text(badge)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(2)
                    .background(Circle().fill(.black.opacity(0.4)))
                    .offset(x: -3, y: 3)
            }
        }
    }

    // MARK: - Ring（外环 = 月度，DESIGN.md §8.3）

    @ViewBuilder
    private func ringLayer(time: Double) -> some View {
        switch model.mode {
        case .balance, .cold:
            // 余额球 / 冷启动：无外环进度，仅淡轨道
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: Theme.ringWidth)
        case .error:
            // 错误/陈旧：灰色虚线脉冲环（DESIGN.md §8.4 error）
            let pulse = 0.4 + 0.3 * (0.5 + 0.5 * sin(time * .pi / 1.0))
            Circle()
                .stroke(Color.gray.opacity(pulse),
                        style: StrokeStyle(lineWidth: Theme.ringWidth, lineCap: .round, dash: [6, 4]))
        case .windowed:
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: Theme.ringWidth)
            if let ringUsed = model.ringUsed {
                Circle()
                    .trim(from: 0, to: min(max(ringUsed, 0), 1))
                    .stroke(Theme.healthColor(model.health),
                            style: StrokeStyle(lineWidth: Theme.ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }

    // MARK: - Core / 液面（活跃窗口，DESIGN.md §8.3）

    private func coreLayer(phase: Double) -> some View {
        ZStack {
            Circle().fill(.black.opacity(0.55))
            if let coreRemaining = model.coreRemaining {
                LiquidShape(level: coreRemaining, phase: phase)
                    .fill(Theme.stateColor(model.state).gradient)
                    .clipShape(Circle())
            }
            Circle().stroke(.white.opacity(0.2), lineWidth: 1)
        }
        .padding(Theme.coreInset)
    }

    // MARK: - 中央文字

    private var centerTextLayer: some View {
        VStack(spacing: 0) {
            Text(model.centerText)
                .font(.system(size: model.mode == .balance ? 16 : 15,
                              weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if !model.subText.isEmpty {
                Text(model.subText)
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(Theme.coreInset)
        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
    }

    // MARK: - 逃逸徽标（DESIGN.md §8.1）

    @ViewBuilder
    private func badgeLayer(time: Double) -> some View {
        let positions = BadgeLayout.positions(count: model.alertBadges.count, ballSize: Theme.ballSize)
        ForEach(Array(positions.enumerated()), id: \.offset) { idx, pos in
            if idx < model.alertBadges.count {
                let badge = model.alertBadges[idx]
                let theme = ProviderTheme.theme(for: badge.id)
                let pulse = 0.65 + 0.35 * (0.5 + 0.5 * sin(time * .pi * 2 / 1.2))
                Circle()
                    .fill(theme.color.opacity(pulse))
                    .frame(width: BadgeLayout.dotDiameter, height: BadgeLayout.dotDiameter)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .position(x: Theme.ballSize / 2 + pos.x,
                              y: Theme.ballSize / 2 - pos.y) // y 翻转（view 原点左上）
            }
        }
    }

    // MARK: - 状态动画修饰（DESIGN.md §8.4）

    /// near-depleted：轻微抖动
    private func shakeOffset(_ time: Double) -> CGSize {
        guard model.state == .nearDepleted else { return .zero }
        return CGSize(width: 1.5 * sin(time * 18), height: 1.2 * sin(time * 13))
    }

    /// depleted：慢闪；stale：变暗；否则不透明
    private func displayOpacity(_ time: Double) -> Double {
        if model.state == .depleted {
            return 0.55 + 0.45 * (0.5 + 0.5 * sin(time * .pi / 1.5)) // ~1.5s 慢闪
        }
        if model.isStale && model.state != .error { return 0.55 }
        return 1.0
    }
}
