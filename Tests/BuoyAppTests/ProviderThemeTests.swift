import XCTest
@testable import BuoyApp

/// Verifies `ProviderTheme.shortName(for:)` -- the provider code shown on the ball nameplate.
final class ProviderThemeTests: XCTestCase {

    func test_shortName_abbreviatesKnownLongProviders() {
        // Arrange / Act / Assert
        XCTAssertEqual(ProviderTheme.shortName(for: "deepseek"), "ds")
        XCTAssertEqual(ProviderTheme.shortName(for: "volcano"), "vol")
    }

    func test_shortName_isCaseInsensitive() {
        XCTAssertEqual(ProviderTheme.shortName(for: "DeepSeek"), "ds")
        XCTAssertEqual(ProviderTheme.shortName(for: "VOLCANO"), "vol")
    }

    func test_shortName_showsShortIdInFull() {
        // id <= 4 chars is shown verbatim (lowercased)
        XCTAssertEqual(ProviderTheme.shortName(for: "gpt"), "gpt")
        XCTAssertEqual(ProviderTheme.shortName(for: "ABCD"), "abcd") // boundary: 4 chars
    }

    func test_shortName_unknownLongIdFallsBackToPrefix() {
        // unknown id > 4 chars -> first 3 chars (lowercased)
        XCTAssertEqual(ProviderTheme.shortName(for: "claude"), "cla")
        XCTAssertEqual(ProviderTheme.shortName(for: "Moonshot"), "moo")
    }

    func test_shortName_emptyIdReturnsEmpty() {
        XCTAssertEqual(ProviderTheme.shortName(for: ""), "")
    }
}
