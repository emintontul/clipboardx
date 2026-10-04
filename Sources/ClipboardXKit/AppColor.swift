import CoreGraphics
import Foundation
import ImageIO

/// Picks a header color for a source app from its icon: a saturation-weighted average of the opaque pixels, softened so a
/// near-white icon does not give a white header. Returns ARGB, or nil when the icon cannot be read or is fully transparent.
public enum AppColor {
    public static func dominant(of png: Data) -> UInt32? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        var sums = (r: 0.0, g: 0.0, b: 0.0), total = 0.0
        for p in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[p + 3]) / 255
            guard alpha > 0.3 else { continue }
            let r = Double(pixels[p]) / 255 / alpha, g = Double(pixels[p + 1]) / 255 / alpha, b = Double(pixels[p + 2]) / 255 / alpha
            let top = max(r, g, b), bottom = min(r, g, b)
            let weight = ((top - bottom) / max(top, 0.001) + 0.1) * alpha
            sums.r += min(r, 1) * weight; sums.g += min(g, 1) * weight; sums.b += min(b, 1) * weight
            total += weight
        }
        guard total > 0 else { return nil }
        var (r, g, b) = (sums.r / total, sums.g / total, sums.b / total)
        let peak = max(r, g, b)
        if peak > 0.85 { let k = 0.85 / peak; r *= k; g *= k; b *= k }
        func byte(_ v: Double) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return 0xFF00_0000 | byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}
