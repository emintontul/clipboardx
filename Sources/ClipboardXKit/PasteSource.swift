import Foundation

/// Rows read from a Paste snapshot. Core Data timestamps count from 2001-01-01; `unixOffset` converts them.
struct PasteSource {
    static let unixOffset = 978_307_200.0

    struct Item {
        let pk: Int
        let identifier: String
        let rawKind: Int
        let createdAt: Double
        let copiedAt: Double
        let title: String?
        let board: String?
        let boardOrder: Int?
        let appBundleID: String?
        let preview: Data?
        let blob: Data
    }

    struct Board { let pk: Int; let identifier: String; let name: String; let kind: Int; let createdAt: Double; let index: Int; let attributes: Data? }
    struct App { let pk: Int; let bundleID: String; let name: String; let icon: Data? }

    let reader: SQLiteReader

    init(snapshot: URL) throws { reader = try SQLiteReader(path: snapshot) }

    func apps() throws -> [App] {
        var out: [App] = []
        try reader.forEachRow("SELECT Z_PK,ZBUNDLEIDENTIFIER,ZNAME,ZRAWICON FROM ZAPPLICATIONENTITY ORDER BY Z_PK") { r in
            guard let bundle = r.text(1) else { return }
            out.append(App(pk: r.int(0) ?? 0, bundleID: bundle, name: r.text(2) ?? bundle, icon: r.blob(3)))
        }
        return out
    }

    func boards() throws -> [Board] {
        var out: [Board] = []
        let sql = """
        SELECT l.Z_PK,l.ZIDENTIFIER,l.ZNAME,l.ZRAWTYPE,l.ZCREATEDAT,COALESCE(m.ZINDEX,9999),l.ZRAWATTRIBUTES
        FROM ZLISTENTITY l LEFT JOIN ZLISTMETADATAENTITY m ON m.ZLIST=l.Z_PK ORDER BY COALESCE(m.ZINDEX,9999),l.Z_PK
        """
        try reader.forEachRow(sql) { r in
            guard let id = r.text(1) else { return }
            out.append(Board(pk: r.int(0) ?? 0, identifier: id, name: r.text(2) ?? "", kind: r.int(3) ?? 0,
                             createdAt: (r.double(4) ?? 0) + Self.unixOffset, index: r.int(5) ?? 0, attributes: r.blob(6)))
        }
        return out
    }

    /// Streams items oldest-first so the log reads chronologically.
    func forEachItem(_ body: (Item) throws -> Void) throws {
        let sql = """
        SELECT i.Z_PK,i.ZIDENTIFIER,i.ZRAWTYPE,i.ZCREATEDAT,i.ZTIMESTAMP,i.ZTITLE,l.ZIDENTIFIER,i.ZDISPLAYORDERINPINBOARD,
               a.ZBUNDLEIDENTIFIER,i.ZRAWPREVIEW,d.ZRAWPASTEBOARDITEMS
        FROM ZITEMENTITY i
        JOIN ZITEMDATAENTITY d ON d.ZITEM=i.Z_PK
        LEFT JOIN ZLISTENTITY l ON l.Z_PK=i.ZLIST
        LEFT JOIN ZAPPLICATIONENTITY a ON a.Z_PK=i.ZSOURCEAPPLICATION
        ORDER BY COALESCE(i.ZTIMESTAMP,i.ZCREATEDAT),i.Z_PK
        """
        try reader.forEachRow(sql) { r in
            let pk = r.int(0) ?? 0
            let created = r.double(3) ?? r.double(4) ?? 0
            let copied = r.double(4) ?? created
            let title = r.text(5).flatMap { $0.isEmpty ? nil : $0 }
            try body(Item(pk: pk, identifier: r.text(1) ?? "pk-\(pk)", rawKind: r.int(2) ?? 0,
                          createdAt: created + Self.unixOffset, copiedAt: copied + Self.unixOffset, title: title,
                          board: r.text(6), boardOrder: r.int(7), appBundleID: r.text(8), preview: r.blob(9),
                          blob: r.blob(10) ?? Data()))
        }
    }

    func itemCount() throws -> Int {
        var n = 0
        try reader.forEachRow("SELECT count(*) FROM ZITEMENTITY") { n = $0.int(0) ?? 0 }
        return n
    }
}
