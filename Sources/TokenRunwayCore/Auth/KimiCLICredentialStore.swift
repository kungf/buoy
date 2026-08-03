import Foundation

/// Kimi Code CLI 的本机 OAuth 登录态（`$KIMI_CODE_HOME/credentials/kimi-code.json`，
/// 默认 `~/.kimi-code`）。access_token 仅 15 分钟有效，过期时用 refresh_token 走
/// oauth/token 刷新并原子写回；与 Kimi CLI 共用同一文件，多进程协调方式与 CLI 一致：
/// 刷新前重读一次，若 refresh_token 已被外部轮换，直接用文件里的新 access_token，
/// 放弃本次刷新。token 绝不打印、不写日志。
public struct KimiCLICredentialStore: Sendable {
    public static let refreshURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    public static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    /// 新鲜度余量：过期前 60s 即视为过期，避免请求在飞行中过期
    public static let freshnessSkew: TimeInterval = 60

    /// RFC 3986 unreserved 严格白名单（A-Z a-z 0-9 -._~），用于 form-urlencoded body。
    /// 不用 CharacterSet.urlQueryAllowed：它放行 `+` 和 `&`，会静默破坏 form body
    ///（`+` 解码成空格、`&` 切出多余参数）。
    static let formUnreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formUnreserved) ?? value
    }

    /// KIMI_CODE_HOME 环境变量优先，缺省 ~/.kimi-code
    public static var defaultHome: URL {
        if let dir = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
    }

    public let home: URL
    private let http: HTTPClient

    public init(home: URL = KimiCLICredentialStore.defaultHome, http: HTTPClient = URLSessionHTTPClient()) {
        self.home = home
        self.http = http
    }

    public var credentialsURL: URL { home.appendingPathComponent("credentials/kimi-code.json") }
    public var deviceIDURL: URL { home.appendingPathComponent("device_id") }

    /// 凭证文件快照（保留原始字段全集，写回时不丢 scope/token_type 等未知字段）
    struct Snapshot {
        var fields: [String: Any]
        let accessToken: String
        let refreshToken: String
        /// epoch 秒
        let expiresAt: TimeInterval

        func isFresh(at now: Date) -> Bool {
            expiresAt > now.timeIntervalSince1970 + KimiCLICredentialStore.freshnessSkew
        }
    }

    /// 取可用的 access_token：新鲜直接用，过期走协调刷新。
    /// 文件不存在 -> unauthorized（提示用户运行 `kimi` 并执行 /login）。
    public func accessToken(now: Date = Date()) async throws -> String {
        let snapshot = try readSnapshot()
        if snapshot.isFresh(at: now) { return snapshot.accessToken }
        return try await refreshCoordinated(snapshot, now: now)
    }

    /// 多进程协调：刷新前重读文件。refresh_token 已变 = Kimi CLI 刚刷新过，
    /// 直接用新 access_token，放弃本次刷新（与 CLI 的协调协议一致）。
    func refreshCoordinated(_ snapshot: Snapshot, now: Date) async throws -> String {
        let latest = try readSnapshot()
        if latest.refreshToken != snapshot.refreshToken {
            return latest.accessToken
        }
        return try await refresh(latest, now: now)
    }

    // MARK: - File IO

    func readSnapshot() throws -> Snapshot {
        guard let data = try? Data(contentsOf: credentialsURL) else {
            // 文件不存在 = 未登录
            throw ProviderError.unauthorized
        }
        guard let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = fields["access_token"] as? String,
              let refreshToken = fields["refresh_token"] as? String else {
            throw ProviderError.parse("kimi: malformed credentials file")
        }
        // expires_at 由外部工具写入，兼容 NSNumber 与字符串数字（如 "1900000000"）；
        // 两种都解析不出时视为已过期（0），交给刷新路径判定，而不是误报"文件损坏"
        // 诱导用户删掉一个可能持有有效登录态的文件。
        let expiresAt: TimeInterval
        if let number = (fields["expires_at"] as? NSNumber)?.doubleValue {
            expiresAt = number
        } else if let string = fields["expires_at"] as? String, let value = Double(string) {
            expiresAt = value
        } else {
            expiresAt = 0
        }
        return Snapshot(fields: fields, accessToken: accessToken,
                        refreshToken: refreshToken, expiresAt: expiresAt)
    }

    /// 原子写回（Data.write options: .atomic，chmod 0600；与 CredentialStore.save 同款模式）。
    /// credentials/ 目录不存在时先创建（正常流程它必然存在，防御 mkpath 消除边角失败）。
    private func writeSnapshot(_ fields: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: fields)
        try FileManager.default.createDirectory(at: credentialsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: credentialsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsURL.path)
    }

    // MARK: - Refresh

    private func refresh(_ snapshot: Snapshot, now: Date) async throws -> String {
        var request = URLRequest(url: Self.refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let raw = try? String(contentsOf: deviceIDURL, encoding: .utf8) {
            let deviceID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !deviceID.isEmpty {
                request.setValue(deviceID, forHTTPHeaderField: "X-Msh-Device-Id")
            }
        }
        request.httpBody = Data("client_id=\(Self.formEncode(Self.clientID))&grant_type=refresh_token&refresh_token=\(Self.formEncode(snapshot.refreshToken))".utf8)

        let response = try await http.send(request)
        let body = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
        if response.status == 401 || response.status == 403 { throw ProviderError.unauthorized }
        // invalid_grant（refresh_token 失效/被吊销，常为 400）-> 需重新 /login
        if let code = body?["error"] as? String {
            if code == "invalid_grant" { throw ProviderError.unauthorized }
            throw ProviderError.parse("kimi: \(code)")
        }
        if let error = ProviderError.fromStatus(response.status) { throw error }
        guard let body else {
            throw ProviderError.parse("kimi: bad token response")
        }
        guard let newAccessToken = body["access_token"] as? String, !newAccessToken.isEmpty,
              let expiresIn = (body["expires_in"] as? NSNumber)?.doubleValue else {
            throw ProviderError.parse("kimi: bad token response")
        }

        var fields = snapshot.fields
        fields["access_token"] = newAccessToken
        fields["expires_in"] = expiresIn
        fields["expires_at"] = now.timeIntervalSince1970 + expiresIn
        // 服务端可能轮换 refresh_token；没有则保留旧的
        if let rotated = body["refresh_token"] as? String, !rotated.isEmpty {
            fields["refresh_token"] = rotated
        }
        do {
            try writeSnapshot(fields)
        } catch {
            throw ProviderError.network("kimi: failed to persist refreshed credentials")
        }
        return newAccessToken
    }
}
