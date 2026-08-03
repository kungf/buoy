import Foundation

/// "哪些 provider 存在"的唯一事实源。`UsageStore`、`trwyctl`、Dashboard 均从此读取，
/// 新增 provider 只需在此注册一行（外加其 adapter 文件与 logo 资源），不再维护并行清单。
public enum ProviderRegistry {
    /// Provider 初始化顺序（稳定：决定"第一个球"与簇内排列）。
    public static let all: [any Provider] = [
        VolcanoProvider(),
        DeepSeekProvider(),
        KimiProvider(),
        MiMoProvider(),
    ]

    public static var ids: [String] { all.map { $0.manifest.id } }

    public static func provider(for id: String) -> (any Provider)? {
        all.first { $0.manifest.id == id }
    }
}
