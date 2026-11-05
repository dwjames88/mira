import Foundation

/// Looks Mira authors in code instead of loading a LUT file: Mira originals, built from parametric
/// transforms (a tone curve, a saturation matrix with skin protection and split colour balance),
/// inspired by the published characteristic behavior of cinema negative, cinema print film and colour
/// paper. They are not copies of any LUT or measurement and carry no affiliation with Kodak or Fujifilm.
///
/// Each look is evaluated at every lattice point of a 64³ cube (sRGB-encoded in and out, the same
/// layout as Hald-derived LUTs) and cached per id. The print looks (`cinema-print`, `color-paper`) are
/// the one implementation behind both the film cards and the renderer's Paper stage.
public enum ProceduralLooks {
    /// Cube dimension of the generated LUTs.
    public static let dimension = 64

    /// Every registered look id.
    public static let ids: [String] = ["vision3-500t", "vision3-250d", "cinema-print", "color-paper"]

    public static func isRegistered(_ id: String) -> Bool { parameters[id] != nil }

    /// The look id of a print stock, nil for `.none`.
    public static func id(for paper: PaperProfile) -> String? {
        switch paper {
        case .none: nil
        case .cinemaPrint: "cinema-print"
        case .colorPaper: "color-paper"
        }
    }

    /// The (cached) LUT of look `id`; throws for an unregistered id.
    public static func lut(_ id: String) throws -> LUT {
        guard let p = parameters[id] else { throw LUTError.invalidCube("unknown procedural look \(id)") }
        return cache.lut(id) { generate(p) }
    }

    // MARK: Parameters

    /// The numbers of one look. Tone values are sRGB-encoded units.
    struct Params: Equatable, Sendable {
        /// Per-channel gain in linear light (white balance of the stock; tungsten film in daylight is blue).
        var balance: SIMD3<Double> = [1, 1, 1]
        /// Slope at `pivot`.
        var contrast = 1.0
        var pivot = 0.5
        /// Toe: below `toeStart` values roll into `black` (the density floor).
        var toeStart = 0.2
        var black = 0.0
        /// Shoulder: above `shoulderStart` values roll toward `white`.
        var shoulderStart = 0.7
        var white = 1.0
        /// Saturation multiplier about luma.
        var saturation = 1.0
        /// 0...1: how much of the saturation change is withheld from skin (orange) hues.
        var skinProtection = 0.0
        /// Split colour balance, added in encoded units: weight (1-L)² / L² for shadows / highlights and
        /// (1-L)⁶ for the deep shadows.
        var shadowTint: SIMD3<Double> = [0, 0, 0]
        var deepShadowTint: SIMD3<Double> = [0, 0, 0]
        var highlightTint: SIMD3<Double> = [0, 0, 0]
    }

    static let parameters: [String: Params] = [
        // Tungsten-balanced negative printed neutral: low contrast, long soft shoulder, lifted teal
        // shadows, warm creamy highlights, restrained saturation. Linear gains 0.90 / 1 / 1.14 give the
        // cool-blue daylight cast (correct with Temperature).
        "vision3-500t": Params(
            balance: [0.90, 1.0, 1.14], contrast: 0.86, toeStart: 0.22, black: 0.035,
            shoulderStart: 0.58, white: 0.985, saturation: 0.88, skinProtection: 0.6,
            shadowTint: [-0.012, 0.006, 0.010], deepShadowTint: [-0.010, 0.008, 0.004],
            highlightTint: [0.014, 0.006, -0.012]),
        // Daylight-balanced sibling: neutral balance, a touch more contrast and saturation.
        "vision3-250d": Params(
            contrast: 0.98, toeStart: 0.20, black: 0.028,
            shoulderStart: 0.64, white: 0.975, saturation: 0.95, skinProtection: 0.5,
            shadowTint: [-0.006, 0.003, 0.006], deepShadowTint: [-0.006, 0.005, 0.002],
            highlightTint: [0.010, 0.004, -0.008]),
        // Release print film: deep contrast, dense blacks with a cool-neutral cast, saturated but
        // hue-stable (skin mostly spared), slightly warm highlight roll-off.
        "cinema-print": Params(
            contrast: 1.38, toeStart: 0.12, black: 0.012,
            shoulderStart: 0.66, white: 0.975, saturation: 1.18, skinProtection: 0.35,
            shadowTint: [-0.006, 0.0, 0.008], deepShadowTint: [-0.004, 0.0, 0.006],
            highlightTint: [0.010, 0.004, -0.008]),
        // Colour paper: clean bright whites, moderate contrast, gentle warmth, natural saturation.
        "color-paper": Params(
            balance: [1.03, 1.0, 0.96], contrast: 1.10, toeStart: 0.08, black: 0.006,
            shoulderStart: 0.84, white: 1.0, saturation: 1.06, skinProtection: 0.3,
            highlightTint: [0.006, 0.003, -0.004]),
    ]

    // MARK: Transform

    /// The look applied to one sRGB-encoded colour.
    static func transform(_ p: Params, _ rgb: SIMD3<Double>) -> SIMD3<Double> {
        // 1. Stock balance in linear light.
        var c = SIMD3<Double>(repeating: 0)
        for i in 0..<3 {
            let lin = decode(rgb[i]) * p.balance[i]
            c[i] = encode(min(max(lin, 0), 1))
        }
        // 2. Tone curve per channel.
        for i in 0..<3 { c[i] = curve(p, c[i]) }
        // 3. Saturation about luma, withheld from skin hues.
        let y = luma(c)
        let skin = skinWeight(c)
        let sat = 1 + (p.saturation - 1) * (1 - p.skinProtection * skin)
        c = SIMD3(repeating: y) + (c - SIMD3(repeating: y)) * sat
        // 4. Split colour balance.
        let l = min(max(luma(c), 0), 1)
        let ws = (1 - l) * (1 - l), wd = pow(1 - l, 6), wh = l * l
        c += p.shadowTint * ws + p.deepShadowTint * wd + p.highlightTint * wh
        return SIMD3(min(max(c.x, 0), 1), min(max(c.y, 0), 1), min(max(c.z, 0), 1))
    }

    /// Monotone S-curve: linear about the pivot, tanh toe into `black`, tanh shoulder into `white`.
    static func curve(_ p: Params, _ x: Double) -> Double {
        var y = p.pivot + (x - p.pivot) * p.contrast
        if y > p.shoulderStart {
            let span = p.white - p.shoulderStart
            y = p.shoulderStart + span * tanh((y - p.shoulderStart) / span)
        }
        if y < p.toeStart {
            let span = p.toeStart - p.black
            y = p.toeStart - span * tanh((p.toeStart - y) / span)
        }
        return y
    }

    /// Weight 0...1 of the skin hue band (orange, about 25° in HSV hue), faded by chroma.
    private static func skinWeight(_ c: SIMD3<Double>) -> Double {
        let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z)
        let d = mx - mn
        guard d > 1e-6 else { return 0 }
        var h: Double
        if mx == c.x { h = 60 * ((c.y - c.z) / d) }
        else if mx == c.y { h = 60 * ((c.z - c.x) / d + 2) }
        else { h = 60 * ((c.x - c.y) / d + 4) }
        if h < 0 { h += 360 }
        let dh = (h - 25) / 22
        return exp(-dh * dh)
    }

    private static func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    private static func decode(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func encode(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    // MARK: Generation and cache

    private static func generate(_ p: Params) -> LUT {
        let n = dimension
        var out = [Float](repeating: 1, count: n * n * n * 4)
        let scale = 1.0 / Double(n - 1)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let o = ((b * n + g) * n + r) * 4
                    let v = transform(p, [Double(r) * scale, Double(g) * scale, Double(b) * scale])
                    out[o] = Float(v.x); out[o + 1] = Float(v.y); out[o + 2] = Float(v.z)
                }
            }
        }
        return LUT(dimension: n, data: out.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var luts: [String: LUT] = [:]
        func lut(_ id: String, make: () -> LUT) -> LUT {
            lock.lock(); defer { lock.unlock() }
            if let hit = luts[id] { return hit }
            let made = make()
            luts[id] = made
            return made
        }
    }

    private static let cache = Cache()
}
