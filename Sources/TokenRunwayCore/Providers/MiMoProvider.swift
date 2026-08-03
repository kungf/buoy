import Foundation

/// 小米 MiMo（consoleSession / 月度 Token Plan 额度），DESIGN.md §5.4。
/// 无公开用量 API：走控制台内部接口（platform.xiaomimimo.com/api/v1），
/// 凭内嵌 WKWebView 登录后提取的 SSO 会话 cookie（api-platform_serviceToken + userId）。
/// 只取套餐信息（tokenPlan/detail）与月度用量（tokenPlan/usage）；余额对套餐用户恒为 0，不取。
public struct MiMoProvider: Provider {
    public let manifest = ProviderManifest(
        id: "mimo",
        displayName: "MiMo",
        authMode: .consoleSession,
        defaultBaseURL: "https://platform.xiaomimimo.com/api/v1",
        allowsBaseURLOverride: false,
        defaultPollInterval: 300,
        shortName: "mimo",
        consoleURL: "https://platform.xiaomimimo.com/console/plan-manage",
        logoName: "mimo_logo",
        themeColor: .gray
    )
    public let supportedQuotaTypes: [QuotaType] = [.timeWindowed]

    private let baseURL: String
    private let http: HTTPClient

    public init(baseURL: String? = nil, http: HTTPClient = URLSessionHTTPClient()) {
        guard let url = baseURL ?? manifest.defaultBaseURL else {
            fatalError("MiMoProvider: manifest missing defaultBaseURL")
        }
        self.baseURL = url
        self.http = http
    }

    public func fetchUsage(credential: Credential) async throws -> ProviderReport {
        guard case .sessionCookies(let serviceToken, let userId) = credential else {
            throw ProviderError.missingCredential
        }
        let cookie = "api-platform_serviceToken=\(serviceToken); userId=\(userId)"

        // 两个端点并行取（detail 失败则整体失败；usage 失败保留 detail 结果）
        async let detail = fetchAuthenticated(path: "/tokenPlan/detail", cookie: cookie)
        async let usage = fetchAuthenticated(path: "/tokenPlan/usage", cookie: cookie)

        // 只有 detail 是必需的（驱动套餐周期与过期态）；usage 拿不到时返回空额度
        let detailData = try await detail
        let usageData = (try? await usage) ?? nil
        return try Self.parse(detailData: detailData, usageData: usageData)
    }

    private func fetchAuthenticated(path: String, cookie: String) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw ProviderError.network("invalid baseURL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 控制台接口校验浏览器上下文：带与页面一致的 Origin/Referer/UA（实测缺 Origin 会 403）
        request.setValue("https://platform.xiaomimimo.com", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.xiaomimimo.com/console/plan-manage", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")

        let response = try await http.send(request)
        if let error = ProviderError.fromStatus(response.status) { throw error }
        return response.data
    }

    // MARK: - Parsing

    struct DetailResponse: Decodable {
        let code: Int
        let message: String?
        let data: DetailPayload?
    }
    struct DetailPayload: Decodable {
        let planCode: String?
        let planName: String?
        let currentPeriodEnd: String?
        let expired: Bool?
    }

    struct UsageResponse: Decodable {
        let code: Int
        let message: String?
        let data: UsagePayload?
    }
    struct UsagePayload: Decodable {
        let monthUsage: MonthUsage?
    }
    struct MonthUsage: Decodable {
        let items: [UsageItem]?
    }
    struct UsageItem: Decodable {
        let name: String?
        let used: Int?
        let limit: Int?
    }

    /// 月度周期 = 30 天（Lite 套餐按自然月计费，periodEnd − 30d 作为窗口起点）。
    static let monthlyWindow: TimeInterval = 30 * 86400

    /// MiMo 的解析入口需要两个端点响应（detail 必需 + usage 可选），
    /// 与单响应型 provider（DeepSeek/Volcano）不同，故不提供单参数 parse 版本。
    static func parse(detailData: Data, usageData: Data?, now: Date = Date()) throws -> ProviderReport {
        let detail: DetailResponse
        do {
            detail = try JSONDecoder().decode(DetailResponse.self, from: detailData)
        } catch {
            throw ProviderError.parse("mimo: \(error.localizedDescription)")
        }
        // 只暴露错误码，不透传服务端自由文本（DESIGN.md §10）
        guard detail.code == 0 else {
            throw ProviderError.parse("mimo: code \(detail.code)")
        }
        guard let payload = detail.data else {
            throw ProviderError.parse("mimo: missing detail data")
        }

        var quotas: [Quota] = []
        if let usageData {
            let usage: UsageResponse
            do {
                usage = try JSONDecoder().decode(UsageResponse.self, from: usageData)
            } catch {
                throw ProviderError.parse("mimo: \(error.localizedDescription)")
            }
            guard usage.code == 0 else {
                throw ProviderError.parse("mimo: code \(usage.code)")
            }
            // items 缺失 = 本月尚无用量记录 -> 不产出额度（避免 0/0），只保留过期态
            if let item = usage.data?.monthUsage?.items?.first,
               let used = item.used, let limit = item.limit, limit > 0,
               let periodEnd = parsePeriodEnd(payload.currentPeriodEnd) {
                quotas.append(Quota(
                    id: "mimo.monthly",
                    type: .timeWindowed,
                    label: "月度额度",
                    unit: .credits,
                    used: Double(used),
                    limit: Double(limit),
                    windowStart: periodEnd.addingTimeInterval(-monthlyWindow),
                    resetsAt: periodEnd
                ))
            }
        }

        return ProviderReport(
            providerId: "mimo",
            fetchedAt: now,
            quotas: quotas,
            planExpired: payload.expired == true
        )
    }

    /// "yyyy-MM-dd HH:mm:ss"（UTC，来自控制台）。解析失败返回 nil -> 不产出额度。
    static func parsePeriodEnd(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: raw)
    }
}
