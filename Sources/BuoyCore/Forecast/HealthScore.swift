import Foundation

/// Health score（DESIGN.md §7）：跨 quota 统一紧急度，越低越紧急。
/// windowed = remaining / limit；balance = ETA 健康度归一（>7 天 = 1.0，<1 天 ≈ 0）。
/// provider 紧急度取其所有 quota 的最小值；error / stale 不参与排序。
public enum HealthScore {
    /// 窗口型：剩余比例
    public static func forWindowed(quota: Quota) -> Double? {
        guard let limit = quota.limit, limit > 0,
              let remaining = quota.effectiveRemaining else { return nil }
        return min(max(remaining / limit, 0), 1)
    }

    /// Windowed health at a given time. If the quota's window has already reset
    /// (`now >= resetsAt`), reports 1.0 (full health) regardless of the cached
    /// `used` value — mirrors `Quota.percentUsedAt(now:)` so a stale cache
    /// after Mac sleep does not paint the ball red for an already-reset window.
    public static func forWindowed(quota: Quota, now: Date) -> Double? {
        if quota.type == .timeWindowed, let resetsAt = quota.resetsAt, now >= resetsAt {
            return 1.0
        }
        return forWindowed(quota: quota)
    }

    /// 余额型：按 ETA 天数归一（7 天及以上 = 健康满分）
    public static func forBalance(etaSeconds: TimeInterval?) -> Double? {
        guard let etaSeconds else { return nil }
        let days = etaSeconds / 86_400
        return min(max(days / 7, 0), 1)
    }

    public static func score(quota: Quota, etaSeconds: TimeInterval?) -> Double? {
        switch quota.type {
        case .timeWindowed:
            return forWindowed(quota: quota)
        case .balance:
            return forBalance(etaSeconds: etaSeconds)
        case .rateLimit:
            return nil
        }
    }

    /// `now`-aware score: routes windowed quotas through `forWindowed(quota:now:)`
    /// so expired windows read as full health. Balance / rateLimit unchanged.
    public static func score(quota: Quota, etaSeconds: TimeInterval?, now: Date) -> Double? {
        switch quota.type {
        case .timeWindowed:
            return forWindowed(quota: quota, now: now)
        case .balance:
            return forBalance(etaSeconds: etaSeconds)
        case .rateLimit:
            return nil
        }
    }

    /// provider 级紧急度 = 所有可评分 quota 的最小值
    public static func providerScore(quotas: [Quota], etas: [String: TimeInterval?]) -> Double? {
        quotas.compactMap { score(quota: $0, etaSeconds: etas[$0.id] ?? nil) }.min()
    }

    /// `now`-aware provider score. See `score(quota:etaSeconds:now:)`.
    public static func providerScore(quotas: [Quota], etas: [String: TimeInterval?], now: Date) -> Double? {
        quotas.compactMap { score(quota: $0, etaSeconds: etas[$0.id] ?? nil, now: now) }.min()
    }
}
