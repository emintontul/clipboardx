import XCTest
@testable import ClipboardXKit

final class EventLogTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func event(_ id: String) -> ClipEvent {
        ClipEvent.put(ClipRecord(
            id: id, createdAt: 1, copiedAt: 2, title: nil, appBundleID: "com.apple.Terminal",
            board: nil, boardOrder: nil, rawKind: 5,
            representations: [Representation(uti: "public.utf8-plain-text", blob: "ab", size: 3)],
            source: "test"))
    }

    func testAppendAndReadBackInOrder() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try EventLog(directory: dir, deviceID: "dev1")
        try log.append(event("a")); try log.append(event("b")); try log.append(event("c"))
        let read = try EventLog.readAll(directory: dir)
        XCTAssertEqual(read.compactMap { if case .put(let r) = $0 { return r.id } else { return nil } }, ["a", "b", "c"])
    }

    func testReopenAppendsInsteadOfOverwriting() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try EventLog(directory: dir, deviceID: "dev1").append(event("a"))
        try EventLog(directory: dir, deviceID: "dev1").append(event("b"))
        XCTAssertEqual(try EventLog.readAll(directory: dir).count, 2)
    }

    func testEachDeviceWritesOwnFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try EventLog(directory: dir, deviceID: "dev1").append(event("a"))
        try EventLog(directory: dir, deviceID: "dev2").append(event("b"))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".jsonl") }
        XCTAssertEqual(files.count, 2)
    }

    func testTornLastLineIsReportedNotSilentlyDropped() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try EventLog(directory: dir, deviceID: "dev1")
        try log.append(event("a"))
        let file = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" }!
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"op\":\"put\",\"trunc".utf8)); try handle.close()
        XCTAssertThrowsError(try EventLog.readAll(directory: dir)) { error in
            guard case EventLog.ReadError.corruptLine = error else { return XCTFail("\(error)") }
        }
    }
}
