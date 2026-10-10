import XCTest
@testable import ClipboardXKit

final class LibraryBackupTests: XCTestCase {
    private var root: URL!
    private var library: URL { root.appendingPathComponent("lib") }
    private var backup: URL { root.appendingPathComponent("icloud/ClipboardX/dev1") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func seed(_ count: Int, prefix: String = "blob") throws -> [String: Data] {
        let store = try BlobStore(root: library.appendingPathComponent("blobs"))
        let log = try EventLog(directory: library.appendingPathComponent("log"), deviceID: "dev1")
        var written: [String: Data] = [:]
        for i in 0..<count {
            let data = Data("\(prefix)-\(i)-".utf8) + Data(repeating: UInt8(i % 250), count: 300 + i)
            written[try store.put(data)] = data
            try log.append(.app(AppRecord(bundleID: "app.\(prefix).\(i)", name: "n", iconBlob: nil)))
        }
        try log.sync()
        return written
    }

    func testBackupThenRestoreReproducesEveryBlobAndLog() throws {
        let blobs = try seed(40)
        let result = try LibraryBackup.backup(library: library, destination: backup, packSize: 4_000, deviceID: "dev1")
        XCTAssertEqual(result.blobsPacked, 40)
        XCTAssertGreaterThan(result.packsWritten, 1)

        let restored = root.appendingPathComponent("restored")
        let restore = try LibraryBackup.restore(from: backup, to: restored)
        XCTAssertEqual(restore.blobsRestored, 40)
        let store = try BlobStore(root: restored.appendingPathComponent("blobs"))
        for (id, data) in blobs { XCTAssertEqual(try store.get(id), data) }
        XCTAssertEqual(try EventLog.readAll(directory: restored.appendingPathComponent("log")).count, 40)
    }

    func testChangeSignatureIsStableUntilTheLogGrows() throws {
        try seed(3)
        let before = LibraryBackup.changeSignature(library: library)
        XCTAssertEqual(LibraryBackup.changeSignature(library: library), before)
        let log = try EventLog(directory: library.appendingPathComponent("log"), deviceID: "dev1")
        try log.append(.app(AppRecord(bundleID: "app.new", name: "n", iconBlob: nil))); try log.sync()
        XCTAssertNotEqual(LibraryBackup.changeSignature(library: library), before)
    }

    func testSecondRunPacksOnlyNewBlobs() throws {
        try seed(10)
        _ = try LibraryBackup.backup(library: library, destination: backup, packSize: 1_000_000, deviceID: "dev1")
        let again = try LibraryBackup.backup(library: library, destination: backup, packSize: 1_000_000, deviceID: "dev1")
        XCTAssertEqual(again.blobsPacked, 0)
        XCTAssertEqual(again.packsWritten, 0)
        try seed(5, prefix: "more")
        let third = try LibraryBackup.backup(library: library, destination: backup, packSize: 1_000_000, deviceID: "dev1")
        XCTAssertEqual(third.blobsPacked, 5)
    }

    func testIncompletePackWithoutIndexIsIgnoredAndRewritten() throws {
        try seed(6)
        let packs = backup.appendingPathComponent("packs")
        try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
        try Data("garbage from a crashed run".utf8).write(to: packs.appendingPathComponent("pack-dev1-00001.cxp"))
        let result = try LibraryBackup.backup(library: library, destination: backup, packSize: 1_000_000, deviceID: "dev1")
        XCTAssertEqual(result.blobsPacked, 6)
        let restore = try LibraryBackup.restore(from: backup, to: root.appendingPathComponent("r"))
        XCTAssertEqual(restore.blobsRestored, 6)
    }

    func testCorruptedPackFailsRestoreLoudly() throws {
        try seed(5)
        _ = try LibraryBackup.backup(library: library, destination: backup, packSize: 1_000_000, deviceID: "dev1")
        let pack = try FileManager.default.contentsOfDirectory(at: backup.appendingPathComponent("packs"), includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "cxp" }!
        var bytes = try Data(contentsOf: pack)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: pack)
        XCTAssertThrowsError(try LibraryBackup.restore(from: backup, to: root.appendingPathComponent("r")))
    }

    func testBackupDoesNotChangeTheSourceLibrary() throws {
        let blobs = try seed(8)
        _ = try LibraryBackup.backup(library: library, destination: backup, packSize: 1_000_000, deviceID: "dev1")
        let store = try BlobStore(root: library.appendingPathComponent("blobs"))
        for (id, data) in blobs { XCTAssertEqual(try store.get(id), data) }
    }

    func testVerifyBackupMatchesLibrary() throws {
        try seed(12)
        _ = try LibraryBackup.backup(library: library, destination: backup, packSize: 2_000, deviceID: "dev1")
        let report = try LibraryBackup.verify(library: library, backup: backup)
        XCTAssertTrue(report.complete, "\(report)")
        XCTAssertEqual(report.missingFromBackup, 0)
        try seed(1, prefix: "late")
        XCTAssertFalse(try LibraryBackup.verify(library: library, backup: backup).complete)
    }
}
