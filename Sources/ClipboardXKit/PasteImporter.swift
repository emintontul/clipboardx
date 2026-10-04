import Foundation

public struct ImportSummary: Sendable {
    public let itemsRead: Int
    public let itemsImported: Int
    public let itemsAlreadyPresent: Int
    public let undecodable: [String]
    public let boards: Int
    public let apps: Int
}

/// Imports a Paste snapshot into the ClipboardX layout: `output/log` (append-only events) and `output/blobs`.
/// Safe to re-run: items already in the log are skipped.
public enum PasteImporter {
    public static let idPrefix = "paste:"

    public static func run(snapshot: URL, externalDirectory: URL, output: URL, deviceID: String,
                           progress: ((Int, Int) -> Void)? = nil) throws -> ImportSummary {
        let source = try PasteSource(snapshot: snapshot)
        let blobs = try BlobStore(root: output.appendingPathComponent("blobs"))
        let logDirectory = output.appendingPathComponent("log")
        let existing = try existingIdentifiers(logDirectory)
        let log = try EventLog(directory: logDirectory, deviceID: deviceID)

        var newBoards = 0, newApps = 0
        for app in try source.apps() where !existing.apps.contains(app.bundleID) {
            let icon = try app.icon.map { try blobs.put($0) }
            try log.append(.app(AppRecord(bundleID: app.bundleID, name: app.name, iconBlob: icon)))
            newApps += 1
        }
        for board in try source.boards() where !existing.boards.contains(board.identifier) {
            let attributes = try board.attributes.map { try blobs.put($0) }
            try log.append(.board(BoardRecord(id: board.identifier, name: board.name, index: board.index,
                                              kind: board.kind, createdAt: board.createdAt, attributesBlob: attributes)))
            newBoards += 1
        }

        let total = try source.itemCount()
        var read = 0, imported = 0, present = 0
        var undecodable: [String] = []
        try source.forEachItem { item in
            read += 1
            let id = idPrefix + item.identifier
            if existing.items.contains(id) { present += 1; return }
            let record = try makeRecord(item, id: id, blobs: blobs, externalDirectory: externalDirectory)
            if !record.flags.isEmpty { undecodable.append(item.identifier) }
            try log.append(.put(record))
            imported += 1
            if read % 1000 == 0 { try log.sync(); progress?(read, total) }
        }
        try log.sync()
        progress?(read, total)
        return ImportSummary(itemsRead: read, itemsImported: imported, itemsAlreadyPresent: present,
                             undecodable: undecodable, boards: newBoards, apps: newApps)
    }

    static func makeRecord(_ item: PasteSource.Item, id: String, blobs: BlobStore, externalDirectory: URL) throws -> ClipRecord {
        let preview = try item.preview.map { try blobs.put($0) }
        var representations: [Representation] = []
        var flags: [String] = []
        var raw: String?
        do {
            let decoded = try PasteBlobDecoder.decode(item.blob, externalDirectory: externalDirectory)
            for (index, pasteboardItem) in decoded.items.enumerated() {
                for uti in pasteboardItem.types {
                    guard let data = pasteboardItem.dataByType[uti] else { continue }
                    representations.append(Representation(uti: uti, blob: try blobs.put(data), size: data.count, item: index))
                }
            }
        } catch {
            flags.append("undecodable")
            raw = try blobs.put(item.blob)
        }
        return ClipRecord(id: id, createdAt: item.createdAt, copiedAt: item.copiedAt, title: item.title,
                          appBundleID: item.appBundleID, board: item.board, boardOrder: item.boardOrder,
                          rawKind: item.rawKind, representations: representations, source: "paste-import",
                          flags: flags, rawBlob: raw, previewBlob: preview)
    }

    private struct Existing { var items = Set<String>(); var boards = Set<String>(); var apps = Set<String>() }

    private static func existingIdentifiers(_ logDirectory: URL) throws -> Existing {
        guard FileManager.default.fileExists(atPath: logDirectory.path) else { return Existing() }
        var found = Existing()
        for event in try EventLog.readAll(directory: logDirectory) {
            switch event {
            case .put(let r): found.items.insert(r.id)
            case .board(let b): found.boards.insert(b.id)
            case .app(let a): found.apps.insert(a.bundleID)
            case .delete, .restore, .purge: break
            }
        }
        return found
    }
}
