import XCTest
@testable import BuoyCore

final class BallStateTests: XCTestCase {
    // MARK: - error / stale 优先

    func testErrorWhenHasError() {
        let state = BallStateResolver.resolve(health: 0.9, burnRate: nil,
                                              expectedBurnRate: nil, hasError: true, isStale: false)
        XCTAssertEqual(state, .error)
    }

    func testErrorWhenStaleEvenWithGoodHealth() {
        let state = BallStateResolver.resolve(health: 0.9, burnRate: nil,
                                              expectedBurnRate: nil, hasError: false, isStale: true)
        XCTAssertEqual(state, .error)
    }

    func testErrorPrecedenceOverDepleted() {
        let state = BallStateResolver.resolve(health: 0.01, burnRate: nil,
                                              expectedBurnRate: nil, hasError: true, isStale: false)
        XCTAssertEqual(state, .error)
    }

    // MARK: - 冷启动 / idle

    func testIdleWhenHealthUnknown() {
        let state = BallStateResolver.resolve(health: nil, burnRate: nil,
                                              expectedBurnRate: nil, hasError: false, isStale: false)
        XCTAssertEqual(state, .idle)
    }

    func testIdleWhenHealthyAndNoSpike() {
        let state = BallStateResolver.resolve(health: 0.8, burnRate: 1,
                                              expectedBurnRate: 1, hasError: false, isStale: false)
        XCTAssertEqual(state, .idle)
    }

    // MARK: - depleted / nearDepleted

    func testDepletedBelowThreshold() {
        let state = BallStateResolver.resolve(health: 0.03, burnRate: nil,
                                              expectedBurnRate: nil, hasError: false, isStale: false)
        XCTAssertEqual(state, .depleted)
    }

    func testNearDepletedBetweenThresholds() {
        let state = BallStateResolver.resolve(health: 0.1, burnRate: nil,
                                              expectedBurnRate: nil, hasError: false, isStale: false)
        XCTAssertEqual(state, .nearDepleted)
    }

    func testNearDepletedPrecedenceOverFastBurn() {
        // health<0.15 但燃烧率突增 -> 临近耗尽优先（级别 > 速率）
        let state = BallStateResolver.resolve(health: 0.1, burnRate: 100,
                                              expectedBurnRate: 1, hasError: false, isStale: false)
        XCTAssertEqual(state, .nearDepleted)
    }

    // MARK: - fastBurn

    func testFastBurnWhenRateSpikesAtMidHealth() {
        // 实际 3× 期望，health 0.3 -> fast-burn（而非 consuming）
        let state = BallStateResolver.resolve(health: 0.3, burnRate: 30,
                                              expectedBurnRate: 10, hasError: false, isStale: false)
        XCTAssertEqual(state, .fastBurn)
    }

    func testFastBurnEvenWhenHealthy() {
        // health 充裕但速率突增 -> 仍提示 fast-burn
        let state = BallStateResolver.resolve(health: 0.9, burnRate: 30,
                                              expectedBurnRate: 10, hasError: false, isStale: false)
        XCTAssertEqual(state, .fastBurn)
    }

    func testNoFastBurnBelowMultiplier() {
        // 1.5× 未达 2× 阈值 -> consuming（health 0.3）
        let state = BallStateResolver.resolve(health: 0.3, burnRate: 15,
                                              expectedBurnRate: 10, hasError: false, isStale: false)
        XCTAssertEqual(state, .consuming)
    }

    func testNoFastBurnForBalanceWithoutExpectedRate() {
        // balance 型无 expectedBurnRate -> 不触发 fast-burn，按 health 走 consuming
        let state = BallStateResolver.resolve(health: 0.3, burnRate: 5,
                                              expectedBurnRate: nil, hasError: false, isStale: false)
        XCTAssertEqual(state, .consuming)
    }

    // MARK: - consuming

    func testConsumingBetweenNearDepletedAndIdle() {
        let state = BallStateResolver.resolve(health: 0.4, burnRate: nil,
                                              expectedBurnRate: nil, hasError: false, isStale: false)
        XCTAssertEqual(state, .consuming)
    }

    // MARK: - 边界

    func testBoundaryExactlyNearDepletedThresholdIsConsuming() {
        // health == 0.15 不满足 < 0.15 -> 非 nearDepleted
        let state = BallStateResolver.resolve(health: 0.15, burnRate: nil,
                                              expectedBurnRate: nil, hasError: false, isStale: false)
        XCTAssertEqual(state, .consuming)
    }

    func testBoundaryExactlyDepletedThresholdIsNearDepleted() {
        // health == 0.05 不满足 < 0.05 -> 非 depleted，落入 nearDepleted
        let state = BallStateResolver.resolve(health: 0.05, burnRate: nil,
                                              expectedBurnRate: nil, hasError: false, isStale: false)
        XCTAssertEqual(state, .nearDepleted)
    }

    func testZeroExpectedRateNeverFastBurn() {
        // expectedBurnRate <= 0 不触发 fast-burn（避免除零 / 无意义比较）
        let state = BallStateResolver.resolve(health: 0.3, burnRate: 100,
                                              expectedBurnRate: 0, hasError: false, isStale: false)
        XCTAssertEqual(state, .consuming)
    }
}
