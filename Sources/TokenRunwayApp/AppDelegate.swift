import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var ballController: BallPanelController?
    private var dashboardController: DashboardWindowController?
    private var detailController: ProviderDetailWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
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
        // Also refresh when the Mac wakes from sleep. Swift Tasks are frozen
        // during long sleeps, so even after they resume they may have missed a
        // window reset — refetch immediately instead of showing yesterday's data.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func appBecameActive() {
        Task { await store.refresh() }
    }

    @objc private func systemDidWake() {
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

    // MARK: - 菜单栏

    /// Minimal main menu with an Edit menu so Cmd+V / Cmd+C / Cmd+A work in text fields.
    /// LSUIElement apps do not get a default menu bar — without this, standard clipboard
    /// shortcuts have no `paste:` / `copy:` / `selectAll:` responder.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // --- App menu ---
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit TokenRunway",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // --- Edit menu (enables Cmd+V / Cmd+C / Cmd+X / Cmd+A / Cmd+Z) ---
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    /// 菜单栏图标（穿透模式退出阀；Phase 6.2 会扩展为完整菜单）
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "TokenRunway")
        }
        let menu = buildStatusMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem("Dashboard", action: #selector(openDashboardAction)))
        let ballTitle = (ballController?.isBallHidden == true) ? "Show ball" : "Hide ball"
        menu.addItem(makeItem(ballTitle, action: #selector(toggleBallAction)))
        let through = makeItem(store.clickThrough ? "Disable click-through" : "Click-through",
                               action: #selector(toggleClickThroughAction))
        through.state = store.clickThrough ? .on : .off
        menu.addItem(through)
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit TokenRunway", action: #selector(quitAction)))
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
