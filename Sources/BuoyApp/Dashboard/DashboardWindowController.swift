import AppKit
import SwiftUI

/// 总面板窗口（M0：普通 NSWindow；pin/NSPanel 形态在 M1 做，DESIGN.md §8.2）。
@MainActor
final class DashboardWindowController {
    private let window: NSWindow

    init(store: UsageStore) {
        let hosting = NSHostingController(rootView: DashboardView(store: store))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Buoy 总面板"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
    }

    func toggle() {
        if window.isVisible {
            window.close()
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
