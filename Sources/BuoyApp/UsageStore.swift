import Foundation
import BuoyCore

/// 用量数据中心：真数据（per-provider 轮询 + 退避 + 持久化）或 mock 场景（BUOY_MOCK，视觉测试）。
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var reports: [ProviderReport] = []
    @Published private(set) var providerErrors: [String: String] = [:]
    @Published private(set) var isRefreshing = false

    // MARK: 展示状态（DESIGN.md §8.1）
    /// 球面展示模式；默认 `tightest`（自动选最差健康度的 provider 上球）
    @Published var displayMode: DisplayMode = .tightest
    /// 用户钉选的 provider（`fixed` 模式生效；徽标点击 / 右键菜单切换会回退到 fixed）
    @Published var pinnedProviderId: String = "volcano"
    /// 轮播索引（`carousel` 模式生效）
    @Published private(set) var carouselIndex: Int = 0
    /// 核心液面窗口（滚轮切换，DESIGN.md §8.5）
    @Published var coreQuotaId: String = "volcano.5h"
    /// 穿透模式：球体鼠标穿透，仅 ambient 显示（DESIGN.md §8.5）
    @Published var clickThrough: Bool = false
    /// 暂停轮询（右键菜单开关）
    @Published var pollingPaused: Bool = false

    private let providers: [String: any Provider]
    private var pollTasks: [String: Task<Void, Never>] = [:]
    private var carouselTask: Task<Void, Never>?
    private var consecutiveFailures: [String: Int] = [:]
    private let backoff = BackoffPolicy()
    /// 采样历史 + 燃烧率/ETA（DESIGN.md §7）。每次成功拉取后 ingest；持久化到 cache.json。
    private var forecast = ForecastEngine()

    init(providers: [any Provider] = [VolcanoProvider(), DeepSeekProvider()]) {
        self.providers = Dictionary(providers.map { ($0.manifest.id, $0) },
                                    uniquingKeysWith: { first, _ in first })
    }

    // MARK: - 启动 / 调度

    /// 启动：加载缓存 + per-provider 轮询（错峰 + 退避）+ 轮播计时。BUOY_MOCK=<scenario> 走 mock 场景。
    func start() {
        if let scenario = ProcessInfo.processInfo.environment["BUOY_MOCK"] {
            loadMockScenario(scenario)
            return
        }
        loadCache()
        let ids = providers.keys.sorted()
        for (index, id) in ids.enumerated() {
            guard let provider = providers[id] else { continue }
            let base = provider.manifest.defaultPollInterval
            pollTasks[id] = Task { [weak self] in
                // 错峰：每个 provider 错开 5s 起步，避免齐刷刷打满网络（DESIGN.md §6）
                try? await Task.sleep(for: .seconds(Double(index) * 5))
                while !Task.isCancelled {
                    guard let self else { return }
                    if !self.pollingPaused { await self.fetchOne(id) }
                    let delay = self.backoff.delay(base: base, afterFailures: self.consecutiveFailures[id] ?? 0)
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
        startCarouselTimer()
    }

    func stop() {
        pollTasks.values.forEach { $0.cancel() }
        pollTasks.removeAll()
        carouselTask?.cancel()
        carouselTask = nil
    }

    /// 打开总面板时调用：数据太旧则补一次拉取
    func refreshIfStale(maxAge: TimeInterval = 60) {
        guard !pollTasks.isEmpty else { return } // mock 模式不刷
        let oldest = reports.map(\.fetchedAt).min() ?? .distantPast
        if Date().timeIntervalSince(oldest) > maxAge {
            Task { await refresh() }
        }
    }

    // MARK: - 拉取

    /// 手动刷新全部 provider（刷新按钮 / 回前台）。
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await withTaskGroup(of: Void.self) { group in
            for id in providers.keys {
                group.addTask { [weak self] in await self?.fetchOne(id) }
            }
            for await _ in group {}
        }
    }

    /// 拉取单个 provider。失败保留旧 report + 记录连续失败次数（驱动退避，DESIGN.md §6）。
    private func fetchOne(_ id: String) async {
        guard let provider = providers[id] else { return }
        guard let credential = CredentialStore.credential(for: id, from: CredentialStore.load()) else {
            providerErrors[id] = "未配置凭证"
            return
        }
        do {
            let report = try await provider.fetchUsage(credential: credential)
            upsert(report)
            providerErrors[id] = nil
            consecutiveFailures[id] = 0
            saveCache()
        } catch {
            consecutiveFailures[id] = (consecutiveFailures[id] ?? 0) + 1
            providerErrors[id] = Self.describe(error)
        }
    }

    private func upsert(_ report: ProviderReport) {
        forecast.ingest(report: report, pollInterval: pollInterval(forProvider: report.providerId))
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

    // MARK: - 持久化（DESIGN.md §6 本地缓存，重启不冷启动）

    private func loadCache() {
        guard let cache = CacheStore.load() else { return }
        reports = cache.reports.sorted { $0.providerId < $1.providerId }
        forecast = cache.forecast
    }

    private func saveCache() {
        CacheStore.save(BuoyCache(reports: reports, forecast: forecast))
    }

    // MARK: - 轮播

    private func startCarouselTimer() {
        carouselTask?.cancel()
        carouselTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard let self else { return }
                if self.displayMode == .carousel { self.advanceCarousel() }
            }
        }
    }

    private func advanceCarousel() {
        let ids = reports.map(\.providerId).sorted()
        guard !ids.isEmpty else { return }
        carouselIndex = (carouselIndex + 1) % ids.count
    }

    // MARK: - 展示派生

    private func pollInterval(forProvider id: String) -> TimeInterval {
        providers[id]?.manifest.defaultPollInterval ?? 300
    }

    /// 当前球面展示的 provider（按模式解析，DESIGN.md §8.1）。
    var displayProviderId: String {
        let sortedIds = reports.map(\.providerId).sorted()
        switch displayMode {
        case .fixed:
            return pinnedProviderId
        case .tightest:
            guard !reports.isEmpty else { return pinnedProviderId }
            // 最差健康度优先；error/stale provider 健康度 nil 视作最紧（需上球示警）
            let best = reports.min { lhs, rhs in
                let l = healthScore(for: lhs) ?? 0
                let r = healthScore(for: rhs) ?? 0
                return l < r
            }
            return best?.providerId ?? pinnedProviderId
        case .carousel:
            guard !sortedIds.isEmpty else { return pinnedProviderId }
            return sortedIds[carouselIndex % sortedIds.count]
        }
    }

    /// 钉选某 provider 上球并切到 fixed 模式（徽标点击 / 总面板选择）。
    func pinDisplay(to id: String) {
        pinnedProviderId = id
        displayMode = .fixed
    }

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

    /// 展示数据是否过期（拉取失败 / 数据陈旧，DESIGN.md §6 降级 -> 球面 stale）。
    var displayIsStale: Bool {
        isStale(for: displayReport?.providerId ?? displayProviderId)
    }

    func isStale(for providerId: String) -> Bool {
        guard let report = reports.first(where: { $0.providerId == providerId }) else { return false }
        return Date().timeIntervalSince(report.fetchedAt) > pollInterval(forProvider: providerId) * 2
    }

    /// 当前核心窗口的 ETA（球呼吸节奏用，DESIGN.md §8.4）。
    var coreEta: TimeInterval? {
        guard let quota = coreQuota else { return nil }
        return forecast.eta(for: quota, pollInterval: pollInterval(forProvider: displayReport?.providerId ?? ""))
    }

    /// 单 quota 的 ETA（总面板展示）。
    func eta(for quota: Quota) -> TimeInterval? {
        let providerId = String(quota.id.prefix { $0 != "." })
        return forecast.eta(for: quota, pollInterval: pollInterval(forProvider: providerId))
    }

    /// 单 quota 的采样序列（sparkline 用）。
    func samples(for quotaId: String) -> [UsageSample] {
        forecast.samples(for: quotaId)
    }

    /// provider 级健康度（用真实 ETA，修复 balance 型恒 nil，DESIGN.md §7）。
    func healthScore(for report: ProviderReport) -> Double? {
        let interval = pollInterval(forProvider: report.providerId)
        let etas: [String: TimeInterval?] = Dictionary(
            report.quotas.map { ($0.id, forecast.eta(for: $0, pollInterval: interval)) },
            uniquingKeysWith: { first, _ in first }
        )
        return HealthScore.providerScore(quotas: report.quotas, etas: etas)
    }

    // MARK: - 球面状态 / 模型（DESIGN.md §8.3 / §8.4）

    /// windowed 型期望燃烧率 = limit / 窗口秒数（匀速耗尽基准）。balance / 缺失返回 nil。
    private func expectedBurnRate(for quota: Quota) -> Double? {
        guard quota.type == .timeWindowed,
              let limit = quota.limit, limit > 0,
              let start = quota.windowStart, let end = quota.resetsAt, end > start else { return nil }
        return limit / end.timeIntervalSince(start)
    }

    /// 单个 provider 的球面状态（用于展示 provider 与隐藏 provider 徽标）。
    func ballState(forProvider id: String) -> BallState {
        guard let report = reports.first(where: { $0.providerId == id }) else {
            return providerErrors[id] != nil ? .error : .idle
        }
        let interval = pollInterval(forProvider: id)
        let windowed = report.quotas.first(where: { $0.type == .timeWindowed })
        let burnRate = windowed.flatMap { forecast.burnRate(for: $0, pollInterval: interval) }
        let expected = windowed.flatMap { expectedBurnRate(for: $0) }
        return BallStateResolver.resolve(
            health: healthScore(for: report),
            burnRate: burnRate,
            expectedBurnRate: expected,
            hasError: providerErrors[id] != nil,
            isStale: isStale(for: id)
        )
    }

    /// 当前展示 provider 的球面状态（用展示中的核心窗口判定 fast-burn）。
    var displayBallState: BallState {
        let interval = pollInterval(forProvider: displayProviderId)
        let burnRate = coreQuota.flatMap { forecast.burnRate(for: $0, pollInterval: interval) }
        let expected = coreQuota.flatMap { expectedBurnRate(for: $0) }
        let hasError = displayError != nil && displayReport == nil
        return BallStateResolver.resolve(
            health: displayHealth,
            burnRate: burnRate,
            expectedBurnRate: expected,
            hasError: hasError,
            isStale: displayIsStale
        )
    }

    /// 球面展示模型（BallView 的单一数据源，DESIGN.md §8）。
    var ballModel: BallModel {
        let badges = alertBadges
        let breath = breathUrgency(from: coreEta)
        let stale = displayIsStale

        guard let report = displayReport else {
            // 冷启动：无数据
            return BallModel(mode: .cold, ringUsed: nil, coreRemaining: nil,
                             health: nil, centerText: "--", subText: "",
                             currencyBadge: nil, state: .idle,
                             breathUrgency: breath, isStale: stale, alertBadges: badges)
        }

        let state = displayBallState

        // 余额型：环退化为单层余额球（DESIGN.md §8.3）
        if report.balance != nil, !report.quotas.contains(where: { $0.type == .timeWindowed }) {
            let eta = coreEta
            let balHealth = HealthScore.forBalance(etaSeconds: eta)
            return BallModel(mode: .balance, ringUsed: nil,
                             coreRemaining: balHealth, health: balHealth,
                             centerText: String(format: "%.2f", report.balance?.total ?? 0),
                             subText: formatETA(eta),
                             currencyBadge: report.balance.map { currencySymbol($0.currency) },
                             state: state, breathUrgency: breath, isStale: stale,
                             alertBadges: badges)
        }

        // 窗口型：外环 + 核心
        let ring = ringQuota?.percentUsed                    // 外环 = 已用 %（DESIGN §8.3）
        let core = coreQuota?.percentUsed.map { 1 - $0 }     // 液面 = 剩余 %（耗尽抽空，DESIGN §8.3/§8.4）
        let coreUsed = coreQuota?.percentUsed                // 中央数字 = 已用 %（100% = 耗尽）
        let isError = state == .error
        let center: String
        if isError { center = "!" }
        else if let coreUsed { center = "\(Int((coreUsed * 100).rounded()))%" }
        else { center = "--" }
        let sub = isError ? "error" : shortLabel(coreQuota?.id ?? "")
        return BallModel(mode: isError ? .error : .windowed,
                         ringUsed: ring, coreRemaining: core, health: displayHealth,
                         centerText: center, subText: sub, currencyBadge: nil,
                         state: state, breathUrgency: breath, isStale: stale,
                         alertBadges: badges)
    }

    /// 逃逸徽标（DESIGN.md §8.1）：任一非展示 provider 告急。
    var alertBadges: [AlertBadge] {
        let displayId = displayProviderId
        var badges: [AlertBadge] = []
        for report in reports where report.providerId != displayId {
            let severity = severity(forState: ballState(forProvider: report.providerId))
            if let severity { badges.append(AlertBadge(id: report.providerId, severity: severity)) }
        }
        // 有错误但从未拿到数据的 provider
        for id in providerErrors.keys where id != displayId && !reports.contains(where: { $0.providerId == id }) {
            badges.append(AlertBadge(id: id, severity: .error))
        }
        return badges
    }

    /// 任一隐藏 provider 告急（旧 API 兼容）。
    var hasHiddenProviderAlert: Bool { !alertBadges.isEmpty }

    private func severity(forState state: BallState) -> BadgeSeverity? {
        switch state {
        case .error: return .error
        case .depleted: return .depleted
        case .nearDepleted: return .nearDepleted
        case .fastBurn: return .fastBurn
        case .idle, .consuming: return nil
        }
    }

    // MARK: - 滚轮 / 核心窗口

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
    /// exhausted 耗尽 / mixed 环急核缓 / balance-critical 余额将尽 / 缺省 = healthy
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
                      used: fiveHourUsed, limit: 10000,
                      windowStart: now.addingTimeInterval(-2 * 3600), resetsAt: now.addingTimeInterval(3 * 3600)),
                Quota(id: "volcano.7d", type: .timeWindowed, label: "每周额度", unit: .credits,
                      used: weeklyUsed, limit: 35000,
                      windowStart: now.addingTimeInterval(-3 * 86400), resetsAt: now.addingTimeInterval(4 * 86400)),
                Quota(id: "volcano.30d", type: .timeWindowed, label: "每月额度", unit: .credits,
                      used: monthlyUsed, limit: 100000,
                      windowStart: now.addingTimeInterval(-12 * 86400), resetsAt: now.addingTimeInterval(18 * 86400)),
            ]
        )
        let deepseekRemaining: Double = (name == "balance-critical") ? 0.5 : 1.25
        let deepseek = ProviderReport(
            providerId: "deepseek",
            fetchedAt: now,
            quotas: [Quota(id: "deepseek.balance", type: .balance, label: "账户余额", unit: .cny,
                           remaining: deepseekRemaining)],
            balance: BalanceInfo(currency: "CNY", total: deepseekRemaining, granted: 0, toppedUp: deepseekRemaining)
        )
        reports = [volcano, deepseek]

        // balance-critical：合成下降采样，让余额球显出 depleted 动画
        if name == "balance-critical" {
            seedBalanceForecast(endingAt: deepseekRemaining)
        }
    }

    /// 合成 deepseek 余额下降采样（视觉测试用；正常路径由 fetchOne -> ingest 产生）。
    private func seedBalanceForecast(endingAt remaining: Double) {
        let now = Date()
        let interval = pollInterval(forProvider: "deepseek")
        let step: TimeInterval = 120
        for i in 0..<4 {
            let t = now.addingTimeInterval(-Double(3 - i) * step)
            let r = remaining + Double(3 - i) * 1.0
            let report = ProviderReport(
                providerId: "deepseek", fetchedAt: t,
                quotas: [Quota(id: "deepseek.balance", type: .balance, label: "账户余额", unit: .cny, remaining: r)],
                balance: BalanceInfo(currency: "CNY", total: r, granted: 0, toppedUp: r))
            forecast.ingest(report: report, pollInterval: interval)
        }
    }
}
