import SwiftUI

/// provider 主题（颜色 + 图标）。逃逸徽标着色、详情图标用（DESIGN.md §8.1）。
struct ProviderTheme: Equatable {
    let id: String
    let color: Color
    /// Bundle resource image name (e.g. "deepseek_logo", "volcengine_logo")
    let imageName: String
    /// True when `imageName` is an SF Symbol name rather than a bundled resource.
    let isSystemImage: Bool
}

extension ProviderTheme {
    /// 已知 provider 主题表；未知 provider 兜底紫色。
    static let registry: [String: ProviderTheme] = [
        "volcano": ProviderTheme(id: "volcano", color: .orange, imageName: "volcengine_logo", isSystemImage: false),
        "deepseek": ProviderTheme(id: "deepseek", color: .blue, imageName: "deepseek_logo", isSystemImage: false),
    ]

    static func theme(for id: String) -> ProviderTheme {
        registry[id] ?? ProviderTheme(id: id, color: .purple, imageName: "circle.fill", isSystemImage: true)
    }

    /// Creates the appropriate `Image` — loads from the module bundle for known
    /// providers, falls back to SF Symbol for unknown providers.
    func makeImage() -> Image {
        if isSystemImage {
            return Image(systemName: imageName)
        } else if let nsImage = Bundle.module.image(forResource: imageName) {
            return Image(nsImage: nsImage)
        } else {
            return Image(systemName: "questionmark.circle")
        }
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
