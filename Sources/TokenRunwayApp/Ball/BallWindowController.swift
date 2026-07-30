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
    private var hoverPanel: NSPanel?
    private var hoverCloseMonitor: Any?
    private var hoverExitWorkItem: DispatchWorkItem?

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
            if inside {
                self?.showPopover()
            } else {
                self?.scheduleConditionalHide()
            }
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

    // MARK: Hover panel

    private func showPopover() {
        guard !store.clickThrough, let ballContentView = panel.contentView else {
            hidePopover()
            return
        }

        // Cancel any pending hide from a previous mouse-exit
        hoverExitWorkItem?.cancel()
        hoverExitWorkItem = nil

        guard hoverPanel == nil else { return }

        let hostingController = NSHostingController(
            rootView: HoverSummaryView(store: store, providerId: providerId))
        hostingController.view.layoutSubtreeIfNeeded()
        let fit = hostingController.view.fittingSize
        let pad = Theme.hoverPanelPadding
        let pw = fit.width + pad * 2
        let ph = fit.height + pad * 2

        // --- shadow wrapper (no mask, carries the shadow) ---
        let shadowView = NSView(frame: NSRect(x: 0, y: 0, width: pw, height: ph))
        shadowView.wantsLayer = true
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.15
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -3)
        shadowView.layer?.shadowRadius = 10
        shadowView.layer?.shadowPath = CGPath(
            roundedRect: shadowView.bounds,
            cornerWidth: Theme.hoverPanelCornerRadius,
            cornerHeight: Theme.hoverPanelCornerRadius,
            transform: nil)

        // --- rounded container (clips content) ---
        let container = NSView(frame: shadowView.bounds)
        container.wantsLayer = true
        container.layer?.cornerRadius = Theme.hoverPanelCornerRadius
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.97).cgColor
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.separatorColor
            .withAlphaComponent(0.25).cgColor

        shadowView.addSubview(container)

        hostingController.view.frame = NSRect(
            x: pad, y: pad, width: fit.width, height: fit.height)
        container.addSubview(hostingController.view)

        // --- window ---
        let hp = NSPanel(
            contentRect: shadowView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        hp.isOpaque = false
        hp.backgroundColor = .clear
        hp.level = .floating
        hp.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hp.hidesOnDeactivate = false
        hp.contentView = shadowView
        hoverPanel = hp

        let ballRect = NSRect(x: Theme.canvasMargin, y: Theme.canvasMargin,
                              width: Theme.ballSize, height: Theme.ballSize)

        hp.orderFrontRegardless()
        positionHoverPanel(hp, contentView: ballContentView, ballRect: ballRect)

        // Click-away: close when clicking outside both the hover panel and the ball
        hoverCloseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let hp = self.hoverPanel else { return }
                let mouse = NSEvent.mouseLocation
                if !hp.frame.contains(mouse) && !self.panel.frame.contains(mouse) {
                    self.hidePopover()
                }
            }
            return event
        }
    }

    /// Position the hover panel flush against the ball's left edge, vertically centered.
    private func positionHoverPanel(_ hp: NSPanel, contentView: NSView, ballRect: NSRect) {
        guard let screenBallRect = contentView.window?
            .convertToScreen(contentView.convert(ballRect, to: nil)) else { return }
        let gap: CGFloat = Theme.hoverPanelGap
        let expectedX = screenBallRect.minX - hp.frame.width - gap
        let expectedY = screenBallRect.midY - hp.frame.height / 2
        let expected = NSPoint(x: expectedX, y: expectedY)
        if abs(hp.frame.origin.x - expected.x) > 0.5
            || abs(hp.frame.origin.y - expected.y) > 0.5 {
            hp.setFrameOrigin(expected)
        }
    }

    /// After the mouse leaves the ball, defer hiding briefly so the user can
    /// move the pointer onto the hover panel. If the pointer is still outside
    /// both windows after the delay, close the panel.
    private func scheduleConditionalHide() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, let hp = self.hoverPanel else { return }
            let mouse = NSEvent.mouseLocation
            if !hp.frame.contains(mouse) && !self.panel.frame.contains(mouse) {
                self.hidePopover()
            } else {
                self.scheduleConditionalHide()
            }
        }
        hoverExitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.hoverHideDelay, execute: work)
    }

    private func hidePopover() {
        hoverExitWorkItem?.cancel()
        hoverExitWorkItem = nil
        if let monitor = hoverCloseMonitor { NSEvent.removeMonitor(monitor) }
        hoverCloseMonitor = nil
        hoverPanel?.close()
        hoverPanel = nil
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
