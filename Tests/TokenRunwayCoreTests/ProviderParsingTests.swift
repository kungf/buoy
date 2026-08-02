import XCTest
@testable import TokenRunwayCore

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

    // MARK: Kimi

    /// 真实响应样例（已脱敏）：每周配额 + 300 分钟限流窗 + 加油包 disabled
    func testKimiParsesWeeklyAndRateWindow() throws {
        // Arrange
        let json = """
        {
          "user": {"userId": "xxx", "region": "REGION_CN", "membership": {"level": "LEVEL_INTERMEDIATE"}},
          "usage": {"limit": "100", "used": "51", "remaining": "49", "resetTime": "2026-08-07T05:45:09.020360Z"},
          "limits": [
            {"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
             "detail": {"limit": "100", "used": "12", "remaining": "88", "resetTime": "2026-08-02T01:45:09.020360Z"}}
          ],
          "boosterWallet": {"status": "STATUS_DISABLED", "monthlyChargeLimit": {"currency": "CNY", "priceInCents": "10000"}, "monthlyUsed": {"currency": "CNY", "priceInCents": "0"}},
          "subType": "TYPE_PURCHASE"
        }
        """.data(using: .utf8)!

        // Act
        let report = try KimiProvider.parse(data: json)

        // Assert
        XCTAssertEqual(report.providerId, "kimi")
        XCTAssertEqual(report.quotas.map(\.id), ["kimi.7d", "kimi.rate.300m"])

        let weekly = report.quotas[0]
        XCTAssertEqual(weekly.type, .timeWindowed)
        XCTAssertEqual(weekly.used, 51)
        XCTAssertEqual(weekly.limit, 100)
        XCTAssertEqual(weekly.effectiveRemaining, 49)
        XCTAssertEqual(weekly.percentUsed, 0.51)
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 7
        comps.hour = 5; comps.minute = 45; comps.second = 9
        comps.timeZone = TimeZone(identifier: "UTC")
        let expectedReset = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(weekly.resetsAt!.timeIntervalSince1970, expectedReset.timeIntervalSince1970, accuracy: 0.1)
        XCTAssertEqual(weekly.windowStart!.timeIntervalSince1970,
                       expectedReset.timeIntervalSince1970 - 7 * 24 * 3600, accuracy: 0.1)

        let rate = report.quotas[1]
        XCTAssertEqual(rate.type, .timeWindowed)
        XCTAssertEqual(rate.label, "5 小时限流窗")
        XCTAssertEqual(rate.used, 12)
        XCTAssertEqual(rate.limit, 100)
        XCTAssertEqual(rate.resetsAt!.timeIntervalSince1970 - rate.windowStart!.timeIntervalSince1970,
                       300 * 60, accuracy: 0.01)
    }

    /// boosterWallet STATUS_ENABLED 时映射为 balance 型（priceInCents 为分，转 CNY）
    func testKimiParsesBoosterWalletWhenEnabled() throws {
        // Arrange
        let json = """
        {
          "usage": {"limit": "100", "used": "51", "remaining": "49", "resetTime": "2026-08-07T05:45:09.020360Z"},
          "limits": [],
          "boosterWallet": {"status": "STATUS_ENABLED", "monthlyChargeLimit": {"currency": "CNY", "priceInCents": "10000"}, "monthlyUsed": {"currency": "CNY", "priceInCents": "2500"}}
        }
        """.data(using: .utf8)!

        // Act
        let report = try KimiProvider.parse(data: json)

        // Assert
        XCTAssertEqual(report.quotas.map(\.id), ["kimi.7d", "kimi.booster"])
        let booster = report.quotas[1]
        XCTAssertEqual(booster.type, .balance)
        XCTAssertEqual(booster.unit, .cny)
        XCTAssertEqual(booster.limit, 100)
        XCTAssertEqual(booster.used, 25)
        XCTAssertEqual(booster.effectiveRemaining, 75)
    }

    /// limits 为空数组时只产出每周配额
    func testKimiParsesEmptyLimits() throws {
        // Arrange
        let json = """
        {
          "usage": {"limit": "100", "used": "51", "remaining": "49", "resetTime": "2026-08-07T05:45:09.020360Z"},
          "limits": []
        }
        """.data(using: .utf8)!

        // Act
        let report = try KimiProvider.parse(data: json)

        // Assert
        XCTAssertEqual(report.quotas.map(\.id), ["kimi.7d"])
    }

    /// 解析错误只暴露错误码，不透传服务端自由文本（SKILL.md / DESIGN.md §10）
    func testKimiErrorExposesOnlyCodeNotFreeText() {
        // Arrange
        let json = """
        {"error": {"code": "UNAUTHENTICATED", "message": "internal token detail must not leak"}}
        """.data(using: .utf8)!

        // Act / Assert
        XCTAssertThrowsError(try KimiProvider.parse(data: json)) { error in
            guard case ProviderError.parse(let msg) = error else {
                return XCTFail("expected parse error, got \(error)")
            }
            XCTAssertTrue(msg.contains("UNAUTHENTICATED"), "should expose the error code: \(msg)")
            XCTAssertFalse(msg.contains("internal token detail"), "must not leak server free text: \(msg)")
        }
    }

    /// resetTime 不带小数秒：兜底 formatter 解析（.withFractionalSeconds 会把小数秒变成必需）
    func testKimiParsesResetTimeWithoutFractionalSeconds() throws {
        // Arrange
        let json = """
        {
          "usage": {"limit": "100", "used": "51", "remaining": "49", "resetTime": "2026-08-07T05:45:09Z"},
          "limits": []
        }
        """.data(using: .utf8)!

        // Act
        let report = try KimiProvider.parse(data: json)

        // Assert
        XCTAssertEqual(report.quotas.map(\.id), ["kimi.7d"])
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 7
        comps.hour = 5; comps.minute = 45; comps.second = 9
        comps.timeZone = TimeZone(identifier: "UTC")
        let expected = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(report.quotas[0].resetsAt!.timeIntervalSince1970,
                       expected.timeIntervalSince1970, accuracy: 0.001)
    }

    /// usage 存在但全部字段非法：抛 parse 错误，让响应结构变更大声暴露（而非静默空 report）
    func testKimiThrowsWhenUsagePresentButNothingParsed() {
        // Arrange
        let json = """
        {"usage": {"limit": "abc", "used": "??", "remaining": "49", "resetTime": "not-a-date"}, "limits": []}
        """.data(using: .utf8)!

        // Act / Assert
        XCTAssertThrowsError(try KimiProvider.parse(data: json)) { error in
            guard case ProviderError.parse = error else {
                return XCTFail("expected parse error, got \(error)")
            }
        }
    }

    /// USD 加油包：按 currency 映射为 .usd，不假定 CNY
    func testKimiParsesUSDBoosterWallet() throws {
        // Arrange
        let json = """
        {
          "usage": {"limit": "100", "used": "51", "remaining": "49", "resetTime": "2026-08-07T05:45:09.020360Z"},
          "limits": [],
          "boosterWallet": {"status": "STATUS_ENABLED", "monthlyChargeLimit": {"currency": "USD", "priceInCents": "10000"}, "monthlyUsed": {"currency": "USD", "priceInCents": "2500"}}
        }
        """.data(using: .utf8)!

        // Act
        let report = try KimiProvider.parse(data: json)

        // Assert
        XCTAssertEqual(report.quotas.map(\.id), ["kimi.7d", "kimi.booster"])
        let booster = report.quotas[1]
        XCTAssertEqual(booster.unit, .usd)
        XCTAssertEqual(booster.limit, 100)
        XCTAssertEqual(booster.used, 25)
        XCTAssertEqual(booster.effectiveRemaining, 75)
    }

    /// 未知币种的加油包：跳过该 quota（不假定 CNY），其余 quota 不受影响
    func testKimiSkipsBoosterWalletWithUnknownCurrency() throws {
        // Arrange
        let json = """
        {
          "usage": {"limit": "100", "used": "51", "remaining": "49", "resetTime": "2026-08-07T05:45:09.020360Z"},
          "limits": [],
          "boosterWallet": {"status": "STATUS_ENABLED", "monthlyChargeLimit": {"currency": "EUR", "priceInCents": "10000"}, "monthlyUsed": {"currency": "EUR", "priceInCents": "0"}}
        }
        """.data(using: .utf8)!

        // Act
        let report = try KimiProvider.parse(data: json)

        // Assert
        XCTAssertEqual(report.quotas.map(\.id), ["kimi.7d"])
    }
}
