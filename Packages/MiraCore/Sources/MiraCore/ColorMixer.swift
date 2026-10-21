import Foundation

/// The eight hue ranges of the colour mixer.
public enum ColorRange: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    public var displayName: String { rawValue.capitalized }

    /// Hue of the range centre in OKLCh degrees. The mixer kernel uses the same numbers.
    public var centreHue: Double {
        switch self {
        case .red: 25
        case .orange: 55
        case .yellow: 100
        case .green: 145
        case .aqua: 195
        case .blue: 258
        case .purple: 300
        case .magenta: 340
        }
    }

    /// A display colour for the range, sRGB 0...1 (swatches in the UI).
    public var swatch: (r: Double, g: Double, b: Double) {
        switch self {
        case .red: (0.91, 0.24, 0.22)
        case .orange: (0.95, 0.52, 0.14)
        case .yellow: (0.95, 0.82, 0.18)
        case .green: (0.30, 0.74, 0.32)
        case .aqua: (0.18, 0.78, 0.78)
        case .blue: (0.22, 0.42, 0.92)
        case .purple: (0.55, 0.36, 0.88)
        case .magenta: (0.88, 0.30, 0.72)
        }
    }

    /// OKLCh hue (degrees, 0..<360) and chroma of an sRGB-encoded colour.
    public static func oklch(sRGB r: Double, _ g: Double, _ b: Double) -> (hue: Double, chroma: Double) {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let lr = lin(r), lg = lin(g), lb = lin(b)
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var h = atan2(bb, a) * 180 / .pi
        if h < 0 { h += 360 }
        return (h, (a * a + bb * bb).squareRoot())
    }

    /// The range whose centre is nearest to `hue` (OKLCh degrees), around the colour circle.
    public static func nearest(toHue hue: Double) -> ColorRange {
        allCases.min { circularDistance($0.centreHue, hue) < circularDistance($1.centreHue, hue) } ?? .red
    }

    /// The range for an sRGB-encoded colour, nil for greys (no hue to speak of).
    public static func nearest(sRGB r: Double, _ g: Double, _ b: Double) -> ColorRange? {
        let c = oklch(sRGB: r, g, b)
        return c.chroma < 0.02 ? nil : nearest(toHue: c.hue)
    }

    private static func circularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}

/// Hue, saturation and luminance moves for one range, each -1...1.
public struct ColorAdjust: Codable, Hashable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var luminance: Double

    public static let zero = ColorAdjust()

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    private enum CodingKeys: String, CodingKey { case hue, saturation, luminance }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        luminance = try c.decodeIfPresent(Double.self, forKey: .luminance) ?? 0
    }

    public var isZero: Bool { hue == 0 && saturation == 0 && luminance == 0 }
}

/// The colour mixer: eight ranges, each with hue, saturation and luminance. Default is no change.
public struct ColorMixerSettings: Codable, Hashable, Sendable {
    public var red = ColorAdjust.zero
    public var orange = ColorAdjust.zero
    public var yellow = ColorAdjust.zero
    public var green = ColorAdjust.zero
    public var aqua = ColorAdjust.zero
    public var blue = ColorAdjust.zero
    public var purple = ColorAdjust.zero
    public var magenta = ColorAdjust.zero

    public static let identity = ColorMixerSettings()

    public init() {}

    private enum CodingKeys: String, CodingKey { case red, orange, yellow, green, aqua, blue, purple, magenta }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        red = try c.decodeIfPresent(ColorAdjust.self, forKey: .red) ?? .zero
        orange = try c.decodeIfPresent(ColorAdjust.self, forKey: .orange) ?? .zero
        yellow = try c.decodeIfPresent(ColorAdjust.self, forKey: .yellow) ?? .zero
        green = try c.decodeIfPresent(ColorAdjust.self, forKey: .green) ?? .zero
        aqua = try c.decodeIfPresent(ColorAdjust.self, forKey: .aqua) ?? .zero
        blue = try c.decodeIfPresent(ColorAdjust.self, forKey: .blue) ?? .zero
        purple = try c.decodeIfPresent(ColorAdjust.self, forKey: .purple) ?? .zero
        magenta = try c.decodeIfPresent(ColorAdjust.self, forKey: .magenta) ?? .zero
    }

    public subscript(range: ColorRange) -> ColorAdjust {
        get {
            switch range {
            case .red: red
            case .orange: orange
            case .yellow: yellow
            case .green: green
            case .aqua: aqua
            case .blue: blue
            case .purple: purple
            case .magenta: magenta
            }
        }
        set {
            switch range {
            case .red: red = newValue
            case .orange: orange = newValue
            case .yellow: yellow = newValue
            case .green: green = newValue
            case .aqua: aqua = newValue
            case .blue: blue = newValue
            case .purple: purple = newValue
            case .magenta: magenta = newValue
            }
        }
    }

    public var isIdentity: Bool { ColorRange.allCases.allSatisfy { self[$0].isZero } }

    /// Ranges that have any move, in range order.
    public var changedRanges: [ColorRange] { ColorRange.allCases.filter { !self[$0].isZero } }
}
