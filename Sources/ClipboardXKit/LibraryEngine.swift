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
    private var index: SearchIndex
    private var building = false
    private var buildProgress = 0.0
    private var buildFailure: String?
    private let lock = NSRecursiveLock()
    private static let imageTypes = ["public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif"]

    public convenience init(library: URL, deviceID: String) throws {
        try self.init(library: library, deviceID: deviceID, beforeIndexSwap: nil)
    }

    /// Opens the library. A missing or outdated index is rebuilt on a background queue: until it is ready the engine
    /// answers from an empty in-memory index, and everything captured meanwhile is replayed into the new index.
    init(library: URL, deviceID: String, beforeIndexSwap: (() -> Void)?) throws {
        self.library = library
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        blobs = try BlobStore(root: library.appendingPathComponent("blobs"))
        log = try EventLog(directory: library.appendingPathComponent("log"), deviceID: deviceID)
        let indexURL = library.appendingPathComponent("index.sqlite")
        var opened: SearchIndex?
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do { opened = try SearchIndex(path: indexURL) } catch SearchIndex.IndexError.outdated { opened = nil }
        }
        if let opened {
            index = opened
        } else if !Self.logHasEvents(library.appendingPathComponent("log")) {
            index = try SearchIndex(path: indexURL)   // brand-new library: nothing to replay
        } else {
            index = try SearchIndex(inMemory: true)
            building = true
            startRebuild(beforeSwap: beforeIndexSwap)
        }
    }

    private static func logHasEvents(_ directory: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { name in
            name.hasSuffix(".jsonl") && ((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size]) as? Int ?? 0) > 0
        }
    }

    public var isIndexing: Bool { locked { building } }
    public var indexingProgress: Double { locked { buildProgress } }
    public var indexingError: String? { locked { buildFailure } }

    private func startRebuild(beforeSwap: (() -> Void)?) {
        let library = library
        let offsets = EventLog.fileSizes(directory: library.appendingPathComponent("log"))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let built = library.appendingPathComponent("index.sqlite.building")
            do {
                _ = try IndexBuilder.rebuild(library: library, indexURL: built) { done, total in
                    self?.setProgress(total == 0 ? 1 : Double(done) / Double(total))
                }
                beforeSwap?()
                try self?.finishRebuild(from: built, logOffsets: offsets)
            } catch {
                self?.failRebuild(error)
            }
        }
    }

    private func setProgress(_ value: Double) { locked { buildProgress = value } }

    private func failRebuild(_ error: Error) {
        locked { buildFailure = error.localizedDescription; building = false }
    }

    private func finishRebuild(from built: URL, logOffsets: [String: Int]) throws {
        try locked {
            let target = library.appendingPathComponent("index.sqlite")
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: target.path + suffix) }
            try FileManager.default.moveItem(at: built, to: target)
            index = try SearchIndex(path: target)
            try catchUp(after: logOffsets)
            building = false
            buildProgress = 1
        }
    }

    /// Applies events appended after the rebuild started (by log position, not by time, so late-arriving events count too).
    private func catchUp(after offsets: [String: Int]) throws {
        let logDirectory = library.appendingPathComponent("log")
        let recent = try EventLog.readAllStamped(directory: logDirectory, after: offsets)
        guard !recent.isEmpty else { return }
        let events = try EventLog.readAllStamped(directory: logDirectory)
        let state = LibraryState.fold(events)
        var touched = Set<String>(), boardIDs = Set<String>(), appIDs = Set<String>()
        for stamped in recent {
            switch stamped.event {
            case .put(let r): touched.insert(r.id)
            case .delete(let id), .restore(let id), .purge(let id): touched.insert(id)
            case .board(let b): boardIDs.insert(b.id)
            case .app(let a): appIDs.insert(a.bundleID)
            }
        }
        for id in appIDs { if let app = state.apps[id] { try index.upsertApp(app) } }
        for id in boardIDs { if let board = state.boards[id] { try index.upsertBoard(board) } }
        for id in touched {
            guard let record = state.records[id] else { try index.removeDocument(id: id); continue }
            let appName = try record.appBundleID.flatMap { try index.app(bundleID: $0)?.name }
            try index.upsert(SearchDocument(id: id, title: record.title, text: RecordText.text(for: record, blobs: blobs),
                                            appName: appName, copiedAt: record.copiedAt, board: record.board,
                                            boardOrder: record.boardOrder, record: record, deletedAt: state.deleted[id]))
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
                return try commit(existing.with(copiedAt: now, appBundleID: source.map { .some($0.bundleID) }, source: "capture"), at: now)
            }
            return try commit(draft, at: now)
        }
    }

    public func setTitle(_ id: String, to title: String, now: Double = Date().timeIntervalSince1970) throws {
        try locked {
            try requireReady()
            guard let record = try index.records(ids: [id]).first else { return }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            try commit(record.with(title: .some(trimmed.isEmpty ? nil : trimmed)), at: now)
        }
    }

    /// Copies an item onto a pinboard, appended at the end. The original stays in history, as in Paste.
    @discardableResult
    public func pin(_ id: String, to board: String, now: Double = Date().timeIntervalSince1970) throws -> ClipRecord {
        try locked {
            try requireReady()
            guard let record = try index.records(ids: [id]).first else { throw LibraryError.unknownRecord(id) }
            let order = try index.nextBoardOrder(board)
            return try commit(record.with(id: "cx:" + UUID().uuidString, board: .some(board), boardOrder: .some(order), source: "pin"), at: now)
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

    // MARK: trash and editing

    /// Moves a clip to the trash. It stays recoverable until `purgeExpired` removes it after the retention window.
    public func delete(_ id: String, now: Double = Date().timeIntervalSince1970) throws {
        try locked {
            try requireReady()
            guard try index.records(ids: [id]).first != nil else { return }
            try log.append(.delete(id), at: now); try log.sync()
            try index.setDeleted(id: id, at: now)
        }
    }

    /// Brings a clip back. A pinboard copy whose pinboard is gone returns to history instead.
    public func restore(_ id: String, now: Double = Date().timeIntervalSince1970) throws {
        try locked {
            try requireReady()
            guard let record = try index.records(ids: [id]).first else { return }
            if let boardID = record.board {
                let board = try index.board(id: boardID)
                if board == nil || board?.deletedAt != nil {
                    try commit(record.with(board: .some(nil), boardOrder: .some(nil)), at: now)
                }
            }
            try log.append(.restore(id), at: now); try log.sync()
            try index.setDeleted(id: id, at: nil)
        }
    }

    public func trash(limit: Int, offset: Int = 0) throws -> [ClipRecord] {
        try locked { try index.recentRecords(scope: .trash, limit: limit, offset: offset) }
    }

    /// Permanently removes clips that have been in the trash longer than `days`. Blobs stay in the store.
    @discardableResult
    public func purgeExpired(olderThanDays days: Int = 90, now: Double = Date().timeIntervalSince1970) throws -> Int {
        try locked {
            let ids = try index.expiredTrashIDs(before: now - Double(days) * 86_400)
            for id in ids {
                try log.append(.purge(id), at: now)
                try index.removeDocument(id: id)
            }
            try log.sync()
            return ids.count
        }
    }

    /// Replaces the text of a clip. Stale rich-text variants are dropped from the record; every old blob stays in the store.
    @discardableResult
    public func edit(_ id: String, text: String, now: Double = Date().timeIntervalSince1970) throws -> ClipRecord {
        try locked {
            try requireReady()
            guard let record = try index.records(ids: [id]).first else { throw LibraryError.unknownRecord(id) }
            let stale: Set<String> = ["public.utf8-plain-text", "public.utf16-external-plain-text", "public.text", "public.html",
                                      "public.rtf", "com.apple.flat-rtfd"]
            let data = Data(text.utf8)
            let kept = record.representations.filter { !stale.contains($0.uti) }
            let reps = kept + [Representation(uti: "public.utf8-plain-text", blob: try blobs.put(data), size: data.count, item: 0)]
            return try commit(record.with(representations: reps, source: "edit"), at: now)
        }
    }

    // MARK: pinboard management

    public func renameBoard(_ id: String, to name: String, now: Double = Date().timeIntervalSince1970) throws {
        try updateBoard(id, now: now) { $0.with(name: name) }
    }

    public func recolorBoard(_ id: String, colorCode: UInt32, now: Double = Date().timeIntervalSince1970) throws {
        let blob = try blobs.put(try JSONSerialization.data(withJSONObject: ["type": "pinboard", "colorCode": colorCode], options: [.sortedKeys]))
        try updateBoard(id, now: now) { $0.with(attributesBlob: .some(blob)) }
    }

    /// Deletes a pinboard. Its clips go to the trash with it, so nothing is lost for the retention window.
    public func deleteBoard(_ id: String, now: Double = Date().timeIntervalSince1970) throws {
        try locked {
            try requireReady()
            for record in try index.recentRecords(scope: .board(id), limit: 100_000) { try delete(record.id, now: now) }
            try updateBoard(id, now: now) { $0.with(deletedAt: .some(now)) }
        }
    }

    /// Moves a pinboard to a new position among the active pinboards. The history view always stays first.
    public func moveBoard(_ id: String, toIndex target: Int, now: Double = Date().timeIntervalSince1970) throws {
        try locked {
            try requireReady()
            var ordered = try index.boards()
            guard let from = ordered.firstIndex(where: { $0.id == id }), ordered[from].kind != 1 else { return }
            let board = ordered.remove(at: from)
            ordered.insert(board, at: min(max(target, 0), ordered.count))
            for (position, item) in ordered.enumerated() where item.index != position {
                let moved = item.with(index: position)
                try log.append(.board(moved), at: now)
                try index.upsertBoard(moved)
            }
            try log.sync()
        }
    }

    private func updateBoard(_ id: String, now: Double, _ change: (BoardRecord) -> BoardRecord) throws {
        try locked {
            try requireReady()
            guard let board = try index.board(id: id) else { return }
            let updated = change(board)
            try log.append(.board(updated), at: now); try log.sync()
            try index.upsertBoard(updated)
        }
    }

    public func records(ids: [String]) throws -> [ClipRecord] { try locked { try index.records(ids: ids) } }

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

    public enum LibraryError: Error, Equatable { case unknownRecord(String), indexing }

    /// Changes that need an existing record cannot run while the index is still being rebuilt.
    private func requireReady() throws { if building { throw LibraryError.indexing } }

    @discardableResult
    private func commit(_ record: ClipRecord, at: Double = Date().timeIntervalSince1970) throws -> ClipRecord {
        try log.append(.put(record), at: at); try log.sync()
        let name = try record.appBundleID.flatMap { try index.app(bundleID: $0)?.name }
        try index.upsert(SearchDocument(id: record.id, title: record.title, text: RecordText.text(for: record, blobs: blobs),
                                        appName: name, copiedAt: record.copiedAt, board: record.board,
                                        boardOrder: record.boardOrder, record: record, deletedAt: try index.deletedAt(id: record.id)))
        return record
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    /// The pseudo-board id the UI uses for the trash view.
    public static let trashBoardID = "trash"

    private static func scope(_ board: String?) -> SearchScope {
        guard let board, board != "sharedPasteboardHistory" else { return .history }
        return board == trashBoardID ? .trash : .board(board)
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
