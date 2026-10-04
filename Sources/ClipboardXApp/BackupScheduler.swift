import ClipboardXKit
import Foundation

/// Copies new data to iCloud Drive every ten minutes. Packs and log segments only ever grow, so syncing never conflicts.
final class BackupScheduler {
    private let library: URL
    private let engine: LibraryEngine
    private let deviceID: String
    private let settings: AppSettings
    private var timer: Timer?
    private let queue = DispatchQueue(label: "clipboardx.backup", qos: .utility)
    private(set) var status = "iCloud backup: not run yet"
    var onStatus: (() -> Void)?
    /// Called on the main thread after other Macs' changes were merged in.
    var onSynced: (() -> Void)?

    init(library: URL, engine: LibraryEngine, deviceID: String, settings: AppSettings) {
        self.library = library
        self.engine = engine
        self.deviceID = deviceID
        self.settings = settings
    }

    var destination: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/ClipboardX/\(deviceID)", isDirectory: true)
    }

    func start() {
        timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in self?.runNow() }
        RunLoop.main.add(timer!, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.runNow() }
    }

    func runNow() {
        guard settings.icloudBackup else { return update("iCloud backup: off") }
        let drive = destination.deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: drive.path) else { return update("iCloud backup: iCloud Drive not found") }
        update("iCloud backup: running…")
        queue.async { [library, destination, deviceID, engine, settings, weak self] in
            do {
                let result = try LibraryBackup.backup(library: library, destination: destination, deviceID: deviceID)
                let report = try LibraryBackup.verify(library: library, backup: destination)
                let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
                var line = report.complete ? "iCloud backup: complete at \(stamp) (+\(result.blobsPacked) new)" : "iCloud backup: INCOMPLETE, \(report.missingFromBackup) missing"
                if settings.icloudSync, !engine.isIndexing {
                    let sync = try LibrarySync(engine: engine, sharedRoot: destination.deletingLastPathComponent(), ownFolder: destination.lastPathComponent).syncNow()
                    if sync.devices == 0 { line += " · no other Macs yet" }
                    else {
                        line += " · synced \(sync.newEvents) change\(sync.newEvents == 1 ? "" : "s") from \(sync.devices) Mac\(sync.devices == 1 ? "" : "s")"
                        if sync.deferred > 0 { line += " (\(sync.deferred) file\(sync.deferred == 1 ? "" : "s") still downloading)" }
                    }
                    if sync.newEvents > 0 { DispatchQueue.main.async { self?.onSynced?() } }
                }
                self?.update(line)
            } catch { self?.update("iCloud backup or sync failed: \(error.localizedDescription)") }
        }
    }

    private func update(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.status = text; self?.onStatus?() }
    }
}
