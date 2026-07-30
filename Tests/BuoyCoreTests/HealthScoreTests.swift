import XCTest
@testable import BuoyCore

final class HealthScoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testWindowedScoreIsRemainingRatio() {
        // Arrange
        let q = Quota(id: "v.5h", type: .timeWindowed, label: "5h", unit: .credits, used: 25, limit: 50)

        // Act & Assert
        XCTAssertEqual(HealthScore.score(quota: q, etaSeconds: nil) ?? -1, 0.5, accuracy: 1e-9)
    }

    func testBalanceScoreNormalizesByWeek() {
        let q = Quota(id: "d.balance", type: .balance, label: "余额", unit: .cny, remaining: 42.5)

        // 7 天 -> 1.0；3.5 天 -> 0.5
        XCTAssertEqual(HealthScore.score(quota: q, etaSeconds: 7 * 86_400) ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(HealthScore.score(quota: q, etaSeconds: 3.5 * 86_400) ?? -1, 0.5, accuracy: 1e-9)
        // 无 ETA（冷启动）-> nil，不参与排序
        XCTAssertNil(HealthScore.score(quota: q, etaSeconds: nil))
    }

    func testProviderScoreTakesMin() {
        let tight = Quota(id: "v.5h", type: .timeWindowed, label: "5h", unit: .credits, used: 45, limit: 50)
        let loose = Quota(id: "v.30d", type: .timeWindowed, label: "30d", unit: .credits, used: 100, limit: 2000)

        let score = HealthScore.providerScore(quotas: [tight, loose], etas: [:])
        XCTAssertEqual(score ?? -1, 0.1, accuracy: 1e-9)
    }

    // MARK: - now-aware variants (mirror Quota.percentUsedAt(now:))

    /// A windowed quota whose window has already reset must read as full health
    /// even if the cached `used` value is nearly the limit — otherwise the ball
    /// paints red for a fresh empty window when the Mac slept through the reset.
    func testForWindowedNowAfterResetsAtReturnsFullHealth() {
        let q = Quota(id: "v.5h", type: .timeWindowed, label: "5h",
                      unit: .credits, used: 9500, limit: 10000,
                      windowStart: t0.addingTimeInterval(-5 * 3600),
                      resetsAt: t0.addingTimeInterval(-1))

        XCTAssertEqual(HealthScore.forWindowed(quota: q, now: t0) ?? -1, 1.0, accuracy: 1e-9)
    }

    /// Before the reset boundary, the `now`-aware overload matches the plain one.
    func testForWindowedNowBeforeResetsAtMatchesPlain() {
        let q = Quota(id: "v.5h", type: .timeWindowed, label: "5h",
                      unit: .credits, used: 9500, limit: 10000,
                      windowStart: t0.addingTimeInterval(-4 * 3600),
                      resetsAt: t0.addingTimeInterval(3600))

        let now = HealthScore.forWindowed(quota: q, now: t0)
        let plain = HealthScore.forWindowed(quota: q)
        XCTAssertEqual(now, plain)
        XCTAssertEqual(now ?? -1, 0.05, accuracy: 1e-9)
    }

    /// Balance quotas ignore the reset check even if a stray `resetsAt` is set.
    func testScoreNowBalanceIgnoresResetsAt() {
        let q = Quota(id: "d.balance", type: .balance, label: "balance",
                      unit: .cny, remaining: 1.15,
                      resetsAt: t0.addingTimeInterval(-3600))

        let s = HealthScore.score(quota: q, etaSeconds: 7 * 86_400, now: t0)
        XCTAssertEqual(s ?? -1, 1.0, accuracy: 1e-9)
    }

    /// Provider score with a mix: one expired 5h + one healthy 30d — the expired
    /// one is treated as full health so the min collapses to the 30d value, not 0.05.
    func testProviderScoreNowTreatsExpiredWindowAsHealthy() {
        let expired = Quota(id: "v.5h", type: .timeWindowed, label: "5h",
                            unit: .credits, used: 9500, limit: 10000,
                            windowStart: t0.addingTimeInterval(-5 * 3600),
                            resetsAt: t0.addingTimeInterval(-1))
        let healthy = Quota(id: "v.30d", type: .timeWindowed, label: "30d",
                            unit: .credits, used: 100, limit: 2000,
                            windowStart: t0.addingTimeInterval(-86_400),
                            resetsAt: t0.addingTimeInterval(29 * 86_400))

        let score = HealthScore.providerScore(quotas: [expired, healthy],
                                              etas: [:], now: t0)
        // Without the now-aware fix this would be 0.05 (from the expired quota).
        XCTAssertEqual(score ?? -1, 0.95, accuracy: 1e-9)
    }
}
