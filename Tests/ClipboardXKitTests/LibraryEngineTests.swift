import XCTest
import SQLite3
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

    func testBoardsAndAppIconsAreAvailable() throws {
        try engine.addBoard(id: "list:codes", name: "Codes")
        _ = try engine.capture(items: textItem("x"), source: terminal, now: 1)
        XCTAssertTrue(try engine.boards().contains { $0.name == "Codes" })
        XCTAssertEqual(try engine.app(bundleID: "com.apple.Terminal")?.name, "Terminal")
        XCTAssertEqual(try engine.iconData(bundleID: "com.apple.Terminal"), Data([0x89, 0x50]))
    }

    func testRebuildFromLogReproducesEditedState() throws {
        let rec = try XCTUnwrap(try engine.capture(items: textItem("keep me"), source: terminal, now: 1))
        try engine.setTitle(rec.id, to: "Named", now: 3)
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

    // MARK: background index rebuild

    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw XCTSkip("timed out waiting for condition") }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func makeIndexOutdated() {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("index.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version = 1", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
    }

    func testOutdatedIndexRebuildsInBackgroundAndKeepsCapturesMadeMeanwhile() throws {
        let early = try XCTUnwrap(try engine.capture(items: textItem("captured before upgrade"), source: terminal, now: 10))
        engine = nil
        makeIndexOutdated()
        let gate = DispatchSemaphore(value: 0)
        engine = try LibraryEngine(library: dir, deviceID: "dev1", beforeIndexSwap: { gate.wait() })
        XCTAssertTrue(engine.isIndexing)
        XCTAssertEqual(try engine.recent(board: nil, limit: 10).count, 0, "serves an empty placeholder while building")
        let during = try XCTUnwrap(try engine.capture(items: textItem("typed while indexing"), source: terminal, now: 20))
        gate.signal()
        try waitUntil { !engine.isIndexing }
        XCTAssertEqual(Set(try engine.recent(board: nil, limit: 10).map(\.id)), [early.id, during.id])
        XCTAssertEqual(try engine.search("indexing", board: nil, limit: 5).map(\.id), [during.id])
    }

    func testEditsAreRefusedWhileIndexingAndWorkAfterwards() throws {
        let rec = try XCTUnwrap(try engine.capture(items: textItem("will be trashed"), source: terminal, now: 10))
        engine = nil
        makeIndexOutdated()
        let gate = DispatchSemaphore(value: 0)
        engine = try LibraryEngine(library: dir, deviceID: "dev1", beforeIndexSwap: { gate.wait() })
        XCTAssertThrowsError(try engine.delete(rec.id, now: 30)) { error in
            XCTAssertEqual(error as? LibraryEngine.LibraryError, .indexing)
        }
        XCTAssertThrowsError(try engine.setTitle(rec.id, to: "x", now: 31))
        gate.signal()
        try waitUntil { !engine.isIndexing }
        try engine.delete(rec.id, now: 40)
        XCTAssertEqual(try engine.trash(limit: 10).map(\.id), [rec.id])
    }

    func testFreshLibraryIsNotIndexing() throws {
        XCTAssertFalse(engine.isIndexing)
    }

    // MARK: trash, edit, board management

    func testDeleteMovesToTrashAndHidesFromHistoryAndSearch() throws {
        let rec = try XCTUnwrap(try engine.capture(items: textItem("secret plan"), source: terminal, now: 100))
        try engine.delete(rec.id, now: 200)
        XCTAssertEqual(try engine.recent(board: nil, limit: 10).count, 0)
        XCTAssertEqual(try engine.search("secret", board: nil, limit: 5).count, 0)
        XCTAssertEqual(try engine.trash(limit: 10).map(\.id), [rec.id])
    }

    func testRestoreBringsItBack() throws {
        let rec = try XCTUnwrap(try engine.capture(items: textItem("keep"), source: terminal, now: 100))
        try engine.delete(rec.id, now: 200)
        try engine.restore(rec.id, now: 300)
        XCTAssertEqual(try engine.recent(board: nil, limit: 10).map(\.id), [rec.id])
        XCTAssertEqual(try engine.trash(limit: 10).count, 0)
    }

    func testPurgeExpiredRemovesOnlyOldTrash() throws {
        let day = 86_400.0
        let old = try XCTUnwrap(try engine.capture(items: textItem("old"), source: terminal, now: 1))
        let recent = try XCTUnwrap(try engine.capture(items: textItem("recent"), source: terminal, now: 2))
        let now = 200 * day
        try engine.delete(old.id, now: now - 100 * day)
        try engine.delete(recent.id, now: now - 10 * day)
        XCTAssertEqual(try engine.purgeExpired(olderThanDays: 90, now: now), 1)
        XCTAssertEqual(try engine.trash(limit: 10).map(\.id), [recent.id])
    }

    func testPurgedClipStaysGoneAfterRebuild() throws {
        let rec = try XCTUnwrap(try engine.capture(items: textItem("gone"), source: terminal, now: 1))
        try engine.delete(rec.id, now: 2)
        _ = try engine.purgeExpired(olderThanDays: 0, now: 10_000_000)
        engine = nil
        _ = try IndexBuilder.rebuild(library: dir)
        engine = try LibraryEngine(library: dir, deviceID: "dev1")
        XCTAssertEqual(try engine.trash(limit: 10).count, 0)
        XCTAssertEqual(try engine.recent(board: nil, limit: 10).count, 0)
    }

    func testDeleteSurvivesRebuild() throws {
        let rec = try XCTUnwrap(try engine.capture(items: textItem("trashed"), source: terminal, now: 1))
        try engine.delete(rec.id, now: 2)
        engine = nil
        _ = try IndexBuilder.rebuild(library: dir)
        engine = try LibraryEngine(library: dir, deviceID: "dev1")
        XCTAssertEqual(try engine.trash(limit: 10).map(\.id), [rec.id])
        XCTAssertEqual(try engine.recent(board: nil, limit: 10).count, 0)
    }

    func testEditReplacesTextKeepsOldBlobAndIsSearchable() throws {
        let rec = try XCTUnwrap(try engine.capture(items: textItem("first draft"), source: terminal, now: 1))
        let oldBlob = try XCTUnwrap(rec.representations.first { $0.uti == "public.utf8-plain-text" }).blob
        let edited = try engine.edit(rec.id, text: "second draft")
        XCTAssertEqual(edited.id, rec.id)
        XCTAssertEqual(engine.text(of: edited), "second draft")
        XCTAssertEqual(try engine.search("second", board: nil, limit: 5).map(\.id), [rec.id])
        XCTAssertEqual(try engine.search("first", board: nil, limit: 5).count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: BlobStoreTestAccess.path(library: dir, id: oldBlob)))
    }

    func testRenameRecolorAndDeleteBoard() throws {
        try engine.addBoard(id: "list:a", name: "Alpha", colorCode: 0xFF112233)
        try engine.renameBoard("list:a", to: "Alpha 2")
        try engine.recolorBoard("list:a", colorCode: 0xFF445566)
        let board = try XCTUnwrap(try engine.boards().first { $0.id == "list:a" })
        XCTAssertEqual(board.name, "Alpha 2")
        XCTAssertEqual(engine.boardColorCode(board), 0xFF445566)
        try engine.deleteBoard("list:a", now: 50)
        XCTAssertFalse(try engine.boards().contains { $0.id == "list:a" })
    }

    func testDeletingABoardSendsItsClipsToTrash() throws {
        try engine.addBoard(id: "list:a", name: "Alpha")
        let rec = try XCTUnwrap(try engine.capture(items: textItem("pinned thing"), source: terminal, now: 1))
        let pinned = try engine.pin(rec.id, to: "list:a")
        try engine.deleteBoard("list:a", now: 50)
        XCTAssertEqual(try engine.trash(limit: 10).map(\.id), [pinned.id])
        XCTAssertEqual(try engine.recent(board: nil, limit: 10).map(\.id), [rec.id])
    }

    func testRestoringAClipFromADeletedBoardFallsBackToHistory() throws {
        try engine.addBoard(id: "list:a", name: "Alpha")
        let rec = try XCTUnwrap(try engine.capture(items: textItem("pinned thing"), source: terminal, now: 1))
        let pinned = try engine.pin(rec.id, to: "list:a")
        try engine.deleteBoard("list:a", now: 50)
        try engine.restore(pinned.id, now: 60)
        let restored = try XCTUnwrap(try engine.records(ids: [pinned.id]).first)
        XCTAssertNil(restored.board)
    }

    func testMoveBoardReorders() throws {
        try engine.addBoard(id: "list:a", name: "A")
        try engine.addBoard(id: "list:b", name: "B")
        try engine.addBoard(id: "list:c", name: "C")
        try engine.moveBoard("list:c", toIndex: 0)
        XCTAssertEqual(try engine.boards().map(\.id), ["list:c", "list:a", "list:b"])
    }
}

private enum BlobStoreTestAccess {
    static func path(library: URL, id: String) -> String {
        library.appendingPathComponent("blobs/\(id.prefix(2))/\(id.dropFirst(2).prefix(2))/\(id)").path
    }
}
