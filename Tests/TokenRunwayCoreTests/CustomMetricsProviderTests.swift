import XCTest
@testable import TokenRunwayCore

/// CustomMetricsProvider：Prometheus instant query 适配器。
/// parse 走静态方法（与 DeepSeek/Volcano 一致，可无 HTTP 测解析）；
/// fetch 用可编程 StubHTTPClient 断言请求形状（与 KimiCLICredentialStoreTests 同模式）。
final class CustomMetricsProviderTests: XCTestCase {

    /// 可编程 HTTPClient：记录请求并返回预设响应
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

    // Foundation 也有 Unit（NSUnit），测试 target 里用模块限定消除歧义
    private typealias QuotaUnit = TokenRunwayCore.Unit

    private func makeConfig(max: Double? = nil, unit: QuotaUnit? = nil,
                            label: String = "", semantics: MetricSemantics = .used) -> CustomMetricConfig {
        CustomMetricConfig(id: "custom-1", name: "本月 API 预算",
                           baseURL: "http://prom.internal:9090",
                           metric: "api_budget_usage", label: label,
                           max: max, unit: unit, semantics: semantics)
    }

    /// Prometheus 官方 instant query 响应样例：value = [时间戳, 数值字符串]
    private func promResponse(value: String = "1234.5", count: Int = 1) -> Data {
        let series = (0..<count).map { i in
            #"{"metric":{"team":"data"},"value":[1778806800.0,"\#(value)"]}"# +
            (i == count - 1 ? "" : ",")
        }.joined()
        return Data("""
        {"status":"success","data":{"resultType":"vector","result":[\(series)]}}
        """.utf8)
    }

    // MARK: parse — used 语义（默认）

    /// used + max → 已用水位（满 = 耗尽）
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
        XCTAssertTrue(q.showsUsedLevel, "used 语义水位必须为已用方向")
        XCTAssertNil(report.balance)
    }

    /// used 无 max：纯值无水位（limit nil → percentUsed nil），不带 BalanceInfo
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
        // Arrange：max <= 0 = 无上限（避免 limit=0 除零/误导）
        let report = try CustomMetricsProvider.parse(
            data: promResponse(), config: makeConfig(max: 0))
        XCTAssertEqual(report.quotas[0].type, .timeWindowed)
        XCTAssertNil(report.quotas[0].limit)
    }

    // MARK: parse — remaining 语义

    /// remaining：指标值 = 剩余量，余额球（水位 = 值/历史高水位）
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
        // 余额分支必须带 BalanceInfo：ballModel 据此路由到余额球（否则显示 "--"）
        XCTAssertNotNil(report.balance)
        XCTAssertEqual(report.balance?.total, 880.25)
    }

    /// remaining + max：水位 = 剩余比例（remaining/max，满 = 健康，与内置 provider 一致）
    func testParsesRemainingWithMaxAsRemainingLevel() throws {
        // Arrange：指标值 4321 = 剩余量，总额度 10000
        let json = promResponse(value: "4321.0")

        // Act
        let report = try CustomMetricsProvider.parse(
            data: json, config: makeConfig(max: 10000, semantics: .remaining))

        // Assert：remaining 型 timeWindowed，已用 56.79%、剩余 43.21%
        let q = report.quotas[0]
        XCTAssertEqual(q.type, .timeWindowed)
        XCTAssertEqual(q.remaining, 4321)
        XCTAssertEqual(q.limit, 10000)
        XCTAssertFalse(q.showsUsedLevel, "remaining 语义水位必须为剩余方向")
        XCTAssertEqual(try XCTUnwrap(q.percentUsed), 5679.0 / 10000, accuracy: 1e-9)
        XCTAssertNil(report.balance, "有上限的 remaining 不应附加 BalanceInfo")
    }

    /// 余额分支的 currency 由 unit 映射（CNY → 余额球显示 ¥ 角标）；无单位 → 空
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

    // MARK: parse — 公共行为

    func testParsesMapsConfiguredUnit() throws {
        // Arrange：配了 CNY → 映射 .cny；没配 → .none
        let withUnit = try CustomMetricsProvider.parse(
            data: promResponse(), config: makeConfig(max: 5000, unit: .cny))
        XCTAssertEqual(withUnit.quotas[0].unit, .cny)

        let noUnit = try CustomMetricsProvider.parse(
            data: promResponse(), config: makeConfig(max: 5000))
        XCTAssertEqual(noUnit.quotas[0].unit, .none)
    }

    func testThrowsOnStatusErrorWithoutFreeText() {
        // Arrange：Prometheus 业务错误，status=error（服务端自由文本不得泄露）
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
        // Arrange：查询无数据 = 配置问题（指标名/标签写错），报错而非静默空报告
        let json = Data(#"{"status":"success","data":{"resultType":"vector","result":[]}}"#.utf8)

        // Act / Assert
        XCTAssertThrowsError(try CustomMetricsProvider.parse(data: json, config: makeConfig())) { error in
            guard case ProviderError.parse(let msg) = error else {
                return XCTFail("expected parse error, got \(error)")
            }
            XCTAssertTrue(msg.contains("no data"), "unexpected message: \(msg)")
        }
    }

    /// 多序列（未聚合时）取第一条 —— 需要聚合就在 metric 里写 sum(...)
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

    // MARK: fetch（请求形状）

    func testFetchBuildsQueryURL() async throws {
        // Arrange：metric + label → PromQL，URL 编码
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
        // Arrange：401 → unauthorized；429 → rateLimited
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
        // Arrange：label 非法（缺 =）→ fetch 层直接报错，不发请求
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

    /// manifest 契约：自定义 provider 允许无凭证（内网公开端点），displayName = 用户配置的 name
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
