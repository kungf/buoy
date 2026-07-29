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

    /// Short ASCII code for the ball nameplate, derived from the provider id (locale-independent:
    /// unaffected by `displayName`, which may be localized). id <= 4 chars -> shown in full;
    /// longer known ids -> a hand-picked short code; unknown long ids -> first 3 chars. Keeps the
    /// 88pt ball readable (DESIGN.md §8.3). e.g. "deepseek" -> "ds", "volcano" -> "vol".
    static func shortName(for id: String) -> String {
        let lower = id.lowercased()
        if lower.count <= 4 { return lower }
        switch lower {
        case "deepseek": return "ds"
        case "volcano": return "vol"
        default: return String(lower.prefix(3))
        }
    }
}
