import CoreGraphics
import Foundation

/// What a dodge and burn stroke does.
public enum DodgeBurnMode: String, Codable, CaseIterable, Sendable {
    /// Lightens.
    case dodge
    /// Darkens.
    case burn
    /// Removes the effect of the strokes painted before it (under the brush).
    case erase

    /// The other of dodge and burn (erase stays erase). The ⌥ key flips with it.
    public var flipped: DodgeBurnMode {
        switch self {
        case .dodge: .burn
        case .burn: .dodge
        case .erase: .erase
        }
    }
}

/// The tones a stroke acts on, like Photoshop's Range menu.
public enum DodgeBurnRange: String, Codable, CaseIterable, Sendable {
    case shadows, midtones, highlights
}

/// One recorded brush position. `x` and `y` are normalised to the uncropped, upright source
/// (0...1, origin top left); `pressure` is 0...1 (1 for a mouse).
public struct StrokePoint: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var pressure: Double

    public init(x: Double, y: Double, pressure: Double = 1) {
        self.x = x; self.y = y; self.pressure = pressure
    }
}

/// Limits a stroke to a band of tones of the picture (a luminosity mask). Values are
/// sRGB-encoded luminance, 0...1; `softness` widens both edges outward.
public struct LumaRange: Codable, Hashable, Sendable {
    public var low: Double
    public var high: Double
    public var softness: Double

    public static let full = LumaRange(low: 0, high: 1, softness: 0.1)

    public init(low: Double = 0, high: Double = 1, softness: Double = 0.1) {
        self.low = low; self.high = high; self.softness = softness
    }

    /// True when it limits nothing.
    public var isFull: Bool { low <= 0.0005 && high >= 0.9995 }

    public var clamped: LumaRange {
        let lo = min(max(low.isFinite ? low : 0, 0), 1)
        let hi = min(max(high.isFinite ? high : 1, lo), 1)
        return LumaRange(low: lo, high: hi, softness: min(max(softness.isFinite ? softness : 0.1, 0), 0.5))
    }

    private enum CodingKeys: String, CodingKey { case low, high, softness }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = LumaRange(low: try c.decodeIfPresent(Double.self, forKey: .low) ?? 0,
                         high: try c.decodeIfPresent(Double.self, forKey: .high) ?? 1,
                         softness: try c.decodeIfPresent(Double.self, forKey: .softness) ?? 0.1).clamped
    }
}

/// One brush stroke: its path and every setting it was painted with. Each stroke keeps its own
/// settings so any of them can be edited, hidden or deleted later.
///
/// **Space.** Points are normalised to the *uncropped, upright source* and `size` is a fraction of
/// that source's short side, so a stroke stays on the same part of the picture when the crop,
/// rotation, flip or straighten changes. The renderer maps them through `CropGeometry`.
public struct DodgeBurnStroke: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var mode: DodgeBurnMode
    public var points: [StrokePoint]
    /// Brush diameter as a fraction of the source's short side.
    public var size: Double
    /// 0 is a hard edge, 1 falls off from the centre.
    public var feather: Double
    /// How much each dab adds (builds up while painting over the same spot).
    public var flow: Double
    /// The strongest this stroke gets (its opacity), 0...1.
    public var strength: Double
    public var range: DodgeBurnRange
    /// Soft-limits the change so dodge never clips highlights and burn never crushes shadows to black.
    public var protectTones: Bool
    /// Optional luminosity mask: the stroke only acts on pixels in this band of tones.
    public var lumaRange: LumaRange?
    public var hidden: Bool

    public static let sizeRange: ClosedRange<Double> = 0.004...0.5

    public init(
        id: UUID = UUID(), mode: DodgeBurnMode = .dodge, points: [StrokePoint] = [], size: Double = 0.08,
        feather: Double = 0.6, flow: Double = 0.5, strength: Double = 0.5, range: DodgeBurnRange = .midtones,
        protectTones: Bool = true, lumaRange: LumaRange? = nil, hidden: Bool = false
    ) {
        self.id = id; self.mode = mode; self.points = points; self.size = size; self.feather = feather
        self.flow = flow; self.strength = strength; self.range = range; self.protectTones = protectTones
        self.lumaRange = lumaRange; self.hidden = hidden
    }

    /// True when the stroke can change a pixel.
    public var isActive: Bool { !hidden && !points.isEmpty && (mode == .erase || strength > 0) && flow > 0 }

    private enum CodingKeys: String, CodingKey {
        case id, mode, points, size, feather, flow, strength, range, protectTones, lumaRange, hidden
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DodgeBurnStroke()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        mode = (try? c.decodeIfPresent(DodgeBurnMode.self, forKey: .mode)) ?? d.mode
        func unit(_ v: Double?, _ fallback: Double) -> Double {
            guard let v, v.isFinite else { return fallback }
            return min(max(v, 0), 1)
        }
        let flat = try c.decodeIfPresent([Double].self, forKey: .points) ?? []
        var pts: [StrokePoint] = []
        pts.reserveCapacity(flat.count / 3)
        var i = 0
        while i + 2 < flat.count {
            if flat[i].isFinite, flat[i + 1].isFinite {
                pts.append(StrokePoint(x: flat[i], y: flat[i + 1], pressure: unit(flat[i + 2], 1)))
            }
            i += 3
        }
        points = pts
        let s = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        size = s.isFinite ? min(max(s, Self.sizeRange.lowerBound), Self.sizeRange.upperBound) : d.size
        feather = unit(try c.decodeIfPresent(Double.self, forKey: .feather), d.feather)
        flow = unit(try c.decodeIfPresent(Double.self, forKey: .flow), d.flow)
        strength = unit(try c.decodeIfPresent(Double.self, forKey: .strength), d.strength)
        range = (try? c.decodeIfPresent(DodgeBurnRange.self, forKey: .range)) ?? d.range
        protectTones = try c.decodeIfPresent(Bool.self, forKey: .protectTones) ?? d.protectTones
        lumaRange = try c.decodeIfPresent(LumaRange.self, forKey: .lumaRange)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }

    /// Points are written as one flat `[x, y, pressure, x, y, pressure, ...]` array, rounded to four
    /// decimals (two for pressure), to keep sidecars and Photos adjustment data small.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(mode, forKey: .mode)
        var flat: [Double] = []
        flat.reserveCapacity(points.count * 3)
        for p in points {
            flat.append((p.x * 10_000).rounded() / 10_000)
            flat.append((p.y * 10_000).rounded() / 10_000)
            flat.append((p.pressure * 100).rounded() / 100)
        }
        try c.encode(flat, forKey: .points)
        try c.encode(size, forKey: .size)
        try c.encode(feather, forKey: .feather)
        try c.encode(flow, forKey: .flow)
        try c.encode(strength, forKey: .strength)
        try c.encode(range, forKey: .range)
        try c.encode(protectTones, forKey: .protectTones)
        try c.encodeIfPresent(lumaRange, forKey: .lumaRange)
        if hidden { try c.encode(hidden, forKey: .hidden) }
    }
}

/// Dodge and burn painted on a photo: a list of strokes, applied in order. Identity (no strokes)
/// by default. Belongs to the photo like the crop, so presets never carry it.
public struct DodgeBurnSettings: Codable, Hashable, Sendable {
    public typealias Stroke = DodgeBurnStroke

    public var strokes: [DodgeBurnStroke]

    public static let identity = DodgeBurnSettings()

    public init(strokes: [DodgeBurnStroke] = []) { self.strokes = strokes }

    /// True with no strokes (hidden ones still count, so they are saved).
    public var isIdentity: Bool { strokes.isEmpty }

    /// The strokes that can change the picture, in painting order.
    public var activeStrokes: [DodgeBurnStroke] { strokes.filter(\.isActive) }

    /// True when rendering has anything to do.
    public var hasVisibleEffect: Bool { strokes.contains { $0.isActive && $0.mode != .erase } }

    private enum CodingKeys: String, CodingKey { case strokes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strokes = try c.decodeIfPresent([DodgeBurnStroke].self, forKey: .strokes) ?? []
    }
}
