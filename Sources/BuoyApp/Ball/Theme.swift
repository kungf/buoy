import SwiftUI
import BuoyCore

/// 健康度 → 颜色（DESIGN.md §7：绿 >0.5 / 橙 0.2~0.5 / 红 <0.2 / 无数据灰）
enum Theme {
    static func healthColor(_ score: Double?) -> Color {
        guard let score else { return .gray }
        switch score {
        case ..<0.2: return .red
        case ..<0.5: return .orange
        default: return .green
        }
    }

    /// 球面状态 -> 颜色（DESIGN.md §8.4 视觉编码）。
    /// ring 用 healthColor（月度 ambient），core 用 stateColor（活跃窗口状态）。
    static func stateColor(_ state: BallState) -> Color {
        switch state {
        case .idle, .consuming: return .green
        case .fastBurn: return .yellow
        case .nearDepleted: return .orange
        case .depleted: return .red
        case .error: return .gray
        }
    }

    static let ballSize: CGFloat = 88
    static let ringWidth: CGFloat = 5
    static let coreInset: CGFloat = 11
    static let screenMargin: CGFloat = 16
}
