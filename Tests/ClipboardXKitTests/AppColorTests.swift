import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ClipboardXKit

final class AppColorTests: XCTestCase {
    private func png(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) -> Data {
        let size = 32
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: alpha))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private func channels(_ argb: UInt32) -> (r: Int, g: Int, b: Int) { (Int((argb >> 16) & 0xFF), Int((argb >> 8) & 0xFF), Int(argb & 0xFF)) }

    func testRedIconGivesAReddishColor() throws {
        let c = channels(try XCTUnwrap(AppColor.dominant(of: png(red: 0.9, green: 0.1, blue: 0.1))))
        XCTAssertGreaterThan(c.r, c.g + 80)
        XCTAssertGreaterThan(c.r, c.b + 80)
    }

    func testBlueIconGivesABluishColor() throws {
        let c = channels(try XCTUnwrap(AppColor.dominant(of: png(red: 0.1, green: 0.3, blue: 0.9))))
        XCTAssertGreaterThan(c.b, c.r + 80)
    }

    func testResultIsOpaqueAndNeitherTooDarkNorTooLight() throws {
        let argb = try XCTUnwrap(AppColor.dominant(of: png(red: 1, green: 1, blue: 0.9)))
        XCTAssertEqual(argb >> 24, 0xFF)
        let c = channels(argb)
        XCTAssertLessThan(max(c.r, c.g, c.b), 256)
        XCTAssertLessThan((c.r + c.g + c.b) / 3, 235, "a near-white icon must not give a white header")
    }

    func testGrayIconStaysGray() throws {
        let c = channels(try XCTUnwrap(AppColor.dominant(of: png(red: 0.5, green: 0.5, blue: 0.5))))
        XCTAssertLessThan(abs(c.r - c.g), 12)
        XCTAssertLessThan(abs(c.g - c.b), 12)
    }

    func testInvalidDataGivesNil() {
        XCTAssertNil(AppColor.dominant(of: Data([1, 2, 3])))
        XCTAssertNil(AppColor.dominant(of: Data()))
    }

    func testFullyTransparentIconGivesNil() {
        XCTAssertNil(AppColor.dominant(of: png(red: 1, green: 0, blue: 0, alpha: 0)))
    }

    // MARK: dominant hue, vivid result

    /// A square icon split into colored regions, given as (color, share of the area in percent), painted as vertical stripes.
    private func striped(_ parts: [(CGColor, Int)]) -> Data {
        let size = 100
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var x = 0
        for (color, percent) in parts {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: x, y: 0, width: percent, height: size))
            x += percent
        }
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private func hsv(_ argb: UInt32) -> (h: Double, s: Double, v: Double) {
        let r = Double((argb >> 16) & 0xFF) / 255, g = Double((argb >> 8) & 0xFF) / 255, b = Double(argb & 0xFF) / 255
        let top = max(r, g, b), bottom = min(r, g, b), delta = top - bottom
        var h = 0.0
        if delta > 0 {
            if top == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) } else if top == g { h = (b - r) / delta + 2 } else { h = (r - g) / delta + 4 }
            h /= 6; if h < 0 { h += 1 }
        }
        return (h, top == 0 ? 0 : delta / top, top)
    }

    func testMultiColoredIconPicksItsBiggestColorNotAMuddyAverage() throws {
        // mostly blue with bits of red, green and yellow, like a browser icon
        let icon = striped([(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1), 15), (CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1), 15),
                            (CGColor(red: 0.95, green: 0.8, blue: 0.1, alpha: 1), 15), (CGColor(red: 0.15, green: 0.4, blue: 0.95, alpha: 1), 55)])
        let c = hsv(try XCTUnwrap(AppColor.dominant(of: icon)))
        XCTAssertEqual(c.h, 0.62, accuracy: 0.05, "blue, not the olive an average would give")
    }

    func testChromaticResultsAreVividAndNeitherDarkNorPale() throws {
        let samples: [CGColor] = [CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1), CGColor(red: 0.95, green: 0.8, blue: 0.2, alpha: 1),
                                  CGColor(red: 0.5, green: 0.7, blue: 0.5, alpha: 1), CGColor(red: 0.2, green: 0.2, blue: 0.5, alpha: 1)]
        for sample in samples {
            let c = hsv(try XCTUnwrap(AppColor.dominant(of: striped([(sample, 100)]))))
            XCTAssertGreaterThanOrEqual(c.s, 0.55, "\(sample) gave a dull color")
            XCTAssertGreaterThanOrEqual(c.v, 0.6)
            XCTAssertLessThanOrEqual(c.v, 0.92)
        }
    }

    func testBlackAndWhiteIconsGetAGraphiteNotBlackOrWhite() throws {
        for color in [CGColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1), CGColor(red: 1, green: 1, blue: 1, alpha: 1)] {
            let c = hsv(try XCTUnwrap(AppColor.dominant(of: striped([(color, 100)]))))
            XCTAssertLessThan(c.s, 0.2)
            XCTAssertGreaterThan(c.v, 0.2)
            XCTAssertLessThan(c.v, 0.5)
        }
    }

    func testAMostlyGrayIconWithATinyAccentStaysGray() throws {
        let icon = striped([(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1), 97), (CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1), 3)])
        XCTAssertLessThan(hsv(try XCTUnwrap(AppColor.dominant(of: icon))).s, 0.2)
    }
}
