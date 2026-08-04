import Foundation

/// Custom metrics provider: Prometheus instant-query adapter.
/// One CustomMetricConfig instance maps to one provider (id = config.id):
/// GET {baseURL}/api/v1/query?query={metric}{labels}, takes result[0].value.
/// Semantics × max (see MetricSemantics): used+max → used water; used no-max → plain value;
/// remaining+max → remaining water; remaining no-max → balance ball.
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
            break   // open internal endpoint — bare request
        default:
            throw ProviderError.missingCredential
        }

        let response = try await http.send(request)
        if let error = ProviderError.fromStatus(response.status) { throw error }
        return try Self.parse(data: response.data, config: config)
    }

    // MARK: - Parsing

    /// Prometheus instant-query response (official format): value = [timestamp, numeric string]
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
        // status=error exposes only the error state, never server free text (DESIGN.md §10)
        guard decoded.status == "success" else {
            throw ProviderError.parse("custom: prometheus status=error")
        }
        // No data = wrong metric/label; fail loudly instead of a silent empty report
        guard let sample = decoded.data?.result?.first?.value else {
            throw ProviderError.parse("custom: no data for query")
        }
        // Double("NaN")/Double("Inf") parse successfully but would poison percent/remaining math — reject
        guard let used = Double(sample.value), used.isFinite else {
            throw ProviderError.parse("custom: non-numeric value")
        }

        // Remaining semantics: the value = amount left.
        if config.semantics == .remaining {
            if let max = config.max, max > 0 {
                // remaining + max: water = remaining/max (full = healthy, same as built-in providers)
                let quota = Quota(id: "\(config.id).main", type: .timeWindowed,
                                  label: config.name, unit: config.unit ?? .none,
                                  limit: max, remaining: used)
                return ProviderReport(providerId: config.id, fetchedAt: now, quotas: [quota])
            }
            // remaining without max: balance ball. BalanceInfo is required so ballModel routes to the
            // balance shape (otherwise the windowed branch renders "--"). currency maps ¥/$ badge.
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

        // Used semantics (default): the value = consumed. With max → used water (full = drained); without → plain value
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
