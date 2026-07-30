import Foundation

/// 计费形态（DESIGN.md §3.1）
public enum QuotaType: String, Codable, Sendable {
    /// 滚动时间窗：有 windowStart/End，到点 reset（火山 5h/7d/30d、MiMo 月度等）
    case timeWindowed
    /// 余额型：纯账户余额，无时间窗 reset（DeepSeek）
    case balance
    /// 速率限制：TPM/RPM（MVP 不接）
    case rateLimit
}

/// 计量单位。不同 unit 之间禁止跨 provider 聚合求和（DESIGN.md §3.2）
public enum Unit: String, Codable, Sendable {
    case tokens
    /// 火山 AFP 点数
    case credits
    case usd
    case cny
}

/// 统一额度模型（DESIGN.md §3.2）。
/// 派生量（percent / eta / healthScore）由上层计算，不存于此，保持值类型纯净。
public struct Quota: Identifiable, Codable, Sendable, Equatable {
    /// 如 "volcano.5h" / "deepseek.balance"
    public let id: String
    public let type: QuotaType
    /// 展示名，如 "5 小时额度" / "账户余额"
    public let label: String
    public let unit: Unit

    /// 已用（部分 provider 只给 used，无 limit）
    public let used: Double?
    /// 上限（nil = 无上限 / 未知）
    public let limit: Double?
    /// 剩余（部分 provider 直接给）
    public let remaining: Double?

    /// 仅 timeWindowed
    public let windowStart: Date?
    /// 窗口结束 / reset 时刻
    public let resetsAt: Date?

    public init(
        id: String,
        type: QuotaType,
        label: String,
        unit: Unit,
        used: Double? = nil,
        limit: Double? = nil,
        remaining: Double? = nil,
        windowStart: Date? = nil,
        resetsAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.unit = unit
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.windowStart = windowStart
        self.resetsAt = resetsAt
    }
}

public extension Quota {
    /// 已用比例 [0, 1]。limit 缺失或为 0 时返回 nil（Quota=0 的窗口不应存在，见 VolcanoProvider）。
    var percentUsed: Double? {
        if let used, let limit, limit > 0 {
            return min(max(used / limit, 0), 1)
        }
        if let remaining, let limit, limit > 0 {
            return min(max(1 - remaining / limit, 0), 1)
        }
        return nil
    }

    /// 剩余量（优先显式 remaining，其次 limit - used）
    var effectiveRemaining: Double? {
        if let remaining { return remaining }
        if let used, let limit { return max(limit - used, 0) }
        return nil
    }

    /// Used% at the given time. For a `timeWindowed` quota whose window has
    /// already reset (`now >= resetsAt`), returns 0 regardless of the cached
    /// `used` value — so the UI shows the new empty window immediately even
    /// when polling is paused (e.g. the Mac slept through the reset).
    /// Falls through to `percentUsed` otherwise.
    func percentUsedAt(now: Date) -> Double? {
        if type == .timeWindowed, let resetsAt, now >= resetsAt {
            return 0
        }
        return percentUsed
    }
}
