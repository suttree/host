import Cocoa
import ApplicationServices

/// Result of trying to put an app's window into the workspace rect.
struct PlacementResult {
    let bundleID: String
    let launched: Bool
    let waitedForWindow: TimeInterval
    let requested: CGRect      // AX coords
    let actual: CGRect?        // AX coords, read back afterwards
    let error: String?

    /// How far the window ended up from where we asked, in points.
    var drift: CGFloat? {
        guard let a = actual else { return nil }
        return max(abs(a.minX - requested.minX), abs(a.minY - requested.minY),
                   abs(a.width - requested.width), abs(a.height - requested.height))
    }
}

final class WindowManager {
    static let shared = WindowManager()

    /// All AX traffic goes here. AXUIElementCopyAttributeValue is a synchronous
    /// IPC call into the target process; on the main thread an unresponsive app
    /// would stall our UI for the full messaging timeout on every read.
    private let queue = DispatchQueue(label: "host.ax", qos: .userInitiated)

    /// Fired on the main thread when a tracked window is moved or resized by the
    /// user, with the window's new frame in Cocoa coordinates. This is how the
    /// strip follows a window the user drags or resizes by its own edges.
    var onGeometryChange: ((String, CGRect) -> Void)?

    private var geometryGeneration: UInt64 = 0
    /// Geometry notifications caused by our own placement, which must not be read
    /// back as user intent. Keyed by bundle id, on the AX queue.
    private var suppressGeometryUntil: [String: Date] = [:]
    private var trackedWindows: [String: AXUIElement] = [:]
    private var appElements: [pid_t: AXUIElement] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    /// The window we picked per app, so a second document window does not steal the tab.
    private var boundWindows: [String: AXUIElement] = [:]

    private init() {
        axSetTimeout(AXUIElementCreateSystemWide())
    }

    // MARK: - Public API

    /// Launch if needed, find the main window, move it into `cocoaRect`, raise it.
    func place(bundleID: String, in cocoaRect: CGRect, completion: @escaping (PlacementResult) -> Void) {
        let axRect = Coords.flip(cocoaRect)
        queue.async {
            let result = self.placeSync(bundleID: bundleID, axRect: axRect)
            DispatchQueue.main.async { completion(result) }

            // Check back once. Some apps -- Electron ones in particular -- restore
            // their own remembered bounds a moment after being shown or activated,
            // quietly undoing a placement that reported success at the time.
            self.queue.asyncAfter(deadline: .now() + 0.3) {
                self.ensureFrontmost(bundleID: bundleID)
            }
            self.queue.asyncAfter(deadline: .now() + 0.45) {
                self.reassert(bundleID: bundleID, axRect: axRect, reason: "after placement")
            }
        }
    }

    /// Put a window back in the workspace without launching or activating anything.
    ///
    /// This is what makes the workspace hold together when you reach an app some
    /// other way -- command-tab, clicking its window, the Dock. Without it a tab
    /// can be the active tab while its window sits at whatever size the app last
    /// chose, which looks like the sizing simply not working.
    func snap(bundleID: String, in cocoaRect: CGRect, reason: String = "reached outside Host") {
        let axRect = Coords.flip(cocoaRect)
        queue.async {
            guard let app = Self.runningApp(bundleID), !app.isHidden else { return }
            let element = self.appElement(for: app.processIdentifier)
            guard let window = self.waitForWindow(bundleID: bundleID, appElement: element, deadline: 1)
            else { return }
            self.reassert(bundleID: bundleID, axRect: axRect, reason: reason, window: window)
        }
    }

    /// Reapply the frame if the window is not where the workspace says it should
    /// be. Runs at most once per call, so an app that genuinely cannot comply --
    /// one with a minimum size -- is not fought in a loop.
    private func reassert(bundleID: String, axRect: CGRect, reason: String,
                          window explicit: AXUIElement? = nil) {
        guard let window = explicit ?? boundWindows[bundleID],
              let actual = axFrame(window) else { return }
        let off = max(abs(actual.minX - axRect.minX), abs(actual.minY - axRect.minY),
                      abs(actual.width - axRect.width), abs(actual.height - axRect.height))
        guard off > 2 else { return }

        Log.line("  \(bundleID) is \(Int(off))pt out (\(reason)); putting it back")
        self.suppressGeometryUntil[bundleID] = Date().addingTimeInterval(1.0)
        axSetFrame(window, axRect)
    }

    /// AXFullScreen is how an app's own full-screen button is driven, so this puts
    /// a window into the same state a user would.
    func setFullScreen(bundleID: String, to wanted: Bool) {
        queue.async {
            // Re-find rather than trusting the binding: going full screen fires a
            // main-window-changed event, which unbinds the window we were holding.
            guard let app = Self.runningApp(bundleID) else { return }
            let element = self.appElement(for: app.processIdentifier)
            guard let window = self.waitForWindow(bundleID: bundleID, appElement: element,
                                                  deadline: 2) else {
                Log.line("  no window for \(bundleID); cannot toggle full screen")
                return
            }
            let error = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString,
                                                    (wanted ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
            Log.line("  full screen \(wanted) for \(bundleID): \(error == .success ? "ok" : "failed (\(error.rawValue))")")
        }
    }

    func forget(bundleID: String) {
        queue.async { self.boundWindows[bundleID] = nil }
    }

    // MARK: - Implementation

    private func placeSync(bundleID: String, axRect: CGRect) -> PlacementResult {
        var launched = false

        var running = Self.runningApp(bundleID)
        if running == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return PlacementResult(bundleID: bundleID, launched: false, waitedForWindow: 0,
                                       requested: axRect, actual: nil,
                                       error: "no application installed with that bundle id")
            }
            Log.line("launching \(bundleID)")
            launched = true
            let sema = DispatchSemaphore(value: 0)
            var launchError: String?
            let config = NSWorkspace.OpenConfiguration()
            // Must be true. Document-based apps commonly create no window at all
            // when launched without activation -- TextEdit launches, reports zero
            // AX windows forever, and the tab simply never appears. We raise the
            // window immediately afterwards anyway, so nothing is gained by
            // launching quietly.
            config.activates = true
            config.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if let error { launchError = error.localizedDescription }
                running = app
                sema.signal()
            }
            if sema.wait(timeout: .now() + 20) == .timedOut {
                return PlacementResult(bundleID: bundleID, launched: true, waitedForWindow: 0,
                                       requested: axRect, actual: nil, error: "launch timed out")
            }
            if let launchError {
                return PlacementResult(bundleID: bundleID, launched: true, waitedForWindow: 0,
                                       requested: axRect, actual: nil, error: launchError)
            }
        }

        guard let app = running else {
            return PlacementResult(bundleID: bundleID, launched: launched, waitedForWindow: 0,
                                   requested: axRect, actual: nil, error: "application not running")
        }

        // A hidden app reports no windows at all, so unhide before looking.
        if app.isHidden { app.unhide() }

        let appElement = self.appElement(for: app.processIdentifier)
        self.installObserver(pid: app.processIdentifier, element: appElement, bundleID: bundleID)

        let waitStart = Date()
        var window = self.waitForWindow(bundleID: bundleID, appElement: appElement,
                                        deadline: launched ? 12 : 3)
        if window == nil {
            // Reopening is the documented nudge for an app that is running but
            // showing nothing: LaunchServices sends it a reopen event, which is
            // what makes a document app produce an untitled document or its open
            // panel.
            Log.line("  \(bundleID): running but no window yet, nudging with a reopen")
            axSetBool(appElement, kAXFrontmostAttribute as String, true)
            self.reopen(bundleID)
            window = self.waitForWindow(bundleID: bundleID, appElement: appElement, deadline: 8)
        }
        guard let window else {
            for line in axDescribe(bundleID) { Log.line("  \(line)") }
            return PlacementResult(bundleID: bundleID, launched: launched,
                                   waitedForWindow: Date().timeIntervalSince(waitStart),
                                   requested: axRect, actual: nil,
                                   error: "no standard window appeared")
        }
        let waited = Date().timeIntervalSince(waitStart)
        self.trackGeometry(pid: app.processIdentifier, bundleID: bundleID, window: window)

        // A minimised window silently ignores position and size writes.
        if axBool(window, kAXMinimizedAttribute as String) == true {
            axSetBool(window, kAXMinimizedAttribute as String, false)
            Thread.sleep(forTimeInterval: 0.15)   // the genie animation must finish first
        }

        // Our own resize is about to fire move/resize notifications. Without this
        // an app that clamps to a minimum size would report its clamped frame,
        // followWindow would treat that as the user resizing the workspace, and
        // the size the user actually chose would be silently replaced by whatever
        // the least flexible app in the workspace permits.
        self.suppressGeometryUntil[bundleID] = Date().addingTimeInterval(1.0)
        axSetFrame(window, axRect)

        // Raise within the app, then bring the app forward. Doing it in this
        // order avoids a frame where the wrong window of the target app is on top.
        axSetBool(window, kAXMainAttribute as String, true)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        self.activate(app, appElement: appElement)

        // Read back rather than trusting the write. Apps with size constraints,
        // and full-screen or tiled windows, will quietly refuse.
        let actual = axFrame(window)
        if let actual, abs(actual.width - axRect.width) > 2 || abs(actual.height - axRect.height) > 2 {
            Log.line("  \(bundleID) refused the workspace size " +
                     "(wanted \(Int(axRect.width))x\(Int(axRect.height)), " +
                     "took \(Int(actual.width))x\(Int(actual.height))) -- minimum size; workspace unchanged")
        }
        return PlacementResult(bundleID: bundleID, launched: launched, waitedForWindow: waited,
                               requested: axRect, actual: actual, error: nil)
    }

    /// Bring an app to the front.
    ///
    /// NSRunningApplication.activate alone is not enough. Since macOS 14 an app
    /// may only activate another app while it holds activation rights, and Host's
    /// tab strip is a non-activating panel, so Host is almost never frontmost and
    /// the request is simply refused. The window gets moved into place correctly
    /// and then never comes forward -- which looks exactly like "the tab does
    /// nothing".
    ///
    /// Setting AXFrontmost goes through the Accessibility API instead, which is
    /// not subject to that restriction. Host already requires Accessibility to do
    /// anything at all, so this costs nothing extra.
    private func reopen(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.addsToRecentItems = false
        let sema = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in sema.signal() }
        _ = sema.wait(timeout: .now() + 10)
    }

    private func activate(_ app: NSRunningApplication, appElement: AXUIElement) {
        let bundleID = app.bundleIdentifier ?? "?"
        // Report what actually happened. Setting AXFrontmost can fail too, and
        // assuming it succeeded whenever activate() was refused meant the log
        // claimed the switch had worked at the exact moments it had not.
        let axError = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString,
                                                   kCFBooleanTrue as CFTypeRef)
        let activated = app.activate(options: [.activateAllWindows])
        if !activated || axError != .success {
            Log.line("  \(bundleID): activate=\(activated) AXFrontmost=\(axError == .success ? "ok" : "failed")")
        }
    }

    /// Check the app really did come forward, and have one more go if it did not.
    ///
    /// Since macOS 14 an app may only activate another while it holds activation
    /// rights, and Host's strip is a non-activating panel, so activate() is
    /// sometimes refused. AXFrontmost usually covers that but not always, and when
    /// both miss, the window is placed correctly and simply stays behind the app
    /// you were on -- the tab looks like it did nothing.
    private func ensureFrontmost(bundleID: String) {
        guard let app = Self.runningApp(bundleID), !app.isHidden else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard front != bundleID else { return }

        Log.line("  \(bundleID) did not come forward (\(front ?? "nothing") is in front); trying again")
        let element = self.appElement(for: app.processIdentifier)
        if let window = boundWindows[bundleID] {
            axSetBool(window, kAXMainAttribute as String, true)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        activate(app, appElement: element)
    }

    /// Poll for a usable window. Polling rather than waiting on an AX notification
    /// because a freshly launched process often has no AX application element yet,
    /// so there is nothing to observe until it does.
    private func waitForWindow(bundleID: String, appElement: AXUIElement, deadline: TimeInterval) -> AXUIElement? {
        if let bound = boundWindows[bundleID], axFrame(bound) != nil {
            return bound
        }
        let end = Date().addingTimeInterval(deadline)
        repeat {
            if let w = primaryWindow(of: appElement) {
                boundWindows[bundleID] = w
                return w
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < end
        return nil
    }

    /// Which window is "the" window. Apps disagree about this, so try the
    /// specific attributes first and only then fall back to scanning the list.
    private func primaryWindow(of appElement: AXUIElement) -> AXUIElement? {
        for attribute in [kAXMainWindowAttribute as String, kAXFocusedWindowAttribute as String] {
            if let w = axElement(appElement, attribute), axIsStandardWindow(w) {
                return w
            }
        }
        let windows = axElements(appElement, kAXWindowsAttribute as String)
        if let standard = windows.first(where: axIsStandardWindow) { return standard }

        // Last resort: the biggest window, whatever it calls itself.
        //
        // Some apps mislabel their one and only window. Music reports its main
        // window as AXDialog, which the subrole test rejects, and the tab then does
        // nothing at all with no visible reason. A window that is plainly the app's
        // main window is a better tab than no tab.
        let fallback = windows
            .compactMap { window -> (AXUIElement, CGFloat)? in
                guard let frame = axFrame(window), frame.width > 200, frame.height > 200 else { return nil }
                return (window, frame.width * frame.height)
            }
            .max { $0.1 < $1.1 }?.0
        if fallback != nil {
            Log.line("  no window with a standard subrole; falling back to the largest")
        }
        return fallback
    }

    private func appElement(for pid: pid_t) -> AXUIElement {
        if let existing = appElements[pid] { return existing }
        let element = AXUIElementCreateApplication(pid)
        axSetTimeout(element)
        appElements[pid] = element
        return element
    }

    // MARK: - Observers
    //
    // Without these a tab breaks the moment the app opens a second document
    // window or the user closes the one we bound to.

    private func installObserver(pid: pid_t, element: AXUIElement, bundleID: String) {
        guard observers[pid] == nil else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let box = Unmanaged<ObserverBox>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String

            // Handled first and without logging: a live drag fires these dozens
            // of times a second and would drown the log.
            if name == (kAXWindowMovedNotification as String)
                || name == (kAXWindowResizedNotification as String) {
                WindowManager.shared.geometryChanged(window: element, bundleID: box.bundleID)
                return
            }

            Log.line("ax event \(box.bundleID): \(name)")
            if name == (kAXUIElementDestroyedNotification as String)
                || name == (kAXMainWindowChangedNotification as String) {
                WindowManager.shared.forget(bundleID: box.bundleID)
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let box = ObserverBox(bundleID: bundleID)
        boxes.append(box)
        let refcon = Unmanaged.passUnretained(box).toOpaque()

        for name in [kAXWindowCreatedNotification, kAXMainWindowChangedNotification,
                     kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private var boxes: [ObserverBox] = []

    /// Subscribe to move/resize on the one window this tab is bound to.
    private func trackGeometry(pid: pid_t, bundleID: String, window: AXUIElement) {
        guard let observer = observers[pid] else { return }
        if let existing = trackedWindows[bundleID], CFEqual(existing, window) { return }
        if let existing = trackedWindows[bundleID] {
            AXObserverRemoveNotification(observer, existing, kAXWindowMovedNotification as CFString)
            AXObserverRemoveNotification(observer, existing, kAXWindowResizedNotification as CFString)
        }
        guard let box = boxes.first(where: { $0.bundleID == bundleID }) else { return }
        let refcon = Unmanaged.passUnretained(box).toOpaque()
        AXObserverAddNotification(observer, window, kAXWindowMovedNotification as CFString, refcon)
        AXObserverAddNotification(observer, window, kAXWindowResizedNotification as CFString, refcon)
        trackedWindows[bundleID] = window
    }

    /// Called on the main run loop by the AX observer.
    ///
    /// The frame read is pushed onto the AX queue like every other AX call, and
    /// a generation counter drops results that a newer notification has already
    /// superseded. Without that, a fast drag builds a backlog of stale frames and
    /// the strip lags visibly behind the window.
    fileprivate func geometryChanged(window: AXUIElement, bundleID: String) {
        geometryGeneration &+= 1
        let generation = geometryGeneration
        queue.async {
            if let until = self.suppressGeometryUntil[bundleID], Date() < until { return }
            guard let axRect = axFrame(window) else { return }
            DispatchQueue.main.async {
                guard generation == self.geometryGeneration else { return }
                self.onGeometryChange?(bundleID, Coords.flip(axRect))
            }
        }
    }

    // MARK: - Helpers

    static func runningApp(_ bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
    }
}

/// AXObserverCallback is a bare C function pointer and cannot capture context,
/// so identity is passed through the refcon instead.
final class ObserverBox {
    let bundleID: String
    init(bundleID: String) { self.bundleID = bundleID }
}
