import Foundation

public struct BackupResult: Sendable {
    public let blobsPacked: Int
    public let packsWritten: Int
    public let logFilesCopied: Int
}

public struct RestoreResult: Sendable {
    public let blobsRestored: Int
    public let logFilesRestored: Int
}

public struct BackupReport: Sendable {
    public let libraryBlobs: Int
    public let missingFromBackup: Int
    public let missingLogFiles: Int
    public let brokenPacks: Int
    public var complete: Bool { missingFromBackup == 0 && missingLogFiles == 0 && brokenPacks == 0 }
}

/// Backs the library up as large immutable packs plus copies of the event-log segments.
///
/// A pack is `CXP1` followed by records `[64-byte hex id][8-byte big-endian length][stored bytes]`.
/// A pack counts only when its `.idx` exists and records the pack's exact size; `.idx` is written last, so a crash leaves
/// an ignorable pack. Packs and indexes never change once written, which keeps iCloud syncing conflict-free.
public enum LibraryBackup {
    public static let defaultPackSize = 64 * 1024 * 1024
    private static let magic = Data("CXP1".utf8)

    public enum BackupError: Error { case corruptPack(String), badRecord(String) }

    // MARK: backup

    public static func backup(library: URL, destination: URL, packSize: Int = defaultPackSize, deviceID: String,
                              store sharedStore: BlobStore? = nil) throws -> BackupResult {
        let fm = FileManager.default
        let packs = destination.appendingPathComponent("packs", isDirectory: true)
        try fm.createDirectory(at: packs, withIntermediateDirectories: true)
        let copied = try copyLogs(from: library.appendingPathComponent("log"), to: destination.appendingPathComponent("log"))

        let store = try sharedStore ?? BlobStore(root: library.appendingPathComponent("blobs"))
        let existing = try validPacks(in: packs)
        let packed = Set(existing.flatMap(\.ids))
        let pending = store.cachedIDs().filter { !packed.contains($0) }.sorted()
        var sequence = (existing.map(\.sequence).max() ?? 0) + 1
        var written = 0

        var writer: PackWriter?
        for id in pending {
            if writer == nil { writer = try PackWriter(directory: packs, deviceID: deviceID, sequence: sequence) }
            try writer?.add(id: id, stored: try store.storedBytes(id))
            if let current = writer, current.size >= packSize {
                try current.seal(); writer = nil; sequence += 1; written += 1
            }
        }
        if let current = writer { try current.seal(); written += 1 }
        return BackupResult(blobsPacked: pending.count, packsWritten: written, logFilesCopied: copied)
    }

    /// Cheap fingerprint of "has anything been written since": every new blob comes with a log event, so the log segment
    /// names and sizes are enough. Lets the scheduler skip a full scan of hundreds of thousands of blob files.
    public static func changeSignature(library: URL) -> String {
        let dir = library.appendingPathComponent("log")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
        return names.map { "\($0):\(size(dir.appendingPathComponent($0)))" }.joined(separator: "|")
    }

    // MARK: restore

    public static func restore(from backup: URL, to library: URL) throws -> RestoreResult {
        let store = try BlobStore(root: library.appendingPathComponent("blobs"))
        var restored = 0
        for pack in try validPacks(in: backup.appendingPathComponent("packs")) {
            let bytes = try Data(contentsOf: pack.file, options: .mappedIfSafe)
            guard bytes.starts(with: magic) else { throw BackupError.corruptPack(pack.file.lastPathComponent) }
            var offset = magic.count
            while offset < bytes.count {
                guard offset + 72 <= bytes.count, let id = String(data: bytes[offset..<(offset + 64)], encoding: .ascii) else {
                    throw BackupError.corruptPack(pack.file.lastPathComponent)
                }
                let length = bytes[(offset + 64)..<(offset + 72)].reduce(0) { ($0 << 8) | Int($1) }
                guard offset + 72 + length <= bytes.count else { throw BackupError.corruptPack(pack.file.lastPathComponent) }
                let stored = Data(bytes[(offset + 72)..<(offset + 72 + length)])
                let had = store.contains(id)
                try store.importStored(id, stored: stored)
                if !had { restored += 1 }
                offset += 72 + length
            }
        }
        let logs = try copyLogs(from: backup.appendingPathComponent("log"), to: library.appendingPathComponent("log"))
        return RestoreResult(blobsRestored: restored, logFilesRestored: logs)
    }

    // MARK: verify

    /// Cheap completeness check: every library blob is listed in a valid pack index and every log segment is backed up.
    public static func verify(library: URL, backup: URL, store sharedStore: BlobStore? = nil) throws -> BackupReport {
        let store = try sharedStore ?? BlobStore(root: library.appendingPathComponent("blobs"))
        let packsDir = backup.appendingPathComponent("packs")
        let valid = try validPacks(in: packsDir)
        let packed = Set(valid.flatMap(\.ids))
        let local = store.cachedIDs()
        let fm = FileManager.default
        let packFiles = ((try? fm.contentsOfDirectory(atPath: packsDir.path)) ?? []).filter { $0.hasSuffix(".idx") }.count
        let logSource = library.appendingPathComponent("log"), logBackup = backup.appendingPathComponent("log")
        let missingLogs = ((try? fm.contentsOfDirectory(atPath: logSource.path)) ?? []).filter { $0.hasSuffix(".jsonl") }.filter {
            size(logBackup.appendingPathComponent($0)) != size(logSource.appendingPathComponent($0))
        }.count
        return BackupReport(libraryBlobs: local.count, missingFromBackup: local.filter { !packed.contains($0) }.count,
                            missingLogFiles: missingLogs, brokenPacks: packFiles - valid.count)
    }

    // MARK: helpers

    struct ValidPack { let sequence: Int; let file: URL; let ids: [String] }

    static func validPacks(in directory: URL) throws -> [ValidPack] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [ValidPack] = []
        for name in names.sorted() where name.hasSuffix(".idx") {
            let idx = directory.appendingPathComponent(name)
            let pack = directory.appendingPathComponent(String(name.dropLast(4)) + ".cxp")
            guard let text = try? String(contentsOf: idx, encoding: .utf8) else { continue }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let header = lines.first, header.hasPrefix("CXI1 "), let expected = Int(header.dropFirst(5)),
                  size(pack) == expected else { continue }
            lines.removeFirst()
            let sequence = Int(name.dropLast(4).split(separator: "-").last ?? "") ?? 0
            out.append(ValidPack(sequence: sequence, file: pack, ids: lines))
        }
        return out
    }

    private static func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? -1
    }

    /// Copies `.jsonl` segments whose size differs. Logs are append-only, so a size change means new events.
    private static func copyLogs(from source: URL, to destination: URL) throws -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: source.path) else { return 0 }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var copied = 0
        for name in names.sorted() where name.hasSuffix(".jsonl") {
            let from = source.appendingPathComponent(name), to = destination.appendingPathComponent(name)
            if size(to) == size(from) { continue }
            let temp = destination.appendingPathComponent(".\(name).tmp")
            try? fm.removeItem(at: temp)
            try fm.copyItem(at: from, to: temp)
            try? fm.removeItem(at: to)
            try fm.moveItem(at: temp, to: to)
            copied += 1
        }
        return copied
    }

    private final class PackWriter {
        private let finalPack: URL, finalIndex: URL, tempPack: URL
        private let handle: FileHandle
        private var ids: [String] = []
        private(set) var size = 0

        init(directory: URL, deviceID: String, sequence: Int) throws {
            let base = String(format: "pack-%@-%05d", deviceID, sequence)
            finalPack = directory.appendingPathComponent(base + ".cxp")
            finalIndex = directory.appendingPathComponent(base + ".idx")
            tempPack = directory.appendingPathComponent(".\(base).cxp.tmp")
            try? FileManager.default.removeItem(at: finalIndex)
            FileManager.default.createFile(atPath: tempPack.path, contents: nil)
            handle = try FileHandle(forWritingTo: tempPack)
            try handle.write(contentsOf: LibraryBackup.magic)
            size = LibraryBackup.magic.count
        }

        func add(id: String, stored: Data) throws {
            var length = UInt64(stored.count).bigEndian
            var record = Data(id.utf8)
            record.append(Data(bytes: &length, count: 8))
            record.append(stored)
            try handle.write(contentsOf: record)
            size += record.count
            ids.append(id)
        }

        func seal() throws {
            try handle.synchronize()
            try handle.close()
            try? FileManager.default.removeItem(at: finalPack)
            try FileManager.default.moveItem(at: tempPack, to: finalPack)
            let tempIndex = finalIndex.deletingLastPathComponent().appendingPathComponent(".\(finalIndex.lastPathComponent).tmp")
            try (["CXI1 \(size)"] + ids).joined(separator: "\n").write(to: tempIndex, atomically: false, encoding: .utf8)
            try FileManager.default.moveItem(at: tempIndex, to: finalIndex)
        }
    }
}
