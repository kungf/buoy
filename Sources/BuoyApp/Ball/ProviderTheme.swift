import SwiftUI

/// provider 主题（颜色 + 图标）。逃逸徽标着色、详情图标用（DESIGN.md §8.1）。
struct ProviderTheme: Equatable {
    let id: String
    let color: Color
    /// SF Symbol 名
    let icon: String
}

extension ProviderTheme {
    /// 已知 provider 主题表；未知 provider 兜底紫色。
    static let registry: [String: ProviderTheme] = [
        "volcano": ProviderTheme(id: "volcano", color: .orange, icon: "flame.fill"),
        "deepseek": ProviderTheme(id: "deepseek", color: .blue, icon: "circle.hexagongrid.fill"),
    ]

    static func theme(for id: String) -> ProviderTheme {
        registry[id] ?? ProviderTheme(id: id, color: .purple, icon: "circle.fill")
    }
}
