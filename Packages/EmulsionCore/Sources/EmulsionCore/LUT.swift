import CoreGraphics
import Foundation
import ImageIO

public enum LUTError: Error, Equatable, CustomStringConvertible {
    case invalidCube(String)
    case oneDimensionalNotSupported
    case invalidHald(String)
    case imageDecodeFailed(String)

    public var description: String {
        switch self {
        case .invalidCube(let m): "Invalid .cube file: \(m)"
        case .oneDimensionalNotSupported: "Only 3D .cube LUTs are supported (found a 1D-only LUT)"
        case .invalidHald(let m): "Invalid HaldCLUT: \(m)"
        case .imageDecodeFailed(let m): "Could not decode image: \(m)"
        }
    }
}

/// A 3D colour lookup table. `data` is `dimension^3` RGBA Float32 texels, red varying
/// fastest, then green, then blue — the layout `CIColorCubeWithColorSpace` expects.
/// Values are sRGB-encoded (display-referred), see `Renderer` for how this is applied.
public struct LUT: Sendable {
    public let dimension: Int
    public let data: Data

    public init(dimension: Int, data: Data) {
        self.dimension = dimension
        self.data = data
    }

    /// Largest cube dimension we keep in memory for Hald-derived LUTs.
    public static let maxHaldDimension = 64

    // MARK: .cube

    public static func parseCube(_ text: String) throws -> LUT {
        var size3D: Int?
        var has1D = false
        var dmin: [Float] = [0, 0, 0]
        var dmax: [Float] = [1, 1, 1]
        var values: [Float] = []

        func triple(_ parts: [Substring], _ keyword: String) throws -> [Float] {
            guard parts.count == 4, let a = Float(parts[1]), let b = Float(parts[2]), let c = Float(parts[3]) else {
                throw LUTError.invalidCube("malformed \(keyword) line")
            }
            return [a, b, c]
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = parts.first else { continue }

            switch first.uppercased() {
            case "TITLE":
                continue
            case "LUT_3D_SIZE":
                guard parts.count == 2, let n = Int(parts[1]), n >= 2, n <= 256 else {
                    throw LUTError.invalidCube("bad LUT_3D_SIZE")
                }
                size3D = n
                values.reserveCapacity(n * n * n * 3)
            case "LUT_1D_SIZE":
                has1D = true
            case "DOMAIN_MIN":
                dmin = try triple(parts, "DOMAIN_MIN")
            case "DOMAIN_MAX":
                dmax = try triple(parts, "DOMAIN_MAX")
            case "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE":
                continue
            default:
                guard parts.count == 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else {
                    throw LUTError.invalidCube("unrecognised line: \(line.prefix(40))")
                }
                values.append(contentsOf: [r, g, b])
            }
        }

        guard let n = size3D else {
            if has1D { throw LUTError.oneDimensionalNotSupported }
            throw LUTError.invalidCube("missing LUT_3D_SIZE")
        }
        let expected = n * n * n * 3
        guard values.count == expected else {
            throw LUTError.invalidCube("expected \(n * n * n) entries for size \(n), found \(values.count / 3)")
        }
        let range = (0..<3).map { max(dmax[$0] - dmin[$0], 1e-9) }

        var out = [Float](repeating: 1, count: n * n * n * 4)
        for i in 0..<(n * n * n) {
            for c in 0..<3 {
                out[i * 4 + c] = min(max((values[i * 3 + c] - dmin[c]) / range[c], 0), 1)
            }
        }
        return LUT(dimension: n, data: out.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    // MARK: HaldCLUT

    public static func loadHald(url: URL) throws -> LUT {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw LUTError.imageDecodeFailed(url.lastPathComponent) }
        return try loadHald(cgImage: image)
    }

    /// Image side must be `L^3` (level L); the cube has dimension `L^2`. Pixels are read in
    /// the image's own colour space with no conversion, so the values stay sRGB-encoded.
    /// Cubes larger than 64 are trilinearly resampled down to 64.
    public static func loadHald(cgImage: CGImage) throws -> LUT {
        let side = cgImage.width
        guard cgImage.height == side else { throw LUTError.invalidHald("image is not square") }
        var level = 0
        for l in 2...32 where l * l * l == side { level = l }
        guard level >= 2 else { throw LUTError.invalidHald("side \(side) is not a perfect cube (L^3)") }
        let n = level * level

        var space = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if space.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB)! }

        let bytesPerRow = side * 8
        var pixels = [UInt16](repeating: 0, count: side * side * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: side, height: side, bitsPerComponent: 16,
                bytesPerRow: bytesPerRow, space: space, bitmapInfo: bitmapInfo
            ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { throw LUTError.imageDecodeFailed("could not create bitmap context") }

        var out = [Float](repeating: 1, count: n * n * n * 4)
        let scale: Float = 1.0 / 65535.0
        // Texel i (r fastest, then g, then b) is pixel i in row-major order.
        for i in 0..<(n * n * n) {
            out[i * 4 + 0] = Float(pixels[i * 4 + 0]) * scale
            out[i * 4 + 1] = Float(pixels[i * 4 + 1]) * scale
            out[i * 4 + 2] = Float(pixels[i * 4 + 2]) * scale
        }
        let lut = LUT(dimension: n, data: out.withUnsafeBufferPointer { Data(buffer: $0) })
        return n > maxHaldDimension ? lut.resampled(to: maxHaldDimension) : lut
    }

    // MARK: Resampling

    /// Trilinear resample to a cube of `dimension`^3.
    public func resampled(to newDimension: Int) -> LUT {
        let m = max(newDimension, 2)
        if m == dimension { return self }
        let n = dimension
        let src: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var out = [Float](repeating: 1, count: m * m * m * 4)
        let ratio = Float(n - 1) / Float(m - 1)

        @inline(__always) func at(_ r: Int, _ g: Int, _ b: Int, _ c: Int) -> Float {
            src[((b * n + g) * n + r) * 4 + c]
        }

        for bi in 0..<m {
            let fb = Float(bi) * ratio, b0 = min(Int(fb), n - 2), tb = fb - Float(b0)
            for gi in 0..<m {
                let fg = Float(gi) * ratio, g0 = min(Int(fg), n - 2), tg = fg - Float(g0)
                for ri in 0..<m {
                    let fr = Float(ri) * ratio, r0 = min(Int(fr), n - 2), tr = fr - Float(r0)
                    let o = ((bi * m + gi) * m + ri) * 4
                    for c in 0..<3 {
                        let c00 = at(r0, g0, b0, c) * (1 - tr) + at(r0 + 1, g0, b0, c) * tr
                        let c10 = at(r0, g0 + 1, b0, c) * (1 - tr) + at(r0 + 1, g0 + 1, b0, c) * tr
                        let c01 = at(r0, g0, b0 + 1, c) * (1 - tr) + at(r0 + 1, g0, b0 + 1, c) * tr
                        let c11 = at(r0, g0 + 1, b0 + 1, c) * (1 - tr) + at(r0 + 1, g0 + 1, b0 + 1, c) * tr
                        let c0 = c00 * (1 - tg) + c10 * tg
                        let c1 = c01 * (1 - tg) + c11 * tg
                        out[o + c] = c0 * (1 - tb) + c1 * tb
                    }
                }
            }
        }
        return LUT(dimension: m, data: out.withUnsafeBufferPointer { Data(buffer: $0) })
    }

}
