import AppKit
import ClipboardXKit

/// Watches the system pasteboard (there is no change notification on macOS, so it polls the cheap change counter).
final class PasteboardMonitor {
    private let engine: LibraryEngine
    private let settings: AppSettings
    private let queue = DispatchQueue(label: "clipboardx.capture", qos: .userInitiated)
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var registeredApps = Set<String>()
    private static let maxPayload = 256 * 1024 * 1024
    var onCapture: ((ClipRecord) -> Void)?

    init(engine: LibraryEngine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
    }

    func start() {
        timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount
        let pbItems = pasteboard.pasteboardItems ?? []
        let allTypes = pbItems.flatMap { $0.types.map(\.rawValue) }
        let front = NSWorkspace.shared.frontmostApplication
        guard CapturePolicy.decision(types: allTypes, sourceBundleID: front?.bundleIdentifier, settings: settings.capture) == .capture else { return }

        let items: [PasteboardItem] = pbItems.map { item in
            var data: [String: Data] = [:]
            var order: [String] = []
            for type in item.types {
                guard let bytes = item.data(forType: type), bytes.count <= Self.maxPayload else { continue }
                data[type.rawValue] = bytes
                order.append(type.rawValue)
            }
            return PasteboardItem(types: order, dataByType: data)
        }
        let source = front.flatMap { app -> SourceApp? in
            guard let bundle = app.bundleIdentifier else { return nil }
            let needsIcon = registeredApps.insert(bundle).inserted
            return SourceApp(bundleID: bundle, name: app.localizedName ?? bundle, iconPNG: needsIcon ? app.icon.flatMap(Self.png) : nil)
        }
        queue.async { [engine, onCapture] in
            do {
                if let record = try engine.capture(items: items, source: source) {
                    DispatchQueue.main.async { onCapture?(record) }
                }
            } catch { NSLog("ClipboardX: capture failed: \(error)") }
        }
    }

    private static func png(_ image: NSImage) -> Data? {
        let size = NSSize(width: 64, height: 64)
        let small = NSImage(size: size)
        small.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        small.unlockFocus()
        guard let tiff = small.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
