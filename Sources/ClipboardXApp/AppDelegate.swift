import AppKit
import Carbon
import ClipboardXKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var engine: LibraryEngine!
    private var model: ShelfModel!
    private var shelf: ShelfController!
    private var monitor: PasteboardMonitor!
    private var backup: BackupScheduler!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let settings = AppSettings.shared
    private var backupItem: NSMenuItem!
    private var countItem: NSMenuItem!
    private var shortcutLabel = "⇧⌘V"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let env = ProcessInfo.processInfo.environment
        let library = env["CLIPBOARDX_LIBRARY"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ClipboardX-library")
        let device = ProcessInfo.processInfo.hostName.replacingOccurrences(of: " ", with: "-")
        buildStatusItem()
        do { engine = try LibraryEngine(library: library, deviceID: device.lowercased()) } catch {
            let alert = NSAlert()
            alert.messageText = "ClipboardX could not open its library"
            alert.informativeText = "\(library.path)\n\n\(error.localizedDescription)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        PreviewStore.shared.engine = engine
        model = ShelfModel(engine: engine, settings: settings)
        shelf = ShelfController(model: model)
        model.onPaste = { [weak self] record, plain in self?.paste(record, plain: plain) }
        model.onOpenSettings = { [weak self] in self?.shelf.hide(); self?.openSettings() }

        monitor = PasteboardMonitor(engine: engine, settings: settings)
        monitor.start()
        backup = BackupScheduler(library: library, deviceID: device, settings: settings)
        backup.onStatus = { [weak self] in self?.backupItem?.title = self?.backup.status ?? "" }
        backup.start()

        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), id: 1) { [weak self] in self?.shelf.toggle() }
        if hotKey == nil {
            // Paste owns ⇧⌘V while it runs; fall back to ⌥⌘V so both can coexist during the switch-over.
            hotKey = HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey), id: 2) { [weak self] in self?.shelf.toggle() }
            shortcutLabel = "⌥⌘V"
            statusItem.menu?.items.first?.title = "Show Clipboard    ⌥⌘V"
        }

        if env["CLIPBOARDX_DEMO"] == "1" {
            let query = env["CLIPBOARDX_DEMO_QUERY"]
            let board = env["CLIPBOARDX_DEMO_BOARD"].flatMap(Int.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if env["CLIPBOARDX_DEMO_SETTINGS"] == "1" { self?.openSettings(); return }
                self?.shelf.show(query: query)
                if let board { self?.model.selectBoard(board) }
            }
        }
    }

    private func paste(_ record: ClipRecord, plain: Bool) {
        guard let items = try? engine.payload(of: record) else { return }
        shelf.hide()
        if settings.soundEffects { NSSound(named: "Pop")?.play() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [settings] in
            PasteAction.perform(items: items, plainText: plain, autoPaste: settings.pasteToActiveApp)
        }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipboardX")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Show Clipboard", action: #selector(showShelf), keyEquivalent: "").target = self
        menu.items.last?.title = "Show Clipboard    ⇧⌘V"
        menu.addItem(.separator())
        countItem = NSMenuItem(title: "Library: loading…", action: nil, keyEquivalent: "")
        menu.addItem(countItem)
        backupItem = NSMenuItem(title: "iCloud backup: not run yet", action: nil, keyEquivalent: "")
        menu.addItem(backupItem)
        menu.addItem(withTitle: "Back Up to iCloud Now", action: #selector(backupNow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ClipboardX", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        backupItem.title = backup?.status ?? backupItem.title
        let boards = (try? engine?.boards().count) ?? 0
        countItem.title = "Library: \(boards) pinboards"
    }

    @objc private func showShelf() { shelf.show() }
    @objc private func backupNow() { backup.runNow() }
    @objc private func openSettingsAction() { openSettings() }

    private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, backupStatus: { [weak self] in self?.backup.status ?? "" },
                                    backupNow: { [weak self] in self?.backup.runNow() }, libraryPath: engine.library.path)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "ClipboardX Settings"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
