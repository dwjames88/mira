import CoreGraphics
import CoreImage
import Foundation

/// Colours that decide how small a packed film cube may be: pixels of real photographs plus a synthetic sweep, as
/// encoded sRGB triples in 0...1. A cube is judged by how far it moves these colours, not by its lattice corners,
/// most of which (saturated, near-clipped) no photo reaches.
public enum PackProbe {
    /// Unique 8-bit colours of `Fixtures/sample.jpg` and `Fixtures/raw/iphone-xs.dng` (developed with defaults), each
    /// scaled to about 512 px on the long side, plus `synthetic`. Missing fixture files are skipped.
    public static func colors(fixturesDirectory: URL) -> [Float] {
        var packed = Set<UInt32>()
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        for name in ["sample.jpg", "raw/iphone-xs.dng"] {
            let url = fixturesDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path), let image = ImageSource.load(url: url) else { continue }
            insert(pixels(of: image, longSide: 512, context: context), into: &packed)
        }
        var out: [Float] = []
        out.reserveCapacity((packed.count + 3000) * 3)
        for v in packed.sorted() {
            out += [Float(v >> 16 & 255) / 255, Float(v >> 8 & 255) / 255, Float(v & 255) / 255]
        }
        return out + synthetic
    }

    /// A 64-step neutral ramp and a sweep of 36 hues x 8 saturations x 8 values in HSV (skies, skin, foliage and the
    /// saturated primaries).
    public static let synthetic: [Float] = {
        var out: [Float] = []
        for i in 0..<64 { let v = Float(i) / 63; out += [v, v, v] }
        for h in 0..<36 { for s in 1...8 { for v in 1...8 {
            let hue = Float(h) / 36 * 6, sat = Float(s) / 8, val = Float(v) / 8
            let f = hue - hue.rounded(.down), p = val * (1 - sat), q = val * (1 - sat * f), t = val * (1 - sat * (1 - f))
            switch Int(hue) % 6 {
            case 0: out += [val, t, p]
            case 1: out += [q, val, p]
            case 2: out += [p, val, t]
            case 3: out += [p, q, val]
            case 4: out += [t, p, val]
            default: out += [val, p, q]
            }
        } } }
        return out
    }()

    private static func pixels(of image: CIImage, longSide: CGFloat, context: CIContext) -> [UInt8] {
        let e = image.extent
        let scale = longSide / max(e.width, e.height)
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        let r = scaled.extent.integral
        let w = Int(r.width), h = Int(r.height)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        context.render(scaled, toBitmap: &buf, rowBytes: w * 4, bounds: r, format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return buf
    }

    private static func insert(_ rgba: [UInt8], into set: inout Set<UInt32>) {
        for i in stride(from: 0, to: rgba.count, by: 4) {
            set.insert(UInt32(rgba[i]) << 16 | UInt32(rgba[i + 1]) << 8 | UInt32(rgba[i + 2]))
        }
    }
}
