import Foundation

/// <DisplayName>（<authMode> / <quota shape>）。
/// <one-line note: endpoint, auth scope gotchas, doc URL>
///
/// Template for a bearer-token, balance-style provider. For volcSignature or a
/// rolling time-window quota, see VolcanoProvider.swift as the reference.
public struct <Name>Provider: Provider {
    public let manifest = ProviderManifest(
        id: "<id>",                       // lowercase, stable, e.g. "openai"
        displayName: "<DisplayName>",      // human name, may be localized
        authMode: .bearer,                 // reuse .bearer for API-key providers
        defaultBaseURL: "https://api.example.com",
        allowsBaseURLOverride: true,
        defaultPollInterval: 180,          // 120 for short rolling windows, 180 for balance
        shortName: "<xx>",                 // 2-3 chars for the 88pt ball nameplate
        consoleURL: "https://platform.example.com",  // where the user gets the credential
        logoName: "<id>_logo",             // must match Resources/<id>_logo.png
        themeColor: .blue                  // pick from ThemeColor enum
        // envPrefixOverride: "LEGACY"      // only if a legacy env-var name must be kept
    )
    public let supportedQuotaTypes: [QuotaType] = [.balance]

    private let baseURL: String
    private let http: HTTPClient

    public init(baseURL: String? = nil, http: HTTPClient = URLSessionHTTPClient()) {
        guard let url = baseURL ?? manifest.defaultBaseURL else {
            fatalError("<Name>Provider: manifest missing defaultBaseURL")
        }
        self.baseURL = url
        self.http = http
    }

    public func fetchUsage(credential: Credential) async throws -> ProviderReport {
        // Guard credential matches authMode; never log the token.
        guard case .bearer(let token) = credential else { throw ProviderError.missingCredential }

        guard let url = URL(string: baseURL + "/usage") else {
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

    struct UsageResponse: Decodable {
        // Map the provider's JSON to the fields you need to build Quota(s).
        // let total: String
    }

    public static func parse(data: Data, now: Date = Date()) throws -> ProviderReport {
        let decoded: UsageResponse
        do {
            decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw ProviderError.parse("<id>: \(error.localizedDescription)")
        }

        // Build Quota(s). id format: "<id>.<window>". Skip limit==0 windows.
        // Unit: .tokens / .credits / .usd / .cny - never aggregate across units.
        let quota = Quota(
            id: "<id>.balance",
            type: .balance,
            label: "账户余额",
            unit: .usd,
            remaining: 0   // from decoded response
        )
        return ProviderReport(providerId: "<id>", fetchedAt: now, quotas: [quota])
    }
}
