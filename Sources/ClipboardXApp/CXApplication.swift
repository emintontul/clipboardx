import AppKit

/// ClipboardX is a menu-bar app with no windows of its own most of the time. When a key event reaches it while it has no
/// key window and is not the active app, AppKit has nowhere to route it and plays the error beep. Those events are
/// leftovers of keys the shelf already handled, so they are dropped here instead.
final class CXApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .keyUp {
            if keyWindow == nil, !isActive { return }
        }
        super.sendEvent(event)
    }
}
