import Foundation

/// 智谱 BigModel（bearer / 滚动时间窗 token 配额）。
/// 无公开余额 API：走控制台内部配额接口 `GET /api/monitor/usage/quota/limit`
/// （open.bigmodel.cn 根域，非 /api/paas/v4），凭 API key 直接作 Authorization 头
/// （**不带 `Bearer ` 前缀**——控制台接口的认证约定，社区工具实测有效）。
/// 只取 TOKENS_LIMIT（unit 3 月 / 6 周）；TIME_LIMIT（unit 5 日）是调用次数限流
/// （rateLimit 型，MVP 不接）。余额型账户无 token 配额，不予展示。
public struct ZhipuProvider: Provider {
    public let manifest = ProviderManifest(
        id: "zhipu",
        displayName: "智谱",
        authMode: .bearer,
        defaultBaseURL: "https://open.bigmodel.cn",
        allowsBaseURLOverride: true,
        defaultPollInterval: 180,
        shortName: "zhip",
        consoleURL: "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys",
        logoName: "zhipu_logo",
        themeColor: .purple
    )
    public let supportedQuotaTypes: [QuotaType] = [.timeWindowed]

    private let baseURL: String
    private let http: HTTPClient

    public init(baseURL: String? = nil, http: HTTPClient = URLSessionHTTPClient()) {
        guard let url = baseURL ?? manifest.defaultBaseURL else {
            fatalError("ZhipuProvider: manifest missing defaultBaseURL")
        }
        self.baseURL = url
        self.http = http
    }

    public func fetchUsage(credential: Credential) async throws -> ProviderReport {
        guard case .bearer(let key) = credential else { throw ProviderError.missingCredential }

        guard let url = URL(string: baseURL + "/api/monitor/usage/quota/limit") else {
            throw ProviderError.network("invalid baseURL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // 控制台内部接口认证约定：裸 key，不加 "Bearer "（与 /api/paas/v4 不同）
        request.setValue(key, forHTTPHeaderField: "Authorization")

        let response = try await http.send(request)
        if let error = ProviderError.fromStatus(response.status) { throw error }
        return try Self.parse(data: response.data)
    }

    // MARK: - Parsing

    struct QuotaLimitResponse: Decodable {
        let code: Int
        let data: QuotaLimitPayload?
    }
    struct QuotaLimitPayload: Decodable {
        let limits: [LimitItem]?
        let level: String?
    }
    struct LimitItem: Decodable {
        let type: String?
        /// 3 = 月，5 = 日，6 = 周（日/周/月均为滚动窗口；无 5h 级窗口）
        let unit: Int?
        /// 配额总额（疑似以万 token 为单位，量纲待实测确认；按原值展示）
        let number: Int?
        let percentage: Int?
        /// 毫秒时间戳；月条常缺失（只有周条带）
        let nextResetTime: Int64?
    }

    static let weeklyWindow: TimeInterval = 7 * 86400
    static let monthlyWindow: TimeInterval = 30 * 86400

    public static func parse(data: Data, now: Date = Date()) throws -> ProviderReport {
        let decoded: QuotaLimitResponse
        do {
            decoded = try JSONDecoder().decode(QuotaLimitResponse.self, from: data)
        } catch {
            throw ProviderError.parse("zhipu: \(error.localizedDescription)")
        }
        // 只暴露错误码，不透传服务端自由文本（DESIGN.md §10）
        guard decoded.code == 200 else {
            // 服务端对未订阅账号（无 coding plan）返回 500：视为无额度（空报告），
            // 避免把「未订阅」显示成错误球；其余错误码照常抛错。
            if decoded.code == 500 {
                return ProviderReport(providerId: "zhipu", fetchedAt: now, quotas: [])
            }
            throw ProviderError.parse("zhipu: code \(decoded.code)")
        }
        guard let limits = decoded.data?.limits, !limits.isEmpty else {
            throw ProviderError.parse("zhipu: empty limits")
        }

        var quotas: [Quota] = []
        for item in limits {
            // 只取 TOKENS_LIMIT；TIME_LIMIT（日调用限流）与未知 unit 跳过
            guard item.type == "TOKENS_LIMIT", let unit = item.unit else { continue }
            let window: (id: String, label: String, duration: TimeInterval)
            switch unit {
            case 3: window = ("zhipu.monthly", "月度额度", monthlyWindow)
            case 6: window = ("zhipu.weekly", "周额度", weeklyWindow)
            default: continue
            }
            // number 缺失或为 0 = 未订阅该配额 -> 跳过（避免误导性的 0%）
            guard let number = item.number, number > 0 else { continue }

            let percentage = Double(item.percentage ?? 0)
            let remaining = Double(number) * (100 - percentage) / 100
            var resetsAt: Date?
            if let ms = item.nextResetTime, ms > 0 {
                resetsAt = Date(timeIntervalSince1970: Double(ms) / 1000)
            }
            quotas.append(Quota(
                id: window.id,
                type: .timeWindowed,
                label: window.label,
                unit: .tokens,
                limit: Double(number),
                remaining: remaining,
                windowStart: resetsAt?.addingTimeInterval(-window.duration),
                resetsAt: resetsAt
            ))
        }
        return ProviderReport(providerId: "zhipu", fetchedAt: now, quotas: quotas)
    }
}
