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
}
