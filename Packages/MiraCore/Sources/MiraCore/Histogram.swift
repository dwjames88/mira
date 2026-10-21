import CoreVideo
import Foundation

/// A 256-bin histogram of an 8-bit image: red, green, blue and luminance, as fractions of the
/// pixels counted (each array sums to 1), plus how many pixels sit at the two ends.
public struct HistogramData: Sendable, Equatable {
    public static let binCount = 256

    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]
    public var luminance: [Float]
    /// Largest share of pixels at 0 in any colour channel.
    public var clippedLow: Float
    /// Largest share of pixels at 255 in any colour channel.
    public var clippedHigh: Float

    /// Share of clipped pixels above which the indicator lights up.
    public static let clipThreshold: Float = 0.005

    public var isClippingLow: Bool { clippedLow > Self.clipThreshold }
    public var isClippingHigh: Bool { clippedHigh > Self.clipThreshold }

    public static let empty = HistogramData(
        red: [Float](repeating: 0, count: 256), green: [Float](repeating: 0, count: 256),
        blue: [Float](repeating: 0, count: 256), luminance: [Float](repeating: 0, count: 256),
        clippedLow: 0, clippedHigh: 0)

    public func bins(_ channel: CurveChannel) -> [Float] {
        switch channel {
        case .red: red
        case .green: green
        case .blue: blue
        case .luminance: luminance
        case .rgb: luminance
        }
    }

    /// Bins from 32-bit BGRA pixels (the preview frame format), sampling at most about
    /// `maxSamples` pixels on a regular grid.
    public static func compute(
        bgra base: UnsafeRawPointer, width: Int, height: Int, rowBytes: Int, maxSamples: Int = 250_000
    ) -> HistogramData {
        guard width > 0, height > 0 else { return .empty }
        let stride = max(1, Int((Double(width * height) / Double(maxSamples)).squareRoot().rounded(.up)))
        var r = [UInt32](repeating: 0, count: 256), g = r, b = r, l = r
        var total: UInt32 = 0
        var y = 0
        while y < height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            var x = 0
            while x < width {
                let p = row + x * 4
                let bb = Int(p[0]), gg = Int(p[1]), rr = Int(p[2])
                r[rr] += 1; g[gg] += 1; b[bb] += 1
                let luma = (2126 * rr + 7152 * gg + 722 * bb + 5000) / 10000
                l[min(255, luma)] += 1
                total += 1
                x += stride
            }
            y += stride
        }
        guard total > 0 else { return .empty }
        let inv = 1 / Float(total)
        func norm(_ v: [UInt32]) -> [Float] { v.map { Float($0) * inv } }
        return HistogramData(
            red: norm(r), green: norm(g), blue: norm(b), luminance: norm(l),
            clippedLow: Float(max(r[0], g[0], b[0])) * inv,
            clippedHigh: Float(max(r[255], g[255], b[255])) * inv)
    }

    public static func compute(frame: PreviewFrame) -> HistogramData {
        let buffer = frame.pixelBuffer
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return .empty }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return compute(bgra: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                       rowBytes: CVPixelBufferGetBytesPerRow(buffer))
    }
}

extension PreviewFrame {
    /// The sRGB colour (0...1) at a point given as fractions of the frame, origin top left.
    public func color(atNormalized point: CGPoint) -> (r: Double, g: Double, b: Double)? {
        guard point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else { return nil }
        let buffer = pixelBuffer
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let x = min(w - 1, Int(point.x * Double(w))), y = min(h - 1, Int(point.y * Double(h)))
        // Average a 5x5 neighbourhood so grain does not decide the hue.
        var sum = (0.0, 0.0, 0.0), n = 0.0
        for yy in max(0, y - 2)...min(h - 1, y + 2) {
            let row = (base + yy * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
            for xx in max(0, x - 2)...min(w - 1, x + 2) {
                sum.0 += Double(row[xx * 4 + 2]); sum.1 += Double(row[xx * 4 + 1]); sum.2 += Double(row[xx * 4])
                n += 1
            }
        }
        return (sum.0 / n / 255, sum.1 / n / 255, sum.2 / n / 255)
    }
}
