import Foundation

/// MiniMax（bearer / 滚动时间窗 Token Plan 配额），DESIGN.md §5 扩展。
/// 无公开余额 API：走 Token Plan 配额接口 `GET /v1/token_plan/remains`
/// （api.minimaxi.com 中国大陆 / api.minimax.io 国际，Bearer 认证）。
/// 每个套餐额度（文本模型 5 小时窗、媒体日窗等）返回一个 `model_remains[]`
/// bucket，各带滚动 interval 窗口与 weekly 窗口及剩余百分比。
/// 注意：MiniMax 凭证被拒时也返回 HTTP 200，必须以 `base_resp.status_code` 判定成败；
/// 且 `current_*_usage_count` 名为 usage、实为**剩余**额度（与控制台核对，社区工具同）。
public struct MiniMaxProvider: Provider {
    public let manifest = ProviderManifest(
        id: "minimax",
        displayName: "MiniMax",
        authMode: .bearer,
        defaultBaseURL: "https://api.minimaxi.com",
        allowsBaseURLOverride: true,
        defaultPollInterval: 120,   // 5 小时滚动窗：短窗勤拉（默认值参考表）
        shortName: "mmx",
        consoleURL: "https://platform.minimaxi.com/user-center/basic-information/interface-key",
        logoName: "minimax_logo",
        themeColor: .red
    )
    public let supportedQuotaTypes: [QuotaType] = [.timeWindowed]

    private let baseURL: String
    private let http: HTTPClient

    public init(baseURL: String? = nil, http: HTTPClient = URLSessionHTTPClient()) {
        guard let url = baseURL ?? manifest.defaultBaseURL else {
            fatalError("MiniMaxProvider: manifest missing defaultBaseURL")
        }
        self.baseURL = url
        self.http = http
    }

    public func fetchUsage(credential: Credential) async throws -> ProviderReport {
        guard case .bearer(let token) = credential else { throw ProviderError.missingCredential }

        guard let url = URL(string: baseURL + "/v1/token_plan/remains") else {
            throw ProviderError.network("invalid baseURL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await http.send(request)
        if let error = ProviderError.fromStatus(response.status) { throw error }
        return try Self.parse(data: response.data)
    }

    // MARK: - Parsing

    struct RemainsResponse: Decodable {
        let base_resp: BaseResp?
        let model_remains: [ModelRemainDTO]?
    }
    struct BaseResp: Decodable {
        let status_code: Int
    }
    struct ModelRemainDTO: Decodable {
        let model_name: String?
        /// 毫秒时间戳（容忍秒级）
        let start_time: Int64?
        let end_time: Int64?
        let current_interval_remaining_percent: Int?
        let current_interval_total_count: Int64?
        /// 名为 usage、实为**剩余**额度（与控制台核对）
        let current_interval_usage_count: Int64?
        /// 1 = 正常，2 = 已耗尽，3 = 无限（不在套餐）
        let current_interval_status: Int?
        let weekly_start_time: Int64?
        let weekly_end_time: Int64?
        let current_weekly_remaining_percent: Int?
        let current_weekly_total_count: Int64?
        let current_weekly_usage_count: Int64?
        let current_weekly_status: Int?
    }

    static func parseTimestamp(_ raw: Int64?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        let seconds = raw < 1_000_000_000_000 ? Double(raw) : Double(raw) / 1000
        return Date(timeIntervalSince1970: seconds)
    }

    /// 间隔窗口 ID/标签按实际跨度（文本 5h、媒体日级）；非整小时记分钟。
    static func intervalWindow(durationMs: Int64?) -> (id: String, label: String) {
        guard let durationMs, durationMs > 0 else { return ("interval", "滚动额度") }
        let hours = Double(durationMs) / 3_600_000
        if hours >= 1, hours.rounded() == hours {
            return ("\(Int(hours))h", "\(Int(hours)) 小时额度")
        }
        let minutes = Int((Double(durationMs) / 60_000).rounded())
        return minutes > 0 ? ("\(minutes)m", "\(minutes) 分钟额度") : ("interval", "滚动额度")
    }

    /// 模型名 -> Quota.id 片段（仅保留字母数字与横线，全小写）。
    static func modelKey(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" })
    }

    /// 由窗口计数构建 Quota。usageCount 语义为剩余；status==2 强制置 0。
    /// limit 缺失或为 0 = 未订阅该窗口 -> 不产出（避免误导性 0% 与除零）。
    static func buildWindowQuota(
        modelName: String, windowId: String, label: String,
        totalCount: Int64?, usageCount: Int64?, remainingPercent: Int?,
        status: Int?, start: Int64?, end: Int64?
    ) -> Quota? {
        guard let totalCount, totalCount > 0 else { return nil }
        var remaining: Double
        if let usageCount {
            remaining = Double(usageCount)
        } else if let remainingPercent {
            remaining = Double(totalCount) * Double(remainingPercent) / 100
        } else {
            return nil
        }
        if status == 2 { remaining = 0 }   // 已耗尽：无论百分比/计数是否过期
        remaining = min(max(remaining, 0), Double(totalCount))

        return Quota(
            id: "minimax.\(modelKey(modelName)).\(windowId)",
            type: .timeWindowed,
            label: "\(modelName) \(label)",
            unit: .credits,               // 请求次数配额（非 token/货币，禁止跨 unit 聚合）
            used: Double(totalCount) - remaining,
            limit: Double(totalCount),
            remaining: remaining,
            windowStart: parseTimestamp(start),
            resetsAt: parseTimestamp(end)
        )
    }

    public static func parse(data: Data, now: Date = Date()) throws -> ProviderReport {
        let decoded: RemainsResponse
        do {
            decoded = try JSONDecoder().decode(RemainsResponse.self, from: data)
        } catch {
            throw ProviderError.parse("minimax: \(error.localizedDescription)")
        }
        // MiniMax 凭证被拒也返回 HTTP 200：以 base_resp.status_code 判定成败
        guard let base = decoded.base_resp else {
            throw ProviderError.parse("minimax: missing base_resp")
        }
        // 只暴露错误码，不透传服务端自由文本（DESIGN.md §10）
        guard base.status_code == 0 else {
            throw ProviderError.parse("minimax: code \(base.status_code)")
        }

        var quotas: [Quota] = []
        for bucket in decoded.model_remains ?? [] {
            guard let modelName = bucket.model_name, !modelName.isEmpty else { continue }
            let interval = intervalWindow(durationMs: (bucket.end_time ?? 0) - (bucket.start_time ?? 0))
            if let q = buildWindowQuota(
                modelName: modelName, windowId: interval.id, label: interval.label,
                totalCount: bucket.current_interval_total_count,
                usageCount: bucket.current_interval_usage_count,
                remainingPercent: bucket.current_interval_remaining_percent,
                status: bucket.current_interval_status,
                start: bucket.start_time, end: bucket.end_time) {
                quotas.append(q)
            }
            if let q = buildWindowQuota(
                modelName: modelName, windowId: "7d", label: "周额度",
                totalCount: bucket.current_weekly_total_count,
                usageCount: bucket.current_weekly_usage_count,
                remainingPercent: bucket.current_weekly_remaining_percent,
                status: bucket.current_weekly_status,
                start: bucket.weekly_start_time, end: bucket.weekly_end_time) {
                quotas.append(q)
            }
        }
        // 全 unlimited / 空 = 未订阅 Token Plan：返回空报告（正常态，不抛错）
        return ProviderReport(providerId: "minimax", fetchedAt: now, quotas: quotas)
    }
}
