import AppKit

// --snapshot mode: render views to PNGs via ImageRenderer, no physical screen needed.
if CommandLine.arguments.contains("--snapshot") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // Schedule the render before app.run() blocks
    Timer.scheduledTimer(withTimeInterval: 0.0, repeats: false) { _ in
        Task { @MainActor in
            await SnapshotRenderer.renderAll()
            NSApp.terminate(nil)
        }
    }
    app.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // 无 Dock 图标（LSUIElement 打包时再次声明）
app.run()
