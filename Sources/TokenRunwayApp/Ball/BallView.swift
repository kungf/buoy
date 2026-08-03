import SwiftUI
import TokenRunwayCore

/// Floating ball rendered from `BallModel` (DESIGN.md §8.3 form / §8.4 visual encoding / §8.6 animation).
/// Outer ring = longest window used (30d ambient); middle ring = 7d used — both used-progress.
/// Core liquid = REMAINING water level (windowed: 1−used; balance: remaining/highWater), so
/// full = healthy and the water drains as you consume, consistently across providers.
/// Each channel is colored by its OWN remaining health (green -> orange -> red), never by
/// `state`. State drives animation only: breathing / slow-blink / dashed pulse / heat particles.
/// (The near-depleted shake was removed because it triggered on merely-low windows like 7d
/// @ 85% used and read as jitter, not signal — color already communicates urgency.)
struct BallView: View {
    let model: BallModel
    /// Which provider this ball represents; drives the bottom nameplate short code.
    let providerId: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            BallScene(model: model,
                      providerId: providerId,
                      time: context.date.timeIntervalSinceReferenceDate)
        }
    }
}

/// Ball scene driven by an explicit `time` (seconds since an arbitrary reference).
/// `BallView` feeds it the wall clock via `TimelineView`; the GIF renderer (`GifRenderer`)
/// feeds it a deterministic time sequence so generated animations match the live ball exactly.
/// The scene owns everything time-dependent (breathing scale, liquid wave phase, badge pulse,
/// blink opacity) plus the static chrome (currency badge, provider nameplate).
struct BallScene: View {
    let model: BallModel
    /// Which provider this ball represents; drives the bottom nameplate short code.
    let providerId: String
    /// Animation clock, seconds since an arbitrary reference point.
    let time: Double

    var body: some View {
        // urgency 0 -> ~2.4s calm period; 1 -> ~0.7s urgent, larger amplitude
        let period = max(2.4 - 1.7 * model.breathUrgency, 0.5)
        let amplitude = 0.025 + 0.02 * model.breathUrgency
        let breathe = 1 + amplitude * sin(time * .pi / period)

        ZStack {
            ringLayer(time: time)
            midRingLayer()
            coreLayer(phase: time * 1.8)
            centerTextLayer
            badgeLayer(time: time)
            if model.state == .fastBurn {
                HeatParticles(phase: time)
            }
        }
        .scaleEffect(breathe)
        .opacity(displayOpacity(time))
        // Ball content is sized to `ballSize`; the outer canvas frame (`canvasSize`) centers
        // it and leaves margin so the ring stroke / breathing are not clipped by the
        // square panel (fixes "ball looks cropped on all sides").
        .frame(width: Theme.ballSize, height: Theme.ballSize)
        .frame(width: Theme.canvasSize, height: Theme.canvasSize)
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
        .overlay(alignment: .bottom) {
            nameplateLayer
        }
    }

    // MARK: - Outer ring (30d, DESIGN.md §8.3)

    @ViewBuilder
    private func ringLayer(time: Double) -> some View {
        switch model.mode {
        case .balance, .cold:
            // Balance / cold start: no outer-ring progress, just a faint track
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: Theme.ringWidth)
        case .error:
            // Error / stale: gray dashed pulsing ring (DESIGN.md §8.4 error)
            let pulse = 0.4 + 0.3 * (0.5 + 0.5 * sin(time * .pi / 1.0))
            Circle()
                .stroke(Color.gray.opacity(pulse),
                        style: StrokeStyle(lineWidth: Theme.ringWidth, lineCap: .round, dash: [6, 4]))
        case .windowed:
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: Theme.ringWidth)
            if let ringUsed = model.ringUsed {
                Circle()
                    .trim(from: 0, to: min(max(ringUsed, 0), 1))
                    .stroke(Theme.healthColor(model.ringHealth),
                            style: StrokeStyle(lineWidth: Theme.ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }

    // MARK: - Middle ring (7d)

    /// Second concentric ring for the 7-day window. Only drawn for windowed providers that have a
    /// 7d quota; inset inside the outer ring. Colored by the 7d remaining health.
    @ViewBuilder
    private func midRingLayer() -> some View {
        if model.mode == .windowed, let midUsed = model.midRingUsed {
            Circle().inset(by: Theme.midRingSpacing)
                .stroke(Color.primary.opacity(0.1), lineWidth: Theme.midRingWidth)
            Circle().inset(by: Theme.midRingSpacing)
                .trim(from: 0, to: min(max(midUsed, 0), 1))
                .stroke(Theme.healthColor(model.midRingHealth),
                        style: StrokeStyle(lineWidth: Theme.midRingWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }

    // MARK: - Core / liquid (active window, DESIGN.md §8.3)

    private func coreLayer(phase: Double) -> some View {
        ZStack {
            Circle().fill(.black.opacity(0.55))
            if let coreLevel = model.coreLevel {
                LiquidShape(level: coreLevel, phase: phase)
                    .fill(Theme.healthColor(model.coreHealth).gradient)
                    .clipShape(Circle())
            }
            Circle().stroke(.white.opacity(0.2), lineWidth: 1)
        }
        .padding(Theme.coreInset)
    }

    // MARK: - Center text

    private var centerTextLayer: some View {
        VStack(spacing: 0) {
            // Balance: upper (small) = last-5h spend, lower (big) = balance.
            if model.mode == .balance, let spent = model.spentRecentText {
                Text(spent)
                    .font(.system(size: 8, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
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

    // MARK: - Provider nameplate (bottom of the ball)

    /// Tiny capsule at the ball's bottom rim showing the provider short code (e.g. "ds", "vol"),
    /// so each independent ball is identifiable. Straddles the rim; does not breathe (kept outside
    /// the TimelineView-scaled ZStack). Draws nothing for a blank id.
    @ViewBuilder
    private var nameplateLayer: some View {
        let name = ProviderTheme.shortName(for: providerId)
        if !name.isEmpty {
            Text(name)
                .font(.system(size: Theme.nameplateFontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(.black.opacity(0.55)))
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
                .offset(y: Theme.nameplateOffsetY)
        }
    }

    // MARK: - Escape badges (DESIGN.md §8.1)

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
                              y: Theme.ballSize / 2 - pos.y) // y flipped (view origin top-left)
            }
        }
    }

    // MARK: - State-driven animation modifiers (DESIGN.md §8.4)

    /// depleted: slow blink; stale/expired: dimmed; otherwise fully opaque
    private func displayOpacity(_ time: Double) -> Double {
        if model.state == .depleted {
            return 0.55 + 0.45 * (0.5 + 0.5 * sin(time * .pi / 1.5)) // ~1.5s slow blink
        }
        if model.state == .expired { return 0.55 }
        if model.isStale && model.state != .error { return 0.55 }
        return 1.0
    }
}
