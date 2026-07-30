import Foundation

/// 指数退避策略（DESIGN.md §6：429/5xx 指数退避，上限 5 次）。
/// delay = base * min(factor^failures, maxMultiplier)。值类型，可单测。
public struct BackoffPolicy: Sendable, Equatable {
    public let factor: Double
    public let maxMultiplier: Double
    public let maxRetries: Int

    public init(factor: Double = 2, maxMultiplier: Double = 5, maxRetries: Int = 5) {
        self.factor = factor
        self.maxMultiplier = maxMultiplier
        self.maxRetries = maxRetries
    }

    /// 连续失败 failures 次后的下一次轮询延迟。
    public func delay(base: TimeInterval, afterFailures failures: Int) -> TimeInterval {
        let exp = Double(max(0, failures))
        let multiplier = min(pow(factor, exp), maxMultiplier)
        return base * multiplier
    }

    /// 超过 maxRetries 次连续失败 -> 视为进入 error 态（不再快速重试，DESIGN.md §6）。
    public func isErrorState(afterFailures failures: Int) -> Bool {
        failures >= maxRetries
    }
}
