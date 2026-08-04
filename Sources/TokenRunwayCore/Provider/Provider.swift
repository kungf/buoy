import Foundation

/// Auth mode (DESIGN.md §4)
public enum AuthMode: String, Codable, Sendable {
    /// Bearer direct (DeepSeek / OpenAI / Anthropic)
    case bearer
    /// Volc Signature V4 HMAC (Volcano)
    case volcSignature
    /// Console browser login state via an embedded WKWebView (fallback for providers without an API)
    case consoleSession
    /// Reuses the local CLI's OAuth login state (reads the CLI credential file, e.g. Kimi Code; no manual input)
    case localCLI
    /// No credential required (custom metrics on open internal endpoints)
    case none
}

/// Credential (injected; adapters don't own it; stored in Keychain, see DESIGN.md §10)
public enum Credential: Sendable {
    case bearer(String)
    case volcAccessKey(ak: String, sk: String)
    /// localCLI mode: points at the local CLI's credential root (e.g. ~/.kimi-code), read/refreshed by the adapter
    case localOAuth(home: String)
    /// Console login state: browser SSO session cookies (e.g. MiMo api-platform_serviceToken + userId).
    /// Extracted after login in the embedded WKWebView; re-login when expired.
    case sessionCookies(serviceToken: String, userId: String)
    /// No credential: adapter sends a bare request (custom metric on an open endpoint)
    case none
}

/// Never leaks plaintext: any print()/String(describing:) sees only the first 4 chars + length (DESIGN.md §10, keys never touch disk).
extension Credential: CustomStringConvertible {
    public var description: String {
        switch self {
        case .bearer(let token):
            return "bearer(\(token.prefix(4))…\(token.count) chars)"
        case .volcAccessKey(let ak, let sk):
            return "volcAccessKey(ak: \(ak.prefix(4))…, sk: \(sk.prefix(4))…)"
        case .localOAuth(let home):
            return "localOAuth(home: \(home.prefix(4))…\(home.count) chars)"
        case .sessionCookies(let serviceToken, let userId):
            return "sessionCookies(serviceToken: \(serviceToken.prefix(4))…\(serviceToken.count) chars, userId: \(userId.prefix(4))…)"
        case .none:
            return "none"
        }
    }
}

public enum ProviderError: Error, Sendable, Equatable {
    case missingCredential
    /// 401 (under volcSignature, distinguish credential errors from local clock drift)
    case unauthorized
    case rateLimited
    case network(String)
    /// Response structure change
    case parse(String)
    /// 5xx etc.
    case unknown(Int)
}

/// Provider theme color (Core-safe, no SwiftUI dependency). The App layer maps it to `Color` via an extension.
/// Color identity lives in the manifest so adding a provider never requires maintaining a parallel App theme table.
public enum ThemeColor: Sendable {
    case orange, blue, purple, green, red, teal, indigo, pink, gray
}

public struct ProviderManifest: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let authMode: AuthMode
    public let defaultBaseURL: String?
    public let allowsBaseURLOverride: Bool
    /// Default poll interval (seconds). Short-window providers poll more often:
    /// Volcano 5h window = 120s; DeepSeek balance = 180s (3min, trades off consumption
    /// tracking granularity against fewer requests).
    public let defaultPollInterval: TimeInterval
    /// Short ball badge code (e.g. "ds"/"vol"). nil -> heuristic truncation from the id.
    public let shortName: String?
    /// Console/platform URL for the settings panel's "how to get credentials" help link. Per provider, not per authMode.
    public let consoleURL: String?
    /// Logo resource name in the App bundle (e.g. "deepseek_logo"). nil -> SF Symbol fallback.
    public let logoName: String?
    /// Theme color.
    public let themeColor: ThemeColor
    /// trwyctl env-var prefix override (e.g. Volcano uses "VOLC", not the id "VOLCANO"). nil -> uppercased id.
    /// External contract: changes must be synced with the README and users' shell rc.
    public let envPrefixOverride: String?
    /// Fetching works without credentials (e.g. custom metrics on open internal endpoints).
    /// When true, UsageStore injects `.none` if no stored credential exists, and the
    /// adapter sends a bare request.
    public let allowsNoCredential: Bool

    /// Actual env-var prefix, e.g. "DEEPSEEK" / "VOLC".
    public var envPrefix: String { envPrefixOverride ?? id.uppercased() }

    public init(
        id: String,
        displayName: String,
        authMode: AuthMode,
        defaultBaseURL: String? = nil,
        allowsBaseURLOverride: Bool = false,
        defaultPollInterval: TimeInterval = 300,
        shortName: String? = nil,
        consoleURL: String? = nil,
        logoName: String? = nil,
        themeColor: ThemeColor = .purple,
        envPrefixOverride: String? = nil,
        allowsNoCredential: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.authMode = authMode
        self.defaultBaseURL = defaultBaseURL
        self.allowsBaseURLOverride = allowsBaseURLOverride
        self.defaultPollInterval = defaultPollInterval
        self.shortName = shortName
        self.consoleURL = consoleURL
        self.logoName = logoName
        self.themeColor = themeColor
        self.envPrefixOverride = envPrefixOverride
        self.allowsNoCredential = allowsNoCredential
    }
}

/// Provider adapter protocol (DESIGN.md §4; the manifest is the single source of truth for id/name)
public protocol Provider: Sendable {
    var manifest: ProviderManifest { get }
    var supportedQuotaTypes: [QuotaType] { get }
    func fetchUsage(credential: Credential) async throws -> ProviderReport
}

public extension Provider {
    var id: String { manifest.id }
}
