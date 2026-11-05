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

/// `.mlut`: a lossless, compressed 3D cube of 16-bit RGB samples (the payload of a Hald CLUT PNG).
///
/// Layout, little endian: `"MLUT"`, UInt16 version, UInt16 dimension, UInt8 channels (3), UInt8 transform,
/// UInt8 codec, UInt8 reserved (0), UInt32 raw payload length; then the compressed payload.
/// The raw payload holds the `dimension^3 * 3` UInt16 samples (red fastest, then green, then blue) after the
/// reversible `Transform`. Decoding gives back exactly the samples `LUT.haldSamples` read from the PNG.
public enum PackedLUT {
    public static let fileExtension = "mlut"
    public static let version: UInt16 = 1
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

        /// What `mira-sheet --pack-films` writes (chosen by measurement: smallest with LZMA).
        public static let standard = Transform(predictor: .left, zigzag: false, split: false)
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
