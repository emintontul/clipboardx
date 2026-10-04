import AppKit
import ClipboardXKit
import Foundation

/// Builds a small, entirely made-up library for screenshots and demos. Nothing here comes from a real clipboard.
enum DemoSeed {
    private struct Clip {
        let text: String?
        let app: String
        let minutesAgo: Double
        var title: String?
        var fileURL: String?
        var image = false
    }

    static func run(at library: URL) throws {
        let engine = try LibraryEngine(library: library, deviceID: "demo")
        let apps: [String: String] = [
            "com.apple.Terminal": "Terminal", "com.apple.Notes": "Notes", "com.apple.Safari": "Safari", "com.apple.mail": "Mail",
            "com.apple.Preview": "Preview", "com.apple.dt.Xcode": "Xcode", "com.apple.finder": "Finder",
        ]
        for (bundle, name) in apps { try engine.registerApp(SourceApp(bundleID: bundle, name: name, iconPNG: icon(for: bundle))) }

        let clips: [Clip] = [
            Clip(text: "file:///Users/demo/Documents/Roadmap.pdf", app: "com.apple.finder", minutesAgo: 2880, fileURL: "file:///Users/demo/Documents/Roadmap.pdf"),
            Clip(text: "Ship the beta on Friday. Ask design for the final icon set.", app: "com.apple.Notes", minutesAgo: 1500),
            Clip(text: "ssh deploy@staging.example.com -p 2222", app: "com.apple.Terminal", minutesAgo: 1440, title: "Staging server"),
            Clip(text: "SELECT count(*) FROM clips WHERE pinned = 1;", app: "com.apple.dt.Xcode", minutesAgo: 360, title: "Count pinned"),
            Clip(text: "enum DayOfWeek: CaseIterable {\n    case monday, tuesday, wednesday\n    case thursday, friday\n}", app: "com.apple.dt.Xcode", minutesAgo: 340),
            Clip(text: "Project kick-off meeting\nPlease join us on Friday at 10 am for the kick-off in the third-floor room. We will cover scope, timeline and owners. Water and light refreshments will be provided.", app: "com.apple.Notes", minutesAgo: 320),
            Clip(text: "https://swift.org/blog/swift-6/", app: "com.apple.Safari", minutesAgo: 300),
            Clip(text: "Call Alex about the lease before Friday", app: "com.apple.Notes", minutesAgo: 180),
            Clip(text: "docker compose up -d && docker compose logs -f api", app: "com.apple.Terminal", minutesAgo: 120),
            Clip(text: nil, app: "com.apple.Preview", minutesAgo: 60, image: true),
            Clip(text: "Invoice #2041 · due Oct 28 · total $1,280.00", app: "com.apple.mail", minutesAgo: 40),
            Clip(text: "https://developer.apple.com/documentation/appkit/nspasteboard", app: "com.apple.Safari", minutesAgo: 25),
            Clip(text: "Standup: finish onboarding flow, review PR #482, update release notes", app: "com.apple.Notes", minutesAgo: 12),
            Clip(text: "git rebase -i HEAD~3", app: "com.apple.Terminal", minutesAgo: 5),
        ]
        let now = Date().timeIntervalSince1970
        var ids: [String] = []
        for clip in clips {
            let item = pasteboardItem(for: clip)
            let source = SourceApp(bundleID: clip.app, name: apps[clip.app] ?? clip.app, iconPNG: nil)
            guard let record = try engine.capture(items: [item], source: source, now: now - clip.minutesAgo * 60) else { continue }
            if let title = clip.title { try engine.setTitle(record.id, to: title) }
            ids.append(record.id)
        }

        let boards: [(String, String, UInt32)] = [
            ("list:snippets", "Snippets", 0xFF0A84FF), ("list:servers", "Servers", 0xFFFF453A), ("list:links", "Links", 0xFF32D74B),
            ("list:design", "Design", 0xFFBF5AF2), ("list:receipts", "Receipts", 0xFFFF9F0A),
        ]
        for (id, name, color) in boards { try engine.addBoard(id: id, name: name, colorCode: color) }
        let byTitle = { (needle: String) in try engine.search(needle, board: nil, limit: 1).first?.id }
        if let id = try byTitle("Staging server") { try engine.pin(id, to: "list:servers") }
        if let id = try byTitle("Count pinned") { try engine.pin(id, to: "list:snippets") }
        if let id = try byTitle("git rebase") { try engine.pin(id, to: "list:snippets") }
        if let id = try byTitle("swift.org") { try engine.pin(id, to: "list:links") }
        if let id = try byTitle("nspasteboard") { try engine.pin(id, to: "list:links") }
        if let id = try byTitle("Invoice") { try engine.pin(id, to: "list:receipts") }
        if let id = try byTitle("Call Alex") { try engine.delete(id, now: now - 3600) }
        print("demo library at \(library.path): \(ids.count) clips, \(boards.count) pinboards")
    }

    private static func pasteboardItem(for clip: Clip) -> PasteboardItem {
        if clip.image { return PasteboardItem(types: ["public.png"], dataByType: ["public.png": gradientPNG()]) }
        if let url = clip.fileURL { return PasteboardItem(types: ["public.file-url"], dataByType: ["public.file-url": Data(url.utf8)]) }
        let text = Data((clip.text ?? "").utf8)
        return PasteboardItem(types: ["public.utf8-plain-text"], dataByType: ["public.utf8-plain-text": text])
    }

    private static func icon(for bundleID: String) -> Data? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        NSWorkspace.shared.icon(forFile: url.path).draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func gradientPNG() -> Data {
        let size = NSSize(width: 640, height: 400)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [NSColor(red: 0.98, green: 0.55, blue: 0.30, alpha: 1), NSColor(red: 0.55, green: 0.25, blue: 0.85, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: size), angle: 35)
        let text = NSAttributedString(string: "Q3 report", attributes: [.font: NSFont.systemFont(ofSize: 54, weight: .bold), .foregroundColor: NSColor.white])
        text.draw(at: NSPoint(x: 36, y: 40))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
