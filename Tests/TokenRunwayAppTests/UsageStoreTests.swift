import XCTest
@testable import TokenRunwayApp
@testable import TokenRunwayCore

/// UsageStore auto-switch logic: when all selected providers are unconfigured and another
/// provider has data, the ball should auto-switch to the first provider with data.
@MainActor
final class UsageStoreTests: XCTestCase {

    // MARK: - Auto-switch

    func test_autoSwitch_switchesToFirstProviderWithData_whenAllSelectedUnconfigured() {
        let store = makeStore()

        // Given: provider_a is selected (default) but unconfigured
        store.selectOnly("provider_a")
        store.providerErrors["provider_a"] = UsageStore.notConfiguredError

        // And: provider_b has data
        installReport(store, id: "provider_b")

        // When
        store.autoSwitchIfNeeded()

        // Then: selection switches to the first provider with data
        XCTAssertEqual(store.selectedProviderIds, ["provider_b"])
    }

    func test_autoSwitch_noOp_whenSelectedProviderHasData() {
        let store = makeStore()

        // Given: provider_a is selected and has data
        store.selectOnly("provider_a")
        installReport(store, id: "provider_a")

        // When: autoSwitchIfNeeded has no reason to switch
        store.autoSwitchIfNeeded()

        // Then: selection stays on provider_a
        XCTAssertEqual(store.selectedProviderIds, ["provider_a"])
    }

    func test_autoSwitch_noOp_whenNoOtherProviderHasData() {
        let store = makeStore()

        // Given: provider_a is selected but unconfigured, and no other provider has data
        store.selectOnly("provider_a")
        store.providerErrors["provider_a"] = UsageStore.notConfiguredError

        // When
        store.autoSwitchIfNeeded()

        // Then: no switch — no data to switch to
        XCTAssertEqual(store.selectedProviderIds, ["provider_a"])
    }

    func test_autoSwitch_noOp_whenSelectionIsEmpty() {
        let store = makeStore()
        store.start()
        defer { store.stop() }

        // Given: no providers selected
        store.toggleSelection("provider_a") // start() loaded default, now remove it
        XCTAssertTrue(store.selectedProviderIds.isEmpty)

        installReport(store, id: "provider_b")

        // When
        store.autoSwitchIfNeeded()

        // Then: still empty — no selection to auto-switch
        XCTAssertTrue(store.selectedProviderIds.isEmpty)
    }

    func test_autoSwitch_doesNotSwitch_whenAConfiguredProviderIsAlreadySelected() {
        let store = makeStore()
        store.start()
        defer { store.stop() }

        // Given: both provider_a and provider_b are selected
        store.addToSelection("provider_b")
        XCTAssertEqual(store.selectedProviderIds, ["provider_a", "provider_b"])

        // provider_a is unconfigured but provider_b has data
        store.providerErrors["provider_a"] = UsageStore.notConfiguredError
        installReport(store, id: "provider_b")

        // When: at least one selected provider (provider_b) is configured
        store.autoSwitchIfNeeded()

        // Then: no switch needed
        XCTAssertEqual(store.selectedProviderIds, ["provider_a", "provider_b"])
    }

    func test_autoSwitch_switchesToFirstWithData_inProviderOrder() {
        let store = makeStore(ids: ["provider_c", "provider_b", "provider_a"])

        // Given: provider_a is selected but unconfigured
        store.selectOnly("provider_a")
        store.providerErrors["provider_a"] = UsageStore.notConfiguredError

        // And: both provider_b and provider_c have data
        installReport(store, id: "provider_c")
        installReport(store, id: "provider_b")

        // When: provider_c comes first in providerOrder
        store.autoSwitchIfNeeded()

        // Then: switches to provider_c (first in order with data)
        XCTAssertEqual(store.selectedProviderIds, ["provider_c"])
    }

    // MARK: - Ball state (expired / error precedence)

    func test_ballState_expiredPlanWithFetchError_prefersError() {
        let store = makeStore()
        store.selectOnly("provider_a")
        installReport(store, id: "provider_a", planExpired: true)

        // When: fetch fails (e.g. cookie expired -> 401) while plan is expired
        store.providerErrors["provider_a"] = "Auth failed (check key)"

        // Then: transient error wins over the persistent expired state
        XCTAssertEqual(store.ballState(for: "provider_a"), .error)
    }

    func test_ballState_expiredPlanShowsExpired_whenNoError() {
        let store = makeStore()
        store.selectOnly("provider_a")
        installReport(store, id: "provider_a", planExpired: true)

        // When: fetch succeeded but the plan itself is expired
        // Then: ball reads as expired (dimmed)
        XCTAssertEqual(store.ballState(for: "provider_a"), .expired)
    }

    // MARK: - Helpers

    /// Create a UsageStore with N mock providers.
    /// If `ids` is provided, uses those ids in that order; otherwise defaults to
    /// ["provider_a", "provider_b"].
    private func makeStore(ids: [String] = ["provider_a", "provider_b"]) -> UsageStore {
        let providers = ids.map { MockProvider(id: $0) }
        let storage = InMemorySelectionStorage()
        return UsageStore(providers: providers, preferences: storage)
    }

    /// Install a minimal report for a provider (no windowed quotas, so the ball is idle).
    private func installReport(_ store: UsageStore, id: String, planExpired: Bool? = nil) {
        let report = ProviderReport(
            providerId: id,
            fetchedAt: Date(),
            quotas: [
                Quota(id: "\(id).balance", type: .balance, label: "Balance", unit: .cny, remaining: 100)
            ],
            balance: BalanceInfo(currency: "CNY", total: 100, granted: 0, toppedUp: 100),
            planExpired: planExpired
        )
        store.installDemoReport(report)
    }

    // MARK: - Custom metrics hot reload

    /// reloadCustomMetrics hot-reloads after settings-panel save/delete:
    /// new ones register and join the ordered list, deleted ones are removed (incl. selection cleanup).
    func test_reloadCustomMetrics_registersAndRemovesProviders() throws {
        // Arrange: point CredentialStore at a temp config.json (avoid touching the real ~/.trwy/config.json)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trwy-reload-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tempURL = dir.appendingPathComponent("config.json")
        let originalDefaultURL = CredentialStore.defaultURL
        CredentialStore.defaultURL = tempURL
        defer { CredentialStore.defaultURL = originalDefaultURL }

        let store = makeStore(ids: ["provider_a"])
        store.start()
        defer { store.stop() }

        let config = CustomMetricConfig(id: "custom-1", name: "预算",
                                        baseURL: "http://prom:9090", metric: "usage")
        try CustomMetricConfigStore.upsert(config, to: tempURL)

        // Act: save, then hot-reload
        store.reloadCustomMetrics()

        // Assert: the custom provider is registered after the built-ins
        XCTAssertTrue(store.knownProviderIds.contains("custom-1"))
        XCTAssertEqual(store.knownProviderIds.last, "custom-1")

        // Deleted, then hot-reloaded: provider is gone
        try CustomMetricConfigStore.remove(id: "custom-1", from: tempURL)
        store.reloadCustomMetrics()
        XCTAssertFalse(store.knownProviderIds.contains("custom-1"))
    }

    /// Editing and saving must replace the provider instance (displayName etc. apply immediately, no restart)
    func test_reloadCustomMetrics_replacesEditedProviderInstance() throws {
        // Arrange: redirect config to a temp file
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trwy-reload-edit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tempURL = dir.appendingPathComponent("config.json")
        let originalDefaultURL = CredentialStore.defaultURL
        CredentialStore.defaultURL = tempURL
        defer { CredentialStore.defaultURL = originalDefaultURL }

        let store = makeStore(ids: ["provider_a"])
        store.start()
        defer { store.stop() }

        // Save (old name) → hot-reload
        try CustomMetricConfigStore.upsert(
            CustomMetricConfig(id: "custom-1", name: "旧名", baseURL: "u", metric: "m"), to: tempURL)
        store.reloadCustomMetrics()
        XCTAssertEqual(store.providerDisplayName(for: "custom-1"), "旧名")

        // Edit (new name) → hot-reload: displayName updates immediately
        try CustomMetricConfigStore.upsert(
            CustomMetricConfig(id: "custom-1", name: "新名", baseURL: "u", metric: "m"), to: tempURL)
        store.reloadCustomMetrics()
        XCTAssertEqual(store.providerDisplayName(for: "custom-1"), "新名")
    }

    /// Deleting a custom metric must persist the cache, or ghost reports resurrect from cache.json on restart
    func test_reloadCustomMetrics_deletedProviderNotResurrectedFromCache() throws {
        // Arrange: redirect config + cache to temp files
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trwy-reload-cache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config.json")
        let cacheURL = dir.appendingPathComponent("cache.json")
        let originalConfigURL = CredentialStore.defaultURL
        let originalCacheURL = CacheStore.defaultURL
        CredentialStore.defaultURL = configURL
        CacheStore.defaultURL = cacheURL
        defer {
            CredentialStore.defaultURL = originalConfigURL
            CacheStore.defaultURL = originalCacheURL
        }

        let store = makeStore(ids: ["provider_a"])
        store.start()
        defer { store.stop() }

        // A report already exists (simulating a successful fetch)
        try CustomMetricConfigStore.upsert(
            CustomMetricConfig(id: "custom-1", name: "预算", baseURL: "u", metric: "m"), to: configURL)
        store.reloadCustomMetrics()
        installReport(store, id: "custom-1")
        store.refreshIfStale()   // no-op; we don't depend on it — assert the cache directly

        // Act: delete → hot-reload
        try CustomMetricConfigStore.remove(id: "custom-1", from: configURL)
        store.reloadCustomMetrics()

        // Assert: cache persisted and free of the deleted provider (no resurrection on restart)
        let cache = CacheStore.load(from: cacheURL)
        XCTAssertFalse(cache?.reports.contains { $0.providerId == "custom-1" } ?? true)
        XCTAssertTrue(store.reports.allSatisfy { $0.providerId != "custom-1" })
    }

    // MARK: - used-semantics ball shapes

    /// used + max: water = used proportion (full = drained), center = usage value, sub = used percent
    func test_ballModel_usedSemanticsWithMax() {
        // Arrange
        let store = makeStore(ids: ["provider_a"])
        let report = ProviderReport(providerId: "provider_a", fetchedAt: Date(), quotas: [
            Quota(id: "provider_a.main", type: .timeWindowed, label: "用量",
                  unit: .tokens, used: 80, limit: 100, showsUsedLevel: true)
        ])
        store.installDemoReport(report)

        // Act
        let model = store.ballModel(for: "provider_a")

        // Assert: water = 80% (used direction), center = value 80, sub = 80%
        XCTAssertEqual(model.coreLevel ?? -1, 0.8, accuracy: 1e-9)
        XCTAssertEqual(model.centerText, "80")
        XCTAssertEqual(model.subText, "80%")
    }

    /// used without max: no water (coreLevel nil), center = usage value, sub = unit abbreviation
    func test_ballModel_usedSemanticsWithoutMax() {
        // Arrange
        let store = makeStore(ids: ["provider_a"])
        let report = ProviderReport(providerId: "provider_a", fetchedAt: Date(), quotas: [
            Quota(id: "provider_a.main", type: .timeWindowed, label: "用量",
                  unit: .cny, used: 880.25, showsUsedLevel: true)
        ])
        store.installDemoReport(report)

        // Act
        let model = store.ballModel(for: "provider_a")

        // Assert: no water, center = 880.2 (one decimal), sub = ¥
        XCTAssertNil(model.coreLevel)
        XCTAssertEqual(model.centerText, "880.2")
        XCTAssertEqual(model.subText, "¥")
    }

    /// remaining + max: water = remaining/max (full = healthy), center = remaining percent
    func test_ballModel_remainingWithMaxShowsRemainingLevel() {
        // Arrange: remaining=4321, limit=10000 → 43.21% left
        let store = makeStore(ids: ["provider_a"])
        let report = ProviderReport(providerId: "provider_a", fetchedAt: Date(), quotas: [
            Quota(id: "provider_a.main", type: .timeWindowed, label: "预算",
                  unit: .cny, limit: 10000, remaining: 4321)
        ])
        store.installDemoReport(report)

        // Act
        let model = store.ballModel(for: "provider_a")

        // Assert: water = 43.2% remaining, center = 43%
        XCTAssertEqual(model.coreLevel ?? -1, 4321.0 / 10000, accuracy: 1e-9)
        XCTAssertEqual(model.centerText, "43%")
    }

    /// Default semantics (showsUsedLevel=false) keeps original behavior: water = remaining, center = remaining percent
    func test_ballModel_remainingSemanticsKeepsOriginalBehavior() {
        // Arrange
        let store = makeStore(ids: ["provider_a"])
        let report = ProviderReport(providerId: "provider_a", fetchedAt: Date(), quotas: [
            Quota(id: "provider_a.main", type: .timeWindowed, label: "额度",
                  unit: .tokens, used: 80, limit: 100)
        ])
        store.installDemoReport(report)

        // Act
        let model = store.ballModel(for: "provider_a")

        // Assert: water = 20% remaining, center = 20%
        XCTAssertEqual(model.coreLevel ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(model.centerText, "20%")
    }

    /// loadCache at startup must filter providers that no longer exist (stale cache after manual config removal)
    func test_loadCache_filtersGhostProviders() throws {
        // Arrange: temp cache.json holds a ghost provider + a normal provider
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trwy-ghost-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cacheURL = dir.appendingPathComponent("cache.json")
        let originalCacheURL = CacheStore.defaultURL
        CacheStore.defaultURL = cacheURL
        defer { CacheStore.defaultURL = originalCacheURL }

        let ghost = ProviderReport(providerId: "custom-ghost", fetchedAt: Date(), quotas: [])
        CacheStore.save(TokenRunwayCache(reports: [ghost], forecast: ForecastEngine()), to: cacheURL)

        // Act: start (providers contains only provider_a, no custom-ghost)
        let store = makeStore(ids: ["provider_a"])
        store.start()
        defer { store.stop() }

        // Assert: the ghost report is filtered out
        XCTAssertFalse(store.reports.contains { $0.providerId == "custom-ghost" })
    }
}

// MARK: - Mocks

/// A minimal Provider that returns a fixed report.
private struct MockProvider: Provider {
    let manifest: ProviderManifest

    init(id: String) {
        manifest = ProviderManifest(
            id: id,
            displayName: id,
            authMode: .bearer,
            defaultPollInterval: 300,
            shortName: String(id.prefix(2)),
            envPrefixOverride: id.uppercased()
        )
    }

    var supportedQuotaTypes: [QuotaType] { [.balance] }

    func fetchUsage(credential: Credential) async throws -> ProviderReport {
        throw ProviderError.unknown(999)
    }
}

/// In-memory selection storage for tests.
private final class InMemorySelectionStorage: SelectionStorage {
    private var ids: [String] = []
    func loadSelectedIds() -> [String] { ids }
    func saveSelectedIds(_ ids: [String]) { self.ids = ids }
}