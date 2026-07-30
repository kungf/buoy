import XCTest
@testable import TokenRunwayCore

final class VolcSignerTests: XCTestCase {
    /// 参考实现（Python hmac/hashlib）生成的测试向量，见 M0 验收报告
    func testSignatureMatchesReferenceVector() {
        // Arrange
        let signer = VolcSigner()
        let now = Date(timeIntervalSince1970: 1_778_379_634) // 2026-05-10T02:20:34Z（UTC）
        let body = Data("{}".utf8)

        // Act
        let signed = signer.sign(
            method: "POST",
            uri: "/",
            query: ["Action": "GetAFPUsage", "Version": "2024-01-01"],
            host: "ark.cn-beijing.volces.com",
            body: body,
            ak: "test-ak",
            sk: "test-sk",
            now: now
        )

        // Assert
        XCTAssertEqual(signed.xDate, "20260510T022034Z")
        XCTAssertEqual(signed.contentSHA256, "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
        XCTAssertTrue(signed.authorization.hasPrefix(
            "HMAC-SHA256 Credential=test-ak/20260510/cn-beijing/ark/request, SignedHeaders=host;x-content-sha256;x-date, Signature="))
        XCTAssertTrue(signed.authorization.hasSuffix(
            "d85e4d33b3e873ff1c55b2869ce00a3ef08f3df3d2da9e308345c12e7ee6940a"))
    }

    func testPercentEncodeKeepsUnreserved() {
        XCTAssertEqual(VolcSigner.percentEncode("GetAFPUsage"), "GetAFPUsage")
        XCTAssertEqual(VolcSigner.percentEncode("2024-01-01"), "2024-01-01")
        XCTAssertEqual(VolcSigner.percentEncode("a b/c"), "a%20b%2Fc")
    }
}
