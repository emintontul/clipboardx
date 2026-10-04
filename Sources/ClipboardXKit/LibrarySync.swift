import Foundation

/// Merges the libraries of several Macs through a shared folder (iCloud Drive).
///
/// Every Mac backs itself up into `<root>/<device>/` (log segments and packs). A sync reads the other devices' log segments
/// incrementally and keeps copies under `library/log/remote/<device>/`, so a rebuilt index never needs the cloud. Foreign events
/// are never written to this Mac's own log, which keeps them from echoing back. All logs are replayed in `(time, device)`
/// order, so the Macs converge. Small text blobs come along immediately; images and big payloads are fetched from the other
/// Mac's pack the first time they are needed.
public final class LibrarySync {
    public struct Report: Sendable, Equatable {
        public var devices = 0
        public var newEvents = 0
        public var blobsFetched = 0
        /// Files still being downloaded or uploaded by iCloud, retried next time.
        public var deferred = 0
        /// Clips shown without searchable text until their pack arrives.
        public var pendingText = 0
    }

    private struct State: Codable {
        var offsets: [String: Int] = [:]
        var pendingText: [String] = []
    }

    /// Text up to this size is fetched on arrival so search works at once.
    private static let eagerTextLimit = 1_000_000
    private static let textTypes: Set<String> = ["public.utf8-plain-text", "public.utf16-external-plain-text", "public.text", "public.file-url", "public.html"]

    private let engine: LibraryEngine
    private let sharedRoot: URL
    private let ownFolder: String
    private let library: URL
    private let remote: RemoteBlobIndex?

    public init(engine: LibraryEngine, sharedRoot: URL, ownFolder: String) {
        self.engine = engine
        self.sharedRoot = sharedRoot
        self.ownFolder = ownFolder
        self.library = engine.library
        remote = try? RemoteBlobIndex(library: engine.library)
    }

    public func syncNow() throws -> Report {
        var report = Report()
        var state = loadState()
        let folders = otherDeviceFolders()
        report.devices = folders.count
        remote?.setPackDirectories(folders.map { $0.appendingPathComponent("packs") })
        engine.setRemoteBlobProvider { [remote] id in remote?.storedBytes(id) }

        var newEvents: [StampedEvent] = []
        for folder in folders { try pull(folder, into: &state, events: &newEvents, report: &report) }
        report.newEvents = newEvents.count

        // Text first, so search works the moment a clip appears; clips whose pack has not arrived yet are retried next round.
        var stillPending = Set<String>()
        let retry = Set(state.pendingText)
        for record in newEvents.compactMap({ if case .put(let r) = $0.event { return r } else { return nil } }) + (try engine.records(ids: Array(retry))) {
            if fetchText(of: record, report: &report) == false { stillPending.insert(record.id) }
        }
        report.pendingText = stillPending.count
        state.pendingText = Array(stillPending)

        try engine.mergeRemote(newEvents, also: retry)
        saveState(state)
        return report
    }

    // MARK: pulling logs

    private func otherDeviceFolders() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sharedRoot.path)) ?? []
        return names.sorted().compactMap { name in
            guard !name.hasPrefix("."), name.lowercased() != ownFolder.lowercased() else { return nil }
            let folder = sharedRoot.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            let hasLog = FileManager.default.fileExists(atPath: folder.appendingPathComponent("log").path, isDirectory: &isDirectory) && isDirectory.boolValue
            return hasLog ? folder : nil
        }
    }

    private func pull(_ folder: URL, into state: inout State, events: inout [StampedEvent], report: inout Report) throws {
        let device = folder.lastPathComponent
        let logDirectory = folder.appendingPathComponent("log")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: logDirectory.path)) ?? []).sorted()

        // iCloud keeps not-yet-downloaded files as ".name.icloud" stubs: ask for them and come back later.
        for name in names where name.hasPrefix(".") && name.hasSuffix(".icloud") {
            report.deferred += 1
            let real = String(name.dropFirst().dropLast(".icloud".count))
            try? FileManager.default.startDownloadingUbiquitousItem(at: logDirectory.appendingPathComponent(real))
        }

        for name in names where name.hasSuffix(".jsonl") && !name.hasPrefix(".") {
            let key = device + "/" + name
            guard let data = try? Data(contentsOf: logDirectory.appendingPathComponent(name)) else { report.deferred += 1; continue }
            let start = min(state.offsets[key] ?? 0, data.count)
            let bytes = [UInt8](data[start...])
            var cursor = 0, consumed = 0
            var parsed: [StampedEvent] = []
            while let newline = bytes[cursor...].firstIndex(of: 0x0A) {
                let line = Data(bytes[cursor..<newline])
                if !line.isEmpty {
                    guard let event = EventLog.decodeStamped(line, device: EventLog.device(fromFileName: name)) else { report.deferred += 1; break }
                    parsed.append(event)
                }
                consumed = newline + 1
                cursor = newline + 1
            }
            guard consumed > 0 else { continue }
            try append(Data(bytes[0..<consumed]), to: remoteCopy(device: device, name: name))
            state.offsets[key] = start + consumed
            events.append(contentsOf: parsed)
        }
    }

    private func remoteCopy(device: String, name: String) throws -> URL {
        let directory = library.appendingPathComponent("log/remote/\(device)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    private func append(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    // MARK: blobs

    /// Makes sure the small text blobs of a clip are on this Mac. False when one could not be fetched yet.
    private func fetchText(of record: ClipRecord, report: inout Report) -> Bool {
        var complete = true
        for rep in record.representations where Self.textTypes.contains(rep.uti) && rep.size <= Self.eagerTextLimit {
            let had = engine.hasBlobLocally(rep.blob)
            if had { continue }
            if engine.hasBlob(rep.blob) { report.blobsFetched += 1 } else { complete = false }
        }
        return complete
    }

    // MARK: state file

    private var stateURL: URL { library.appendingPathComponent("sync-state.json") }

    private func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    private func saveState(_ state: State) {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }
}
