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

    /// provider 级紧急度 = 所有可评分 quota 的最小值
    public static func providerScore(quotas: [Quota], etas: [String: TimeInterval?]) -> Double? {
        quotas.compactMap { score(quota: $0, etaSeconds: etas[$0.id] ?? nil) }.min()
    }
}
