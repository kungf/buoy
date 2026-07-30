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
}
