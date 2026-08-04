import XCTest
@testable import TokenRunwayCore

/// CustomMetricConfig: user-defined metric config for the output-contract HTTP adapter.
/// Covers URL construction (sourceURL), shape mapping (makeReport), Codable round-trips
/// and legacy-config tolerance.
final class CustomMetricConfigTests: XCTestCase {

    private func makeConfig(url: String = "https://api.corp.com/v1/usage", userId: String = "wyang",
                            max: Double? = nil, unit: TokenRunwayCore.Unit? = nil,
                            semantics: MetricSemantics = .used) -> CustomMetricConfig {
        CustomMetricConfig(id: "custom-1", name: "GPU 配额",
                           url: url, userId: userId, max: max, unit: unit, semantics: semantics)
    }

    // MARK: sourceURL

    func testSourceURLReplacesUserIdPlaceholder() {
        // Arrange: RESTful path with {userId} placeholder
        let config = makeConfig(url: "https://api.corp.com/v1/users/{userId}/usage")

        // Act / Assert
        XCTAssertEqual(config.sourceURL, "https://api.corp.com/v1/users/wyang/usage")
    }

    func testSourceURLPercentEncodesUserIdInPlaceholder() {
        // Arrange: user id with reserved characters must not break the URL
        let config = makeConfig(url: "https://api.corp.com/v1/users/{userId}/usage", userId: "a b&c")

        // Act / Assert
        XCTAssertEqual(config.sourceURL, "https://api.corp.com/v1/users/a%20b%26c/usage")
    }

    func testSourceURLAppendsUserIdQueryWhenNoPlaceholder() {
        // Act / Assert
        XCTAssertEqual(makeConfig().sourceURL, "https://api.corp.com/v1/usage?user_id=wyang")
    }

    func testSourceURLAppendsUserIdToExistingQuery() {
        // Arrange: URL already carries query params → user_id joins with &
        let config = makeConfig(url: "https://api.corp.com/v1/usage?team=data")

        // Act / Assert
        XCTAssertEqual(config.sourceURL, "https://api.corp.com/v1/usage?team=data&user_id=wyang")
    }

    func testSourceURLDoesNotDuplicateExistingUserIdQuery() {
        // Arrange: URL already has user_id (hand-edited config) → not appended twice
        let config = makeConfig(url: "https://api.corp.com/v1/usage?user_id=alice", userId: "bob")

        // Act / Assert
        XCTAssertEqual(config.sourceURL, "https://api.corp.com/v1/usage?user_id=alice")
    }

    func testSourceURLWithoutUserIdKeepsURLAsIs() {
        // Arrange
        let config = makeConfig(userId: "")

        // Act / Assert
        XCTAssertEqual(config.sourceURL, "https://api.corp.com/v1/usage")
    }

    /// Placeholder present but no user id configured → nil (config error; a bare placeholder
    /// would hit a dangling path like /users//usage)
    func testSourceURLPlaceholderWithoutUserIdReturnsNil() {
        // Arrange
        let config = makeConfig(url: "https://api.corp.com/v1/users/{userId}/usage", userId: "")

        // Act / Assert
        XCTAssertNil(config.sourceURL)
    }

    func testSourceURLNilWhenURLEmpty() {
        // Arrange
        let config = makeConfig(url: "")

        // Act / Assert
        XCTAssertNil(config.sourceURL)
    }

    /// Regression (code review): "+" must be strictly encoded in the query-param path too —
    /// form-urlencoded backends decode "+" as a space, which would resolve the wrong identity
    /// (e.g. "alice+ops@corp.com" → "alice ops@corp.com")
    func testSourceURLPercentEncodesPlusInQueryParam() {
        // Arrange
        let config = makeConfig(userId: "alice+ops@corp.com")

        // Act / Assert
        XCTAssertEqual(config.sourceURL,
                       "https://api.corp.com/v1/usage?user_id=alice%2Bops%40corp.com")
    }

    /// Regression (code review): percentEncodedQueryItems must not re-normalize the user's
    /// pre-encoded query (signed URLs / opaque query backends rely on it)
    func testSourceURLKeepsConfiguredQueryEncoding() {
        // Arrange
        let config = makeConfig(url: "https://api.corp.com/v1/usage?team=dev%2Fops")

        // Act / Assert
        XCTAssertEqual(config.sourceURL,
                       "https://api.corp.com/v1/usage?team=dev%2Fops&user_id=wyang")
    }

    // MARK: Codable

    func testCodableRoundtripPreservesAllFields() throws {
        // Arrange
        let config = makeConfig(max: 5000, unit: .cny, semantics: .remaining)

        // Act
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CustomMetricConfig.self, from: data)

        // Assert
        XCTAssertEqual(decoded, config)
    }

    func testDecodesMissingOptionalFields() throws {
        // Arrange: userId/max/unit/semantics all optional
        let json = #"{"id":"custom-1","name":"x","url":"u"}"#

        // Act
        let decoded = try JSONDecoder().decode(CustomMetricConfig.self, from: Data(json.utf8))

        // Assert
        XCTAssertEqual(decoded.userId, "")
        XCTAssertNil(decoded.max)
        XCTAssertNil(decoded.unit)
        XCTAssertEqual(decoded.semantics, .used)
    }

    /// Legacy prometheus-source configs carry baseURL/metric/label keys — ignored (decoded
    /// with an empty url, failing the fetch with "missing url"); a stale key must not
    /// poison the whole config.json decode
    func testDecodesLegacyPrometheusConfigTolerantly() throws {
        // Arrange
        let json = #"{"id":"custom-1","name":"x","baseURL":"http://prom:9090","metric":"m","label":"team=a"}"#

        // Act
        let decoded = try JSONDecoder().decode(CustomMetricConfig.self, from: Data(json.utf8))

        // Assert
        XCTAssertEqual(decoded.url, "")
        XCTAssertEqual(decoded.semantics, .used)
    }

    func testNewConfigDefaultsToUsedSemantics() {
        // Act / Assert
        XCTAssertEqual(CustomMetricConfig(name: "x", url: "u").semantics, .used)
    }

    func testNewInstanceGetsUniqueId() {
        // Arrange / Act
        let a = CustomMetricConfig(name: "x", url: "u")
        let b = CustomMetricConfig(name: "x", url: "u")

        // Assert: id is a stable persistence key (selection/ball-position state depends on it) — must be unique
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertFalse(a.id.isEmpty)
    }

    // MARK: makeReport (shared shape mapping)

    /// label override applies to all four shapes (used by the adapter's output label)
    func testMakeReportOverridesLabel() throws {
        // Arrange
        let config = makeConfig(max: 5000)

        // Act
        let report = config.makeReport(value: 100, label: "动态名称")

        // Assert
        XCTAssertEqual(report.quotas[0].label, "动态名称")
    }
}
