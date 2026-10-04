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

    private struct StampedLine: Encodable {
        let event: ClipEvent, at: Double, dev: String
        private enum StampKeys: String, CodingKey { case at, dev }
        func encode(to encoder: Encoder) throws {
            try event.encode(to: encoder)
            var c = encoder.container(keyedBy: StampKeys.self)
            try c.encode(at, forKey: .at)
            try c.encode(dev, forKey: .dev)
        }
    }

    private struct DecodedLine: Decodable {
        let event: ClipEvent
        let at: Double?
        let dev: String?
        private enum StampKeys: String, CodingKey { case at, dev }
        init(from decoder: Decoder) throws {
            event = try ClipEvent(from: decoder)
            let c = try decoder.container(keyedBy: StampKeys.self)
            at = try c.decodeIfPresent(Double.self, forKey: .at)
            dev = try c.decodeIfPresent(String.self, forKey: .dev)
        }
    }

    public func append(_ event: ClipEvent, at: Double = Date().timeIntervalSince1970) throws {
        var line = try encoder.encode(StampedLine(event: event, at: at, dev: deviceID))
        line.append(0x0A)
        if written + line.count > Self.segmentLimit, written > 0 { try rotate() }
        try handle.write(contentsOf: line)
        written += line.count
    }

    /// Forces buffered bytes to disk. Call after batches and before reporting success.
    public func sync() throws { try handle.synchronize() }

    public static func readAll(directory: URL) throws -> [ClipEvent] {
        try readAllStamped(directory: directory).map(\.event)
    }

    /// Reads every segment. Lines written before events were stamped take the device from the file name and a time from
    /// the record itself, so old libraries replay in a sensible order.
    public static func readAllStamped(directory: URL) throws -> [StampedEvent] {
        try readAllStamped(directory: directory, after: [:])
    }

    /// Every segment, own and (under `remote/<device>/`) copies of other devices' logs, keyed by relative path.
    private static func segmentFiles(in directory: URL) -> [(key: String, url: URL, device: String)] {
        let fm = FileManager.default
        var out: [(String, URL, String)] = []
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".jsonl") {
            out.append((name, directory.appendingPathComponent(name), device(fromFileName: name)))
        }
        let remote = directory.appendingPathComponent("remote", isDirectory: true)
        for folder in (try? fm.contentsOfDirectory(atPath: remote.path)) ?? [] {
            let dir = remote.appendingPathComponent(folder, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".jsonl") {
                out.append(("remote/\(folder)/\(name)", dir.appendingPathComponent(name), device(fromFileName: name)))
            }
        }
        return out.sorted { $0.0 < $1.0 }.map { (key: $0.0, url: $0.1, device: $0.2) }
    }

    /// Byte size of every segment right now. Pair with `readAllStamped(directory:after:)` to read only what was added later.
    public static func fileSizes(directory: URL) -> [String: Int] {
        var sizes: [String: Int] = [:]
        for file in segmentFiles(in: directory) {
            sizes[file.key] = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int) ?? 0
        }
        return sizes
    }

    /// Events past the given per-file byte offsets (a file missing from `offsets` is read from the start).
    public static func readAllStamped(directory: URL, after offsets: [String: Int]) throws -> [StampedEvent] {
        let decoder = JSONDecoder()
        var events: [StampedEvent] = []
        for file in segmentFiles(in: directory) {
            let data = try Data(contentsOf: file.url)
            let start = min(offsets[file.key] ?? 0, data.count)
            let lines = data.dropFirst(start).split(separator: 0x0A, omittingEmptySubsequences: true)
            for (index, line) in lines.enumerated() {
                guard let decoded = try? decoder.decode(DecodedLine.self, from: Data(line)) else {
                    throw ReadError.corruptLine(file: file.key, line: index + 1)
                }
                events.append(StampedEvent(event: decoded.event, at: decoded.at ?? fallbackTime(decoded.event), dev: decoded.dev ?? file.device))
            }
        }
        return events
    }

    /// Decodes one log line, or nil when it is not a complete valid event.
    static func decodeStamped(_ line: Data, device: String) -> StampedEvent? {
        guard let decoded = try? JSONDecoder().decode(DecodedLine.self, from: line) else { return nil }
        return StampedEvent(event: decoded.event, at: decoded.at ?? fallbackTime(decoded.event), dev: decoded.dev ?? device)
    }

    static func device(fromFileName name: String) -> String {
        guard name.hasPrefix("events-"), let dash = name.lastIndex(of: "-"), dash > name.index(name.startIndex, offsetBy: 7) else { return "unknown" }
        return String(name[name.index(name.startIndex, offsetBy: 7)..<dash])
    }

    private static func fallbackTime(_ event: ClipEvent) -> Double {
        switch event {
        case .put(let r): return r.copiedAt
        case .board(let b): return b.createdAt
        default: return 0
        }
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
