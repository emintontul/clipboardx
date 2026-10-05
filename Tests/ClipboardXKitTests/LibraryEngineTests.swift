import XCTest
@testable import ClipboardXKit

final class LibraryEngineTests: XCTestCase {
    private var dir: URL!
    private var engine: LibraryEngine!
    private let terminal = SourceApp(bundleID: "com.apple.Terminal", name: "Terminal", iconPNG: Data([0x89, 0x50]))

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        engine = try LibraryEngine(library: dir, deviceID: "dev1")
    }

    override func tearDownWithError() throws { engine = nil; try? FileManager.default.removeItem(at: dir) }

    private func textItem(_ s: String) -> [PasteboardItem] {
        [PasteboardItem(types: ["public.utf8-plain-text"], dataByType: ["public.utf8-plain-text": Data(s.utf8)])]
    }

    func testCaptureStoresPayloadAndShowsFirstInHistory() throws {
        let rec = try XCTUnwrap(try engine.capture(items: textItem("hello world"), source: terminal, now: 100))
        XCTAssertEqual(try engine.recent(board: nil, limit: 10).map(\.id), [rec.id])
        XCTAssertEqual(try engine.payload(of: rec), textItem("hello world"))
        XCTAssertEqual(engine.text(of: rec), "hello world")
        XCTAssertEqual(rec.appBundleID, "com.apple.Terminal")
    }

    func testSameContentBumpsInsteadOfDuplicating() throws {
        let a = try XCTUnwrap(try engine.capture(items: textItem("same"), source: terminal, now: 100))
        _ = try engine.capture(items: textItem("other"), source: terminal, now: 200)
        let again = try XCTUnwrap(try engine.capture(items: textItem("same"), source: terminal, now: 300))
        XCTAssertEqual(again.id, a.id)
        let recent = try engine.recent(board: nil, limit: 10)
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent.first?.id, a.id)
        XCTAssertEqual(recent.first?.copiedAt, 300)
        XCTAssertEqual(recent.first?.createdAt, 100)
    }

    func testRenameMakesItSearchableByNewTitle() throws {
        let rec = try XCTUnwrap(try engine.capture(items: textItem("ssh deploy@host"), source: terminal, now: 1))
        try engine.setTitle(rec.id, to: "ToggLite")
        XCTAssertEqual(try engine.search("Togg Lite", board: nil, limit: 5).map(\.id), [rec.id])
        XCTAssertEqual(try engine.search("Togg Lite", board: nil, limit: 5).first?.title, "ToggLite")
    }

    func testPinCopiesToBoardInOrderAndKeepsHistory() throws {
        try engine.addBoard(id: "list:ssh", name: "SSH")
        let a = try XCTUnwrap(try engine.capture(items: textItem("alpha"), source: terminal, now: 1))
        let b = try XCTUnwrap(try engine.capture(items: textItem("beta"), source: terminal, now: 2))
        let pinnedB = try engine.pin(b.id, to: "list:ssh")
        let pinnedA = try engine.pin(a.id, to: "list:ssh")
        XCTAssertNotEqual(pinnedB.id, b.id)
        XCTAssertEqual(try engine.recent(board: nil, limit: 10).count, 2)
        XCTAssertEqual(try engine.recent(board: "list:ssh", limit: 10).map(\.id), [pinnedB.id, pinnedA.id])
        XCTAssertEqual(try engine.search("alpha", board: "list:ssh", limit: 5).count, 1)
        XCTAssertEqual(try engine.search("alpha", board: nil, limit: 5).map(\.id), [a.id])
    }

    func testBoardKeepsItsColor() throws {
        try engine.addBoard(id: "list:blue", name: "Blue", colorCode: 0xFF0A84FF)
        try engine.addBoard(id: "list:none", name: "Plain")
        let boards = try engine.boards()
        XCTAssertEqual(engine.boardColorCode(try XCTUnwrap(boards.first { $0.id == "list:blue" })), 0xFF0A84FF)
        XCTAssertNil(engine.boardColorCode(try XCTUnwrap(boards.first { $0.id == "list:none" })))
    }

    func testBoardColorSurvivesIndexRebuild() throws {
        try engine.addBoard(id: "list:blue", name: "Blue", colorCode: 0xFF0A84FF)
        engine = nil
        _ = try IndexBuilder.rebuild(library: dir)
        engine = try LibraryEngine(library: dir, deviceID: "dev1")
        XCTAssertEqual(engine.boardColorCode(try XCTUnwrap(try engine.boards().first { $0.id == "list:blue" })), 0xFF0A84FF)
    }

    func testBoardCanBeRenamedRecoloredAndReordered() throws {
        try engine.addBoard(id: "list:one", name: "One", colorCode: 0xFFFF453A)
        try engine.addBoard(id: "list:two", name: "Two", colorCode: 0xFF32D74B)
        try engine.addBoard(id: "list:three", name: "Three", colorCode: 0xFF0A84FF)

        try engine.renameBoard("list:two", to: "Second")
        try engine.setBoardColor("list:two", to: 0xFFBF5AF2)
        try engine.moveBoard("list:three", by: -2)

        let boards = try engine.boards()
        XCTAssertEqual(boards.map(\.id), ["list:three", "list:one", "list:two"])
        XCTAssertEqual(boards.last?.name, "Second")
        XCTAssertEqual(engine.boardColorCode(try XCTUnwrap(boards.last)), 0xFFBF5AF2)

        engine = nil
        _ = try IndexBuilder.rebuild(library: dir)
        engine = try LibraryEngine(library: dir, deviceID: "dev1")
        XCTAssertEqual(try engine.boards().map(\.id), ["list:three", "list:one", "list:two"])
        XCTAssertEqual(try engine.boards().last?.name, "Second")
    }

    func testBoardRenameRequiresNameAndMoveClampsAtEnds() throws {
        try engine.addBoard(id: "list:one", name: "One")
        try engine.addBoard(id: "list:two", name: "Two")

        XCTAssertThrowsError(try engine.renameBoard("list:one", to: " \n "))
        try engine.moveBoard("list:one", by: Int.min)
        try engine.moveBoard("list:two", by: Int.max)

        XCTAssertEqual(try engine.boards().map(\.id), ["list:one", "list:two"])
    }

    func testDeletingBoardReturnsClipsToHistoryAndSurvivesRebuild() throws {
        try engine.addBoard(id: "list:links", name: "Links")
        let original = try XCTUnwrap(try engine.capture(items: textItem("https://example.com"), source: terminal, now: 10))
        let pinned = try engine.pin(original.id, to: "list:links")
        XCTAssertEqual(try engine.recent(board: "list:links", limit: 10).map(\.id), [pinned.id])

        try engine.deleteBoard("list:links")

        XCTAssertFalse(try engine.boards().contains { $0.id == "list:links" })
        XCTAssertTrue(try engine.recent(board: "list:links", limit: 10).isEmpty)
        XCTAssertEqual(Set(try engine.recent(board: nil, limit: 10).map(\.id)), Set([original.id, pinned.id]))
        XCTAssertEqual(engine.text(of: try XCTUnwrap(try engine.recent(board: nil, limit: 10).first { $0.id == pinned.id })), "https://example.com")

        engine = nil
        _ = try IndexBuilder.rebuild(library: dir)
        engine = try LibraryEngine(library: dir, deviceID: "dev1")
        XCTAssertFalse(try engine.boards().contains { $0.id == "list:links" })
        XCTAssertEqual(Set(try engine.recent(board: nil, limit: 10).map(\.id)), Set([original.id, pinned.id]))
        XCTAssertEqual(engine.text(of: try XCTUnwrap(try engine.recent(board: nil, limit: 10).first { $0.id == pinned.id })), "https://example.com")
    }

    func testBoardsAndAppIconsAreAvailable() throws {
        try engine.addBoard(id: "list:codes", name: "Codes")
        _ = try engine.capture(items: textItem("x"), source: terminal, now: 1)
        XCTAssertTrue(try engine.boards().contains { $0.name == "Codes" })
        XCTAssertEqual(try engine.app(bundleID: "com.apple.Terminal")?.name, "Terminal")
        XCTAssertEqual(try engine.iconData(bundleID: "com.apple.Terminal"), Data([0x89, 0x50]))
    }

    func testRebuildFromLogReproducesEditedState() throws {
        let rec = try XCTUnwrap(try engine.capture(items: textItem("keep me"), source: terminal, now: 1))
        try engine.setTitle(rec.id, to: "Named")
        _ = try engine.capture(items: textItem("keep me"), source: terminal, now: 5)
        engine = nil
        _ = try IndexBuilder.rebuild(library: dir)
        engine = try LibraryEngine(library: dir, deviceID: "dev1")
        let recent = try engine.recent(board: nil, limit: 10)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.title, "Named")
        XCTAssertEqual(recent.first?.copiedAt, 5)
        XCTAssertEqual(try engine.app(bundleID: "com.apple.Terminal")?.name, "Terminal")
    }

    func testImageItemKeepsBytesAndHasImageData() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let item = PasteboardItem(types: ["public.png"], dataByType: ["public.png": png])
        let rec = try XCTUnwrap(try engine.capture(items: [item], source: terminal, now: 1))
        XCTAssertEqual(engine.imageData(of: rec), png)
        XCTAssertEqual(engine.text(of: rec), "")
    }

    func testEmptyItemsAreNotCaptured() throws {
        XCTAssertNil(try engine.capture(items: [], source: terminal, now: 1))
        XCTAssertNil(try engine.capture(items: textItem("   \n"), source: terminal, now: 1))
    }

    func testCaptureSurvivesReopenWithoutRebuild() throws {
        let rec = try XCTUnwrap(try engine.capture(items: textItem("persist"), source: terminal, now: 1))
        engine = nil
        engine = try LibraryEngine(library: dir, deviceID: "dev1")
        XCTAssertEqual(try engine.recent(board: nil, limit: 10).map(\.id), [rec.id])
    }
}
