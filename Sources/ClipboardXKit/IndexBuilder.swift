import Foundation

public struct IndexBuildSummary: Sendable {
    public let documents: Int
    public let withText: Int
    public let seconds: Double
}

/// Rebuilds the derived index from the event log and blob store. Later events for the same id win, so renames,
/// pins and re-copies replay exactly. Safe to delete and rerun.
public enum IndexBuilder {
    public static func rebuild(library: URL, progress: ((Int, Int) -> Void)? = nil) throws -> IndexBuildSummary {
        let started = Date()
        let blobs = try BlobStore(root: library.appendingPathComponent("blobs"))
        let logDirectory = library.appendingPathComponent("log")
        let events = FileManager.default.fileExists(atPath: logDirectory.path) ? try EventLog.readAll(directory: logDirectory) : []
        var apps: [String: AppRecord] = [:]
        var boards: [String: BoardRecord] = [:]
        var latest: [String: ClipRecord] = [:]
        for event in events {
            switch event {
            case .app(let a): apps[a.bundleID] = a
            case .board(let b): boards[b.id] = b
            case .boardDeleted(let id): boards.removeValue(forKey: id)
            case .put(let r): latest[r.id] = r
            }
        }
        let records = latest.values.sorted { ($0.copiedAt, $0.id) < ($1.copiedAt, $1.id) }

        let indexURL = library.appendingPathComponent("index.sqlite")
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: indexURL.path + suffix) }
        let index = try SearchIndex(path: indexURL)
        var withText = 0
        try index.bulk(fresh: true) { add in
            for (n, record) in records.enumerated() {
                let text = RecordText.text(for: record, blobs: blobs)
                if !text.isEmpty { withText += 1 }
                add(SearchDocument(id: record.id, title: record.title, text: text,
                                   appName: record.appBundleID.flatMap { apps[$0]?.name }, copiedAt: record.copiedAt,
                                   board: record.board, boardOrder: record.boardOrder, record: record))
                if n % 5000 == 0 { progress?(n, records.count) }
            }
        }
        try index.replaceMetadata(boards: Array(boards.values), apps: Array(apps.values))
        progress?(records.count, records.count)
        return IndexBuildSummary(documents: records.count, withText: withText, seconds: Date().timeIntervalSince(started))
    }
}
