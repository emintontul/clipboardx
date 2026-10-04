import XCTest
@testable import ClipboardXKit

final class LibraryStateTests: XCTestCase {
    private func rec(_ id: String, title: String? = nil, board: String? = nil) -> ClipRecord {
        ClipRecord(id: id, createdAt: 1, copiedAt: 1, title: title, appBundleID: nil, board: board, boardOrder: nil, rawKind: 5,
                   representations: [], source: "test")
    }

    private func stamp(_ event: ClipEvent, at: Double, dev: String = "a") -> StampedEvent { StampedEvent(event: event, at: at, dev: dev) }

    func testLatestPutWinsRegardlessOfInputOrder() {
        let state = LibraryState.fold([stamp(.put(rec("x", title: "new")), at: 2), stamp(.put(rec("x", title: "old")), at: 1)])
        XCTAssertEqual(state.records["x"]?.title, "new")
    }

    func testSameTimestampIsBrokenByDeviceID() {
        let state = LibraryState.fold([stamp(.put(rec("x", title: "from-a")), at: 5, dev: "a"), stamp(.put(rec("x", title: "from-b")), at: 5, dev: "b")])
        XCTAssertEqual(state.records["x"]?.title, "from-b")
    }

    func testDeleteMarksTrashWithItsTimestampAndRestoreClearsIt() {
        var state = LibraryState.fold([stamp(.put(rec("x")), at: 1), stamp(.delete("x"), at: 10)])
        XCTAssertEqual(state.deleted["x"], 10)
        state = LibraryState.fold([stamp(.put(rec("x")), at: 1), stamp(.delete("x"), at: 10), stamp(.restore("x"), at: 11)])
        XCTAssertNil(state.deleted["x"])
        XCTAssertNotNil(state.records["x"])
    }

    func testPurgeRemovesTheClipAndBlocksLaterPuts() {
        let state = LibraryState.fold([stamp(.put(rec("x")), at: 1), stamp(.delete("x"), at: 2), stamp(.purge("x"), at: 3), stamp(.put(rec("x", title: "ghost")), at: 4)])
        XCTAssertNil(state.records["x"])
        XCTAssertNil(state.deleted["x"])
    }

    func testDeleteOfAnUnknownClipIsIgnored() {
        let state = LibraryState.fold([stamp(.delete("nope"), at: 1)])
        XCTAssertTrue(state.records.isEmpty)
        XCTAssertTrue(state.deleted.isEmpty)
    }

    func testPutAfterDeleteKeepsItInTrash() {
        let state = LibraryState.fold([stamp(.put(rec("x")), at: 1), stamp(.delete("x"), at: 2), stamp(.put(rec("x", title: "renamed")), at: 3)])
        XCTAssertEqual(state.deleted["x"], 2)
        XCTAssertEqual(state.records["x"]?.title, "renamed")
    }

    func testBoardEventsFoldLatestWins() {
        let a = BoardRecord(id: "b", name: "Old", index: 1, kind: 2, createdAt: 1, attributesBlob: nil)
        let b = BoardRecord(id: "b", name: "New", index: 2, kind: 2, createdAt: 1, attributesBlob: nil, deletedAt: 9)
        let state = LibraryState.fold([stamp(.board(b), at: 5), stamp(.board(a), at: 1)])
        XCTAssertEqual(state.boards["b"]?.name, "New")
        XCTAssertEqual(state.boards["b"]?.deletedAt, 9)
    }
}
