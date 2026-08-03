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