import CoreGraphics
import Foundation

/// A normalised rectangle (all values 0...1) with a **top-left origin and y pointing down**, the
/// way a UI draws it. It lives in the *crop canvas* (see `CropSettings`).
public struct CropRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public static let full = CropRect(x: 0, y: 0, w: 1, h: 1)

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, w: rect.size.width, h: rect.size.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    /// True when the rect covers the whole canvas (within rounding).
    public var isFull: Bool {
        abs(x) < 1e-9 && abs(y) < 1e-9 && abs(w - 1) < 1e-9 && abs(h - 1) < 1e-9
    }

    /// The rect forced into 0...1 with a small positive size.
    public func clamped() -> CropRect {
        let minSide = 0.001
        let nw = min(max(w.isFinite ? w : 1, minSide), 1)
        let nh = min(max(h.isFinite ? h : 1, minSide), 1)
        let nx = min(max(x.isFinite ? x : 0, 0), 1 - nw)
        let ny = min(max(y.isFinite ? y : 0, 0), 1 - nh)
        return CropRect(x: nx, y: ny, w: nw, h: nh)
    }

    private enum CodingKeys: String, CodingKey { case x, y, w, h }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        w = try c.decodeIfPresent(Double.self, forKey: .w) ?? 1
        h = try c.decodeIfPresent(Double.self, forKey: .h) ?? 1
    }
}

/// Non-destructive crop, rotation, flip and straighten of a photo.
///
/// **Space.** The pipeline is: source (upright) -> `rotate90` clockwise quarter turns -> `flipH`
/// / `flipV` (mirrors in the rotated frame) -> `straighten` (rotation about the centre) with
/// auto-fit (the largest axis-aligned rectangle of the oriented aspect ratio inscribed in the
/// rotated image, scaled up to fill the frame, so no empty corners). The result is the *crop
/// canvas*: it has the size of the oriented image (width and height swapped for odd `rotate90`).
/// `rect` is expressed in that canvas, normalised, top-left origin, y down.
public struct CropSettings: Codable, Hashable, Sendable {
    public var rect: CropRect
    /// Degrees, -45...45. Positive turns the picture clockwise.
    public var straighten: Double
    /// Clockwise quarter turns, 0...3.
    public var rotate90: Int
    public var flipH: Bool
    public var flipV: Bool
    /// Preset id, see `CropAspect`.
    public var aspect: String

    public static let identity = CropSettings()

    public init(
        rect: CropRect = .full, straighten: Double = 0, rotate90: Int = 0,
        flipH: Bool = false, flipV: Bool = false, aspect: String = CropAspect.original
    ) {
        self.rect = rect
        self.straighten = straighten
        self.rotate90 = rotate90
        self.flipH = flipH
        self.flipV = flipV
        self.aspect = aspect
    }

    /// True when the geometry does nothing (the aspect preset alone is only UI state).
    public var isIdentity: Bool {
        rect.isFull && abs(straighten) < 1e-9 && normalizedQuarterTurns == 0 && !flipH && !flipV
    }

    /// `rotate90` folded into 0...3.
    public var normalizedQuarterTurns: Int { ((rotate90 % 4) + 4) % 4 }

    /// Same geometry with the crop rect covering the whole canvas.
    public var withFullRect: CropSettings {
        var c = self
        c.rect = .full
        return c
    }

    private enum CodingKeys: String, CodingKey { case rect, straighten, rotate90, flipH, flipV, aspect }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rect = (try c.decodeIfPresent(CropRect.self, forKey: .rect) ?? .full).clamped()
        let s = try c.decodeIfPresent(Double.self, forKey: .straighten) ?? 0
        straighten = s.isFinite ? min(max(s, -45), 45) : 0
        let r = try c.decodeIfPresent(Int.self, forKey: .rotate90) ?? 0
        rotate90 = ((r % 4) + 4) % 4
        flipH = try c.decodeIfPresent(Bool.self, forKey: .flipH) ?? false
        flipV = try c.decodeIfPresent(Bool.self, forKey: .flipV) ?? false
        aspect = try c.decodeIfPresent(String.self, forKey: .aspect) ?? CropAspect.original
    }
}

/// Aspect presets by id: "original", "free", "square", "3:2", "2:3", "4:3", "3:4", "5:4", "4:5",
/// "16:9", "9:16".
public enum CropAspect {
    public static let original = "original"
    public static let free = "free"
    public static let square = "square"

    public static let allIDs = [
        "original", "free", "square", "3:2", "2:3", "4:3", "3:4", "5:4", "4:5", "16:9", "9:16",
    ]

    /// Width / height of the preset, or nil for "free" (and unknown ids). `canvas` is the size of
    /// the crop canvas, used by "original".
    public static func ratio(id: String, canvas: CGSize) -> Double? {
        switch id {
        case original: return canvas.height > 0 ? Double(canvas.width / canvas.height) : nil
        case free: return nil
        case square: return 1
        default:
            let parts = id.split(separator: ":")
            guard parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), a > 0, b > 0 else { return nil }
            return a / b
        }
    }

    /// The portrait/landscape counterpart ("3:2" <-> "2:3"); other ids come back unchanged.
    public static func swapped(_ id: String) -> String {
        let parts = id.split(separator: ":")
        guard parts.count == 2 else { return id }
        return "\(parts[1]):\(parts[0])"
    }

    /// True for ratios that are taller than wide ("2:3", "9:16").
    public static func isPortrait(_ id: String) -> Bool {
        guard let r = ratio(id: id, canvas: CGSize(width: 1, height: 1)) else { return false }
        return r < 1
    }

    /// The landscape form of a preset id, used to match the tab row.
    public static func landscape(_ id: String) -> String { isPortrait(id) ? swapped(id) : id }

    /// Short label for display ("ORIGINAL", "3:2").
    public static func label(_ id: String) -> String {
        switch id {
        case original: "Original"
        case free: "Free"
        case square: "Square"
        default: id
        }
    }
}
