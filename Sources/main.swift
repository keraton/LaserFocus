import AppKit

// When git runs LaserFocus as its password prompt, answer and exit before any app setup.
GitAskPass.handleIfNeeded()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
