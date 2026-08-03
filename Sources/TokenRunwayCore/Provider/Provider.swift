import Foundation

/// 鉴权模式（DESIGN.md §4）
public enum AuthMode: String, Codable, Sendable {
    /// Bearer 直连（DeepSeek / OpenAI / Anthropic）
    case bearer
    /// Volc Signature V4 HMAC（火山）
    case volcSignature
    /// 控制台浏览器登录态，经内嵌 WKWebView（无 API 的 provider 兜底）
    case consoleSession
    /// 复用本机 CLI 的 OAuth 登录态（读 CLI 凭证文件，如 Kimi Code；无需用户手填）
    case localCLI
}

/// 凭证（注入式，适配器不持有；真实存储在 Keychain，见 DESIGN.md §10）
public enum Credential: Sendable {
    case bearer(String)
    case volcAccessKey(ak: String, sk: String)
    /// localCLI 模式：指向本机 CLI 的凭证根目录（如 ~/.kimi-code），由适配器自行读取/刷新
    case localOAuth(home: String)
}

/// 永不泄露明文：任何 print()/String(describing:) 只看到前 4 字符 + 长度（DESIGN.md §10 密钥零落盘）。
extension Credential: CustomStringConvertible {
    public var description: String {
        switch self {
        case .bearer(let token):
            return "bearer(\(token.prefix(4))…\(token.count) chars)"
        case .volcAccessKey(let ak, let sk):
            return "volcAccessKey(ak: \(ak.prefix(4))…, sk: \(sk.prefix(4))…)"
        case .localOAuth(let home):
            return "localOAuth(home: \(home.prefix(4))…\(home.count) chars)"
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

/// Provider 主题色（Core-safe，不依赖 SwiftUI）。App 层通过扩展映射成 `Color`。
/// 把颜色身份放进 manifest，避免新增 provider 时还要维护一份并行的 App 主题表。
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
    /// 球面铭牌短码（如 "ds"/"vol"）。nil -> 按 id 启发式截取。
    public let shortName: String?
    /// 控制台/平台 URL，用于设置面板的"如何获取凭证"帮助链接。按 provider 而非 authMode。
    public let consoleURL: String?
    /// App bundle 内的 logo 资源名（如 "deepseek_logo"）。nil -> SF Symbol 兜底。
    public let logoName: String?
    /// 主题色。
    public let themeColor: ThemeColor
    /// trwyctl env 变量前缀覆盖（如火山用 "VOLC" 而非 id "VOLCANO"）。nil -> id 大写。
    /// 外部契约：改动需同步 README 与用户 shell rc。
    public let envPrefixOverride: String?

    /// 实际 env 变量前缀，如 "DEEPSEEK" / "VOLC"。
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
        envPrefixOverride: String? = nil
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
