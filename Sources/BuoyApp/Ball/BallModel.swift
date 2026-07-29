import SwiftUI
import BuoyCore

/// Escape-badge severity (DESIGN.md §8.4 state -> badge coloring).
enum BadgeSeverity: String, Equatable {
    case fastBurn, nearDepleted, depleted, error
}

/// A single escape badge (DESIGN.md §8.1): a themed dot on the ball rim for a
/// non-displayed provider that is in an alerting state.
struct AlertBadge: Equatable, Identifiable {
    /// providerId
    let id: String
    let severity: BadgeSeverity
}

/// Ball display model: store state compressed into a value that `BallView` renders (DESIGN.md §8).
/// Pure value type; constructed by `UsageStore.ballModel`.
///
/// Unified "used amount" semantics: outer ring / middle ring / liquid level all show
/// **used %** (rising as quota is consumed). Each channel's **color depends only on its own
/// remaining health** (green -> orange -> red), never on `state` -- this fixes "5h at 7% turns
/// yellow" (formerly forced by fast-burn). `state` now drives animation only
/// (breathing / shake / slow-blink / particles).
struct BallModel: Equatable {
    enum Mode: Equatable { case windowed, balance, error, cold }

    let mode: Mode
    /// Outer ring (30d) used 0...1; nil for balance / error / cold (no outer ring drawn)
    let ringUsed: Double?
    /// Middle ring (7d) used 0...1; nil when there is no 7d window or mode is not windowed
    let midRingUsed: Double?
    /// Core liquid level 0...1 (windowed = active window used %, rising as consumed;
    /// balance = ETA health, falling toward depletion)
    let coreLevel: Double?
    /// Outer ring remaining health (coloring; DESIGN §8.3 each ring colored independently)
    let ringHealth: Double?
    /// Middle ring remaining health (coloring)
    let midRingHealth: Double?
    /// Core remaining health (coloring; no longer uses state, fixing low-usage yellow)
    let coreHealth: Double?
    /// Center text: "73%" | "¥42.50" | "!" | "--"
    let centerText: String
    /// Sub text: "5h" | "~3.2d" | "error" | ""
    let subText: String
    /// Currency badge: "¥" | "$" | nil (balance only)
    let currencyBadge: String?
    /// Ball state: drives animation only (breathing / shake / slow-blink / particles), not color
    let state: BallState
    /// Breath urgency 0...1 (mapped from ETA; closer to depletion = more urgent, DESIGN.md §8.4)
    let breathUrgency: Double
    let isStale: Bool
    /// Alert badges for non-displayed providers (populated only on the primary ball to avoid duplicates)
    let alertBadges: [AlertBadge]
}

/// Badge layout: fixed polar coordinates so `BallEventView` can hit-test (DESIGN.md §8.1 ball rim).
/// Positions are returned relative to the ball center, y up. View and hit-test use the same conversion.
enum BadgeLayout {
    static let maxBadges = 3
    static let dotDiameter: CGFloat = 12

    /// Offsets of `count` badge centers relative to the ball center (y up),
    /// distributed along the upper-right rim arc.
    static func positions(count: Int, ballSize: CGFloat) -> [CGPoint] {
        let n = min(max(count, 0), maxBadges)
        guard n > 0 else { return [] }
        let r = ballSize / 2
        // From top (pi/2) to right (0), evenly along the upper-right arc
        let start = CGFloat.pi / 2
        let span: CGFloat = -CGFloat.pi / 2
        let step = n > 1 ? span / CGFloat(n - 1) : 0
        return (0..<n).map { i in
            let angle = start + CGFloat(i) * step
            return CGPoint(x: r * cos(angle), y: r * sin(angle))
        }
    }
}

// MARK: - Shared formatting helpers

/// Currency code -> symbol
func currencySymbol(_ code: String) -> String {
    switch code.uppercased() {
    case "CNY", "RMB": return "¥"
    case "USD": return "$"
    default: return code
    }
}

/// Last segment of a quotaId as a short label: "volcano.5h" -> "5h"
func shortLabel(_ id: String) -> String {
    guard let suffix = id.split(separator: ".").last else { return "" }
    return String(suffix)
}

/// ETA -> breath urgency: <5min = 1.0 (urgent), >2h = 0 (calm), linear between (DESIGN.md §8.4).
func breathUrgency(from eta: TimeInterval?) -> Double {
    guard let eta else { return 0 }
    let hours = eta / 3600
    return min(max(1 - hours / 2, 0), 1)
}
