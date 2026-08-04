import Foundation

/// Custom metrics provider: plain HTTP JSON adapter (output-contract mode).
/// One CustomMetricConfig instance maps to one provider (id = config.id):
/// GET {url} — {userId} placeholder or user_id query param, optional Bearer — expects the
/// output contract: {"value": number|string, "max"?, "semantics"?, "unit"?, "label"?, "updatedAt"?}.
/// Output fields override the config; missing optional fields fall back to the config.
/// Shape mapping (used/remaining × max) is CustomMetricConfig.makeReport.
public struct CustomMetricsProvider: Provider {
    public let manifest: ProviderManifest
    public let config: CustomMetricConfig
    private let http: HTTPClient

    public init(config: CustomMetricConfig, http: HTTPClient = URLSessionHTTPClient()) {
        self.config = config
        self.manifest = ProviderManifest(
            id: config.id,
            displayName: config.name,
            authMode: .bearer,
            defaultBaseURL: config.url,
            allowsBaseURLOverride: false,
            defaultPollInterval: 300,
            shortName: nil,
            consoleURL: nil,
            logoName: nil,
            themeColor: .gray,
            allowsNoCredential: true
        )
        self.http = http
    }

    public let supportedQuotaTypes: [QuotaType] = [.timeWindowed, .balance]

    public func fetchUsage(credential: Credential) async throws -> ProviderReport {
        guard let urlString = config.sourceURL else {
            throw ProviderError.parse("custom: missing url (or empty userId with a {userId} placeholder)")
        }
        guard let url = URL(string: urlString) else {
            throw ProviderError.network("invalid url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        switch credential {
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .none:
            break   // open internal endpoint — bare request
        default:
            throw ProviderError.missingCredential
        }

        let response = try await http.send(request)
        if let error = ProviderError.fromStatus(response.status) { throw error }
        return try Self.parse(data: response.data, config: config)
    }

    // MARK: - Parsing

    /// Output contract DTO. value is required (nil = missing); the rest is optional.
    /// updatedAt is accepted implicitly and ignored — no staleness check yet (YAGNI).
    struct UsageOutput: Decodable {
        let value: Double?
        let max: Double?
        let semantics: String?
        let unit: String?
        let label: String?
        let error: String?

        // Hand-written init(from:) (Decodable-only type) → the compiler doesn't synthesize
        // CodingKeys; declare it explicitly
        private enum CodingKeys: String, CodingKey {
            case value, max, semantics, unit, label, error
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = container.contains(.value) ? try container.decode(ValueDTO.self, forKey: .value).double : nil
            max = try container.decodeIfPresent(Double.self, forKey: .max)
            semantics = try container.decodeIfPresent(String.self, forKey: .semantics)
            unit = try container.decodeIfPresent(String.self, forKey: .unit)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            error = try container.decodeIfPresent(String.self, forKey: .error)
        }

        /// Flexible value: JSON number or numeric string (gateways often stringify numbers)
        struct ValueDTO: Decodable {
            let double: Double
            init(from decoder: Decoder) throws {
                let single = try decoder.singleValueContainer()
                if let number = try? single.decode(Double.self) {
                    double = number
                } else if let text = try? single.decode(String.self), let parsed = Double(text) {
                    double = parsed
                } else {
                    throw DecodingError.dataCorruptedError(in: single,
                        debugDescription: "value must be a number or a numeric string")
                }
            }
        }
    }

    public static func parse(data: Data, config: CustomMetricConfig,
                             now: Date = Date()) throws -> ProviderReport {
        let decoded: UsageOutput
        do {
            decoded = try JSONDecoder().decode(UsageOutput.self, from: data)
        } catch {
            throw ProviderError.parse("custom: \(error.localizedDescription)")
        }
        // {"error": "..."} = business error; expose only the error state, never server free text
        if let serverError = decoded.error, !serverError.isEmpty {
            throw ProviderError.parse("custom: server error")
        }
        // NaN/Inf would poison percent/remaining math — reject. JSON null → decode failure above.
        guard let value = decoded.value, value.isFinite else {
            throw ProviderError.parse("custom: missing or non-numeric value")
        }

        // Output overrides config; missing optional fields fall back to the config (immutable copy)
        var effective = config
        if let raw = decoded.semantics {
            guard let semantics = MetricSemantics(rawValue: raw) else {
                throw ProviderError.parse("custom: invalid semantics")
            }
            effective.semantics = semantics
        }
        if let max = decoded.max { effective.max = max > 0 ? max : nil }
        if let unitText = decoded.unit {
            let trimmed = unitText.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased() == "none" {
                effective.unit = .none
            } else if !trimmed.isEmpty {
                effective.unit = Self.unit(from: trimmed)
            }
            // empty unit text → keep the config's unit
        }
        let label = decoded.label.flatMap {
            $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
        }
        return effective.makeReport(value: value, label: label ?? config.name, now: now)
    }

    /// Map an output unit string to the Unit enum: known tokens → fixed cases,
    /// anything else → .custom (e.g. "GB" → .custom("GB"))
    static func unit(from text: String) -> Unit {
        switch text.lowercased() {
        case "cny": return .cny
        case "usd": return .usd
        case "tokens": return .tokens
        case "credits": return .credits
        default: return .custom(text)
        }
    }
}
