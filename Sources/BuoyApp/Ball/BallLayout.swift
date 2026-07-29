import Foundation

/// Pure layout math for the independent floating balls (no AppKit), so it is unit-testable.
/// Default arrangement is a vertical stack at the top-right of the screen; each ball can then be
/// freely dragged to a persisted position.
enum BallLayout {
    /// Extra top inset to clear the macOS menu bar.
    static let menuBarInset: CGFloat = 24

    /// Default origin for the ball at `index` in a vertical stack anchored top-right (y down).
    static func defaultOrigin(index: Int,
                              in screen: CGRect,
                              ballSize: CGFloat,
                              spacing: CGFloat,
                              margin: CGFloat) -> CGPoint {
        let topY = screen.maxY - ballSize - margin - menuBarInset
        let startX = screen.maxX - ballSize - margin
        return CGPoint(x: startX, y: topY - CGFloat(index) * (ballSize + spacing))
    }

    /// All default origins for `count` balls (top-right, going downward).
    static func defaultOrigins(count: Int,
                               in screen: CGRect,
                               ballSize: CGFloat,
                               spacing: CGFloat,
                               margin: CGFloat) -> [CGPoint] {
        (0..<max(count, 0)).map { defaultOrigin(index: $0, in: screen, ballSize: ballSize,
                                                spacing: spacing, margin: margin) }
    }

    /// Clamp an origin so the ball stays fully inside the visible frame (with margin).
    static func clamped(_ origin: CGPoint,
                        ballSize: CGFloat,
                        in visible: CGRect,
                        margin: CGFloat) -> CGPoint {
        let x = min(max(origin.x, visible.minX + margin), visible.maxX - ballSize - margin)
        let y = min(max(origin.y, visible.minY + margin), visible.maxY - ballSize - margin)
        return CGPoint(x: x, y: y)
    }

    /// First default-stack origin (by index) whose frame does not overlap any occupied origin's frame,
    /// so a newly added ball is not stacked on top of an existing ball that kept its position.
    /// Falls back to the last default origin when every slot is taken.
    static func firstNonOverlappingDefault(count: Int,
                                           in screen: CGRect,
                                           ballSize: CGFloat,
                                           spacing: CGFloat,
                                           margin: CGFloat,
                                           avoiding occupied: [CGPoint]) -> CGPoint {
        let defaults = defaultOrigins(count: count, in: screen, ballSize: ballSize,
                                      spacing: spacing, margin: margin)
        return defaults.first(where: { origin in
            !occupied.contains(where: { occ in Self.overlaps(occ, origin, ballSize: ballSize) })
        }) ?? defaults.last ?? .zero
    }

    /// Whether two ball frames (side `ballSize`, origins at top-left) overlap. Touching edges do not
    /// count as overlap (strict `<`), so adjacent stacked balls are allowed.
    private static func overlaps(_ a: CGPoint, _ b: CGPoint, ballSize: CGFloat) -> Bool {
        abs(a.x - b.x) < ballSize && abs(a.y - b.y) < ballSize
    }
}
