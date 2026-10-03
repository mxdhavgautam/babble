import AppKit
import Carbon.HIToolbox

/// Types text into the focused field by pasting it, then puts the user's clipboard back.
/// Posting ⌘V needs the Accessibility permission.
@MainActor
enum Paster {
    static func paste(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Tells clipboard managers to skip this entry.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ours = pasteboard.changeCount

        await waitForModifiersReleased()
        pressCommandV()

        try? await Task.sleep(for: .milliseconds(300))
        guard pasteboard.changeCount == ours else { return }
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    /// A still-held Option would turn ⌘V into ⌘⌥V in some apps, so wait (up to 1s) for it to lift.
    private static func waitForModifiersReleased() async {
        for _ in 0..<50 {
            if NSEvent.modifierFlags.intersection([.option, .shift, .control, .command]).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
