import Foundation

public struct IndexBuildSummary: Sendable {
    public let documents: Int
    public let withText: Int
    public let seconds: Double
}

/// Rebuilds the derived index from the event log and blob store by folding stamped events (`LibraryState`): later events
/// win, so renames, pins, deletes and re-copies replay exactly. Safe to delete and rerun.
public enum IndexBuilder {
    public static func rebuild(library: URL, indexURL: URL? = nil, progress: ((Int, Int) -> Void)? = nil) throws -> IndexBuildSummary {
        let started = Date()
        let blobs = try BlobStore(root: library.appendingPathComponent("blobs"))
        let logDirectory = library.appendingPathComponent("log")
        let events = FileManager.default.fileExists(atPath: logDirectory.path) ? try EventLog.readAllStamped(directory: logDirectory) : []
        let state = LibraryState.fold(events)
        let records = state.records.values.sorted { ($0.copiedAt, $0.id) < ($1.copiedAt, $1.id) }

        let indexURL = indexURL ?? library.appendingPathComponent("index.sqlite")
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: indexURL.path + suffix) }
        let index = try SearchIndex(path: indexURL)
        var withText = 0
        try index.bulk(fresh: true) { add in
            for (n, record) in records.enumerated() {
                let text = RecordText.text(for: record, blobs: blobs)
                if !text.isEmpty { withText += 1 }
                add(SearchDocument(id: record.id, title: record.title, text: text,
                                   appName: record.appBundleID.flatMap { state.apps[$0]?.name }, copiedAt: record.copiedAt,
                                   board: record.board, boardOrder: record.boardOrder, record: record, deletedAt: state.deleted[record.id]))
                if n % 5000 == 0 { progress?(n, records.count) }
            }
        }
        try index.replaceMetadata(boards: Array(state.boards.values), apps: Array(state.apps.values))
        progress?(records.count, records.count)
        return IndexBuildSummary(documents: records.count, withText: withText, seconds: Date().timeIntervalSince(started))
    }
}
