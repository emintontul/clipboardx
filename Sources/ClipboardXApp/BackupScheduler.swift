import ClipboardXKit
import Foundation

/// Copies new data to iCloud Drive every ten minutes. Packs and log segments only ever grow, so syncing never conflicts.
final class BackupScheduler {
    private let library: URL
    private let deviceID: String
    private let settings: AppSettings
    private var timer: Timer?
    private let queue = DispatchQueue(label: "clipboardx.backup", qos: .utility)
    private(set) var status = "iCloud backup: not run yet"
    var onStatus: (() -> Void)?

    init(library: URL, deviceID: String, settings: AppSettings) {
        self.library = library
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
        queue.async { [library, destination, deviceID, weak self] in
            do {
                let result = try LibraryBackup.backup(library: library, destination: destination, deviceID: deviceID)
                let report = try LibraryBackup.verify(library: library, backup: destination)
                let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
                self?.update(report.complete ? "iCloud backup: complete at \(stamp) (+\(result.blobsPacked) new)" : "iCloud backup: INCOMPLETE, \(report.missingFromBackup) missing")
            } catch { self?.update("iCloud backup failed: \(error.localizedDescription)") }
        }
    }

    private func update(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.status = text; self?.onStatus?() }
    }
}
