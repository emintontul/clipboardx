import Foundation

public struct Representation: Codable, Equatable, Sendable {
    public let uti: String
    public let blob: String
    public let size: Int
    public let item: Int

    public init(uti: String, blob: String, size: Int, item: Int = 0) {
        self.uti = uti
        self.blob = blob
        self.size = size
        self.item = item
    }
}

/// Everything known about one clipboard entry. Payload bytes live in the blob store, referenced by hash.
public struct ClipRecord: Codable, Equatable, Sendable {
    public let id: String
    public let createdAt: Double
    public let copiedAt: Double
    public let title: String?
    public let appBundleID: String?
    public let board: String?
    public let boardOrder: Int?
    public let rawKind: Int
    public let representations: [Representation]
    public let source: String
    public let flags: [String]
    public let rawBlob: String?
    public let previewBlob: String?

    public init(id: String, createdAt: Double, copiedAt: Double, title: String?, appBundleID: String?,
                board: String?, boardOrder: Int?, rawKind: Int, representations: [Representation], source: String,
                flags: [String] = [], rawBlob: String? = nil, previewBlob: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.copiedAt = copiedAt
        self.title = title
        self.appBundleID = appBundleID
        self.board = board
        self.boardOrder = boardOrder
        self.rawKind = rawKind
        self.representations = representations
        self.source = source
        self.flags = flags
        self.rawBlob = rawBlob
        self.previewBlob = previewBlob
    }

    /// Hash of the meaningful content. Browser bookkeeping types are ignored so re-copying the same text matches.
    public var fingerprint: String {
        let ignored = ["org.chromium.", "dyn.", "org.nspasteboard.", "com.apple.pasteboard.", "NeXT"]
        let meaningful = representations.filter { rep in !ignored.contains { rep.uti.hasPrefix($0) } }
        let basis = (meaningful.isEmpty ? representations : meaningful).map { "\($0.item)|\($0.uti)|\($0.blob)" }.sorted()
        return Hashing.sha256Hex(Data(basis.joined(separator: "\n").utf8))
    }

    public func with(id: String? = nil, copiedAt: Double? = nil, title: String?? = nil, appBundleID: String?? = nil,
                     board: String?? = nil, boardOrder: Int?? = nil, source: String? = nil) -> ClipRecord {
        ClipRecord(id: id ?? self.id, createdAt: createdAt, copiedAt: copiedAt ?? self.copiedAt,
                   title: title ?? self.title, appBundleID: appBundleID ?? self.appBundleID,
                   board: board ?? self.board, boardOrder: boardOrder ?? self.boardOrder, rawKind: rawKind,
                   representations: representations, source: source ?? self.source, flags: flags, rawBlob: rawBlob, previewBlob: previewBlob)
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, copiedAt, title, appBundleID, board, boardOrder, rawKind, representations, source, flags, rawBlob, previewBlob
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            createdAt: try c.decode(Double.self, forKey: .createdAt),
            copiedAt: try c.decode(Double.self, forKey: .copiedAt),
            title: try c.decodeIfPresent(String.self, forKey: .title),
            appBundleID: try c.decodeIfPresent(String.self, forKey: .appBundleID),
            board: try c.decodeIfPresent(String.self, forKey: .board),
            boardOrder: try c.decodeIfPresent(Int.self, forKey: .boardOrder),
            rawKind: try c.decode(Int.self, forKey: .rawKind),
            representations: try c.decode([Representation].self, forKey: .representations),
            source: try c.decode(String.self, forKey: .source),
            flags: try c.decodeIfPresent([String].self, forKey: .flags) ?? [],
            rawBlob: try c.decodeIfPresent(String.self, forKey: .rawBlob),
            previewBlob: try c.decodeIfPresent(String.self, forKey: .previewBlob))
    }
}

public struct BoardRecord: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let index: Int
    public let kind: Int
    public let createdAt: Double
    public let attributesBlob: String?

    public init(id: String, name: String, index: Int, kind: Int, createdAt: Double, attributesBlob: String?) {
        self.id = id
        self.name = name
        self.index = index
        self.kind = kind
        self.createdAt = createdAt
        self.attributesBlob = attributesBlob
    }
}

public struct AppRecord: Codable, Equatable, Sendable {
    public let bundleID: String
    public let name: String
    public let iconBlob: String?

    public init(bundleID: String, name: String, iconBlob: String?) {
        self.bundleID = bundleID
        self.name = name
        self.iconBlob = iconBlob
    }
}

/// One line of the append-only log. History is derived from these; nothing here is ever rewritten.
public enum ClipEvent: Codable, Equatable, Sendable {
    case put(ClipRecord)
    case board(BoardRecord)
    case app(AppRecord)

    private enum Keys: String, CodingKey { case op, record }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .op) {
        case "put": self = .put(try c.decode(ClipRecord.self, forKey: .record))
        case "board": self = .board(try c.decode(BoardRecord.self, forKey: .record))
        case "app": self = .app(try c.decode(AppRecord.self, forKey: .record))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown op \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .put(let r): try c.encode("put", forKey: .op); try c.encode(r, forKey: .record)
        case .board(let r): try c.encode("board", forKey: .op); try c.encode(r, forKey: .record)
        case .app(let r): try c.encode("app", forKey: .op); try c.encode(r, forKey: .record)
        }
    }
}
