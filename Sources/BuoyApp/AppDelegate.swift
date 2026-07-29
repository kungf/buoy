import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var ballController: BallPanelController?
    private var dashboardController: DashboardWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        ballController = BallPanelController(store: store, onOpenDashboard: { [weak self] in
            self?.toggleDashboard()
        })
        ballController?.show()
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

    private func toggleDashboard() {
        if dashboardController == nil {
            dashboardController = DashboardWindowController(store: store)
        }
        dashboardController?.toggle()
    }
}
