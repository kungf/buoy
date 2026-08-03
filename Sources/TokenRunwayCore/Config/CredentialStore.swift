import Foundation

/// ~/.trwy/config.json 的单 provider 条目。字段按 auth 模式取用：
/// bearer → token；volcSignature → ak/sk；apiKey/baseURL 保留给推理类接口。
public struct ProviderCredentials: Codable, Sendable, Equatable {
    public var auth: String?
    public var token: String?
    public var ak: String?
    public var sk: String?
    public var apiKey: String?
    public var baseURL: String?

    public init(auth: String? = nil, token: String? = nil, ak: String? = nil,
                sk: String? = nil, apiKey: String? = nil, baseURL: String? = nil) {
        self.auth = auth
        self.token = token
        self.ak = ak
        self.sk = sk
        self.apiKey = apiKey
        self.baseURL = baseURL
    }
}

/// 凭证配置文件（chmod 600，仓库外；M2 迁移 Keychain，DESIGN.md §10）
public struct TokenRunwayConfigFile: Codable, Sendable, Equatable {
    public var providers: [String: ProviderCredentials]

    public init(providers: [String: ProviderCredentials]) {
        self.providers = providers
    }
}

/// 凭证加载与映射。token 绝不打印、不写日志。
public enum CredentialStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".trwy/config.json")
    }

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
        let data = try JSONEncoder().encode(config)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 条目 → 统一 Credential。ak/sk 齐备优先 volcAccessKey，其次 bearer token。
    public static func credential(for providerId: String, from config: TokenRunwayConfigFile?) -> Credential? {
        guard let entry = config?.providers[providerId] else { return nil }
        if let ak = entry.ak, let sk = entry.sk, !ak.isEmpty, !sk.isEmpty {
            return .volcAccessKey(ak: ak, sk: sk)
        }
        if let token = entry.token, !token.isEmpty {
            return .bearer(token)
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
