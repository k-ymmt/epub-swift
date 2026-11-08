import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// RGBA8 bitmap extracted from a snapshot image, used for pixel assertions.
public struct Bitmap: Sendable {
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]
    /// Pixels per point: rects passed to the query methods are in points and scaled by this.
    public var pointScale: Double = 1

    public init(cgImage: CGImage, pointScale: Double = 1) {
        self.pointScale = pointScale
        let w = cgImage.width, h = cgImage.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        width = w
        height = h
        bytes = buf
    }

    public struct RGB: Equatable, Sendable, CustomStringConvertible {
        public var r: Int, g: Int, b: Int
        public var description: String { String(format: "#%02x%02x%02x", r, g, b) }
        public func near(_ o: RGB, tolerance: Int = 24) -> Bool {
            abs(r - o.r) <= tolerance && abs(g - o.g) <= tolerance && abs(b - o.b) <= tolerance
        }
    }

    public func pixel(_ x: Int, _ y: Int) -> RGB {
        let i = (y * width + x) * 4
        return RGB(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]))
    }

    /// Most frequent color (quantized to 16 levels per channel) inside a pixel rect.
    private func px(_ rect: CGRect?) -> CGRect {
        guard let rect else { return CGRect(x: 0, y: 0, width: width, height: height) }
        return CGRect(x: rect.minX * pointScale, y: rect.minY * pointScale, width: rect.width * pointScale, height: rect.height * pointScale)
    }

    public func dominantColor(in rect: CGRect? = nil) -> RGB {
        let r = px(rect)
        var counts: [Int: Int] = [:]
        var sample: [Int: RGB] = [:]
        for y in Int(r.minY)..<Int(r.maxY) where y >= 0 && y < height {
            for x in Int(r.minX)..<Int(r.maxX) where x >= 0 && x < width {
                let p = pixel(x, y)
                let key = (p.r >> 4) << 8 | (p.g >> 4) << 4 | (p.b >> 4)
                counts[key, default: 0] += 1
                if sample[key] == nil { sample[key] = p }
            }
        }
        let best = counts.max { $0.value < $1.value }!.key
        return sample[best]!
    }

    public func count(where pred: (RGB) -> Bool, in rect: CGRect? = nil) -> Int {
        countPixels(where: pred, in: px(rect))
    }

    private func countPixels(where pred: (RGB) -> Bool, in r: CGRect) -> Int {
        var n = 0
        for y in Int(r.minY)..<Int(r.maxY) where y >= 0 && y < height {
            for x in Int(r.minX)..<Int(r.maxX) where x >= 0 && x < width {
                if pred(pixel(x, y)) { n += 1 }
            }
        }
        return n
    }

    /// Fraction of non-background (non-white) pixels inside a rect. Used to detect blank renders.
    public func inkRatio(in rect: CGRect? = nil) -> Double {
        let r = px(rect)
        let total = max(1, Int(r.width) * Int(r.height))
        let ink = countPixels(where: { !($0.r > 235 && $0.g > 235 && $0.b > 235) }, in: r)
        return Double(ink) / Double(total)
    }
}

public func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw SpikeError.unexpected("cannot create PNG destination \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) { throw SpikeError.unexpected("PNG write failed \(url.path)") }
}
