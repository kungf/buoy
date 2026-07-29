import AppKit
import SwiftUI

/// 浮标球窗口控制器：悬浮 NSPanel + 手势（拖动/边缘吸附/点击/滚轮/hover popover，DESIGN.md §8.5）。
@MainActor
final class BallPanelController {
    private let store: UsageStore
    private let onOpenDashboard: () -> Void
    private let panel: NSPanel
    private var hoverPopover: NSPopover?

    init(store: UsageStore, onOpenDashboard: @escaping () -> Void) {
        self.store = store
        self.onOpenDashboard = onOpenDashboard

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Theme.ballSize, height: Theme.ballSize),
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
        self.panel = panel

        let rootView = BallRootView(store: store)
        let eventView = BallEventView(rootView: rootView)
        panel.contentView = eventView

        eventView.onClick = { [weak self] in
            self?.hidePopover()
            onOpenDashboard()
        }
        eventView.onDragEnd = { [weak self] in self?.snapToNearestEdge() }
        eventView.onScroll = { [weak self] forward in
            self?.store.cycleCoreWindow(forward: forward)
        }
        eventView.onHover = { [weak self] inside in
            guard let self else { return }
            inside ? self.showPopover() : self.hidePopover()
        }

        moveToInitialPosition()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    /// 初始位置：主屏右上角
    private func moveToInitialPosition() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let origin = NSPoint(
            x: screen.maxX - Theme.ballSize - Theme.screenMargin,
            y: screen.maxY - Theme.ballSize - Theme.screenMargin - 24
        )
        panel.setFrameOrigin(origin)
    }

    /// 拖动结束：吸附到所在屏幕最近的水平边缘（DESIGN.md §8.5）
    private func snapToNearestEdge() {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
                ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        let centerX = frame.midX
        let snapLeft = abs(centerX - visible.minX) < abs(centerX - visible.maxX)
        frame.origin.x = snapLeft
            ? visible.minX + Theme.screenMargin
            : visible.maxX - frame.width - Theme.screenMargin
        frame.origin.y = min(max(frame.origin.y, visible.minY + Theme.screenMargin),
                             visible.maxY - frame.height - Theme.screenMargin)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    // MARK: - Hover popover

    private func showPopover() {
        guard let contentView = panel.contentView else { return }
        let popover = hoverPopover ?? NSPopover()
        popover.behavior = .semitransient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: HoverSummaryView(store: store))
        hoverPopover = popover
        guard popover.isShown == false else { return }
        popover.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minX)
    }

    private func hidePopover() {
        hoverPopover?.close()
    }
}

/// 球的 SwiftUI 根视图：桥接 store 数据到 BallView。
private struct BallRootView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        BallView(
            ringRemaining: store.ringQuota?.percentUsed.map { 1 - $0 },
            coreRemaining: store.coreQuota?.percentUsed.map { 1 - $0 },
            health: store.displayHealth,
            coreLabel: shortLabel(store.coreQuota?.id ?? ""),
            hasError: store.displayError != nil && store.displayReport == nil,
            showAlertBadge: store.hasHiddenProviderAlert,
            breathUrgency: breathUrgency(from: store.coreEta),
            isStale: store.displayIsStale
        )
        .background(Circle().fill(.black.opacity(0.35)).blur(radius: 4))
    }

    private func shortLabel(_ id: String) -> String {
        guard let suffix = id.split(separator: ".").last else { return "" }
        return String(suffix)
    }

    /// ETA -> 呼吸紧迫度：<5min=1.0（急促），>2h=0（平静），之间线性（DESIGN.md §8.4）。
    private func breathUrgency(from eta: TimeInterval?) -> Double {
        guard let eta else { return 0 }
        let hours = eta / 3600
        return min(max(1 - hours / 2, 0), 1)
    }
}

/// 事件层：拖动移动窗口 / 点击 / 滚轮 / hover。
private final class BallEventView<Content: View>: NSHostingView<Content> {
    var onClick: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onScroll: (Bool) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }

    private var dragStartMouse: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero
    private var didDrag = false
    private var scrollAccumulator: CGFloat = 0
    private let clickSlop: CGFloat = 4
    private let scrollThreshold: CGFloat = 12

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
        } else {
            onClick() // 单击与双击 M0 均打开总面板；双击详情在 M1 细分（DESIGN.md §8.5）
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scrollAccumulator += event.scrollingDeltaY
        if abs(scrollAccumulator) >= scrollThreshold {
            onScroll(scrollAccumulator > 0)
            scrollAccumulator = 0
        }
    }
}
