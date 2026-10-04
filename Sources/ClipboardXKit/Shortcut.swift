import Foundation

/// A key combination in Carbon's terms (virtual key code plus modifier bits), so it can be registered as a global hotkey.
public struct Shortcut: Codable, Equatable, Sendable {
    public static let command: UInt32 = 256
    public static let shift: UInt32 = 512
    public static let option: UInt32 = 2048
    public static let control: UInt32 = 4096

    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// macOS order: ⌃ ⌥ ⇧ ⌘, then the key.
    public var display: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + (Self.keyLabels[keyCode] ?? "Key \(keyCode)")
    }

    /// Shift alone (or no modifier) would swallow normal typing, so global shortcuts need ⌘, ⌥ or ⌃.
    public var isValidGlobal: Bool { modifiers & (Self.command | Self.option | Self.control) != 0 }

    private static let keyLabels: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋", 122: "F1", 120: "F2", 99: "F3", 118: "F4",
        96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

public enum ShortcutAction: String, CaseIterable, Sendable {
    case showShelf, pasteStack, nextBoard, previousBoard

    public var title: String {
        switch self {
        case .showShelf: return "Show ClipboardX"
        case .pasteStack: return "Start / stop Paste Stack"
        case .nextBoard: return "Next pinboard"
        case .previousBoard: return "Previous pinboard"
        }
    }

    /// Global actions work in any app; the others only while the shelf is open.
    public var isGlobal: Bool { self == .showShelf || self == .pasteStack }

    public var defaultShortcut: Shortcut {
        switch self {
        case .showShelf: return Shortcut(keyCode: 9, modifiers: Shortcut.shift | Shortcut.command)
        case .pasteStack: return Shortcut(keyCode: 8, modifiers: Shortcut.shift | Shortcut.command)
        case .nextBoard: return Shortcut(keyCode: 124, modifiers: Shortcut.command)
        case .previousBoard: return Shortcut(keyCode: 123, modifiers: Shortcut.command)
        }
    }
}

/// Persists the user's shortcuts. Unknown or corrupt values fall back to the defaults.
public final class ShortcutStore: @unchecked Sendable {
    public enum SetError: Error, Equatable {
        case needsModifier
        case conflict(with: ShortcutAction)
    }

    public static let didChange = Notification.Name("ClipboardXShortcutsDidChange")
    public static let shared = ShortcutStore()
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ action: ShortcutAction) -> String { "shortcuts." + action.rawValue }

    public func shortcut(for action: ShortcutAction) -> Shortcut {
        guard let data = defaults.data(forKey: key(action)), let stored = try? JSONDecoder().decode(Shortcut.self, from: data) else {
            return action.defaultShortcut
        }
        return stored
    }

    public func set(_ shortcut: Shortcut, for action: ShortcutAction) throws {
        if action.isGlobal, !shortcut.isValidGlobal { throw SetError.needsModifier }
        if let other = ShortcutAction.allCases.first(where: { $0 != action && self.shortcut(for: $0) == shortcut }) {
            throw SetError.conflict(with: other)
        }
        defaults.set(try JSONEncoder().encode(shortcut), forKey: key(action))
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    public func resetAll() {
        for action in ShortcutAction.allCases { defaults.removeObject(forKey: key(action)) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    public func matches(keyCode: UInt32, modifiers: UInt32, action: ShortcutAction) -> Bool {
        let wanted = shortcut(for: action)
        return wanted.keyCode == keyCode && wanted.modifiers == modifiers
    }
}
