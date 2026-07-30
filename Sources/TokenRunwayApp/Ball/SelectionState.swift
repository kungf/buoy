import Foundation

/// Ball display selection state (pure value, immutable; DESIGN.md §8.1 multi-select ball cluster).
/// `selectedIds` is ordered and de-duplicated; `providerOrder` gives a stable order for "the first
/// ball" and for cluster arrangement. All transforms return a new value, leaving the original
/// untouched (immutable pattern, CLAUDE.md coding style).
struct SelectionState: Equatable {
    var selectedIds: [String]
    let providerOrder: [String]

    /// Toggle a provider's selection: remove if present, append if absent (order-preserving, dedup).
    func toggling(_ id: String) -> SelectionState {
        if selectedIds.contains(id) {
            return SelectionState(selectedIds: selectedIds.filter { $0 != id },
                                  providerOrder: providerOrder)
        }
        return SelectionState(selectedIds: selectedIds + [id], providerOrder: providerOrder)
    }

    /// Append only when absent (breakthrough badge: add an alerting provider to the cluster,
    /// no duplicate, no replacement).
    func adding(_ id: String) -> SelectionState {
        guard !selectedIds.contains(id) else { return self }
        return SelectionState(selectedIds: selectedIds + [id], providerOrder: providerOrder)
    }

    /// Select only one provider (replace).
    func selectingOnly(_ id: String) -> SelectionState {
        SelectionState(selectedIds: [id], providerOrder: providerOrder)
    }

    /// Drop ids not in the valid set (order-preserving). Used at launch to discard uninstalled providers.
    func sanitized(keepingValid valid: Set<String>) -> SelectionState {
        SelectionState(selectedIds: selectedIds.filter { valid.contains($0) },
                       providerOrder: providerOrder)
    }

    /// Default selection: the first entry of `providerOrder` (empty if none). First launch = only the
    /// first provider (per product requirement).
    static func defaultSelection(providerOrder: [String]) -> SelectionState {
        SelectionState(selectedIds: Array(providerOrder.prefix(1)), providerOrder: providerOrder)
    }
}
