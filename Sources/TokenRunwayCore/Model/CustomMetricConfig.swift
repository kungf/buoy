import Foundation

/// 自定义指标语义：指标值代表什么（决定球体形态）
public enum MetricSemantics: String, Codable, Sendable {
    /// 已使用（默认）：值 = 用量。配 max → 水位 = used/max（满 = 耗尽）；
    /// 不配 max → 球只显示数值，无水位
    case used
    /// 余额：值 = 剩余量。余额球（水位 = 值/历史高水位），max 不适用
    case remaining
}

/// 用户自定义指标配置（自定义指标 Provider）。
/// 一个配置 = 一个 provider 实例 = 一个球。存于 ~/.trwy/config.json 的 `customMetrics` 字段
/// （与 trwyctl 共享，非 UserDefaults——CLI 与 App 分属不同进程域）。
/// 非机密字段全在此；访问令牌走 providers[<id>].token 的现有 bearer 通道。
public struct CustomMetricConfig: Codable, Sendable, Equatable, Identifiable {
    /// 稳定 id（首次创建生成 UUID），选择/球位置/缓存状态的持久化键，不可变
    public let id: String
    /// 显示名（球面铭牌 / quota label）
    public var name: String
    /// Prometheus 根地址，如 http://prom.internal:9090（适配器拼 /api/v1/query）
    public var baseURL: String
    /// 指标名或完整 PromQL 表达式（如 api_budget_usage / sum(api_budget_usage)）。
    /// 写了聚合表达式时 label 留空（label 无法安全地追加到聚合结果上）。
    public var metric: String
    /// 标签过滤 "xx=xx"，多个逗号分隔（team=data,env=prod）；空 = 不过滤。
    /// 值内不允许逗号与引号（转义只处理反斜杠与引号）。
    public var label: String
    /// 固定上限（用户手填，如月度预算 5000）。仅 used 语义有效：used + max → 已用水位；
    /// used 无 max → 纯值无水位；remaining 语义忽略此字段
    public var max: Double?
    /// 单位（人民币/美元/自定义文本）。nil = 无单位
    public var unit: Unit?
    /// 指标语义：已使用（默认）/ 余额
    public var semantics: MetricSemantics

    /// id 固定 "custom-" 前缀：UsageStore 热加载/移除、Dashboard 入口路由靠它识别自定义 provider
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

    /// 旧配置（无 semantics 字段）默认 .used
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

    /// 解析 "team=data,env=prod" → [("team","data"),("env","prod")]。
    /// 空 label → []；任一键/值为空、缺少 `=`、或出现空段（首尾/连续逗号，如 "a=b,"）→ nil
    /// （fetch 层报错，不静默丢标签）。
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

    /// PromQL 查询串：metric 或 metric{key="value",...}。label 值转义 `\` 与 `"`。
    /// 返回 nil = label 格式非法或 metric 为空。
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
