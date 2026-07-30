import Foundation
import CryptoKit

/// Volc Signature V4（HMAC-SHA256）签名器，DESIGN.md §5.2。
/// 官方文档示例：SignedHeaders=host;x-content-sha256;x-date
public struct VolcSigner: Sendable {
    public let region: String
    public let service: String

    public init(region: String = "cn-beijing", service: String = "ark") {
        self.region = region
        self.service = service
    }

    public struct SignedHeaders: Sendable {
        public let xDate: String
        public let contentSHA256: String
        public let authorization: String
    }

    /// 对请求签名。query 需已按键名排序要求传入（内部会排序）。
    public func sign(
        method: String,
        uri: String,
        query: [String: String],
        host: String,
        body: Data,
        ak: String,
        sk: String,
        now: Date = Date()
    ) -> SignedHeaders {
        let xDate = Self.xDateFormatter.string(from: now)
        let shortDate = String(xDate.prefix(8))

        let payloadHash = Self.hexSHA256(body)
        let canonicalQuery = query
            .sorted { $0.key < $1.key }
            .map { "\(Self.percentEncode($0.key))=\(Self.percentEncode($0.value))" }
            .joined(separator: "&")

        let canonicalHeaders =
            "host:\(host)\n" +
            "x-content-sha256:\(payloadHash)\n" +
            "x-date:\(xDate)\n"
        let signedHeaders = "host;x-content-sha256;x-date"

        let canonicalRequest = [
            method,
            uri,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let credentialScope = "\(shortDate)/\(region)/\(service)/request"
        let stringToSign = [
            "HMAC-SHA256",
            xDate,
            credentialScope,
            Self.hexSHA256(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let kDate = Self.hmac(key: Data(sk.utf8), data: Data(shortDate.utf8))
        let kRegion = Self.hmac(key: kDate, data: Data(region.utf8))
        let kService = Self.hmac(key: kRegion, data: Data(service.utf8))
        let kSigning = Self.hmac(key: kService, data: Data("request".utf8))
        let signature = Self.hmac(key: kSigning, data: Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()

        let authorization =
            "HMAC-SHA256 Credential=\(ak)/\(credentialScope), " +
            "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        return SignedHeaders(xDate: xDate, contentSHA256: payloadHash, authorization: authorization)
    }

    static let xDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// RFC3986：保留 [A-Za-z0-9-_.~]
    static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
