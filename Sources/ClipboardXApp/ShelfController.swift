import AppKit
import ClipboardXKit
import SwiftUI

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
    /// Keys the shelf consumed on key-down. Their key-up (and auto-repeat) can arrive after the panel hides, with no window
    /// to handle it, which makes macOS play the error beep.
    private var consumedKeys = Set<UInt16>()
    private var resignObserver: NSObjectProtocol?
    private static let height: CGFloat = 276
    private static let margin: CGFloat = 8

    init(model: ShelfModel) {
        self.model = model
        panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: Self.height),
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
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.hide()
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
        let target = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.minY + Self.margin, width: width, height: Self.height)
        panel.setFrame(target.offsetBy(dx: 0, dy: -(Self.height + Self.margin)), display: false)
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

    func hide() {
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
        guard panel.isKeyWindow else { return event }
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53: consumedKeys.insert(event.keyCode); hide(); return nil
        case 123: consumedKeys.insert(event.keyCode); command ? model.switchBoard(by: -1) : model.move(-1); return nil
        case 124: consumedKeys.insert(event.keyCode); command ? model.switchBoard(by: 1) : model.move(1); return nil
        case 36, 76: consumedKeys.insert(event.keyCode); model.pasteSelected(plain: shift); return nil
        default: break
        }
        if command, let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), (1...9).contains(digit) {
            consumedKeys.insert(event.keyCode); model.paste(at: digit - 1, plain: shift); return nil
        }
        return event
    }
}
