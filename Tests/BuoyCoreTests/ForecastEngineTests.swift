import XCTest
@testable import BuoyCore

final class ForecastEngineTests: XCTestCase {
    private let poll: TimeInterval = 120
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func windowedReport(used: Double, limit: Double = 10_000, at: Date) -> ProviderReport {
        ProviderReport(providerId: "volcano", fetchedAt: at, quotas: [
            Quota(id: "volcano.5h", type: .timeWindowed, label: "5h", unit: .credits,
                  used: used, limit: limit, resetsAt: at.addingTimeInterval(2 * 3600))
        ])
    }

    private func balanceReport(remaining: Double, at: Date) -> ProviderReport {
        ProviderReport(providerId: "deepseek", fetchedAt: at, quotas: [
            Quota(id: "deepseek.balance", type: .balance, label: "余额", unit: .cny, remaining: remaining)
        ])
    }

    // MARK: windowed

    func testWindowedETAComputedFromBurnRate() {
        // Arrange：每 120s used +2 -> 燃烧率 1/min = 1/60 per sec
        var engine = ForecastEngine()
        engine.ingest(report: windowedReport(used: 1000, at: t0), pollInterval: poll)
        engine.ingest(report: windowedReport(used: 1002, at: t0.addingTimeInterval(120)), pollInterval: poll)
        engine.ingest(report: windowedReport(used: 1004, at: t0.addingTimeInterval(240)), pollInterval: poll)
        engine.ingest(report: windowedReport(used: 1006, at: t0.addingTimeInterval(360)), pollInterval: poll)

        // Act：remaining = 10000 - 1006 = 8994；ETA = 8994 / (1/60) = 539640s
        let quota = Quota(id: "volcano.5h", type: .timeWindowed, label: "5h", unit: .credits,
                          used: 1006, limit: 10_000)
        let eta = engine.eta(for: quota, pollInterval: poll)

        // Assert
        XCTAssertEqual(eta ?? 0, 539_640, accuracy: 1)
    }

    func testColdStartReturnsNilETA() {
        var engine = ForecastEngine()
        engine.ingest(report: windowedReport(used: 100, at: t0), pollInterval: poll)
        engine.ingest(report: windowedReport(used: 102, at: t0.addingTimeInterval(120)), pollInterval: poll)

        let quota = Quota(id: "volcano.5h", type: .timeWindowed, label: "5h", unit: .credits,
                          used: 102, limit: 10_000)
        XCTAssertNil(engine.eta(for: quota, pollInterval: poll)) // < minSamples(3)
    }

    // MARK: ring buffer

    func testRingBufferCapsSamples() {
        // Arrange
        var engine = ForecastEngine(maxSamplesPerQuota: 3)
        for i in 0..<5 {
            engine.ingest(report: windowedReport(used: Double(i),
                                                 at: t0.addingTimeInterval(Double(i) * 120)),
                          pollInterval: poll)
        }

        // Act：仅保留最近 3 个（used 2/3/4）
        let samples = engine.samples(for: "volcano.5h")

        // Assert
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples.first?.used, 2)
        XCTAssertEqual(samples.last?.used, 4)
    }

    // MARK: balance（-remaining 代理量）

    func testBalanceETAFromDecliningRemaining() {
        // Arrange：remaining 100->94，每 120s -2 -> 燃烧率 1/60 per sec
        var engine = ForecastEngine()
        engine.ingest(report: balanceReport(remaining: 100, at: t0), pollInterval: poll)
        engine.ingest(report: balanceReport(remaining: 98, at: t0.addingTimeInterval(120)), pollInterval: poll)
        engine.ingest(report: balanceReport(remaining: 96, at: t0.addingTimeInterval(240)), pollInterval: poll)
        engine.ingest(report: balanceReport(remaining: 94, at: t0.addingTimeInterval(360)), pollInterval: poll)

        // Act：ETA = 94 / (1/60) = 5640s
        let quota = Quota(id: "deepseek.balance", type: .balance, label: "余额", unit: .cny, remaining: 94)
        let eta = engine.eta(for: quota, pollInterval: poll)

        // Assert
        XCTAssertEqual(eta ?? 0, 5_640, accuracy: 1)
    }

    func testTopUpBreaksSegmentAndResetsBaseline() {
        // Arrange：先消耗 4 点建立基线
        var engine = ForecastEngine()
        engine.ingest(report: balanceReport(remaining: 100, at: t0), pollInterval: poll)
        engine.ingest(report: balanceReport(remaining: 98, at: t0.addingTimeInterval(120)), pollInterval: poll)
        engine.ingest(report: balanceReport(remaining: 96, at: t0.addingTimeInterval(240)), pollInterval: poll)
        engine.ingest(report: balanceReport(remaining: 94, at: t0.addingTimeInterval(360)), pollInterval: poll)

        // 充值：remaining 跳升到 200 -> -remaining 回落 -> 触发断段
        engine.ingest(report: balanceReport(remaining: 200, at: t0.addingTimeInterval(480)), pollInterval: poll)

        // Assert：断段后新段仅 1 点 -> 冷启动 -> ETA nil
        let quota = Quota(id: "deepseek.balance", type: .balance, label: "余额", unit: .cny, remaining: 200)
        XCTAssertNil(engine.eta(for: quota, pollInterval: poll))

        // Act：再积累 2 点（新段共 3 点）
        engine.ingest(report: balanceReport(remaining: 198, at: t0.addingTimeInterval(600)), pollInterval: poll)
        engine.ingest(report: balanceReport(remaining: 196, at: t0.addingTimeInterval(720)), pollInterval: poll)

        // 新段斜率 1/60；当前 remaining=196 -> ETA = 196*60 = 11760
        let current = Quota(id: "deepseek.balance", type: .balance, label: "余额", unit: .cny, remaining: 196)
        let eta = engine.eta(for: current, pollInterval: poll)

        // Assert：基线已重置，不再受充值前旧段影响
        XCTAssertEqual(eta ?? 0, 11_760, accuracy: 1)
    }

    // MARK: rateLimit 不追踪

    func testRateLimitQuotaNotTracked() {
        var engine = ForecastEngine()
        let report = ProviderReport(providerId: "x", fetchedAt: t0, quotas: [
            Quota(id: "x.rpm", type: .rateLimit, label: "rpm", unit: .tokens, used: 10, limit: 100)
        ])
        engine.ingest(report: report, pollInterval: poll)

        XCTAssertTrue(engine.samples(for: "x.rpm").isEmpty)
    }

    // MARK: - consumed (5h window spend, top-up-robust)

    private let fiveHours: TimeInterval = 5 * 3600

    private func balanceQuota(_ remaining: Double) -> Quota {
        Quota(id: "deepseek.balance", type: .balance, label: "balance", unit: .cny, remaining: remaining)
    }

    func testConsumedSteadyAccumulation() {
        // Arrange: remaining 100->98->96->94, -2 every 120s
        var engine = ForecastEngine()
        engine.ingest(report: balanceReport(remaining: 100, at: t0), pollInterval: poll)
        engine.ingest(report: balanceReport(remaining: 98, at: t0.addingTimeInterval(120)), pollInterval: poll)
        engine.ingest(report: balanceReport(remaining: 96, at: t0.addingTimeInterval(240)), pollInterval: poll)
        engine.ingest(report: balanceReport(remaining: 94, at: t0.addingTimeInterval(360)), pollInterval: poll)

        // Act: spent = 2 + 2 + 2 = 6
        let consumed = engine.consumed(for: balanceQuota(94), windowSeconds: fiveHours, now: t0.addingTimeInterval(360))

        // Assert
        XCTAssertEqual(consumed ?? 0, 6, accuracy: 1e-9)
    }

    func testConsumedTopUpIgnored() {
        // Arrange: spend 100->98->96, top up to 200, spend to 198
        var engine = ForecastEngine()
        engine.ingest(report: balanceReport(remaining: 100, at: t0), pollInterval: poll)
        engine.ingest(report: balanceReport(remaining: 98, at: t0.addingTimeInterval(120)), pollInterval: poll)
        engine.ingest(report: balanceReport(remaining: 96, at: t0.addingTimeInterval(240)), pollInterval: poll)
        engine.ingest(report: balanceReport(remaining: 200, at: t0.addingTimeInterval(360)), pollInterval: poll)
        engine.ingest(report: balanceReport(remaining: 198, at: t0.addingTimeInterval(480)), pollInterval: poll)

        // Act: spent = 2 + 2 + 0 (top-up) + 2 = 6 (top-up does not pollute)
        let consumed = engine.consumed(for: balanceQuota(198), windowSeconds: fiveHours, now: t0.addingTimeInterval(480))

        // Assert
        XCTAssertEqual(consumed ?? 0, 6, accuracy: 1e-9)
    }

    func testConsumedFlatReturnsZero() {
        // Arrange: balance unchanged across samples
        var engine = ForecastEngine()
        for i in 0..<4 {
            engine.ingest(report: balanceReport(remaining: 100, at: t0.addingTimeInterval(Double(i) * 120)),
                          pollInterval: poll)
        }

        // Act
        let consumed = engine.consumed(for: balanceQuota(100), windowSeconds: fiveHours, now: t0.addingTimeInterval(360))

        // Assert: samples present but no spend -> 0 (not nil)
        XCTAssertEqual(consumed ?? -1, 0, accuracy: 1e-9)
    }

    func testConsumedInsufficientSamplesReturnsNil() {
        // Arrange: only one sample
        var engine = ForecastEngine()
        engine.ingest(report: balanceReport(remaining: 100, at: t0), pollInterval: poll)

        // Act
        let consumed = engine.consumed(for: balanceQuota(100), windowSeconds: fiveHours, now: t0)

        // Assert
        XCTAssertNil(consumed)
    }

    func testConsumedExcludesSamplesOutsideWindow() {
        // Arrange: early samples fall outside the 5h window; only the latest pair is inside
        var engine = ForecastEngine()
        engine.ingest(report: balanceReport(remaining: 100, at: t0), pollInterval: poll)
        engine.ingest(report: balanceReport(remaining: 98, at: t0.addingTimeInterval(120)), pollInterval: poll)
        engine.ingest(report: balanceReport(remaining: 96, at: t0.addingTimeInterval(240)), pollInterval: poll)
        // A fresh pair 6h later
        let late = t0.addingTimeInterval(6 * 3600)
        engine.ingest(report: balanceReport(remaining: 94, at: late), pollInterval: poll)
        engine.ingest(report: balanceReport(remaining: 92, at: late.addingTimeInterval(120)), pollInterval: poll)

        // Act: now at the last sample; 5h window holds only 94/92 -> spent = 2
        let consumed = engine.consumed(for: balanceQuota(92), windowSeconds: fiveHours, now: late.addingTimeInterval(120))

        // Assert
        XCTAssertEqual(consumed ?? 0, 2, accuracy: 1e-9)
    }
}
