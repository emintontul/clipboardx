import XCTest
@testable import ClipboardXKit

final class TextExtractorTests: XCTestCase {
    private func item(_ reps: [String: Data], order: [String]) -> PasteboardItem { PasteboardItem(types: order, dataByType: reps) }

    func testPrefersUTF8PlainText() {
        let i = item(["public.utf8-plain-text": Data("plain".utf8), "public.html": Data("<b>html</b>".utf8)],
                     order: ["public.html", "public.utf8-plain-text"])
        XCTAssertEqual(TextExtractor.text(from: [i]), "plain")
    }

    func testFallsBackToUTF16ThenHTMLStripped() {
        let u16 = item(["public.utf16-external-plain-text": "héllo".data(using: .utf16)!], order: ["public.utf16-external-plain-text"])
        XCTAssertEqual(TextExtractor.text(from: [u16]), "héllo")
        let html = item(["public.html": Data("<p>Hello &amp; <b>world</b></p>".utf8)], order: ["public.html"])
        XCTAssertEqual(TextExtractor.text(from: [html]), "Hello & world")
    }

    func testFileURLsBecomeTheirPath() {
        let i = item(["public.file-url": Data("file:///Users/me/My%20File.pdf".utf8)], order: ["public.file-url"])
        XCTAssertEqual(TextExtractor.text(from: [i]), "/Users/me/My File.pdf")
    }

    func testImageOnlyHasNoText() {
        XCTAssertEqual(TextExtractor.text(from: [item(["public.png": Data([1, 2, 3])], order: ["public.png"])]), "")
    }

    func testMultipleItemsAreJoined() {
        let a = item(["public.utf8-plain-text": Data("one".utf8)], order: ["public.utf8-plain-text"])
        let b = item(["public.utf8-plain-text": Data("two".utf8)], order: ["public.utf8-plain-text"])
        XCTAssertEqual(TextExtractor.text(from: [a, b]), "one\ntwo")
    }
}
