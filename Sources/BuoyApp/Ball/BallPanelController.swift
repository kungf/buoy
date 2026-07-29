import AppKit
import SwiftUI
import Combine
import BuoyCore

/// 浮标球窗口控制器：悬浮 NSPanel + 手势
/// （拖动/边缘吸附/单击/双击/滚轮/hover popover/右键菜单/穿透/徽标点击，DESIGN.md §8.5）。
@MainActor
final class BallPanelController: NSObject {
    private let store: UsageStore
    private let onOpenDashboard: () -> Void
    private let onOpenDetail: () -> Void
    private let panel: NSPanel
    private var hoverPopover: NSPopover?
    private var clickThroughCancellable: AnyCancellable?
    /// 球是否被「隐藏」收起（右键隐藏后，菜单栏是唯一的恢复入口）。
    private(set) var isBallHidden = false

    init(store: UsageStore,
         onOpenDashboard: @escaping () -> Void,
         onOpenDetail: @escaping () -> Void) {
        self.store = store
        self.onOpenDashboard = onOpenDashboard
        self.onOpenDetail = onOpenDetail

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
        super.init()

        let rootView = BallRootView(store: store)
        let eventView = BallEventView(rootView: rootView)
        panel.contentView = eventView

        eventView.onClick = { [weak self] in
            self?.hidePopover()
            self?.onOpenDashboard()
        }
        eventView.onDoubleClick = { [weak self] in
            self?.hidePopover()
            self?.onOpenDetail()
        }
        eventView.onDragEnd = { [weak self] in self?.snapToNearestEdge() }
        eventView.onScroll = { [weak self] forward in
            self?.store.cycleCoreWindow(forward: forward)
        }
        eventView.onHover = { [weak self] inside in
            guard let self else { return }
            inside ? self.showPopover() : self.hidePopover()
        }
        eventView.badgeProvider = { [weak store] in
            store?.ballModel.alertBadges.map(\.id) ?? []
        }
        eventView.onBadgeTap = { [weak self] id in
            self?.store.pinDisplay(to: id) // 徽标点击：切到该 provider（DESIGN.md §8.1）
        }
        eventView.menuProvider = { [weak self] in self?.buildMenu() }

        moveToInitialPosition()
        observeClickThrough()
    }

    func show() {
        panel.orderFrontRegardless()
        isBallHidden = false
    }

    /// 收起球（右键「隐藏球」/ 菜单栏「隐藏球」）。菜单栏可重新 show。
    func hide() {
        panel.orderOut(nil)
        isBallHidden = true
    }

    // MARK: - 位置 / 吸附

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

    // MARK: - 穿透模式（DESIGN.md §8.5：开启时鼠标穿透，仅 ambient；菜单栏/右键可关）

    private func observeClickThrough() {
        panel.ignoresMouseEvents = store.clickThrough
        clickThroughCancellable = store.$clickThrough
            .sink { [weak self] on in self?.panel.ignoresMouseEvents = on }
    }

    // MARK: - Hover popover

    private func showPopover() {
        guard !store.clickThrough, let contentView = panel.contentView else { return }
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

    // MARK: - 右键菜单（DESIGN.md §8.5）

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem("刷新", action: #selector(refreshAction)))
        let pause = makeItem(store.pollingPaused ? "继续轮询" : "暂停轮询", action: #selector(togglePauseAction))
        pause.state = store.pollingPaused ? .on : .off
        menu.addItem(pause)
        let through = makeItem("穿透模式", action: #selector(toggleClickThroughAction))
        through.state = store.clickThrough ? .on : .off
        menu.addItem(through)
        menu.addItem(.separator())
        menu.addItem(makeItem("打开总面板", action: #selector(openDashboardAction)))
        menu.addItem(makeItem("打开详情", action: #selector(openDetailAction)))
        menu.addItem(.separator())
        menu.addItem(makeItem("隐藏球", action: #selector(hideAction)))
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
    @objc private func openDetailAction() { onOpenDetail() }
    @objc private func hideAction() { hide() }
}

/// 球的 SwiftUI 根视图：桥接 store 数据到 BallView（DESIGN.md §8.1 换脸过渡）。
private struct BallRootView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        ZStack {
            BallView(model: store.ballModel)
                .id(store.displayProviderId) // 换脸：identity 变化触发 transition
                .transition(.opacity.combined(with: .scale))
        }
        .animation(.easeInOut(duration: 0.35), value: store.displayProviderId)
        .background(Circle().fill(.black.opacity(0.35)).blur(radius: 4))
    }
}

/// 事件层：拖动 / 单击 / 双击 / 滚轮 / hover / 右键 / 徽标命中（DESIGN.md §8.5）。
private final class BallEventView<Content: View>: NSHostingView<Content> {
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
    /// 单击延迟：等待可能的第二次点击以区分双击（DESIGN.md §8.5 单击=总面板 / 双击=详情）
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
        // 徽标命中优先于单击/双击（DESIGN.md §8.1 点击徽章切 provider）
        if let badgeId = hitBadge(event) {
            onBadgeTap(badgeId)
            return
        }
        if event.clickCount >= 2 {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
            onDoubleClick()
        } else {
            // 延迟触发单击；若 250ms 内来到第二次点击则取消并走双击
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

    /// 徽标命中测试：用 BadgeLayout 的固定极坐标 + 当前徽标列表（DESIGN.md §8.1）。
    private func hitBadge(_ event: NSEvent) -> String? {
        let ids = badgeProvider()
        guard !ids.isEmpty else { return nil }
        let positions = BadgeLayout.positions(count: ids.count, ballSize: bounds.width)
        let p = convert(event.locationInWindow, from: nil)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let hitRadius = BadgeLayout.dotDiameter / 2 + 3 // 容差
        for (i, pos) in positions.enumerated() where i < ids.count {
            let bx = center.x + pos.x
            // NSHostingView isFlipped=true（原点左上），与 SwiftUI .position 一致：y 上为负
            let by = isFlipped ? (center.y - pos.y) : (center.y + pos.y)
            if hypot(Double(p.x - bx), Double(p.y - by)) <= Double(hitRadius) {
                return ids[i]
            }
        }
        return nil
    }
}
