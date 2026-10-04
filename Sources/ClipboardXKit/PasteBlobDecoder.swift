import Foundation

/// Decodes the `ZRAWPASTEBOARDITEMS` column of Paste's Core Data store.
///
/// Byte 0 is a tag: 0x01 = inline payload, 0x02 = `<UUID>\0` naming a file in `_EXTERNAL_DATA`.
/// The payload is a binary plist, an LZFSE stream (`bvx*`) or raw deflate, and decodes to
/// `[{types: [UTI], dataByType: {UTI: bytes}}]`.
public enum PasteBlobDecoder {
    public enum Format: String, Sendable, Codable {
        case inlineDeflate, inlineLZFSE, inlinePlist
        case externalDeflate, externalLZFSE, externalPlist
    }

    public enum DecodeError: Error, Equatable {
        case empty
        case unknownTag(UInt8)
        case malformedExternalReference
        case externalFileMissing(String)
        case undecodable
        case unexpectedStructure
    }

    public struct Result: Sendable {
        public let format: Format
        public let items: [PasteboardItem]
    }

    public static func decode(_ blob: Data, externalDirectory: URL?) throws -> Result {
        guard let tag = blob.first else { throw DecodeError.empty }
        switch tag {
        case 0x01:
            let (kind, structured) = try unwrap(Data(blob.dropFirst()))
            return Result(format: inline(kind), items: try items(from: structured))
        case 0x02:
            let uuid = try externalName(blob)
            guard let directory = externalDirectory else { throw DecodeError.externalFileMissing(uuid) }
            let url = directory.appendingPathComponent(uuid)
            guard let file = try? Data(contentsOf: url) else { throw DecodeError.externalFileMissing(uuid) }
            let (kind, structured) = try unwrap(file)
            return Result(format: external(kind), items: try items(from: structured))
        default:
            throw DecodeError.unknownTag(tag)
        }
    }

    private enum Kind { case deflate, lzfse, plist }

    private static func inline(_ kind: Kind) -> Format {
        switch kind {
        case .deflate: return .inlineDeflate
        case .lzfse: return .inlineLZFSE
        case .plist: return .inlinePlist
        }
    }

    private static func external(_ kind: Kind) -> Format {
        switch kind {
        case .deflate: return .externalDeflate
        case .lzfse: return .externalLZFSE
        case .plist: return .externalPlist
        }
    }

    private static func externalName(_ blob: Data) throws -> String {
        let body = blob.dropFirst().prefix { $0 != 0 }
        guard let name = String(data: Data(body), encoding: .utf8), name.count == 36,
              !name.contains("/") else { throw DecodeError.malformedExternalReference }
        return name
    }

    /// Returns the container kind and the decompressed structured bytes (plist or JSON).
    private static func unwrap(_ payload: Data) throws -> (Kind, Data) {
        if payload.starts(with: Data("bplist00".utf8)) { return (.plist, payload) }
        if payload.starts(with: Data("bvx".utf8)) {
            guard let out = try? (payload as NSData).decompressed(using: .lzfse) as Data else {
                throw DecodeError.undecodable
            }
            return (.lzfse, out)
        }
        if let out = try? (payload as NSData).decompressed(using: .zlib) as Data { return (.deflate, out) }
        throw DecodeError.undecodable
    }

    private static func items(from structured: Data) throws -> [PasteboardItem] {
        let object: Any
        if structured.starts(with: Data("bplist00".utf8)) {
            object = try PropertyListSerialization.propertyList(from: structured, options: [], format: nil)
        } else {
            object = try JSONSerialization.jsonObject(with: structured)
        }
        guard let list = object as? [[String: Any]] else { throw DecodeError.unexpectedStructure }
        return try list.map(item)
    }

    private static func item(_ dict: [String: Any]) throws -> PasteboardItem {
        guard let raw = dict["dataByType"] as? [String: Any] else { throw DecodeError.unexpectedStructure }
        var data: [String: Data] = [:]
        for (uti, value) in raw {
            if let bytes = value as? Data {
                data[uti] = bytes
            } else if let text = value as? String, let bytes = Data(base64Encoded: text) {
                data[uti] = bytes
            } else {
                throw DecodeError.unexpectedStructure
            }
        }
        let declared = (dict["types"] as? [String]) ?? []
        let extra = data.keys.filter { !declared.contains($0) }.sorted()
        return PasteboardItem(types: declared + extra, dataByType: data)
    }
}
