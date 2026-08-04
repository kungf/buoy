import Foundation

/// 自定义指标 Provider：Prometheus instant query 适配器。
/// 一个 CustomMetricConfig 实例对应一个 provider（id = config.id）：
/// GET {baseURL}/api/v1/query?query={metric}{labels}，取 result[0].value 的数值。
/// 配了 max（>0）→ timeWindowed（used=usage, limit=max，显示已用百分比/剩余/呼吸）；
/// 未配 max → balance（remaining=usage，DeepSeek 式余额球）。
public struct CustomMetricsProvider: Provider {
    public let manifest: ProviderManifest
    public let config: CustomMetricConfig
    private let http: HTTPClient

    public init(config: CustomMetricConfig, http: HTTPClient = URLSessionHTTPClient()) {
        self.config = config
        self.manifest = ProviderManifest(
            id: config.id,
            displayName: config.name,
            authMode: .bearer,
            defaultBaseURL: config.baseURL,
            allowsBaseURLOverride: false,
            defaultPollInterval: 300,
            shortName: nil,
            consoleURL: nil,
            logoName: nil,
            themeColor: .gray,
            allowsNoCredential: true
        )
        self.http = http
    }

    public let supportedQuotaTypes: [QuotaType] = [.timeWindowed, .balance]

    public func fetchUsage(credential: Credential) async throws -> ProviderReport {
        guard let query = config.query else {
            throw ProviderError.parse("custom: malformed metric/label config")
        }
        guard var components = URLComponents(string: config.baseURL),
              components.scheme != nil, components.host != nil else {
            throw ProviderError.network("invalid baseURL")
        }
        components.path = components.path.hasSuffix("/")
            ? components.path + "api/v1/query"
            : components.path + "/api/v1/query"
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = components.url else {
            throw ProviderError.network("invalid baseURL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        switch credential {
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .none:
            break   // 内网公开端点，裸请求
        default:
            throw ProviderError.missingCredential
        }

        let response = try await http.send(request)
        if let error = ProviderError.fromStatus(response.status) { throw error }
        return try Self.parse(data: response.data, config: config)
    }

    // MARK: - Parsing

    /// Prometheus instant query 响应（官方格式）：value = [时间戳, 数值字符串]
    struct PrometheusResponse: Decodable {
        let status: String
        let data: DataDTO?
        struct DataDTO: Decodable {
            let resultType: String?
            let result: [ResultDTO]?
        }
        struct ResultDTO: Decodable {
            let value: SampleDTO?
        }
        struct SampleDTO: Decodable {
            let timestamp: Double
            let value: String
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                timestamp = try container.decode(Double.self)
                value = try container.decode(String.self)
            }
        }
    }

    public static func parse(data: Data, config: CustomMetricConfig,
                             now: Date = Date()) throws -> ProviderReport {
        let decoded: PrometheusResponse
        do {
            decoded = try JSONDecoder().decode(PrometheusResponse.self, from: data)
        } catch {
            throw ProviderError.parse("custom: \(error.localizedDescription)")
        }
        // status=error 只暴露错误状态，不透传服务端自由文本（DESIGN.md §10）
        guard decoded.status == "success" else {
            throw ProviderError.parse("custom: prometheus status=error")
        }
        // 查询无数据 = 指标名/标签写错，报错而非静默空报告
        guard let sample = decoded.data?.result?.first?.value else {
            throw ProviderError.parse("custom: no data for query")
        }
        // Double("NaN")/Double("Inf") 会解析成功，但会污染百分比/剩余计算，必须拒绝
        guard let used = Double(sample.value), used.isFinite else {
            throw ProviderError.parse("custom: non-numeric value")
        }

        // 余额语义：指标值 = 剩余量。
        if config.semantics == .remaining {
            if let max = config.max, max > 0 {
                // 余额 + 上限：水位 = 剩余比例（remaining/max，满 = 健康，与内置 provider 一致）
                let quota = Quota(id: "\(config.id).main", type: .timeWindowed,
                                  label: config.name, unit: config.unit ?? .none,
                                  limit: max, remaining: used)
                return ProviderReport(providerId: config.id, fetchedAt: now, quotas: [quota])
            }
            // 余额无上限：余额球。必须带 BalanceInfo：ballModel 据此路由到余额球
            // （否则走 windowed 分支显示 "--"）。currency 由 unit 映射出 ¥/$ 角标。
            let quota = Quota(id: "\(config.id).main", type: .balance,
                              label: config.name, unit: config.unit ?? .none,
                              remaining: used)
            let currency: String
            switch config.unit {
            case .cny: currency = "CNY"
            case .usd: currency = "USD"
            default: currency = ""
            }
            return ProviderReport(providerId: config.id, fetchedAt: now, quotas: [quota],
                                  balance: BalanceInfo(currency: currency, total: used,
                                                       granted: 0, toppedUp: 0))
        }

        // 已使用语义（默认）：值 = 用量。配 max → 已用水位（满 = 耗尽）；不配 → 纯值无水位
        let quota: Quota
        if let max = config.max, max > 0 {
            quota = Quota(id: "\(config.id).main", type: .timeWindowed,
                          label: config.name, unit: config.unit ?? .none,
                          used: used, limit: max, showsUsedLevel: true)
        } else {
            quota = Quota(id: "\(config.id).main", type: .timeWindowed,
                          label: config.name, unit: config.unit ?? .none,
                          used: used, showsUsedLevel: true)
        }
        return ProviderReport(providerId: config.id, fetchedAt: now, quotas: [quota])
    }
}
