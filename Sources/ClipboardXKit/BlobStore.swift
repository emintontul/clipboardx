import Compression
import Foundation

/// Content-addressed, immutable blob storage: `root/ab/cd/<sha256>`.
/// File layout: 1 codec byte (0 = raw, 1 = LZFSE) followed by the bytes. The id is the SHA-256 of the original data.
public final class BlobStore: Sendable {
    public enum StoreError: Error {
        case missing(String)
        case corrupted(String)
    }

    private let root: URL

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func path(for id: String) -> URL {
        root.appendingPathComponent(String(id.prefix(2)), isDirectory: true)
            .appendingPathComponent(String(id.dropFirst(2).prefix(2)), isDirectory: true)
            .appendingPathComponent(id)
    }

    @discardableResult
    public func put(_ data: Data) throws -> String {
        let id = Hashing.sha256Hex(data)
        let url = path(for: id)
        if FileManager.default.fileExists(atPath: url.path) { return id }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(data).write(to: url, options: .atomic)
        return id
    }

    public func get(_ id: String) throws -> Data {
        guard let stored = try? Data(contentsOf: path(for: id)) else { throw StoreError.missing(id) }
        guard let codec = stored.first else { throw StoreError.corrupted(id) }
        let body = Data(stored.dropFirst())
        let data: Data
        switch codec {
        case 0: data = body
        case 1:
            guard let out = try? (body as NSData).decompressed(using: .lzfse) as Data else { throw StoreError.corrupted(id) }
            data = out
        default: throw StoreError.corrupted(id)
        }
        guard Hashing.sha256Hex(data) == id else { throw StoreError.corrupted(id) }
        return data
    }

    /// Every stored blob id. Ids are the file names two directory levels down.
    public func allIDs() -> [String] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.count == 64 && !$0.lastPathComponent.hasPrefix(".") }
            .map(\.lastPathComponent)
    }

    /// Raw on-disk bytes (codec byte + payload), used by backups so blobs are never recompressed.
    public func storedBytes(_ id: String) throws -> Data {
        guard let data = try? Data(contentsOf: path(for: id)) else { throw StoreError.missing(id) }
        return data
    }

    /// Writes already-encoded bytes under `id`, then verifies the content hash. Removes the file again if it does not match.
    public func importStored(_ id: String, stored: Data) throws {
        let url = path(for: id)
        if FileManager.default.fileExists(atPath: url.path) { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try stored.write(to: url, options: .atomic)
        do { _ = try get(id) } catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    public func contains(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: path(for: id).path)
    }

    public var blobCount: Int {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        return walker.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.count
    }

    private func encode(_ data: Data) throws -> Data {
        if data.count >= 64, let packed = try? (data as NSData).compressed(using: .lzfse) as Data, packed.count < data.count {
            return Data([1]) + packed
        }
        return Data([0]) + data
    }
}
