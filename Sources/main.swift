import AppKit

// Explicit AppKit entry point. (Relying on `@main` on a bare NSApplicationDelegate
// did not reliably install the delegate / start the run loop on this toolchain.)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
