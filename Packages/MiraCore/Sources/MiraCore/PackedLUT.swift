import Compression
import Foundation

public enum PackedLUTError: Error, Equatable, CustomStringConvertible {
    case notPacked
    case unsupported(String)
    case corrupt(String)

    public var description: String {
        switch self {
        case .notPacked: "Not a packed LUT (bad magic)"
        case .unsupported(let m): "Unsupported packed LUT: \(m)"
        case .corrupt(let m): "Corrupt packed LUT: \(m)"
        }
    }
}

/// `.mlut`: a compressed 3D cube of 16-bit RGB samples. The container is lossless; the app ships each film's
/// 64^3 Hald cube at the smallest of `candidateDimensions` whose error stays within `Limits` (`choose`).
///
/// Layout, little endian: `"MLUT"`, UInt16 version, UInt16 dimension, UInt8 channels (3), UInt8 transform,
/// UInt8 codec, UInt8 reserved (0), UInt32 raw payload length; then the compressed payload.
/// The raw payload holds the `dimension^3 * 3` UInt16 samples (red fastest, then green, then blue) after the
/// reversible `Transform`. Decoding gives back exactly the samples that were packed.
public enum PackedLUT {
    public static let fileExtension = "mlut"
    public static let version: UInt16 = 1
    /// Cube dimensions the packer tries, smallest first. 64 is the source resolution and is stored exactly.
    public static let candidateDimensions = [48, 56, 64]

    /// Error of a smaller cube against the 64^3 original, evaluated trilinearly at the 64^3 lattice points.
    public struct Fidelity: Sendable {
        /// Largest absolute difference of any channel, 0...1.
        public var max: Float
        /// Largest per-channel 99.9th percentile of the absolute difference, 0...1.
        public var p999: Float
        public func within(maxError: Float, p999Error: Float) -> Bool { max <= maxError && p999 <= p999Error }
    }

    /// Limits for accepting a smaller cube, measured on `PackProbe` colours (real image pixels and a synthetic
    /// sweep): max 4/255 and 99.9th percentile 1.5/255, per channel.
    public static let acceptedMaxError: Float = 4.0 / 255
    public static let acceptedP999Error: Float = 1.5 / 255

    /// Trilinear evaluation of `lut` at each colour (encoded sRGB triples in 0...1); returns triples.
    public static func evaluate(_ lut: LUT, colors: [Float]) -> [Float] {
        let n = lut.dimension
        let cube = lut.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var out = [Float](repeating: 0, count: colors.count)
        let scale = Float(n - 1)
        cube.withUnsafeBufferPointer { c in
            for k in 0..<(colors.count / 3) {
                var base = [0, 0, 0], frac: [Float] = [0, 0, 0]
                for ch in 0..<3 {
                    let x = Swift.min(Swift.max(colors[k * 3 + ch], 0), 1) * scale
                    let i = Swift.min(Int(x), n - 2)
                    base[ch] = i; frac[ch] = x - Float(i)
                }
                var acc: (Float, Float, Float) = (0, 0, 0)
                for db in 0...1 { for dg in 0...1 { for dr in 0...1 {
                    let w = (dr == 1 ? frac[0] : 1 - frac[0]) * (dg == 1 ? frac[1] : 1 - frac[1]) * (db == 1 ? frac[2] : 1 - frac[2])
                    let o = (((base[2] + db) * n + base[1] + dg) * n + base[0] + dr) * 4
                    acc.0 += c[o] * w; acc.1 += c[o + 1] * w; acc.2 += c[o + 2] * w
                } } }
                out[k * 3] = acc.0; out[k * 3 + 1] = acc.1; out[k * 3 + 2] = acc.2
            }
        }
        return out
    }

    /// Error of `candidate` against `original` on the probe colours (a precomputed `evaluate(original, ...)` may be
    /// passed as `reference`).
    public static func probeError(reference: [Float], candidate: LUT, colors: [Float]) -> Fidelity {
        let got = evaluate(candidate, colors: colors)
        let count = colors.count / 3
        var worst: Float = 0, p999: Float = 0
        var errs = [Float](repeating: 0, count: count)
        for c in 0..<3 {
            for i in 0..<count { errs[i] = abs(reference[i * 3 + c] - got[i * 3 + c]) }
            errs.sort()
            worst = Swift.max(worst, errs[count - 1])
            p999 = Swift.max(p999, errs[Int(Double(count) * 0.999)])
        }
        return Fidelity(max: worst, p999: p999)
    }

    /// The 64^3 RGBA Float cube a Hald image yields in the app (`LUT.loadHald`), from its raw samples.
    public static func original(_ rgb: [UInt16], dimension n: Int) -> LUT {
        let lut = LUT(dimension: n, rgb16: rgb)
        return n > LUT.maxHaldDimension ? lut.resampled(to: LUT.maxHaldDimension) : lut
    }

    /// How far `candidate` (any dimension) is from `original` when sampled at `original`'s lattice points.
    public static func fidelity(original: LUT, candidate: LUT) -> Fidelity {
        let up = candidate.dimension == original.dimension ? candidate : candidate.resampled(to: original.dimension)
        let a = original.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let b = up.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let texels = a.count / 4
        var worst: Float = 0, p999: Float = 0
        var errs = [Float](repeating: 0, count: texels)
        for c in 0..<3 {
            for i in 0..<texels { errs[i] = abs(a[i * 4 + c] - b[i * 4 + c]) }
            errs.sort()
            worst = Swift.max(worst, errs[texels - 1])
            p999 = Swift.max(p999, errs[Int(Double(texels) * 0.999)])
        }
        return Fidelity(max: worst, p999: p999)
    }

    /// The samples to store for a Hald image: the first of `candidateDimensions` whose probe error (see `PackProbe`)
    /// meets the limits, else the 64^3 cube itself. Returns the dimension, the samples, the probe error of the choice
    /// and its lattice error (for information).
    public static func choose(
        _ rgb: [UInt16], dimension n: Int, probe: [Float],
        maxError: Float = acceptedMaxError, p999Error: Float = acceptedP999Error
    ) -> (dimension: Int, rgb: [UInt16], probe: Fidelity, lattice: Fidelity) {
        let orig = original(rgb, dimension: n)
        let reference = evaluate(orig, colors: probe)
        for m in candidateDimensions where m < orig.dimension {
            let samples = resampled(rgb, from: n, to: m)
            let cube = LUT(dimension: m, rgb16: samples)
            let f = probeError(reference: reference, candidate: cube, colors: probe)
            if f.within(maxError: maxError, p999Error: p999Error) {
                return (m, samples, f, fidelity(original: orig, candidate: cube))
            }
        }
        let m = orig.dimension
        let exact = Fidelity(max: 0, p999: 0)
        return (m, n == m ? rgb : resampled(rgb, from: n, to: m), exact, exact)
    }

    /// Trilinear resample of interleaved 16-bit RGB samples from `n`^3 (via 64^3 when larger) to `m`^3 at lattice points (in Float),
    /// rounded to the nearest UInt16. This is what `mira-sheet --pack-films` stores.
    public static func resampled(_ rgb: [UInt16], from n: Int, to m: Int) -> [UInt16] {
        // Hald images larger than 64^3 go through 64^3 first, exactly like `LUT.loadHald` (all in Float).
        var lut = LUT(dimension: n, rgb16: rgb)
        if n > LUT.maxHaldDimension { lut = lut.resampled(to: LUT.maxHaldDimension) }
        let f = lut.resampled(to: m).data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var out = [UInt16](repeating: 0, count: m * m * m * 3)
        for i in 0..<(m * m * m) {
            for c in 0..<3 { out[i * 3 + c] = UInt16((min(max(f[i * 4 + c], 0), 1) * 65535).rounded()) }
        }
        return out
    }
    static let magic: [UInt8] = Array("MLUT".utf8)
    static let headerSize = 16

    /// Sample transform applied before compression: a predictor per colour channel (residual = sample - prediction,
    /// UInt16 wrapping), optional zigzag mapping of residuals to small unsigned values, and optional splitting
    /// into per-channel, per-byte planes. Neighbours outside the cube predict as 0.
    public struct Transform: Equatable, Sendable {
        public enum Predictor: UInt8, Sendable, CaseIterable {
            case none = 0
            /// Previous texel along the red axis.
            case left = 1
            /// left + up - upLeft, with up the previous texel along green.
            case gradient = 2
            /// Trilinear-exact 3D predictor over the red, green and blue neighbours.
            case trilinear = 3
        }
        public var predictor: Predictor
        public var zigzag: Bool
        public var split: Bool

        public init(predictor: Predictor, zigzag: Bool, split: Bool) {
            self.predictor = predictor; self.zigzag = zigzag; self.split = split
        }

        var rawValue: UInt8 { predictor.rawValue | (zigzag ? 4 : 0) | (split ? 8 : 0) }
        init?(rawValue: UInt8) {
            guard rawValue < 16, let p = Predictor(rawValue: rawValue & 3) else { return nil }
            self.init(predictor: p, zigzag: rawValue & 4 != 0, split: rawValue & 8 != 0)
        }

        /// What `mira-sheet --pack-films` writes (chosen by measurement).
        public static let standard = Transform(predictor: .left, zigzag: false, split: true)
    }

    public enum Codec: UInt8, Sendable, CaseIterable {
        case lzfse = 1
        case lzma = 2
        case zlib = 3

        var algorithm: compression_algorithm {
            switch self {
            case .lzfse: COMPRESSION_LZFSE
            case .lzma: COMPRESSION_LZMA
            case .zlib: COMPRESSION_ZLIB
            }
        }
    }

    /// What `mira-sheet --pack-films` writes.
    public static let standardCodec = Codec.lzma

    // MARK: Encode

    public static func pack(
        dimension n: Int, rgb: [UInt16], transform: Transform = .standard, codec: Codec = standardCodec
    ) throws -> Data {
        let texels = n * n * n
        guard n >= 2, n <= 256, rgb.count == texels * 3 else {
            throw PackedLUTError.corrupt("dimension \(n) does not match \(rgb.count) samples")
        }
        let raw = forward(rgb, n: n, transform: transform)
        let compressed = try raw.withUnsafeBufferPointer { src -> [UInt8] in
            var dst = [UInt8](repeating: 0, count: src.count + 4096)
            let size = compression_encode_buffer(&dst, dst.count, src.baseAddress!, src.count, nil, codec.algorithm)
            guard size > 0 else { throw PackedLUTError.corrupt("compression failed") }
            return Array(dst[0..<size])
        }
        var out = Data(capacity: headerSize + compressed.count)
        out.append(contentsOf: magic)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        put(version); put(UInt16(n)); put(UInt8(3)); put(transform.rawValue); put(codec.rawValue); put(UInt8(0))
        put(UInt32(raw.count))
        out.append(contentsOf: compressed)
        return out
    }

    // MARK: Decode

    public static func unpackSamples(_ data: Data) throws -> (dimension: Int, rgb: [UInt16]) {
        guard data.count >= headerSize else { throw PackedLUTError.corrupt("truncated header") }
        let b = [UInt8](data.prefix(headerSize))
        guard Array(b[0..<4]) == magic else { throw PackedLUTError.notPacked }
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        guard u16(4) == Int(version) else { throw PackedLUTError.unsupported("version \(u16(4))") }
        let n = u16(6)
        guard n >= 2, n <= 256 else { throw PackedLUTError.corrupt("dimension \(n)") }
        guard b[8] == 3 else { throw PackedLUTError.unsupported("\(b[8]) channels") }
        guard let transform = Transform(rawValue: b[9]) else { throw PackedLUTError.unsupported("transform \(b[9])") }
        guard let codec = Codec(rawValue: b[10]) else { throw PackedLUTError.unsupported("codec \(b[10])") }
        guard b[11] == 0 else { throw PackedLUTError.unsupported("reserved byte") }
        let rawLength = Int(b[12]) | Int(b[13]) << 8 | Int(b[14]) << 16 | Int(b[15]) << 24
        let texels = n * n * n
        guard rawLength == texels * 6 else { throw PackedLUTError.corrupt("payload length \(rawLength)") }

        var raw = [UInt8](repeating: 0, count: rawLength)
        let produced = data.withUnsafeBytes { buf -> Int in
            let src = buf.bindMemory(to: UInt8.self)
            return compression_decode_buffer(&raw, rawLength, src.baseAddress! + headerSize, src.count - headerSize, nil, codec.algorithm)
        }
        guard produced == rawLength else { throw PackedLUTError.corrupt("payload decompresses to \(produced) bytes") }
        return (n, inverse(raw, n: n, transform: transform))
    }

    public static func unpack(_ data: Data) throws -> LUT {
        let (n, rgb) = try unpackSamples(data)
        return LUT(dimension: n, rgb16: rgb)
    }

    // MARK: Transform

    @inline(__always) private static func predict(
        _ p: UnsafePointer<UInt16>, _ i: Int, _ r: Int, _ g: Int, _ b: Int, _ n: Int, _ kind: Transform.Predictor
    ) -> UInt16 {
        if kind == .none { return 0 }
        let dg = n, db = n * n
        let l = r > 0 ? Int32(p[i - 1]) : 0
        if kind == .left { return UInt16(truncatingIfNeeded: l) }
        let u = g > 0 ? Int32(p[i - dg]) : 0
        let ul = (r > 0 && g > 0) ? Int32(p[i - dg - 1]) : 0
        if kind == .gradient { return UInt16(truncatingIfNeeded: l + u - ul) }
        let k = b > 0 ? Int32(p[i - db]) : 0
        let kl = (b > 0 && r > 0) ? Int32(p[i - db - 1]) : 0
        let ku = (b > 0 && g > 0) ? Int32(p[i - db - dg]) : 0
        let kul = (b > 0 && g > 0 && r > 0) ? Int32(p[i - db - dg - 1]) : 0
        return UInt16(truncatingIfNeeded: l + u + k - ul - kl - ku + kul)
    }

    @inline(__always) private static func zig(_ v: UInt16) -> UInt16 {
        let s = Int16(bitPattern: v)
        return UInt16(bitPattern: (s << 1) ^ (s >> 15))
    }
    @inline(__always) private static func unzig(_ z: UInt16) -> UInt16 {
        (z >> 1) ^ (0 &- (z & 1))
    }

    static func forward(_ rgb: [UInt16], n: Int, transform t: Transform) -> [UInt8] {
        let texels = n * n * n
        var out = [UInt8](repeating: 0, count: texels * 6)
        var plane = [UInt16](repeating: 0, count: texels)
        var res = [UInt16](repeating: 0, count: texels)
        for c in 0..<3 {
            for i in 0..<texels { plane[i] = rgb[i * 3 + c] }
            plane.withUnsafeBufferPointer { p in
                var i = 0
                for b in 0..<n { for g in 0..<n { for r in 0..<n {
                    var d = p[i] &- predict(p.baseAddress!, i, r, g, b, n, t.predictor)
                    if t.zigzag { d = zig(d) }
                    res[i] = d
                    i += 1
                } } }
            }
            for i in 0..<texels {
                if t.split {
                    out[c * texels * 2 + i] = UInt8(truncatingIfNeeded: res[i])
                    out[c * texels * 2 + texels + i] = UInt8(truncatingIfNeeded: res[i] >> 8)
                } else {
                    // Interleaved RGB, little endian.
                    out[(i * 3 + c) * 2] = UInt8(truncatingIfNeeded: res[i])
                    out[(i * 3 + c) * 2 + 1] = UInt8(truncatingIfNeeded: res[i] >> 8)
                }
            }
        }
        return out
    }

    static func inverse(_ raw: [UInt8], n: Int, transform t: Transform) -> [UInt16] {
        let texels = n * n * n
        var rgb = [UInt16](repeating: 0, count: texels * 3)
        var plane = [UInt16](repeating: 0, count: texels)
        for c in 0..<3 {
            plane.withUnsafeMutableBufferPointer { p in
                var i = 0
                for b in 0..<n { for g in 0..<n { for r in 0..<n {
                    var d: UInt16
                    if t.split {
                        d = UInt16(raw[c * texels * 2 + i]) | UInt16(raw[c * texels * 2 + texels + i]) << 8
                    } else {
                        d = UInt16(raw[(i * 3 + c) * 2]) | UInt16(raw[(i * 3 + c) * 2 + 1]) << 8
                    }
                    if t.zigzag { d = unzig(d) }
                    p[i] = d &+ predict(UnsafePointer(p.baseAddress!), i, r, g, b, n, t.predictor)
                    i += 1
                } } }
            }
            for i in 0..<texels { rgb[i * 3 + c] = plane[i] }
        }
        return rgb
    }
}
