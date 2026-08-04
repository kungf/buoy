import XCTest
@testable import TokenRunwayCore

/// Unit 枚举编解码：固定 case 沿用旧缓存纯字符串格式，.custom(文本) 用 {"custom":"GBP"}。
final class UnitTests: XCTestCase {

    // Foundation 也有 Unit（NSUnit），测试 target 里必须用模块限定消除歧义
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

    /// 旧缓存格式：固定 case 存为纯字符串（String raw value 时代遗留），必须仍可解码
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

    /// .custom 必须编码为 keyed object（而不是字符串），避免与固定 case 歧义
    func testCustomUnitEncodesAsKeyedObject() throws {
        // Act
        let data = try JSONEncoder().encode(QuotaUnit.custom("GBP"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        // Assert
        XCTAssertEqual(object, ["custom": "GBP"])
    }
}
