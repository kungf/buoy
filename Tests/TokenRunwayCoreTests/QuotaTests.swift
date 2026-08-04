import XCTest
@testable import TokenRunwayCore

/// Unit tests for `Quota.percentUsedAt(now:)` — the local-window-expiry
/// escape hatch that lets the UI display 0% when the Mac slept through a
/// `resetsAt` and cached `used` is stale.
final class QuotaTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: percentUsedAt

    func testPercentUsedAtBeforeResetsAtMatchesPercentUsed() {
        // Arrange: window still open (resetsAt one hour in the future)
        let q = Quota(id: "volcano.5h", type: .timeWindowed, label: "5h",
                      unit: .credits, used: 9500, limit: 10000,
                      windowStart: t0.addingTimeInterval(-4 * 3600),
                      resetsAt: t0.addingTimeInterval(3600))

        // Act
        let live = q.percentUsedAt(now: t0)

        // Assert: identical to raw percentUsed
        XCTAssertEqual(live ?? -1, 0.95, accuracy: 1e-9)
        XCTAssertEqual(live, q.percentUsed)
    }

    func testPercentUsedAtAfterResetsAtReturnsZero() {
        // Arrange: window reset one second ago; cached used is still 9500
        let q = Quota(id: "volcano.5h", type: .timeWindowed, label: "5h",
                      unit: .credits, used: 9500, limit: 10000,
                      windowStart: t0.addingTimeInterval(-5 * 3600),
                      resetsAt: t0.addingTimeInterval(-1))

        // Act
        let live = q.percentUsedAt(now: t0)

        // Assert: UI reads a fresh empty window, not the stale 95%
        XCTAssertEqual(live ?? -1, 0, accuracy: 1e-9)
    }

    func testPercentUsedAtAtExactlyResetsAtReturnsZero() {
        // Arrange: now == resetsAt (the boundary must count as expired)
        let q = Quota(id: "volcano.5h", type: .timeWindowed, label: "5h",
                      unit: .credits, used: 7500, limit: 10000,
                      windowStart: t0.addingTimeInterval(-5 * 3600),
                      resetsAt: t0)

        // Act & Assert
        XCTAssertEqual(q.percentUsedAt(now: t0) ?? -1, 0, accuracy: 1e-9)
    }

    func testPercentUsedAtBalanceIgnoresResetsAt() {
        // Arrange: balance quotas don't reset; even a past resetsAt shouldn't
        // trigger the zero-out (balance types shouldn't have resetsAt at all
        // in practice, but we defend against it).
        let q = Quota(id: "deepseek.balance", type: .balance,
                      label: "balance", unit: .cny, remaining: 1.15,
                      resetsAt: t0.addingTimeInterval(-3600))

        // Act & Assert: falls through to percentUsed (which is nil for a
        // balance quota without limit).
        XCTAssertNil(q.percentUsedAt(now: t0))
    }

    func testPercentUsedAtWithoutResetsAtFallsThrough() {
        // Arrange: timeWindowed but resetsAt not populated
        let q = Quota(id: "x.5h", type: .timeWindowed, label: "5h",
                      unit: .credits, used: 2000, limit: 10000)

        // Act & Assert
        XCTAssertEqual(q.percentUsedAt(now: t0) ?? -1, 0.2, accuracy: 1e-9)
    }

    // MARK: Codable (showsUsedLevel cache round-trip)

    /// Regression: defaulted `let` properties are silently dropped by the synthesized decoder —
    /// used-semantics water direction must survive the cache.json round-trip or it reverts on restart
    func testShowsUsedLevelSurvivesCodableRoundtrip() throws {
        // Arrange
        let q = Quota(id: "custom-1.main", type: .timeWindowed, label: "用量",
                      unit: .tokens, used: 80, limit: 100, showsUsedLevel: true)

        // Act
        let data = try JSONEncoder().encode(q)
        let decoded = try JSONDecoder().decode(Quota.self, from: data)

        // Assert
        XCTAssertTrue(decoded.showsUsedLevel, "used-semantics water direction must survive")
        XCTAssertEqual(decoded.used, 80)
        XCTAssertEqual(decoded.limit, 100)
    }

    /// Legacy caches without showsUsedLevel decode to false (default remaining semantics, backward-compatible)
    func testDecodesLegacyCacheWithoutShowsUsedLevel() throws {
        // Arrange: legacy JSON without the field
        let json = #"{"id":"volcano.5h","type":"timeWindowed","label":"5h","unit":"credits","used":12.5,"limit":50}"#

        // Act
        let decoded = try JSONDecoder().decode(Quota.self, from: Data(json.utf8))

        // Assert
        XCTAssertFalse(decoded.showsUsedLevel)
        XCTAssertEqual(decoded.percentUsed, 0.25)
    }
}
