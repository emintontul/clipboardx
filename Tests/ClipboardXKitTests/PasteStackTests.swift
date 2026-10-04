import XCTest
@testable import ClipboardXKit

final class PasteStackTests: XCTestCase {
    func testStartsInactiveAndIgnoresEnqueue() {
        var stack = PasteStack()
        stack.enqueue("a")
        XCTAssertFalse(stack.isActive)
        XCTAssertTrue(stack.ids.isEmpty)
    }

    func testItemsComeOutInTheOrderTheyWereCopied() {
        var stack = PasteStack()
        stack.start()
        ["a", "b", "c"].forEach { stack.enqueue($0) }
        XCTAssertEqual(stack.popFirst(), "a")
        XCTAssertEqual(stack.popFirst(), "b")
        XCTAssertEqual(stack.ids, ["c"])
    }

    func testCopyingTheSameClipTwiceInARowQueuesItOnce() {
        var stack = PasteStack()
        stack.start()
        stack.enqueue("a"); stack.enqueue("a"); stack.enqueue("b"); stack.enqueue("a")
        XCTAssertEqual(stack.ids, ["a", "b", "a"])
    }

    func testRemoveTakesOutOnlyTheFirstMatch() {
        var stack = PasteStack()
        stack.start()
        ["a", "b", "a"].forEach { stack.enqueue($0) }
        stack.remove("a")
        XCTAssertEqual(stack.ids, ["b", "a"])
    }

    func testStopClearsEverything() {
        var stack = PasteStack()
        stack.start(); stack.enqueue("a")
        stack.stop()
        XCTAssertFalse(stack.isActive)
        XCTAssertTrue(stack.ids.isEmpty)
        XCTAssertNil(stack.popFirst())
    }

    func testStartingAgainBeginsEmpty() {
        var stack = PasteStack()
        stack.start(); stack.enqueue("a")
        stack.start()
        XCTAssertTrue(stack.ids.isEmpty)
        XCTAssertTrue(stack.isActive)
    }
}
