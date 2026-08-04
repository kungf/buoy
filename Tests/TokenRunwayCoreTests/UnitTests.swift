import XCTest
@testable import TokenRunwayCore

/// Unit codable: fixed cases keep the legacy plain-string format; .custom(text) uses {"custom":"GBP"}.
final class UnitTests: XCTestCase {

    // Foundation also has Unit (NSUnit) — qualify with the module in the test target
    private typealias QuotaUnit = TokenRunwayCore.Unit

    func testCodableRoundtripAllFixedCases() throws {
        // Arrange / Act / Assert
        for unit: QuotaUnit in [.tokens, .credits, .usd, .cny, .none] {
            let data = try JSONEncoder().encode(unit)
            XCTAssertEqual(try JSONDecoder().decode(QuotaUnit.self, from: data), unit,
                           "roundtrip failed for \(unit)")
        }
    }

    func testCodableRoundtripCustomUnit() throws {
        // Arrange
        let unit: QuotaUnit = .custom("GBP")

        // Act
        let data = try JSONEncoder().encode(unit)
        let decoded = try JSONDecoder().decode(QuotaUnit.self, from: data)

        // Assert
        XCTAssertEqual(decoded, unit)
    }

    /// Legacy cache format: fixed cases stored as plain strings (String-raw-value era) must still decode
    func testDecodesLegacyStringFormat() throws {
        // Arrange / Act / Assert
        let legacy: [(raw: String, unit: QuotaUnit)] = [
            ("tokens", .tokens), ("credits", .credits), ("usd", .usd), ("cny", .cny),
        ]
        for entry in legacy {
            let data = Data("\"\(entry.raw)\"".utf8)
            XCTAssertEqual(try JSONDecoder().decode(QuotaUnit.self, from: data), entry.unit,
                           "legacy decode failed for \(entry.raw)")
        }
    }

    /// .custom must encode as a keyed object (not a string) to stay unambiguous vs. fixed cases
    func testCustomUnitEncodesAsKeyedObject() throws {
        // Act
        let data = try JSONEncoder().encode(QuotaUnit.custom("GBP"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        // Assert
        XCTAssertEqual(object, ["custom": "GBP"])
    }
}
