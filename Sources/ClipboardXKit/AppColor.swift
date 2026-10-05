import CoreGraphics
import Foundation
import ImageIO

/// Picks a header color for a source app from its icon.
///
/// Averaging a multi-colored icon gives mud (a browser icon averages to khaki), so the icon's pixels are sorted into twelve hue
/// groups and the heaviest one wins; the result is then moved into a vivid, readable range. Icons with no real color (black,
/// white, gray) get a neutral graphite instead of black or white. Returns ARGB, or nil when the icon cannot be read or is fully
/// transparent.
public enum AppColor {
    private static let graphite: UInt32 = 0xFF4A4C52
    private static let bins = 12

    public static func dominant(of png: Data) -> UInt32? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let size = 24
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        var weight = [Double](repeating: 0, count: bins)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: bins)
        var opaque = 0.0
        for p in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[p + 3]) / 255
            guard alpha > 0.5 else { continue }
            opaque += 1
            let r = min(Double(pixels[p]) / 255 / alpha, 1), g = min(Double(pixels[p + 1]) / 255 / alpha, 1), b = min(Double(pixels[p + 2]) / 255 / alpha, 1)
            let (h, s, v) = hsv(r, g, b)
            guard s >= 0.18, v >= 0.2 else { continue }       // gray, black and white carry no hue
            let bin = Int(h * Double(bins)) % bins
            let w = s * v
            weight[bin] += w
            sums[bin].r += r * w; sums[bin].g += g * w; sums[bin].b += b * w
        }
        guard opaque > 0 else { return nil }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] / opaque > 0.04 else { return graphite }

        let (h, s, v) = hsv(sums[best].r / weight[best], sums[best].g / weight[best], sums[best].b / weight[best])
        return argb(h: h, s: min(max(s, 0.6), 0.85), v: min(max(v, 0.66), 0.9))
    }

    private static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let top = max(r, g, b), delta = top - min(r, g, b)
        var h = 0.0
        if delta > 0 {
            if top == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) } else if top == g { h = (b - r) / delta + 2 } else { h = (r - g) / delta + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, top == 0 ? 0 : delta / top, top)
    }

    private static func argb(h: Double, s: Double, v: Double) -> UInt32 {
        let c = v * s, x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h * 6) % 6 {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        func byte(_ value: Double) -> UInt32 { UInt32(max(0, min(255, ((value + m) * 255).rounded()))) }
        return 0xFF00_0000 | byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}
