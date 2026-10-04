import AppKit
import Combine
import ClipboardXKit
import SwiftUI

/// Quick Look must be a key window: an inactive menu-bar app does not draw SwiftUI content in windows that are not key.
final class QuickLookPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the bottom-of-screen panel. It never activates the app, so the app you were typing in keeps focus for pasting.
final class ShelfController {
    private let panel: ShelfPanel
    private let model: ShelfModel
    private var keyMonitor: Any?
    private var strayKeyMonitor: Any?
    private var quickLookPanel: QuickLookPanel?
    /// Set before the Quick Look panel takes the key, because `@Published` publishes before the model's value changes.
    private var quickLookOpen = false
    private var quickLookSubscription: AnyCancellable?
    /// Keys the shelf consumed on key-down. Their key-up (and auto-repeat) can arrive after the panel hides, with no window
    /// to handle it, which makes macOS play the error beep.
    private var consumedKeys = Set<UInt16>()
    private var resignObserver: NSObjectProtocol?
    private static let minHeight: CGFloat = 276
    private static let maxHeight: CGFloat = 460
    private static let margin: CGFloat = 8
    private var height: CGFloat = 276

    init(model: ShelfModel) {
        self.model = model
        let saved = UserDefaults.standard.double(forKey: "shelfHeight")
        let override = ProcessInfo.processInfo.environment["CLIPBOARDX_SHELF_HEIGHT"].flatMap(Double.init)
        height = min(max(CGFloat(override ?? (saved > 0 ? saved : 276)), Self.minHeight), Self.maxHeight)
        model.shelfHeight = height
        panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: height),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isFloatingPanel = true
        // Must come after isFloatingPanel, which resets the level. Above the Dock so the shelf covers it.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: ShelfView(model: model))
        strayKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyUp { return self.consumedKeys.remove(event.keyCode) != nil ? nil : event }
            return (!self.panel.isVisible && self.consumedKeys.contains(event.keyCode)) ? nil : event
        }
        quickLookSubscription = model.$quickLookID.sink { [weak self] id in self?.updateQuickLook(id) }
        model.onResizeDrag = { [weak self] in self?.dragResize() }
        model.onResizeEnd = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(self.height), forKey: "shelfHeight")
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self, !self.quickLookOpen else { return }
            self.hide()
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show(query: String? = nil) {
        model.resetForShow()
        if let query { model.query = query }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        // CLIPBOARDX_SHELF_WIDTH narrows and centers the shelf; used only to frame screenshots.
        let full = screen.frame.width - Self.margin * 2
        let width = ProcessInfo.processInfo.environment["CLIPBOARDX_SHELF_WIDTH"].flatMap(Double.init).map { min(CGFloat($0), full) } ?? full
        let target = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.minY + Self.margin, width: width, height: height)
        panel.setFrame(target.offsetBy(dx: 0, dy: -(height + Self.margin)), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        installKeyMonitor()
    }

    /// Keeps the bottom edge fixed and follows the mouse with the top edge.
    private func dragResize() {
        let newHeight = min(max(NSEvent.mouseLocation.y - panel.frame.minY + 8, Self.minHeight), Self.maxHeight)
        guard newHeight != height else { return }
        height = newHeight
        model.shelfHeight = newHeight
        var frame = panel.frame
        frame.size.height = newHeight
        panel.setFrame(frame, display: true)
    }

    /// Quick Look lives in its own panel above the shelf, so it is not clipped by the shelf and never takes keyboard focus.
    private func updateQuickLook(_ id: String?) {
        guard let id, let card = model.cards.first(where: { $0.id == id }) else {
            quickLookOpen = false
            let wasOpen = quickLookPanel?.isVisible == true
            quickLookPanel?.orderOut(nil)
            if wasOpen, panel.isVisible { panel.makeKey() }
            return
        }
        let size = NSSize(width: 580, height: 440)
        let look = quickLookPanel ?? QuickLookPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: false)
        look.isOpaque = false
        look.backgroundColor = .clear
        look.hasShadow = true
        look.isFloatingPanel = true
        look.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        look.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        look.contentView = NSHostingView(rootView: QuickLookView(card: card, model: model))
        let shelf = panel.frame
        look.setFrame(NSRect(x: shelf.midX - size.width / 2, y: shelf.maxY + 14, width: size.width, height: size.height), display: true)
        quickLookOpen = true
        look.orderFrontRegardless()
        look.makeKey()
        quickLookPanel = look
    }

    func hide() {
        model.quickLookID = nil
        guard panel.isVisible else { return }
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.handle(event) ?? event }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard panel.isKeyWindow || quickLookPanel?.isKeyWindow == true else { return event }
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53: consumedKeys.insert(event.keyCode); if !model.closeQuickLook() { hide() }; return nil
        case 49 where model.query.isEmpty: consumedKeys.insert(event.keyCode); model.toggleQuickLook(); return nil
        case 51 where !command && model.query.isEmpty && model.hasFilters: consumedKeys.insert(event.keyCode); _ = model.removeLastFilter(); return nil
        case 123: consumedKeys.insert(event.keyCode); command ? model.switchBoard(by: -1) : model.move(-1); return nil
        case 124: consumedKeys.insert(event.keyCode); command ? model.switchBoard(by: 1) : model.move(1); return nil
        case 36, 76: consumedKeys.insert(event.keyCode); model.pasteSelected(plain: shift); return nil
        case 51, 117 where command: consumedKeys.insert(event.keyCode); model.deleteSelected(); return nil
        case 14 where command: consumedKeys.insert(event.keyCode); model.editSelected(); return nil
        default: break
        }
        if command, let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), (1...9).contains(digit) {
            consumedKeys.insert(event.keyCode); model.paste(at: digit - 1, plain: shift); return nil
        }
        return event
    }
}
