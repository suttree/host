import Cocoa

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
// Regular, so Host appears in the Dock and owns a menu bar. The tab strip is
// still a non-activating panel, so clicking a tab does not make Host frontmost --
// only clicking the Dock icon does.
application.setActivationPolicy(.regular)
application.run()
