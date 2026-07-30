import AppKit
import SwiftUI

/// 总面板窗口：NSPanel（可 pin 常驻跨 Space，DESIGN.md §8.2）。
/// 注：DESIGN 的"附着球的瞬态 NSPopover -> 撕下成 NSPanel"留待 Phase 6；
/// 此处为 NSPanel + pin 按钮的形态，满足"pin 成 NSPanel"且可逆。
@MainActor
final class DashboardWindowController {
    private let panel: NSPanel

    init(store: UsageStore) {
        let hosting = NSHostingController(rootView: AnyView(EmptyView()))
        let panel = NSPanel(contentViewController: hosting)
        panel.title = "TokenRunway 总面板"
        panel.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.center()
        self.panel = panel
        // self 完成初始化后再捕获（避免 init 期 self 引用）
        hosting.rootView = AnyView(DashboardView(
            store: store,
            onTogglePin: { [weak self] pinned in self?.setPinned(pinned) }
        ))
    }

    /// pin：置顶跨 Space 常驻；否则普通浮窗。
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
