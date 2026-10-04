import Foundation

/// The library as a pure fold over stamped events. Replay is deterministic: events are ordered by `(at, dev)`, then by
/// their position, so two devices that read the same events end up with the same state.
public struct LibraryState {
    public private(set) var records: [String: ClipRecord] = [:]
    public private(set) var deleted: [String: Double] = [:]
    public private(set) var boards: [String: BoardRecord] = [:]
    public private(set) var apps: [String: AppRecord] = [:]
    private var purged = Set<String>()

    public init() {}

    public static func fold(_ events: [StampedEvent]) -> LibraryState {
        var state = LibraryState()
        let ordered = events.enumerated().sorted { a, b in
            (a.element.at, a.element.dev, a.offset) < (b.element.at, b.element.dev, b.offset)
        }
        for item in ordered { state.apply(item.element) }
        return state
    }

    public mutating func apply(_ stamped: StampedEvent) {
        switch stamped.event {
        case .put(let record):
            guard !purged.contains(record.id) else { return }
            records[record.id] = record
        case .board(let board): boards[board.id] = board
        case .app(let app): apps[app.bundleID] = app
        case .delete(let id): if records[id] != nil { deleted[id] = stamped.at }
        case .restore(let id): deleted[id] = nil
        case .purge(let id):
            records[id] = nil
            deleted[id] = nil
            purged.insert(id)
        }
    }
}
