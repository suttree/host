import Cocoa
import ApplicationServices

// MARK: - Logging

enum Log {
    static let start = Date()
    private static let fmt: NumberFormatter = {
        let f = NumberFormatter()
        f.minimumFractionDigits = 3
        f.maximumFractionDigits = 3
        return f
    }()

    static let fileURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Host.log")

    static func line(_ s: String) {
        let t = Date().timeIntervalSince(start)
        let stamp = fmt.string(from: NSNumber(value: t)) ?? "?"
        let msg = "[\(stamp)] \(s)"
        FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
        append(msg + "\n")
        DispatchQueue.main.async { LogWindow.shared.append(msg) }
    }

    private static let fileQueue = DispatchQueue(label: "host.log")

    private static func append(_ text: String) {
        fileQueue.async {
            guard let data = text.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    static func startFile() {
        try? "--- host \(Date()) ---\n".data(using: .utf8)?.write(to: fileURL)
    }
}

// MARK: - Coordinates
//
// The Accessibility API reports and accepts screen coordinates with the origin
// at the TOP-LEFT of the primary display, y increasing downward. Cocoa/NSScreen
// use the BOTTOM-LEFT of the primary display, y increasing upward. Mixing these
// up is the single most common source of "the window went somewhere weird".
// NSScreen.screens[0] is always the primary (menu bar) display, which is the
// one AX measures from.

enum Coords {
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }
    /// The conversion is its own inverse, so one function covers both directions.
    static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

// MARK: - Accessibility permission

enum AXPermission {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestIfNeeded() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Low level AX helpers
//
// Every one of these can block on the target process. They must never run on
// the main thread -- see AXQueue in WindowManager.swift.

/// Short timeout so a beachballed target cannot freeze us for the 6s default.
let axTimeout: Float = 0.25

func axSetTimeout(_ element: AXUIElement) {
    AXUIElementSetMessagingTimeout(element, axTimeout)
}

func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value
}

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    axCopy(element, attribute) as? String
}

func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    guard let v = axCopy(element, attribute) else { return nil }
    guard CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
    return (v as! CFBoolean) == kCFBooleanTrue
}

func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let v = axCopy(element, attribute) else { return nil }
    guard CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

func axElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
    guard let v = axCopy(element, attribute) else { return [] }
    guard CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
    return (v as! CFArray) as? [AXUIElement] ?? []
}

private func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    guard let v = axCopy(element, attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue((v as! AXValue), .cgPoint, &point) else { return nil }
    return point
}

private func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
    guard let v = axCopy(element, attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue((v as! AXValue), .cgSize, &size) else { return nil }
    return size
}

/// Window frame in AX (top-left origin) coordinates.
func axFrame(_ window: AXUIElement) -> CGRect? {
    guard let origin = axPoint(window, kAXPositionAttribute as String),
          let size = axSize(window, kAXSizeAttribute as String) else { return nil }
    return CGRect(origin: origin, size: size)
}

/// Set a window's frame, given AX (top-left origin) coordinates.
///
/// Position is written twice on purpose. Windows with a minimum size clamp the
/// resize and then shift their own origin to keep the window on screen, so the
/// first position write is undone by the size write. Writing it again afterwards
/// pins the top-left corner where we asked for it.
@discardableResult
func axSetFrame(_ window: AXUIElement, _ rect: CGRect) -> Bool {
    var origin = rect.origin
    var size = rect.size
    var ok = true

    if let v = AXValueCreate(.cgPoint, &origin) {
        ok = (AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) == .success) && ok
    }
    if let v = AXValueCreate(.cgSize, &size) {
        ok = (AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v) == .success) && ok
    }
    if let v = AXValueCreate(.cgPoint, &origin) {
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
    }
    return ok
}

func axSetBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) {
    AXUIElementSetAttributeValue(element, attribute as CFString,
                                 (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
}

/// A "real" window: not a sheet, palette, popover or the dialog an app throws up
/// on launch.
///
/// Written as a blocklist rather than an allowlist on purpose. Requiring
/// subrole == AXStandardWindow looks tidier but rejects every app that reports no
/// subrole at all, which is a lot of them -- and the failure is invisible, just a
/// tab that never appears.
func axIsStandardWindow(_ window: AXUIElement) -> Bool {
    guard let role = axString(window, kAXRoleAttribute as String),
          role == (kAXWindowRole as String) else { return false }

    if let subrole = axString(window, kAXSubroleAttribute as String) {
        let rejected: Set<String> = [
            kAXDialogSubrole as String,
            kAXSystemDialogSubrole as String,
            kAXFloatingWindowSubrole as String,
            kAXSystemFloatingWindowSubrole as String,
        ]
        if rejected.contains(subrole) { return false }
    }

    // Zero-sized windows are placeholders some apps keep around.
    guard let frame = axFrame(window), frame.width > 40, frame.height > 40 else { return false }
    return true
}

/// Read-only report on what an app is actually exposing, for when a tab silently
/// fails to appear.
func axDescribe(_ bundleID: String) -> [String] {
    guard let app = WindowManager.runningApp(bundleID) else {
        return ["\(bundleID): not running"]
    }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    axSetTimeout(element)

    var lines = ["\(bundleID): pid \(app.processIdentifier), hidden=\(app.isHidden), active=\(app.isActive)"]
    let windows = axElements(element, kAXWindowsAttribute as String)
    lines.append("  AXWindows count: \(windows.count)")
    if let main = axElement(element, kAXMainWindowAttribute as String) {
        lines.append("  AXMainWindow: \(axString(main, kAXTitleAttribute as String) ?? "untitled")")
    } else {
        lines.append("  AXMainWindow: none")
    }
    for (i, window) in windows.prefix(6).enumerated() {
        let role = axString(window, kAXRoleAttribute as String) ?? "nil"
        let subrole = axString(window, kAXSubroleAttribute as String) ?? "nil"
        let title = axString(window, kAXTitleAttribute as String) ?? "untitled"
        let frame = axFrame(window).map { NSStringFromRect($0) } ?? "unreadable"
        var posSettable: DarwinBoolean = false
        var sizeSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &posSettable)
        AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable)
        lines.append("  [\(i)] role=\(role) subrole=\(subrole) settable(pos=\(posSettable.boolValue) size=\(sizeSettable.boolValue))")
        lines.append("      title=\(title) frame=\(frame) accepted=\(axIsStandardWindow(window))")
    }
    return lines
}
