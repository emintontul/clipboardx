import XCTest
import ClipboardXKit
@testable import ClipboardXApp

final class ShelfModelTests: XCTestCase {
    private var dir: URL!
    private var engine: LibraryEngine!
    private var model: ShelfModel!
    private let app = SourceApp(bundleID: "com.apple.Terminal", name: "Terminal", iconPNG: nil)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        engine = try LibraryEngine(library: dir, deviceID: "dev")
        model = ShelfModel(engine: engine, settings: AppSettings.shared)
    }

    override func tearDownWithError() throws {
        model = nil; engine = nil
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func copy(_ text: String, at now: Double) throws -> ClipRecord {
        let item = PasteboardItem(types: ["public.utf8-plain-text"], dataByType: ["public.utf8-plain-text": Data(text.utf8)])
        let record = try XCTUnwrap(try engine.capture(items: [item], source: app, now: now))
        model.reload(resetSelection: true)
        return record
    }

    // MARK: Paste Stack

    func testStackShowsClipsInCopyOrderAndPastingRemovesThem() throws {
        let a = try copy("first", at: 1), b = try copy("second", at: 2)
        model.toggleStack()
        XCTAssertTrue(model.stack.isActive)
        XCTAssertTrue(model.inStack, "starting the stack opens its view")
        let c = try copy("third", at: 3)
        model.enqueueToStack(a.id); model.enqueueToStack(b.id); model.enqueueToStack(c.id)
        XCTAssertEqual(model.cards.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(model.boards.first { $0.id == ShelfModel.stackID }?.name, "Paste Stack")

        var pasted: [String] = []
        model.onPaste = { [unowned model = model!] record, _ in pasted.append(record.id); model.didPaste(record) }
        model.pasteSelected(plain: false)
        XCTAssertEqual(pasted, [a.id])
        XCTAssertEqual(model.cards.map(\.id), [b.id, c.id])
        XCTAssertEqual(model.selection, b.id, "the next item is ready to paste")
    }

    func testEnqueueIsIgnoredWhileTheStackIsOff() throws {
        let a = try copy("x", at: 1)
        model.enqueueToStack(a.id)
        XCTAssertTrue(model.stack.ids.isEmpty)
        XCTAssertNil(model.boards.first { $0.id == ShelfModel.stackID })
    }

    func testEndingTheStackReturnsToHistory() throws {
        try copy("x", at: 1)
        model.toggleStack()
        XCTAssertTrue(model.inStack)
        model.toggleStack()
        XCTAssertFalse(model.stack.isActive)
        XCTAssertEqual(model.currentBoard?.id, ShelfModel.historyID)
        XCTAssertNil(model.boards.first { $0.id == ShelfModel.stackID })
    }

    func testStackChangeCallbackReportsTheCount() throws {
        var counts: [Int] = []
        model.onStackChanged = { counts.append($0.ids.count) }
        let a = try copy("x", at: 1)
        model.toggleStack(); model.enqueueToStack(a.id); model.toggleStack()
        XCTAssertEqual(counts, [0, 1, 0])
    }

    func testShowingTheShelfOpensTheStackWhenItIsActive() throws {
        try copy("x", at: 1)
        model.toggleStack()
        model.selectBoard(0)
        model.resetForShow()
        XCTAssertTrue(model.inStack)
    }

    // MARK: filters and search

    func testKindFilterAndTypedFilterNarrowTheCards() throws {
        try copy("plain note", at: 1)
        let link = try copy("https://swift.org/blog", at: 2)
        model.kindFilters = [.link]
        XCTAssertEqual(model.cards.map(\.id), [link.id])
        model.kindFilters = []
        XCTAssertEqual(model.cards.count, 2)
        model.query = "type:link"
        XCTAssertEqual(model.cards.map(\.id), [link.id], "typed filters work like chips")
    }

    func testSpacedQueryStillFindsTheClip() throws {
        let rec = try copy("ssh deploy@host", at: 1)
        try engine.setTitle(rec.id, to: "ToggLite", now: 2)
        model.reload(resetSelection: true)
        model.query = "Togg Lite"
        XCTAssertEqual(model.cards.map(\.id), [rec.id])
    }

    func testSuggestionsCompleteDatePhrasesAndTypes() throws {
        try copy("x", at: 1)
        model.query = "L"
        XCTAssertTrue(model.suggestions.map(\.title).contains("Last week"))
        XCTAssertTrue(model.suggestions.map(\.title).contains("Last month"))
        XCTAssertTrue(model.suggestions.map(\.title).contains("Link"))
        let lastWeek = try XCTUnwrap(model.suggestions.first { $0.title == "Last week" })
        model.apply(lastWeek)
        XCTAssertEqual(model.datePreset, .lastWeek)
        XCTAssertEqual(model.query, "")
    }

    func testBackspaceRemovesTheLastFilterChip() {
        model.kindFilters = [.link]
        model.appFilter = "Safari"
        XCTAssertTrue(model.removeLastFilter())
        XCTAssertNil(model.appFilter)
        XCTAssertTrue(model.removeLastFilter())
        XCTAssertTrue(model.kindFilters.isEmpty)
        XCTAssertFalse(model.removeLastFilter())
    }

    // MARK: trash and pinboards

    func testDeleteMovesToTrashViewAndRestoreBringsItBack() throws {
        let rec = try copy("to delete", at: 1)
        model.delete(rec.id)
        XCTAssertTrue(model.cards.isEmpty)
        model.selectBoard(model.boards.firstIndex { $0.id == ShelfModel.trashID }!)
        XCTAssertEqual(model.cards.map(\.id), [rec.id])
        model.restore(rec.id)
        XCTAssertTrue(model.cards.isEmpty)
        model.selectBoard(0)
        XCTAssertEqual(model.cards.map(\.id), [rec.id])
    }

    func testCreatingAPinboardFromAClipPinsIt() throws {
        let rec = try copy("keep this", at: 1)
        model.pendingPinClipID = rec.id
        model.addBoard(named: "Keepers")
        XCTAssertEqual(model.currentBoard?.name, "Keepers")
        XCTAssertEqual(model.cards.count, 1)
        XCTAssertNotNil(model.boardColors[model.currentBoard!.id], "new pinboards get a color")
    }

    func testDeletingAPinboardReturnsToHistory() throws {
        let rec = try copy("keep this", at: 1)
        model.pendingPinClipID = rec.id
        model.addBoard(named: "Temp")
        let id = try XCTUnwrap(model.currentBoard?.id)
        model.deleteBoard(id)
        XCTAssertEqual(model.currentBoard?.id, ShelfModel.historyID)
        XCTAssertFalse(model.boards.contains { $0.id == id })
    }

    func testCardsStaySquareAtEverySize() {
        for height in stride(from: 276.0, through: 460.0, by: 22) {
            model.shelfHeight = CGFloat(height)
            XCTAssertEqual(model.cardWidth, model.cardHeight)
            XCTAssertEqual(model.expanded, height >= 330)
        }
    }
}
