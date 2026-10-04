import XCTest
@testable import ClipboardXKit

final class LinkSafetyTests: XCTestCase {
    private func ok(_ s: String) -> Bool { LinkSafety.isFetchable(URL(string: s)!) }

    func testOrdinaryPublicLinksAreFetchable() {
        XCTAssertTrue(ok("https://swift.org/blog/swift-6/"))
        XCTAssertTrue(ok("http://example.com/page?id=42&lang=en"))
        XCTAssertTrue(ok("https://developer.apple.com/documentation/appkit/nspasteboard"))
    }

    func testOnlyHttpAndHttpsAreFetched() {
        XCTAssertFalse(ok("ftp://example.com/file"))
        XCTAssertFalse(ok("file:///Users/me/secret.txt"))
        XCTAssertFalse(ok("javascript:alert(1)"))
        XCTAssertFalse(ok("ssh://deploy@host"))
    }

    func testLocalAndPrivateAddressesAreNeverFetched() {
        for host in ["localhost", "127.0.0.1", "127.1.2.3", "10.0.4.21", "192.168.1.5", "172.16.0.9", "172.31.255.1", "169.254.10.10", "0.0.0.0",
                     "[::1]", "[fe80::1]", "[fd00::1]", "nas.local", "printer.localhost", "router.lan", "box.home.arpa", "app.internal"] {
            XCTAssertFalse(ok("http://\(host)/x"), host)
        }
        XCTAssertTrue(ok("http://172.32.0.1/x"), "172.32 is public")
        XCTAssertTrue(ok("http://8.8.8.8/"))
    }

    func testPortsOnPrivateHostsAreStillBlocked() {
        XCTAssertFalse(ok("http://localhost:3100/dashboard"))
        XCTAssertFalse(ok("http://192.168.0.2:8080/"))
    }

    func testLinksWithCredentialsAreNotFetched() {
        XCTAssertFalse(ok("https://user:pass@example.com/"))
    }

    func testTokenLikeQueriesAreNotFetched() {
        for q in ["token=abc", "access_token=abc", "key=abc", "api_key=abc", "apikey=abc", "sig=abc", "signature=abc", "code=abc", "auth=abc",
                  "password=abc", "secret=abc", "session=abc", "otp=123456", "jwt=abc", "X-Amz-Signature=abc", "Token=ABC", "a=1&token=2"] {
            XCTAssertFalse(ok("https://example.com/path?\(q)"), q)
        }
    }

    func testOneTimePathsAreNotFetched() {
        for path in ["/reset-password/abc", "/verify/abc", "/confirm/abc", "/magic/abc", "/unsubscribe/abc", "/invite/abc", "/activate/abc",
                     "/login", "/signin", "/oauth/callback", "/Reset/abc"] {
            XCTAssertFalse(ok("https://example.com\(path)"), path)
        }
        XCTAssertTrue(ok("https://example.com/blog/how-to-verify-your-code"), "a harmless word inside a longer slug is fine")
    }

    func testTokensInTheFragmentAreNotFetched() {
        XCTAssertFalse(ok("https://example.com/cb#access_token=abc"))
        XCTAssertTrue(ok("https://example.com/docs#installation"))
    }

    func testHarmlessQueryKeysThatContainSensitiveWordsAreFine() {
        XCTAssertTrue(ok("https://example.com/search?keyboard=mechanical&decode=1"))
    }
}
