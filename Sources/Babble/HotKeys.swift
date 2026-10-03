import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon. Needs no permissions and swallows the keystroke,
/// so Option+D never types "∂" into the focused app. Handlers run on the main thread.
@MainActor
final class HotKeys {
    enum Phase { case pressed, released }

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: (Phase) -> Void] = [:]
    private var nextID: UInt32 = 1

    init() {
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let phase: Phase = GetEventKind(event) == UInt32(kEventHotKeyPressed) ? .pressed : .released
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKeys.handlers[hotKeyID.id]?(phase) }
            return noErr
        }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// Registers `keyCode` + Carbon `modifiers` (e.g. `optionKey | shiftKey`). Returns an id for `unregister`.
    @discardableResult
    func register(keyCode: Int, modifiers: Int, handler: @escaping (Phase) -> Void) -> UInt32 {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4242_4C45), id: id)  // 'BBLE'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if let ref { refs[id] = ref }
        handlers[id] = handler
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }
}
