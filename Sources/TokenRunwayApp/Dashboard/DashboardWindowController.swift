import AppKit
import SwiftUI

/// Dashboard window: floating NSPanel with optional pin-to-all-spaces (DESIGN.md §8.2).
@MainActor
final class DashboardWindowController {
    private let panel: NSPanel

    init(store: UsageStore) {
        let hosting = NSHostingController(rootView: AnyView(EmptyView()))
        let panel = NSPanel(contentViewController: hosting)
        panel.title = "TokenRunway"
        panel.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.center()
        self.panel = panel
        hosting.rootView = AnyView(DashboardView(
            store: store,
            onTogglePin: { [weak self] pinned in self?.setPinned(pinned) }
        ))
    }

    func setPinned(_ pinned: Bool) {
        panel.level = pinned ? .statusBar : .floating
        panel.collectionBehavior = pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.canJoinAllSpaces]
    }

    func toggle() {
        if panel.isVisible {
            panel.close()
        } else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
