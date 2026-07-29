import Foundation

/// 球面展示模式（DESIGN.md §8.1）。
/// `tightest` 为默认：自动展示 health score 最差的 provider，换脸本身即是强提示。
enum DisplayMode: String, Codable, CaseIterable {
    /// 用户钉选一个 provider 上球
    case fixed
    /// 自动展示 health score 最差的 provider（默认）
    case tightest
    /// 定时轮播（默认关：频繁换脸干扰"肌肉记忆式一瞥"）
    case carousel

    var label: String {
        switch self {
        case .fixed: return "固定"
        case .tightest: return "最紧"
        case .carousel: return "轮播"
        }
    }
}
