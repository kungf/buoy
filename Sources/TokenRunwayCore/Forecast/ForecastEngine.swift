import Foundation

/// Forecast engine: collects per-quota samples and estimates burn rate / ETA
/// (DESIGN.md §7).
///
/// Value type (struct semantics): `ingest` produces a new copy with no shared
/// mutable state (coding-style immutability). Phase 1: in-memory ring buffer;
/// persistence and per-provider poll intervals land in Phase 2.
///
/// **Sample-value convention**: BurnRateEstimator expects a quantity that is
/// monotonic while being consumed, and treats any drop as a reset / segment break.
/// - windowed: use `used` directly (monotonic within a window; reset to 0 ->
///   natural segment break).
/// - balance: use `-remaining`. Spending drops `remaining` -> `-remaining`
///   rises; a top-up / grant expiry raises `remaining` -> `-remaining` drops ->
///   triggers a segment break (the "cliff detection" baseline reset from
///   DESIGN §13). This reuses the existing reset heuristic, so BurnRateEstimator
///   needs no changes.
public struct ForecastEngine: Sendable, Equatable, Codable {
    private var samplesByQuota: [String: [UsageSample]] = [:]
    public let maxSamplesPerQuota: Int
    public let estimator: BurnRateEstimator

    public init(maxSamplesPerQuota: Int = 100, estimator: BurnRateEstimator = BurnRateEstimator()) {
        self.maxSamplesPerQuota = maxSamplesPerQuota
        self.estimator = estimator
    }

    /// Ingest one fetch result: append a sample for each trackable quota
    /// (drop oldest beyond capacity).
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

    /// Sample sequence for this quota (ascending by time). Used directly by sparklines.
    public func samples(for quotaId: String) -> [UsageSample] {
        samplesByQuota[quotaId] ?? []
    }

    /// Burn rate (units / second). nil on cold start or insufficient samples.
    public func burnRate(for quota: Quota, pollInterval: TimeInterval) -> Double? {
        estimator.burnRate(samples: samples(for: quota.id), pollInterval: pollInterval)
    }

    /// ETA (seconds) = remaining / burnRate. nil when not estimable (UI shows "--").
    public func eta(for quota: Quota, pollInterval: TimeInterval) -> TimeInterval? {
        guard let remaining = quota.effectiveRemaining, remaining > 0,
              let rate = burnRate(for: quota, pollInterval: pollInterval), rate > 0 else { return nil }
        return remaining / rate
    }

    /// Spend over the trailing `windowSeconds` (e.g. last 5h), top-up-robust.
    ///
    /// Sums only positive `used` deltas across consecutive in-window samples:
    /// for balance quotas `used = -remaining`, so a spend (remaining down) is a
    /// positive delta and a top-up (remaining up) is clipped to 0. This is
    /// additive (no division by a near-zero rate), so a static balance yields 0
    /// instead of an exploding ETA. Returns nil on cold start (<2 in-window samples).
    ///
    /// Gap-spanning pairs are intentionally kept: a net decrease across a gap can
    /// only under-report true spend (top-ups offset), never over-report.
    public func consumed(for quota: Quota, windowSeconds: TimeInterval, now: Date) -> Double? {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        let windowed = samples(for: quota.id).filter { $0.at >= cutoff }
        guard windowed.count >= 2 else { return nil }
        var spent: Double = 0
        for i in 1..<windowed.count {
            let delta = windowed[i].used - windowed[i - 1].used
            if delta > 0 { spent += delta }
        }
        return spent
    }

    /// Monotonic sample-proxy quantity. rateLimit is not tracked.
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
