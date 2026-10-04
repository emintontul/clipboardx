import XCTest
@testable import ClipboardXKit

final class SearchIndexTests: XCTestCase {
    private var dir: URL!
    private var index: SearchIndex!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        index = try SearchIndex(path: dir.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func add(_ id: String, title: String? = nil, text: String, app: String? = nil, copied: Double = 1000, board: String? = nil) throws {
        try index.upsert(SearchDocument(id: id, title: title, text: text, appName: app, copiedAt: copied, board: board))
    }

    private func ids(_ query: String, limit: Int = 20) throws -> [String] {
        try index.search(query, limit: limit).map(\.id)
    }

    func testSpacedQueryFindsUnspacedTitle() throws {
        try add("named", title: "ToggLite", text: "ssh deploy@10.0.4.21 -p 2222")
        try add("other", text: "unrelated content here")
        XCTAssertEqual(try ids("Togg Lite"), ["named"])
        XCTAssertEqual(try ids("togglite"), ["named"])
    }

    func testUnspacedQueryFindsSpacedContent() throws {
        try add("body", text: "Togg Lite onboarding checklist")
        XCTAssertEqual(try ids("togglite"), ["body"])
    }

    func testTurkishFolding() throws {
        try add("tr", text: "Toplantı notları İstanbul ofisi")
        XCTAssertEqual(try ids("istanbul"), ["tr"])
        XCTAssertEqual(try ids("TOPLANTI NOTLARI"), ["tr"])
    }

    func testTitleMatchOutranksBodyMatch() throws {
        try add("body", text: "notes about ToggLite rollout", copied: 5000)
        try add("title", title: "ToggLite", text: "x", copied: 1000)
        XCTAssertEqual(try ids("togglite").first, "title")
    }

    func testTokensInAnyOrder() throws {
        try add("a", text: "nginx reload fails with 502 upstream")
        XCTAssertEqual(try ids("upstream nginx"), ["a"])
    }

    func testMidWordSubstring() throws {
        try add("a", text: "SELECT count(*) FROM ZITEMENTITY")
        XCTAssertEqual(try ids("tementi"), ["a"])
    }

    func testShortQueriesStillWork() throws {
        try add("a", title: "SSH", text: "ssh deploy@host")
        try add("b", text: "nothing")
        XCTAssertEqual(try ids("ss"), ["a"])
        XCTAssertEqual(try ids("s").contains("a"), true)
    }

    func testEmptyQueryReturnsNewestFirst() throws {
        try add("old", text: "a", copied: 1)
        try add("new", text: "b", copied: 9)
        XCTAssertEqual(try ids(""), ["new", "old"])
    }

    func testUpsertReplacesPreviousDocument() throws {
        try add("a", text: "alpha content")
        try add("a", text: "beta content")
        XCTAssertEqual(try ids("alpha"), [])
        XCTAssertEqual(try ids("beta"), ["a"])
    }

    func testNoMatchReturnsEmpty() throws {
        try add("a", text: "hello world")
        XCTAssertEqual(try ids("zzzzzz"), [])
    }

    func testQuotesAndOperatorsInQueryDoNotBreakSearch() throws {
        try add("a", text: "say \"hello\" AND goodbye OR NOT")
        XCTAssertNoThrow(try ids("\"hello\" AND (goodbye"))
        XCTAssertNoThrow(try ids("* NEAR ^ :"))
    }

    func testResultsExplainWhyTheyMatched() throws {
        try add("a", title: "ToggLite", text: "x")
        let hit = try XCTUnwrap(index.search("Togg Lite", limit: 5).first)
        XCTAssertTrue(hit.reasons.contains { $0.hasPrefix("title") })
    }

    func testSearchStaysFastOnLargeIndex() throws {
        try index.bulk { add in
            for i in 0..<20_000 {
                add(SearchDocument(id: "i\(i)", title: nil, text: "row \(i) lorem ipsum dolor sit amet \(i * 7919)", appName: "Notes", copiedAt: Double(i), board: nil))
            }
        }
        try add("needle", title: "ToggLite", text: "x")
        let start = Date()
        let hits = try ids("Togg Lite")
        XCTAssertEqual(hits, ["needle"])
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25)
    }
}

extension SearchIndexTests {
    func testTypoToleranceOnTitles() throws {
        try add("named", title: "ToggLite", text: "x")
        XCTAssertEqual(try ids("tog lite"), ["named"])
    }
}
