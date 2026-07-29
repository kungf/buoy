import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var ballController: BallPanelController?
    private var dashboardController: DashboardWindowController?
    private var detailController: ProviderDetailWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        ballController = BallPanelController(
            store: store,
            onOpenDashboard: { [weak self] in self?.toggleDashboard() },
            onOpenDetail: { [weak self] id in self?.openDetail(providerId: id) }
        )
        ballController?.show()
        setupStatusItem()
        // 回前台立即刷新一次（DESIGN.md §6）
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func appBecameActive() {
        Task { await store.refresh() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // 常驻后台，球在 App 就在
    }

    // MARK: - 窗口

    private func toggleDashboard() {
        if dashboardController == nil {
            dashboardController = DashboardWindowController(store: store)
        }
        dashboardController?.toggle()
    }

    /// 双击球：打开该 provider 的详情面板（DESIGN.md §8.5）
    private func openDetail(providerId: String) {
        detailController = ProviderDetailWindowController(store: store, providerId: providerId)
        detailController?.show()
    }

    // MARK: - 菜单栏（穿透模式退出阀；Phase 6.2 会扩展为完整菜单）

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "Buoy")
        }
        let menu = buildStatusMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem("打开总面板", action: #selector(openDashboardAction)))
        let ballTitle = (ballController?.isBallHidden == true) ? "显示球" : "隐藏球"
        menu.addItem(makeItem(ballTitle, action: #selector(toggleBallAction)))
        let through = makeItem(store.clickThrough ? "退出穿透模式" : "穿透模式",
                               action: #selector(toggleClickThroughAction))
        through.state = store.clickThrough ? .on : .off
        menu.addItem(through)
        menu.addItem(.separator())
        menu.addItem(makeItem("退出 Buoy", action: #selector(quitAction)))
        return menu
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openDashboardAction() { toggleDashboard() }
    @objc private func toggleBallAction() {
        guard let ball = ballController else { return }
        ball.isBallHidden ? ball.show() : ball.hide()
    }
    @objc private func toggleClickThroughAction() { store.clickThrough.toggle() }
    @objc private func quitAction() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // 刷新穿透模式勾选态（球在穿透模式下无法右键，菜单栏是唯一退出阀）
        menu.removeAllItems()
        for item in buildStatusMenu().items { menu.addItem(item) }
    }
}
