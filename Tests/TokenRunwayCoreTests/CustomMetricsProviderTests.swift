import XCTest
@testable import TokenRunwayCore

/// CustomMetricsProvider: Prometheus instant-query adapter.
/// parse goes through the static method (like DeepSeek/Volcano — testable without HTTP);
/// fetch uses a programmable StubHTTPClient to assert request shape (same pattern as KimiCLICredentialStoreTests).
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
                            label: String = "", semantics: MetricSemantics = .used) -> CustomMetricConfig {
        CustomMetricConfig(id: "custom-1", name: "本月 API 预算",
                           baseURL: "http://prom.internal:9090",
                           metric: "api_budget_usage", label: label,
                           max: max, unit: unit, semantics: semantics)
    }

    /// Official Prometheus instant-query sample: value = [timestamp, numeric string]
    private func promResponse(value: String = "1234.5", count: Int = 1) -> Data {
        let series = (0..<count).map { i in
            #"{"metric":{"team":"data"},"value":[1778806800.0,"\#(value)"]}"# +
            (i == count - 1 ? "" : ",")
        }.joined()
        return Data("""
        {"status":"success","data":{"resultType":"vector","result":[\(series)]}}
        """.utf8)
    }

    // MARK: parse — used semantics (default)

    /// used + max → used water (full = drained)
    func testParsesUsedWithMaxAsTimeWindowed() throws {
        // Arrange
        let json = promResponse(value: "1234.5")

        // Act
        let report = try CustomMetricsProvider.parse(data: json, config: makeConfig(max: 5000))

        // Assert
        XCTAssertEqual(report.providerId, "custom-1")
        XCTAssertEqual(report.quotas.count, 1)
        let q = report.quotas[0]
        XCTAssertEqual(q.id, "custom-1.main")
        XCTAssertEqual(q.type, .timeWindowed)
        XCTAssertEqual(q.label, "本月 API 预算")
        XCTAssertEqual(q.used, 1234.5)
        XCTAssertEqual(q.limit, 5000)
        XCTAssertEqual(q.effectiveRemaining, 3765.5)
        XCTAssertEqual(try XCTUnwrap(q.percentUsed), 1234.5 / 5000, accuracy: 1e-9)
        XCTAssertTrue(q.showsUsedLevel, "used semantics water must be used-direction")
        XCTAssertNil(report.balance)
    }

    /// used without max: plain value, no water (limit nil → percentUsed nil), no BalanceInfo
    func testParsesUsedWithoutMaxAsPlainValue() throws {
        // Arrange
        let json = promResponse(value: "880.25")

        // Act
        let report = try CustomMetricsProvider.parse(data: json, config: makeConfig())

        // Assert
        let q = report.quotas[0]
        XCTAssertEqual(q.type, .timeWindowed)
        XCTAssertEqual(q.used, 880.25)
        XCTAssertNil(q.limit)
        XCTAssertNil(q.percentUsed)
        XCTAssertTrue(q.showsUsedLevel)
        XCTAssertNil(report.balance, "used 语义不应附加 BalanceInfo")
    }

    func testParsesUsedMaxZeroAsPlainValue() throws {
        // Arrange: max <= 0 = no cap (avoids limit=0 division/misleading)
        let report = try CustomMetricsProvider.parse(
            data: promResponse(), config: makeConfig(max: 0))
        XCTAssertEqual(report.quotas[0].type, .timeWindowed)
        XCTAssertNil(report.quotas[0].limit)
    }

    // MARK: parse — remaining semantics

    /// remaining: value = amount left, balance ball (water = value / high-water mark)
    func testParsesRemainingAsBalance() throws {
        // Arrange
        let json = promResponse(value: "880.25")

        // Act
        let report = try CustomMetricsProvider.parse(
            data: json, config: makeConfig(semantics: .remaining))

        // Assert
        let q = report.quotas[0]
        XCTAssertEqual(q.type, .balance)
        XCTAssertEqual(q.remaining, 880.25)
        XCTAssertNil(q.limit)
        XCTAssertNil(q.used)
        // Balance branch must attach BalanceInfo: ballModel routes to the balance shape (else "--")
        XCTAssertNotNil(report.balance)
        XCTAssertEqual(report.balance?.total, 880.25)
    }

    /// remaining + max: water = remaining/max (full = healthy, same as built-ins)
    func testParsesRemainingWithMaxAsRemainingLevel() throws {
        // Arrange: value 4321 = remaining, total cap 10000
        let json = promResponse(value: "4321.0")

        // Act
        let report = try CustomMetricsProvider.parse(
            data: json, config: makeConfig(max: 10000, semantics: .remaining))

        // Assert: remaining-style timeWindowed, 56.79% used / 43.21% remaining
        let q = report.quotas[0]
        XCTAssertEqual(q.type, .timeWindowed)
        XCTAssertEqual(q.remaining, 4321)
        XCTAssertEqual(q.limit, 10000)
        XCTAssertFalse(q.showsUsedLevel, "remaining semantics water must be remaining-direction")
        XCTAssertEqual(try XCTUnwrap(q.percentUsed), 5679.0 / 10000, accuracy: 1e-9)
        XCTAssertNil(report.balance, "remaining with cap must not attach BalanceInfo")
    }

    /// Balance-branch currency maps from unit (CNY → ¥ badge); unitless → empty
    func testParsesBalanceCurrencyFromUnit() throws {
        // Arrange
        let json = promResponse()

        // Act
        let cny = try CustomMetricsProvider.parse(
            data: json, config: makeConfig(unit: .cny, semantics: .remaining))
        let none = try CustomMetricsProvider.parse(
            data: json, config: makeConfig(semantics: .remaining))

        // Assert
        XCTAssertEqual(cny.balance?.currency, "CNY")
        XCTAssertEqual(none.balance?.currency, "")
    }

    // MARK: parse — common behavior

    func testParsesMapsConfiguredUnit() throws {
        // Arrange: CNY configured → .cny; not configured → .none
        let withUnit = try CustomMetricsProvider.parse(
            data: promResponse(), config: makeConfig(max: 5000, unit: .cny))
        XCTAssertEqual(withUnit.quotas[0].unit, .cny)

        let noUnit = try CustomMetricsProvider.parse(
            data: promResponse(), config: makeConfig(max: 5000))
        XCTAssertEqual(noUnit.quotas[0].unit, .none)
    }

    func testThrowsOnStatusErrorWithoutFreeText() {
        // Arrange: Prometheus business error, status=error (server free text must not leak)
        let json = Data("""
        {"status":"error","errorType":"bad_data","error":"internal detail must not leak"}
        """.utf8)

        // Act / Assert
        XCTAssertThrowsError(try CustomMetricsProvider.parse(data: json, config: makeConfig())) { error in
            guard case ProviderError.parse(let msg) = error else {
                return XCTFail("expected parse error, got \(error)")
            }
            XCTAssertTrue(msg.contains("error"), "should expose the error state: \(msg)")
            XCTAssertFalse(msg.contains("must not leak"), "must not leak server free text: \(msg)")
        }
    }

    func testThrowsOnEmptyResult() {
        // Arrange: no data = config problem (wrong metric/label); fail loudly, not a silent empty report
        let json = Data(#"{"status":"success","data":{"resultType":"vector","result":[]}}"#.utf8)

        // Act / Assert
        XCTAssertThrowsError(try CustomMetricsProvider.parse(data: json, config: makeConfig())) { error in
            guard case ProviderError.parse(let msg) = error else {
                return XCTFail("expected parse error, got \(error)")
            }
            XCTAssertTrue(msg.contains("no data"), "unexpected message: \(msg)")
        }
    }

    /// Multi-series (unaggregated) takes the first — use sum(...) in the metric field to aggregate
    func testTakesFirstSeriesWhenMultiple() throws {
        // Arrange
        let json = Data("""
        {"status":"success","data":{"resultType":"vector","result":[
          {"metric":{"team":"a"},"value":[1778806800.0,"100"]},
          {"metric":{"team":"b"},"value":[1778806800.0,"200"]}
        ]}}
        """.utf8)

        // Act
        let report = try CustomMetricsProvider.parse(data: json, config: makeConfig(max: 500))

        // Assert
        XCTAssertEqual(report.quotas[0].used, 100)
    }

    func testThrowsOnBadJSON() {
        // Arrange / Act / Assert
        XCTAssertThrowsError(try CustomMetricsProvider.parse(data: Data("not json".utf8),
                                                             config: makeConfig())) { error in
            guard case ProviderError.parse = error else {
                return XCTFail("expected parse error, got \(error)")
            }
        }
    }

    func testThrowsOnNonNumericValue() {
        // Arrange
        let json = Data("""
        {"status":"success","data":{"resultType":"vector","result":[
          {"metric":{},"value":[1778806800.0,"NaN"]}
        ]}}
        """.utf8)

        // Act / Assert
        XCTAssertThrowsError(try CustomMetricsProvider.parse(data: json, config: makeConfig())) { error in
            guard case ProviderError.parse = error else {
                return XCTFail("expected parse error, got \(error)")
            }
        }
    }

    // MARK: fetch (request shape)

    func testFetchBuildsQueryURL() async throws {
        // Arrange: metric + label → PromQL, URL-encoded
        let http = StubHTTPClient(responses: [HTTPResponse(status: 200, data: promResponse())])
        let provider = CustomMetricsProvider(config: makeConfig(max: 5000, label: "team=data,env=prod"),
                                             http: http)

        // Act
        _ = try await provider.fetchUsage(credential: .none)

        // Assert
        let request = await http.requests[0]
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/api/v1/query")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "query" }?.value,
                       #"api_budget_usage{team="data",env="prod"}"#)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                     "no-auth endpoint must not send an Authorization header")
    }

    func testFetchSendsBearerWhenCredentialProvided() async throws {
        // Arrange
        let http = StubHTTPClient(responses: [HTTPResponse(status: 200, data: promResponse())])
        let provider = CustomMetricsProvider(config: makeConfig(max: 5000), http: http)

        // Act
        _ = try await provider.fetchUsage(credential: .bearer("sekret"))

        // Assert
        let request = await http.requests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sekret")
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

    func testFetchThrowsOnMalformedLabel() async {
        // Arrange: malformed label (missing =) → fetch errors without sending a request
        let http = StubHTTPClient()
        let provider = CustomMetricsProvider(config: makeConfig(label: "team"), http: http)

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
        XCTAssertEqual(count, 0, "must not send a request for a malformed query")
    }

    /// Manifest contract: custom providers allow no credential (open internal endpoints),
    /// displayName = the user-configured name
    func testManifestReflectsConfig() {
        // Arrange
        let provider = CustomMetricsProvider(config: makeConfig(max: 5000))

        // Assert
        XCTAssertEqual(provider.manifest.id, "custom-1")
        XCTAssertEqual(provider.manifest.displayName, "本月 API 预算")
        XCTAssertEqual(provider.manifest.defaultBaseURL, "http://prom.internal:9090")
        XCTAssertTrue(provider.manifest.allowsNoCredential)
        XCTAssertEqual(provider.manifest.authMode, .bearer)
    }
}
