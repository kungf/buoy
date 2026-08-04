import Foundation
import TokenRunwayCore

/// Usage data center: real data (per-provider polling + backoff + persistence) or mock scenarios
/// (TRWY_MOCK, for visual testing).
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var reports: [ProviderReport] = []
    @Published var providerErrors: [String: String] = [:]
    @Published private(set) var isRefreshing = false

    // MARK: Display state (DESIGN.md §8.1 multi-select ball cluster)
    /// Providers shown on the ball (multi-select, ordered; persisted to UserDefaults). Defaults to
    /// only the first provider.
    @Published private(set) var selectedProviderIds: [String] = []
    /// Core liquid window per displayed provider (scroll-wheel cycling, DESIGN.md §8.5)
    @Published private(set) var coreQuotaIds: [String: String] = [:]
    /// Click-through mode: the ball lets mouse events pass through, ambient display only (DESIGN.md §8.5)
    @Published var clickThrough: Bool = false
    /// Error message when a provider has no credentials in ~/.trwy/config.json.
    static let notConfiguredError = "Not configured"
    /// Polling paused (toggled from the right-click menu)
    @Published var pollingPaused: Bool = false

    /// var：自定义指标保存后可热加载（reloadCustomMetrics）
    private var providers: [String: any Provider]
    /// Provider init order (gives a stable order for "the first ball" and cluster arrangement)
    private var providerOrder: [String]
    private let preferences: SelectionStorage
    private var pollTasks: [String: Task<Void, Never>] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private let backoff = BackoffPolicy()
    /// Sample history + burn-rate/ETA (DESIGN.md §7). Ingested after each successful fetch; persisted
    /// to cache.json.
    private var forecast = ForecastEngine()

    init(providers: [any Provider]? = nil,
         preferences: SelectionStorage = Preferences()) {
        // 未显式注入时：内置 provider + 用户自定义指标（~/.trwy/config.json 的 customMetrics）
        let resolved = providers ?? ProviderRegistry.all(includingCustom: CustomMetricConfigStore.load())
        self.providerOrder = resolved.map { $0.manifest.id }
        self.providers = Dictionary(resolved.map { ($0.manifest.id, $0) },
                                    uniquingKeysWith: { first, _ in first })
        self.preferences = preferences
    }

    // MARK: - Startup / scheduling

    /// Startup: load selection + cache + per-provider polling (staggered + backoff).
    /// TRWY_MOCK=<scenario> runs a mock scenario instead.
    func start() {
        loadSelection()
        if let scenario = ProcessInfo.processInfo.environment["TRWY_MOCK"] {
            loadMockScenario(scenario)
            return
        }
        loadCache()
        for (index, id) in providerOrder.enumerated() {
            startPolling(id: id, stagger: Double(index) * 5)
        }
    }

    /// 启动单个 provider 的轮询任务。start 时错峰 5s（避免同步网络突发，DESIGN.md §6）；
    /// 自定义指标保存后热加载时即时启动（stagger=1）。
    private func startPolling(id: String, stagger: TimeInterval) {
        guard let provider = providers[id] else { return }
        let base = provider.manifest.defaultPollInterval
        pollTasks[id]?.cancel()
        pollTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(stagger))
            while !Task.isCancelled {
                guard let self else { return }
                if !self.pollingPaused { await self.fetchOne(id) }
                let delay = self.backoff.delay(base: base, afterFailures: self.consecutiveFailures[id] ?? 0)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// 自定义指标配置变更后热加载（设置面板保存/删除后调用）：
    /// 新增的立即注册并开始轮询；编辑的替换实例（轮询循环每轮重读 providers[id]，无需重启任务）；
    /// 删除的取消轮询、清理报告/错误/选中态并落盘缓存（否则删除的指标会在重启后从 cache.json 复活）。
    func reloadCustomMetrics() {
        let configs = CustomMetricConfigStore.load()
        let activeIds = Set(configs.map(\.id))
        // 删除已移除的
        for id in Array(providers.keys) where isCustomProvider(id) && !activeIds.contains(id) {
            providers.removeValue(forKey: id)
            providerOrder.removeAll { $0 == id }
            pollTasks[id]?.cancel()
            pollTasks.removeValue(forKey: id)
            consecutiveFailures.removeValue(forKey: id)
            providerErrors.removeValue(forKey: id)
            reports.removeAll { $0.providerId == id }
        }
        // 新增/更新的：注册（总是替换实例，使编辑立即生效）+ 启动轮询
        for config in configs {
            if providers[config.id] == nil {
                providerOrder.append(config.id)
            }
            providers[config.id] = CustomMetricsProvider(config: config)
            if pollTasks[config.id] == nil {
                startPolling(id: config.id, stagger: 1)
            }
        }
        // 删除的 provider 若在球簇上，一并移除（保持选择集合有效）
        let valid = providerOrder
        selectedProviderIds = selectedProviderIds.filter { valid.contains($0) }
        persistSelection()
        saveCache()
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
        guard let credential = resolveCredential(for: provider) else {
            providerErrors[id] = Self.notConfiguredError
            return
        }
        do {
            let report = try await provider.fetchUsage(credential: credential)
            // await 期间该 provider 可能已被删除（自定义指标热移除）：重新确认，
            // 否则已删除的 report/错误行会作为"幽灵"复活且无人能清理
            guard providers[id] != nil else { return }
            upsert(report)
            providerErrors[id] = nil
            consecutiveFailures[id] = 0
            saveCache()
            autoSwitchIfNeeded()
        } catch {
            guard providers[id] != nil else { return }
            consecutiveFailures[id] = (consecutiveFailures[id] ?? 0) + 1
            providerErrors[id] = Self.describe(error)
        }
    }

    /// 自定义指标 provider 判定（按类型而非 id 前缀：手改 config.json 的 id 也能正确
    /// 识别，热移除/齿轮路由才不致漏掉）
    func isCustomProvider(_ id: String) -> Bool {
        providers[id] is CustomMetricsProvider
    }

    /// 凭证解析：localCLI 模式读本机 CLI 登录态目录；自定义指标（allowsNoCredential）
    /// 无存储凭证时注入 .none —— 内网公开端点允许裸请求，不显示 "Not configured"。
    private func resolveCredential(for provider: any Provider) -> Credential? {
        if provider.manifest.authMode == .localCLI {
            return CredentialStore.localCLICredential()
        }
        let stored = CredentialStore.credential(for: provider.manifest.id, from: CredentialStore.load())
        // 注意必须写 Credential.none——返回类型是 Credential?，裸 .none 会解析成 Optional.none（nil）
        if stored == nil, provider.manifest.allowsNoCredential {
            return Credential.none
        }
        return stored
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
        case .missingCredential: return "Missing credential"
        case .unauthorized: return "Auth failed (check key)"
        case .rateLimited: return "Rate limited, will retry"
        case .network(let msg): return "Network error: \(msg)"
        case .parse(let msg): return "Parse error: \(msg)"
        case .unknown(let code): return "HTTP \(code)"
        }
    }

    // MARK: - Persistence (DESIGN.md §6 local cache, no cold start on restart)

    private func loadCache() {
        guard let cache = CacheStore.load() else { return }
        let order = providerOrder
        // 过滤掉已不存在的 provider（如重启前删除的自定义指标残留），防止幽灵报告复活
        reports = cache.reports
            .filter { order.contains($0.providerId) }
            .sorted { lhs, rhs in
                let li = order.firstIndex(of: lhs.providerId) ?? Int.max
                let ri = order.firstIndex(of: rhs.providerId) ?? Int.max
                return li < ri
            }
        forecast = cache.forecast
    }

    private func saveCache() {
        CacheStore.save(TokenRunwayCache(reports: reports, forecast: forecast))
    }

    // MARK: - Selection (multi-select ball cluster, DESIGN.md §8.1)

    func isSelected(_ id: String) -> Bool { selectedProviderIds.contains(id) }

    /// Human-readable provider name for hover popover / detail views.
    func providerDisplayName(for id: String) -> String {
        providers[id]?.manifest.displayName ?? id
    }

    /// Auth mode for a provider (drives settings form).
    var knownProviderIds: [String] { providerOrder }
    func providerManifest(for id: String) -> ProviderManifest? {
        providers[id]?.manifest
    }

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

    /// If all selected providers are unconfigured and at least one other provider has data,
    /// auto-switch to the first provider with data. Called after each successful fetch so
    /// the ball transitions from "no key" to showing real data without manual intervention.
    func autoSwitchIfNeeded() {
        guard !selectedProviderIds.isEmpty else { return }
        let allSelectedUnconfigured = selectedProviderIds.allSatisfy {
            providerErrors[$0] == Self.notConfiguredError
        }
        guard allSelectedUnconfigured else { return }
        guard let firstWithData = providerOrder.first(where: { id in
            reports.contains(where: { $0.providerId == id })
        }) else { return }
        applySelection(SelectionState(selectedIds: [firstWithData], providerOrder: providerOrder))
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

    /// Outer ring = longest window (30d preferred; otherwise max by window length).
    /// Volcano: 30d. Kimi: 7d weekly — the old `windowed.last` fallback put Kimi's SHORTEST
    /// window (the 300m rate window) on the outside, inverting the hierarchy.
    /// Durations are exact: providers set `windowStart = resetsAt − period` (Kimi, Volcano).
    func ringQuota(for providerId: String) -> Quota? {
        guard let report = report(for: providerId) else { return nil }
        let windowed = report.quotas.filter { $0.type == .timeWindowed }
        if let preferred = windowed.first(where: { $0.id.hasSuffix(".30d") }) { return preferred }
        return Self.longestWindow(windowed) ?? windowed.last
    }

    /// Core = the provider's active window (coreQuotaIds, else the SHORTEST window — the most
    /// immediate tier, mirroring Volcano's 5h core; the old "first windowed" made Kimi's 7d
    /// weekly — its LONGEST window — the core while the 5h rate window became the outer ring).
    /// For balance-only providers (no windowed quotas), falls back to the balance quota so the
    /// core liquid renders.
    func coreQuota(for providerId: String) -> Quota? {
        guard let report = report(for: providerId) else { return nil }
        let windowed = report.quotas.filter { $0.type == .timeWindowed }
        if let id = coreQuotaIds[providerId] {
            return windowed.first { $0.id == id } ?? Self.shortestWindow(windowed)
        }
        return Self.shortestWindow(windowed) ?? report.quotas.first { $0.type == .balance }
    }

    /// Longest window among those with a known duration (windowDuration > 0); when no duration
    /// is known, falls back to report order — same rule for ring/mid/core, in one place.
    private static func longestWindow(_ quotas: [Quota]) -> Quota? {
        knownDuration(quotas).max { windowDuration($0) < windowDuration($1) }
    }

    /// Shortest window (the most immediate tier) among those with a known duration; falls back
    /// to report order when no duration is known.
    private static func shortestWindow(_ quotas: [Quota]) -> Quota? {
        knownDuration(quotas).min { windowDuration($0) < windowDuration($1) }
    }

    private static func knownDuration(_ quotas: [Quota]) -> [Quota] {
        let known = quotas.filter { windowDuration($0) > 0 }
        return known.isEmpty ? quotas : known
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
    /// `now`-aware so a windowed quota whose `resetsAt` has passed is treated as fully
    /// healthy (mirrors `Quota.percentUsedAt(now:)` — keeps state consistent with the
    /// liquid level when the Mac slept through a window reset).
    func healthScore(for report: ProviderReport) -> Double? {
        let interval = pollInterval(forProvider: report.providerId)
        let etas: [String: TimeInterval?] = Dictionary(
            report.quotas.map { ($0.id, forecast.eta(for: $0, pollInterval: interval)) },
            uniquingKeysWith: { first, _ in first }
        )
        return HealthScore.providerScore(quotas: report.quotas, etas: etas, now: Date())
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
            if providerErrors[providerId] == Self.notConfiguredError { return .notConfigured }
            return providerErrors[providerId] != nil ? .error : .idle
        }
        // 拉取错误优先（与 BallStateResolver 的 error 最高优先级一致）：
        // cookie 过期(401) 等瞬时错误应显示 error 而非永久态 expired，避免误导
        if providerErrors[providerId] != nil { return .error }
        if report.planExpired == true { return .expired }
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
            let state = ballState(for: providerId)
            return coldBallModel(badges: badges, breath: 0, stale: stale, state: state)
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
    private func coldBallModel(badges: [AlertBadge], breath: Double, stale: Bool,
                               state: BallState = .idle) -> BallModel {
        BallModel(mode: .cold, ringUsed: nil, midRingUsed: nil, coreLevel: nil,
                  ringHealth: nil, midRingHealth: nil, coreHealth: nil,
                  centerText: "--", subText: state == .notConfigured ? "no key" : "",
                  spentRecentText: nil,
                  currencyBadge: nil, state: state,
                  breathUrgency: breath, isStale: stale, alertBadges: badges)
    }

    /// `used` samples within the last `windowSeconds`, oldest first — feeds the hover-card
    /// "last-5h spend" sparkline (Dashboard/Sparkline.swift). Balance samples store
    /// `used = -remaining`, so the curve rises while the balance drops. Empty on cold start.
    func usedSeries(for providerId: String, windowSeconds: TimeInterval) -> [Double] {
        guard let quota = coreQuota(for: providerId) else { return [] }
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        return forecast.samples(for: quota.id)
            .filter { $0.at >= cutoff }
            .map(\.used)
    }

    /// Last-5h spend for the balance quota (top-up-robust, DESIGN.md §7). nil on cold start.
    /// Internal for the hover card (HoverSummaryView) which labels the 5h window.
    func consumed5h(for providerId: String) -> Double? {
        let windowSeconds: TimeInterval = 5 * 3600 // last-5h spend window
        guard let quota = coreQuota(for: providerId) else { return nil }
        return forecast.consumed(for: quota, windowSeconds: windowSeconds, now: Date())
    }

    /// Balance high-water mark: the largest remaining balance observed, persisted across
    /// launches (UserDefaults) so a restart never resets the "full" reference. Balance
    /// samples store `used = -remaining`, so the in-session peak = -min(used).
    ///
    /// A significant upward jump in balance vs. the last observed value (top-up / grant
    /// refresh) re-anchors the high-water to the new balance — a refilled account reads as
    /// full again, even if the new balance is below the historical peak. A slow decline is
    /// consumption and never re-anchors; a crash (grant expiry) intentionally does not,
    /// so the low level keeps warning.
    private static let balanceHighWaterKeyPrefix = "trwy.balanceHighWater"
    /// Balance rising more than this ratio vs. the last observed value counts as a new
    /// funding cycle (top-up / grant refresh), not consumption noise.
    private static let topUpJumpRatio = 1.10

    private func balanceHighWater(for quota: Quota, remaining: Double) -> Double {
        let key = Self.balanceHighWaterKeyPrefix + "." + quota.id
        let defaults = UserDefaults.standard
        let persisted = defaults.double(forKey: key)
        // In-session peak counts only samples after the last re-anchor: a top-up below the
        // historical peak must not be undone by old high-balance samples still in the buffer.
        let anchorDate = defaults.object(forKey: key + ".anchor") as? Date
        let minUsed = forecast.samples(for: quota.id)
            .filter { sample in anchorDate.map { $0 <= sample.at } ?? true }
            .map(\.used)
            .min() ?? 0
        var highWater = max(persisted, -minUsed)

        // Balance jumped vs. the last observed value -> refilled: re-anchor to full.
        let lastKey = key + ".last"
        if let last = defaults.object(forKey: lastKey) as? Double,
           remaining > last * Self.topUpJumpRatio {
            highWater = remaining
            defaults.set(Date(), forKey: key + ".anchor")
        } else if remaining > highWater {
            highWater = remaining
        }
        if highWater > 0 { defaults.set(highWater, forKey: key) }
        defaults.set(remaining, forKey: lastKey)
        return highWater
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
        let highWater = quota.map { balanceHighWater(for: $0, remaining: remaining) } ?? remaining
        let level = highWater > 0 ? min(max(remaining / highWater, 0), 1) : 0

        // Breathing: consumed_5h / remaining (the bounded 5h/ETA form; static = calm).
        let consumedOpt = consumed5h(for: providerId)
        let consumed = consumedOpt ?? 0
        let breath = remaining > 0 ? min(max(consumed / remaining, 0), 1) : 0

        // Upper (small): last-5h spend ("−¥x.xx"); Lower (big): balance. The 5h window is
        // labeled on the hover card (HoverSummaryView), not on the ball itself.
        // 符号取自 currency（自定义指标的 USD/无单位余额不再硬编码 ¥）
        let symbol = report.balance.map { currencySymbol($0.currency) } ?? ""
        let spentText = consumedOpt.map { "−\(symbol)\(String(format: "%.2f", $0))" } ?? "--"

        return BallModel(mode: .balance, ringUsed: nil, midRingUsed: nil,
                         coreLevel: level, ringHealth: nil, midRingHealth: nil, coreHealth: level,
                         centerText: String(format: "%.2f", report.balance?.total ?? 0),
                         subText: "", spentRecentText: spentText,
                         currencyBadge: report.balance.map { currencySymbol($0.currency) },
                         state: state, breathUrgency: breath, isStale: stale, alertBadges: badges)
    }

    /// Windowed type: outer ring (30d) + middle ring (7d) as used-progress, core liquid as
    /// the active window's REMAINING water level (unified with balance mode: full = healthy,
    /// drains as you consume — README "core liquid shows your current-window remaining").
    private func windowedBallModel(report: ProviderReport, state: BallState,
                                   badges: [AlertBadge], breath: Double, stale: Bool) -> BallModel {
        let providerId = report.providerId
        let ringQ = ringQuota(for: providerId)
        let midQ = midRingQuota(for: providerId)
        let coreQ = coreQuota(for: providerId)
        // Use `percentUsedAt(now:)` so a window whose `resetsAt` has already
        // passed reads as 0% even if the cached `used` value is stale
        // (e.g. the Mac slept through the reset and polling paused).
        let now = Date()
        let corePct = coreQ?.percentUsedAt(now: now)
        let ringUsed = ringQ?.percentUsedAt(now: now)
        let midUsed = midQ?.percentUsedAt(now: now)
        // 水位方向：used 语义 = 已用比例（满 = 耗尽）；默认 = 剩余比例（满 = 健康）。
        // 红色/呼吸语义不变（used 高 = 剩余少 = 危险，HealthScore 自动正确）。
        let coreLevel = coreQ?.showsUsedLevel == true ? corePct : corePct.map { 1 - $0 }
        let isError = state == .error
        let center: String
        if isError { center = "!" }
        else if coreQ?.showsUsedLevel == true, let used = coreQ?.used {
            // used 语义：中心 = 使用量数值
            center = Self.formatNumber(used)
        }
        else if let coreLevel { center = "\(Int((coreLevel * 100).rounded()))%" }
        else { center = "--" }
        let sub: String
        if isError { sub = "error" }
        else if state == .expired { sub = "expired" }
        else if coreQ?.showsUsedLevel == true {
            // used 语义：有 max → 已用百分比；无 max → 单位缩写
            if let pct = corePct { sub = "\(Int((pct * 100).rounded()))%" }
            else { sub = Self.unitSymbol(coreQ?.unit) }
        }
        else { sub = shortLabel(coreQ?.id ?? "") }
        // Each channel colored by its own remaining health (DESIGN §8.3 independent coloring);
        // core no longer uses state, fixing "5h at 7% turns yellow". `now`-aware so a window
        // whose `resetsAt` has already passed reports full health (green) instead of red-from-
        // stale-used — keeps color aligned with `coreLevel` after Mac sleep-through.
        let ringHealth = ringQ.flatMap { HealthScore.score(quota: $0, etaSeconds: eta(for: $0), now: now) }
        let midHealth = midQ.flatMap { HealthScore.score(quota: $0, etaSeconds: eta(for: $0), now: now) }
        let coreHealth = coreQ.flatMap { HealthScore.score(quota: $0, etaSeconds: eta(for: $0), now: now) }
        return BallModel(mode: isError ? .error : .windowed,
                         ringUsed: ringUsed, midRingUsed: midUsed, coreLevel: coreLevel,
                         ringHealth: ringHealth, midRingHealth: midHealth, coreHealth: coreHealth,
                         centerText: center, subText: sub, spentRecentText: nil, currencyBadge: nil,
                         state: state, breathUrgency: breath, isStale: stale,
                         alertBadges: badges)
    }

    /// used 语义球中心数值：整数不带小数（880），否则一位小数（1234.5）
    private static func formatNumber(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// used 语义无 max 时的单位缩写（球面 sub 文本）
    private static func unitSymbol(_ unit: TokenRunwayCore.Unit?) -> String {
        switch unit {
        case .cny: return "¥"
        case .usd: return "$"
        case .tokens: return "tok"
        case .credits: return "pt"
        case .custom(let text): return text
        case .some(.none): return ""
        case nil: return ""
        }
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
        case .idle, .consuming, .notConfigured, .expired: return nil
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

    // MARK: - Mock scenarios (TRWY_MOCK env var, for visual testing)

    /// Install a single hand-built report (used by the GIF/snapshot renderers, which need
    /// fixed data that the named scenarios do not cover).
    /// Upsert semantics (like `upsert`, but without the ordering step): a demo report for a
    /// provider replaces that provider's report and keeps the others. Also ingests the report
    /// so the hover card's "Spent (last 5h)" row has samples to compute from.
    func installDemoReport(_ report: ProviderReport) {
        forecast.ingest(report: report, pollInterval: 3600)
        var next = reports.filter { $0.providerId != report.providerId }
        next.append(report)
        reports = next
    }

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
