import XCTest
@testable import BuoyCore

final class ProviderParsingTests: XCTestCase {

    // MARK: DeepSeek

    func testDeepSeekParsesBalance() throws {
        // Arrange
        let json = """
        {"is_available":true,"balance_infos":[
          {"currency":"CNY","total_balance":"1.25","granted_balance":"0.00","topped_up_balance":"1.25"}
        ]}
        """.data(using: .utf8)!

        // Act
        let report = try DeepSeekProvider.parse(data: json)

        // Assert
        XCTAssertEqual(report.providerId, "deepseek")
        XCTAssertEqual(report.quotas.count, 1)
        let q = report.quotas[0]
        XCTAssertEqual(q.id, "deepseek.balance")
        XCTAssertEqual(q.type, .balance)
        XCTAssertEqual(q.unit, .cny)
        XCTAssertEqual(q.effectiveRemaining, 1.25)
        XCTAssertEqual(report.balance?.granted, 0)
        XCTAssertEqual(report.balance?.toppedUp, 1.25)
    }

    func testDeepSeekThrowsOnEmptyInfos() {
        let json = #"{"is_available":false,"balance_infos":[]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try DeepSeekProvider.parse(data: json)) { error in
            guard case ProviderError.parse = error else {
                return XCTFail("expected parse error, got \(error)")
            }
        }
    }

    // MARK: Volcano

    /// 官方文档示例响应（docs.volcengine.com/docs/82379/2479847）
    /// 每日窗口（AFPDaily）按产品决策不展示——多数套餐无实际每日限额
    func testVolcanoParsesWindowsAndDropsDaily() throws {
        // Arrange
        let json = """
        {
          "ResponseMetadata": {"Action": "GetAFPUsage", "Service": "ark", "Region": "cn-beijing"},
          "Result": {
            "PlanType": "Large",
            "AFPFiveHour": {"Quota": 50.0, "Used": 12.5, "SubscribeTime": 1778788800000, "ResetTime": 1778806800000},
            "AFPDaily":   {"Quota": 100.0, "Used": 22.5, "SubscribeTime": 1778716800000, "ResetTime": 1778803200000},
            "AFPWeekly":  {"Quota": 500.0, "Used": 150.0, "SubscribeTime": 1778457600000, "ResetTime": 1779062400000},
            "AFPMonthly": {"Quota": 2000.0, "Used": 850.5, "SubscribeTime": 1777939200000, "ResetTime": 1780531200000}
          }
        }
        """.data(using: .utf8)!

        // Act
        let report = try VolcanoProvider.parse(data: json)

        // Assert
        XCTAssertEqual(report.quotas.map(\.id), ["volcano.5h", "volcano.7d", "volcano.30d"])
        let fiveHour = report.quotas[0]
        XCTAssertEqual(fiveHour.used, 12.5)
        XCTAssertEqual(fiveHour.limit, 50.0)
        XCTAssertEqual(fiveHour.percentUsed, 0.25)
        XCTAssertEqual(fiveHour.resetsAt, Date(timeIntervalSince1970: 1_778_806_800))
        XCTAssertEqual(fiveHour.unit, .credits)
    }

    func testVolcanoSkipsZeroQuotaWindows() throws {
        // Arrange：Weekly/Monthly Quota=0 = 未开通（DESIGN.md §5.2）
        let json = """
        {
          "ResponseMetadata": {},
          "Result": {
            "PlanType": "Large",
            "AFPFiveHour": {"Quota": 50.0, "Used": 12.5, "SubscribeTime": 1778788800000, "ResetTime": 1778806800000},
            "AFPDaily":   {"Quota": 100.0, "Used": 22.5, "SubscribeTime": 1778716800000, "ResetTime": 1778803200000},
            "AFPWeekly":  {"Quota": 0, "Used": 0, "SubscribeTime": 0, "ResetTime": 0},
            "AFPMonthly": {"Quota": 0, "Used": 0, "SubscribeTime": 0, "ResetTime": 0}
          }
        }
        """.data(using: .utf8)!

        // Act
        let report = try VolcanoProvider.parse(data: json)

        // Assert
        XCTAssertEqual(report.quotas.map(\.id), ["volcano.5h"])
    }

    func testVolcanoThrowsOnAPIError() {
        let json = """
        {"ResponseMetadata": {"Error": {"Code": "InvalidAccessKeyId", "Message": "bad ak"}}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try VolcanoProvider.parse(data: json)) { error in
            guard case ProviderError.parse(let msg) = error, msg.contains("InvalidAccessKeyId") else {
                return XCTFail("expected parse error, got \(error)")
            }
        }
    }
}
