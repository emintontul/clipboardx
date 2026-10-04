import Foundation

public struct VerificationResult: Sendable {
    public let sourceItems: Int
    public let verifiedItems: Int
    public let mismatches: Int
    public let missingRecords: Int
    public let problemIDs: [String]
    public var passed: Bool { mismatches == 0 && missingRecords == 0 && verifiedItems == sourceItems }
}

/// Re-decodes every source item and checks the imported record, payload hashes and blob files. Prints no content.
public enum PasteVerifier {
    public static func verify(snapshot: URL, externalDirectory: URL, output: URL,
                              progress: ((Int, Int) -> Void)? = nil) throws -> VerificationResult {
        let source = try PasteSource(snapshot: snapshot)
        let blobs = try BlobStore(root: output.appendingPathComponent("blobs"))
        var records: [String: ClipRecord] = [:]
        for case .put(let r) in try EventLog.readAll(directory: output.appendingPathComponent("log")) { records[r.id] = r }

        let total = try source.itemCount()
        var read = 0, verified = 0, mismatches = 0, missing = 0
        var problems: [String] = []
        try source.forEachItem { item in
            read += 1
            let id = PasteImporter.idPrefix + item.identifier
            guard let record = records[id] else { missing += 1; problems.append(item.identifier); return }
            if try matches(record, item: item, blobs: blobs, externalDirectory: externalDirectory) {
                verified += 1
            } else {
                mismatches += 1
                if problems.count < 50 { problems.append(item.identifier) }
            }
            if read % 5000 == 0 { progress?(read, total) }
        }
        progress?(read, total)
        return VerificationResult(sourceItems: read, verifiedItems: verified, mismatches: mismatches,
                                  missingRecords: missing, problemIDs: problems)
    }

    private static func matches(_ record: ClipRecord, item: PasteSource.Item, blobs: BlobStore, externalDirectory: URL) throws -> Bool {
        guard record.title == item.title, record.board == item.board, record.boardOrder == item.boardOrder,
              record.rawKind == item.rawKind, record.createdAt == item.createdAt, record.copiedAt == item.copiedAt else { return false }
        guard let decoded = try? PasteBlobDecoder.decode(item.blob, externalDirectory: externalDirectory) else {
            guard let raw = record.rawBlob, let stored = try? blobs.get(raw) else { return false }
            return stored == item.blob
        }
        var expected: [Representation] = []
        for (index, pasteboardItem) in decoded.items.enumerated() {
            for uti in pasteboardItem.types {
                guard let data = pasteboardItem.dataByType[uti] else { continue }
                expected.append(Representation(uti: uti, blob: Hashing.sha256Hex(data), size: data.count, item: index))
            }
        }
        guard expected == record.representations else { return false }
        for representation in expected {
            guard let stored = try? blobs.get(representation.blob), stored.count == representation.size else { return false }
        }
        return true
    }
}
