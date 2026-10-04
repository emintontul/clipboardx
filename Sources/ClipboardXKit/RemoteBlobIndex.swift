import Foundation

/// Reads blobs out of another Mac's backup packs. Packs never change once written, so each one is scanned once and its
/// record offsets are remembered in a small database next to the library.
final class RemoteBlobIndex {
    struct Location { let pack: URL; let offset: Int; let length: Int }

    private let db: SQLiteDatabase
    private let lock = NSLock()
    private var packDirectories: [URL] = []

    init(library: URL) throws {
        db = try SQLiteDatabase(path: library.appendingPathComponent("remote-blobs.sqlite"))
        try db.execute("CREATE TABLE IF NOT EXISTS packs(path TEXT PRIMARY KEY, size INTEGER NOT NULL)")
        try db.execute("CREATE TABLE IF NOT EXISTS blobs(id TEXT NOT NULL, pack TEXT NOT NULL, offset INTEGER NOT NULL, length INTEGER NOT NULL, PRIMARY KEY(id, pack))")
    }

    func setPackDirectories(_ directories: [URL]) {
        lock.lock(); defer { lock.unlock() }
        packDirectories = directories
    }

    /// Scans packs that were not seen before (or have grown). Incomplete packs (no valid index yet) are skipped.
    func refresh() {
        lock.lock(); defer { lock.unlock() }
        for directory in packDirectories {
            for pack in (try? LibraryBackup.validPacks(in: directory)) ?? [] {
                let size = (try? FileManager.default.attributesOfItem(atPath: pack.file.path)[.size] as? Int) ?? -1
                var known = -1
                try? db.query("SELECT size FROM packs WHERE path=?", [.text(pack.file.path)]) { known = $0.int(0) ?? -1 }
                guard known != size, size > 0, let entries = try? PackReader.scan(pack.file) else { continue }
                try? db.transaction {
                    for e in entries {
                        try db.execute("INSERT OR IGNORE INTO blobs(id,pack,offset,length) VALUES(?,?,?,?)", [.text(e.id), .text(pack.file.path), .int(e.offset), .int(e.length)])
                    }
                    try db.execute("INSERT OR REPLACE INTO packs(path,size) VALUES(?,?)", [.text(pack.file.path), .int(size)])
                }
            }
        }
    }

    func location(of id: String) -> Location? {
        lock.lock(); defer { lock.unlock() }
        var found: Location?
        try? db.query("SELECT pack,offset,length FROM blobs WHERE id=?", [.text(id)]) { r in
            guard found == nil, let path = r.text(0), FileManager.default.fileExists(atPath: path) else { return }
            found = Location(pack: URL(fileURLWithPath: path), offset: r.int(1) ?? 0, length: r.int(2) ?? 0)
        }
        return found
    }

    /// The blob's stored bytes (as written in the pack), or nil when no known pack has it.
    func storedBytes(_ id: String) -> Data? {
        if location(of: id) == nil { refresh() }
        guard let at = location(of: id) else { return nil }
        return try? PackReader.read(at.pack, offset: at.offset, length: at.length)
    }
}

enum PackReader {
    struct Entry { let id: String; let offset: Int; let length: Int }
    private static let magic = Data("CXP1".utf8)

    /// Walks the record headers with seeks, never reading the payloads.
    static func scan(_ pack: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: pack)
        defer { try? handle.close() }
        let end = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        guard try handle.read(upToCount: 4) == magic else { return [] }
        var entries: [Entry] = []
        var position = 4
        while position + 72 <= end {
            try handle.seek(toOffset: UInt64(position))
            guard let header = try handle.read(upToCount: 72), header.count == 72,
                  let id = String(data: header.prefix(64), encoding: .ascii) else { break }
            let length = header.suffix(8).reduce(0) { ($0 << 8) | Int($1) }
            guard position + 72 + length <= end else { break }
            entries.append(Entry(id: id, offset: position + 72, length: length))
            position += 72 + length
        }
        return entries
    }

    static func read(_ pack: URL, offset: Int, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: pack)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
    }
}
