import AppKit

// Entry point. NotchHub is a menu-bar / overlay style app, so we use the
// `.accessory` activation policy (equivalent to LSUIElement) — no Dock icon,
// the app lives in the menu bar and as an overlay over the notch.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
