import Foundation

/// A queue of clips to paste one after another. While active, each new copy joins the end; pasting takes from the front.
public struct PasteStack: Equatable, Sendable {
    public private(set) var isActive = false
    public private(set) var ids: [String] = []

    public init() {}

    public mutating func start() {
        isActive = true
        ids = []
    }

    public mutating func stop() {
        isActive = false
        ids = []
    }

    /// Ignored while inactive. Copying the same clip twice in a row queues it once.
    public mutating func enqueue(_ id: String) {
        guard isActive, ids.last != id else { return }
        ids.append(id)
    }

    /// Removes the first occurrence, e.g. after that clip was pasted.
    public mutating func remove(_ id: String) {
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) }
    }

    @discardableResult
    public mutating func popFirst() -> String? {
        ids.isEmpty ? nil : ids.removeFirst()
    }
}
