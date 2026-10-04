import XCTest
import SwiftUI
import ClipboardXKit
@testable import ClipboardXApp

/// Draws a card off-screen and measures pixels, so corner shapes are checked by number rather than by eye.
@MainActor
final class CardGeometryTests: XCTestCase {
    private var dir: URL!
    private var engine: LibraryEngine!
    private var model: ShelfModel!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        engine = try LibraryEngine(library: dir, deviceID: "dev")
        model = ShelfModel(engine: engine, settings: AppSettings.shared)
        model.shelfHeight = 400
        let item = PasteboardItem(types: ["public.utf8-plain-text"], dataByType: ["public.utf8-plain-text": Data("hello".utf8)])
        _ = try engine.capture(items: [item], source: nil, now: 1)
        model.reload(resetSelection: true)
    }

    override func tearDownWithError() throws { model = nil; engine = nil; try? FileManager.default.removeItem(at: dir) }

    private func renderCard() throws -> (pixels: [UInt8], width: Int, height: Int) {
        let card = try XCTUnwrap(model.cards.first)
        let view = CardView(card: card, number: 1, selected: false, model: model)
            .frame(width: model.cardWidth, height: model.cardHeight)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (pixels, image.width, image.height)
    }

    private func rgba(_ r: (pixels: [UInt8], width: Int, height: Int), x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (y * r.width + x) * 4
        return (Int(r.pixels[i]), Int(r.pixels[i + 1]), Int(r.pixels[i + 2]), Int(r.pixels[i + 3]))
    }

    /// Header is 66 pt tall = 132 px at scale 2. Its bottom-left corner must be as colored as its middle.
    func testHeaderBottomCornersAreSquare() throws {
        let r = try renderCard()
        let headerBottom = 66 * 2
        let middle = rgba(r, x: r.width / 2, y: headerBottom - 6)
        for (x, y) in [(3, headerBottom - 3), (r.width - 4, headerBottom - 3), (6, headerBottom - 2), (r.width - 7, headerBottom - 2)] {
            let corner = rgba(r, x: x, y: y)
            XCTAssertLessThan(abs(corner.r - middle.r) + abs(corner.g - middle.g) + abs(corner.b - middle.b), 60,
                              "pixel (\(x),\(y)) is \(corner) but the header color is \(middle): the header's bottom corner is rounded")
        }
    }

    func testHeaderTopCornersFollowTheCard() throws {
        let r = try renderCard()
        XCTAssertLessThan(rgba(r, x: 1, y: 1).a, 40, "the card's own top corner is rounded, so the very corner pixel is transparent")
    }
}
