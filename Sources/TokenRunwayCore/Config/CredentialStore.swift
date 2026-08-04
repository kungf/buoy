import Foundation

/// ~/.trwy/config.json 的单 provider 条目。字段按 auth 模式取用：
/// bearer → token；volcSignature → ak/sk；consoleSession → cookieToken/cookieUserId；
/// apiKey/baseURL 保留给推理类接口。
public struct ProviderCredentials: Codable, Sendable, Equatable {
    public var auth: String?
    public var token: String?
    public var ak: String?
    public var sk: String?
    public var apiKey: String?
    public var baseURL: String?
    /// consoleSession：浏览器 SSO 会话 cookie（如 MiMo 的 api-platform_serviceToken / userId）
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

/// 凭证配置文件（chmod 600，仓库外；M2 迁移 Keychain，DESIGN.md §10）
public struct TokenRunwayConfigFile: Codable, Sendable, Equatable {
    public var providers: [String: ProviderCredentials]
    /// 用户自定义指标配置（非机密；token 仍走 providers[<id>].token）。
    /// 存同一文件而非 UserDefaults：trwyctl 与 App 分属不同进程域，需共享。
    public var customMetrics: [CustomMetricConfig]

    public init(providers: [String: ProviderCredentials], customMetrics: [CustomMetricConfig] = []) {
        self.providers = providers
        self.customMetrics = customMetrics
    }

    /// 旧 config.json 无 customMetrics 字段：decodeIfPresent 兜底为空数组
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decode([String: ProviderCredentials].self, forKey: .providers)
        customMetrics = try container.decodeIfPresent([CustomMetricConfig].self, forKey: .customMetrics) ?? []
    }
}

/// 自定义指标配置的读取与增删（与 providers 同文件，原子写回）。
public enum CustomMetricConfigStore {
    public static func load(from url: URL = CredentialStore.defaultURL) -> [CustomMetricConfig] {
        CredentialStore.load(from: url)?.customMetrics ?? []
    }

    /// 新增/更新（按 id 原地替换保持顺序；不动其余配置与 providers）
    public static func upsert(_ config: CustomMetricConfig, to url: URL = CredentialStore.defaultURL) throws {
        var file = CredentialStore.load(from: url) ?? TokenRunwayConfigFile(providers: [:])
        if let index = file.customMetrics.firstIndex(where: { $0.id == config.id }) {
            file.customMetrics[index] = config
        } else {
            file.customMetrics.append(config)
        }
        try CredentialStore.save(file, to: url)
    }

    /// 删除配置并清理同 id 的凭证条目
    public static func remove(id: String, from url: URL = CredentialStore.defaultURL) throws {
        var file = CredentialStore.load(from: url) ?? TokenRunwayConfigFile(providers: [:])
        file.customMetrics.removeAll { $0.id == id }
        file.providers.removeValue(forKey: id)
        try CredentialStore.save(file, to: url)
    }
}

/// 凭证加载与映射。token 绝不打印、不写日志。
public enum CredentialStore {
    /// 配置路径。get-set：测试可重定向到临时文件（默认 ~/.trwy/config.json）
    public static var defaultURL: URL {
        get { defaultURLStorage }
        set { defaultURLStorage = newValue }
    }
    /// nonisolated(unsafe)：仅测试重定向用，生产路径只读
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
        // 目录若已存在（旧版本创建/手动创建）不会应用 createDirectory 的权限，
        // 必须每次保存都强制 0700，否则 .atomic 临时文件在 chmod 600 前可能按 umask 落盘
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let data = try JSONEncoder().encode(config)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 条目 → 统一 Credential。ak/sk 齐备优先 volcAccessKey，其次 bearer token，
    /// 其次 consoleSession 会话 cookie。
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

    /// localCLI 模式：不读 ~/.trwy/config.json，凭证指向本机 CLI 的 OAuth 登录态目录
    ///（KIMI_CODE_HOME 或 ~/.kimi-code），由适配器读取/刷新。
    /// CLI 凭证文件不存在（= 未登录）时返回 nil：上层据此映射为 not-configured，
    /// Dashboard 才会显示齿轮按钮（打开含 /login 指引的设置页），而不是误导性的
    /// "Auth failed (check key)"。注意只判文件存在性，不判 token 新鲜度——
    /// "文件存在但 token 过期"是正常路径，交由适配器刷新。
    public static func localCLICredential(home: URL = KimiCLICredentialStore.defaultHome) -> Credential? {
        let credentialsFile = home.appendingPathComponent("credentials/kimi-code.json")
        guard FileManager.default.fileExists(atPath: credentialsFile.path) else { return nil }
        return .localOAuth(home: home.path)
    }
}
