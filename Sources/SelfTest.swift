import Cocoa

/// The Phase 1 success criterion.
///
/// Attaching one app once proves almost nothing. Everything that makes this idea
/// fail lives in the *switch*: windows drifting a few points each time, the strip
/// falling behind the app, focus bouncing, an app that quietly refuses to resize.
/// So: two apps, ten switches, and a report of the worst drift seen.
enum SelfTest {
    static func run(controller: TabStripController) {
        guard controller.workspace.tabs.count >= 2 else {
            Log.line("self-test needs at least two tabs")
            return
        }
        guard AXPermission.isTrusted else {
            AppDelegate.shared?.nagAboutPermission()
            return
        }

        LogWindow.shared.show()
        Log.line("--- self-test: 10 switches between \(controller.workspace.tabs[0].name) and \(controller.workspace.tabs[1].name) ---")

        var worstDrift: CGFloat = 0
        var failures: [String] = []
        var slowest: TimeInterval = 0
        let target = controller.workspace.contentFrame

        func step(_ n: Int) {
            guard n < 10 else {
                Log.line("--- self-test done ---")
                Log.line(String(format: "worst drift: %.1fpt   slowest switch: %.2fs", worstDrift, slowest))
                if failures.isEmpty {
                    Log.line("no failures. If nothing visibly flickered or stole focus, Phase 1 is proved.")
                } else {
                    for f in failures { Log.line("FAILURE: \(f)") }
                }
                return
            }
            let index = n % 2
            let tab = controller.workspace.tabs[index]
            let began = Date()
            WindowManager.shared.place(bundleID: tab.bundleIdentifier, in: target) { result in
                let elapsed = Date().timeIntervalSince(began)
                slowest = max(slowest, elapsed)
                if let error = result.error {
                    failures.append("\(tab.name): \(error)")
                } else if let drift = result.drift {
                    worstDrift = max(worstDrift, drift)
                    Log.line(String(format: "  switch %2d  %-12@  %.2fs  drift %.1fpt",
                                    n + 1, tab.name as NSString, elapsed, drift))
                    if drift > 2 {
                        failures.append("\(tab.name) drifted \(Int(drift))pt on switch \(n + 1)")
                    }
                } else {
                    failures.append("\(tab.name): could not read window frame back")
                }
                controller.raiseStrip()
                // A beat between switches, otherwise we measure our own queue
                // rather than what the user would actually experience.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { step(n + 1) }
            }
        }
        step(0)
    }
}

/// Somewhere to read the log without keeping a terminal open.
final class LogWindow {
    static let shared = LogWindow()
    private var window: NSWindow?
    private let textView = NSTextView()
    private var pending: [String] = []

    func append(_ line: String) {
        pending.append(line)
        guard window != nil else { return }
        flush()
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let text = pending.joined(separator: "\n") + "\n"
        pending.removeAll()
        textView.textStorage?.append(NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.labelColor]))
        textView.scrollToEndOfDocument(nil)
    }

    func show() {
        if window == nil {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 380))
            scroll.hasVerticalScroller = true
            textView.isEditable = false
            textView.autoresizingMask = [.width]
            textView.minSize = .zero
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.textContainer?.containerSize = NSSize(width: 720, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = true
            scroll.documentView = textView

            let w = NSWindow(contentRect: scroll.frame,
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Host log"
            w.contentView = scroll
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        flush()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
