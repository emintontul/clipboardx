import XCTest
@testable import ClipboardXKit

final class QueryParserTests: XCTestCase {
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    // Wednesday 2026-10-07 15:30 UTC
    private var now: Date { Date(timeIntervalSince1970: 1_791_387_000) }

    private func parse(_ q: String) -> ParsedQuery { QueryParser.parse(q, now: now, calendar: utc) }

    func testPlainTextHasNoFilters() {
        let p = parse("Togg Lite")
        XCTAssertEqual(p.text, "Togg Lite")
        XCTAssertTrue(p.filters.isEmpty)
    }

    func testTypeFilters() {
        XCTAssertEqual(parse("type:link").filters.kinds, [.link])
        XCTAssertEqual(parse("type:link type:image notes").filters.kinds, [.link, .image])
        XCTAssertEqual(parse("type:link notes").text, "notes")
        XCTAssertEqual(parse("type:foo").text, "type:foo", "unknown types stay searchable text")
    }

    func testAppFilter() {
        let p = parse("app:Safari swift blog")
        XCTAssertEqual(p.filters.appName, "Safari")
        XCTAssertEqual(p.text, "swift blog")
    }

    func testAbsoluteDates() {
        let p = parse("after:2026-09-01 before:2026-09-30 invoice")
        XCTAssertEqual(p.filters.after, 1_788_220_800)   // 2026-09-01 00:00 UTC
        XCTAssertEqual(p.filters.before, 1_790_726_400)  // 2026-09-30 00:00 UTC
        XCTAssertEqual(p.text, "invoice")
    }

    func testNaturalDatePhrases() {
        let startOfToday = 1_791_331_200.0   // 2026-10-07 00:00 UTC
        XCTAssertEqual(parse("today").filters.after, startOfToday)
        XCTAssertEqual(parse("yesterday").filters.after, startOfToday - 86_400)
        XCTAssertEqual(parse("yesterday").filters.before, startOfToday)
        XCTAssertEqual(parse("last week").filters.after, startOfToday - 7 * 86_400)
        XCTAssertEqual(parse("last month").filters.after, startOfToday - 30 * 86_400)
        XCTAssertEqual(parse("last week invoice").text, "invoice")
    }

    func testBadDatesAreKeptAsText() {
        XCTAssertEqual(parse("after:soon").text, "after:soon")
        XCTAssertNil(parse("after:soon").filters.after)
    }

    func testEmpty() {
        let p = parse("   ")
        XCTAssertEqual(p.text, "")
        XCTAssertTrue(p.filters.isEmpty)
    }
}
