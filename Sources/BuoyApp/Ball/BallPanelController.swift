import AppKit
import Combine

/// Coordinates the independent floating balls: one `BallWindowController` (one NSPanel) per selected
/// provider. Balls are NOT bound into a cluster -- each is freely draggable and remembers its own
/// position. Default arrangement is a vertical stack at the top-right of the screen. The first
/// (primary) ball carries the breakthrough badges for non-selected alerting providers.
@MainActor
final class BallPanelController: NSObject {
    private let store: UsageStore
    private let onOpenDashboard: () -> Void
    private let onOpenDetail: (String) -> Void
    private let positionStorage: BallPositionStorage
    private var controllers: [String: BallWindowController] = [:]
    private var selectionCancellable: AnyCancellable?
    private var clickThroughCancellable: AnyCancellable?
    /// Whether all balls are hidden (status-bar / right-click "hide ball" toggles this).
    private(set) var isBallHidden = false

    init(store: UsageStore,
         onOpenDashboard: @escaping () -> Void,
         onOpenDetail: @escaping (String) -> Void,
         positionStorage: BallPositionStorage = Preferences()) {
        self.store = store
        self.onOpenDashboard = onOpenDashboard
        self.onOpenDetail = onOpenDetail
        self.positionStorage = positionStorage
        super.init()
        observeClickThrough()
        observeSelection()
    }

    func show() {
        controllers.values.forEach { $0.show() }
        isBallHidden = false
    }

    /// Hide all balls (right-click "hide ball" on any ball, or status-bar "hide ball").
    /// The status bar is the only way back (DESIGN.md §8.5).
    func hide() {
        controllers.values.forEach { $0.hide() }
        isBallHidden = true
    }

    // MARK: Selection sync

    private func observeSelection() {
        selectionCancellable = store.$selectedProviderIds
            .sink { [weak self] ids in self?.syncControllers(for: ids) }
    }

    /// Diff the live controllers against the selection: remove balls for providers no longer
    /// selected, create balls for newly selected providers. Existing balls keep their positions.
    private func syncControllers(for ids: [String]) {
        for (id, controller) in controllers where !ids.contains(id) {
            controller.hide()
            controllers.removeValue(forKey: id)
        }
        for id in ids where controllers[id] == nil {
            let origin = resolveOrigin(for: id, count: ids.count)
            let controller = BallWindowController(
                providerId: id,
                store: store,
                origin: origin,
                onOpenDashboard: onOpenDashboard,
                onOpenDetail: onOpenDetail,
                onHideAll: { [weak self] in self?.hide() },
                onPositionChange: { [weak self] pid, point in self?.persist(origin: point, for: pid) }
            )
            controllers[id] = controller
            if !isBallHidden { controller.show() }
        }
    }

    // MARK: Position

    /// Restore a persisted position (clamped on screen), else the first default vertical-stack slot
    /// that does not overlap an existing ball (so a re-added ball is not stacked on a kept one).
    private func resolveOrigin(for id: String, count: Int) -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let ballSize = Theme.canvasSize
        if let stored = positionStorage.loadOrigin(for: id) {
            return BallLayout.clamped(stored, ballSize: ballSize, in: screen, margin: Theme.screenMargin)
        }
        let occupied = controllers.values.map { $0.currentOrigin }
        let origin = BallLayout.firstNonOverlappingDefault(count: count, in: screen,
                                                           ballSize: ballSize,
                                                           spacing: Theme.ballSpacing,
                                                           margin: Theme.screenMargin,
                                                           avoiding: occupied)
        return BallLayout.clamped(origin, ballSize: ballSize, in: screen, margin: Theme.screenMargin)
    }

    private func persist(origin: NSPoint, for id: String) {
        positionStorage.saveOrigin(origin, for: id)
    }

    // MARK: Click-through

    private func observeClickThrough() {
        applyClickThrough(store.clickThrough)
        clickThroughCancellable = store.$clickThrough
            .sink { [weak self] on in self?.applyClickThrough(on) }
    }

    private func applyClickThrough(_ on: Bool) {
        controllers.values.forEach { $0.setClickThrough(on) }
    }
}
