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

    // MARK: Codable（showsUsedLevel 缓存往返）

    /// 回归：带默认值的 let 属性被合成解码器静默忽略——used 语义的水位方向
    /// 必须经 cache.json 往返保留，否则重启后回退成剩余语义
    func testShowsUsedLevelSurvivesCodableRoundtrip() throws {
        // Arrange
        let q = Quota(id: "custom-1.main", type: .timeWindowed, label: "用量",
                      unit: .tokens, used: 80, limit: 100, showsUsedLevel: true)

        // Act
        let data = try JSONEncoder().encode(q)
        let decoded = try JSONDecoder().decode(Quota.self, from: data)

        // Assert
        XCTAssertTrue(decoded.showsUsedLevel, "used 语义水位方向必须保留")
        XCTAssertEqual(decoded.used, 80)
        XCTAssertEqual(decoded.limit, 100)
    }

    /// 旧缓存无 showsUsedLevel 字段 → 解码为 false（默认剩余语义，向后兼容）
    func testDecodesLegacyCacheWithoutShowsUsedLevel() throws {
        // Arrange：旧格式 JSON（无该字段）
        let json = #"{"id":"volcano.5h","type":"timeWindowed","label":"5h","unit":"credits","used":12.5,"limit":50}"#

        // Act
        let decoded = try JSONDecoder().decode(Quota.self, from: Data(json.utf8))

        // Assert
        XCTAssertFalse(decoded.showsUsedLevel)
        XCTAssertEqual(decoded.percentUsed, 0.25)
    }
}
