import Foundation

public struct SourceApp: Sendable {
    public let bundleID: String
    public let name: String
    public let iconPNG: Data?

    public init(bundleID: String, name: String, iconPNG: Data?) {
        self.bundleID = bundleID
        self.name = name
        self.iconPNG = iconPNG
    }
}

/// The app's single entry point to the library: captures, edits, queries. Every change is appended to the event log
/// first, then mirrored into the derived index. All calls are serialized by one lock.
public final class LibraryEngine {
    public let library: URL
    private let blobs: BlobStore
    private let log: EventLog
    private let index: SearchIndex
    private let lock = NSRecursiveLock()
    private static let imageTypes = ["public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif"]

    public init(library: URL, deviceID: String) throws {
        self.library = library
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        blobs = try BlobStore(root: library.appendingPathComponent("blobs"))
        log = try EventLog(directory: library.appendingPathComponent("log"), deviceID: deviceID)
        let indexURL = library.appendingPathComponent("index.sqlite")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do { index = try SearchIndex(path: indexURL) } catch SearchIndex.IndexError.outdated {
                _ = try IndexBuilder.rebuild(library: library)
                index = try SearchIndex(path: indexURL)
            }
        } else {
            _ = try IndexBuilder.rebuild(library: library)
            index = try SearchIndex(path: indexURL)
        }
    }

    // MARK: capture and edits

    /// Records a pasteboard change. Identical content already in history moves to the top instead of duplicating.
    @discardableResult
    public func capture(items: [PasteboardItem], source: SourceApp?, now: Double = Date().timeIntervalSince1970) throws -> ClipRecord? {
        try locked {
            let hasContent = items.contains { item in item.dataByType.values.contains { !$0.isEmpty } }
            guard hasContent, !isBlankText(items) else { return nil }
            if let source { try registerApp(source) }
            var reps: [Representation] = []
            for (n, item) in items.enumerated() {
                for uti in item.types {
                    guard let data = item.dataByType[uti] else { continue }
                    reps.append(Representation(uti: uti, blob: try blobs.put(data), size: data.count, item: n))
                }
            }
            let draft = ClipRecord(id: "cx:" + UUID().uuidString, createdAt: now, copiedAt: now, title: nil,
                                   appBundleID: source?.bundleID, board: nil, boardOrder: nil, rawKind: Self.kind(of: items),
                                   representations: reps, source: "capture")
            if let existingID = try index.recordID(fingerprint: draft.fingerprint),
               let existing = try index.records(ids: [existingID]).first {
                return try commit(existing.with(copiedAt: now, appBundleID: source.map { .some($0.bundleID) }, source: "capture"))
            }
            return try commit(draft)
        }
    }

    public func setTitle(_ id: String, to title: String) throws {
        try locked {
            guard let record = try index.records(ids: [id]).first else { return }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            try commit(record.with(title: .some(trimmed.isEmpty ? nil : trimmed)))
        }
    }

    /// Copies an item onto a pinboard, appended at the end. The original stays in history, as in Paste.
    @discardableResult
    public func pin(_ id: String, to board: String) throws -> ClipRecord {
        try locked {
            guard let record = try index.records(ids: [id]).first else { throw LibraryError.unknownRecord(id) }
            let order = try index.nextBoardOrder(board)
            return try commit(record.with(id: "cx:" + UUID().uuidString, board: .some(board), boardOrder: .some(order), source: "pin"))
        }
    }

    /// `colorCode` is ARGB, the same encoding Paste uses, so imported and new pinboards read the same way.
    public func addBoard(id: String, name: String, colorCode: UInt32? = nil) throws {
        try locked {
            let next = (try index.boards().map(\.index).max() ?? -1) + 1
            let attributes = try colorCode.map { code -> String in
                let json = try JSONSerialization.data(withJSONObject: ["type": "pinboard", "colorCode": code], options: [.sortedKeys])
                return try blobs.put(json)
            }
            let board = BoardRecord(id: id, name: name, index: next, kind: 2, createdAt: Date().timeIntervalSince1970, attributesBlob: attributes)
            try log.append(.board(board)); try log.sync()
            try index.upsertBoard(board)
        }
    }

    public func registerApp(_ source: SourceApp) throws {
        try locked {
            let known = try index.app(bundleID: source.bundleID)
            if let known, known.name == source.name, known.iconBlob != nil || source.iconPNG == nil { return }
            let icon = try source.iconPNG.map { try blobs.put($0) } ?? known?.iconBlob
            let app = AppRecord(bundleID: source.bundleID, name: source.name, iconBlob: icon)
            try log.append(.app(app))
            try index.upsertApp(app)
        }
    }

    // MARK: queries

    public func recent(board: String?, limit: Int, offset: Int = 0) throws -> [ClipRecord] {
        try locked { try index.recentRecords(scope: Self.scope(board), limit: limit, offset: offset) }
    }

    public func search(_ query: String, board: String?, limit: Int) throws -> [ClipRecord] {
        try locked {
            let hits = try index.search(query, limit: limit, scope: Self.scope(board))
            return try index.records(ids: hits.map(\.id))
        }
    }

    public func boards() throws -> [BoardRecord] { try locked { try index.boards() } }
    public func app(bundleID: String) throws -> AppRecord? { try locked { try index.app(bundleID: bundleID) } }

    public func iconData(bundleID: String) throws -> Data? {
        try locked { try index.app(bundleID: bundleID)?.iconBlob.flatMap { try? blobs.get($0) } }
    }

    // MARK: payloads

    public func payload(of record: ClipRecord) throws -> [PasteboardItem] {
        try locked {
            let grouped = Dictionary(grouping: record.representations, by: \.item)
            return try grouped.keys.sorted().map { n in
                let reps = grouped[n] ?? []
                var data: [String: Data] = [:]
                for rep in reps { data[rep.uti] = try blobs.get(rep.blob) }
                return PasteboardItem(types: reps.map(\.uti), dataByType: data)
            }
        }
    }

    public func text(of record: ClipRecord) -> String { locked { RecordText.text(for: record, blobs: blobs) } }

    public func imageData(of record: ClipRecord) -> Data? {
        locked {
            for uti in Self.imageTypes {
                if let rep = record.representations.first(where: { $0.uti == uti }), let data = try? blobs.get(rep.blob) { return data }
            }
            return nil
        }
    }

    /// Pinboard color from the attributes blob Paste stored (`colorCode` is ARGB). Nil when absent or unreadable.
    public func boardColorCode(_ board: BoardRecord) -> UInt32? {
        locked {
            guard let id = board.attributesBlob, let data = try? blobs.get(id),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = (json["colorCode"] as? NSNumber)?.uint64Value else { return nil }
            return UInt32(truncatingIfNeeded: code)
        }
    }

    public func previewData(of record: ClipRecord) -> Data? {
        locked { record.previewBlob.flatMap { try? blobs.get($0) } }
    }

    // MARK: internals

    public enum LibraryError: Error { case unknownRecord(String) }

    @discardableResult
    private func commit(_ record: ClipRecord) throws -> ClipRecord {
        try log.append(.put(record)); try log.sync()
        let name = try record.appBundleID.flatMap { try index.app(bundleID: $0)?.name }
        try index.upsert(SearchDocument(id: record.id, title: record.title, text: RecordText.text(for: record, blobs: blobs),
                                        appName: name, copiedAt: record.copiedAt, board: record.board,
                                        boardOrder: record.boardOrder, record: record))
        return record
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private static func scope(_ board: String?) -> SearchScope {
        guard let board, board != "sharedPasteboardHistory" else { return .history }
        return .board(board)
    }

    private func isBlankText(_ items: [PasteboardItem]) -> Bool {
        let onlyText = items.allSatisfy { Set($0.types).isSubset(of: ["public.utf8-plain-text", "public.utf16-external-plain-text", "public.text"]) }
        return onlyText && TextExtractor.text(from: items).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func kind(of items: [PasteboardItem]) -> Int {
        let types = Set(items.flatMap(\.types))
        if types.contains("public.file-url") { return 3 }
        if !types.isDisjoint(with: Set(imageTypes)), !types.contains("public.utf8-plain-text") { return 1 }
        let text = TextExtractor.text(from: items).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains(" "), !text.contains("\n"), let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme) { return 4 }
        return 5
    }
}
