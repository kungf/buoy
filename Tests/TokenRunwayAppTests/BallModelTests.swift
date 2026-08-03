import XCTest
import TokenRunwayCore
@testable import TokenRunwayApp

/// Verifies the unified "used amount" display model and per-channel health coloring.
@MainActor
final class BallModelTests: XCTestCase {

    // MARK: Theme.healthColor thresholds

    func test_healthColor_greenWhenHealthy() {
        XCTAssertEqual(Theme.healthColor(0.9), .green)
        XCTAssertEqual(Theme.healthColor(0.5), .green)
    }

    func test_healthColor_orangeInMidRange() {
        XCTAssertEqual(Theme.healthColor(0.3), .orange)
        XCTAssertEqual(Theme.healthColor(0.2), .orange) // 0.2 is not < 0.2 -> orange
    }

    func test_healthColor_redWhenCritical() {
        XCTAssertEqual(Theme.healthColor(0.1), .red)
    }

    func test_healthColor_grayWhenUnknown() {
        XCTAssertEqual(Theme.healthColor(nil), .gray)
    }

    // MARK: ballModel via mock scenarios

    /// balanceHighWater persists to UserDefaults; clear those keys so a previous test run
    /// (same process or disk) can't skew the high-water-dependent assertions.
    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("trwy.balanceHighWater") {
            defaults.removeObject(forKey: key)
        }
    }

    private func store(scenario: String) -> UsageStore {
        let store = UsageStore()
        store.loadMockScenario(scenario)
        return store
    }

    func test_healthy_showsAllThreeChannels_lowWater_greenCore() {
        // 5h 1000/10000 = 10% used, 7d 5000/35000, 30d 20000/100000.
        let model = store(scenario: "healthy").ballModel(for: "volcano")
        XCTAssertEqual(model.mode, .windowed)
        XCTAssertEqual(model.ringUsed ?? -1, 0.2, accuracy: 0.001)            // 30d used
        XCTAssertEqual(model.midRingUsed ?? -1, 5000.0 / 35000.0, accuracy: 0.001) // 7d used
        // Liquid level = REMAINING % (drains as consumed) -> 90% -> HIGH water, near-full.
        XCTAssertEqual(model.coreLevel ?? -1, 0.9, accuracy: 0.001)
        XCTAssertEqual(model.centerText, "90%")
        // Core color is driven by remaining health (0.9) -> green, NOT by fast-burn state.
        XCTAssertEqual(model.coreHealth ?? -1, 0.9, accuracy: 0.001)
        XCTAssertEqual(Theme.healthColor(model.coreHealth), .green)
    }

    func test_critical_highWater_redCore() {
        // 5h 9500/10000 = 95% used -> 5% remaining water level.
        let model = store(scenario: "critical").ballModel(for: "volcano")
        XCTAssertEqual(model.coreLevel ?? -1, 0.05, accuracy: 0.001)
        XCTAssertEqual(model.centerText, "5%")
        XCTAssertEqual(model.coreHealth ?? -1, 0.05, accuracy: 0.001)
        XCTAssertEqual(Theme.healthColor(model.coreHealth), .red)
    }

    func test_balanceMode_singleChannel() {
        // balance-critical seeds a forecast so the balance ETA (and thus coreLevel) is non-nil.
        let model = store(scenario: "balance-critical").ballModel(for: "deepseek")
        XCTAssertEqual(model.mode, .balance)
        XCTAssertNil(model.ringUsed)
        XCTAssertNil(model.midRingUsed)
        XCTAssertNotNil(model.coreLevel)
        XCTAssertEqual(model.currencyBadge, "¥")
    }

    func test_nonPrimaryBallHasNoBadges() {
        // Badges live only on the primary (first selected) ball.
        let store = store(scenario: "healthy")
        store.addToSelection("deepseek") // selection becomes [volcano, deepseek]
        let secondary = store.ballModel(for: "deepseek")
        XCTAssertTrue(secondary.alertBadges.isEmpty)
    }

    // MARK: balance ball: last-5h spend + balance (ETA dropped)

    func test_balanceModel_showsSpendAndBalance_noETA() {
        // balance-critical seeds a declining series: remaining 3.5 -> 2.5 -> 1.5 -> 0.5.
        let model = store(scenario: "balance-critical").ballModel(for: "deepseek")
        XCTAssertEqual(model.mode, .balance)
        XCTAssertEqual(model.centerText, "0.50")           // balance (big, lower)
        XCTAssertEqual(model.spentRecentText, "−¥3.00")  // 5h spend (small, upper), no window label
        XCTAssertEqual(model.subText, "")                   // ETA dropped
        XCTAssertEqual(model.currencyBadge, "¥")
    }

    func test_balanceModel_breathIsConsumedOverRemaining() {
        // consumed 3.0 / remaining 0.5 = 6.0 -> clamped to 1.0 (urgent, explosion-free).
        let model = store(scenario: "balance-critical").ballModel(for: "deepseek")
        XCTAssertEqual(model.breathUrgency, 1.0, accuracy: 1e-9)
    }

    func test_balanceModel_coreLevelIsRemainingOverHighWater() {
        // remaining 0.5 / highWater 3.5 -> liquid level decoupled from breathing.
        let model = store(scenario: "balance-critical").ballModel(for: "deepseek")
        XCTAssertEqual(model.coreLevel ?? -1, 0.5 / 3.5, accuracy: 1e-9)
        XCTAssertEqual(model.coreHealth ?? -1, 0.5 / 3.5, accuracy: 1e-9)
    }

    func test_balanceModel_topUpReanchor_notUndoneByOldPeak() {
        // Regression for the HIGH finding in code review: after a top-up re-anchors the
        // high-water to the new balance, a later render must NOT pull the old sample-buffer
        // peak (42.50) back in via max(persisted, -minUsed) — the water level stays full.
        let store = UsageStore()
        let now = Date()
        func report(remaining: Double, at: Date) -> ProviderReport {
            ProviderReport(providerId: "deepseek", fetchedAt: at,
                           quotas: [Quota(id: "deepseek.balance", type: .balance,
                                          label: "账户余额", unit: .cny,
                                          used: -remaining, remaining: remaining)],
                           balance: BalanceInfo(currency: "CNY", total: remaining,
                                                granted: 0, toppedUp: remaining))
        }
        // Historical peak 42.50, then a crash (grant expiry) to 8.00 — old samples remain.
        store.installDemoReport(report(remaining: 42.50, at: now.addingTimeInterval(-4 * 3600)))
        store.installDemoReport(report(remaining: 8.00, at: now))
        XCTAssertEqual(store.ballModel(for: "deepseek").coreLevel ?? -1, 8.0 / 42.5,
                       accuracy: 1e-9) // low water after the crash

        // Top-up to 20.00 (2.5x jump vs. last observed 8.00) -> re-anchor, reads full.
        store.installDemoReport(report(remaining: 20.00, at: now.addingTimeInterval(1)))
        XCTAssertEqual(store.ballModel(for: "deepseek").coreLevel ?? -1, 1.0, accuracy: 1e-9)

        // A subsequent render must stay full despite the old 42.50 peak in the buffer.
        XCTAssertEqual(store.ballModel(for: "deepseek").coreLevel ?? -1, 1.0, accuracy: 1e-9)
    }

    func test_balanceModel_staticBalance_calmBreath_dashSpend() {
        // healthy: deepseek balance is static (no forecast samples) -> calm, dash, full liquid.
        let model = store(scenario: "healthy").ballModel(for: "deepseek")
        XCTAssertEqual(model.mode, .balance)
        XCTAssertEqual(model.breathUrgency, 0.0, accuracy: 1e-9)
        XCTAssertEqual(model.spentRecentText, "--")
        XCTAssertEqual(model.coreLevel ?? -1, 1.0, accuracy: 1e-9)
    }
}
