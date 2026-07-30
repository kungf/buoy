import Foundation

/// 球面状态（DESIGN.md §8.4 视觉编码）。驱动动画节奏与着色，越靠后越紧急。
public enum BallState: String, Sendable, Equatable {
    /// 近 K 分钟无消耗：绿，缓慢呼吸
    case idle
    /// 正常速率消耗：绿->青，液面缓变
    case consuming
    /// 燃烧率突增：黄，呼吸加快 + 热气粒子
    case fastBurn
    /// windowed>85% / balance ETA<1天：橙，轻微抖动
    case nearDepleted
    /// 窗口耗尽 / 余额近 0：红，慢闪
    case depleted
    /// 拉取失败 / 陈旧：灰，脉冲虚线
    case error
    /// 未配置凭证：不报警，平静显示"需配置"
    case notConfigured
}

/// 纯函数状态解析（与 HealthScore 同层，可单测；DESIGN.md §8.4）。
///
/// 输入均为派生量，调用方负责计算：
/// - `health` 0...1（nil = 未知 / 冷启动）
/// - `burnRate` / `expectedBurnRate` 同量纲（单位/秒）；`expectedBurnRate` 仅 windowed 型可算
///   （= limit / 窗口秒数），balance 型传 nil -> 不触发 fast-burn
/// - `hasError` / `isStale` 由拉取结果与陈旧度判定
///
/// 优先级（高 -> 低）：error > depleted > nearDepleted > fastBurn > consuming > idle。
/// 级别（depleted/nearDepleted）优先于速率（fastBurn）：临近耗尽时按级别告警更可执行。
public enum BallStateResolver {
    public static let depletedThreshold: Double = 0.05
    public static let nearDepletedThreshold: Double = 0.15
    public static let consumingThreshold: Double = 0.5
    /// 燃烧率突增倍数：实际 > 期望 × 此值 = fast-burn（DESIGN.md §8.4 "燃烧率突增"）
    public static let fastBurnMultiplier: Double = 2.0

    public static func resolve(
        health: Double?,
        burnRate: Double?,
        expectedBurnRate: Double?,
        hasError: Bool,
        isStale: Bool
    ) -> BallState {
        if hasError || isStale { return .error }
        guard let health else { return .idle }
        if health < depletedThreshold { return .depleted }
        if health < nearDepletedThreshold { return .nearDepleted }
        if let burnRate, let expectedBurnRate, expectedBurnRate > 0,
           burnRate > expectedBurnRate * fastBurnMultiplier {
            return .fastBurn
        }
        if health < consumingThreshold { return .consuming }
        return .idle
    }
}
