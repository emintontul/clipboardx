import Foundation

public struct SearchDocument: Sendable {
    public let id: String
    public let title: String?
    public let text: String
    public let appName: String?
    public let copiedAt: Double
    public let board: String?
    public let boardOrder: Int?
    public let record: ClipRecord?
    public let deletedAt: Double?

    public init(id: String, title: String?, text: String, appName: String?, copiedAt: Double, board: String?,
                boardOrder: Int? = nil, record: ClipRecord? = nil, deletedAt: Double? = nil) {
        self.id = id
        self.title = title
        self.text = text
        self.appName = appName
        self.copiedAt = copiedAt
        self.board = board
        self.boardOrder = boardOrder
        self.record = record
        self.deletedAt = deletedAt
    }
}

public struct SearchHit: Equatable, Sendable {
    public let id: String
    public let score: Double
    public let reasons: [String]
    public let copiedAt: Double
}

/// Which items a query or listing covers. History is every item that is not on a pinboard. Deleted items only appear
/// in `.trash`.
public enum SearchScope: Equatable, Sendable {
    case all, history, board(String), trash
}

/// Derived, rebuildable index and query model. Compact columns ignore spacing and punctuation so "Togg Lite" finds
/// "ToggLite"; token columns support any-order word matching; both use FTS5 trigram so mid-word substrings match too.
public final class SearchIndex {
    public enum IndexError: Error { case outdated }

    public static let schemaVersion = 5
    private static let bodyLimit = 8_000
    private let db: SQLiteDatabase
    private var appNames: Set<String>?
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }()
    private let decoder = JSONDecoder()

    public convenience init(path: URL) throws { try self.init(database: try SQLiteDatabase(path: path)) }

    /// An empty index that lives only in memory. Used as a stand-in while the real one is rebuilt.
    public convenience init(inMemory: Bool) throws { try self.init(database: try SQLiteDatabase(location: ":memory:")) }

    private init(database: SQLiteDatabase) throws {
        db = database
        var version = 0, hasDocs = false
        try db.query("PRAGMA user_version") { version = $0.int(0) ?? 0 }
        try db.query("SELECT 1 FROM sqlite_master WHERE name='docs'") { _ in hasDocs = true }
        if hasDocs, version != Self.schemaVersion { throw IndexError.outdated }
        try db.execute("""
        CREATE TABLE IF NOT EXISTS docs(
          rowid INTEGER PRIMARY KEY, id TEXT UNIQUE NOT NULL, title TEXT, board TEXT, board_order INTEGER, copied REAL NOT NULL,
          title_c TEXT NOT NULL, body_c TEXT NOT NULL, app_c TEXT NOT NULL, title_n TEXT NOT NULL, body_n TEXT NOT NULL,
          rec TEXT NOT NULL DEFAULT '', fp TEXT, deleted_at REAL, kind TEXT NOT NULL DEFAULT 'text', app_id TEXT)
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS docs_copied ON docs(copied DESC)")
        try db.execute("CREATE INDEX IF NOT EXISTS docs_title ON docs(title_c) WHERE title_c <> ''")
        try db.execute("CREATE INDEX IF NOT EXISTS docs_app ON docs(app_c, copied DESC)")
        try db.execute("CREATE INDEX IF NOT EXISTS docs_board ON docs(board, board_order, copied DESC)")
        try db.execute("CREATE INDEX IF NOT EXISTS docs_fp ON docs(fp) WHERE fp IS NOT NULL")
        // Without this, "which apps have clips" scanned the whole table once per app and the shelf took seconds to open.
        try db.execute("CREATE INDEX IF NOT EXISTS docs_app_live ON docs(app_id, deleted_at)")
        try db.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
          title_c, body_c, app_c, title_n, body_n, tokenize='trigram')
        """)
        try db.execute("CREATE TABLE IF NOT EXISTS boards(id TEXT PRIMARY KEY, name TEXT NOT NULL, idx INTEGER NOT NULL, kind INTEGER NOT NULL, created REAL NOT NULL, attrs TEXT, deleted REAL)")
        try db.execute("CREATE TABLE IF NOT EXISTS links(url TEXT PRIMARY KEY, title TEXT, icon TEXT, image TEXT, fetched REAL NOT NULL, failed INTEGER NOT NULL)")
        try db.execute("CREATE TABLE IF NOT EXISTS apps(bundle TEXT PRIMARY KEY, name TEXT NOT NULL, icon TEXT)")
        try db.execute("PRAGMA user_version = \(Self.schemaVersion)")
    }

    // MARK: writing

    public func upsert(_ doc: SearchDocument) throws { try db.transaction { try insert(doc) } }

    /// Fast path for rebuilds: one transaction for many documents.
    public func bulk(fresh: Bool = false, _ body: (_ add: (SearchDocument) -> Void) throws -> Void) throws {
        var failure: Error?
        try db.transaction {
            try body { doc in
                guard failure == nil else { return }
                do { try insert(doc, replacing: !fresh) } catch { failure = error }
            }
        }
        if let failure { throw failure }
    }

    public func upsertBoard(_ board: BoardRecord) throws {
        try db.execute("INSERT OR REPLACE INTO boards(id,name,idx,kind,created,attrs,deleted) VALUES(?,?,?,?,?,?,?)",
                       [.text(board.id), .text(board.name), .int(board.index), .int(board.kind), .double(board.createdAt),
                        board.attributesBlob.map(SQLValue.text) ?? .null, board.deletedAt.map(SQLValue.double) ?? .null])
    }

    public func upsertApp(_ app: AppRecord) throws {
        try db.execute("INSERT OR REPLACE INTO apps(bundle,name,icon) VALUES(?,?,?)",
                       [.text(app.bundleID), .text(app.name), app.iconBlob.map(SQLValue.text) ?? .null])
    }

    public func upsertLink(_ link: LinkRecord) throws {
        try db.execute("INSERT OR REPLACE INTO links(url,title,icon,image,fetched,failed) VALUES(?,?,?,?,?,?)",
                       [.text(link.url), link.title.map(SQLValue.text) ?? .null, link.iconBlob.map(SQLValue.text) ?? .null,
                        link.imageBlob.map(SQLValue.text) ?? .null, .double(link.fetchedAt), .int(link.failed ? 1 : 0)])
    }

    public func link(url: String) throws -> LinkRecord? {
        var out: LinkRecord?
        try db.query("SELECT url,title,icon,image,fetched,failed FROM links WHERE url=?", [.text(url)]) { r in
            out = LinkRecord(url: r.text(0) ?? "", title: r.text(1), iconBlob: r.text(2), imageBlob: r.text(3),
                             fetchedAt: r.double(4) ?? 0, failed: (r.int(5) ?? 0) != 0)
        }
        return out
    }

    /// Writes boards, apps and link previews in one transaction (rebuilds).
    public func replaceMetadata(boards: [BoardRecord], apps: [AppRecord], links: [LinkRecord] = []) throws {
        try db.transaction {
            for board in boards { try upsertBoard(board) }
            for app in apps { try upsertApp(app) }
            for link in links { try upsertLink(link) }
        }
    }

    // MARK: reading

    /// Active pinboards in display order. Deleted ones are only reachable through `board(id:)`.
    public func boards() throws -> [BoardRecord] {
        var out: [BoardRecord] = []
        try db.query("SELECT id,name,idx,kind,created,attrs,deleted FROM boards WHERE deleted IS NULL ORDER BY idx, name") { r in
            out.append(Self.board(from: r))
        }
        return out
    }

    public func board(id: String) throws -> BoardRecord? {
        var out: BoardRecord?
        try db.query("SELECT id,name,idx,kind,created,attrs,deleted FROM boards WHERE id=?", [.text(id)]) { out = Self.board(from: $0) }
        return out
    }

    private static func board(from r: SQLiteReader.Row) -> BoardRecord {
        BoardRecord(id: r.text(0) ?? "", name: r.text(1) ?? "", index: r.int(2) ?? 0, kind: r.int(3) ?? 0,
                    createdAt: r.double(4) ?? 0, attributesBlob: r.text(5), deletedAt: r.double(6))
    }

    public func setDeleted(id: String, at: Double?) throws {
        try db.execute("UPDATE docs SET deleted_at=? WHERE id=?", [at.map(SQLValue.double) ?? .null, .text(id)])
    }

    public func deletedAt(id: String) throws -> Double? {
        var value: Double?
        try db.query("SELECT deleted_at FROM docs WHERE id=?", [.text(id)]) { value = $0.double(0) }
        return value
    }

    private static let appsInUseSQL = """
    SELECT a.bundle,a.name,a.icon FROM apps a
    WHERE EXISTS (SELECT 1 FROM docs d WHERE d.app_id = a.bundle AND d.deleted_at IS NULL)
    ORDER BY a.name COLLATE NOCASE
    """

    /// Apps that have at least one live clip, for the app filter list.
    public func appsInUse() throws -> [AppRecord] {
        var out: [AppRecord] = []
        try db.query(Self.appsInUseSQL) { out.append(AppRecord(bundleID: $0.text(0) ?? "", name: $0.text(1) ?? "", iconBlob: $0.text(2))) }
        return out
    }

    /// SQLite's plan for `appsInUse`, so a test can make sure it stays index-driven.
    func appsInUseQueryPlan() throws -> String {
        var lines: [String] = []
        try db.query("EXPLAIN QUERY PLAN " + Self.appsInUseSQL) { lines.append($0.text(3) ?? "") }
        return lines.joined(separator: "\n")
    }

    /// Ids of trashed clips deleted before `cutoff` (seconds since 1970).
    public func expiredTrashIDs(before cutoff: Double) throws -> [String] {
        var ids: [String] = []
        try db.query("SELECT id FROM docs WHERE deleted_at IS NOT NULL AND deleted_at < ?", [.double(cutoff)]) { ids.append($0.text(0) ?? "") }
        return ids
    }

    /// Removes a clip from the index for good. The event log keeps the purge event; blobs are never deleted.
    public func removeDocument(id: String) throws { try db.transaction { try remove(id: id) } }

    public func app(bundleID: String) throws -> AppRecord? {
        var out: AppRecord?
        try db.query("SELECT bundle,name,icon FROM apps WHERE bundle=?", [.text(bundleID)]) {
            out = AppRecord(bundleID: $0.text(0) ?? "", name: $0.text(1) ?? "", iconBlob: $0.text(2))
        }
        return out
    }

    public func nextBoardOrder(_ board: String) throws -> Int {
        var n = 0
        try db.query("SELECT COALESCE(MAX(board_order)+1,0) FROM docs WHERE board=? AND deleted_at IS NULL", [.text(board)]) { n = $0.int(0) ?? 0 }
        return n
    }

    public func recordID(fingerprint: String) throws -> String? {
        var id: String?
        try db.query("SELECT id FROM docs WHERE fp=? AND board IS NULL AND deleted_at IS NULL ORDER BY copied DESC LIMIT 1", [.text(fingerprint)]) { id = $0.text(0) }
        return id
    }

    public func records(ids: [String]) throws -> [ClipRecord] {
        guard !ids.isEmpty else { return [] }
        var byID: [String: ClipRecord] = [:]
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        try db.query("SELECT id,rec FROM docs WHERE id IN (\(marks))", ids.map(SQLValue.text)) { r in
            if let json = r.text(1), let record = try? decoder.decode(ClipRecord.self, from: Data(json.utf8)) { byID[r.text(0) ?? ""] = record }
        }
        return ids.compactMap { byID[$0] }
    }

    public func recentRecords(scope: SearchScope, limit: Int, offset: Int = 0, filters: ClipFilters = ClipFilters()) throws -> [ClipRecord] {
        let (clause, params) = Self.clause(scope, filters)
        let order: String
        switch scope {
        case .board: order = "COALESCE(d.board_order, 1000000), d.copied DESC"
        case .trash: order = "d.deleted_at DESC"
        default: order = "d.copied DESC"
        }
        var ids: [String] = []
        try db.query("SELECT d.id FROM docs d WHERE 1=1 \(clause) ORDER BY \(order) LIMIT ? OFFSET ?",
                     params + [.int(limit), .int(offset)]) { ids.append($0.text(0) ?? "") }
        return try records(ids: ids)
    }

    public func search(_ query: String, limit: Int, scope: SearchScope = .all, filters: ClipFilters = ClipFilters()) throws -> [SearchHit] {
        let qc = TextNormalizer.compact(query)
        let tokens = TextNormalizer.tokens(query)
        if qc.isEmpty { return try newest(limit: limit, scope: scope, filters: filters) }
        var hits = try candidates(qc: qc, tokens: tokens, scope: scope, filters: filters).compactMap { score($0, qc: qc, tokens: tokens) }
        if hits.count < 3, qc.count >= 4 {
            hits += try fuzzyCandidates(qc: qc, scope: scope, filters: filters).compactMap { fuzzyScore($0, qc: qc) }
        }
        var seen = Set<String>()
        return hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.copiedAt > $1.copiedAt }
            .filter { seen.insert($0.id).inserted }
            .prefix(limit).map { $0 }
    }

    // MARK: indexing

    private func insert(_ doc: SearchDocument, replacing: Bool = true) throws {
        if replacing { try remove(id: doc.id) }
        let body = String(doc.text.prefix(Self.bodyLimit))
        let titleC = TextNormalizer.compact(doc.title ?? "")
        let bodyC = TextNormalizer.compact(body)
        let appC = TextNormalizer.compact(doc.appName ?? "")
        let titleN = TextNormalizer.fold(doc.title ?? "")
        let bodyN = TextNormalizer.fold(body)
        let json = (try? doc.record.map { String(decoding: try encoder.encode($0), as: UTF8.self) }) ?? nil
        try db.execute("""
        INSERT INTO docs(id,title,board,board_order,copied,title_c,body_c,app_c,title_n,body_n,rec,fp,deleted_at,kind,app_id)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [.text(doc.id), doc.title.map(SQLValue.text) ?? .null, doc.board.map(SQLValue.text) ?? .null,
              doc.boardOrder.map(SQLValue.int) ?? .null, .double(doc.copiedAt), .text(titleC), .text(bodyC), .text(appC),
              .text(titleN), .text(bodyN), .text(json ?? ""), doc.record.map { .text($0.fingerprint) } ?? .null,
              doc.deletedAt.map(SQLValue.double) ?? .null, .text(ClipKind.of(doc.record, text: doc.text).rawValue),
              doc.record?.appBundleID.map(SQLValue.text) ?? .null])
        if !appC.isEmpty { appNames?.insert(appC) }
        var rowid = 0
        try db.query("SELECT rowid FROM docs WHERE id=?", [.text(doc.id)]) { rowid = $0.int(0) ?? 0 }
        try db.execute("INSERT INTO fts(rowid,title_c,body_c,app_c,title_n,body_n) VALUES(?,?,?,?,?,?)",
                       [.int(rowid), .text(titleC), .text(bodyC), .text(appC), .text(titleN), .text(bodyN)])
    }

    private func remove(id: String) throws {
        var rowid: Int?
        try db.query("SELECT rowid FROM docs WHERE id=?", [.text(id)]) { rowid = $0.int(0) }
        guard let rowid else { return }
        try db.execute("DELETE FROM fts WHERE rowid=?", [.int(rowid)])
        try db.execute("DELETE FROM docs WHERE rowid=?", [.int(rowid)])
    }

    // MARK: querying

    /// A candidate row. Body text is never loaded: which field matched is decided by separate FTS queries.
    private struct Candidate { let id: String; let copied: Double; let titleC: String; let appC: String; var inBody = false; var inTokens = false }

    private static let rowColumns = "d.id,d.copied,d.title_c,d.app_c"

    private static func clause(_ scope: SearchScope, _ filters: ClipFilters = ClipFilters()) -> (String, [SQLValue]) {
        var sql: String, params: [SQLValue] = []
        switch scope {
        case .all: sql = " AND d.deleted_at IS NULL"
        // The unary plus keeps SQLite on docs_copied; otherwise it walks every un-pinned clip via docs_board and sorts them.
        case .history: sql = " AND +d.board IS NULL AND d.deleted_at IS NULL"
        case .board(let id): sql = " AND d.board = ? AND d.deleted_at IS NULL"; params = [.text(id)]
        case .trash: sql = " AND d.deleted_at IS NOT NULL"
        }
        if !filters.kinds.isEmpty {
            sql += " AND d.kind IN (" + Array(repeating: "?", count: filters.kinds.count).joined(separator: ",") + ")"
            params += filters.kinds.map { SQLValue.text($0.rawValue) }.sorted { "\($0)" < "\($1)" }
        }
        if let app = filters.appName, !TextNormalizer.compact(app).isEmpty { sql += " AND d.app_c LIKE ?"; params.append(.text("%" + TextNormalizer.compact(app) + "%")) }
        if let after = filters.after { sql += " AND d.copied >= ?"; params.append(.double(after)) }
        if let before = filters.before { sql += " AND d.copied < ?"; params.append(.double(before)) }
        return (sql, params)
    }

    private func candidateRows(_ sql: String, _ params: [SQLValue] = []) throws -> [Candidate] {
        var out: [Candidate] = []
        try db.query(sql, params) { r in
            out.append(Candidate(id: r.text(0) ?? "", copied: r.double(1) ?? 0, titleC: r.text(2) ?? "", appC: r.text(3) ?? ""))
        }
        return out
    }

    private func newest(limit: Int, scope: SearchScope, filters: ClipFilters) throws -> [SearchHit] {
        let (clause, params) = Self.clause(scope, filters)
        return try candidateRows("SELECT \(Self.rowColumns) FROM docs d WHERE 1=1 \(clause) ORDER BY d.copied DESC LIMIT ?", params + [.int(limit)])
            .map { SearchHit(id: $0.id, score: 1, reasons: [], copiedAt: $0.copied) }
    }

    private static func phrase(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    private func match(_ expression: String, limit: Int, scope: SearchScope, filters: ClipFilters) throws -> [Candidate] {
        let (clause, params) = Self.clause(scope, filters)
        return try candidateRows("""
        SELECT \(Self.rowColumns) FROM fts JOIN docs d ON d.rowid=fts.rowid
        WHERE fts MATCH ? \(clause) ORDER BY fts.rowid DESC LIMIT ?
        """, [.text(expression)] + params + [.int(limit)])
    }

    private func candidates(qc: String, tokens: [String], scope: SearchScope, filters: ClipFilters) throws -> [Candidate] {
        guard qc.count >= 3 else { return try shortCandidates(qc, scope: scope, filters: filters) }
        var merged: [String: Candidate] = [:]
        func add(_ rows: [Candidate], body: Bool = false, tokens: Bool = false) {
            for var row in rows {
                if let old = merged[row.id] {
                    row = Candidate(id: old.id, copied: old.copied, titleC: old.titleC, appC: old.appC,
                                    inBody: old.inBody || body, inTokens: old.inTokens || tokens)
                } else { row.inBody = body; row.inTokens = tokens }
                merged[row.id] = row
            }
        }
        add(try match("title_c : \(Self.phrase(qc))", limit: 100, scope: scope, filters: filters))
        add(try match("app_c : \(Self.phrase(qc))", limit: 50, scope: scope, filters: filters))
        add(try match("body_c : \(Self.phrase(qc))", limit: 150, scope: scope, filters: filters), body: true)
        let long = tokens.filter { $0.count >= 3 }
        if tokens.count > 1, long.count == tokens.count {
            let body = long.map { "body_n : \(Self.phrase($0))" }.joined(separator: " AND ")
            let title = long.map { "title_n : \(Self.phrase($0))" }.joined(separator: " AND ")
            add(try match("(\(body)) OR (\(title))", limit: 150, scope: scope, filters: filters), tokens: true)
        }
        return Array(merged.values)
    }

    /// One or two characters: trigram cannot index these. Fields use partial indexes; one character never searches
    /// bodies, two characters only the newest 60.
    private func shortCandidates(_ qc: String, scope: SearchScope, filters: ClipFilters) throws -> [Candidate] {
        let like = SQLValue.text("%" + qc.replacingOccurrences(of: "%", with: "") + "%")
        let (clause, scopeParams) = Self.clause(scope, filters)
        let apps = try knownApps().filter { $0.contains(qc) }.sorted()
        var fields = try candidateRows("""
        SELECT \(Self.rowColumns) FROM docs d INDEXED BY docs_title WHERE d.title_c <> '' AND d.title_c LIKE ? \(clause)
        ORDER BY d.copied DESC LIMIT 100
        """, [like] + scopeParams)
        for app in apps.prefix(20) {
            fields += try candidateRows("SELECT \(Self.rowColumns) FROM docs d WHERE d.app_c = ? \(clause) ORDER BY d.copied DESC LIMIT 30",
                                        [.text(app)] + scopeParams)
        }
        guard qc.count == 2 else { return fields }
        let bodies = try candidateRows("""
        SELECT d.id,d.copied,d.title_c,d.app_c FROM (SELECT id,copied,title_c,app_c,body_c FROM docs d WHERE 1=1 \(clause)
        ORDER BY copied DESC LIMIT 60) d WHERE d.body_c LIKE ?
        """, scopeParams + [like]).map { Candidate(id: $0.id, copied: $0.copied, titleC: $0.titleC, appC: $0.appC, inBody: true) }
        return fields + bodies
    }

    /// Distinct compact app names, loaded once and kept current by `insert`; a few hundred strings at most.
    private func knownApps() throws -> Set<String> {
        if let appNames { return appNames }
        var names = Set<String>()
        try db.query("SELECT DISTINCT app_c FROM docs WHERE app_c <> ''") { names.insert($0.text(0) ?? "") }
        appNames = names
        return names
    }

    private func fuzzyCandidates(qc: String, scope: SearchScope, filters: ClipFilters) throws -> [Candidate] {
        let grams = Self.trigrams(qc)
        guard !grams.isEmpty else { return [] }
        return try match(grams.map { "title_c : \(Self.phrase($0))" }.joined(separator: " OR "), limit: 300, scope: scope, filters: filters)
    }

    private static func trigrams(_ text: String) -> [String] {
        let chars = Array(text)
        guard chars.count >= 3 else { return [] }
        return Set((0...(chars.count - 3)).map { String(chars[$0..<($0 + 3)]) }).sorted()
    }

    // MARK: scoring

    private func score(_ row: Candidate, qc: String, tokens: [String]) -> SearchHit? {
        var best = 0.0
        var reasons: [String] = []
        if !row.titleC.isEmpty {
            if row.titleC == qc { best = 100; reasons.append("title: exact") }
            else if row.titleC.hasPrefix(qc) { best = 90; reasons.append("title") }
            else if row.titleC.contains(qc) { best = 80; reasons.append("title") }
        }
        if best == 0, row.appC.contains(qc) { best = 55; reasons.append("app") }
        if row.inBody { best = max(best, 65); reasons.append("content") }
        else if row.inTokens { best = max(best, 60); reasons.append("content: all words") }
        guard best > 0 else { return nil }
        return SearchHit(id: row.id, score: best, reasons: reasons, copiedAt: row.copied)
    }

    private func fuzzyScore(_ row: Candidate, qc: String) -> SearchHit? {
        guard !row.titleC.isEmpty else { return nil }
        let a = Set(Self.trigrams(qc)), b = Set(Self.trigrams(row.titleC))
        guard !a.isEmpty else { return nil }
        let similarity = Double(a.intersection(b).count) / Double(a.count)
        guard similarity >= 0.5 else { return nil }
        return SearchHit(id: row.id, score: 40 + similarity * 10, reasons: ["typo tolerance"], copiedAt: row.copied)
    }
}
