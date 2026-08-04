import Foundation

/// One provider entry in ~/.trwy/config.json. Fields are used per auth mode:
/// bearer → token; volcSignature → ak/sk; consoleSession → cookieToken/cookieUserId;
/// apiKey/baseURL reserved for inference-style APIs.
public struct ProviderCredentials: Codable, Sendable, Equatable {
    public var auth: String?
    public var token: String?
    public var ak: String?
    public var sk: String?
    public var apiKey: String?
    public var baseURL: String?
    /// consoleSession: browser SSO session cookies (e.g. MiMo api-platform_serviceToken / userId)
    public var cookieToken: String?
    public var cookieUserId: String?

    public init(auth: String? = nil, token: String? = nil, ak: String? = nil,
                sk: String? = nil, apiKey: String? = nil, baseURL: String? = nil,
                cookieToken: String? = nil, cookieUserId: String? = nil) {
        self.auth = auth
        self.token = token
        self.ak = ak
        self.sk = sk
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.cookieToken = cookieToken
        self.cookieUserId = cookieUserId
    }
}

/// Credential config file (chmod 600, outside the repo; M2 migrates to Keychain, DESIGN.md §10)
public struct TokenRunwayConfigFile: Codable, Sendable, Equatable {
    public var providers: [String: ProviderCredentials]
    /// User custom-metric configs (non-secret; tokens still go via providers[<id>].token).
    /// Same file rather than UserDefaults: trwyctl and the App run in different process
    /// domains and need to share.
    public var customMetrics: [CustomMetricConfig]

    public init(providers: [String: ProviderCredentials], customMetrics: [CustomMetricConfig] = []) {
        self.providers = providers
        self.customMetrics = customMetrics
    }

    /// Legacy config.json has no customMetrics field: decodeIfPresent falls back to []
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decode([String: ProviderCredentials].self, forKey: .providers)
        customMetrics = try container.decodeIfPresent([CustomMetricConfig].self, forKey: .customMetrics) ?? []
    }
}

/// Custom-metric config load / upsert / remove (same file as providers, atomic write-back).
public enum CustomMetricConfigStore {
    public static func load(from url: URL = CredentialStore.defaultURL) -> [CustomMetricConfig] {
        CredentialStore.load(from: url)?.customMetrics ?? []
    }

    /// Add or update (replace in place by id, keeping order; other configs and providers untouched)
    public static func upsert(_ config: CustomMetricConfig, to url: URL = CredentialStore.defaultURL) throws {
        var file = CredentialStore.load(from: url) ?? TokenRunwayConfigFile(providers: [:])
        if let index = file.customMetrics.firstIndex(where: { $0.id == config.id }) {
            file.customMetrics[index] = config
        } else {
            file.customMetrics.append(config)
        }
        try CredentialStore.save(file, to: url)
    }

    /// Remove a config and its same-id credential entry
    public static func remove(id: String, from url: URL = CredentialStore.defaultURL) throws {
        var file = CredentialStore.load(from: url) ?? TokenRunwayConfigFile(providers: [:])
        file.customMetrics.removeAll { $0.id == id }
        file.providers.removeValue(forKey: id)
        try CredentialStore.save(file, to: url)
    }
}

/// Credential loading and mapping. Tokens are never printed or logged.
public enum CredentialStore {
    /// Config path. get-set: tests can redirect to a temp file (default ~/.trwy/config.json)
    public static var defaultURL: URL {
        get { defaultURLStorage }
        set { defaultURLStorage = newValue }
    }
    /// nonisolated(unsafe): test redirect only; production path is read-only
    private nonisolated(unsafe) static var defaultURLStorage = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".trwy/config.json")

    public static func load(from url: URL = defaultURL) -> TokenRunwayConfigFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TokenRunwayConfigFile.self, from: data)
    }

    /// Write config to disk (chmod 0700 dir, 0600 file, never log keys).
    public static func save(_ config: TokenRunwayConfigFile, to url: URL = defaultURL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // A pre-existing dir (created by an older version or by hand) won't pick up the
        // createDirectory permissions — force 0700 on every save, otherwise the .atomic
        // temp file may land with umask permissions before the chmod 600
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let data = try JSONEncoder().encode(config)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Entry → unified Credential. Complete ak/sk wins (volcAccessKey), then bearer token,
    /// then consoleSession cookies.
    public static func credential(for providerId: String, from config: TokenRunwayConfigFile?) -> Credential? {
        guard let entry = config?.providers[providerId] else { return nil }
        if let ak = entry.ak, let sk = entry.sk, !ak.isEmpty, !sk.isEmpty {
            return .volcAccessKey(ak: ak, sk: sk)
        }
        if let token = entry.token, !token.isEmpty {
            return .bearer(token)
        }
        if let serviceToken = entry.cookieToken, let userId = entry.cookieUserId,
           !serviceToken.isEmpty, !userId.isEmpty {
            return .sessionCookies(serviceToken: serviceToken, userId: userId)
        }
        return nil
    }

    /// localCLI mode: does not read ~/.trwy/config.json; the credential points at the local
    /// CLI's OAuth login directory (KIMI_CODE_HOME or ~/.kimi-code), read/refreshed by the
    /// adapter. Returns nil when the CLI credential file is missing (= not logged in): the
    /// upper layer maps that to not-configured so the Dashboard shows the gear button (opening
    /// the settings page with /login guidance) instead of a misleading "Auth failed (check
    /// key)". Only existence is checked, not freshness — "file exists but token expired" is
    /// the normal path and is left to the adapter to refresh.
    public static func localCLICredential(home: URL = KimiCLICredentialStore.defaultHome) -> Credential? {
        let credentialsFile = home.appendingPathComponent("credentials/kimi-code.json")
        guard FileManager.default.fileExists(atPath: credentialsFile.path) else { return nil }
        return .localOAuth(home: home.path)
    }
}
