import XCTest
@testable import TokenRunwayCore

// MARK: - BackoffPolicy

final class BackoffPolicyTests: XCTestCase {
    private let policy = BackoffPolicy()

    func testNoFailureReturnsBase() {
        XCTAssertEqual(policy.delay(base: 120, afterFailures: 0), 120, accuracy: 1e-9)
    }

    func testExponentialGrowth() {
        // 120 * 2^2 = 480
        XCTAssertEqual(policy.delay(base: 120, afterFailures: 2), 480, accuracy: 1e-9)
    }

    func testCappedAtMaxMultiplier() {
        // 120 * min(2^10, 5) = 120 * 5 = 600
        XCTAssertEqual(policy.delay(base: 120, afterFailures: 10), 600, accuracy: 1e-9)
    }

    func testErrorStateThreshold() {
        XCTAssertFalse(policy.isErrorState(afterFailures: 4))
        XCTAssertTrue(policy.isErrorState(afterFailures: 5))
    }
}

// MARK: - CacheStore

final class CacheStoreTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trwy-cache-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    func testRoundTripPreservesReportsAndForecast() {
        // Arrange
        let report = ProviderReport(
            providerId: "deepseek",
            fetchedAt: Date(timeIntervalSince1970: 1_000_000),
            quotas: [Quota(id: "deepseek.balance", type: .balance, label: "余额", unit: .cny, remaining: 1.25)])
        let cache = TokenRunwayCache(reports: [report], forecast: ForecastEngine())

        // Act
        CacheStore.save(cache, to: tempURL)
        let loaded = CacheStore.load(from: tempURL)

        // Assert
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.reports, cache.reports)
        XCTAssertEqual(loaded?.forecast, cache.forecast)
    }

    func testLoadReturnsNilForMissingFile() {
        XCTAssertNil(CacheStore.load(from: tempURL))
    }
}
