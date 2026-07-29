import XCTest
@testable import BuoyApp

/// Selection-state pure-logic tests (immutability, order preservation, unknown filtering, persistence round-trip).
final class SelectionStateTests: XCTestCase {

    private let order = ["volcano", "deepseek", "mimo"]

    // MARK: Default selection

    func test_defaultSelection_picksFirstProvider() {
        let state = SelectionState.defaultSelection(providerOrder: order)
        XCTAssertEqual(state.selectedIds, ["volcano"])
    }

    func test_defaultSelection_emptyOrderReturnsEmpty() {
        let state = SelectionState.defaultSelection(providerOrder: [])
        XCTAssertTrue(state.selectedIds.isEmpty)
    }

    // MARK: toggle

    func test_toggle_addsWhenAbsent_preservingOrder() {
        let state = SelectionState(selectedIds: ["volcano"], providerOrder: order)
        XCTAssertEqual(state.toggling("deepseek").selectedIds, ["volcano", "deepseek"])
    }

    func test_toggle_removesWhenPresent_preservingOrder() {
        let state = SelectionState(selectedIds: ["volcano", "deepseek"], providerOrder: order)
        XCTAssertEqual(state.toggling("volcano").selectedIds, ["deepseek"])
    }

    func test_toggle_doesNotMutateOriginal() {
        let state = SelectionState(selectedIds: ["volcano"], providerOrder: order)
        _ = state.toggling("deepseek")
        XCTAssertEqual(state.selectedIds, ["volcano"], "SelectionState must be immutable: original unchanged")
    }

    // MARK: add (breakthrough: append only, no duplicate)

    func test_add_appendsWhenAbsent() {
        let state = SelectionState(selectedIds: ["volcano"], providerOrder: order)
        XCTAssertEqual(state.adding("deepseek").selectedIds, ["volcano", "deepseek"])
    }

    func test_add_noOpWhenPresent() {
        let state = SelectionState(selectedIds: ["volcano", "deepseek"], providerOrder: order)
        XCTAssertEqual(state.adding("volcano").selectedIds, ["volcano", "deepseek"])
    }

    // MARK: selectOnly

    func test_selectingOnly_replacesWithSingle() {
        let state = SelectionState(selectedIds: ["volcano", "deepseek"], providerOrder: order)
        XCTAssertEqual(state.selectingOnly("mimo").selectedIds, ["mimo"])
    }

    // MARK: Filter unknown providers

    func test_sanitized_dropsUnknownIds_preservingOrder() {
        let state = SelectionState(selectedIds: ["volcano", "ghost", "deepseek"], providerOrder: order)
        XCTAssertEqual(state.sanitized(keepingValid: Set(order)).selectedIds, ["volcano", "deepseek"])
    }

    // MARK: Persistence round-trip

    func test_persistence_roundTrip() {
        let storage = InMemorySelectionStorage()
        var state = SelectionState.defaultSelection(providerOrder: order)
        state = state.toggling("deepseek")
        storage.saveSelectedIds(state.selectedIds)

        let loaded = SelectionState(selectedIds: storage.loadSelectedIds(), providerOrder: order)
            .sanitized(keepingValid: Set(order))
        XCTAssertEqual(loaded.selectedIds, ["volcano", "deepseek"])
    }

    func test_persistence_emptyFallsBackToDefault() {
        let storage = InMemorySelectionStorage()
        let raw = SelectionState(selectedIds: storage.loadSelectedIds(), providerOrder: order)
            .sanitized(keepingValid: Set(order))
        let resolved = raw.selectedIds.isEmpty
            ? SelectionState.defaultSelection(providerOrder: order)
            : raw
        XCTAssertEqual(resolved.selectedIds, ["volcano"])
    }
}

/// In-memory storage for tests (isolates UserDefaults).
private final class InMemorySelectionStorage: SelectionStorage {
    private var ids: [String] = []
    func loadSelectedIds() -> [String] { ids }
    func saveSelectedIds(_ ids: [String]) { self.ids = ids }
}
