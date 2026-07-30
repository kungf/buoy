import SwiftUI
import TokenRunwayCore

/// Health score -> color (DESIGN.md §7: green >0.5 / orange 0.2..0.5 / red <0.2 / gray = no data).
enum Theme {
    static func healthColor(_ score: Double?) -> Color {
        guard let score else { return .gray }
        switch score {
        case ..<0.2: return .red
        case ..<0.5: return .orange
        default: return .green
        }
    }

    static let ballSize: CGFloat = 88
    /// Margin around the ball inside its canvas/frame. Leaves room for the ring stroke (drawn at
    /// the edge), the breathing scale-up, and the shake offset, so the square panel does not clip
    /// the circle (fixes "the ball looks cropped on all sides").
    static let canvasMargin: CGFloat = 8
    /// Full canvas (panel) size hosting one ball: ball + margin on both sides.
    static var canvasSize: CGFloat { ballSize + 2 * canvasMargin }
    static let ringWidth: CGFloat = 5
    /// Middle ring (7d) stroke width, slightly thinner than the outer ring.
    static let midRingWidth: CGFloat = 3
    /// Middle ring inward offset from the outer ring (outer center -> middle center).
    static let midRingSpacing: CGFloat = 8
    /// Core liquid inset from the ball edge; enlarged to make room for the middle ring.
    static let coreInset: CGFloat = 12
    static let screenMargin: CGFloat = 16
    /// Vertical spacing between independently stacked balls.
    static let ballSpacing: CGFloat = 6
    /// Provider nameplate (bottom of the ball) font size.
    static let nameplateFontSize: CGFloat = 8
    /// Lifts the nameplate up from the canvas bottom so it sits on the ball's bottom rim
    /// (canvasMargin = 8). Negative = up; the pill straddles the rim and hangs into the margin.
    static let nameplateOffsetY: CGFloat = -3

    // MARK: Hover panel

    /// Padding inside the hover panel around the SwiftUI content.
    static let hoverPanelPadding: CGFloat = 8
    /// Corner radius for the hover panel card.
    static let hoverPanelCornerRadius: CGFloat = 14
    /// Gap between the ball's left edge and the hover panel.
    static let hoverPanelGap: CGFloat = 10
    /// Delay before hiding the hover panel after the mouse exits the ball.
    static let hoverHideDelay: TimeInterval = 0.2
}
