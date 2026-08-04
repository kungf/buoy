import XCTest
@testable import TokenRunwayCore

/// Verifies `ProviderRegistry` - the single source of truth for which providers exist.
final class ProviderRegistryTests: XCTestCase {

    func test_idsAreUniqueAndNonEmpty() {
        // Arrange
        let ids = ProviderRegistry.ids

        // Assert
        XCTAssertFalse(ids.isEmpty, "registry must register at least one provider")
        XCTAssertEqual(ids.count, Set(ids).count, "provider ids must be unique: \(ids)")
    }

    func test_lookupByIdReturnsProvider() {
        // Act / Assert
        XCTAssertEqual(ProviderRegistry.provider(for: "deepseek")?.id, "deepseek")
        XCTAssertEqual(ProviderRegistry.provider(for: "volcano")?.id, "volcano")
    }

    func test_unknownIdReturnsNil() {
        XCTAssertNil(ProviderRegistry.provider(for: "nope"))
    }

    func test_everyManifestIsWellFormed() {
        // Arrange / Act / Assert
        for provider in ProviderRegistry.all {
            XCTAssertFalse(provider.manifest.displayName.isEmpty, "\(provider.id): empty displayName")
            XCTAssertFalse(provider.manifest.shortName?.isEmpty ?? false, "\(provider.id): empty shortName")
            XCTAssertNotNil(provider.manifest.logoName, "\(provider.id): missing logoName")
            XCTAssertNotNil(provider.manifest.consoleURL, "\(provider.id): missing consoleURL")
        }
    }

    /// Guards the trwyctl env-var contract (README): DeepSeek uses the full id,
    /// Volcano uses the legacy "VOLC" abbreviation - NOT "VOLCANO". Renaming these
    /// silently breaks users' shell rc, so lock them in.
    func test_envPrefixMatchesDocumentedNames() {
        XCTAssertEqual(ProviderRegistry.provider(for: "deepseek")?.manifest.envPrefix, "DEEPSEEK")
        XCTAssertEqual(ProviderRegistry.provider(for: "volcano")?.manifest.envPrefix, "VOLC")
    }

    // MARK: Custom metrics merge

    func test_includingCustomMergesCustomProvidersAfterBuiltins() {
        // Arrange
        let custom = [
            CustomMetricConfig(id: "custom-1", name: "预算 A", baseURL: "u", metric: "m"),
            CustomMetricConfig(id: "custom-2", name: "预算 B", baseURL: "u", metric: "m"),
        ]

        // Act
        let all = ProviderRegistry.all(includingCustom: custom)

        // Assert：内置 provider 在前、自定义在后，顺序稳定（决定球簇排列）
        XCTAssertEqual(Array(all.prefix(ProviderRegistry.all.count)).map(\.id),
                       ProviderRegistry.ids)
        XCTAssertEqual(Array(all.suffix(custom.count)).map(\.id), ["custom-1", "custom-2"])
        XCTAssertEqual(all.count, ProviderRegistry.all.count + custom.count)
    }

    func test_includingCustomWithEmptyListReturnsBuiltinsOnly() {
        // Act / Assert
        XCTAssertEqual(ProviderRegistry.all(includingCustom: []).map(\.id), ProviderRegistry.ids)
    }
}
