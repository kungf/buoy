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

/// Measurement unit. Units must not be summed across providers (DESIGN.md §3.2)
public enum Unit: Codable, Sendable, Equatable {
    case tokens
    /// 火山 AFP 点数
    case credits
    case usd
    case cny
    /// No unit (custom metrics without a configured unit show a bare number)
    case none
    /// Arbitrary custom unit text (e.g. "GBP"). Encoded as {"custom":"GBP"},
    /// distinct from the plain-string format of the fixed cases.
    case custom(String)

    /// Serialized name of the fixed cases (the legacy cache format)
    private var fixedName: String? {
        switch self {
        case .tokens: return "tokens"
        case .credits: return "credits"
        case .usd: return "usd"
        case .cny: return "cny"
        case .none: return "none"
        case .custom: return nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        if let name = fixedName {
            var container = encoder.singleValueContainer()
            try container.encode(name)
            return
        }
        if case .custom(let text) = self {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(text, forKey: .custom)
        }
    }

    public init(from decoder: Decoder) throws {
        // Legacy/fixed cases: plain strings ("tokens" etc.)
        if let container = try? decoder.singleValueContainer(),
           let raw = try? container.decode(String.self) {
            switch raw {
            case "tokens": self = .tokens
            case "credits": self = .credits
            case "usd": self = .usd
            case "cny": self = .cny
            case "none": self = .none
            default: self = .custom(raw)
            }
            return
        }
        // New format: .custom(text) → {"custom":"GBP"}
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.custom) {
            self = .custom(try container.decode(String.self, forKey: .custom))
            return
        }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "unknown Unit value"))
    }

    private enum CodingKeys: String, CodingKey { case custom }
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
    /// Water-level direction (only meaningful for timeWindowed): true = used proportion
    /// (used/limit, full = drained, custom-metric used semantics); false = remaining
    /// proportion (default, full = healthy, built-in providers).
    public let showsUsedLevel: Bool

    public init(
        id: String,
        type: QuotaType,
        label: String,
        unit: Unit,
        used: Double? = nil,
        limit: Double? = nil,
        remaining: Double? = nil,
        windowStart: Date? = nil,
        resetsAt: Date? = nil,
        showsUsedLevel: Bool = false
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
        self.showsUsedLevel = showsUsedLevel
    }

    /// Custom decode: showsUsedLevel is a defaulted `let`, which the synthesized decoder
    /// silently drops ("immutable property will not be decoded") — used-semantics quotas
    /// would lose the water direction across the cache.json round-trip and revert on
    /// restart. Legacy caches without the field decode to false.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(QuotaType.self, forKey: .type)
        label = try container.decode(String.self, forKey: .label)
        unit = try container.decode(Unit.self, forKey: .unit)
        used = try container.decodeIfPresent(Double.self, forKey: .used)
        limit = try container.decodeIfPresent(Double.self, forKey: .limit)
        remaining = try container.decodeIfPresent(Double.self, forKey: .remaining)
        windowStart = try container.decodeIfPresent(Date.self, forKey: .windowStart)
        resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
        showsUsedLevel = try container.decodeIfPresent(Bool.self, forKey: .showsUsedLevel) ?? false
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
