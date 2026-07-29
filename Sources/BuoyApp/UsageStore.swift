import Foundation
import BuoyCore

/// 用量数据中心：真数据（轮询）或 mock 场景（BUOY_MOCK 环境变量，用于视觉测试）。
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var reports: [ProviderReport] = []
    @Published private(set) var providerErrors: [String: String] = [:]
    @Published private(set) var isRefreshing = false
    /// 球上展示的 provider（DESIGN.md §8.1）
    @Published var displayProviderId: String = "volcano"
    /// 核心液面窗口（滚轮切换，DESIGN.md §8.5）
    @Published var coreQuotaId: String = "volcano.5h"

    private let providers: [String: any Provider]
    private let pollInterval: TimeInterval
    private var pollTimer: Timer?
    /// 采样历史 + 燃烧率/ETA（DESIGN.md §7）。每次成功拉取后 ingest。
    private var forecast = ForecastEngine()

    init(providers: [any Provider] = [VolcanoProvider(), DeepSeekProvider()],
         pollInterval: TimeInterval = 300) {
        self.providers = Dictionary(providers.map { ($0.manifest.id, $0) },
                                    uniquingKeysWith: { first, _ in first })
        self.pollInterval = pollInterval
    }

    /// 启动：立即拉一次 + 周期轮询。BUOY_MOCK=<scenario> 时改用 mock 场景（不发网络请求）。
    func start() {
        if let scenario = ProcessInfo.processInfo.environment["BUOY_MOCK"] {
            loadMockScenario(scenario)
            return
        }
        Task { await refresh() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    /// 打开总面板时调用：数据太旧则补一次拉取
    func refreshIfStale(maxAge: TimeInterval = 60) {
        guard pollTimer != nil else { return } // mock 模式不刷
        let oldest = reports.map(\.fetchedAt).min() ?? .distantPast
        if Date().timeIntervalSince(oldest) > maxAge {
            Task { await refresh() }
        }
    }

    // MARK: - 拉取

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let config = CredentialStore.load()
        // 并发拉取各 provider；单个失败不影响其他，且保留该 provider 旧数据
        await withTaskGroup(of: (String, Result<ProviderReport, Error>?).self) { group in
            for (id, provider) in providers {
                group.addTask {
                    guard let credential = CredentialStore.credential(for: id, from: config) else {
                        return (id, nil)
                    }
                    do {
                        return (id, .success(try await provider.fetchUsage(credential: credential)))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let report):
                    upsert(report)
                    providerErrors[id] = nil
                case .failure(let error):
                    providerErrors[id] = Self.describe(error)
                case .none:
                    providerErrors[id] = "未配置凭证"
                }
            }
        }
    }

    private func upsert(_ report: ProviderReport) {
        forecast.ingest(report: report, pollInterval: pollInterval)
        var next = reports.filter { $0.providerId != report.providerId }
        next.append(report)
        reports = next.sorted { $0.providerId < $1.providerId }
    }

    private static func describe(_ error: Error) -> String {
        guard let providerError = error as? ProviderError else { return error.localizedDescription }
        switch providerError {
        case .missingCredential: return "缺少凭证"
        case .unauthorized: return "鉴权失败（检查 key）"
        case .rateLimited: return "被限流，稍后自动重试"
        case .network(let msg): return "网络错误：\(msg)"
        case .parse(let msg): return "解析错误：\(msg)"
        case .unknown(let code): return "HTTP \(code)"
        }
    }

    // MARK: - 展示派生

    var displayReport: ProviderReport? {
        reports.first { $0.providerId == displayProviderId } ?? reports.first
    }

    /// 外环 = 最长窗口（30d 优先）
    var ringQuota: Quota? {
        guard let report = displayReport else { return nil }
        let windowed = report.quotas.filter { $0.type == .timeWindowed }
        return windowed.first { $0.id.hasSuffix(".30d") } ?? windowed.last
    }

    var coreQuota: Quota? {
        guard let report = displayReport else { return nil }
        let windowed = report.quotas.filter { $0.type == .timeWindowed }
        return windowed.first { $0.id == coreQuotaId } ?? windowed.first
    }

    var displayHealth: Double? {
        guard let report = displayReport else { return nil }
        return healthScore(for: report)
    }

    var displayError: String? {
        providerErrors[displayReport?.providerId ?? displayProviderId]
    }

    /// 当前核心窗口的 ETA（球呼吸节奏用，DESIGN.md §8.4）。
    var coreEta: TimeInterval? {
        guard let quota = coreQuota else { return nil }
        return forecast.eta(for: quota, pollInterval: pollInterval)
    }

    /// 单 quota 的 ETA（总面板展示）。
    func eta(for quota: Quota) -> TimeInterval? {
        forecast.eta(for: quota, pollInterval: pollInterval)
    }

    /// 单 quota 的采样序列（sparkline 用）。
    func samples(for quotaId: String) -> [UsageSample] {
        forecast.samples(for: quotaId)
    }

    /// provider 级健康度（用真实 ETA，修复 balance 型恒 nil，DESIGN.md §7）。
    func healthScore(for report: ProviderReport) -> Double? {
        let etas: [String: TimeInterval?] = Dictionary(
            report.quotas.map { ($0.id, forecast.eta(for: $0, pollInterval: pollInterval)) },
            uniquingKeysWith: { first, _ in first }
        )
        return HealthScore.providerScore(quotas: report.quotas, etas: etas)
    }

    /// 逃逸徽标（DESIGN.md §8.1）：任一隐藏 provider 出错或健康度告急
    var hasHiddenProviderAlert: Bool {
        let displayId = displayReport?.providerId
        for report in reports where report.providerId != displayId {
            if providerErrors[report.providerId] != nil { return true }
            if let score = healthScore(for: report), score < 0.2 {
                return true
            }
        }
        for id in providerErrors.keys where id != displayId {
            return true
        }
        return false
    }

    /// 滚轮：在展示 provider 的窗口型 quota 间循环
    func cycleCoreWindow(forward: Bool) {
        guard let report = displayReport else { return }
        let windowed = report.quotas.filter { $0.type == .timeWindowed }
        guard windowed.count > 1 else { return }
        let current = windowed.firstIndex { $0.id == coreQuota?.id } ?? 0
        let next = (current + (forward ? 1 : -1) + windowed.count) % windowed.count
        coreQuotaId = windowed[next].id
    }

    // MARK: - Mock 场景（BUOY_MOCK 环境变量，视觉测试用）

    /// 场景：critical 5h 95% 红 / warning 45% 橙 / healthy 10% 绿 /
    /// exhausted 耗尽 / mixed 环急核缓 / 缺省 = healthy
    func loadMockScenario(_ name: String) {
        let now = Date()
        let fiveHourUsed: Double
        let weeklyUsed: Double
        let monthlyUsed: Double
        switch name {
        case "critical": fiveHourUsed = 9500; weeklyUsed = 32000; monthlyUsed = 92000
        case "warning":  fiveHourUsed = 4500; weeklyUsed = 18000; monthlyUsed = 55000
        case "exhausted": fiveHourUsed = 10000; weeklyUsed = 35000; monthlyUsed = 100000
        case "mixed":    fiveHourUsed = 500; weeklyUsed = 2000; monthlyUsed = 97000
        default:         fiveHourUsed = 1000; weeklyUsed = 5000; monthlyUsed = 20000 // healthy
        }
        let volcano = ProviderReport(
            providerId: "volcano",
            fetchedAt: now,
            quotas: [
                Quota(id: "volcano.5h", type: .timeWindowed, label: "5 小时额度", unit: .credits,
                      used: fiveHourUsed, limit: 10000, resetsAt: now.addingTimeInterval(2 * 3600)),
                Quota(id: "volcano.7d", type: .timeWindowed, label: "每周额度", unit: .credits,
                      used: weeklyUsed, limit: 35000, resetsAt: now.addingTimeInterval(4 * 86400)),
                Quota(id: "volcano.30d", type: .timeWindowed, label: "每月额度", unit: .credits,
                      used: monthlyUsed, limit: 100000, resetsAt: now.addingTimeInterval(18 * 86400)),
            ]
        )
        let deepseek = ProviderReport(
            providerId: "deepseek",
            fetchedAt: now,
            quotas: [Quota(id: "deepseek.balance", type: .balance, label: "账户余额", unit: .cny,
                           remaining: 1.25)],
            balance: BalanceInfo(currency: "CNY", total: 1.25, granted: 0, toppedUp: 1.25)
        )
        reports = [volcano, deepseek]
    }
}
