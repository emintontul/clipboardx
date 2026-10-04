import Foundation

/// Append-only JSONL log. Each device writes only its own segment files, so syncing folders never merges writes.
public final class EventLog {
    public enum ReadError: Error {
        case corruptLine(file: String, line: Int)
    }

    private static let segmentLimit = 4 * 1024 * 1024
    private let directory: URL
    private let deviceID: String
    private var handle: FileHandle
    private var segment: Int
    private var written: Int
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public init(directory: URL, deviceID: String) throws {
        self.directory = directory
        self.deviceID = deviceID
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let last = Self.lastSegment(directory: directory, deviceID: deviceID) ?? 1
        let url = Self.url(directory, deviceID, last)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        self.segment = last
        self.written = size
        self.handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    public func append(_ event: ClipEvent) throws {
        var line = try encoder.encode(event)
        line.append(0x0A)
        if written + line.count > Self.segmentLimit, written > 0 { try rotate() }
        try handle.write(contentsOf: line)
        written += line.count
    }

    /// Forces buffered bytes to disk. Call after batches and before reporting success.
    public func sync() throws { try handle.synchronize() }

    public static func readAll(directory: URL) throws -> [ClipEvent] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let decoder = JSONDecoder()
        var events: [ClipEvent] = []
        for file in files {
            let lines = try Data(contentsOf: file).split(separator: 0x0A, omittingEmptySubsequences: true)
            for (index, line) in lines.enumerated() {
                guard let event = try? decoder.decode(ClipEvent.self, from: Data(line)) else {
                    throw ReadError.corruptLine(file: file.lastPathComponent, line: index + 1)
                }
                events.append(event)
            }
        }
        return events
    }

    private func rotate() throws {
        try handle.synchronize()
        try handle.close()
        segment += 1
        let url = Self.url(directory, deviceID, segment)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        written = 0
    }

    private static func url(_ dir: URL, _ device: String, _ segment: Int) -> URL {
        dir.appendingPathComponent(String(format: "events-%@-%05d.jsonl", device, segment))
    }

    private static func lastSegment(directory: URL, deviceID: String) -> Int? {
        let prefix = "events-\(deviceID)-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".jsonl") }
            .compactMap { Int($0.dropFirst(prefix.count).dropLast(".jsonl".count)) }
            .max()
    }
}
