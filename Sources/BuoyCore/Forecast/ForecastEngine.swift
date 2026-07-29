import Foundation

/// 预测引擎：收集每个 quota 的采样点，估算燃烧率与 ETA（DESIGN.md §7）。
///
/// 值类型（struct 语义）：`ingest` 产生新拷贝，无共享可变状态（coding-style immutability）。
/// Phase 1：内存环形 buffer；持久化与 per-provider 轮询间隔在 Phase 2 补。
///
/// **采样量约定**：BurnRateEstimator 期望一个"消耗时单调递增"的量，并把"回落"视作 reset/断段。
/// - windowed：直接用 `used`（窗口内单调递增，reset 后跳回 0 -> 自然断段）。
/// - balance：用 `-remaining`。余额消耗时 remaining 递减 -> `-remaining` 递增；充值/赠送到期回升
///   时 remaining 跳升 -> `-remaining` 回落 -> 触发断段（即 DESIGN §13 的"跳崖识别"基线重置）。
///   这样复用已有 reset 启发式，无需改动 BurnRateEstimator。
public struct ForecastEngine: Sendable, Equatable {
    private var samplesByQuota: [String: [UsageSample]] = [:]
    public let maxSamplesPerQuota: Int
    public let estimator: BurnRateEstimator

    public init(maxSamplesPerQuota: Int = 120, estimator: BurnRateEstimator = BurnRateEstimator()) {
        self.maxSamplesPerQuota = maxSamplesPerQuota
        self.estimator = estimator
    }

    /// 摄入一次拉取结果：对每个可追踪的 quota 追加一个采样点（超出容量丢最旧）。
    public mutating func ingest(report: ProviderReport, pollInterval: TimeInterval) {
        for quota in report.quotas {
            guard let value = sampleValue(for: quota) else { continue }
            var samples = samplesByQuota[quota.id] ?? []
            samples.append(UsageSample(at: report.fetchedAt, used: value))
            if samples.count > maxSamplesPerQuota {
                samples.removeFirst(samples.count - maxSamplesPerQuota)
            }
            samplesByQuota[quota.id] = samples
        }
    }

    /// 该 quota 的采样序列（按时间升序）。供 sparkline 直接取用。
    public func samples(for quotaId: String) -> [UsageSample] {
        samplesByQuota[quotaId] ?? []
    }

    /// 燃烧率（单位/秒）。冷启动或样本不足返回 nil。
    public func burnRate(for quota: Quota, pollInterval: TimeInterval) -> Double? {
        estimator.burnRate(samples: samples(for: quota.id), pollInterval: pollInterval)
    }

    /// ETA（秒）= remaining / burnRate。无法估计时返回 nil（UI 显示 "--"）。
    public func eta(for quota: Quota, pollInterval: TimeInterval) -> TimeInterval? {
        guard let remaining = quota.effectiveRemaining, remaining > 0,
              let rate = burnRate(for: quota, pollInterval: pollInterval), rate > 0 else { return nil }
        return remaining / rate
    }

    /// 单调递增的采样代理量。rateLimit 不追踪。
    private func sampleValue(for quota: Quota) -> Double? {
        switch quota.type {
        case .timeWindowed:
            return quota.used
        case .balance:
            return quota.effectiveRemaining.map { -$0 }
        case .rateLimit:
            return nil
        }
    }
}
