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
public struct CustomMetricConfig: Codable, Sendable, Equatable, Identifiable {
    /// Stable id (UUID at creation), the persistence key for selection / ball-position / cache state; immutable
    public let id: String
    /// Display name (ball badge / quota label)
    public var name: String
    /// Prometheus root URL, e.g. http://prom.internal:9090 (adapter appends /api/v1/query)
    public var baseURL: String
    /// Metric name or full PromQL expression (e.g. api_budget_usage / sum(api_budget_usage)).
    /// Leave label empty when using an aggregation expression (labels can't be safely
    /// appended to an aggregation result).
    public var metric: String
    /// Label filter "xx=xx", comma-separated (team=data,env=prod); empty = no filter.
    /// Values must not contain commas or quotes (only backslash and quote are escaped).
    public var label: String
    /// Fixed cap (user-entered, e.g. monthly budget 5000). used + max → used water;
    /// used without max → plain value, no water; remaining + max → remaining water
    public var max: Double?
    /// Unit (CNY/USD/custom text). nil = no unit
    public var unit: Unit?
    /// Metric semantics: used (default) / remaining
    public var semantics: MetricSemantics

    /// id carries a fixed "custom-" prefix so UsageStore hot-reload/removal and
    /// Dashboard routing can identify custom providers
    public init(id: String = "custom-\(UUID().uuidString)", name: String, baseURL: String,
                metric: String, label: String = "", max: Double? = nil, unit: Unit? = nil,
                semantics: MetricSemantics = .used) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.metric = metric
        self.label = label
        self.max = max
        self.unit = unit
        self.semantics = semantics
    }

    /// Legacy configs (no semantics field) default to .used
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        metric = try container.decode(String.self, forKey: .metric)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        max = try container.decodeIfPresent(Double.self, forKey: .max)
        unit = try container.decodeIfPresent(Unit.self, forKey: .unit)
        semantics = try container.decodeIfPresent(MetricSemantics.self, forKey: .semantics) ?? .used
    }

    /// Parse "team=data,env=prod" → [("team","data"),("env","prod")].
    /// Empty label → []; nil when any key/value is empty, `=` is missing, or an empty segment
    /// appears (leading/trailing/double commas, e.g. "a=b,") — the fetch layer reports the
    /// error instead of silently dropping labels.
    public var labelPairs: [(key: String, value: String)]? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var pairs: [(key: String, value: String)] = []
        for part in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let comps = part.split(separator: "=", maxSplits: 1)
            guard comps.count == 2,
                  let key = comps.first.map({ $0.trimmingCharacters(in: .whitespaces) }), !key.isEmpty,
                  let value = comps.last.map({ $0.trimmingCharacters(in: .whitespaces) }), !value.isEmpty
            else { return nil }
            pairs.append((key, value))
        }
        return pairs
    }

    /// PromQL query string: metric or metric{key="value",...}. Label values escape `\` and `"`.
    /// nil = malformed label or empty metric.
    public var query: String? {
        let trimmed = metric.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let pairs = labelPairs else { return nil }
        guard !pairs.isEmpty else { return trimmed }
        let rendered = pairs.map { "\($0.key)=\"\(Self.escape($0.value))\"" }.joined(separator: ",")
        return "\(trimmed){\(rendered)}"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
