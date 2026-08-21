import Cocoa
import Carbon.HIToolbox

/// Global hotkeys via Carbon's RegisterEventHotKey.
///
/// This is deliberately not NSEvent.addGlobalMonitorForEvents: a global monitor
/// can observe a key press but cannot consume it, so the frontmost app would
/// also receive the keystroke. RegisterEventHotKey swallows the event, and it
/// works from an accessory app that never becomes active.
///
/// Host only claims Option-Shift-[ and Option-Shift-]. Option-digit combinations
/// are text input on several keyboard layouts, including Option-3 for `#`.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var handlerInstalled = false

    private init() {}

    func registerOptionShiftBrackets(previous: @escaping () -> Void,
                                     next: @escaping () -> Void) {
        let modifiers = UInt32(optionKey | shiftKey)
        register(keyCode: UInt32(kVK_ANSI_LeftBracket), modifiers: modifiers,
                 id: 100, handler: previous)
        register(keyCode: UInt32(kVK_ANSI_RightBracket), modifiers: modifiers,
                 id: 101, handler: next)
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
