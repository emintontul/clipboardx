import XCTest
@testable import ClipboardXKit

final class HTMLMetadataTests: XCTestCase {
    private let base = URL(string: "https://www.example.com/blog/post")!
    private func parse(_ html: String) -> PageMetadata { HTMLMetadata.parse(html, base: base) }

    func testPrefersOpenGraphOverTitleTag() {
        let m = parse(#"<html><head><title>Plain title</title><meta property="og:title" content="Social title"></head></html>"#)
        XCTAssertEqual(m.title, "Social title")
    }

    func testFallsBackToTitleTagAndDecodesEntities() {
        XCTAssertEqual(parse("<title>Tom &amp; Jerry &quot;live&quot;</title>").title, "Tom & Jerry \"live\"")
        XCTAssertEqual(parse("<TITLE>\n  Spaced   out \n</TITLE>").title, "Spaced out")
    }

    func testAttributeOrderAndQuotesDoNotMatter() {
        XCTAssertEqual(parse(#"<meta content="Reversed" property="og:title">"#).title, "Reversed")
        XCTAssertEqual(parse("<meta property='og:title' content='Single quoted'>").title, "Single quoted")
        XCTAssertEqual(parse(#"<meta name="twitter:title" content="From Twitter">"#).title, "From Twitter")
    }

    func testImageIsResolvedAgainstThePageURL() {
        XCTAssertEqual(parse(#"<meta property="og:image" content="/img/cover.png">"#).imageURL?.absoluteString, "https://www.example.com/img/cover.png")
        XCTAssertEqual(parse(#"<meta property="og:image" content="https://cdn.example.net/a.jpg">"#).imageURL?.absoluteString, "https://cdn.example.net/a.jpg")
        XCTAssertEqual(parse(#"<meta name="twitter:image" content="//cdn.example.net/t.jpg">"#).imageURL?.absoluteString, "https://cdn.example.net/t.jpg")
    }

    func testIconComesFromLinkTagsThenFaviconIco() {
        XCTAssertEqual(parse(#"<link rel="icon" href="/static/f.png">"#).iconURL?.absoluteString, "https://www.example.com/static/f.png")
        XCTAssertEqual(parse(#"<link rel="shortcut icon" href="f.ico">"#).iconURL?.absoluteString, "https://www.example.com/blog/f.ico")
        XCTAssertEqual(parse(#"<link href="/apple.png" rel="apple-touch-icon">"#).iconURL?.absoluteString, "https://www.example.com/apple.png")
        XCTAssertEqual(parse("<html></html>").iconURL?.absoluteString, "https://www.example.com/favicon.ico")
    }

    func testOnlyHttpAndHttpsURLsAreAccepted() {
        XCTAssertNil(parse(#"<meta property="og:image" content="javascript:alert(1)">"#).imageURL)
        XCTAssertNil(parse(#"<meta property="og:image" content="data:image/png;base64,AAAA">"#).imageURL)
        XCTAssertNil(parse(#"<meta property="og:image" content="file:///etc/passwd">"#).imageURL)
    }

    func testEmptyAndGarbageInput() {
        let none = parse("")
        XCTAssertNil(none.title)
        XCTAssertNil(none.imageURL)
        XCTAssertNil(parse("<<<>>> not html at all").title)
        XCTAssertNil(parse("<title></title>").title)
    }

    func testOnlyTheStartOfHugeDocumentsIsRead() {
        let huge = String(repeating: "x", count: 600_000) + #"<meta property="og:title" content="too late">"#
        XCTAssertNil(parse(huge).title)
    }
}
