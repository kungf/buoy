import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let data: Data
}

/// 薄 URLSession 封装，便于测试替换（DESIGN.md §11 Networking 层）
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network("non-HTTP response")
        }
        return HTTPResponse(status: http.statusCode, data: data)
    }
}

public extension ProviderError {
    /// 按 HTTP 状态码映射错误模型（DESIGN.md §4）
    static func fromStatus(_ status: Int) -> ProviderError? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        default: return .unknown(status)
        }
    }
}
