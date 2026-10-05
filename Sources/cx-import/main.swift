import AppKit
import ClipboardXKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func option(_ name: String, in args: [String]) -> URL? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
}

let args = Array(CommandLine.arguments.dropFirst())

if args.first == "demo" {
    guard let out = option("--out", in: args) else { fail("usage: cx-import demo --out <empty folder>") }
    do { try DemoSeed.run(at: out); exit(0) } catch { fail("error: \(error)") }
}

if args.first == "app-colors" {
    // Prints the header color ClipboardX would pick for each installed app's icon.
    let ids = ["com.google.Chrome", "com.apple.Safari", "com.apple.Notes", "com.apple.mail", "com.apple.Terminal", "com.apple.finder", "com.apple.dt.Xcode",
               "com.apple.Preview", "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "com.tinyspeck.slackmacgap", "com.microsoft.VSCode", "ru.keepcoder.Telegram",
               "com.apple.Photos", "com.apple.iCal", "com.apple.reminders", "com.apple.systempreferences", "com.openai.chat", "company.thebrowser.Browser", "com.figma.Desktop"]
    for id in ids {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus(); NSWorkspace.shared.icon(forFile: url.path).draw(in: NSRect(origin: .zero, size: size)); image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { continue }
        let hex = AppColor.dominant(of: png).map { String(format: "#%06X", $0 & 0xFFFFFF) } ?? "none"
        print("\(id) \(hex)")
    }
    exit(0)
}

if args.first == "trash" {
    // Moves history clips whose text starts with the given prefix to the trash (restorable). Run it with the app closed.
    guard let library = option("--library", in: args), let prefix = args.firstIndex(of: "--prefix").map({ args[$0 + 1] }), prefix.count >= 8 else {
        fail("usage: cx-import trash --library <lib> --prefix <text, at least 8 characters>")
    }
    do {
        let device = ProcessInfo.processInfo.hostName.replacingOccurrences(of: " ", with: "-").lowercased()
        let engine = try LibraryEngine(library: library, deviceID: device)
        while engine.isIndexing { Thread.sleep(forTimeInterval: 0.2) }
        var moved = 0
        for record in try engine.search(prefix, board: nil, limit: 50) {
            let text = engine.text(of: record)
            guard text.hasPrefix(prefix), text.count < 120 else { continue }
            try engine.delete(record.id)
            moved += 1
        }
        print("moved to trash: \(moved) clip(s) starting with \"\(prefix)\"")
        exit(0)
    } catch { fail("error: \(error)") }
}

if args.first == "sync" {
    guard let library = option("--library", in: args), let shared = option("--shared", in: args), let own = args.firstIndex(of: "--own").map({ args[$0 + 1] }),
          let device = args.firstIndex(of: "--device").map({ args[$0 + 1] }) else { fail("usage: cx-import sync --library <lib> --shared <ClipboardX folder> --own <own folder name> --device <device id>") }
    do {
        let engine = try LibraryEngine(library: library, deviceID: device)
        while engine.isIndexing { Thread.sleep(forTimeInterval: 0.2) }
        let started = Date()
        let r = try LibrarySync(engine: engine, sharedRoot: shared, ownFolder: own).syncNow()
        print("devices=\(r.devices) newEvents=\(r.newEvents) blobsFetched=\(r.blobsFetched) deferred=\(r.deferred) pendingText=\(r.pendingText) seconds=\(String(format: "%.1f", Date().timeIntervalSince(started)))")
        exit(0)
    } catch { fail("error: \(error)") }
}

if ["backup", "restore", "backup-verify"].contains(args.first ?? "") {
    let deviceID = ProcessInfo.processInfo.hostName.replacingOccurrences(of: " ", with: "-")
    do {
        switch args.first {
        case "backup":
            guard let library = option("--library", in: args), let dest = option("--dest", in: args) else { fail("usage: cx-import backup --library <lib> --dest <dir>") }
            let r = try LibraryBackup.backup(library: library, destination: dest, deviceID: deviceID)
            print("blobsPacked=\(r.blobsPacked) packsWritten=\(r.packsWritten) logFilesCopied=\(r.logFilesCopied)")
        case "restore":
            guard let from = option("--from", in: args), let to = option("--to", in: args) else { fail("usage: cx-import restore --from <backup> --to <lib>") }
            let r = try LibraryBackup.restore(from: from, to: to)
            print("blobsRestored=\(r.blobsRestored) logFilesRestored=\(r.logFilesRestored)")
        default:
            guard let library = option("--library", in: args), let dest = option("--dest", in: args) else { fail("usage: cx-import backup-verify --library <lib> --dest <dir>") }
            let r = try LibraryBackup.verify(library: library, backup: dest)
            print("libraryBlobs=\(r.libraryBlobs) missingFromBackup=\(r.missingFromBackup) missingLogFiles=\(r.missingLogFiles) brokenPacks=\(r.brokenPacks) complete=\(r.complete)")
            exit(r.complete ? 0 : 2)
        }
        exit(0)
    } catch { fail("error: \(error)") }
}

if ["index", "search", "bench"].contains(args.first ?? "") {
    guard let library = option("--library", in: args) else { fail("usage: cx-import index|search --library <library> [query]") }
    do {
        if args.first == "index" {
            let s = try IndexBuilder.rebuild(library: library, progress: { d, t in FileHandle.standardError.write(Data("  \(d)/\(t)\r".utf8)) })
            print("indexed=\(s.documents) withText=\(s.withText) seconds=\(String(format: "%.1f", s.seconds))")
        } else if args.first == "bench" {
            let index = try SearchIndex(path: library.appendingPathComponent("index.sqlite"))
            let queries = ["Togg Lite", "togglite", "tog lite", "istanbul", "ssh", "ss", "nginx upstream", "http", "a", "merhaba", "zzzzqx"]
            print("query | median ms | p95 ms | hits  (20 runs, warm, one process)")
            for q in queries {
                _ = try index.search(q, limit: 10)
                var times: [Double] = []
                var count = 0
                for _ in 0..<20 {
                    let t0 = Date(); count = try index.search(q, limit: 10).count
                    times.append(Date().timeIntervalSince(t0) * 1000)
                }
                times.sort()
                print("\(q) | \(String(format: "%.1f", times[10])) | \(String(format: "%.1f", times[18])) | \(count)")
            }
        } else {
            let query = args.last { !$0.hasPrefix("--") && URL(fileURLWithPath: $0) != library } ?? ""
            let index = try SearchIndex(path: library.appendingPathComponent("index.sqlite"))
            let t0 = Date()
            let hits = try index.search(query, limit: 10)
            let ms = Date().timeIntervalSince(t0) * 1000
            print("hits=\(hits.count) time=\(String(format: "%.1f", ms))ms")
            for h in hits { print("  \(h.id) score=\(Int(h.score)) \(h.reasons.joined(separator: ","))") }
        }
        exit(0)
    } catch { fail("error: \(error)") }
}

guard let command = args.first, ["import", "verify"].contains(command),
      let snapshot = option("--snapshot", in: args), let external = option("--external", in: args),
      let output = option("--out", in: args) else {
    fail("usage: cx-import import|verify --snapshot <paste-snapshot.sqlite> --external <_EXTERNAL_DATA> --out <library>")
}

let progress: (Int, Int) -> Void = { done, total in
    FileHandle.standardError.write(Data("  \(done)/\(total)\r".utf8))
}

do {
    switch command {
    case "import":
        let deviceID = ProcessInfo.processInfo.hostName.replacingOccurrences(of: " ", with: "-")
        let s = try PasteImporter.run(snapshot: snapshot, externalDirectory: external, output: output,
                                      deviceID: deviceID, progress: progress)
        print("read=\(s.itemsRead) imported=\(s.itemsImported) alreadyPresent=\(s.itemsAlreadyPresent) boards=\(s.boards) apps=\(s.apps) undecodable=\(s.undecodable.count)")
        if !s.undecodable.isEmpty { print("undecodable ids (kept raw): \(s.undecodable.prefix(20).joined(separator: ","))") }
    default:
        let r = try PasteVerifier.verify(snapshot: snapshot, externalDirectory: external, output: output, progress: progress)
        print("source=\(r.sourceItems) verified=\(r.verifiedItems) mismatches=\(r.mismatches) missing=\(r.missingRecords) passed=\(r.passed)")
        if !r.problemIDs.isEmpty { print("problem ids: \(r.problemIDs.prefix(20).joined(separator: ","))") }
        exit(r.passed ? 0 : 2)
    }
} catch {
    fail("error: \(error)")
}
