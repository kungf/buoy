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

    /// windowStart 必须 = resetsAt − 窗口期长（而不是 SubscribeTime）：窗口时长
    /// （resetsAt−windowStart）驱动环/核的时长排序与预期消耗速率（limit/时长），
    /// 用订阅起始时间会让时长变成"订阅年龄 + 距下次 reset"，随相位漂移。
    func testVolcanoWindowStartDerivedFromResetNotSubscribeTime() throws {
        // Arrange：SubscribeTime 在 reset 前 30 天（订阅已久），与 5h 窗口期长无关
        let json = """
        {
          "ResponseMetadata": {},
          "Result": {
            "PlanType": "Large",
            "AFPFiveHour": {"Quota": 50.0, "Used": 12.5, "SubscribeTime": 1777939200000, "ResetTime": 1778806800000},
            "AFPWeekly":  {"Quota": 0, "Used": 0, "SubscribeTime": 0, "ResetTime": 0},
            "AFPMonthly": {"Quota": 0, "Used": 0, "SubscribeTime": 0, "ResetTime": 0}
          }
        }
        """.data(using: .utf8)!

        // Act
        let report = try VolcanoProvider.parse(data: json)

        // Assert
        let fiveHour = report.quotas[0]
        XCTAssertEqual(fiveHour.resetsAt!.timeIntervalSince(fiveHour.windowStart!), 5 * 3600,
                       accuracy: 1e-9)
        XCTAssertNotEqual(fiveHour.windowStart, Date(timeIntervalSince1970: 1_777_939_200))
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

    // MARK: MiMo

    /// 真实响应样例（脱敏）：Lite 套餐有效期内，月度额度 items 有值
    func testMiMoParsesMonthlyQuota() throws {
        // Arrange
        let detail = """
        {"code":0,"message":"","data":{"planCode":"lite","planName":"Lite","currentPeriodEnd":"2026-08-25 23:59:59","expired":false}}
        """.data(using: .utf8)!
        let usage = """
        {"code":0,"message":"","data":{"monthUsage":{"percent":12.5,"items":[{"name":"mimo-v2.5-pro","used":512000000,"limit":4100000000,"percent":12.5}]},"usage":null}}
        """.data(using: .utf8)!

        // Act
        let report = try MiMoProvider.parse(detailData: detail, usageData: usage)

        // Assert
        XCTAssertEqual(report.providerId, "mimo")
        XCTAssertEqual(report.planExpired, false)
        XCTAssertEqual(report.quotas.map(\.id), ["mimo.monthly"])
        let q = report.quotas[0]
        XCTAssertEqual(q.type, .timeWindowed)
        XCTAssertEqual(q.unit, .credits)
        XCTAssertEqual(q.used, 512_000_000)
        XCTAssertEqual(q.limit, 4_100_000_000)
        XCTAssertEqual(try XCTUnwrap(q.percentUsed), 512_000_000 / 4_100_000_000, accuracy: 1e-9)
        // windowStart = periodEnd − 30d；periodEnd 为 UTC 解析
        XCTAssertEqual(q.resetsAt!.timeIntervalSince(q.windowStart!), 30 * 86400, accuracy: 0.1)
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 25
        comps.hour = 23; comps.minute = 59; comps.second = 59
        comps.timeZone = TimeZone(identifier: "UTC")
        let expectedEnd = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(q.resetsAt!.timeIntervalSince1970, expectedEnd.timeIntervalSince1970, accuracy: 0.1)
    }

    /// 已过期 + 本月无用量记录（items 为 null）：不产出额度（避免 0/0），只保留过期态
    func testMiMoParsesExpiredWithNoUsageItems() throws {
        // Arrange（真实响应：plan-manage 页面在套餐过期且无用量时返回该结构）
        let detail = """
        {"code":0,"message":"","data":{"planCode":"lite","planName":"Lite","currentPeriodEnd":"2026-07-25 23:59:59","expired":true}}
        """.data(using: .utf8)!
        let usage = """
        {"code":0,"message":"","data":{"monthUsage":{"percent":0,"items":null},"usage":null}}
        """.data(using: .utf8)!

        // Act
        let report = try MiMoProvider.parse(detailData: detail, usageData: usage)

        // Assert：无额度，但过期态必须透传（驱动球面 .expired 显示）
        XCTAssertEqual(report.planExpired, true)
        XCTAssertTrue(report.quotas.isEmpty)
    }

    /// 错误响应只暴露错误码，不透传服务端自由文本（DESIGN.md §10）
    func testMiMoErrorExposesOnlyCodeNotFreeText() {
        // Arrange
        let detail = #"{"code":401,"message":"session expired, please re-login","data":null}"#.data(using: .utf8)!

        // Act / Assert
        XCTAssertThrowsError(try MiMoProvider.parse(detailData: detail, usageData: nil)) { error in
            guard case ProviderError.parse(let msg) = error else {
                return XCTFail("expected parse error, got \(error)")
            }
            XCTAssertTrue(msg.contains("401"), "should expose the error code: \(msg)")
            XCTAssertFalse(msg.contains("please re-login"), "must not leak server free text: \(msg)")
        }
    }

    /// periodEnd 格式异常（结构变更）时不产出额度但保留过期态
    func testMiMoSkipsQuotaWhenPeriodEndUnparseable() throws {
        // Arrange
        let detail = #"{"code":0,"message":"","data":{"planCode":"lite","planName":"Lite","currentPeriodEnd":"not-a-date","expired":false}}"#.data(using: .utf8)!
        let usage = #"{"code":0,"message":"","data":{"monthUsage":{"percent":0,"items":[{"name":"m","used":1,"limit":100,"percent":1}]}}}"#.data(using: .utf8)!

        // Act
        let report = try MiMoProvider.parse(detailData: detail, usageData: usage)

        // Assert
        XCTAssertTrue(report.quotas.isEmpty)
        XCTAssertEqual(report.planExpired, false)
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

    // MARK: Zhipu

    /// 真实响应样例（OpenUsage 文档示例）：日 TIME_LIMIT 跳过，月/周 TOKENS_LIMIT 产出两条额度
    func testZhipuParsesMonthlyAndWeeklyQuota() throws {
        // Arrange
        let json = """
        {
          "code": 200,
          "msg": "Operation successful",
          "data": {
            "limits": [
              {"type": "TIME_LIMIT", "unit": 5, "usage": 100, "currentValue": 2, "remaining": 98, "percentage": 2, "nextResetTime": 1774091383998},
              {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 36},
              {"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 77, "nextResetTime": 1772276983998}
            ],
            "level": "lite"
          },
          "success": true
        }
        """.data(using: .utf8)!

        // Act
        let report = try ZhipuProvider.parse(data: json)

        // Assert
        XCTAssertEqual(report.providerId, "zhipu")
        XCTAssertEqual(report.quotas.map(\.id), ["zhipu.monthly", "zhipu.weekly"])

        // 月条：无 nextResetTime -> resetsAt/windowStart 为 nil；remaining = 5 × (100−36)/100
        let monthly = report.quotas[0]
        XCTAssertEqual(monthly.type, .timeWindowed)
        XCTAssertEqual(monthly.unit, .tokens)
        XCTAssertEqual(monthly.limit, 5)
        XCTAssertEqual(monthly.remaining, 5 * 0.64)
        XCTAssertNil(monthly.resetsAt)
        XCTAssertNil(monthly.windowStart)
        XCTAssertEqual(try XCTUnwrap(monthly.percentUsed), 0.36, accuracy: 1e-9)

        // 周条：resetsAt = 毫秒时间戳转秒；windowStart = resetsAt − 7d
        let weekly = report.quotas[1]
        XCTAssertEqual(weekly.limit, 1)
        XCTAssertEqual(try XCTUnwrap(weekly.remaining), 0.23, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(weekly.resetsAt).timeIntervalSince1970, 1_772_276_983.998, accuracy: 0.001)
        XCTAssertEqual(weekly.resetsAt!.timeIntervalSince(weekly.windowStart!), 7 * 86400, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(weekly.percentUsed), 0.77, accuracy: 1e-9)
    }

    /// 只有日调用限流（TIME_LIMIT）或 number=0 的未订阅配额：全部跳过，返回空额度
    func testZhipuSkipsTimeLimitAndZeroQuota() throws {
        // Arrange
        let json = """
        {
          "code": 200,
          "data": {
            "limits": [
              {"type": "TIME_LIMIT", "unit": 5, "usage": 100, "currentValue": 2, "remaining": 98, "percentage": 2},
              {"type": "TOKENS_LIMIT", "unit": 3, "number": 0, "percentage": 0},
              {"type": "TOKENS_LIMIT", "unit": 6, "percentage": 77}
            ]
          },
          "success": true
        }
        """.data(using: .utf8)!

        // Act
        let report = try ZhipuProvider.parse(data: json)

        // Assert：无可用 token 配额 -> 空 quotas（不抛错，账号可能只有日限流）
        XCTAssertTrue(report.quotas.isEmpty)
    }

    /// limits 缺失/为空 = 响应异常 -> 抛错
    func testZhipuThrowsOnEmptyLimits() {
        // Arrange
        let json = #"{"code":200,"data":{"limits":[],"level":"lite"},"success":true}"#.data(using: .utf8)!

        // Act / Assert
        XCTAssertThrowsError(try ZhipuProvider.parse(data: json)) { error in
            guard case ProviderError.parse(let msg) = error else {
                return XCTFail("expected parse error, got \(error)")
            }
            XCTAssertTrue(msg.contains("empty limits"), "unexpected message: \(msg)")
        }
    }

    /// 错误响应只暴露错误码，不透传服务端自由文本（DESIGN.md §10）
    func testZhipuErrorExposesOnlyCodeNotFreeText() {
        // Arrange
        let json = #"{"code":401,"msg":"API key invalid, please check your key","data":null}"#.data(using: .utf8)!

        // Act / Assert
        XCTAssertThrowsError(try ZhipuProvider.parse(data: json)) { error in
            guard case ProviderError.parse(let msg) = error else {
                return XCTFail("expected parse error, got \(error)")
            }
            XCTAssertTrue(msg.contains("401"), "should expose the error code: \(msg)")
            XCTAssertFalse(msg.contains("API key invalid"), "must not leak server free text: \(msg)")
        }
    }

    /// 未订阅 coding plan（实测真实响应：code 500 + 自由文本）：视为无额度，返回空报告，
    /// 不抛错（球显示无数据态而非错误态），也不泄露服务端自由文本
    func testZhipuNoSubscriptionReturnsEmptyReport() throws {
        // Arrange（实测响应，msg 已按真实结构构造）
        let json = #"{"code":500,"msg":"当前用户不存在coding plan","success":false}"#.data(using: .utf8)!

        // Act
        let report = try ZhipuProvider.parse(data: json)

        // Assert
        XCTAssertEqual(report.providerId, "zhipu")
        XCTAssertTrue(report.quotas.isEmpty)
    }

    // MARK: MiniMax

    /// 真实响应结构样例（GET /v1/token_plan/remains）：一个文本模型 bucket，
    /// 滚动 5 小时窗 + 周窗各产出一条额度；usage_count 实为剩余
    func testMiniMaxParsesIntervalAndWeeklyQuota() throws {
        // Arrange（5 小时窗 = 18,000,000ms；usage_count=60 是剩余，非已用）
        let json = """
        {
          "base_resp": {"status_code": 0, "status_msg": "success"},
          "model_remains": [
            {
              "model_name": "MiniMax-M3",
              "start_time": 1774091383000, "end_time": 1774109383000,
              "current_interval_remaining_percent": 60,
              "current_interval_total_count": 100,
              "current_interval_usage_count": 60,
              "current_interval_status": 1,
              "weekly_start_time": 1773624600000, "weekly_end_time": 1774229400000,
              "current_weekly_remaining_percent": 10,
              "current_weekly_total_count": 700,
              "current_weekly_usage_count": 70,
              "current_weekly_status": 1
            }
          ]
        }
        """.data(using: .utf8)!

        // Act
        let report = try MiniMaxProvider.parse(data: json)

        // Assert（模型名在 id 中统一小写，与全仓 id 惯例一致）
        XCTAssertEqual(report.providerId, "minimax")
        XCTAssertEqual(report.quotas.map(\.id), ["minimax.minimax-m3.5h", "minimax.minimax-m3.7d"])

        // 5 小时窗：used = total − usage（usage 是剩余）
        let interval = report.quotas[0]
        XCTAssertEqual(interval.type, .timeWindowed)
        XCTAssertEqual(interval.unit, .credits)
        XCTAssertEqual(interval.label, "MiniMax-M3 5 小时额度")
        XCTAssertEqual(interval.limit, 100)
        XCTAssertEqual(try XCTUnwrap(interval.remaining), 60, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(interval.used), 40, accuracy: 1e-9)
        XCTAssertEqual(interval.windowStart!.timeIntervalSince1970, 1_774_091_383, accuracy: 0.01)
        XCTAssertEqual(interval.resetsAt!.timeIntervalSince1970, 1_774_109_383, accuracy: 0.01)
        XCTAssertEqual(interval.resetsAt!.timeIntervalSince(interval.windowStart!), 5 * 3600, accuracy: 1)

        // 周窗：remaining_percent 与 counts 自洽（70/700 = 10%）
        let weekly = report.quotas[1]
        XCTAssertEqual(weekly.id, "minimax.minimax-m3.7d")
        XCTAssertEqual(weekly.label, "MiniMax-M3 周额度")
        XCTAssertEqual(try XCTUnwrap(weekly.remaining), 70, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(weekly.percentUsed), 0.9, accuracy: 1e-9)
    }

    /// 未订阅（status=3 unlimited、total=0）或 limit=0 的窗口：全部跳过，返回空额度
    func testMiniMaxSkipsUnsubscribedAndZeroWindows() throws {
        // Arrange
        let json = """
        {
          "base_resp": {"status_code": 0},
          "model_remains": [
            {
              "model_name": "MiniMax-M3",
              "start_time": 1774091383000, "end_time": 1774109383000,
              "current_interval_remaining_percent": 100,
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "current_interval_status": 3,
              "weekly_start_time": 0, "weekly_end_time": 0,
              "current_weekly_remaining_percent": 100,
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "current_weekly_status": 3
            },
            {
              "model_name": "video",
              "start_time": 1774091383000, "end_time": 1774177783000,
              "current_interval_remaining_percent": 100,
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "current_interval_status": 1,
              "weekly_start_time": 0, "weekly_end_time": 0,
              "current_weekly_remaining_percent": 100,
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "current_weekly_status": 1
            }
          ]
        }
        """.data(using: .utf8)!

        // Act
        let report = try MiniMaxProvider.parse(data: json)

        // Assert：未订阅 = 空报告（正常态，不抛错）
        XCTAssertEqual(report.providerId, "minimax")
        XCTAssertTrue(report.quotas.isEmpty)
    }

    /// 已耗尽（status=2）窗口：即使 usage_count 非 0，remaining 强制为 0、used=limit
    func testMiniMaxExhaustedWindowForcesFullUsed() throws {
        // Arrange（usage_count=5 残留，但 status=2 表示已耗尽）
        let json = """
        {
          "base_resp": {"status_code": 0},
          "model_remains": [
            {
              "model_name": "MiniMax-M3",
              "start_time": 1774091383000, "end_time": 1774109383000,
              "current_interval_remaining_percent": 5,
              "current_interval_total_count": 100,
              "current_interval_usage_count": 5,
              "current_interval_status": 2,
              "weekly_start_time": 0, "weekly_end_time": 0,
              "current_weekly_remaining_percent": 100,
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "current_weekly_status": 3
            }
          ]
        }
        """.data(using: .utf8)!

        // Act
        let report = try MiniMaxProvider.parse(data: json)

        // Assert
        XCTAssertEqual(report.quotas.count, 1)
        XCTAssertEqual(try XCTUnwrap(report.quotas[0].remaining), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(report.quotas[0].used), 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(report.quotas[0].percentUsed), 1, accuracy: 1e-9)
    }

    /// 错误响应只暴露 status_code，不透传服务端自由文本（DESIGN.md §10）；
    /// MiniMax 凭证被拒也返回 HTTP 200，成败全看 base_resp
    func testMiniMaxErrorExposesOnlyCodeNotFreeText() {
        // Arrange
        let json = #"{"base_resp":{"status_code":1004,"status_msg":"unauthorized, please check your api key"},"model_remains":[]}"#.data(using: .utf8)!

        // Act / Assert
        XCTAssertThrowsError(try MiniMaxProvider.parse(data: json)) { error in
            guard case ProviderError.parse(let msg) = error else {
                return XCTFail("expected parse error, got \(error)")
            }
            XCTAssertTrue(msg.contains("1004"), "should expose the error code: \(msg)")
            XCTAssertFalse(msg.contains("unauthorized"), "must not leak server free text: \(msg)")
        }
    }
}
