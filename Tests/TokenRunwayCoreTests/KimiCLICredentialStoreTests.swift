import XCTest
@testable import TokenRunwayCore

/// KimiCLICredentialStore：本机 Kimi Code CLI OAuth 登录态的读取/刷新/原子写回。
final class KimiCLICredentialStoreTests: XCTestCase {

    /// 可编程 HTTPClient：按队列返回响应并记录请求（断言请求形状用）
    actor StubHTTPClient: HTTPClient {
        private var responses: [HTTPResponse]
        private(set) var requests: [URLRequest] = []

        init(responses: [HTTPResponse] = []) { self.responses = responses }

        var callCount: Int { requests.count }

        func send(_ request: URLRequest) async throws -> HTTPResponse {
            requests.append(request)
            XCTAssertFalse(responses.isEmpty, "unexpected HTTP call: \(request.url?.absoluteString ?? "?")")
            return responses.isEmpty ? HTTPResponse(status: 500, data: Data()) : responses.removeFirst()
        }
    }

    private var home: URL!
    private var credentialsURL: URL { home.appendingPathComponent("credentials/kimi-code.json") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("kimi-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("credentials"),
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeCredentials(expiresAt: TimeInterval,
                                  accessToken: String = "old-access",
                                  refreshToken: String = "old-refresh",
                                  extra: [String: Any] = [:]) throws {
        var fields: [String: Any] = [
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "expires_at": expiresAt,
            "scope": "kimi-code",
            "token_type": "Bearer",
            "expires_in": 900,
        ]
        fields.merge(extra) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: fields)
        try data.write(to: credentialsURL)
    }

    private func readCredentialsFile() throws -> [String: Any] {
        let data = try Data(contentsOf: credentialsURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Tests

    /// token 新鲜（expires_at > now + 60s）：直接用，不发任何 HTTP 请求
    func testFreshTokenReturnedWithoutRefresh() async throws {
        let now = Date()
        try writeCredentials(expiresAt: now.timeIntervalSince1970 + 600)
        let http = StubHTTPClient()
        let store = KimiCLICredentialStore(home: home, http: http)

        let token = try await store.accessToken(now: now)
        let callCount = await http.callCount

        XCTAssertEqual(token, "old-access")
        XCTAssertEqual(callCount, 0, "fresh token must not trigger a refresh")
    }

    /// form 编码：严格 RFC 3986 unreserved 白名单，含 + / & = 的 token 编码后能还原
    ///（CharacterSet.urlQueryAllowed 会放行 + 和 &，不能用）
    func testFormEncodeEscapesSpecialCharacters() {
        let raw = "tok+with/slash&and=eq~ok-._9"
        let encoded = KimiCLICredentialStore.formEncode(raw)
        XCTAssertEqual(encoded, "tok%2Bwith%2Fslash%26and%3Deq~ok-._9")
        XCTAssertEqual(encoded.removingPercentEncoding, raw)
    }

    /// 刷新 body：特殊字符 refresh_token 编码后，按 form-urlencoded 规则解析能还原，
    /// 且不会被 `&` 切出多余参数
    func testRefreshBodyEncodesSpecialCharactersInToken() async throws {
        let now = Date()
        let nasty = "tok+with/slash&and=eq"
        try writeCredentials(expiresAt: now.timeIntervalSince1970 - 10, refreshToken: nasty)
        let refreshBody = #"{"access_token":"new-access","expires_in":900}"#
        let http = StubHTTPClient(responses: [HTTPResponse(status: 200, data: Data(refreshBody.utf8))])
        let store = KimiCLICredentialStore(home: home, http: http)

        _ = try await store.accessToken(now: now)
        let requests = await http.requests

        let request = try XCTUnwrap(requests.first)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("refresh_token=tok%2Bwith%2Fslash%26and%3Deq"), body)
        // 模拟服务端 form 解析：& 拆分 + percent-decode，必须还原原值
        var params: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            params[String(kv[0])] = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? "") : ""
        }
        XCTAssertEqual(params.count, 3, "an unescaped & would split out extra params: \(body)")
        XCTAssertEqual(params["refresh_token"], nasty)
    }

    /// expires_at 为字符串数字（"1900000000"）：与 NSNumber 同等处理，新鲜时不触发刷新
    func testStringExpiresAtAccepted() async throws {
        let now = Date()
        try writeCredentials(expiresAt: 0, extra: ["expires_at": String(Int(now.timeIntervalSince1970 + 600))])
        let http = StubHTTPClient()
        let store = KimiCLICredentialStore(home: home, http: http)

        let token = try await store.accessToken(now: now)
        let callCount = await http.callCount

        XCTAssertEqual(token, "old-access")
        XCTAssertEqual(callCount, 0, "string expires_at must be honored as a valid timestamp")
    }

    /// expires_at 无法解析（非数字字符串）：视为已过期走刷新路径，而不是误报 malformed
    func testUnparsableExpiresAtTreatedAsExpired() async throws {
        let now = Date()
        try writeCredentials(expiresAt: 0, extra: ["expires_at": "soon"])
        let refreshBody = #"{"access_token":"new-access","expires_in":900}"#
        let http = StubHTTPClient(responses: [HTTPResponse(status: 200, data: Data(refreshBody.utf8))])
        let store = KimiCLICredentialStore(home: home, http: http)

        let token = try await store.accessToken(now: now)
        let callCount = await http.callCount

        XCTAssertEqual(token, "new-access")
        XCTAssertEqual(callCount, 1, "unparsable expires_at must fall into the refresh path, not malformed")
    }

    /// token 过期：触发刷新并原子写回（保留 scope/token_type 等字段，0600 权限）
    func testExpiredTokenRefreshesAndWritesBack() async throws {
        let now = Date()
        try writeCredentials(expiresAt: now.timeIntervalSince1970 - 10, extra: ["custom_field": "keep-me"])
        try "device-abc\n".write(to: home.appendingPathComponent("device_id"),
                                 atomically: true, encoding: .utf8)
        let refreshBody = #"{"access_token":"new-access","expires_in":900,"refresh_token":"new-refresh","token_type":"Bearer"}"#
        let http = StubHTTPClient(responses: [HTTPResponse(status: 200, data: Data(refreshBody.utf8))])
        let store = KimiCLICredentialStore(home: home, http: http)

        let token = try await store.accessToken(now: now)
        let callCount = await http.callCount
        let requests = await http.requests

        XCTAssertEqual(token, "new-access")
        XCTAssertEqual(callCount, 1)

        // 请求形状：POST form-urlencoded + device id header；body 含 refresh_token
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Msh-Device-Id"), "device-abc")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=refresh_token"), body)
        XCTAssertTrue(body.contains("client_id=17e5f671-d194-4dfb-9706-5516cb48c098"), body)
        XCTAssertTrue(body.contains("refresh_token=old-refresh"), body)

        // 写回：新 token、refresh_token 轮换、expires_at 重算、其它字段保留
        let written = try readCredentialsFile()
        XCTAssertEqual(written["access_token"] as? String, "new-access")
        XCTAssertEqual(written["refresh_token"] as? String, "new-refresh")
        XCTAssertEqual(written["scope"] as? String, "kimi-code")
        XCTAssertEqual(written["token_type"] as? String, "Bearer")
        XCTAssertEqual(written["custom_field"] as? String, "keep-me")
        let expiresAt = try XCTUnwrap((written["expires_at"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(expiresAt, now.timeIntervalSince1970 + 900, accuracy: 1)

        // 文件权限 0600
        let attrs = try FileManager.default.attributesOfItem(atPath: credentialsURL.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
    }

    /// 刷新响应不含 refresh_token：保留旧的
    func testRefreshKeepsOldRefreshTokenWhenNotRotated() async throws {
        let now = Date()
        try writeCredentials(expiresAt: now.timeIntervalSince1970 - 10)
        let refreshBody = #"{"access_token":"new-access","expires_in":900}"#
        let http = StubHTTPClient(responses: [HTTPResponse(status: 200, data: Data(refreshBody.utf8))])
        let store = KimiCLICredentialStore(home: home, http: http)

        _ = try await store.accessToken(now: now)

        let written = try readCredentialsFile()
        XCTAssertEqual(written["refresh_token"] as? String, "old-refresh")
    }

    /// 多进程协调：refresh_token 已被外部（Kimi CLI）轮换 -> 放弃刷新，直接用文件里的新 access_token
    func testAbandonsRefreshWhenRefreshTokenRotatedExternally() async throws {
        let now = Date()
        // 文件里是 CLI 刚轮换过的新凭证
        try writeCredentials(expiresAt: now.timeIntervalSince1970 + 800,
                             accessToken: "cli-fresh-access", refreshToken: "cli-rotated-refresh")
        let http = StubHTTPClient()   // 无响应：任何 HTTP 调用都会 fail
        let store = KimiCLICredentialStore(home: home, http: http)

        // 模拟本进程此前读到的旧快照（refresh_token 已过时）
        let stale = KimiCLICredentialStore.Snapshot(
            fields: [:], accessToken: "stale-access",
            refreshToken: "old-refresh", expiresAt: now.timeIntervalSince1970 - 5)

        let token = try await store.refreshCoordinated(stale, now: now)
        let callCount = await http.callCount

        XCTAssertEqual(token, "cli-fresh-access")
        XCTAssertEqual(callCount, 0, "rotated refresh_token must abandon the refresh")
    }

    /// 凭证文件不存在 -> unauthorized（提示用户运行 kimi 并 /login）
    func testMissingFileThrowsUnauthorized() async throws {
        let store = KimiCLICredentialStore(home: home, http: StubHTTPClient())
        await assertThrowsUnauthorized { try await store.accessToken() }
    }

    /// localCLICredential：文件不存在返回 nil（上层映射 not-configured，走齿轮引导设置页）；
    /// 文件存在即返回 .localOAuth——哪怕 token 已过期（刷新是适配器的职责，不能误判成未配置）
    func testLocalCLICredentialNilOnlyWhenFileMissing() throws {
        XCTAssertNil(CredentialStore.localCLICredential(home: home),
                     "missing credentials file must map to not-configured")
        try writeCredentials(expiresAt: 1)   // 已过期也必须照常返回凭证
        let credential = try XCTUnwrap(CredentialStore.localCLICredential(home: home),
                                       "expired-but-present file is the normal refresh path")
        guard case .localOAuth(let path) = credential else {
            return XCTFail("expected localOAuth, got \(credential)")
        }
        XCTAssertEqual(path, home.path)
    }

    /// 刷新被拒（401/403/invalid_grant）-> unauthorized
    func testRefreshRejectedThrowsUnauthorized() async throws {
        let now = Date()
        try writeCredentials(expiresAt: now.timeIntervalSince1970 - 10)
        let body = #"{"error":"invalid_grant","error_description":"refresh token revoked"}"#
        let http = StubHTTPClient(responses: [HTTPResponse(status: 400, data: Data(body.utf8))])
        let store = KimiCLICredentialStore(home: home, http: http)
        await assertThrowsUnauthorized { try await store.accessToken(now: now) }
    }

    private func assertThrowsUnauthorized(_ operation: () async throws -> String,
                                          file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await operation()
            XCTFail("expected unauthorized", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ProviderError, .unauthorized,
                           "expected unauthorized, got \(error)", file: file, line: line)
        }
    }
}
