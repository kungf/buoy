import XCTest
@testable import TokenRunwayCore

final class BurnRateEstimatorTests: XCTestCase {
    private let estimator = BurnRateEstimator(minSamples: 3)
    private let poll: TimeInterval = 120 // 2 min
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func samples(_ values: [Double], step: TimeInterval = 120) -> [UsageSample] {
        values.enumerated().map { UsageSample(at: t0.addingTimeInterval(Double($0) * step), used: $1) }
    }

    func testSteadyBurnRate() {
        // Arrange：每分钟 +1（= 每 120s +2）
        let s = samples([0, 2, 4, 6, 8])

        // Act
        let rate = estimator.burnRate(samples: s, pollInterval: poll)

        // Assert
        XCTAssertEqual(rate ?? 0, 1.0 / 60.0, accuracy: 1e-9)
    }

    func testColdStartReturnsNil() {
        XCTAssertNil(estimator.burnRate(samples: samples([0, 2]), pollInterval: poll))
        XCTAssertNil(estimator.burnRate(samples: [], pollInterval: poll))
    }

    func testResetBoundaryDiscardsOldSegment() {
        // Arrange：先烧到 10，reset 跳回 0 后重新积累
        let s = samples([4, 6, 8, 10, 0, 2, 4])

        // Act
        let rate = estimator.burnRate(samples: s, pollInterval: poll)

        // Assert：只用 reset 后的 [0, 2, 4]，斜率仍为每分钟 1
        XCTAssertEqual(rate ?? 0, 1.0 / 60.0, accuracy: 1e-9)
    }

    func testSleepGapSplitsSegment() {
        // Arrange：前 3 点正常，然后一个 20 分钟空洞（>3×轮询），再 3 点
        var s = samples([0, 2, 4])
        s.append(UsageSample(at: t0.addingTimeInterval(2 * 120 + 1200), used: 10))
        s.append(UsageSample(at: t0.addingTimeInterval(2 * 120 + 1320), used: 12))
        s.append(UsageSample(at: t0.addingTimeInterval(2 * 120 + 1440), used: 14))

        // Act
        let rate = estimator.burnRate(samples: s, pollInterval: poll)

        // Assert：只用空洞后的 [10, 12, 14]
        XCTAssertEqual(rate ?? 0, 1.0 / 60.0, accuracy: 1e-9)
    }

    func testETAComputedFromRemaining() {
        // Arrange：每分钟 1 点，剩 300 点 -> 300 分钟 = 18000s
        let s = samples([0, 2, 4, 6])

        // Act
        let eta = estimator.eta(remaining: 300, samples: s, pollInterval: poll)

        // Assert
        XCTAssertEqual(eta ?? 0, 18_000, accuracy: 1)
    }

    func testZeroBurnReturnsNilRate() {
        XCTAssertNil(estimator.burnRate(samples: samples([5, 5, 5, 5]), pollInterval: poll))
    }
}
