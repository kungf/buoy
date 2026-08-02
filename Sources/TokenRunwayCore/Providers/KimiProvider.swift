import Foundation

/// Kimi Code（localCLI / 每周配额 + 滚动限流窗 + 加油包），DESIGN.md §5.3。
/// 无需用户手填 token：复用本机 Kimi Code CLI 的 OAuth 登录态（~/.kimi-code），
/// 未登录时提示用户运行 `kimi` 并执行 /login。取数：GET /coding/v1/usages。
public struct KimiProvider: Provider {
    public let manifest = ProviderManifest(
        id: "kimi",
        displayName: "Kimi Code",
        authMode: .localCLI,
        defaultBaseURL: "https://api.kimi.com",
        allowsBaseURLOverride: false,
        defaultPollInterval: 300,
        shortName: "kc",
        consoleURL: "https://www.kimi.com/membership/subscription?tab=quota",
        logoName: "kimi_logo",
        themeColor: .indigo
    )
    public let supportedQuotaTypes: [QuotaType] = [.timeWindowed, .balance]

    private let baseURL: String
    private let http: HTTPClient

    public init(baseURL: String? = nil, http: HTTPClient = URLSessionHTTPClient()) {
        guard let url = baseURL ?? manifest.defaultBaseURL else {
            fatalError("KimiProvider: manifest missing defaultBaseURL")
        }
        self.baseURL = url
        self.http = http
    }

    public func fetchUsage(credential: Credential) async throws -> ProviderReport {
        // localCLI 模式：凭证指向本机 CLI 凭证根目录，token 由凭证仓库读取/刷新
        guard case .localOAuth(let home) = credential else { throw ProviderError.missingCredential }
        let store = KimiCLICredentialStore(home: URL(fileURLWithPath: home), http: http)
        let token = try await store.accessToken()

        guard let url = URL(string: baseURL + "/coding/v1/usages") else {
            throw ProviderError.network("invalid baseURL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await http.send(request)
        if let error = ProviderError.fromStatus(response.status) { throw error }
        return try Self.parse(data: response.data)
    }

    // MARK: - Parsing

    struct UsagesResponse: Decodable {
        let usage: UsageDTO?
        let limits: [LimitEntryDTO]?
        let boosterWallet: BoosterWalletDTO?
    }
    /// 数值均为字符串数字；resetTime 为 ISO8601（带小数秒）
    struct UsageDTO: Decodable {
        let limit: String
        let used: String
        let remaining: String?
        let resetTime: String
    }
    struct LimitEntryDTO: Decodable {
        let window: WindowDTO
        let detail: UsageDTO
    }
    struct WindowDTO: Decodable {
        let duration: Int
        let timeUnit: String
    }
    struct MoneyDTO: Decodable {
        let currency: String?
        let priceInCents: String
    }
    struct BoosterWalletDTO: Decodable {
        let status: String?
        let monthlyChargeLimit: MoneyDTO?
        let monthlyUsed: MoneyDTO?
    }

    static let weeklyWindow: TimeInterval = 7 * 24 * 3600

    static func makeISO8601() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    /// TIME_UNIT_MINUTE/HOUR/DAY/WEEK -> 秒数；未知单位返回 nil（跳过该窗口）
    static func windowSeconds(duration: Int, timeUnit: String) -> TimeInterval? {
        switch timeUnit {
        case "TIME_UNIT_MINUTE": return TimeInterval(duration * 60)
        case "TIME_UNIT_HOUR": return TimeInterval(duration * 3600)
        case "TIME_UNIT_DAY": return TimeInterval(duration * 86400)
        case "TIME_UNIT_WEEK": return TimeInterval(duration * 604800)
        default: return nil
        }
    }

    static func windowLabel(duration: Int, timeUnit: String) -> String {
        switch timeUnit {
        case "TIME_UNIT_MINUTE":
            return duration % 60 == 0 ? "\(duration / 60) 小时限流窗" : "\(duration) 分钟限流窗"
        case "TIME_UNIT_HOUR": return "\(duration) 小时限流窗"
        case "TIME_UNIT_DAY":
            return duration % 7 == 0 ? "\(duration / 7) 周限流窗" : "\(duration) 天限流窗"
        case "TIME_UNIT_WEEK": return "\(duration) 周限流窗"
        default: return "限流窗"
        }
    }

    static func windowIDSuffix(timeUnit: String) -> String {
        switch timeUnit {
        case "TIME_UNIT_MINUTE": return "m"
        case "TIME_UNIT_HOUR": return "h"
        case "TIME_UNIT_DAY": return "d"
        case "TIME_UNIT_WEEK": return "w"
        default: return "?"
        }
    }

    public static func parse(data: Data, now: Date = Date()) throws -> ProviderReport {
        // 错误响应优先：只暴露错误码，不透传服务端自由文本（DESIGN.md §10）
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let errObj = obj["error"] as? [String: Any]
            if let code = (errObj?["code"] as? String) ?? (obj["code"] as? String) {
                throw ProviderError.parse("kimi: \(code)")
            }
        }
        let decoded: UsagesResponse
        do {
            decoded = try JSONDecoder().decode(UsagesResponse.self, from: data)
        } catch {
            throw ProviderError.parse("kimi: \(error.localizedDescription)")
        }
        let iso = makeISO8601()
        var quotas: [Quota] = []

        // usage = 每周配额（7 天窗口；数值为百分比，limit 恒为 100，unit 记 .credits）
        if let usage = decoded.usage,
           let limit = Double(usage.limit), limit > 0,
           let used = Double(usage.used),
           let reset = iso.date(from: usage.resetTime) {
            quotas.append(Quota(
                id: "kimi.7d",
                type: .timeWindowed,
                label: "每周额度",
                unit: .credits,
                used: used,
                limit: limit,
                remaining: usage.remaining.flatMap(Double.init),
                windowStart: reset.addingTimeInterval(-weeklyWindow),
                resetsAt: reset
            ))
        }

        // limits[] = 滚动限流窗（如 300 分钟 = 5 小时）；limit==0 / 数值异常 / 未知时间单位 -> 跳过
        for entry in decoded.limits ?? [] {
            guard let seconds = windowSeconds(duration: entry.window.duration, timeUnit: entry.window.timeUnit),
                  let limit = Double(entry.detail.limit), limit > 0,
                  let used = Double(entry.detail.used),
                  let reset = iso.date(from: entry.detail.resetTime) else { continue }
            quotas.append(Quota(
                id: "kimi.rate.\(entry.window.duration)\(windowIDSuffix(timeUnit: entry.window.timeUnit))",
                type: .timeWindowed,
                label: windowLabel(duration: entry.window.duration, timeUnit: entry.window.timeUnit),
                unit: .credits,
                used: used,
                limit: limit,
                remaining: entry.detail.remaining.flatMap(Double.init),
                windowStart: reset.addingTimeInterval(-seconds),
                resetsAt: reset
            ))
        }

        // boosterWallet = 加油包余额；仅 STATUS_ENABLED 时映射为 balance 型（CNY，priceInCents 为分）。
        // 拿不到数值就跳过，不硬编。
        if let wallet = decoded.boosterWallet, wallet.status == "STATUS_ENABLED",
           let chargeLimit = wallet.monthlyChargeLimit,
           let limitCents = Double(chargeLimit.priceInCents) {
            let usedCents = wallet.monthlyUsed.flatMap { Double($0.priceInCents) }
            quotas.append(Quota(
                id: "kimi.booster",
                type: .balance,
                label: "加油包",
                unit: .cny,
                used: usedCents.map { $0 / 100 },
                limit: limitCents / 100,
                remaining: usedCents.map { (limitCents - $0) / 100 }
            ))
        }

        return ProviderReport(providerId: "kimi", fetchedAt: now, quotas: quotas)
    }
}
