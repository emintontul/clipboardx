import XCTest
@testable import ClipboardXKit

final class TextNormalizerTests: XCTestCase {
    func testFoldsCaseAndTurkishLetters() {
        XCTAssertEqual(TextNormalizer.fold("İstanbul ŞĞÜÖÇ ığüşöç"), "istanbul sguoc igusoc")
        XCTAssertEqual(TextNormalizer.fold("ISPARTA"), "isparta")
    }

    func testCompactDropsSpacesAndPunctuation() {
        XCTAssertEqual(TextNormalizer.compact("Togg Lite"), "togglite")
        XCTAssertEqual(TextNormalizer.compact("togg-lite_v2!"), "togglitev2")
    }

    func testTokensSplitOnNonAlphanumerics() {
        XCTAssertEqual(TextNormalizer.tokens("  Togg  Lite, v2 "), ["togg", "lite", "v2"])
    }

    func testEmptyInput() {
        XCTAssertEqual(TextNormalizer.compact(""), "")
        XCTAssertEqual(TextNormalizer.tokens("   "), [])
    }
}
