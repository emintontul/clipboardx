import AppKit
import ClipboardXKit

struct ShelfCard: Identifiable {
    let record: ClipRecord
    let appName: String?
    var id: String { record.id }
}

enum BoardPalette {
    static let colors: [(name: String, code: UInt32)] = [
        ("Red", 0xFFFF453A), ("Orange", 0xFFFF9F0A), ("Yellow", 0xFFFFD60A), ("Green", 0xFF32D74B),
        ("Blue", 0xFF0A84FF), ("Purple", 0xFFBF5AF2), ("Gray", 0xFF8E8E93),
    ]
    static func next(after count: Int) -> UInt32 { colors[count % colors.count].code }
}

/// State behind the shelf. Everything runs on the main thread; queries take a few milliseconds.
final class ShelfModel: ObservableObject {
    static let historyID = "sharedPasteboardHistory"
    static let trashID = LibraryEngine.trashBoardID
    let engine: LibraryEngine
    let settings: AppSettings
    @Published var query = "" { didSet { if query != oldValue { reload(resetSelection: true) } } }
    @Published private(set) var boards: [BoardRecord] = []
    @Published private(set) var boardIndex = 0
    @Published private(set) var cards: [ShelfCard] = []
    @Published var selection: String?
    @Published var renamingID: String?
    @Published var editingID: String?
    @Published var editText = ""
    @Published var renamingBoardID: String?
    @Published var pendingPinClipID: String?
    @Published private(set) var statusLine = ""
    @Published private(set) var boardColors: [String: UInt32] = [:]
    @Published var addingBoard = false
    @Published private(set) var indexing = false
    @Published private(set) var indexingProgress = 0.0
    private var limit = 60
    private var indexTimer: Timer?
    var onPaste: ((ClipRecord, Bool) -> Void)?
    var onOpenSettings: (() -> Void)?

    init(engine: LibraryEngine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
        refreshBoards()
        reload(resetSelection: true)
        watchIndexing()
    }

    var currentBoard: BoardRecord? { boards.indices.contains(boardIndex) ? boards[boardIndex] : nil }
    var inTrash: Bool { currentBoard?.id == Self.trashID }

    /// While the index is rebuilt in the background the shelf shows progress, then fills itself in.
    private func watchIndexing() {
        guard engine.isIndexing else { return }
        indexing = true
        indexTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.indexingProgress = self.engine.indexingProgress
            if !self.engine.isIndexing {
                timer.invalidate()
                self.indexing = false
                self.refreshBoards()
                self.reload(resetSelection: true)
            }
        }
    }

    func refreshBoards() {
        var list = (try? engine.boards()) ?? []
        if !list.contains(where: { $0.id == Self.historyID }) {
            list.insert(BoardRecord(id: Self.historyID, name: "Clipboard History", index: -1, kind: 1, createdAt: 0, attributesBlob: nil), at: 0)
        }
        list.append(BoardRecord(id: Self.trashID, name: "Recently Deleted", index: Int.max, kind: 3, createdAt: 0, attributesBlob: nil))
        boards = list
        boardColors = Dictionary(uniqueKeysWithValues: list.compactMap { board in engine.boardColorCode(board).map { (board.id, $0) } })
        boardIndex = min(boardIndex, max(list.count - 1, 0))
    }

    func selectBoard(_ index: Int) {
        guard boards.indices.contains(index), index != boardIndex else { return }
        boardIndex = index
        limit = 60
        reload(resetSelection: true)
    }

    func switchBoard(by delta: Int) {
        guard !boards.isEmpty else { return }
        selectBoard((boardIndex + delta + boards.count) % boards.count)
    }

    func reload(resetSelection: Bool) {
        let board = currentBoard?.id
        let records: [ClipRecord]
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            records = (try? engine.recent(board: board, limit: limit)) ?? []
        } else {
            records = (try? engine.search(query, board: board, limit: limit)) ?? []
        }
        cards = records.map { ShelfCard(record: $0, appName: $0.appBundleID.flatMap { (try? engine.app(bundleID: $0))?.name }) }
        if resetSelection || !cards.contains(where: { $0.id == selection }) { selection = cards.first?.id }
        statusLine = query.isEmpty ? "" : "\(cards.count) result\(cards.count == 1 ? "" : "s")"
    }

    /// Called when the end of the strip scrolls into view.
    func loadMoreIfNeeded(after card: ShelfCard) {
        guard card.id == cards.last?.id, cards.count >= limit else { return }
        limit += 60
        reload(resetSelection: false)
    }

    func move(_ delta: Int) {
        guard !cards.isEmpty else { return }
        let current = cards.firstIndex { $0.id == selection } ?? 0
        selection = cards[min(max(current + delta, 0), cards.count - 1)].id
    }

    func pasteSelected(plain: Bool) {
        guard let card = cards.first(where: { $0.id == selection }) else { return }
        onPaste?(card.record, plain || settings.alwaysPlainText)
    }

    func paste(at index: Int, plain: Bool) {
        guard cards.indices.contains(index) else { return }
        onPaste?(cards[index].record, plain || settings.alwaysPlainText)
    }

    // MARK: clips

    func rename(_ id: String, to title: String) {
        try? engine.setTitle(id, to: title)
        renamingID = nil
        reload(resetSelection: false)
    }

    func edit(_ id: String, text: String) {
        _ = try? engine.edit(id, text: text)
        editingID = nil
        reload(resetSelection: false)
    }

    func beginEdit(_ id: String) {
        guard let card = cards.first(where: { $0.id == id }), canEdit(card.record) else { return }
        editText = engine.text(of: card.record)
        editingID = id
    }

    func editSelected() { if let id = selection { beginEdit(id) } }

    func canEdit(_ record: ClipRecord) -> Bool {
        record.representations.contains { $0.uti == "public.utf8-plain-text" } && !inTrash
    }

    func deleteSelected() { if let id = selection { delete(id) } }

    func delete(_ id: String) {
        guard !inTrash else { return }
        let next = neighbor(of: id)
        try? engine.delete(id)
        reload(resetSelection: false)
        selection = next
    }

    func restore(_ id: String) {
        let next = neighbor(of: id)
        try? engine.restore(id)
        reload(resetSelection: false)
        selection = next
    }

    private func neighbor(of id: String) -> String? {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return selection }
        return cards.indices.contains(i + 1) ? cards[i + 1].id : (i > 0 ? cards[i - 1].id : nil)
    }

    func pin(_ id: String, to board: BoardRecord) {
        _ = try? engine.pin(id, to: board.id)
        refreshBoards()
    }

    // MARK: pinboards

    /// Creates a pinboard; when a clip is waiting (from "Create Pinboard…" in the Pin menu) it is pinned to the new board.
    func addBoard(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        addingBoard = false
        let waiting = pendingPinClipID
        pendingPinClipID = nil
        guard !trimmed.isEmpty else { return }
        let id = "list:" + UUID().uuidString
        try? engine.addBoard(id: id, name: trimmed, colorCode: BoardPalette.next(after: boards.count))
        if let waiting { _ = try? engine.pin(waiting, to: id) }
        refreshBoards()
        if let index = boards.firstIndex(where: { $0.id == id }) { selectBoard(index) }
    }

    func renameBoard(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingBoardID = nil
        guard !trimmed.isEmpty else { return }
        try? engine.renameBoard(id, to: trimmed)
        refreshBoards()
    }

    func recolorBoard(_ id: String, code: UInt32) {
        try? engine.recolorBoard(id, colorCode: code)
        refreshBoards()
    }

    func deleteBoard(_ id: String) {
        try? engine.deleteBoard(id)
        refreshBoards()
        selectBoard(0)
        reload(resetSelection: true)
    }

    func moveBoard(_ id: String, by delta: Int) {
        let active = boards.filter { $0.id != Self.trashID }
        guard let from = active.firstIndex(where: { $0.id == id }) else { return }
        try? engine.moveBoard(id, toIndex: from + delta)
        refreshBoards()
    }

    func resetForShow() {
        query = ""
        limit = 60
        boardIndex = 0
        renamingID = nil
        editingID = nil
        renamingBoardID = nil
        refreshBoards()
        reload(resetSelection: true)
    }
}
