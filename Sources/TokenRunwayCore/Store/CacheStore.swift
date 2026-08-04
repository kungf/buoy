import Foundation

/// 本地缓存（DESIGN.md §6：lastGoodReport + 样本环形 buffer 持久化，重启不冷启动）。
/// 存 ~/.trwy/cache.json（仓库外，与 config.json 同目录；含 ProviderReport + ForecastEngine 样本）。
public struct TokenRunwayCache: Codable, Sendable, Equatable {
    public let reports: [ProviderReport]
    public let forecast: ForecastEngine

    public init(reports: [ProviderReport], forecast: ForecastEngine) {
        self.reports = reports
        self.forecast = forecast
    }
}

public enum CacheStore {
    /// Cache path. get-set: tests can redirect to a temp file (default ~/.trwy/cache.json)
    public static var defaultURL: URL {
        get { defaultURLStorage }
        set { defaultURLStorage = newValue }
    }
    /// nonisolated(unsafe): test redirect only; production path is read-only
    private nonisolated(unsafe) static var defaultURLStorage = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".trwy/cache.json")

    public static func load(from url: URL = defaultURL) -> TokenRunwayCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TokenRunwayCache.self, from: data)
    }

    public static func save(_ cache: TokenRunwayCache, to url: URL = defaultURL) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
