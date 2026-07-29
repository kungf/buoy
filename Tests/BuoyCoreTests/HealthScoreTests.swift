import XCTest
@testable import BuoyCore

final class HealthScoreTests: XCTestCase {
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
}
