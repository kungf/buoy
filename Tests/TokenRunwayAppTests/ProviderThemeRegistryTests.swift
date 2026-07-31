import XCTest
import TokenRunwayCore
@testable import TokenRunwayApp

/// Guards the "forgot to add the logo png" footgun: every registered provider's
/// `logoName` must resolve to a bundled resource, and its theme must not fall back
/// to the SF Symbol placeholder. Without this, a missing logo silently renders as
/// a purple circle.fill (DESIGN.md §8.1).
final class ProviderThemeRegistryTests: XCTestCase {

    func test_everyProviderLogoIsBundled() throws {
        // Arrange / Act / Assert
        for provider in ProviderRegistry.all {
            let name = try XCTUnwrap(provider.manifest.logoName, "\(provider.id): logoName must be set")
            XCTAssertNotNil(
                Bundle.module.image(forResource: name),
                "\(provider.id): logo '\(name)' missing from App bundle resources"
            )
        }
    }

    func test_themeResolvesWithoutSFFallbackForKnownProviders() {
        // Arrange / Act / Assert
        for id in ProviderRegistry.ids {
            let theme = ProviderTheme.theme(for: id)
            XCTAssertEqual(theme.id, id)
            XCTAssertFalse(theme.isSystemImage, "\(id): expected bundled logo, got SF Symbol fallback")
        }
    }

    func test_themeIsCaseInsensitive() {
        // Act
        let lower = ProviderTheme.theme(for: "deepseek")
        let mixed = ProviderTheme.theme(for: "DeepSeek")

        // Assert: case-insensitive lookup resolves to the real theme, not the fallback.
        XCTAssertEqual(mixed.color, lower.color)
        XCTAssertFalse(mixed.isSystemImage, "mixed-case id should still resolve the bundled logo")
    }

    func test_themeFallsBackForUnknownId() {
        // Act
        let theme = ProviderTheme.theme(for: "totally-unknown")

        // Assert
        XCTAssertTrue(theme.isSystemImage, "unknown provider should fall back to SF Symbol")
    }
}
