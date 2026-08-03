import SwiftUI
import TokenRunwayCore

/// provider 主题（颜色 + 图标）。逃逸徽标着色、详情图标用（DESIGN.md §8.1）。
/// 颜色与 logo 名都在 `ProviderManifest` 里，这里只是把它们映射成 SwiftUI 类型，
/// 不再维护并行的 provider 主题表。
struct ProviderTheme: Equatable {
    let id: String
    let color: Color
    /// Bundle resource image name (e.g. "deepseek_logo", "volcengine_logo")
    let imageName: String
    /// True when `imageName` is an SF Symbol name rather than a bundled resource.
    let isSystemImage: Bool
}

extension ProviderTheme {
    /// 从 `ProviderRegistry` 取 manifest 派生主题；未知 provider（如旧版残留选择）兜底紫色。
    static func theme(for id: String) -> ProviderTheme {
        if let manifest = ProviderRegistry.provider(for: id.lowercased())?.manifest {
            let logoName = manifest.logoName
            return ProviderTheme(
                id: id,
                color: manifest.themeColor.asColor,
                imageName: logoName ?? "circle.fill",
                isSystemImage: logoName == nil
            )
        }
        return ProviderTheme(id: id, color: .purple, imageName: "circle.fill", isSystemImage: true)
    }

    /// Creates the appropriate `Image` - loads from the app's main bundle
    /// (`Contents/Resources`) for known providers, falls back to SF Symbol
    /// for unknown providers or when the resource is absent (e.g. running
    /// the raw executable without a packaged `.app`).
    func makeImage() -> Image {
        if isSystemImage {
            return Image(systemName: imageName)
        } else if let nsImage = Bundle.main.image(forResource: imageName) {
            return Image(nsImage: nsImage)
        } else {
            return Image(systemName: "questionmark.circle")
        }
    }

    /// Short ASCII code for the ball nameplate (locale-independent: unaffected by `displayName`,
    /// which may be localized). Precedence: known provider -> `manifest.shortName`; otherwise
    /// id <= 4 chars -> shown in full; longer unknown id -> first 4 chars. Keeps the 88pt ball
    /// readable (DESIGN.md §8.3).
    static func shortName(for id: String) -> String {
        let lower = id.lowercased()
        if let sn = ProviderRegistry.provider(for: lower)?.manifest.shortName, !sn.isEmpty {
            return sn
        }
        if lower.count <= 4 { return lower }
        return String(lower.prefix(4))
    }
}

/// Maps the Core-layer `ThemeColor` to SwiftUI `Color`（Core 不依赖 SwiftUI）。
extension ThemeColor {
    var asColor: Color {
        switch self {
        case .orange: return .orange
        case .blue: return .blue
        case .purple: return .purple
        case .green: return .green
        case .red: return .red
        case .teal: return .teal
        case .indigo: return .indigo
        case .pink: return .pink
        case .gray: return .gray
        }
    }
}
