import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // 无 Dock 图标（LSUIElement 打包时再次声明）
app.run()
