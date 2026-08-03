import XCTest
@testable import TokenRunwayApp

/// Verifies `ProviderTheme.shortName(for:)` -- the provider code shown on the ball nameplate.
final class ProviderThemeTests: XCTestCase {

    func test_shortName_abbreviatesKnownLongProviders() {
        // Arrange / Act / Assert
        XCTAssertEqual(ProviderTheme.shortName(for: "deepseek"), "deep")
        XCTAssertEqual(ProviderTheme.shortName(for: "volcano"), "volc")
        XCTAssertEqual(ProviderTheme.shortName(for: "kimi"), "kimi")
        XCTAssertEqual(ProviderTheme.shortName(for: "mimo"), "mimo")
    }

    func test_shortName_isCaseInsensitive() {
        XCTAssertEqual(ProviderTheme.shortName(for: "DeepSeek"), "deep")
        XCTAssertEqual(ProviderTheme.shortName(for: "VOLCANO"), "volc")
    }

    func test_shortName_showsShortIdInFull() {
        // id <= 4 chars is shown verbatim (lowercased)
        XCTAssertEqual(ProviderTheme.shortName(for: "gpt"), "gpt")
        XCTAssertEqual(ProviderTheme.shortName(for: "ABCD"), "abcd") // boundary: 4 chars
    }

    func test_shortName_unknownLongIdFallsBackToPrefix() {
        // unknown id > 4 chars -> first 4 chars (lowercased)
        XCTAssertEqual(ProviderTheme.shortName(for: "claude"), "clau")
        XCTAssertEqual(ProviderTheme.shortName(for: "Moonshot"), "moon")
    }

    func test_shortName_emptyIdReturnsEmpty() {
        XCTAssertEqual(ProviderTheme.shortName(for: ""), "")
    }
}
