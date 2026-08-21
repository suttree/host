import Cocoa
import Carbon.HIToolbox

/// Global hotkeys via Carbon's RegisterEventHotKey.
///
/// This is deliberately not NSEvent.addGlobalMonitorForEvents: a global monitor
/// can observe a key press but cannot consume it, so the frontmost app would
/// also receive the keystroke. RegisterEventHotKey swallows the event, and it
/// works from an accessory app that never becomes active.
///
/// The modifier is Option. Command-digit is already spoken for in most apps -- in
/// a browser it switches tabs, in an editor it toggles panes -- and a switcher
/// that fights the app it just brought forward is worse than no switcher at all.
///
/// Control-digit was the first choice and does not work: macOS reserves it for
/// Mission Control's "Switch to Desktop N" and consumes the event before any
/// Carbon hotkey sees it. Registration still succeeds, which is what makes it
/// such a quiet failure -- the keys simply never fire.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var handlerInstalled = false

    private init() {}

    /// Key codes for the digit row. Note that these are physical key codes and
    /// are not in numeric order -- 5 and 6 are transposed relative to intuition.
    static let digitKeyCodes: [UInt32] = [
        UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
        UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
        UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9),
    ]

    func registerOptionDigit(index: Int, handler: @escaping () -> Void) {
        guard index < Self.digitKeyCodes.count else { return }
        register(keyCode: Self.digitKeyCodes[index],
                 modifiers: UInt32(optionKey),
                 id: UInt32(index + 1),
                 handler: handler)
    }

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        handlers[id] = handler

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x54424853) /* 'TBHS' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            refs.append(ref)
        } else {
            Log.line("hotkey \(id) failed to register (status \(status)) -- probably taken by another app")
        }
    }

    func unregisterAll() {
        for ref in refs where ref != nil { UnregisterEventHotKey(ref!) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr else { return err }
            DispatchQueue.main.async { HotKeyCenter.shared.fire(hotKeyID.id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
