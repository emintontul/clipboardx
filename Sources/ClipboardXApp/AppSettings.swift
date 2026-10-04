import ClipboardXKit
import Foundation
import ServiceManagement

/// User preferences, persisted in UserDefaults. Defaults mirror Paste.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var pasteToActiveApp: Bool { didSet { defaults.set(pasteToActiveApp, forKey: "pasteToActiveApp") } }
    @Published var alwaysPlainText: Bool { didSet { defaults.set(alwaysPlainText, forKey: "alwaysPlainText") } }
    @Published var soundEffects: Bool { didSet { defaults.set(soundEffects, forKey: "soundEffects") } }
    @Published var ignoreConfidential: Bool { didSet { defaults.set(ignoreConfidential, forKey: "ignoreConfidential") } }
    @Published var ignoreTransient: Bool { didSet { defaults.set(ignoreTransient, forKey: "ignoreTransient") } }
    @Published var icloudSync: Bool { didSet { defaults.set(icloudSync, forKey: "icloudSync") } }
    @Published var linkPreviews: Bool { didSet { defaults.set(linkPreviews, forKey: "linkPreviews") } }
    @Published var icloudBackup: Bool { didSet { defaults.set(icloudBackup, forKey: "icloudBackup") } }
    @Published var ignoredApps: [String] { didSet { defaults.set(ignoredApps, forKey: "ignoredApps") } }

    private init() {
        func bool(_ key: String, _ fallback: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? fallback }
        pasteToActiveApp = bool("pasteToActiveApp", true)
        alwaysPlainText = bool("alwaysPlainText", false)
        soundEffects = bool("soundEffects", false)
        ignoreConfidential = bool("ignoreConfidential", true)
        ignoreTransient = bool("ignoreTransient", true)
        icloudBackup = bool("icloudBackup", true)
        linkPreviews = bool("linkPreviews", false)
        icloudSync = bool("icloudSync", true)
        ignoredApps = UserDefaults.standard.stringArray(forKey: "ignoredApps") ?? ["com.apple.keychainaccess"]
    }

    var capture: CaptureSettings {
        CaptureSettings(ignoreConfidential: ignoreConfidential, ignoreTransient: ignoreTransient, ignoredApps: Set(ignoredApps))
    }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { NSLog("ClipboardX: login item change failed: \(error)") }
        }
    }
}
