import Foundation

/// 火山引擎 ARK（volcSignature / GetAFPUsage），DESIGN.md §5.2。
/// 需要 IAM AccessKey + SecretKey（非 ARK 推理 API Key）。
/// 注意：走通用开放网关 open.volcengineapi.com（签名 scope service=ark, region=cn-beijing）。
/// ark.cn-beijing.volces.com 是推理端点，其自有鉴权层不认 IAM AK/SK（实测 401）。
public struct VolcanoProvider: Provider {
    public let manifest = ProviderManifest(
        id: "volcano",
        displayName: "火山引擎",
        authMode: .volcSignature,
        defaultBaseURL: "https://open.volcengineapi.com",
        allowsBaseURLOverride: true,
        defaultPollInterval: 120
    )
    public let supportedQuotaTypes: [QuotaType] = [.timeWindowed]

    private let host: String
    private let baseURL: String
    private let http: HTTPClient
    private let signer: VolcSigner

    public init(baseURL: String? = nil, http: HTTPClient = URLSessionHTTPClient(), signer: VolcSigner = VolcSigner()) {
        guard let url = baseURL ?? manifest.defaultBaseURL else {
            fatalError("VolcanoProvider: manifest missing defaultBaseURL")
        }
        self.baseURL = url
        self.host = URL(string: url)?.host ?? "open.volcengineapi.com"
        self.http = http
        self.signer = signer
    }

    public func fetchUsage(credential: Credential) async throws -> ProviderReport {
        guard case .volcAccessKey(let ak, let sk) = credential else { throw ProviderError.missingCredential }

        let body = Data("{}".utf8)
        let signed = signer.sign(
            method: "POST",
            uri: "/",
            query: ["Action": "GetAFPUsage", "Version": "2024-01-01"],
            host: host,
            body: body,
            ak: ak,
            sk: sk
        )

        guard let url = URL(string: baseURL + "/?Action=GetAFPUsage&Version=2024-01-01") else {
            throw ProviderError.network("invalid baseURL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(signed.xDate, forHTTPHeaderField: "X-Date")
        request.setValue(signed.contentSHA256, forHTTPHeaderField: "X-Content-Sha256")
        request.setValue(signed.authorization, forHTTPHeaderField: "Authorization")

        let response = try await http.send(request)
        if let error = ProviderError.fromStatus(response.status) { throw error }
        return try Self.parse(data: response.data)
    }

    // MARK: - Parsing

    struct UsageResponse: Decodable {
        let Result: ResultDTO?
        let ResponseMetadata: MetadataDTO?
    }
    struct MetadataDTO: Decodable {
        let Error: ErrorDTO?
    }
    struct ErrorDTO: Decodable {
        let Code: String?
        let Message: String?
    }
    struct ResultDTO: Decodable {
        let PlanType: String?
        let AFPFiveHour: WindowDTO?
        let AFPDaily: WindowDTO?
        let AFPWeekly: WindowDTO?
        let AFPMonthly: WindowDTO?
    }
    struct WindowDTO: Decodable {
        let Quota: Double
        let Used: Double
        let SubscribeTime: Double
        let ResetTime: Double
    }

    public static func parse(data: Data, now: Date = Date()) throws -> ProviderReport {
        let decoded: UsageResponse
        do {
            decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw ProviderError.parse("volcano: \(error.localizedDescription)")
        }
        if let apiError = decoded.ResponseMetadata?.Error {
            // 只暴露错误码，不透传服务端自由文本（避免潜在信息泄露，DESIGN §10）
            throw ProviderError.parse("volcano: \(apiError.Code ?? "?")")
        }
        guard let result = decoded.Result else {
            throw ProviderError.parse("volcano: missing Result")
        }

        // 每日窗口不展示：多数套餐无实际每日限额（AFPDaily 字段常为占位值），按产品决策移除
        let windows: [(id: String, label: String, dto: WindowDTO?)] = [
            ("volcano.5h", "5 小时额度", result.AFPFiveHour),
            ("volcano.7d", "每周额度", result.AFPWeekly),
            ("volcano.30d", "每月额度", result.AFPMonthly),
        ]

        // Quota=0 = 该套餐未开通此窗口 -> 不生成 Quota（DESIGN.md §5.2，避免除零与误导性 0%）
        let quotas: [Quota] = windows.compactMap { id, label, dto in
            guard let dto, dto.Quota > 0 else { return nil }
            return Quota(
                id: id,
                type: .timeWindowed,
                label: label,
                unit: .credits,
                used: dto.Used,
                limit: dto.Quota,
                windowStart: Date(timeIntervalSince1970: dto.SubscribeTime / 1000),
                resetsAt: Date(timeIntervalSince1970: dto.ResetTime / 1000)
            )
        }

        return ProviderReport(providerId: "volcano", fetchedAt: now, quotas: quotas)
    }
}
