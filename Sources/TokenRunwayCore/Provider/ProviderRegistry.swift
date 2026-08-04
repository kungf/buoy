import Foundation

/// Single source of truth for "which providers exist". `UsageStore`, `trwyctl` and the
/// Dashboard all read from here; adding a provider means registering one line (plus its
/// adapter file and logo asset) — no parallel lists to maintain.
public enum ProviderRegistry {
    /// Provider init order (stable: decides "the first ball" and the cluster arrangement).
    public static let all: [any Provider] = [
        VolcanoProvider(),
        DeepSeekProvider(),
        KimiProvider(),
        MiMoProvider(),
        ZhipuProvider(),
        MiniMaxProvider(),
    ]

    /// Built-ins + user custom metrics merged (customs last, stable order). Called by UsageStore/trwyctl at startup.
    public static func all(includingCustom customConfigs: [CustomMetricConfig]) -> [any Provider] {
        all + customConfigs.map { CustomMetricsProvider(config: $0) }
    }

    public static var ids: [String] { all.map { $0.manifest.id } }

    public static func provider(for id: String) -> (any Provider)? {
        all.first { $0.manifest.id == id }
    }
}
