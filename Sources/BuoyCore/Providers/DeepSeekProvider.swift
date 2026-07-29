import Foundation

/// DeepSeek（bearer / 余额），DESIGN.md §5.1
public struct DeepSeekProvider: Provider {
    public let manifest = ProviderManifest(
        id: "deepseek",
        displayName: "DeepSeek",
        authMode: .bearer,
        defaultBaseURL: "https://api.deepseek.com",
        allowsBaseURLOverride: true
    )
    public let supportedQuotaTypes: [QuotaType] = [.balance]

    private let baseURL: String
    private let http: HTTPClient

    public init(baseURL: String? = nil, http: HTTPClient = URLSessionHTTPClient()) {
        guard let url = baseURL ?? manifest.defaultBaseURL else {
            fatalError("DeepSeekProvider: manifest missing defaultBaseURL")
        }
        self.baseURL = url
        self.http = http
    }

    public func fetchUsage(credential: Credential) async throws -> ProviderReport {
        guard case .bearer(let token) = credential else { throw ProviderError.missingCredential }

        guard let url = URL(string: baseURL + "/user/balance") else {
            throw ProviderError.network("invalid baseURL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let response = try await http.send(request)
        if let error = ProviderError.fromStatus(response.status) { throw error }
        return try Self.parse(data: response.data)
    }

    // MARK: - Parsing

    struct BalanceResponse: Decodable {
        let is_available: Bool
        let balance_infos: [BalanceInfoDTO]
    }
    struct BalanceInfoDTO: Decodable {
        let currency: String
        let total_balance: String
        let granted_balance: String
        let topped_up_balance: String
    }

    public static func parse(data: Data, now: Date = Date()) throws -> ProviderReport {
        let decoded: BalanceResponse
        do {
            decoded = try JSONDecoder().decode(BalanceResponse.self, from: data)
        } catch {
            throw ProviderError.parse("deepseek: \(error.localizedDescription)")
        }
        guard let info = decoded.balance_infos.first(where: { $0.currency == "CNY" })
                ?? decoded.balance_infos.first else {
            throw ProviderError.parse("deepseek: empty balance_infos")
        }
        guard let total = Double(info.total_balance) else {
            throw ProviderError.parse("deepseek: bad total_balance \(info.total_balance)")
        }
        let granted = Double(info.granted_balance) ?? 0
        let toppedUp = Double(info.topped_up_balance) ?? 0
        let unit: Unit = info.currency == "USD" ? .usd : .cny

        let quota = Quota(
            id: "deepseek.balance",
            type: .balance,
            label: "账户余额",
            unit: unit,
            remaining: total
        )
        return ProviderReport(
            providerId: "deepseek",
            fetchedAt: now,
            quotas: [quota],
            balance: BalanceInfo(currency: info.currency, total: total, granted: granted, toppedUp: toppedUp)
        )
    }
}
