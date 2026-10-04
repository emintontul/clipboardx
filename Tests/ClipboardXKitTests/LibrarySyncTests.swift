import XCTest
@testable import ClipboardXKit

/// Two "Macs" with their own libraries and one shared folder that stands in for iCloud Drive.
final class LibrarySyncTests: XCTestCase {
    private var root: URL!
    private var shared: URL!
    private var libA: URL!, libB: URL!
    private var a: LibraryEngine!, b: LibraryEngine!
    private let app = SourceApp(bundleID: "com.apple.Terminal", name: "Terminal", iconPNG: nil)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        shared = root.appendingPathComponent("ClipboardX")
        libA = root.appendingPathComponent("libA"); libB = root.appendingPathComponent("libB")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        a = try LibraryEngine(library: libA, deviceID: "mac-a")
        b = try LibraryEngine(library: libB, deviceID: "mac-b")
    }

    override func tearDownWithError() throws { a = nil; b = nil; try? FileManager.default.removeItem(at: root) }

    private func text(_ s: String) -> [PasteboardItem] {
        [PasteboardItem(types: ["public.utf8-plain-text"], dataByType: ["public.utf8-plain-text": Data(s.utf8)])]
    }

    @discardableResult
    private func copy(_ engine: LibraryEngine, _ s: String, at now: Double) throws -> ClipRecord {
        try XCTUnwrap(try engine.capture(items: text(s), source: app, now: now))
    }

    private func upload(_ lib: URL, folder: String, device: String, packs: Bool = true) throws {
        _ = try LibraryBackup.backup(library: lib, destination: shared.appendingPathComponent(folder), deviceID: device)
        if !packs { try? FileManager.default.removeItem(at: shared.appendingPathComponent(folder).appendingPathComponent("packs")) }
    }

    @discardableResult
    private func sync(_ engine: LibraryEngine, own: String) throws -> LibrarySync.Report {
        try LibrarySync(engine: engine, sharedRoot: shared, ownFolder: own).syncNow()
    }

    private func ids(_ engine: LibraryEngine) throws -> [String] { try engine.recent(board: nil, limit: 100).map(\.id) }

    // MARK: convergence

    func testClipsFromTheOtherMacAppearOnBothSides() throws {
        let fromA = try copy(a, "written on mac A", at: 100)
        let fromB = try copy(b, "written on mac B", at: 200)
        try upload(libA, folder: "mac-a", device: "mac-a"); try upload(libB, folder: "mac-b", device: "mac-b")
        let reportA = try sync(a, own: "mac-a"), reportB = try sync(b, own: "mac-b")
        XCTAssertEqual(reportA.devices, 1)
        XCTAssertGreaterThan(reportA.newEvents, 0)
        XCTAssertEqual(try ids(a), [fromB.id, fromA.id])
        XCTAssertEqual(try ids(b), [fromB.id, fromA.id], "both Macs end up with the same history in the same order")
        XCTAssertEqual(reportB.devices, 1)
    }

    func testSyncedTextIsSearchableAndPayloadsArePasteable() throws {
        let rec = try copy(b, "quarterly roadmap draft", at: 10)
        try upload(libB, folder: "mac-b", device: "mac-b")
        try sync(a, own: "mac-a")
        XCTAssertEqual(try a.search("roadmap", board: nil, limit: 5).map(\.id), [rec.id])
        let synced = try XCTUnwrap(try a.recent(board: nil, limit: 5).first)
        XCTAssertEqual(try a.payload(of: synced), text("quarterly roadmap draft"))
    }

    func testLargeTextIsStillSearchableAndImagesAreFetchedLazily() throws {
        let big = String(repeating: "alpha beta gamma ", count: 12_000) + " needleword"   // ~200 KB
        let bigRec = try copy(b, big, at: 10)
        let png = Data(repeating: 7, count: 400_000)
        let image = try XCTUnwrap(try b.capture(items: [PasteboardItem(types: ["public.png"], dataByType: ["public.png": png])], source: app, now: 20))
        try upload(libB, folder: "mac-b", device: "mac-b")
        try sync(a, own: "mac-a")
        XCTAssertEqual(try a.search("alpha", board: nil, limit: 5).map(\.id), [bigRec.id], "large text is indexed on arrival")
        let blob = try XCTUnwrap(image.representations.first).blob
        XCTAssertFalse(FileManager.default.fileExists(atPath: BlobPath.path(library: libA, id: blob)), "images are not downloaded up front")
        let synced = try XCTUnwrap(try a.recent(board: nil, limit: 5).first { $0.id == image.id })
        XCTAssertEqual(a.imageData(of: synced), png, "first use fetches it from the other Mac's pack")
        XCTAssertTrue(FileManager.default.fileExists(atPath: BlobPath.path(library: libA, id: blob)), "and keeps a local copy")
    }

    func testDeleteAndRenameFromDifferentMacsConverge() throws {
        let rec = try copy(a, "shared clip", at: 1)
        try upload(libA, folder: "mac-a", device: "mac-a"); try sync(b, own: "mac-b")
        try a.delete(rec.id, now: 100)                       // Mac A trashes it
        try b.setTitle(rec.id, to: "Renamed on B", now: 200) // Mac B renames it later
        try upload(libA, folder: "mac-a", device: "mac-a"); try upload(libB, folder: "mac-b", device: "mac-b")
        try sync(a, own: "mac-a"); try sync(b, own: "mac-b")
        for engine in [a!, b!] {
            XCTAssertEqual(try engine.trash(limit: 10).map(\.id), [rec.id], "deleted stays deleted on both")
            XCTAssertEqual(try engine.trash(limit: 10).first?.title, "Renamed on B", "and the later rename wins on both")
            XCTAssertEqual(try ids(engine), [])
        }
    }

    func testLaterEditWinsWhicheverMacMadeIt() throws {
        let rec = try copy(a, "draft", at: 1)
        try upload(libA, folder: "mac-a", device: "mac-a"); try sync(b, own: "mac-b")
        try a.setTitle(rec.id, to: "from A", now: 300)
        try b.setTitle(rec.id, to: "from B", now: 200)
        try upload(libA, folder: "mac-a", device: "mac-a"); try upload(libB, folder: "mac-b", device: "mac-b")
        try sync(a, own: "mac-a"); try sync(b, own: "mac-b")
        XCTAssertEqual(try a.records(ids: [rec.id]).first?.title, "from A")
        XCTAssertEqual(try b.records(ids: [rec.id]).first?.title, "from A")
    }

    func testPinboardsAndRenamesSync() throws {
        try a.addBoard(id: "list:x", name: "Work", colorCode: 0xFF0A84FF)
        try a.renameBoard("list:x", to: "Work stuff")
        try upload(libA, folder: "mac-a", device: "mac-a")
        try sync(b, own: "mac-b")
        let board = try XCTUnwrap(try b.boards().first { $0.id == "list:x" })
        XCTAssertEqual(board.name, "Work stuff")
        XCTAssertEqual(b.boardColorCode(board), 0xFF0A84FF)
    }

    // MARK: incremental, idempotent, no echo

    func testSecondSyncDoesNothingAndNeverDuplicates() throws {
        try copy(b, "once", at: 1)
        try upload(libB, folder: "mac-b", device: "mac-b")
        try sync(a, own: "mac-a")
        let again = try sync(a, own: "mac-a")
        XCTAssertEqual(again.newEvents, 0)
        XCTAssertEqual(try a.recent(board: nil, limit: 10).count, 1)
    }

    func testOnlyNewEventsAreReadOnLaterRounds() throws {
        try copy(b, "first", at: 1)
        try upload(libB, folder: "mac-b", device: "mac-b")
        let r1 = try sync(a, own: "mac-a")
        try copy(b, "second", at: 2)
        try upload(libB, folder: "mac-b", device: "mac-b")
        let r2 = try sync(a, own: "mac-a")
        XCTAssertGreaterThan(r1.newEvents, 0)
        XCTAssertGreaterThan(r2.newEvents, 0)
        XCTAssertLessThan(r2.newEvents, r1.newEvents + 3)
        XCTAssertEqual(try a.recent(board: nil, limit: 10).count, 2)
    }

    func testForeignEventsNeverEnterTheOwnLogOrTheOwnBackup() throws {
        try copy(b, "from B", at: 1)
        try upload(libB, folder: "mac-b", device: "mac-b")
        try sync(a, own: "mac-a")
        let ownTop = try FileManager.default.contentsOfDirectory(atPath: libA.appendingPathComponent("log").path).filter { $0.hasSuffix(".jsonl") }
        XCTAssertTrue(ownTop.allSatisfy { $0.contains("mac-a") }, "own log holds only own events: \(ownTop)")
        try upload(libA, folder: "mac-a", device: "mac-a")
        let backedUp = try FileManager.default.contentsOfDirectory(atPath: shared.appendingPathComponent("mac-a/log").path)
        XCTAssertTrue(backedUp.allSatisfy { $0.contains("mac-a") }, "the backup must not re-publish another Mac's events: \(backedUp)")
    }

    func testOwnFolderInTheSharedRootIsIgnored() throws {
        try copy(a, "mine", at: 1)
        try upload(libA, folder: "mac-a", device: "mac-a")
        let r = try sync(a, own: "mac-a")
        XCTAssertEqual(r.devices, 0)
        XCTAssertEqual(r.newEvents, 0)
    }

    func testRebuildKeepsSyncedClips() throws {
        let rec = try copy(b, "survives rebuild", at: 1)
        try upload(libB, folder: "mac-b", device: "mac-b")
        try sync(a, own: "mac-a")
        a = nil
        _ = try IndexBuilder.rebuild(library: libA)
        a = try LibraryEngine(library: libA, deviceID: "mac-a")
        XCTAssertEqual(try ids(a), [rec.id])
        XCTAssertEqual(try a.search("survives", board: nil, limit: 5).count, 1)
    }

    // MARK: iCloud realities

    func testHalfWrittenLineIsWaitedForNotCorrupted() throws {
        try copy(b, "complete", at: 1)
        try upload(libB, folder: "mac-b", device: "mac-b")
        let file = try FileManager.default.contentsOfDirectory(at: shared.appendingPathComponent("mac-b/log"), includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" }!
        let whole = try Data(contentsOf: file)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"op":"delete","id":"half"#.utf8)); try handle.close()   // still uploading
        try sync(a, own: "mac-a")
        XCTAssertEqual(try a.recent(board: nil, limit: 10).count, 1)
        try whole.write(to: file)                                                                   // upload finished
        let finished = try XCTUnwrap(String(data: whole, encoding: .utf8)) + #"{"at":5,"dev":"mac-b","id":"nope","op":"delete"}"# + "\n"
        try finished.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try sync(a, own: "mac-a"))
    }

    func testICloudPlaceholdersAreDeferredNotTreatedAsErrors() throws {
        try copy(b, "x", at: 1)
        try upload(libB, folder: "mac-b", device: "mac-b")
        let logDir = shared.appendingPathComponent("mac-b/log")
        let file = try FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" }!
        let placeholder = logDir.appendingPathComponent("." + file.lastPathComponent + ".icloud")
        let held = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try Data().write(to: placeholder)
        let r = try sync(a, own: "mac-a")
        XCTAssertEqual(r.deferred, 1)
        XCTAssertEqual(try ids(a).count, 0)
        try FileManager.default.removeItem(at: placeholder)
        try held.write(to: file)
        try sync(a, own: "mac-a")
        XCTAssertEqual(try ids(a).count, 1, "once the file has downloaded it is picked up")
    }

    func testTextArrivesLaterWhenThePackWasNotUploadedYet() throws {
        let rec = try copy(b, "late arriving words", at: 1)
        try upload(libB, folder: "mac-b", device: "mac-b", packs: false)      // logs are there, packs are still uploading
        try sync(a, own: "mac-a")
        XCTAssertEqual(try ids(a), [rec.id], "the clip shows up")
        XCTAssertEqual(try a.search("arriving", board: nil, limit: 5).count, 0, "but cannot be searched yet")
        try upload(libB, folder: "mac-b", device: "mac-b")                     // packs finish uploading
        try sync(a, own: "mac-a")
        XCTAssertEqual(try a.search("arriving", board: nil, limit: 5).map(\.id), [rec.id], "next round fills in the text")
    }

    func testAMacThatJoinsLaterGetsTheWholeHistory() throws {
        var expected: [String] = []
        for i in 0..<40 { expected.append(try copy(b, "history item \(i)", at: Double(i)).id) }
        try upload(libB, folder: "mac-b", device: "mac-b")
        try sync(a, own: "mac-a")
        XCTAssertEqual(try a.recent(board: nil, limit: 100).count, 40)
        XCTAssertEqual(try a.search("history item 17", board: nil, limit: 3).count, 1)
    }
}

private enum BlobPath {
    static func path(library: URL, id: String) -> String {
        library.appendingPathComponent("blobs/\(id.prefix(2))/\(id.dropFirst(2).prefix(2))/\(id)").path
    }
}
