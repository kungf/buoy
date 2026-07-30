import Foundation
import BuoyCore

/// Usage data center: real data (per-provider polling + backoff + persistence) or mock scenarios
/// (BUOY_MOCK, for visual testing).
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var reports: [ProviderReport] = []
    @Published private(set) var providerErrors: [String: String] = [:]
    @Published private(set) var isRefreshing = false

    // MARK: Display state (DESIGN.md §8.1 multi-select ball cluster)
    /// Providers shown on the ball (multi-select, ordered; persisted to UserDefaults). Defaults to
    /// only the first provider.
    @Published private(set) var selectedProviderIds: [String] = []
    /// Core liquid window per displayed provider (scroll-wheel cycling, DESIGN.md §8.5)
    @Published private(set) var coreQuotaIds: [String: String] = [:]
    /// Click-through mode: the ball lets mouse events pass through, ambient display only (DESIGN.md §8.5)
    @Published var clickThrough: Bool = false
    /// Polling paused (toggled from the right-click menu)
    @Published var pollingPaused: Bool = false

    private let providers: [String: any Provider]
    /// Provider init order (gives a stable order for "the first ball" and cluster arrangement)
    private let providerOrder: [String]
    private let preferences: SelectionStorage
    private var pollTasks: [String: Task<Void, Never>] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private let backoff = BackoffPolicy()
    /// Sample history + burn-rate/ETA (DESIGN.md §7). Ingested after each successful fetch; persisted
    /// to cache.json.
    private var forecast = ForecastEngine()

    init(providers: [any Provider] = [VolcanoProvider(), DeepSeekProvider()],
         preferences: SelectionStorage = Preferences()) {
        self.providerOrder = providers.map { $0.manifest.id }
        self.providers = Dictionary(providers.map { ($0.manifest.id, $0) },
                                    uniquingKeysWith: { first, _ in first })
        self.preferences = preferences
    }

    // MARK: - Startup / scheduling

    /// Startup: load selection + cache + per-provider polling (staggered + backoff).
    /// BUOY_MOCK=<scenario> runs a mock scenario instead.
    func start() {
        loadSelection()
        if let scenario = ProcessInfo.processInfo.environment["BUOY_MOCK"] {
            loadMockScenario(scenario)
            return
        }
        loadCache()
        for (index, id) in providerOrder.enumerated() {
            guard let provider = providers[id] else { continue }
            let base = provider.manifest.defaultPollInterval
            pollTasks[id] = Task { [weak self] in
                // Stagger: each provider starts 5s apart to avoid a synchronized network burst (DESIGN.md §6)
                try? await Task.sleep(for: .seconds(Double(index) * 5))
                while !Task.isCancelled {
                    guard let self else { return }
                    if !self.pollingPaused { await self.fetchOne(id) }
                    let delay = self.backoff.delay(base: base, afterFailures: self.consecutiveFailures[id] ?? 0)
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    func stop() {
        pollTasks.values.forEach { $0.cancel() }
        pollTasks.removeAll()
    }

    /// Called when the dashboard opens: fetch once if data is too stale.
    func refreshIfStale(maxAge: TimeInterval = 60) {
        guard !pollTasks.isEmpty else { return } // no refresh in mock mode
        let oldest = reports.map(\.fetchedAt).min() ?? .distantPast
        if Date().timeIntervalSince(oldest) > maxAge {
            Task { await refresh() }
        }
    }

    // MARK: - Fetching

    /// Manually refresh all providers (refresh button / app re-activation).
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

    /// Fetch a single provider. On failure keep the old report and record consecutive failures
    /// (drives backoff, DESIGN.md §6).
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
        let order = providerOrder
        reports = next.sorted { lhs, rhs in
            let li = order.firstIndex(of: lhs.providerId) ?? Int.max
            let ri = order.firstIndex(of: rhs.providerId) ?? Int.max
            return li < ri
        }
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

    // MARK: - Persistence (DESIGN.md §6 local cache, no cold start on restart)

    private func loadCache() {
        guard let cache = CacheStore.load() else { return }
        let order = providerOrder
        reports = cache.reports.sorted { lhs, rhs in
            let li = order.firstIndex(of: lhs.providerId) ?? Int.max
            let ri = order.firstIndex(of: rhs.providerId) ?? Int.max
            return li < ri
        }
        forecast = cache.forecast
    }

    private func saveCache() {
        CacheStore.save(BuoyCache(reports: reports, forecast: forecast))
    }

    // MARK: - Selection (multi-select ball cluster, DESIGN.md §8.1)

    func isSelected(_ id: String) -> Bool { selectedProviderIds.contains(id) }

    /// Toggle a provider onto the ball (dashboard eye toggle / right-click "remove from ball").
    func toggleSelection(_ id: String) {
        applySelection(currentState().toggling(id))
    }

    /// Add a provider to the cluster (breakthrough badge / alert-bar tap: no duplicate, no replace).
    func addToSelection(_ id: String) {
        applySelection(currentState().adding(id))
    }

    /// Select only one provider (replace).
    func selectOnly(_ id: String) {
        applySelection(currentState().selectingOnly(id))
    }

    private func currentState() -> SelectionState {
        SelectionState(selectedIds: selectedProviderIds, providerOrder: providerOrder)
    }

    private func applySelection(_ state: SelectionState) {
        selectedProviderIds = state.selectedIds
        persistSelection()
    }

    private func loadSelection() {
        let stored = preferences.loadSelectedIds()
        let resolved = SelectionState(selectedIds: stored, providerOrder: providerOrder)
            .sanitized(keepingValid: Set(providerOrder))
        selectedProviderIds = resolved.selectedIds.isEmpty
            ? SelectionState.defaultSelection(providerOrder: providerOrder).selectedIds
            : resolved.selectedIds
        persistSelection()
    }

    private func persistSelection() {
        preferences.saveSelectedIds(selectedProviderIds)
    }

    // MARK: - Display derivation

    private func pollInterval(forProvider id: String) -> TimeInterval {
        providers[id]?.manifest.defaultPollInterval ?? 300
    }

    private func report(for providerId: String) -> ProviderReport? {
        reports.first { $0.providerId == providerId }
    }

    /// Outer ring = longest window (30d preferred)
    func ringQuota(for providerId: String) -> Quota? {
        guard let report = report(for: providerId) else { return nil }
        let windowed = report.quotas.filter { $0.type == .timeWindowed }
        return windowed.first { $0.id.hasSuffix(".30d") } ?? windowed.last
    }

    /// Core = the provider's active window (coreQuotaIds or first windowed). For balance-only
    /// providers (no windowed quotas), falls back to the balance quota so the core liquid renders.
    func coreQuota(for providerId: String) -> Quota? {
        guard let report = report(for: providerId) else { return nil }
        let windowed = report.quotas.filter { $0.type == .timeWindowed }
        if let id = coreQuotaIds[providerId] {
            return windowed.first { $0.id == id } ?? windowed.first
        }
        if let first = windowed.first { return first }
        return report.quotas.first { $0.type == .balance }
    }

    /// Middle ring = the windowed quota that is neither the outer ring nor the core, preferring the
    /// longest such window (for Volcano this is 7d). Returns nil when there is no third tier
    /// (the middle ring is simply not drawn).
    func midRingQuota(for providerId: String) -> Quota? {
        guard let report = report(for: providerId) else { return nil }
        let windowed = report.quotas.filter { $0.type == .timeWindowed }
        let ringId = ringQuota(for: providerId)?.id
        let coreId = coreQuota(for: providerId)?.id
        let candidates = windowed.filter { $0.id != ringId && $0.id != coreId }
        return candidates.max(by: { Self.windowDuration($0) < Self.windowDuration($1) })
    }

    /// Length (seconds) of a windowed quota's [windowStart, resetsAt) interval; 0 if unknown.
    private static func windowDuration(_ quota: Quota) -> TimeInterval {
        guard let start = quota.windowStart, let end = quota.resetsAt, end > start else { return 0 }
        return end.timeIntervalSince(start)
    }

    /// ETA of the current core window (drives ball breathing cadence, DESIGN.md §8.4).
    func coreEta(for providerId: String) -> TimeInterval? {
        guard let quota = coreQuota(for: providerId) else { return nil }
        return forecast.eta(for: quota, pollInterval: pollInterval(forProvider: providerId))
    }

    /// ETA for a single quota (dashboard display).
    func eta(for quota: Quota) -> TimeInterval? {
        let providerId = String(quota.id.prefix { $0 != "." })
        return forecast.eta(for: quota, pollInterval: pollInterval(forProvider: providerId))
    }

    /// Sample sequence for a single quota (sparkline).
    func samples(for quotaId: String) -> [UsageSample] {
        forecast.samples(for: quotaId)
    }

    /// Provider-level health (uses real ETA, fixing balance type always-nil, DESIGN.md §7).
    func healthScore(for report: ProviderReport) -> Double? {
        let interval = pollInterval(forProvider: report.providerId)
        let etas: [String: TimeInterval?] = Dictionary(
            report.quotas.map { ($0.id, forecast.eta(for: $0, pollInterval: interval)) },
            uniquingKeysWith: { first, _ in first }
        )
        return HealthScore.providerScore(quotas: report.quotas, etas: etas)
    }

    func isStale(for providerId: String) -> Bool {
        guard let report = reports.first(where: { $0.providerId == providerId }) else { return false }
        return Date().timeIntervalSince(report.fetchedAt) > pollInterval(forProvider: providerId) * 2
    }

    // MARK: - Ball state / model (DESIGN.md §8.3 / §8.4)

    /// Expected burn rate for a windowed quota = limit / window seconds (uniform-drain baseline).
    /// Returns nil for balance / missing data.
    private func expectedBurnRate(for quota: Quota) -> Double? {
        guard quota.type == .timeWindowed,
              let limit = quota.limit, limit > 0,
              let start = quota.windowStart, let end = quota.resetsAt, end > start else { return nil }
        return limit / end.timeIntervalSince(start)
    }

    /// Ball state for a single provider (uses its core window to detect fast-burn).
    func ballState(for providerId: String) -> BallState {
        guard let report = report(for: providerId) else {
            return providerErrors[providerId] != nil ? .error : .idle
        }
        let interval = pollInterval(forProvider: providerId)
        let core = coreQuota(for: providerId) ?? report.quotas.first { $0.type == .timeWindowed }
        let burnRate = core.flatMap { forecast.burnRate(for: $0, pollInterval: interval) }
        let expected = core.flatMap { expectedBurnRate(for: $0) }
        return BallStateResolver.resolve(
            health: healthScore(for: report),
            burnRate: burnRate,
            expectedBurnRate: expected,
            hasError: providerErrors[providerId] != nil,
            isStale: isStale(for: providerId)
        )
    }

    /// Ball display model (BallView's single source of truth, DESIGN.md §8). One per provider.
    func ballModel(for providerId: String) -> BallModel {
        let stale = isStale(for: providerId)
        // Breakthrough badges live only on the primary (first selected) ball to avoid duplicates.
        let isPrimary = providerId == selectedProviderIds.first
        let badges: [AlertBadge] = isPrimary ? alertBadges : []

        guard let report = report(for: providerId) else {
            return coldBallModel(badges: badges, breath: 0, stale: stale)
        }

        let state = ballState(for: providerId)

        // Balance type: rings collapse to a single balance ball; breathing is derived from
        // 5h spend (explosion-free), NOT from ETA, so coreEta is intentionally not computed here.
        if report.balance != nil, !report.quotas.contains(where: { $0.type == .timeWindowed }) {
            return balanceBallModel(report: report, state: state, badges: badges, stale: stale)
        }
        let breath = breathUrgency(from: coreEta(for: providerId))
        return windowedBallModel(report: report, state: state, badges: badges, breath: breath, stale: stale)
    }

    /// Cold start: no data yet.
    private func coldBallModel(badges: [AlertBadge], breath: Double, stale: Bool) -> BallModel {
        BallModel(mode: .cold, ringUsed: nil, midRingUsed: nil, coreLevel: nil,
                  ringHealth: nil, midRingHealth: nil, coreHealth: nil,
                  centerText: "--", subText: "", spentRecentText: nil,
                  currencyBadge: nil, state: .idle,
                  breathUrgency: breath, isStale: stale, alertBadges: badges)
    }

    /// Last-5h spend for the balance quota (top-up-robust, DESIGN.md §7). nil on cold start.
    private func consumed5h(for providerId: String) -> Double? {
        let windowSeconds: TimeInterval = 5 * 3600 // last-5h spend window
        guard let quota = coreQuota(for: providerId) else { return nil }
        return forecast.consumed(for: quota, windowSeconds: windowSeconds, now: Date())
    }

    /// Balance high-water mark: max remaining observed in the sample buffer (render-time
    /// only; no persistence). Balance samples store `used = -remaining`, so max remaining
    /// = -min(used). nil when there are no samples.
    private func balanceHighWater(for quota: Quota) -> Double? {
        let usedValues = forecast.samples(for: quota.id).map(\.used)
        guard let minUsed = usedValues.min() else { return nil }
        return -minUsed
    }

    /// Balance type: rings collapse to a single balance ball (DESIGN.md §8.3). Drops the ETA
    /// entirely; breathing is `consumed_5h / remaining` (bounded, explosion-free), liquid
    /// level/color is `remaining / highWater` (decoupled from breathing).
    private func balanceBallModel(report: ProviderReport, state: BallState,
                                  badges: [AlertBadge], stale: Bool) -> BallModel {
        let providerId = report.providerId
        let quota = coreQuota(for: providerId)
        let remaining = quota?.effectiveRemaining ?? report.balance?.total ?? 0

        // Liquid level + color: remaining vs high-water mark (decoupled from breathing).
        let highWater = quota.flatMap { balanceHighWater(for: $0) } ?? remaining
        let level = highWater > 0 ? min(max(remaining / highWater, 0), 1) : 0

        // Breathing: consumed_5h / remaining (the bounded 5h/ETA form; static = calm).
        let consumedOpt = consumed5h(for: providerId)
        let consumed = consumedOpt ?? 0
        let breath = remaining > 0 ? min(max(consumed / remaining, 0), 1) : 0

        // Upper (small): last-5h spend; Lower (big): balance.
        let spentText = consumedOpt.map { "¥\(String(format: "%.2f", $0))·5h" } ?? "--"

        return BallModel(mode: .balance, ringUsed: nil, midRingUsed: nil,
                         coreLevel: level, ringHealth: nil, midRingHealth: nil, coreHealth: level,
                         centerText: String(format: "%.2f", report.balance?.total ?? 0),
                         subText: "", spentRecentText: spentText,
                         currencyBadge: report.balance.map { currencySymbol($0.currency) },
                         state: state, breathUrgency: breath, isStale: stale, alertBadges: badges)
    }

    /// Windowed type: outer ring (30d) + middle ring (7d) + core liquid (active window).
    private func windowedBallModel(report: ProviderReport, state: BallState,
                                   badges: [AlertBadge], breath: Double, stale: Bool) -> BallModel {
        let providerId = report.providerId
        let ringQ = ringQuota(for: providerId)
        let midQ = midRingQuota(for: providerId)
        let coreQ = coreQuota(for: providerId)
        let ringUsed = ringQ?.percentUsed
        let midUsed = midQ?.percentUsed
        // Unified "used" semantics: liquid level = active window used % (rises as consumed).
        let coreLevel = coreQ?.percentUsed
        let isError = state == .error
        let center: String
        if isError { center = "!" }
        else if let coreLevel { center = "\(Int((coreLevel * 100).rounded()))%" }
        else { center = "--" }
        let sub = isError ? "error" : shortLabel(coreQ?.id ?? "")
        // Each channel colored by its own remaining health (DESIGN §8.3 independent coloring);
        // core no longer uses state, fixing "5h at 7% turns yellow".
        let ringHealth = ringQ.flatMap { HealthScore.score(quota: $0, etaSeconds: eta(for: $0)) }
        let midHealth = midQ.flatMap { HealthScore.score(quota: $0, etaSeconds: eta(for: $0)) }
        let coreHealth = coreQ.flatMap { HealthScore.score(quota: $0, etaSeconds: eta(for: $0)) }
        return BallModel(mode: isError ? .error : .windowed,
                         ringUsed: ringUsed, midRingUsed: midUsed, coreLevel: coreLevel,
                         ringHealth: ringHealth, midRingHealth: midHealth, coreHealth: coreHealth,
                         centerText: center, subText: sub, spentRecentText: nil, currencyBadge: nil,
                         state: state, breathUrgency: breath, isStale: stale,
                         alertBadges: badges)
    }

    /// Breakthrough badges (DESIGN.md §8.1): an unselected provider in an alerting state raises a
    /// rim reminder on the cluster. Tapping calls addToSelection to add it to the cluster.
    var alertBadges: [AlertBadge] {
        var badges: [AlertBadge] = []
        for id in providerOrder where !isSelected(id) {
            let severity = severity(forState: ballState(for: id))
            if let severity { badges.append(AlertBadge(id: id, severity: severity)) }
        }
        return badges
    }

    private func severity(forState state: BallState) -> BadgeSeverity? {
        switch state {
        case .error: return .error
        case .depleted: return .depleted
        case .nearDepleted: return .nearDepleted
        case .fastBurn: return .fastBurn
        case .idle, .consuming: return nil
        }
    }

    // MARK: - Scroll / core window

    /// Scroll: cycle through a provider's windowed quotas.
    func cycleCoreWindow(forward: Bool, for providerId: String) {
        guard let report = report(for: providerId) else { return }
        let windowed = report.quotas.filter { $0.type == .timeWindowed }
        guard windowed.count > 1 else { return }
        let current = windowed.firstIndex { $0.id == coreQuota(for: providerId)?.id } ?? 0
        let next = (current + (forward ? 1 : -1) + windowed.count) % windowed.count
        coreQuotaIds[providerId] = windowed[next].id
    }

    // MARK: - Mock scenarios (BUOY_MOCK env var, for visual testing)

    /// Scenarios: critical 5h 95% red / warning 45% orange / healthy 10% green /
    /// exhausted drained / mixed ring-hot core-cool / balance-critical balance running out /
    /// default = healthy
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

        // balance-critical: synthesize a declining sample series so the balance ball shows the
        // depleted animation.
        if name == "balance-critical" {
            seedBalanceForecast(endingAt: deepseekRemaining)
        }
    }

    /// Synthesize a declining deepseek balance sample series (for visual testing; the normal path is
    /// produced by fetchOne -> ingest).
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
