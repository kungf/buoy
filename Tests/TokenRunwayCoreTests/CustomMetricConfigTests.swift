import XCTest
@testable import TokenRunwayCore

/// CustomMetricConfig: label parsing and PromQL query building for user-defined metrics.
final class CustomMetricConfigTests: XCTestCase {

    private func makeConfig(label: String = "", metric: String = "api_budget_usage") -> CustomMetricConfig {
        CustomMetricConfig(name: "本月 API 预算", baseURL: "http://prom.internal:9090",
                           metric: metric, label: label)
    }

    // MARK: labelPairs

    func testLabelPairsParsesSinglePair() throws {
        // Arrange
        let config = makeConfig(label: "team=data")

        // Act
        let pairs = try XCTUnwrap(config.labelPairs)

        // Assert
        XCTAssertEqual(pairs.map(\.key), ["team"])
        XCTAssertEqual(pairs.map(\.value), ["data"])
    }

    func testLabelPairsParsesMultiplePairs() throws {
        // Arrange
        let config = makeConfig(label: "team=data,env=prod")

        // Act
        let pairs = try XCTUnwrap(config.labelPairs)

        // Assert
        XCTAssertEqual(pairs.map(\.key), ["team", "env"])
        XCTAssertEqual(pairs.map(\.value), ["data", "prod"])
    }

    func testLabelPairsTrimsWhitespace() throws {
        // Arrange
        let config = makeConfig(label: " team = data , env = prod ")

        // Act
        let pairs = try XCTUnwrap(config.labelPairs)

        // Assert
        XCTAssertEqual(pairs.map(\.key), ["team", "env"])
        XCTAssertEqual(pairs.map(\.value), ["data", "prod"])
    }

    func testLabelPairsEmptyLabelIsEmptyArray() {
        // Arrange / Act
        let pairs = makeConfig(label: "").labelPairs

        // Assert
        XCTAssertEqual(pairs?.count, 0)
    }

    /// Malformed labels (missing =, empty key/value, empty segments) must return nil so the
    /// fetch layer errors instead of silently dropping labels. "team==data" is legal: values
    /// may be any string (=data) and are not rejected.
    func testLabelPairsRejectsMalformedPairs() {
        // Arrange / Act / Assert
        for bad in ["team", "=data", "team=", "a=b,", ",a=b", "a=b,,c=d"] {
            let config = makeConfig(label: bad)
            XCTAssertNil(config.labelPairs, "should reject malformed label: \(bad)")
        }
    }

    /// `=` inside a value is preserved (maxSplits=1 splits at the first =)
    func testLabelPairsKeepsEqualsInsideValue() throws {
        // Arrange
        let config = makeConfig(label: "auth=basic=yes")

        // Act
        let pairs = try XCTUnwrap(config.labelPairs)

        // Assert
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].key, "auth")
        XCTAssertEqual(pairs[0].value, "basic=yes")
    }

    // MARK: query

    func testQueryWithoutLabelIsMetricAlone() {
        // Arrange / Act
        let query = makeConfig(label: "").query

        // Assert
        XCTAssertEqual(query, "api_budget_usage")
    }

    func testQueryAppendsBracedLabels() {
        // Arrange / Act
        let query = makeConfig(label: "team=data,env=prod").query

        // Assert
        XCTAssertEqual(query, #"api_budget_usage{team="data",env="prod"}"#)
    }

    func testQueryEscapesBackslashAndQuoteInLabelValue() {
        // Arrange / Act
        let query = makeConfig(label: #"bucket=a\b"c"#).query

        // Assert
        XCTAssertEqual(query, #"api_budget_usage{bucket="a\\b\"c"}"#)
    }

    func testQueryNilWhenLabelMalformed() {
        // Arrange / Act
        let query = makeConfig(label: "team").query

        // Assert
        XCTAssertNil(query)
    }

    func testQueryNilWhenMetricEmpty() {
        // Arrange / Act
        let query = makeConfig(metric: "  ").query

        // Assert
        XCTAssertNil(query)
    }

    // MARK: Codable

    func testCodableRoundtripPreservesAllFields() throws {
        // Arrange
        let config = CustomMetricConfig(id: "custom-1", name: "本月预算", baseURL: "http://prom:9090",
                                        metric: "sum(usage)", label: "team=data",
                                        max: 5000, unit: .cny, semantics: .remaining)

        // Act
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CustomMetricConfig.self, from: data)

        // Assert
        XCTAssertEqual(decoded, config)
    }

    func testDecodesMissingOptionalFields() throws {
        // Arrange: label is required (defaults to empty string), max/unit optional
        let json = #"{"id":"custom-1","name":"x","baseURL":"u","metric":"m","label":""}"#

        // Act
        let decoded = try JSONDecoder().decode(CustomMetricConfig.self, from: Data(json.utf8))

        // Assert
        XCTAssertEqual(decoded.label, "")
        XCTAssertNil(decoded.max)
        XCTAssertNil(decoded.unit)
        XCTAssertEqual(decoded.name, "x")
    }

    /// Legacy configs (no semantics field) default to .used — the default is a product decision
    func testDecodesLegacyConfigDefaultsToUsedSemantics() throws {
        // Arrange
        let json = #"{"id":"custom-1","name":"x","baseURL":"u","metric":"m","label":""}"#

        // Act
        let decoded = try JSONDecoder().decode(CustomMetricConfig.self, from: Data(json.utf8))

        // Assert
        XCTAssertEqual(decoded.semantics, .used)
    }

    func testNewConfigDefaultsToUsedSemantics() {
        // Act / Assert
        XCTAssertEqual(CustomMetricConfig(name: "x", baseURL: "u", metric: "m").semantics, .used)
    }

    func testNewInstanceGetsUniqueId() {
        // Arrange / Act
        let a = CustomMetricConfig(name: "x", baseURL: "u", metric: "m")
        let b = CustomMetricConfig(name: "x", baseURL: "u", metric: "m")

        // Assert: id is a stable persistence key (selection/ball-position state depends on it) — must be unique
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertFalse(a.id.isEmpty)
    }
}
