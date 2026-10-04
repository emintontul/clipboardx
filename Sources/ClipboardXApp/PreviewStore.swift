import AppKit
import ClipboardXKit
import ImageIO
import QuickLookThumbnailing
import SwiftUI

final class Preview {
    let text: String
    let charCount: Int
    let image: NSImage?
    let imageSize: CGSize?
    let isLink: Bool
    let fileNames: [String]
    let filePaths: [String]
    let fileImage: NSImage?
    let linkTitle: String?
    let linkIcon: NSImage?
    let linkImage: NSImage?

    init(text: String, charCount: Int, image: NSImage?, imageSize: CGSize?, isLink: Bool, fileNames: [String],
         filePaths: [String] = [], fileImage: NSImage? = nil, linkTitle: String? = nil, linkIcon: NSImage? = nil, linkImage: NSImage? = nil) {
        self.linkTitle = linkTitle; self.linkIcon = linkIcon; self.linkImage = linkImage
        self.text = text; self.charCount = charCount; self.image = image; self.imageSize = imageSize
        self.isLink = isLink; self.fileNames = fileNames; self.filePaths = filePaths; self.fileImage = fileImage
    }
}

/// Loads card previews off the main thread and caches them. Full payloads stay in the blob store.
final class PreviewStore {
    static let shared = PreviewStore()
    var engine: LibraryEngine?
    var linkPreviewsEnabled: () -> Bool = { false }
    private let cache = NSCache<NSString, Preview>()
    private let queue = DispatchQueue(label: "clipboardx.preview", qos: .userInitiated, attributes: .concurrent)
    private let icons = NSCache<NSString, NSImage>()
    private var colors: [String: Color?] = [:]
    private let colorLock = NSLock()

    private init() { cache.countLimit = 400 }

    func load(_ record: ClipRecord, completion: @escaping (Preview) -> Void) {
        if let hit = cache.object(forKey: record.id as NSString) { return completion(hit) }
        queue.async { [weak self] in
            guard let self, let engine = self.engine else { return }
            let preview = Self.build(record, engine: engine, enabled: self.linkPreviewsEnabled())
            self.cache.setObject(preview, forKey: record.id as NSString)
            DispatchQueue.main.async { completion(preview) }
        }
    }

    /// Forget cached previews so cards pick up a freshly fetched link title or image.
    func invalidateAll() { cache.removeAllObjects() }

    func icon(bundleID: String?) -> NSImage? {
        guard let bundleID, let engine else { return nil }
        if let hit = icons.object(forKey: bundleID as NSString) { return hit }
        guard let data = try? engine.iconData(bundleID: bundleID), let image = NSImage(data: data) else { return nil }
        icons.setObject(image, forKey: bundleID as NSString)
        return image
    }

    /// Header color for a source app, derived from its icon once and remembered.
    func appColor(bundleID: String?) -> Color? {
        guard let bundleID, let engine else { return nil }
        colorLock.lock(); defer { colorLock.unlock() }
        if let known = colors[bundleID] { return known }
        let color = (try? engine.iconData(bundleID: bundleID)).flatMap { $0 }.flatMap(AppColor.dominant(of:)).map { Color(argb: $0) }
        colors[bundleID] = .some(color)
        return color
    }

    private static func fileThumbnail(path: String) -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 256, height: 256),
                                                   scale: 2, representationTypes: .thumbnail)
        let done = DispatchSemaphore(value: 0)
        var image: NSImage?
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in image = rep?.nsImage; done.signal() }
        _ = done.wait(timeout: .now() + 2)
        return image ?? NSWorkspace.shared.icon(forFile: path)
    }

    private static func build(_ record: ClipRecord, engine: LibraryEngine, enabled: Bool) -> Preview {
        let full = engine.text(of: record)
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        var image: NSImage?
        var size: CGSize?
        if let data = engine.imageData(of: record) ?? engine.previewData(of: record), let thumb = thumbnail(data) {
            image = NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))
            size = CGSize(width: thumb.width, height: thumb.height)
        }
        let isFile = record.representations.contains { $0.uti == "public.file-url" }
        let paths = isFile ? trimmed.split(separator: "\n").map(String.init) : []
        let names = paths.map { ($0 as NSString).lastPathComponent }
        let fileImage = paths.first.flatMap { fileThumbnail(path: $0) }
        let isLink = !trimmed.contains(" ") && !trimmed.contains("\n") && (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"))
        var linkTitle: String?, linkIcon: NSImage?, linkImage: NSImage?
        if isLink, enabled, let link = try? engine.linkRecord(for: trimmed), !link.failed {
            linkTitle = link.title
            linkIcon = link.iconBlob.flatMap { engine.linkBlob($0) }.flatMap { NSImage(data: $0) }
            linkImage = link.imageBlob.flatMap { engine.linkBlob($0) }.flatMap { NSImage(data: $0) }
        }
        return Preview(text: String(trimmed.prefix(1500)), charCount: full.count, image: image, imageSize: size, isLink: isLink,
                       fileNames: names, filePaths: paths, fileImage: fileImage, linkTitle: linkTitle, linkIcon: linkIcon, linkImage: linkImage)
    }

    private static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 560]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
