import AppKit
import ClipboardXKit

extension Shortcut {
    /// Carbon modifier bits for an AppKit event.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var bits: UInt32 = 0
        if flags.contains(.command) { bits |= Shortcut.command }
        if flags.contains(.shift) { bits |= Shortcut.shift }
        if flags.contains(.option) { bits |= Shortcut.option }
        if flags.contains(.control) { bits |= Shortcut.control }
        return bits
    }
}

/// Registers the global shortcuts from `ShortcutStore` and re-registers when the user changes them.
final class HotKeyCenter {
    private let store: ShortcutStore
    private var handlers: [ShortcutAction: () -> Void] = [:]
    private var keys: [ShortcutAction: HotKey] = [:]
    private var observer: NSObjectProtocol?
    /// Shortcuts actually in effect (the show-shelf one falls back to ⌥⌘V if another app owns it).
    private(set) var effective: [ShortcutAction: Shortcut] = [:]
    var onChange: (() -> Void)?

    init(store: ShortcutStore = .shared) {
        self.store = store
        observer = NotificationCenter.default.addObserver(forName: ShortcutStore.didChange, object: nil, queue: .main) { [weak self] _ in self?.reload() }
    }

    func register(_ action: ShortcutAction, handler: @escaping () -> Void) {
        handlers[action] = handler
        reload()
    }

    func reload() {
        keys.removeAll()
        effective = [:]
        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let handler = handlers[action] else { continue }
            let wanted = store.shortcut(for: action)
            if let key = HotKey(keyCode: wanted.keyCode, modifiers: wanted.modifiers, id: UInt32(index + 1), handler: handler) {
                keys[action] = key
                effective[action] = wanted
            } else if action == .showShelf {
                let fallback = Shortcut(keyCode: 9, modifiers: Shortcut.option | Shortcut.command)
                if let key = HotKey(keyCode: fallback.keyCode, modifiers: fallback.modifiers, id: UInt32(index + 1), handler: handler) {
                    keys[action] = key
                    effective[action] = fallback
                }
            }
        }
        onChange?()
    }
}
