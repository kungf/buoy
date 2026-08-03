import Foundation

/// 余额型附加信息（货币、赠送 vs 充值拆分），DESIGN.md §3.3
public struct BalanceInfo: Codable, Sendable, Equatable {
    public let currency: String
    public let total: Double
    public let granted: Double
    public let toppedUp: Double

    public init(currency: String, total: Double, granted: Double, toppedUp: Double) {
        self.currency = currency
        self.total = total
        self.granted = granted
        self.toppedUp = toppedUp
    }
}

/// 一次拉取的结果（DESIGN.md §3.3）
public struct ProviderReport: Codable, Sendable, Equatable {
    public let providerId: String
    public let fetchedAt: Date
    public let quotas: [Quota]
    public let balance: BalanceInfo?
    /// 订阅型套餐是否已过期（如 MiMo Token Plan）。nil = 不适用。
    /// Optional 保持 Codable 向后兼容：旧缓存（无此字段）仍可解码。
    public let planExpired: Bool?

    public init(providerId: String, fetchedAt: Date, quotas: [Quota],
                balance: BalanceInfo? = nil, planExpired: Bool? = nil) {
        self.providerId = providerId
        self.fetchedAt = fetchedAt
        self.quotas = quotas
        self.balance = balance
        self.planExpired = planExpired
    }
}
