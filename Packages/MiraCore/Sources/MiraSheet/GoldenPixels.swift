import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Interleaved RGB samples of a rendered picture (alpha dropped) and the numbers `mira-sheet --golden compare` reports.
///
/// 8-bit pictures hold 0...255 in each sample, 16-bit pictures 0...65535. Differences are always reported in
/// 8-bit levels per channel; one 8-bit level is 257 units of a 16-bit sample (65535 / 255).
struct GoldenPixels {
    var width: Int
    var height: Int
    var bits: Int
    var samples: [UInt16]

    /// Sample units in one 8-bit level.
    var unit: Double { bits == 16 ? 257 : 1 }

    // MARK: Making pixels

    /// Renders `image` straight into 16-bit (or 8-bit) samples through `context` in `space`.
    static func render(_ image: CIImage, context: CIContext, space: CGColorSpace, bits: Int) -> GoldenPixels? {
        let e = image.extent
        guard !e.isInfinite, !e.isEmpty else { return nil }
        let w = Int(e.width.rounded()), h = Int(e.height.rounded())
        var rgb = [UInt16](repeating: 0, count: w * h * 3)
        if bits == 16 {
            var buffer = [UInt16](repeating: 0, count: w * h * 4)
            context.render(image, toBitmap: &buffer, rowBytes: w * 8, bounds: e, format: .RGBA16, colorSpace: space)
            for i in 0..<(w * h) {
                rgb[i * 3] = buffer[i * 4]; rgb[i * 3 + 1] = buffer[i * 4 + 1]; rgb[i * 3 + 2] = buffer[i * 4 + 2]
            }
        } else {
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            context.render(image, toBitmap: &buffer, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: space)
            for i in 0..<(w * h) {
                rgb[i * 3] = UInt16(buffer[i * 4]); rgb[i * 3 + 1] = UInt16(buffer[i * 4 + 1]); rgb[i * 3 + 2] = UInt16(buffer[i * 4 + 2])
            }
        }
        return GoldenPixels(width: w, height: h, bits: bits, samples: rgb)
    }

    /// The samples of a decoded picture, drawn 1:1 into a context of the picture's own colour space (no conversion).
    init?(cgImage: CGImage, bits: Int) {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        let space = (cgImage.colorSpace?.model == .rgb ? cgImage.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var info = CGImageAlphaInfo.premultipliedLast.rawValue
        if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        let bytesPerComponent = bits / 8
        var raw = [UInt8](repeating: 0, count: w * h * 4 * bytesPerComponent)
        let drawn: Bool = raw.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: bits,
                                      bytesPerRow: w * 4 * bytesPerComponent, space: space, bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt16](repeating: 0, count: w * h * 3)
        if bits == 16 {
            raw.withUnsafeBytes { src in
                let s = src.bindMemory(to: UInt16.self)
                for i in 0..<(w * h) { rgb[i * 3] = s[i * 4]; rgb[i * 3 + 1] = s[i * 4 + 1]; rgb[i * 3 + 2] = s[i * 4 + 2] }
            }
        } else {
            for i in 0..<(w * h) { rgb[i * 3] = UInt16(raw[i * 4]); rgb[i * 3 + 1] = UInt16(raw[i * 4 + 1]); rgb[i * 3 + 2] = UInt16(raw[i * 4 + 2]) }
        }
        self.init(width: w, height: h, bits: bits, samples: rgb)
    }

    init(width: Int, height: Int, bits: Int, samples: [UInt16]) {
        self.width = width; self.height = height; self.bits = bits; self.samples = samples
    }

    // MARK: PNG

    /// Writes an RGB PNG (no alpha channel), 8 or 16 bits per sample, tagged with `space`.
    func writePNG(to url: URL, space: CGColorSpace) -> Bool {
        var bytes: [UInt8]
        var info = CGImageAlphaInfo.none.rawValue
        if bits == 16 {
            bytes = [UInt8](repeating: 0, count: samples.count * 2)
            for (i, s) in samples.enumerated() { bytes[i * 2] = UInt8(s >> 8); bytes[i * 2 + 1] = UInt8(s & 0xFF) }
            info |= CGBitmapInfo.byteOrder16Big.rawValue
        } else {
            bytes = samples.map { UInt8(truncatingIfNeeded: $0) }
        }
        let bytesPerPixel = 3 * bits / 8
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * 3,
                                  bytesPerRow: width * bytesPerPixel, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// The reference PNG at `url`, read back as `bits` per sample.
    static func readPNG(at url: URL, bits: Int) -> GoldenPixels? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return GoldenPixels(cgImage: cg, bits: bits)
    }
}

/// How far a render is from its reference, in 8-bit levels per channel (RGB samples only).
struct GoldenDiff {
    var mean = 0.0
    /// 99.9th percentile of the per-sample absolute difference.
    var p999 = 0.0
    var max = 0.0
    /// Pixels with any channel more than one level off.
    var over1 = 0
    var pixels = 0
    var sizeMismatch = false
    /// Per-sample absolute differences in sample units, for the diff image.
    var deltas: [UInt16] = []

    static func between(reference a: GoldenPixels, current b: GoldenPixels) -> GoldenDiff {
        var d = GoldenDiff()
        guard a.width == b.width, a.height == b.height, a.bits == b.bits else { d.sizeMismatch = true; return d }
        let n = a.samples.count
        d.pixels = a.width * a.height
        var histogram = [Int](repeating: 0, count: 65536)
        var total = 0.0
        var maxDelta = 0
        var over = 0
        let one = Int(a.unit)
        d.deltas = [UInt16](repeating: 0, count: n)
        a.samples.withUnsafeBufferPointer { pa in
            b.samples.withUnsafeBufferPointer { pb in
                for p in 0..<d.pixels {
                    var worst = 0
                    for c in 0..<3 {
                        let i = p * 3 + c
                        let delta = abs(Int(pa[i]) - Int(pb[i]))
                        histogram[delta] += 1
                        total += Double(delta)
                        if delta > worst { worst = delta }
                        d.deltas[i] = UInt16(delta)
                    }
                    if worst > maxDelta { maxDelta = worst }
                    if worst > one { over += 1 }
                }
            }
        }
        d.mean = total / Double(n) / a.unit
        d.max = Double(maxDelta) / a.unit
        d.over1 = over
        let target = Int((Double(n) * 0.999).rounded(.up))
        var cumulative = 0
        for (delta, count) in histogram.enumerated() {
            cumulative += count
            if cumulative >= target { d.p999 = Double(delta) / a.unit; break }
        }
        return d
    }

    /// An 8-bit RGB picture of the differences: 32 grey levels per level of difference, saturating at 255.
    func diffImage(width: Int, height: Int, unit: Double) -> GoldenPixels {
        let scaled = deltas.map { UInt16(Swift.min(255, Double($0) / unit * 32)) }
        return GoldenPixels(width: width, height: height, bits: 8, samples: scaled)
    }
}
