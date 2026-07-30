import Foundation

/// 鉴权模式（DESIGN.md §4）
public enum AuthMode: String, Codable, Sendable {
    /// Bearer 直连（DeepSeek / OpenAI / Anthropic）
    case bearer
    /// Volc Signature V4 HMAC（火山）
    case volcSignature
    /// 控制台浏览器登录态，经内嵌 WKWebView（无 API 的 provider 兜底）
    case consoleSession
}

/// 凭证（注入式，适配器不持有；真实存储在 Keychain，见 DESIGN.md §10）
public enum Credential: Sendable {
    case bearer(String)
    case volcAccessKey(ak: String, sk: String)
}

/// 永不泄露明文：任何 print()/String(describing:) 只看到前 4 字符 + 长度（DESIGN.md §10 密钥零落盘）。
extension Credential: CustomStringConvertible {
    public var description: String {
        switch self {
        case .bearer(let token):
            return "bearer(\(token.prefix(4))…\(token.count) chars)"
        case .volcAccessKey(let ak, let sk):
            return "volcAccessKey(ak: \(ak.prefix(4))…, sk: \(sk.prefix(4))…)"
        }
    }
}

public enum ProviderError: Error, Sendable, Equatable {
    case missingCredential
    /// 401（volcSignature 下需区分凭证错误与本地时钟漂移）
    case unauthorized
    case rateLimited
    case network(String)
    /// 响应结构变更
    case parse(String)
    /// 5xx 等
    case unknown(Int)
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

    public init(
        id: String,
        displayName: String,
        authMode: AuthMode,
        defaultBaseURL: String? = nil,
        allowsBaseURLOverride: Bool = false,
        defaultPollInterval: TimeInterval = 300
    ) {
        self.id = id
        self.displayName = displayName
        self.authMode = authMode
        self.defaultBaseURL = defaultBaseURL
        self.allowsBaseURLOverride = allowsBaseURLOverride
        self.defaultPollInterval = defaultPollInterval
    }
}

/// Provider 适配器协议（DESIGN.md §4，manifest 为 id/名称的唯一事实源）
public protocol Provider: Sendable {
    var manifest: ProviderManifest { get }
    var supportedQuotaTypes: [QuotaType] { get }
    func fetchUsage(credential: Credential) async throws -> ProviderReport
}

public extension Provider {
    var id: String { manifest.id }
}
