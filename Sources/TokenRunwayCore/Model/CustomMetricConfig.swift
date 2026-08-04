import Foundation

/// Metric semantics: what the metric value represents (drives the ball shape)
public enum MetricSemantics: String, Codable, Sendable {
    /// Used (default): value = consumed. With max → water = used/max (full = drained);
    /// without max → ball shows the value only, no water level
    case used
    /// Remaining: value = amount left. With max → water = remaining/max (full = healthy);
    /// without max → balance ball (water = value / historical high-water mark)
    case remaining
}

/// User-defined metric config (custom metrics provider).
/// One config = one provider instance = one ball. Stored in the `customMetrics` field of
/// ~/.trwy/config.json (shared with trwyctl, not UserDefaults — CLI and App are different
/// process domains). Non-secret fields only; the access token goes through the existing
/// providers[<id>].token bearer channel.
///
/// The endpoint must implement the output contract: GET returns
/// {"value": number|string, "max"?, "semantics"?, "unit"?, "label"?, "updatedAt"?}.
public struct CustomMetricConfig: Codable, Sendable, Equatable, Identifiable {
    /// Stable id (UUID at creation), the persistence key for selection / ball-position / cache state; immutable
    public let id: String
    /// Display name (ball badge / quota label)
    public var name: String
    /// Request URL (complete, may include a {userId} placeholder)
    public var url: String
    /// User identifier: replaces a {userId} placeholder in `url`, otherwise appended as a
    /// `user_id` query param. Empty = no identity sent
    public var userId: String
    /// Fixed cap (user-entered, e.g. monthly budget 5000). used + max → used water;
    /// used without max → plain value, no water; remaining + max → remaining water
    public var max: Double?
    /// Unit (CNY/USD/custom text). nil = no unit
    public var unit: Unit?
    /// Metric semantics: used (default) / remaining
    public var semantics: MetricSemantics

    /// id carries a fixed "custom-" prefix so UsageStore hot-reload/removal and
    /// Dashboard routing can identify custom providers
    public init(id: String = "custom-\(UUID().uuidString)", name: String, url: String,
                userId: String = "", max: Double? = nil, unit: Unit? = nil,
                semantics: MetricSemantics = .used) {
        self.id = id
        self.name = name
        self.url = url
        self.userId = userId
        self.max = max
        self.unit = unit
        self.semantics = semantics
    }

    /// Legacy configs (pre HTTP-output-contract) carried baseURL/metric/label keys — ignored
    /// here (they decode to an empty url and fail the fetch with "missing url": re-edit them)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        userId = try container.decodeIfPresent(String.self, forKey: .userId) ?? ""
        max = try container.decodeIfPresent(Double.self, forKey: .max)
        unit = try container.decodeIfPresent(Unit.self, forKey: .unit)
        semantics = try container.decodeIfPresent(MetricSemantics.self, forKey: .semantics) ?? .used
    }

    /// Request URL: a {userId} placeholder is replaced with the percent-encoded user id;
    /// otherwise a non-empty userId is appended as a `user_id` query param;
    /// empty userId = the URL is used as-is (no identity sent).
    /// nil = empty url, or a placeholder with an empty userId (config error — the fetch
    /// layer reports it instead of hitting a path with a dangling placeholder).
    public var sourceURL: String? {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("{userId}") {
            guard !userId.isEmpty else { return nil }
            return trimmed.replacingOccurrences(of: "{userId}", with: Self.encode(userId))
        }
        guard !userId.isEmpty else { return trimmed }
        guard var components = URLComponents(string: trimmed) else { return nil }
        // percentEncodedQueryItems: keeps the user's configured URL verbatim (no round-trip
        // re-normalization) and encodes userId with the same strict set as the placeholder
        // path — queryItems would leave "+" raw, which form-urlencoded backends decode as a
        // space (identity mismatch, e.g. "alice+ops@corp.com" → "alice ops@corp.com")
        if components.percentEncodedQueryItems?.contains(where: { $0.name == "user_id" }) != true {
            components.percentEncodedQueryItems = (components.percentEncodedQueryItems ?? [])
                + [URLQueryItem(name: "user_id", value: Self.encode(userId))]
        }
        return components.url?.absoluteString
    }

    /// Shape mapping used by the custom-metrics adapter:
    /// value + semantics + max → the four ball shapes (used+max → used water, full = drained;
    /// used no-max → plain value; remaining+max → remaining water, full = healthy;
    /// remaining no-max → balance ball with ¥/$ badge). `label` overrides the display name.
    public func makeReport(value: Double, label: String? = nil, now: Date = Date()) -> ProviderReport {
        let displayName = label ?? name

        // Remaining semantics: the value = amount left.
        if semantics == .remaining {
            if let max, max > 0 {
                // remaining + max: water = remaining/max (full = healthy, same as built-in providers)
                let quota = Quota(id: "\(id).main", type: .timeWindowed,
                                  label: displayName, unit: unit ?? .none,
                                  limit: max, remaining: value)
                return ProviderReport(providerId: id, fetchedAt: now, quotas: [quota])
            }
            // remaining without max: balance ball. BalanceInfo is required so ballModel routes to the
            // balance shape (otherwise the windowed branch renders "--"). currency maps ¥/$ badge.
            let quota = Quota(id: "\(id).main", type: .balance,
                              label: displayName, unit: unit ?? .none,
                              remaining: value)
            let currency: String
            switch unit {
            case .cny: currency = "CNY"
            case .usd: currency = "USD"
            default: currency = ""
            }
            return ProviderReport(providerId: id, fetchedAt: now, quotas: [quota],
                                  balance: BalanceInfo(currency: currency, total: value,
                                                       granted: 0, toppedUp: 0))
        }

        // Used semantics (default): the value = consumed. With max → used water (full = drained); without → plain value
        let quota: Quota
        if let max, max > 0 {
            quota = Quota(id: "\(id).main", type: .timeWindowed,
                          label: displayName, unit: unit ?? .none,
                          used: value, limit: max, showsUsedLevel: true)
        } else {
            quota = Quota(id: "\(id).main", type: .timeWindowed,
                          label: displayName, unit: unit ?? .none,
                          used: value, showsUsedLevel: true)
        }
        return ProviderReport(providerId: id, fetchedAt: now, quotas: [quota])
    }

    /// Percent-encode a user id for the {userId} placeholder: RFC 3986 unreserved
    /// characters only — safe in both path and query positions (urlQueryAllowed would
    /// leave & and = raw, which breaks the query grammar).
    private static func encode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
