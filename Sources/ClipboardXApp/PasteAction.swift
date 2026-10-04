import AppKit
import ApplicationServices
import ClipboardXKit

/// Puts an item back on the system pasteboard and, when allowed, presses ⌘V in the app that was in front.
enum PasteAction {
    static func perform(items: [PasteboardItem], plainText: Bool, autoPaste: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let objects: [NSPasteboardItem] = items.compactMap { item in
            let out = NSPasteboardItem()
            let types = plainText ? item.types.filter { $0 == "public.utf8-plain-text" } : item.types
            var wrote = false
            for type in types {
                guard let data = item.dataByType[type] else { continue }
                out.setData(data, forType: NSPasteboard.PasteboardType(type)); wrote = true
            }
            if wrote { out.setData(Data(), forType: NSPasteboard.PasteboardType(CapturePolicy.ownMarkerType)) }
            return wrote ? out : nil
        }
        pasteboard.writeObjects(objects)
        guard autoPaste else { return }
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        }
    }
}
