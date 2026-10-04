import AppKit
import ClipboardXKit
import ImageIO
import LinkPresentation
import UniformTypeIdentifiers

struct FetchedLink: Sendable {
    var title: String?
    var iconData: Data?
    var imageData: Data?
}

protocol LinkFetching: Sendable {
    func fetch(_ url: URL) async throws -> FetchedLink
}

/// Fetches page titles and images for link cards. Off by default: a fetch sends the link to its website. Only links that
/// pass `LinkSafety` are ever requested, results (and failures) are cached in the library, and a failed lookup waits a
/// week before it is tried again.
final class LinkPreviewService: @unchecked Sendable {
    static let retryAfter: Double = 7 * 86_400
    private let engine: LibraryEngine
    private let fetcher: LinkFetching
    private let isEnabled: () -> Bool
    private let now: () -> Double
    private let lock = NSLock()
    private var inFlight = Set<String>()
    var onUpdate: ((String) -> Void)?

    init(engine: LibraryEngine, fetcher: LinkFetching, isEnabled: @escaping () -> Bool, now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.engine = engine
        self.fetcher = fetcher
        self.isEnabled = isEnabled
        self.now = now
    }

    /// Called when a link card appears. Returns immediately; the work happens in the background.
    func request(_ link: String) {
        Task.detached(priority: .utility) { [self] in await process(link) }
    }

    func process(_ link: String) async {
        guard isEnabled(), let url = URL(string: link), LinkSafety.isFetchable(url) else { return }
        if let known = try? engine.linkRecord(for: link) {
            if !known.failed { return }
            if now() - known.fetchedAt < Self.retryAfter { return }
        }
        guard begin(link) else { return }
        defer { end(link) }
        do {
            let fetched = try await fetcher.fetch(url)
            _ = try engine.saveLink(url: link, title: fetched.title, icon: fetched.iconData, image: fetched.imageData, now: now())
        } catch {
            _ = try? engine.saveLink(url: link, title: nil, icon: nil, image: nil, failed: true, now: now())
        }
        onUpdate?(link)
    }

    private func begin(_ link: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.insert(link).inserted
    }

    private func end(_ link: String) {
        lock.lock(); defer { lock.unlock() }
        inFlight.remove(link)
    }
}

/// The real fetcher, built on Apple's LinkPresentation.
struct SystemLinkFetcher: LinkFetching {
    func fetch(_ url: URL) async throws -> FetchedLink {
        let provider = LPMetadataProvider()
        provider.timeout = 6
        let metadata = try await provider.startFetchingMetadata(for: url)
        async let icon = Self.imageData(from: metadata.iconProvider, maxSide: 128, jpeg: false)
        async let image = Self.imageData(from: metadata.imageProvider, maxSide: 900, jpeg: true)
        return FetchedLink(title: metadata.title, iconData: await icon, imageData: await image)
    }

    private static func imageData(from provider: NSItemProvider?, maxSide: CGFloat, jpeg: Bool) async -> Data? {
        guard let provider, provider.canLoadObject(ofClass: NSImage.self) else { return nil }
        let image: NSImage? = await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSImage.self) { object, _ in continuation.resume(returning: object as? NSImage) }
        }
        guard let tiff = image?.tiffRepresentation, let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                         kCGImageSourceThumbnailMaxPixelSize: maxSide] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumb, jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary : nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
