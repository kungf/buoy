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
