import Foundation

/// 一次采样点
public struct UsageSample: Sendable, Equatable, Codable {
    public let at: Date
    public let used: Double
    public init(at: Date, used: Double) {
        self.at = at
        self.used = used
    }
}

/// 燃烧率估计器（DESIGN.md §7）。
/// 相邻样本对参与拟合的条件：
///  ① 未跨过 resetsAt（reset 后 Used 跳回 0，负 delta 丢弃）
///  ② 相邻 fetchedAt 间隔 < 3× 轮询周期（睡眠/唤醒空洞丢弃）
/// 冷启动：有效样本不足 minSamples 时 ETA 为 nil（UI 显示 "--"，不触发预警）。
public struct BurnRateEstimator: Sendable, Equatable, Codable {
    public let minSamples: Int
    public let maxGapMultiplier: Double

    public init(minSamples: Int = 3, maxGapMultiplier: Double = 3.0) {
        self.minSamples = minSamples
        self.maxGapMultiplier = maxGapMultiplier
    }

    /// 过滤出可用于拟合的样本序列（丢弃 reset 跨界点与睡眠空洞后的断裂段）。
    /// - Parameters:
    ///   - samples: 按时间升序的采样点
    ///   - pollInterval: 该 quota 的轮询周期（秒）
    /// - Returns: 连续且合法的样本段（取最后一段，因为最新的才反映"当前速度"）
    public func validSegment(samples: [UsageSample], pollInterval: TimeInterval) -> [UsageSample] {
        guard samples.count >= 2 else { return samples }
        var segments: [[UsageSample]] = [[samples[0]]]
        for i in 1..<samples.count {
            let prev = samples[i - 1]
            let cur = samples[i]
            let gap = cur.at.timeIntervalSince(prev.at)
            let crossedReset = cur.used < prev.used
            let gapTooLarge = gap > pollInterval * maxGapMultiplier
            if crossedReset || gapTooLarge {
                segments.append([cur])
            } else {
                segments[segments.count - 1].append(cur)
            }
        }
        return segments.last ?? []
    }

    /// 最小二乘拟合斜率（单位/秒）。样本不足或时间跨度为 0 时返回 nil。
    public func burnRate(samples: [UsageSample], pollInterval: TimeInterval) -> Double? {
        let segment = validSegment(samples: samples, pollInterval: pollInterval)
        guard segment.count >= minSamples,
              let t0 = segment.first?.at,
              let t1 = segment.last?.at,
              t1 > t0 else { return nil }

        let times = segment.map { $0.at.timeIntervalSince(t0) }
        let values = segment.map(\.used)
        let n = Double(segment.count)
        let meanT = times.reduce(0, +) / n
        let meanV = values.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in 0..<segment.count {
            num += (times[i] - meanT) * (values[i] - meanV)
            den += (times[i] - meanT) * (times[i] - meanT)
        }
        guard den > 0 else { return nil }
        let slope = num / den
        return slope > 0 ? slope : nil
    }

    /// ETA（秒）= remaining / burnRate。无法估计时返回 nil。
    public func eta(remaining: Double, samples: [UsageSample], pollInterval: TimeInterval) -> TimeInterval? {
        guard let rate = burnRate(samples: samples, pollInterval: pollInterval), rate > 0 else { return nil }
        return remaining / rate
    }
}
