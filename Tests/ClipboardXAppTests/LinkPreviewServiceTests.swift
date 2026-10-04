import XCTest
import ClipboardXKit
@testable import ClipboardXApp

private final class FakeFetcher: LinkFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [URL] = []
    var result: Result<FetchedLink, Error> = .success(FetchedLink(title: "Page", iconData: Data([1]), imageData: Data([2])))
    var calls: [URL] { lock.lock(); defer { lock.unlock() }; return _calls }
    func fetch(_ url: URL) async throws -> FetchedLink {
        lock.lock(); _calls.append(url); lock.unlock()
        return try result.get()
    }
}

private struct Boom: Error {}

final class LinkPreviewServiceTests: XCTestCase {
    private var dir: URL!
    private var engine: LibraryEngine!
    private var fetcher: FakeFetcher!
    private var enabled = true
    private var clock = 1_000.0

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        engine = try LibraryEngine(library: dir, deviceID: "dev")
        fetcher = FakeFetcher()
        enabled = true
        clock = 1_000
    }

    override func tearDownWithError() throws { engine = nil; try? FileManager.default.removeItem(at: dir) }

    private func service() -> LinkPreviewService {
        LinkPreviewService(engine: engine, fetcher: fetcher, isEnabled: { [unowned self] in self.enabled }, now: { [unowned self] in self.clock })
    }

    func testDoesNothingWhenPreviewsAreOff() async {
        enabled = false
        await service().process("https://swift.org/blog")
        XCTAssertTrue(fetcher.calls.isEmpty, "nothing may leave the Mac while the setting is off")
        XCTAssertNil(try engine.linkRecord(for: "https://swift.org/blog"))
    }

    func testNeverRequestsUnsafeLinks() async {
        let s = service()
        for url in ["http://localhost:3100/x", "http://192.168.1.5/", "https://example.com/reset/abc", "https://example.com/?token=abc",
                    "https://user:pw@example.com/", "ftp://example.com/", "not a url"] {
            await s.process(url)
        }
        XCTAssertTrue(fetcher.calls.isEmpty)
    }

    func testFetchesOnceAndCaches() async throws {
        let s = service()
        await s.process("https://swift.org/blog")
        await s.process("https://swift.org/blog")
        XCTAssertEqual(fetcher.calls.count, 1)
        let record = try XCTUnwrap(try engine.linkRecord(for: "https://swift.org/blog"))
        XCTAssertEqual(record.title, "Page")
        XCTAssertFalse(record.failed)
        XCTAssertEqual(engine.linkBlob(try XCTUnwrap(record.imageBlob)), Data([2]))
    }

    func testFailureIsRememberedAndRetriedOnlyAfterAWeek() async throws {
        fetcher.result = .failure(Boom())
        let s = service()
        await s.process("https://down.example/page")
        XCTAssertTrue(try XCTUnwrap(try engine.linkRecord(for: "https://down.example/page")).failed)
        await s.process("https://down.example/page")
        XCTAssertEqual(fetcher.calls.count, 1, "a failed lookup is not repeated right away")
        clock += 6 * 86_400
        await s.process("https://down.example/page")
        XCTAssertEqual(fetcher.calls.count, 1)
        clock += 2 * 86_400
        await s.process("https://down.example/page")
        XCTAssertEqual(fetcher.calls.count, 2, "after a week it is tried again")
    }

    func testUpdateCallbackFiresWithTheURL() async {
        var updated: [String] = []
        let s = service()
        s.onUpdate = { updated.append($0) }
        await s.process("https://swift.org/blog")
        XCTAssertEqual(updated, ["https://swift.org/blog"])
    }

    func testTurningTheSettingOnLaterStartsFetching() async {
        enabled = false
        let s = service()
        await s.process("https://swift.org/blog")
        enabled = true
        await s.process("https://swift.org/blog")
        XCTAssertEqual(fetcher.calls.count, 1)
    }
}
