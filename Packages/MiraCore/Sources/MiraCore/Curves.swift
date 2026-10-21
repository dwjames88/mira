import Foundation

/// One control point of a tone curve, both axes normalised 0...1 (x = input, y = output).
public struct CurvePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The five editable curves.
public enum CurveChannel: String, CaseIterable, Codable, Sendable {
    case rgb, red, green, blue, luminance
}

/// Tone curves: a master RGB curve, one per colour channel and a luminance curve. Each is a list
/// of control points; the default is the identity (two endpoints on the diagonal).
public struct CurvesSettings: Codable, Hashable, Sendable {
    public static let identityPoints = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    public static let identity = CurvesSettings()

    public var rgb: [CurvePoint]
    public var red: [CurvePoint]
    public var green: [CurvePoint]
    public var blue: [CurvePoint]
    public var luminance: [CurvePoint]

    public init(
        rgb: [CurvePoint] = CurvesSettings.identityPoints,
        red: [CurvePoint] = CurvesSettings.identityPoints,
        green: [CurvePoint] = CurvesSettings.identityPoints,
        blue: [CurvePoint] = CurvesSettings.identityPoints,
        luminance: [CurvePoint] = CurvesSettings.identityPoints
    ) {
        self.rgb = rgb
        self.red = red
        self.green = green
        self.blue = blue
        self.luminance = luminance
    }

    private enum CodingKeys: String, CodingKey { case rgb, red, green, blue, luminance }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rgb = try c.decodeIfPresent([CurvePoint].self, forKey: .rgb) ?? Self.identityPoints
        red = try c.decodeIfPresent([CurvePoint].self, forKey: .red) ?? Self.identityPoints
        green = try c.decodeIfPresent([CurvePoint].self, forKey: .green) ?? Self.identityPoints
        blue = try c.decodeIfPresent([CurvePoint].self, forKey: .blue) ?? Self.identityPoints
        luminance = try c.decodeIfPresent([CurvePoint].self, forKey: .luminance) ?? Self.identityPoints
    }

    public subscript(channel: CurveChannel) -> [CurvePoint] {
        get {
            switch channel {
            case .rgb: rgb
            case .red: red
            case .green: green
            case .blue: blue
            case .luminance: luminance
            }
        }
        set {
            switch channel {
            case .rgb: rgb = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            case .luminance: luminance = newValue
            }
        }
    }

    /// True when no curve changes anything.
    public var isIdentity: Bool { CurveChannel.allCases.allSatisfy { Self.isIdentity(self[$0]) } }

    public func isIdentity(_ channel: CurveChannel) -> Bool { Self.isIdentity(self[channel]) }

    /// Every point on the diagonal (or no points at all).
    public static func isIdentity(_ points: [CurvePoint]) -> Bool {
        points.allSatisfy { abs($0.x - $0.y) < 1e-9 }
    }

    /// Number of entries in a curve LUT.
    public static let lutSize = 1024

    /// The LUT for one curve alone.
    public func lut(_ channel: CurveChannel, size: Int = CurvesSettings.lutSize) -> [Float] {
        let curve = MonotoneCurve(self[channel])
        return (0..<size).map { Float(curve.value(at: Double($0) / Double(size - 1))) }
    }

    /// The table the curves kernel samples: `lutSize` x 2 RGBA float pixels. In the image (origin
    /// bottom left) row 0 holds the colour curves with the master curve folded in (red, green,
    /// blue in R, G, B) and row 1 the luminance curve in all three channels; bitmap memory starts
    /// at the top row, so the luminance row comes first in the array. Alpha is 1.
    public func kernelTable(size: Int = CurvesSettings.lutSize) -> [Float] {
        let master = MonotoneCurve(rgb), r = MonotoneCurve(red), g = MonotoneCurve(green)
        let b = MonotoneCurve(blue), l = MonotoneCurve(luminance)
        var table = [Float](repeating: 1, count: size * 2 * 4)
        for i in 0..<size {
            let x = Double(i) / Double(size - 1)
            let m = master.value(at: x)
            let c = (size + i) * 4
            table[c + 0] = Float(r.value(at: m))
            table[c + 1] = Float(g.value(at: m))
            table[c + 2] = Float(b.value(at: m))
            let y = Float(l.value(at: x))
            let o = i * 4
            table[o + 0] = y
            table[o + 1] = y
            table[o + 2] = y
        }
        return table
    }

    /// Applies the colour curves (master, then the channel's own) to one sRGB-encoded value.
    public func apply(toEncoded value: Double, channel: CurveChannel) -> Double {
        let m = MonotoneCurve(rgb).value(at: value)
        return MonotoneCurve(self[channel]).value(at: m)
    }
}

/// A monotone cubic Hermite curve through control points (Fritsch-Carlson tangents). It never
/// overshoots the points it joins, so the curve cannot ring between neighbouring points.
/// Outside the first and last point the curve is flat.
public struct MonotoneCurve: Sendable {
    private let xs: [Double]
    private let ys: [Double]
    private let ms: [Double]

    /// Points are clamped to 0...1, sorted by x; points with the same x keep the later one.
    public init(_ points: [CurvePoint]) {
        var sorted = points.map { CurvePoint(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1)) }
        sorted.sort { $0.x < $1.x }
        var unique: [CurvePoint] = []
        for p in sorted {
            if let last = unique.last, abs(last.x - p.x) < 1e-9 { unique[unique.count - 1] = p } else { unique.append(p) }
        }
        xs = unique.map(\.x)
        ys = unique.map(\.y)
        let n = unique.count
        var m = [Double](repeating: 0, count: n)
        if n >= 2 {
            var delta = [Double](repeating: 0, count: n - 1)
            for k in 0..<(n - 1) { delta[k] = (ys[k + 1] - ys[k]) / (xs[k + 1] - xs[k]) }
            m[0] = delta[0]
            m[n - 1] = delta[n - 2]
            if n > 2 {
                for k in 1..<(n - 1) {
                    m[k] = delta[k - 1] * delta[k] <= 0 ? 0 : (delta[k - 1] + delta[k]) / 2
                }
            }
            for k in 0..<(n - 1) {
                if delta[k] == 0 {
                    m[k] = 0
                    m[k + 1] = 0
                    continue
                }
                let a = m[k] / delta[k], b = m[k + 1] / delta[k]
                let s = a * a + b * b
                if s > 9 {
                    let tau = 3 / s.squareRoot()
                    m[k] = tau * a * delta[k]
                    m[k + 1] = tau * b * delta[k]
                }
            }
        }
        ms = m
    }

    /// The curve at `x` (0...1), in 0...1. With no points, the identity.
    public func value(at x: Double) -> Double {
        let n = xs.count
        if n == 0 { return x }
        if n == 1 || x <= xs[0] { return ys[0] }
        if x >= xs[n - 1] { return ys[n - 1] }
        var lo = 0, hi = n - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if xs[mid] <= x { lo = mid } else { hi = mid }
        }
        let h = xs[hi] - xs[lo]
        let t = (x - xs[lo]) / h
        let t2 = t * t, t3 = t2 * t
        let v = (2 * t3 - 3 * t2 + 1) * ys[lo] + (t3 - 2 * t2 + t) * h * ms[lo]
            + (-2 * t3 + 3 * t2) * ys[hi] + (t3 - t2) * h * ms[hi]
        return min(max(v, 0), 1)
    }
}
