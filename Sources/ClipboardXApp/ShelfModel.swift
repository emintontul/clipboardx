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

enum DatePreset: String, CaseIterable, Identifiable {
    case today = "Today", yesterday = "Yesterday", lastWeek = "Last week", lastMonth = "Last month"
    var id: String { rawValue }
    var symbol: String { "calendar" }

    /// The `[after, before)` window in seconds since 1970.
    func range(now: Date = Date(), calendar: Calendar = .current) -> (after: Double, before: Double?) {
        let start = calendar.startOfDay(for: now)
        func back(_ days: Int) -> Double { (calendar.date(byAdding: .day, value: -days, to: start) ?? start).timeIntervalSince1970 }
        switch self {
        case .today: return (start.timeIntervalSince1970, nil)
        case .yesterday: return (back(1), start.timeIntervalSince1970)
        case .lastWeek: return (back(7), nil)
        case .lastMonth: return (back(30), nil)
        }
    }
}

struct FilterSuggestion: Identifiable {
    enum Kind { case kind(ClipKind), app(String), date(DatePreset) }
    let kind: Kind
    let title: String
    let symbol: String
    var id: String { title + symbol }
}

extension ClipKind {
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .text: return "text.alignleft"; case .link: return "link"; case .image: return "photo"; case .file: return "doc" }
    }
}

/// State behind the shelf. Everything runs on the main thread; queries take a few milliseconds.
final class ShelfModel: ObservableObject {
    static let historyID = "sharedPasteboardHistory"
    static let trashID = LibraryEngine.trashBoardID
    static let stackID = "stack"
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
    @Published var kindFilters: Set<ClipKind> = [] { didSet { reload(resetSelection: true) } }
    @Published var appFilter: String? { didSet { reload(resetSelection: true) } }
    @Published var datePreset: DatePreset? { didSet { reload(resetSelection: true) } }
    @Published var shelfHeight: CGFloat = 276
    @Published var quickLookID: String?
    @Published private(set) var linkVersion = 0
    var linkService: LinkPreviewService?
    @Published private(set) var stack = PasteStack()
    var onStackChanged: ((PasteStack) -> Void)?
    @Published private(set) var appsInUse: [AppRecord] = []
    private var limit = 60
    private var indexTimer: Timer?
    var onResizeDrag: (() -> Void)?
    var onResizeEnd: (() -> Void)?
    var onCopy: ((ClipRecord) -> Void)?

    static let expandedThreshold: CGFloat = 330
    var expanded: Bool { shelfHeight >= Self.expandedThreshold }
    var cardHeight: CGFloat { min(max(190, shelfHeight - 78), 380) }
    /// Cards stay square at every shelf height, so a taller shelf gives bigger cards, never tall narrow ones.
    var cardWidth: CGFloat { cardHeight }
    var hasFilters: Bool { !kindFilters.isEmpty || appFilter != nil || datePreset != nil }
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
    var inStack: Bool { currentBoard?.id == Self.stackID }

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
        if stack.isActive {
            list.insert(BoardRecord(id: Self.stackID, name: "Paste Stack", index: -1, kind: 4, createdAt: 0, attributesBlob: nil), at: 1)
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

    /// Chip filters plus anything typed as `type:link`, `app:Safari`, `last week`…, merged.
    private func effective() -> (text: String, filters: ClipFilters) {
        let parsed = QueryParser.parse(query)
        var f = ClipFilters(kinds: kindFilters.union(parsed.filters.kinds), appName: parsed.filters.appName ?? appFilter,
                            after: parsed.filters.after, before: parsed.filters.before)
        if let preset = datePreset {
            let r = preset.range()
            f.after = max(f.after ?? r.after, r.after)
            f.before = [f.before, r.before].compactMap { $0 }.min()
        }
        return (parsed.text, f)
    }

    func reload(resetSelection: Bool) {
        let board = currentBoard?.id
        let (text, f) = effective()
        let records: [ClipRecord]
        if board == Self.stackID {
            records = (try? engine.records(ids: stack.ids)) ?? []
        } else if text.trimmingCharacters(in: .whitespaces).isEmpty {
            records = (try? engine.recent(board: board, limit: limit, filters: f)) ?? []
        } else {
            records = (try? engine.search(text, board: board, limit: limit, filters: f)) ?? []
        }
        cards = records.map { ShelfCard(record: $0, appName: $0.appBundleID.flatMap { (try? engine.app(bundleID: $0))?.name }) }
        if resetSelection || !cards.contains(where: { $0.id == selection }) { selection = cards.first?.id }
        statusLine = (query.isEmpty && !hasFilters) ? "" : "\(cards.count) result\(cards.count == 1 ? "" : "s")"
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

    // MARK: filters and suggestions

    /// Completions for the word being typed: date phrases ("L" gives Last week, Last month), types and apps.
    var suggestions: [FilterSuggestion] {
        let words = query.split(separator: " ").map(String.init)
        guard let last = words.last, !query.hasSuffix(" ") else { return [] }
        let two = words.count >= 2 ? (words[words.count - 2] + " " + last).lowercased() : ""
        let one = last.lowercased()
        var out: [FilterSuggestion] = []
        for preset in DatePreset.allCases where preset.rawValue.lowercased().hasPrefix(one) || (!two.isEmpty && preset.rawValue.lowercased().hasPrefix(two)) {
            out.append(FilterSuggestion(kind: .date(preset), title: preset.rawValue, symbol: preset.symbol))
        }
        for kind in ClipKind.allCases where kind.rawValue.hasPrefix(one) {
            out.append(FilterSuggestion(kind: .kind(kind), title: kind.title, symbol: kind.symbol))
        }
        if one.count >= 2 {
            for app in appsInUse where app.name.lowercased().hasPrefix(one) {
                out.append(FilterSuggestion(kind: .app(app.name), title: app.name, symbol: "app"))
            }
        }
        return Array(out.prefix(6))
    }

    func apply(_ suggestion: FilterSuggestion) {
        var words = query.split(separator: " ").map(String.init)
        if case .date = suggestion.kind, words.count >= 2, suggestion.title.lowercased().hasPrefix((words[words.count - 2] + " " + words[words.count - 1]).lowercased()) {
            words.removeLast(2)
        } else if !words.isEmpty { words.removeLast() }
        query = words.joined(separator: " ")
        switch suggestion.kind {
        case .kind(let k): kindFilters.insert(k)
        case .app(let name): appFilter = name
        case .date(let preset): datePreset = preset
        }
    }

    func clearFilters() { kindFilters = []; appFilter = nil; datePreset = nil }

    /// Backspace on an empty search field removes the last chip. Returns whether it did.
    func removeLastFilter() -> Bool {
        if datePreset != nil { datePreset = nil } else if appFilter != nil { appFilter = nil }
        else if let kind = kindFilters.sorted(by: { $0.rawValue < $1.rawValue }).last { kindFilters.remove(kind) } else { return false }
        return true
    }

    /// Loads the app list off the main thread, so opening the shelf never waits for it.
    func refreshApps() {
        DispatchQueue.global(qos: .userInitiated).async { [engine, weak self] in
            let apps = (try? engine.appsInUse()) ?? []
            DispatchQueue.main.async { self?.appsInUse = apps }
        }
    }

    // MARK: paste stack

    func toggleStack() {
        if stack.isActive { stack.stop() } else { stack.start() }
        stackDidChange()
        if stack.isActive, let index = boards.firstIndex(where: { $0.id == Self.stackID }) { selectBoard(index) }
    }

    /// Called for every new copy: while the stack is active it joins the end of the queue.
    func enqueueToStack(_ id: String) {
        guard stack.isActive else { return }
        stack.enqueue(id)
        stackDidChange()
    }

    /// After a paste from the Paste Stack view, that clip leaves the queue.
    func didPaste(_ record: ClipRecord) {
        guard inStack else { return }
        stack.remove(record.id)
        stackDidChange()
    }

    private func stackDidChange() {
        let wasInStack = inStack
        refreshBoards()
        if wasInStack, !stack.isActive { boardIndex = 0 }
        reload(resetSelection: !(wasInStack && stack.isActive))
        onStackChanged?(stack)
    }

    /// A link preview arrived: cards reload their previews.
    func linkPreviewUpdated() {
        PreviewStore.shared.invalidateAll()
        linkVersion += 1
    }

    // MARK: quick look and copy

    func toggleQuickLook() {
        if quickLookID != nil { quickLookID = nil } else { quickLookID = selection }
    }

    /// Esc closes Quick Look first; returns whether it was open.
    func closeQuickLook() -> Bool {
        guard quickLookID != nil else { return false }
        quickLookID = nil
        return true
    }

    func copy(_ record: ClipRecord) { onCopy?(record) }

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
        quickLookID = nil
        kindFilters = []; appFilter = nil; datePreset = nil
        refreshBoards()
        if stack.isActive, let index = boards.firstIndex(where: { $0.id == Self.stackID }) { boardIndex = index }
        refreshApps()
        reload(resetSelection: true)
    }
}
