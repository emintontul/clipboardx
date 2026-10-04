import XCTest
import SQLite3
import Compression
@testable import ClipboardXKit

final class PasteImporterTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: work) }

    // MARK: fixture

    private func deflate(_ json: String) -> Data {
        let src = Data(json.utf8)
        var out = Data(count: src.count + 4096)
        let n = out.withUnsafeMutableBytes { dst in
            src.withUnsafeBytes { s in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                                          s.bindMemory(to: UInt8.self).baseAddress!, s.count, nil, COMPRESSION_ZLIB)
            }
        }
        return Data([1]) + out.prefix(n)
    }

    private func manifest(_ text: String) -> Data {
        deflate(#"[{"types":["public.utf8-plain-text"],"dataByType":{"public.utf8-plain-text":"\#(Data(text.utf8).base64EncodedString())"}}]"#)
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
    }

    private func insertData(_ db: OpaquePointer?, pk: Int, item: Int, blob: Data) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO ZITEMDATAENTITY(Z_PK,ZITEM,ZRAWPASTEBOARDITEMS) VALUES(?,?,?)", -1, &stmt, nil)
        sqlite3_bind_int(stmt, 1, Int32(pk)); sqlite3_bind_int(stmt, 2, Int32(item))
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(blob.count), nil) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE); sqlite3_finalize(stmt)
    }

    /// Builds a miniature Paste store: 3 history items (one with a title, one undecodable), 1 pinboard item.
    private func makeSnapshot() throws -> URL {
        let url = work.appendingPathComponent("snap.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        exec(db, """
        CREATE TABLE ZITEMENTITY(Z_PK INTEGER PRIMARY KEY,ZDISPLAYORDERINPINBOARD INTEGER,ZRAWTYPE INTEGER,ZDATA INTEGER,ZLIST INTEGER,ZSOURCEAPPLICATION INTEGER,ZCREATEDAT REAL,ZTIMESTAMP REAL,ZUPDATEDAT REAL,ZCHECKSUM TEXT,ZIDENTIFIER TEXT,ZTITLE TEXT,ZRAWPREVIEW BLOB);
        CREATE TABLE ZITEMDATAENTITY(Z_PK INTEGER PRIMARY KEY,ZITEM INTEGER,ZRAWPASTEBOARDITEMS BLOB);
        CREATE TABLE ZLISTENTITY(Z_PK INTEGER PRIMARY KEY,ZRAWTYPE INTEGER,ZCREATEDAT REAL,ZIDENTIFIER TEXT,ZNAME TEXT,ZRAWATTRIBUTES BLOB);
        CREATE TABLE ZLISTMETADATAENTITY(Z_PK INTEGER PRIMARY KEY,ZINDEX INTEGER,ZLIST INTEGER);
        CREATE TABLE ZAPPLICATIONENTITY(Z_PK INTEGER PRIMARY KEY,ZBUNDLEIDENTIFIER TEXT,ZNAME TEXT,ZRAWICON BLOB);
        INSERT INTO ZAPPLICATIONENTITY VALUES(1,'com.apple.Terminal','Terminal',x'0102');
        INSERT INTO ZLISTENTITY VALUES(1,1,10,'sharedPasteboardHistory','Clipboard History',NULL);
        INSERT INTO ZLISTENTITY VALUES(2,2,11,'list:SSH','SSH',x'AABB');
        INSERT INTO ZLISTMETADATAENTITY VALUES(1,0,1);
        INSERT INTO ZLISTMETADATAENTITY VALUES(2,3,2);
        INSERT INTO ZITEMENTITY VALUES(1,NULL,5,1,NULL,1,100,300,300,'c1','id-1',NULL,NULL);
        INSERT INTO ZITEMENTITY VALUES(2,NULL,5,2,NULL,1,200,200,200,'c2','id-2','ToggLite',x'FF');
        INSERT INTO ZITEMENTITY VALUES(3,NULL,5,3,NULL,NULL,50,50,50,'c3','id-3',NULL,NULL);
        INSERT INTO ZITEMENTITY VALUES(4,0,5,4,2,1,400,400,400,'c4','id-4','srv',NULL);
        """)
        insertData(db, pk: 1, item: 1, blob: manifest("one"))
        insertData(db, pk: 2, item: 2, blob: manifest("two"))
        insertData(db, pk: 3, item: 3, blob: Data([1, 0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA]))   // undecodable
        insertData(db, pk: 4, item: 4, blob: manifest("four"))
        return url
    }

    private func runImport() throws -> (ImportSummary, URL) {
        let out = work.appendingPathComponent("out")
        let summary = try PasteImporter.run(snapshot: try makeSnapshot(), externalDirectory: work, output: out, deviceID: "dev")
        return (summary, out)
    }

    // MARK: tests

    func testImportsEveryItemAndFlagsUndecodableInsteadOfSkipping() throws {
        let (summary, out) = try runImport()
        XCTAssertEqual(summary.itemsRead, 4)
        XCTAssertEqual(summary.itemsImported, 4)
        XCTAssertEqual(summary.undecodable, ["id-3"])
        let puts = try EventLog.readAll(directory: out.appendingPathComponent("log")).compactMap { e -> ClipRecord? in
            if case .put(let r) = e { return r } else { return nil }
        }
        XCTAssertEqual(puts.count, 4)
        let bad = try XCTUnwrap(puts.first { $0.id == "paste:id-3" })
        XCTAssertTrue(bad.flags.contains("undecodable"))
        XCTAssertNotNil(bad.rawBlob)
        XCTAssertTrue(bad.representations.isEmpty)
    }

    func testPreservesTitleBoardAndOrderAndTimes() throws {
        let (_, out) = try runImport()
        let events = try EventLog.readAll(directory: out.appendingPathComponent("log"))
        let puts = events.compactMap { e -> ClipRecord? in if case .put(let r) = e { return r } else { return nil } }
        let titled = try XCTUnwrap(puts.first { $0.id == "paste:id-2" })
        XCTAssertEqual(titled.title, "ToggLite")
        XCTAssertEqual(titled.createdAt, 200 + 978_307_200)
        let pinned = try XCTUnwrap(puts.first { $0.id == "paste:id-4" })
        XCTAssertEqual(pinned.board, "list:SSH")
        XCTAssertEqual(pinned.boardOrder, 0)
        let recopied = try XCTUnwrap(puts.first { $0.id == "paste:id-1" })
        XCTAssertEqual(recopied.copiedAt, 300 + 978_307_200)
        XCTAssertEqual(recopied.createdAt, 100 + 978_307_200)
    }

    func testBoardsKeepTheirOrderAndApps() throws {
        let (_, out) = try runImport()
        let events = try EventLog.readAll(directory: out.appendingPathComponent("log"))
        let boards = events.compactMap { e -> BoardRecord? in if case .board(let b) = e { return b } else { return nil } }
        XCTAssertEqual(boards.map(\.name), ["Clipboard History", "SSH"])
        XCTAssertEqual(boards.map(\.index), [0, 3])
        XCTAssertNotNil(boards[1].attributesBlob)
        let apps = events.compactMap { e -> AppRecord? in if case .app(let a) = e { return a } else { return nil } }
        XCTAssertEqual(apps.map(\.bundleID), ["com.apple.Terminal"])
    }

    func testRerunDoesNotDuplicate() throws {
        let (_, out) = try runImport()
        let again = try PasteImporter.run(snapshot: work.appendingPathComponent("snap.sqlite"), externalDirectory: work, output: out, deviceID: "dev")
        XCTAssertEqual(again.itemsImported, 0)
        XCTAssertEqual(again.itemsAlreadyPresent, 4)
        let puts = try EventLog.readAll(directory: out.appendingPathComponent("log")).filter { if case .put = $0 { return true } else { return false } }
        XCTAssertEqual(puts.count, 4)
    }

    func testVerifierConfirmsFaithfulImportAndCatchesTampering() throws {
        let (_, out) = try runImport()
        let snapshot = work.appendingPathComponent("snap.sqlite")
        let ok = try PasteVerifier.verify(snapshot: snapshot, externalDirectory: work, output: out)
        XCTAssertTrue(ok.passed, "\(ok)")
        XCTAssertEqual(ok.sourceItems, 4)
        XCTAssertEqual(ok.mismatches, 0)
        // delete one payload blob; verification must fail
        let blobs = try BlobStore(root: out.appendingPathComponent("blobs"))
        let events = try EventLog.readAll(directory: out.appendingPathComponent("log"))
        let rec = events.compactMap { e -> ClipRecord? in if case .put(let r) = e, r.id == "paste:id-1" { return r } else { return nil } }.first!
        try FileManager.default.removeItem(at: blobs.path(for: rec.representations[0].blob))
        let bad = try PasteVerifier.verify(snapshot: snapshot, externalDirectory: work, output: out)
        XCTAssertFalse(bad.passed)
        XCTAssertEqual(bad.mismatches, 1)
    }
}
