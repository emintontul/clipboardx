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
    private let hotKeys = HotKeyCenter()
    private var stackItem: NSMenuItem!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var backdrop: NSWindow?
    private let settings = AppSettings.shared
    private var backupItem: NSMenuItem!
    private var countItem: NSMenuItem!

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
        PreviewStore.shared.linkPreviewsEnabled = { [settings] in settings.linkPreviews }
        model = ShelfModel(engine: engine, settings: settings)
        shelf = ShelfController(model: model)
        let links = LinkPreviewService(engine: engine, fetcher: CompositeLinkFetcher(primary: SystemLinkFetcher(), fallback: WebPageLinkFetcher()), isEnabled: { [settings] in settings.linkPreviews && env["CLIPBOARDX_DEMO"] != "1" })
        links.onUpdate = { [weak self] _ in DispatchQueue.main.async { self?.model.linkPreviewUpdated() } }
        model.linkService = links
        model.onPaste = { [weak self] record, plain in self?.paste(record, plain: plain) }
        model.onCopy = { [weak self] record in
            guard let items = try? self?.engine.payload(of: record) else { return }
            PasteAction.perform(items: items, plainText: false, autoPaste: false)
        }
        model.onOpenSettings = { [weak self] in self?.shelf.hide(); self?.openSettings() }

        // Demo mode (screenshots) never records the real clipboard and never writes to the iCloud backup.
        let demo = env["CLIPBOARDX_DEMO"] == "1"
        monitor = PasteboardMonitor(engine: engine, settings: settings)
        backup = BackupScheduler(library: library, engine: engine, deviceID: device, settings: settings)
        backup.onSynced = { [weak self] in self?.model.refreshBoards(); self?.model.reload(resetSelection: false) }
        backup.onStatus = { [weak self] in self?.backupItem?.title = self?.backup.status ?? "" }
        if !demo {
            monitor.start()
            backup.start()
        }
        if env["CLIPBOARDX_DEMO_BACKDROP"] == "1" { showBackdrop() }
        if !demo { schedulePurge() }

        hotKeys.onChange = { [weak self] in self?.refreshShortcutLabels() }
        hotKeys.register(.showShelf) { [weak self] in self?.shelf.toggle() }
        hotKeys.register(.pasteStack) { [weak self] in self?.model.toggleStack() }
        monitor.onCapture = { [weak self] record in self?.model.enqueueToStack(record.id) }
        model.onStackChanged = { [weak self] stack in self?.stackChanged(stack) }

        if env["CLIPBOARDX_DEMO"] == "1" {
            let query = env["CLIPBOARDX_DEMO_QUERY"]
            let board = env["CLIPBOARDX_DEMO_BOARD"].flatMap(Int.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if env["CLIPBOARDX_DEMO_SETTINGS"] == "1" { self?.openSettings(); return }
                self?.shelf.show(query: query)
                if let board { self?.model.selectBoard(board) }
                if let kind = env["CLIPBOARDX_DEMO_KIND"].flatMap(ClipKind.init(rawValue:)) { self?.model.kindFilters = [kind] }
                if let app = env["CLIPBOARDX_DEMO_APP"] { self?.model.appFilter = app }
                if let preset = env["CLIPBOARDX_DEMO_DATE"].flatMap({ raw in DatePreset.allCases.first { $0.rawValue == raw } }) { self?.model.datePreset = preset }
                if env["CLIPBOARDX_DEMO_EDIT"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.model.editSelected() } }
                if env["CLIPBOARDX_DEMO_QUICKLOOK"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.model.toggleQuickLook() } }
            }
        }
    }

    /// Trash older than 90 days is removed for good. Runs shortly after launch and every six hours.
    private func schedulePurge() {
        let purge = { [engine] in
            DispatchQueue.global(qos: .utility).async { _ = try? engine?.purgeExpired() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { purge() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in purge() }
    }

    /// Screenshots only: a plain gradient window behind the shelf so no real desktop content shows through the glass.
    private func showBackdrop() {
        guard let screen = NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .popUpMenu
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.10, blue: 0.28), Color(red: 0.30, green: 0.14, blue: 0.48), Color(red: 0.05, green: 0.38, blue: 0.50)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 1.0, green: 0.45, blue: 0.35).opacity(0.55)).frame(width: 520).blur(radius: 90).offset(x: -520, y: 280)
            Circle().fill(Color(red: 0.25, green: 0.85, blue: 0.95).opacity(0.50)).frame(width: 600).blur(radius: 100).offset(x: 480, y: 300)
            Circle().fill(Color(red: 0.95, green: 0.80, blue: 0.30).opacity(0.40)).frame(width: 420).blur(radius: 90).offset(x: 40, y: 320)
        }.ignoresSafeArea())
        window.orderFrontRegardless()
        backdrop = window
    }

    private func paste(_ record: ClipRecord, plain: Bool) {
        guard let items = try? engine.payload(of: record) else { return }
        shelf.hide()
        if settings.soundEffects { NSSound(named: "Pop")?.play() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, settings] in
            guard let self else { return }
            PasteAction.perform(items: items, plainText: plain, autoPaste: settings.pasteToActiveApp)
            self.model.didPaste(record)
        }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipboardX")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Show Clipboard", action: #selector(showShelf), keyEquivalent: "").target = self
        menu.items.last?.title = "Show Clipboard    ⇧⌘V"
        stackItem = NSMenuItem(title: "Start Paste Stack", action: #selector(toggleStackAction), keyEquivalent: "")
        stackItem.target = self
        menu.addItem(stackItem)
        menu.addItem(.separator())
        countItem = NSMenuItem(title: "Library: loading…", action: nil, keyEquivalent: "")
        menu.addItem(countItem)
        backupItem = NSMenuItem(title: "iCloud backup: not run yet", action: nil, keyEquivalent: "")
        menu.addItem(backupItem)
        menu.addItem(withTitle: "Back Up and Sync Now", action: #selector(backupNow), keyEquivalent: "").target = self
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
    @objc private func toggleStackAction() { model.toggleStack() }

    private func refreshShortcutLabels() {
        let show = hotKeys.effective[.showShelf]?.display ?? "(none)"
        statusItem.menu?.items.first?.title = "Show Clipboard    \(show)"
        let stack = hotKeys.effective[.pasteStack]?.display ?? ""
        stackItem?.title = (model?.stack.isActive == true ? "End Paste Stack" : "Start Paste Stack") + (stack.isEmpty ? "" : "    \(stack)")
    }

    private func stackChanged(_ stack: PasteStack) {
        statusItem.button?.title = stack.isActive ? " \(stack.ids.count)" : ""
        statusItem.button?.imagePosition = stack.isActive ? .imageLeft : .imageOnly
        statusItem.button?.image = NSImage(systemSymbolName: stack.isActive ? "square.stack.3d.up.fill" : "doc.on.clipboard", accessibilityDescription: "ClipboardX")
        refreshShortcutLabels()
        if settings.soundEffects { NSSound(named: stack.isActive ? "Glass" : "Pop")?.play() }
    }
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
