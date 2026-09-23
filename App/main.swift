import AppKit

// An accessory app: no Dock icon and no menu bar of its own, so it never takes focus.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
