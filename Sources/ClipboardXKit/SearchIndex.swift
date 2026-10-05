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

    public init(id: String, title: String?, text: String, appName: String?, copiedAt: Double, board: String?,
                boardOrder: Int? = nil, record: ClipRecord? = nil) {
        self.id = id
        self.title = title
        self.text = text
        self.appName = appName
        self.copiedAt = copiedAt
        self.board = board
        self.boardOrder = boardOrder
        self.record = record
    }
}

public struct SearchHit: Equatable, Sendable {
    public let id: String
    public let score: Double
    public let reasons: [String]
    public let copiedAt: Double
}

/// Which items a query or listing covers. History is every item that is not on a pinboard.
public enum SearchScope: Equatable, Sendable {
    case all, history, board(String)
}

/// Derived, rebuildable index and query model. Compact columns ignore spacing and punctuation so "Togg Lite" finds
/// "ToggLite"; token columns support any-order word matching; both use FTS5 trigram so mid-word substrings match too.
public final class SearchIndex {
    public enum IndexError: Error { case outdated }

    public static let schemaVersion = 2
    private static let bodyLimit = 8_000
    private let db: SQLiteDatabase
    private var appNames: Set<String>?
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }()
    private let decoder = JSONDecoder()

    public init(path: URL) throws {
        db = try SQLiteDatabase(path: path)
        var version = 0, hasDocs = false
        try db.query("PRAGMA user_version") { version = $0.int(0) ?? 0 }
        try db.query("SELECT 1 FROM sqlite_master WHERE name='docs'") { _ in hasDocs = true }
        if hasDocs, version != Self.schemaVersion { throw IndexError.outdated }
        try db.execute("""
        CREATE TABLE IF NOT EXISTS docs(
          rowid INTEGER PRIMARY KEY, id TEXT UNIQUE NOT NULL, title TEXT, board TEXT, board_order INTEGER, copied REAL NOT NULL,
          title_c TEXT NOT NULL, body_c TEXT NOT NULL, app_c TEXT NOT NULL, title_n TEXT NOT NULL, body_n TEXT NOT NULL,
          rec TEXT NOT NULL DEFAULT '', fp TEXT)
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS docs_copied ON docs(copied DESC)")
        try db.execute("CREATE INDEX IF NOT EXISTS docs_title ON docs(title_c) WHERE title_c <> ''")
        try db.execute("CREATE INDEX IF NOT EXISTS docs_app ON docs(app_c, copied DESC)")
        try db.execute("CREATE INDEX IF NOT EXISTS docs_board ON docs(board, board_order, copied DESC)")
        try db.execute("CREATE INDEX IF NOT EXISTS docs_fp ON docs(fp) WHERE fp IS NOT NULL")
        try db.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
          title_c, body_c, app_c, title_n, body_n, tokenize='trigram')
        """)
        try db.execute("CREATE TABLE IF NOT EXISTS boards(id TEXT PRIMARY KEY, name TEXT NOT NULL, idx INTEGER NOT NULL, kind INTEGER NOT NULL, created REAL NOT NULL, attrs TEXT)")
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
        try db.execute("INSERT OR REPLACE INTO boards(id,name,idx,kind,created,attrs) VALUES(?,?,?,?,?,?)",
                       [.text(board.id), .text(board.name), .int(board.index), .int(board.kind), .double(board.createdAt),
                        board.attributesBlob.map(SQLValue.text) ?? .null])
    }

    public func removeBoard(_ id: String) throws {
        try db.execute("DELETE FROM boards WHERE id=?", [.text(id)])
    }

    public func upsertApp(_ app: AppRecord) throws {
        try db.execute("INSERT OR REPLACE INTO apps(bundle,name,icon) VALUES(?,?,?)",
                       [.text(app.bundleID), .text(app.name), app.iconBlob.map(SQLValue.text) ?? .null])
    }

    /// Writes boards and apps in one transaction (rebuilds).
    public func replaceMetadata(boards: [BoardRecord], apps: [AppRecord]) throws {
        try db.transaction {
            for board in boards { try upsertBoard(board) }
            for app in apps { try upsertApp(app) }
        }
    }

    // MARK: reading

    public func boards() throws -> [BoardRecord] {
        var out: [BoardRecord] = []
        try db.query("SELECT id,name,idx,kind,created,attrs FROM boards ORDER BY idx, name") { r in
            out.append(BoardRecord(id: r.text(0) ?? "", name: r.text(1) ?? "", index: r.int(2) ?? 0, kind: r.int(3) ?? 0,
                                   createdAt: r.double(4) ?? 0, attributesBlob: r.text(5)))
        }
        return out
    }

    public func records(inBoard board: String) throws -> [ClipRecord] {
        var ids: [String] = []
        try db.query("SELECT id FROM docs WHERE board=? ORDER BY board_order, copied DESC", [.text(board)]) {
            ids.append($0.text(0) ?? "")
        }
        return try records(ids: ids)
    }

    public func app(bundleID: String) throws -> AppRecord? {
        var out: AppRecord?
        try db.query("SELECT bundle,name,icon FROM apps WHERE bundle=?", [.text(bundleID)]) {
            out = AppRecord(bundleID: $0.text(0) ?? "", name: $0.text(1) ?? "", iconBlob: $0.text(2))
        }
        return out
    }

    public func nextBoardOrder(_ board: String) throws -> Int {
        var n = 0
        try db.query("SELECT COALESCE(MAX(board_order)+1,0) FROM docs WHERE board=?", [.text(board)]) { n = $0.int(0) ?? 0 }
        return n
    }

    public func recordID(fingerprint: String) throws -> String? {
        var id: String?
        try db.query("SELECT id FROM docs WHERE fp=? AND board IS NULL ORDER BY copied DESC LIMIT 1", [.text(fingerprint)]) { id = $0.text(0) }
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

    public func recentRecords(scope: SearchScope, limit: Int, offset: Int = 0) throws -> [ClipRecord] {
        let (clause, params) = Self.clause(scope)
        let order: String
        if case .board = scope { order = "COALESCE(d.board_order, 1000000), d.copied DESC" } else { order = "d.copied DESC" }
        var ids: [String] = []
        try db.query("SELECT d.id FROM docs d WHERE 1=1 \(clause) ORDER BY \(order) LIMIT ? OFFSET ?",
                     params + [.int(limit), .int(offset)]) { ids.append($0.text(0) ?? "") }
        return try records(ids: ids)
    }

    public func search(_ query: String, limit: Int, scope: SearchScope = .all) throws -> [SearchHit] {
        let qc = TextNormalizer.compact(query)
        let tokens = TextNormalizer.tokens(query)
        if qc.isEmpty { return try newest(limit: limit, scope: scope) }
        var hits = try candidates(qc: qc, tokens: tokens, scope: scope).compactMap { score($0, qc: qc, tokens: tokens) }
        if hits.count < 3, qc.count >= 4 {
            hits += try fuzzyCandidates(qc: qc, scope: scope).compactMap { fuzzyScore($0, qc: qc) }
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
        INSERT INTO docs(id,title,board,board_order,copied,title_c,body_c,app_c,title_n,body_n,rec,fp) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
        """, [.text(doc.id), doc.title.map(SQLValue.text) ?? .null, doc.board.map(SQLValue.text) ?? .null,
              doc.boardOrder.map(SQLValue.int) ?? .null, .double(doc.copiedAt), .text(titleC), .text(bodyC), .text(appC),
              .text(titleN), .text(bodyN), .text(json ?? ""), doc.record.map { .text($0.fingerprint) } ?? .null])
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

    private static func clause(_ scope: SearchScope) -> (String, [SQLValue]) {
        switch scope {
        case .all: return ("", [])
        case .history: return (" AND d.board IS NULL", [])
        case .board(let id): return (" AND d.board = ?", [.text(id)])
        }
    }

    private func candidateRows(_ sql: String, _ params: [SQLValue] = []) throws -> [Candidate] {
        var out: [Candidate] = []
        try db.query(sql, params) { r in
            out.append(Candidate(id: r.text(0) ?? "", copied: r.double(1) ?? 0, titleC: r.text(2) ?? "", appC: r.text(3) ?? ""))
        }
        return out
    }

    private func newest(limit: Int, scope: SearchScope) throws -> [SearchHit] {
        let (clause, params) = Self.clause(scope)
        return try candidateRows("SELECT \(Self.rowColumns) FROM docs d WHERE 1=1 \(clause) ORDER BY d.copied DESC LIMIT ?", params + [.int(limit)])
            .map { SearchHit(id: $0.id, score: 1, reasons: [], copiedAt: $0.copied) }
    }

    private static func phrase(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    private func match(_ expression: String, limit: Int, scope: SearchScope) throws -> [Candidate] {
        let (clause, params) = Self.clause(scope)
        return try candidateRows("""
        SELECT \(Self.rowColumns) FROM fts JOIN docs d ON d.rowid=fts.rowid
        WHERE fts MATCH ? \(clause) ORDER BY fts.rowid DESC LIMIT ?
        """, [.text(expression)] + params + [.int(limit)])
    }

    private func candidates(qc: String, tokens: [String], scope: SearchScope) throws -> [Candidate] {
        guard qc.count >= 3 else { return try shortCandidates(qc, scope: scope) }
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
        add(try match("title_c : \(Self.phrase(qc))", limit: 100, scope: scope))
        add(try match("app_c : \(Self.phrase(qc))", limit: 50, scope: scope))
        add(try match("body_c : \(Self.phrase(qc))", limit: 150, scope: scope), body: true)
        let long = tokens.filter { $0.count >= 3 }
        if tokens.count > 1, long.count == tokens.count {
            let body = long.map { "body_n : \(Self.phrase($0))" }.joined(separator: " AND ")
            let title = long.map { "title_n : \(Self.phrase($0))" }.joined(separator: " AND ")
            add(try match("(\(body)) OR (\(title))", limit: 150, scope: scope), tokens: true)
        }
        return Array(merged.values)
    }

    /// One or two characters: trigram cannot index these. Fields use partial indexes; one character never searches
    /// bodies, two characters only the newest 60.
    private func shortCandidates(_ qc: String, scope: SearchScope) throws -> [Candidate] {
        let like = SQLValue.text("%" + qc.replacingOccurrences(of: "%", with: "") + "%")
        let (clause, scopeParams) = Self.clause(scope)
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

    private func fuzzyCandidates(qc: String, scope: SearchScope) throws -> [Candidate] {
        let grams = Self.trigrams(qc)
        guard !grams.isEmpty else { return [] }
        return try match(grams.map { "title_c : \(Self.phrase($0))" }.joined(separator: " OR "), limit: 300, scope: scope)
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
