import XCTest
@testable import TokenRunwayCore

/// CustomMetricsProvider: output-contract HTTP adapter.
/// parse goes through the static method; fetch uses a programmable StubHTTPClient.
final class CustomMetricsProviderTests: XCTestCase {

    /// Programmable HTTPClient: records requests, returns preset responses
    actor StubHTTPClient: HTTPClient {
        private var responses: [HTTPResponse]
        private(set) var requests: [URLRequest] = []

        init(responses: [HTTPResponse] = []) { self.responses = responses }

        func send(_ request: URLRequest) async throws -> HTTPResponse {
            requests.append(request)
            XCTAssertFalse(responses.isEmpty, "unexpected HTTP call: \(request.url?.absoluteString ?? "?")")
            return responses.isEmpty ? HTTPResponse(status: 500, data: Data()) : responses.removeFirst()
        }
    }

    // Foundation also has Unit (NSUnit) — qualify with the module in the test target
    private typealias QuotaUnit = TokenRunwayCore.Unit

    private func makeConfig(max: Double? = nil, unit: QuotaUnit? = nil,
                            semantics: MetricSemantics = .used,
                            url: String = "https://api.corp.com/v1/usage",
                            userId: String = "") -> CustomMetricConfig {
        CustomMetricConfig(id: "custom-1", name: "GPU 配额",
                           url: url, userId: userId, max: max, unit: unit, semantics: semantics)
    }

    /// Renders {"key":value,...}; caller writes bare keys ("value:1234.5") for brevity
    private func output(_ fields: String...) -> Data {
        let rendered = fields.map { field in
            let parts = field.split(separator: ":", maxSplits: 1)
            return "\"\(parts[0])\":\(parts[1])"
        }.joined(separator: ",")
        return Data("{\(rendered)}".utf8)
    }

    // MARK: parse — value / shapes

    /// used + output max → used water (full = drained); output max wins over config
    func testParsesUsedWithOutputMaxAsTimeWindowed() throws {
        // Arrange
        let json = output(#"value:1234.5"#, #"max:5000"#)

        // Act
        let report = try CustomMetricsProvider.parse(data: json, config: makeConfig())

        // Assert
        XCTAssertEqual(report.providerId, "custom-1")
        let q = report.quotas[0]
        XCTAssertEqual(q.type, .timeWindowed)
        XCTAssertEqual(q.label, "GPU 配额")
        XCTAssertEqual(q.used, 1234.5)
        XCTAssertEqual(q.limit, 5000)
        XCTAssertEqual(try XCTUnwrap(q.percentUsed), 1234.5 / 5000, accuracy: 1e-9)
        XCTAssertTrue(q.showsUsedLevel, "used output must be used-direction water")
        XCTAssertNil(report.balance)
    }

    /// Missing optional output fields fall back to the config
    func testParsesFallsBackToConfigWhenOutputOmitsFields() throws {
        // Arrange: output only carries value; max/unit/semantics come from the config
        let json = output(#"value:4321.0"#)
        let config = makeConfig(max: 10000, unit: .cny, semantics: .remaining)

        // Act
        let report = try CustomMetricsProvider.parse(data: json, config: config)

        // Assert: remaining + max → remaining water
        let q = report.quotas[0]
        XCTAssertEqual(q.type, .timeWindowed)
        XCTAssertEqual(q.remaining, 4321)
        XCTAssertEqual(q.limit, 10000)
        XCTAssertEqual(q.unit, .cny)
        XCTAssertFalse(q.showsUsedLevel, "remaining water must be remaining-direction")
    }

    /// value as numeric string (gateways often stringify numbers)
    func testParsesStringValue() throws {
        // Arrange
        let json = output(#"value:"880.25""#)

        // Act
        let report = try CustomMetricsProvider.parse(data: json, config: makeConfig())

        // Assert
        XCTAssertEqual(report.quotas[0].used, 880.25)
    }

    /// used without max: plain value, no water
    func testParsesUsedWithoutMaxAsPlainValue() throws {
        // Arrange
        let json = output(#"value:880.25"#)

        // Act
        let report = try CustomMetricsProvider.parse(data: json, config: makeConfig())

        // Assert
        let q = report.quotas[0]
        XCTAssertEqual(q.used, 880.25)
        XCTAssertNil(q.limit)
        XCTAssertNil(q.percentUsed)
    }

    /// remaining without max: balance ball with BalanceInfo (currency from output unit)
    func testParsesRemainingAsBalanceBall() throws {
        // Arrange
        let json = output(#"value:88.5"#, #"semantics:"remaining""#, #"unit:"USD""#)

        // Act
        let report = try CustomMetricsProvider.parse(data: json, config: makeConfig())

        // Assert
        let q = report.quotas[0]
        XCTAssertEqual(q.type, .balance)
        XCTAssertEqual(q.remaining, 88.5)
        XCTAssertEqual(q.unit, .usd)
        XCTAssertNotNil(report.balance)
        XCTAssertEqual(report.balance?.currency, "USD")
    }

    // MARK: parse — output overrides

    /// output semantics overrides the config (config remaining + output "used" → used)
    func testOutputSemanticsOverridesConfig() throws {
        // Arrange
        let json = output(#"value:100"#, #"semantics:"used""#)

        // Act
        let report = try CustomMetricsProvider.parse(data: json, config: makeConfig(semantics: .remaining))

        // Assert: used shape, no BalanceInfo
        XCTAssertEqual(report.quotas[0].type, .timeWindowed)
        XCTAssertNil(report.balance)
    }

    func testOutputLabelOverridesName() throws {
        // Arrange
        let json = output(#"value:100"#, #"label:"动态名称""#)

        // Act
        let report = try CustomMetricsProvider.parse(data: json, config: makeConfig())

        // Assert
        XCTAssertEqual(report.quotas[0].label, "动态名称")
    }

    /// output unit overrides the config unit; known tokens map to fixed Unit cases
    func testOutputUnitOverridesConfig() throws {
        // Arrange
        let json = output(#"value:100"#, #"unit:"USD""#)

        // Act
        let report = try CustomMetricsProvider.parse(data: json, config: makeConfig(unit: .cny))

        // Assert
        XCTAssertEqual(report.quotas[0].unit, .usd)
    }

    /// output unit "none" clears the config unit
    func testOutputUnitNoneClearsUnit() throws {
        // Arrange
        let json = output(#"value:100"#, #"unit:"none""#)

        // Act
        let report = try CustomMetricsProvider.parse(data: json, config: makeConfig(unit: .cny))

        // Assert
        XCTAssertEqual(report.quotas[0].unit, .none)
    }

    /// unknown output unit → .custom (e.g. "GB")
    func testOutputUnknownUnitMapsToCustom() throws {
        // Arrange
        let json = output(#"value:100"#, #"unit:"GB""#)

        // Act
        let report = try CustomMetricsProvider.parse(data: json, config: makeConfig())

        // Assert
        XCTAssertEqual(report.quotas[0].unit, .custom("GB"))
    }

    /// output max <= 0 = no cap (same rule as the config path)
    func testOutputMaxZeroIgnored() throws {
        // Arrange
        let json = output(#"value:100"#, #"max:0"#)

        // Act
        let report = try CustomMetricsProvider.parse(data: json, config: makeConfig())

        // Assert
        XCTAssertNil(report.quotas[0].limit)
    }

    // MARK: parse — errors

    /// {"error": "..."} = business error; the free text must not leak into the message
    func testErrorFieldThrowsWithoutFreeText() {
        // Arrange
        let json = output(#"error:"internal detail must not leak""#)

        // Act / Assert
        XCTAssertThrowsError(try CustomMetricsProvider.parse(data: json, config: makeConfig())) { error in
            guard case ProviderError.parse(let msg) = error else {
                return XCTFail("expected parse error, got \(error)")
            }
            XCTAssertTrue(msg.contains("server error"), "unexpected message: \(msg)")
            XCTAssertFalse(msg.contains("must not leak"), "must not leak server free text: \(msg)")
        }
    }

    func testMissingValueThrows() {
        // Arrange: value is required
        let json = output(#"max:5000"#)

        // Act / Assert
        XCTAssertThrowsError(try CustomMetricsProvider.parse(data: json, config: makeConfig())) { error in
            guard case ProviderError.parse = error else {
                return XCTFail("expected parse error, got \(error)")
            }
        }
    }

    func testNonNumericValueThrows() {
        // Arrange: value "abc" is neither number nor numeric string
        let json = output(#"value:"abc""#)

        // Act / Assert
        XCTAssertThrowsError(try CustomMetricsProvider.parse(data: json, config: makeConfig()))
    }

    func testInvalidSemanticsThrows() {
        // Arrange
        let json = output(#"value:100"#, #"semantics:"spent""#)

        // Act / Assert
        XCTAssertThrowsError(try CustomMetricsProvider.parse(data: json, config: makeConfig())) { error in
            guard case ProviderError.parse(let msg) = error else {
                return XCTFail("expected parse error, got \(error)")
            }
            XCTAssertTrue(msg.contains("semantics"), "unexpected message: \(msg)")
        }
    }

    func testBadJSONThrows() {
        // Act / Assert
        XCTAssertThrowsError(try CustomMetricsProvider.parse(data: Data("not json".utf8),
                                                          config: makeConfig()))
    }

    // MARK: fetch (request shape)

    func testFetchReplacesUserIdPlaceholder() async throws {
        // Arrange: RESTful style
        let http = StubHTTPClient(responses: [HTTPResponse(status: 200, data: output(#"value:100"#))])
        let provider = CustomMetricsProvider(config: makeConfig(
            url: "https://api.corp.com/v1/users/{userId}/usage", userId: "wyang"), http: http)

        // Act
        _ = try await provider.fetchUsage(credential: .none)

        // Assert
        let request = await http.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://api.corp.com/v1/users/wyang/usage")
    }

    func testFetchAppendsUserIdQueryParam() async throws {
        // Arrange: query style
        let http = StubHTTPClient(responses: [HTTPResponse(status: 200, data: output(#"value:100"#))])
        let provider = CustomMetricsProvider(config: makeConfig(userId: "wyang"), http: http)

        // Act
        _ = try await provider.fetchUsage(credential: .none)

        // Assert
        let request = await http.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://api.corp.com/v1/usage?user_id=wyang")
    }

    func testFetchSendsBearerWhenCredentialProvided() async throws {
        // Arrange
        let http = StubHTTPClient(responses: [HTTPResponse(status: 200, data: output(#"value:100"#))])
        let provider = CustomMetricsProvider(config: makeConfig(), http: http)

        // Act
        _ = try await provider.fetchUsage(credential: .bearer("sekret"))

        // Assert
        let request = await http.requests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sekret")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testFetchMapsHTTPErrors() async throws {
        // Arrange: 401 → unauthorized; 429 → rateLimited
        for (status, expected) in [(401, ProviderError.unauthorized), (429, ProviderError.rateLimited)] {
            let http = StubHTTPClient(responses: [HTTPResponse(status: status, data: Data())])
            let provider = CustomMetricsProvider(config: makeConfig(), http: http)
            do {
                _ = try await provider.fetchUsage(credential: .none)
                XCTFail("expected error for status \(status)")
            } catch {
                XCTAssertEqual(error as? ProviderError, expected, "status \(status)")
            }
        }
    }

    func testFetchThrowsOnMissingURL() async {
        // Arrange: http config with an empty url → error before any request
        let http = StubHTTPClient()
        let provider = CustomMetricsProvider(config: makeConfig(url: ""), http: http)

        // Act / Assert
        do {
            _ = try await provider.fetchUsage(credential: .none)
            XCTFail("expected error")
        } catch {
            guard case ProviderError.parse = error else {
                return XCTFail("expected parse error, got \(error)")
            }
        }
        let count = await http.requests.count
        XCTAssertEqual(count, 0, "must not send a request for a missing url")
    }

    /// Manifest contract: same as the Prometheus adapter — allows no credential,
    /// displayName = the user-configured name, defaultBaseURL = the endpoint url
    func testManifestReflectsConfig() {
        // Arrange
        let provider = CustomMetricsProvider(config: makeConfig(userId: "wyang"))

        // Assert
        XCTAssertEqual(provider.manifest.id, "custom-1")
        XCTAssertEqual(provider.manifest.displayName, "GPU 配额")
        XCTAssertEqual(provider.manifest.defaultBaseURL, "https://api.corp.com/v1/usage")
        XCTAssertTrue(provider.manifest.allowsNoCredential)
        XCTAssertEqual(provider.manifest.authMode, .bearer)
    }
}
