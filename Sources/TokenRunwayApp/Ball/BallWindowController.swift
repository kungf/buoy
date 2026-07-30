import AppKit
import SwiftUI
import Combine
import TokenRunwayCore

/// SwiftUI bridge: observes the store and renders one provider's ball (re-renders on store change).
struct BallContainerView: View {
    @ObservedObject var store: UsageStore
    let providerId: String

    var body: some View {
        BallView(model: store.ballModel(for: providerId), providerId: providerId)
    }
}

/// One independent floating-ball window: a borderless non-activating NSPanel hosting a single ball,
/// with all gestures scoped to that ball (drag / click / double-click / scroll / hover / right-click
/// menu / escape-badge tap). Reports its own position changes so the coordinator can persist them.
@MainActor
final class BallWindowController {
    let providerId: String
    private let store: UsageStore
    private let onOpenDashboard: () -> Void
    private let onOpenDetail: (String) -> Void
    private let onHideAll: () -> Void
    private let onPositionChange: (String, NSPoint) -> Void
    private let panel: NSPanel
    private var hoverPopover: NSPopover?
    private var hoverFrameObserver: NSKeyValueObservation?
    private var popoverCloseToken: (any NSObjectProtocol)?

    init(providerId: String,
         store: UsageStore,
         origin: NSPoint,
         onOpenDashboard: @escaping () -> Void,
         onOpenDetail: @escaping (String) -> Void,
         onHideAll: @escaping () -> Void,
         onPositionChange: @escaping (String, NSPoint) -> Void) {
        self.providerId = providerId
        self.store = store
        self.onOpenDashboard = onOpenDashboard
        self.onOpenDetail = onOpenDetail
        self.onHideAll = onHideAll
        self.onPositionChange = onPositionChange

        let size = Theme.canvasSize
        let panel = NSPanel(
            contentRect: NSRect(x: origin.x, y: origin.y, width: size, height: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = store.clickThrough
        self.panel = panel

        let container = BallContainerView(store: store, providerId: providerId)
        let eventView = BallEventView(rootView: container)
        eventView.autoresizingMask = [.width, .height]
        panel.contentView = eventView

        let pid = providerId
        eventView.onClick = { [weak self] in
            self?.hidePopover()
            self?.onOpenDashboard()
        }
        eventView.onDoubleClick = { [weak self] in
            self?.hidePopover()
            self?.onOpenDetail(pid)
        }
        eventView.onDragEnd = { [weak self] in
            guard let self else { return }
            self.onPositionChange(pid, self.panel.frame.origin)
        }
        eventView.onScroll = { [weak self] forward in
            self?.store.cycleCoreWindow(forward: forward, for: pid)
        }
        eventView.onHover = { [weak self] inside in
            inside ? self?.showPopover() : self?.hidePopover()
        }
        // Badges are drawn only on the primary ball, so hit-test only there (avoids phantom taps).
        eventView.badgeProvider = { [weak self] in
            guard let self, self.providerId == self.store.selectedProviderIds.first else { return [] }
            return self.store.alertBadges.map(\.id)
        }
        eventView.onBadgeTap = { [weak self] id in self?.store.addToSelection(id) }
        eventView.menuProvider = { [weak self] in self?.buildMenu() }
    }

    // MARK: Lifecycle

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    func setClickThrough(_ on: Bool) { panel.ignoresMouseEvents = on }

    /// Current panel origin (top-left), so the coordinator can avoid stacking a new ball on top of it.
    var currentOrigin: NSPoint { panel.frame.origin }

    // MARK: Hover popover

    private func showPopover() {
        guard !store.clickThrough, let contentView = panel.contentView else {
            hidePopover()
            return
        }
        let popover = hoverPopover ?? NSPopover()
        popover.behavior = .semitransient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: HoverSummaryView(store: store, providerId: providerId))
        hoverPopover = popover
        guard popover.isShown == false else { return }
        let ballRect = NSRect(x: Theme.canvasMargin, y: Theme.canvasMargin,
                              width: Theme.ballSize, height: Theme.ballSize)
        popover.show(relativeTo: ballRect, of: contentView, preferredEdge: .minX)
        // NSPopover's internal coordinate conversion is unreliable for
        // non-activating floating panels: the initial placement is correct,
        // but SwiftUI layout updates later trigger a re-anchor that shifts
        // the popover ~100pt left and ~140pt down. Immediately reposition
        // and observe the popover window's frame to correct any drift.
        repositionPopover(popover, contentView: contentView, ballRect: ballRect)
        if let pw = popover.contentViewController?.view.window {
            hoverFrameObserver?.invalidate()
            hoverFrameObserver = pw.observe(\.frame, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.repositionPopover(popover, contentView: contentView, ballRect: ballRect)
                }
            }
            // Invalidate the observer when the popover closes (semitransient closes
            // on click-away, not just via hidePopover).
            popoverCloseToken = NotificationCenter.default.addObserver(
                forName: NSPopover.willCloseNotification, object: popover, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.hoverFrameObserver?.invalidate()
                        self?.hoverFrameObserver = nil
                    }
                }
        }
    }

    /// Correct the popover window's position so it's flush with the ball's
    /// left edge and vertically centered on the ball.
    private func repositionPopover(_ popover: NSPopover, contentView: NSView, ballRect: NSRect) {
        guard let pw = popover.contentViewController?.view.window,
              let screenBallRect = contentView.window?
                .convertToScreen(contentView.convert(ballRect, to: nil)) else { return }
        let expectedX = screenBallRect.minX - pw.frame.width
        let expectedY = screenBallRect.midY - pw.frame.height / 2
        if abs(pw.frame.origin.x - expectedX) > 0.5 || abs(pw.frame.origin.y - expectedY) > 0.5 {
            pw.setFrameOrigin(NSPoint(x: expectedX, y: expectedY))
        }
    }

    private func hidePopover() {
        hoverFrameObserver?.invalidate()
        hoverFrameObserver = nil
        if let token = popoverCloseToken { NotificationCenter.default.removeObserver(token) }
        popoverCloseToken = nil
        hoverPopover?.close()
    }

    // MARK: Right-click menu (per ball)

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem("Refresh", action: #selector(refreshAction)))
        let pause = makeItem(store.pollingPaused ? "Resume polling" : "Pause polling",
                             action: #selector(togglePauseAction))
        pause.state = store.pollingPaused ? .on : .off
        menu.addItem(pause)
        let through = makeItem("Click-through", action: #selector(toggleClickThroughAction))
        through.state = store.clickThrough ? .on : .off
        menu.addItem(through)
        menu.addItem(.separator())
        menu.addItem(makeItem("Open dashboard", action: #selector(openDashboardAction)))
        menu.addItem(makeItem("Open \(providerId) detail", action: #selector(openDetailAction)))
        if store.isSelected(providerId) {
            menu.addItem(makeItem("Remove \(providerId) from ball", action: #selector(removeAction)))
        } else {
            menu.addItem(makeItem("Add \(providerId) to ball", action: #selector(addAction)))
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("Hide ball", action: #selector(hideAction)))
        return menu
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func refreshAction() { Task { await store.refresh() } }
    @objc private func togglePauseAction() { store.pollingPaused.toggle() }
    @objc private func toggleClickThroughAction() { store.clickThrough.toggle() }
    @objc private func openDashboardAction() { onOpenDashboard() }
    @objc private func openDetailAction() { onOpenDetail(providerId) }
    @objc private func removeAction() { store.toggleSelection(providerId) }
    @objc private func addAction() { store.addToSelection(providerId) }
    @objc private func hideAction() { onHideAll() }
}

/// Event layer for a single ball: drag / click / double-click / scroll / hover / right-click /
/// escape-badge tap. One ball per panel, so there is no cross-ball hit-test; badges are centered on
/// the ball (canvas center).
final class BallEventView: NSHostingView<BallContainerView> {
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onScroll: (Bool) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }
    var onBadgeTap: (String) -> Void = { _ in }
    var badgeProvider: () -> [String] = { [] }
    var menuProvider: () -> NSMenu? = { nil }

    private var dragStartMouse: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero
    private var didDrag = false
    private var scrollAccumulator: CGFloat = 0
    private var pendingSingleClick: DispatchWorkItem?
    private let clickSlop: CGFloat = 4
    private let scrollThreshold: CGFloat = 12
    private let singleClickDelay: TimeInterval = 0.25

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        // A new press cancels any pending single-click from the previous tap, so a quick
        // tap-then-drag does not also fire onClick (open dashboard) mid-drag.
        pendingSingleClick?.cancel()
        pendingSingleClick = nil
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        let delta = NSPoint(x: current.x - dragStartMouse.x, y: current.y - dragStartMouse.y)
        if abs(delta.x) > clickSlop || abs(delta.y) > clickSlop { didDrag = true }
        guard didDrag, let window else { return }
        window.setFrameOrigin(NSPoint(x: dragStartOrigin.x + delta.x, y: dragStartOrigin.y + delta.y))
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            onDragEnd()
            return
        }
        // Badge tap takes priority over click / double-click.
        if let badgeId = hitBadge(event) {
            onBadgeTap(badgeId)
            return
        }
        if event.clickCount >= 2 {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
            onDoubleClick()
        } else {
            // Delay single click; cancel if a second click arrives within the window.
            let work = DispatchWorkItem { [weak self] in self?.onClick() }
            pendingSingleClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + singleClickDelay, execute: work)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider() else { return }
        let point = convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: point, in: self)
    }

    override func scrollWheel(with event: NSEvent) {
        scrollAccumulator += event.scrollingDeltaY
        if abs(scrollAccumulator) >= scrollThreshold {
            onScroll(scrollAccumulator > 0)
            scrollAccumulator = 0
        }
    }

    /// Badge hit-test: badges sit on the ball rim, centered on the canvas (ball center).
    private func hitBadge(_ event: NSEvent) -> String? {
        let ids = badgeProvider()
        guard !ids.isEmpty else { return nil }
        let positions = BadgeLayout.positions(count: ids.count, ballSize: Theme.ballSize)
        let p = convert(event.locationInWindow, from: nil)
        let centerX = bounds.width / 2
        let centerY = bounds.height / 2
        let hitRadius = BadgeLayout.dotDiameter / 2 + 3 // tolerance
        for (i, pos) in positions.enumerated() where i < ids.count {
            let bx = centerX + pos.x
            let by = centerY - pos.y // layout y is up; view origin is top-left
            if hypot(Double(p.x - bx), Double(p.y - by)) <= Double(hitRadius) {
                return ids[i]
            }
        }
        return nil
    }
}
