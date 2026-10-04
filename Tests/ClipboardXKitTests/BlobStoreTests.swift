import XCTest
@testable import ClipboardXKit

final class BlobStoreTests: XCTestCase {
    private func makeStore() throws -> (BlobStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try BlobStore(root: dir), dir)
    }

    func testPutReturnsSHA256AndRoundTrips() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data("abc".utf8)
        let id = try store.put(data)
        XCTAssertEqual(id, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try store.get(id), data)
    }

    func testDuplicatePutStoresOnce() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try store.put(Data("same".utf8))
        let second = try store.put(Data("same".utf8))
        XCTAssertEqual(first, second)
        XCTAssertEqual(store.blobCount, 1)
    }

    func testEmptyDataIsStorable() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try store.put(Data())
        XCTAssertEqual(try store.get(id), Data())
    }

    func testCorruptedBlobIsDetectedOnRead() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try store.put(Data(repeating: 7, count: 2000))
        let path = store.path(for: id)
        var raw = try Data(contentsOf: path)
        raw[raw.count / 2] ^= 0xFF
        try raw.write(to: path)
        XCTAssertThrowsError(try store.get(id))
    }

    func testGetMissingThrows() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try store.get(String(repeating: "0", count: 64)))
    }
}
