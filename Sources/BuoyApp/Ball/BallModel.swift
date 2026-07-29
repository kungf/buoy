import SwiftUI
import BuoyCore

/// 逃逸徽标严重度（DESIGN.md §8.4 状态 -> 徽标着色）。
enum BadgeSeverity: String, Equatable {
    case fastBurn, nearDepleted, depleted, error
}

/// 单个逃逸徽标（DESIGN.md §8.1）：非展示 provider 告急时球边缘的主题色小圆点。
struct AlertBadge: Equatable, Identifiable {
    /// providerId
    let id: String
    let severity: BadgeSeverity
}

/// 球面展示模型：把 store 状态压成一个值，`BallView` 只负责渲染（DESIGN.md §8）。
/// 纯值类型；由 `UsageStore.ballModel` 构造。
struct BallModel: Equatable {
    enum Mode: Equatable { case windowed, balance, error, cold }

    let mode: Mode
    /// 外环已用比例 0...1（DESIGN §8.3 进度环 = 已用 %）；balance / error / cold 下为 nil（不画环）
    let ringUsed: Double?
    /// 核心液面 0...1（windowed = 剩余%，耗尽抽空；balance = ETA 健康度）
    let coreRemaining: Double?
    let health: Double?
    /// 中央文字："73%" | "¥42.50" | "!" | "--"
    let centerText: String
    /// 副文字："5h" | "≈3.2天" | "error" | ""
    let subText: String
    /// 货币角标："¥" | "$" | nil（仅 balance）
    let currencyBadge: String?
    let state: BallState
    /// 呼吸紧迫度 0...1（ETA 映射，越近耗尽越急，DESIGN.md §8.4）
    let breathUrgency: Double
    let isStale: Bool
    /// 非展示 provider 的告急徽标
    let alertBadges: [AlertBadge]
}

/// 徽标布局：固定极坐标，便于 `BallEventView` 命中测试（DESIGN.md §8.1 球边缘）。
/// 位置以"球心为原点、y 向上为正"返回；view 与命中测试用同一换算。
enum BadgeLayout {
    static let maxBadges = 3
    static let dotDiameter: CGFloat = 12

    /// count 个徽标圆心相对球心的偏移（y 向上为正），沿球面右上弧分布。
    static func positions(count: Int, ballSize: CGFloat) -> [CGPoint] {
        let n = min(max(count, 0), maxBadges)
        guard n > 0 else { return [] }
        let r = ballSize / 2
        // 从正上(pi/2)到正右(0)，沿右上弧等角分布
        let start = CGFloat.pi / 2
        let span: CGFloat = -CGFloat.pi / 2
        let step = n > 1 ? span / CGFloat(n - 1) : 0
        return (0..<n).map { i in
            let angle = start + CGFloat(i) * step
            return CGPoint(x: r * cos(angle), y: r * sin(angle))
        }
    }
}

// MARK: - 共享格式化助手

/// 货币代码 -> 符号
func currencySymbol(_ code: String) -> String {
    switch code.uppercased() {
    case "CNY", "RMB": return "¥"
    case "USD": return "$"
    default: return code
    }
}

/// quotaId 末段短标签："volcano.5h" -> "5h"
func shortLabel(_ id: String) -> String {
    guard let suffix = id.split(separator: ".").last else { return "" }
    return String(suffix)
}

/// ETA -> 呼吸紧迫度：<5min=1.0（急促），>2h=0（平静），之间线性（DESIGN.md §8.4）。
func breathUrgency(from eta: TimeInterval?) -> Double {
    guard let eta else { return 0 }
    let hours = eta / 3600
    return min(max(1 - hours / 2, 0), 1)
}
