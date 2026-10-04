import AppKit
import ClipboardXKit

struct ShelfCard: Identifiable {
    let record: ClipRecord
    let appName: String?
    var id: String { record.id }
}

/// State behind the shelf. Everything runs on the main thread; queries take a few milliseconds.
final class ShelfModel: ObservableObject {
    static let historyID = "sharedPasteboardHistory"
    let engine: LibraryEngine
    let settings: AppSettings
    @Published var query = "" { didSet { if query != oldValue { reload(resetSelection: true) } } }
    @Published private(set) var boards: [BoardRecord] = []
    @Published private(set) var boardIndex = 0
    @Published private(set) var cards: [ShelfCard] = []
    @Published var selection: String?
    @Published var renamingID: String?
    @Published private(set) var statusLine = ""
    @Published private(set) var boardColors: [String: UInt32] = [:]
    @Published var addingBoard = false
    private var limit = 60
    var onPaste: ((ClipRecord, Bool) -> Void)?
    var onOpenSettings: (() -> Void)?

    init(engine: LibraryEngine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
        refreshBoards()
        reload(resetSelection: true)
    }

    var currentBoard: BoardRecord? { boards.indices.contains(boardIndex) ? boards[boardIndex] : nil }

    func refreshBoards() {
        var list = (try? engine.boards()) ?? []
        if !list.contains(where: { $0.id == Self.historyID }) {
            list.insert(BoardRecord(id: Self.historyID, name: "Clipboard History", index: -1, kind: 1, createdAt: 0, attributesBlob: nil), at: 0)
        }
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

    func rename(_ id: String, to title: String) {
        try? engine.setTitle(id, to: title)
        renamingID = nil
        reload(resetSelection: false)
    }

    func pin(_ id: String, to board: BoardRecord) {
        _ = try? engine.pin(id, to: board.id)
        refreshBoards()
    }

    func addBoard(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        addingBoard = false
        guard !trimmed.isEmpty else { return }
        try? engine.addBoard(id: "list:" + UUID().uuidString, name: trimmed)
        refreshBoards()
        selectBoard(boards.count - 1)
    }

    func resetForShow() {
        query = ""
        limit = 60
        boardIndex = 0
        renamingID = nil
        refreshBoards()
        reload(resetSelection: true)
    }
}
