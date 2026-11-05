import Foundation

/// Per-channel values (stops of exposure change, or gains), in linear light.
public struct ChannelStops: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    public static let zero = ChannelStops(r: 0, g: 0, b: 0)
}

/// Datasheet reciprocity data of a film (`films.json` -> `"reciprocity"`). Two forms:
/// - `table`: manufacturer rows `[seconds, stops, ccStops]`, no correction up to `noCorrectionUpTo`.
///   `stops` is the recommended exposure increase (nil = "not recommended"); `ccStops` is the absorption
///   in stops, per channel, of the colour-compensating filter the sheet recommends at that time (nil = none).
///   `highIntensity` rows `[seconds, stops]` cover very short exposures.
/// - `schwarzschild`: Ilford's rule t_c = t^p (seconds), no correction up to `threshold`.
public struct ReciprocityData: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case table, schwarzschild }

    public struct Row: Codable, Hashable, Sendable {
        public var seconds: Double
        public var stops: Double?
        public var cc: ChannelStops?
        public init(seconds: Double, stops: Double?, cc: ChannelStops? = nil) {
            self.seconds = seconds; self.stops = stops; self.cc = cc
        }
        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            seconds = try c.decode(Double.self)
            if !c.isAtEnd, try !c.decodeNil() { stops = try c.decode(Double.self) } else { stops = nil }
            if !c.isAtEnd, try !c.decodeNil() { cc = try c.decode(ChannelStops.self) } else { cc = nil }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(seconds)
            if let stops { try c.encode(stops) } else { try c.encodeNil() }
            if let cc { try c.encode(cc) } else { try c.encodeNil() }
        }
    }

    public struct HighRow: Codable, Hashable, Sendable {
        public var seconds: Double
        public var stops: Double
        public init(seconds: Double, stops: Double) { self.seconds = seconds; self.stops = stops }
        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            seconds = try c.decode(Double.self)
            stops = try c.decode(Double.self)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(seconds)
            try c.encode(stops)
        }
    }

    public var type: Kind
    /// Table: longest time (seconds) that needs no correction.
    public var noCorrectionUpTo: Double?
    public var rows: [Row]?
    public var highIntensity: [HighRow]?
    /// Schwarzschild exponent and the time (seconds) up to which no correction is needed.
    public var p: Double?
    public var threshold: Double?
    /// Per stop of loss, extra loss of each channel (stops), when the rows carry no filter data.
    public var castPerStop: ChannelStops?
    /// Fractional gain of the tone-curve slope per stop of loss.
    public var contrastPerStop: Double?
    public var source: String?

    public init(type: Kind, noCorrectionUpTo: Double? = nil, rows: [Row]? = nil, highIntensity: [HighRow]? = nil,
                p: Double? = nil, threshold: Double? = nil, castPerStop: ChannelStops? = nil,
                contrastPerStop: Double? = nil, source: String? = nil) {
        self.type = type; self.noCorrectionUpTo = noCorrectionUpTo; self.rows = rows
        self.highIntensity = highIntensity; self.p = p; self.threshold = threshold
        self.castPerStop = castPerStop; self.contrastPerStop = contrastPerStop; self.source = source
    }
}

/// What a long or short exposure does to a film, for a given exposure time.
public struct ReciprocityEffect: Equatable, Sendable {
    /// Stops of speed lost (> 0) at the exposure time.
    public var lossStops: Double
    /// Per-channel exposure change in stops (negative = that channel loses extra speed). Luminance
    /// weighted mean is 0; the sign is already the direction to apply.
    public var cast: ChannelStops
    /// Slope gain of the tone curve around mid-grey (1 = none).
    public var contrastGain: Double
    /// Grain amplitude gain in the shadows (1 = none).
    public var shadowGrainGain: Double
    /// True when the time lies outside what the datasheet covers (extrapolated).
    public var beyondDatasheet: Bool

    public init(lossStops: Double, cast: ChannelStops, contrastGain: Double, shadowGrainGain: Double,
                beyondDatasheet: Bool) {
        self.lossStops = lossStops; self.cast = cast; self.contrastGain = contrastGain
        self.shadowGrainGain = shadowGrainGain; self.beyondDatasheet = beyondDatasheet
    }

    public static let none = ReciprocityEffect(lossStops: 0, cast: .zero, contrastGain: 1, shadowGrainGain: 1,
                                               beyondDatasheet: false)

    /// True when the effect changes nothing.
    public var isIdentity: Bool {
        abs(lossStops) < 1e-6 && abs(cast.r) < 1e-6 && abs(cast.g) < 1e-6 && abs(cast.b) < 1e-6
            && abs(contrastGain - 1) < 1e-6 && abs(shadowGrainGain - 1) < 1e-6
    }
}

public enum ReciprocityMode: String, Codable, CaseIterable, Sendable {
    case off
    /// The photographer added the datasheet's compensation: mean exposure is kept, the cast, contrast and
    /// shadow-grain residue stay.
    case compensated
    /// No compensation: the picture is also darker by the lost stops.
    case uncompensated

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .compensated: "Compensated"
        case .uncompensated: "Uncompensated"
        }
    }
}

public enum Reciprocity {
    /// Luminance weights of linear sRGB / Rec.709.
    static let lum = (r: 0.2126, g: 0.7152, b: 0.0722)

    // MARK: Family defaults

    /// Defaults for stocks without a datasheet entry, from the research in `reciprocity.json`
    /// (per-stock fits of the published rows). `contrastPerStop` 0.05 and the instant / motion-picture
    /// `castPerStop` are tuning assumptions: no manufacturer publishes a figure (the cast values are
    /// derived from the few filter recommendations that exist). nil for print stocks, which are not exposed
    /// in a camera.
    public static func familyDefault(_ family: FilmFamily) -> ReciprocityData? {
        switch family {
        case .colorNegative:
            // Median per-row fit of Fuji X-TRA 400, Pro 160C, Pro 400H and Vision3 500T (p 1.167 ... 1.301);
            // Kodak's current sheets: no correction up to 1 s. No C-41 sheet prints a filter: cast 0.
            return ReciprocityData(type: .schwarzschild, p: 1.2, threshold: 1, castPerStop: .zero, contrastPerStop: 0.05)
        case .blackAndWhite:
            // Median of the 11 Ilford exponents (1.31). contrastPerStop is an assumption between T-grain /
            // Ilford (no published pull) and classic emulsions (Kodak -10 % development per stop).
            return ReciprocityData(type: .schwarzschild, p: 1.31, threshold: 1, castPerStop: .zero, contrastPerStop: 0.05)
        case .slide:
            // Median over nine slide stocks of each stock's rows (not-recommended cells left out).
            return ReciprocityData(type: .table, noCorrectionUpTo: 32,
                                   rows: [.init(seconds: 64, stops: 0.04), .init(seconds: 128, stops: 0.45),
                                          .init(seconds: 240, stops: 0.75), .init(seconds: 480, stops: 0.83)],
                                   castPerStop: ChannelStops(r: 0.131, g: -0.042, b: -0.035), contrastPerStop: 0.05)
        case .kodachrome:
            // Merge of the K64 and K200 rows (Kodak E-31 Table 5); not recommended from 10 s.
            return ReciprocityData(type: .table, noCorrectionUpTo: 0.01,
                                   rows: [.init(seconds: 0.1, stops: 1.0 / 3, cc: cc05R),
                                          .init(seconds: 1, stops: 0.5, cc: cc10Y)],
                                   castPerStop: ChannelStops(r: 0.221, g: -0.029, b: -0.36), contrastPerStop: 0.05)
        case .motionPicture:
            // One datum: Vision3 500T, 10 s +1 stop with CC10R. Beyond it the log-time extrapolation of
            // (1 s, 0) -> (10 s, 1) is the same as p = 1.301.
            return ReciprocityData(type: .table, noCorrectionUpTo: 1,
                                   rows: [.init(seconds: 10, stops: 1, cc: cc10R)],
                                   castPerStop: ChannelStops(r: 0.261, g: -0.071, b: -0.071), contrastPerStop: 0.05)
        case .instant:
            // Mean of Polaroid 667 (graph estimate) and 669 (printed ISO table); cast from 669's filters.
            return ReciprocityData(type: .table, noCorrectionUpTo: 0.07,
                                   rows: [.init(seconds: 0.25, stops: 0.6), .init(seconds: 1, stops: 1.09),
                                          .init(seconds: 10, stops: 2.15), .init(seconds: 100, stops: 2.4)],
                                   castPerStop: ChannelStops(r: 0.723, g: -0.171, b: -0.332), contrastPerStop: 0.05)
        case .print:
            return nil
        }
    }

    private static let cc05R = ChannelStops(r: 0, g: 0.166, b: 0.166)
    private static let cc10R = ChannelStops(r: 0, g: 0.332, b: 0.332)
    private static let cc10Y = ChannelStops(r: 0, g: 0, b: 0.332)

    // MARK: Effect

    /// The effect of an exposure of `t` seconds on `film` (its datasheet data, else its family's default).
    /// Exactly `ReciprocityEffect.none` at 1/125 s and for any film without data (print stocks).
    public static func effect(film: Film, exposureTime t: Double) -> ReciprocityEffect {
        let fallback = familyDefault(film.family)
        guard let data = film.reciprocity ?? fallback else { return .none }
        var e = effect(data: data, familyCast: fallback?.castPerStop, familyContrast: fallback?.contrastPerStop,
                       exposureTime: t)
        // A monochrome film has no colour layers to fail unequally.
        if film.isMonochrome { e.cast = .zero }
        return e
    }

    /// The loss in stops at `t` and whether it is extrapolated (`beyondDatasheet`), before cast and contrast.
    public static func loss(data: ReciprocityData, exposureTime t: Double) -> (stops: Double, beyond: Bool, short: Bool) {
        guard t.isFinite, t > 0 else { return (0, false, false) }
        switch data.type {
        case .schwarzschild:
            let p = data.p ?? 1, threshold = max(data.threshold ?? 1, 1e-9)
            guard t > threshold else { return (shortLoss(data, t), false, shortLoss(data, t) > 0) }
            // t_c = threshold (t / threshold)^p, so with threshold 1 s this is Ilford's t_c = t^p.
            return ((p - 1) * log2(t / threshold), false, false)
        case .table:
            let anchor = data.noCorrectionUpTo ?? 0
            guard t > anchor else { let s = shortLoss(data, t); return (s, false, s > 0) }
            let pts = points(data)
            if let last = pts.last, t <= last.t {
                return (interpolate(pts, t), false, false)
            }
            // Past the last published row: extrapolate the last segment in log-time.
            let (lastT, lastLoss) = pts.last.map { ($0.t, $0.loss) } ?? (max(anchor, 1e-9), 0)
            var slope: Double
            if pts.count >= 2 {
                let a = pts[pts.count - 2], b = pts[pts.count - 1]
                slope = (b.loss - a.loss) / (log2(b.t) - log2(a.t))
            } else {
                // No published number at all (e.g. "not recommended" only): a Schwarzschild p of 1.2.
                slope = 0.2
            }
            slope = max(slope, 0)
            return (lastLoss + slope * (log2(t) - log2(lastT)), true, false)
        }
    }

    /// Loss for exposures shorter than the no-correction limit (high-intensity failure), 0 unless published.
    private static func shortLoss(_ data: ReciprocityData, _ t: Double) -> Double {
        guard let rows = data.highIntensity?.sorted(by: { $0.seconds < $1.seconds }),
              let first = rows.first, let last = rows.last, t <= last.seconds else { return 0 }
        if t <= first.seconds { return max(first.stops, 0) }
        for i in 1..<rows.count where t <= rows[i].seconds {
            let a = rows[i - 1], b = rows[i]
            let f = (log2(t) - log2(a.seconds)) / (log2(b.seconds) - log2(a.seconds))
            return max(a.stops + f * (b.stops - a.stops), 0)
        }
        return 0
    }

    struct Point { var t: Double; var loss: Double; var cast: ChannelStops?; var hasCC: Bool }

    /// The anchor (no correction up to `noCorrectionUpTo`) followed by the rows with a published number.
    static func points(_ data: ReciprocityData) -> [Point] {
        let anchor = max(data.noCorrectionUpTo ?? 0, 1e-9)
        var pts = [Point(t: anchor, loss: 0, cast: .zero, hasCC: false)]
        for row in (data.rows ?? []).sorted(by: { $0.seconds < $1.seconds }) {
            guard let stops = row.stops, row.seconds > anchor, row.seconds > pts[pts.count - 1].t else { continue }
            var cast: ChannelStops?
            if let f = row.cc { cast = castOf(filter: f) }
            pts.append(Point(t: row.seconds, loss: stops, cast: cast, hasCC: cast != nil))
        }
        return pts
    }

    /// The inverse of a recommended filter, as exposure change per channel: the filter restores channel c by
    /// f_c, so without it channel c sits at (f_c - mean) relative to the luminance-weighted mean (luminance
    /// is preserved). CC10R (0, .33, .33) -> red -0.26, green and blue +0.07.
    static func castOf(filter f: ChannelStops) -> ChannelStops {
        let mean = lum.r * f.r + lum.g * f.g + lum.b * f.b
        return ChannelStops(r: f.r - mean, g: f.g - mean, b: f.b - mean)
    }

    private static func interpolate(_ pts: [Point], _ t: Double) -> Double {
        for i in 1..<pts.count where t <= pts[i].t {
            let a = pts[i - 1], b = pts[i]
            let f = (log2(t) - log2(a.t)) / (log2(b.t) - log2(a.t))
            return a.loss + f * (b.loss - a.loss)
        }
        return pts.last?.loss ?? 0
    }

    /// The effect for a datasheet entry; `familyCast` / `familyContrast` fill what the entry does not say.
    static func effect(data: ReciprocityData, familyCast: ChannelStops?, familyContrast: Double?,
                       exposureTime t: Double) -> ReciprocityEffect {
        let (loss, beyond, short) = loss(data: data, exposureTime: t)
        guard loss > 1e-9 else { return .none }
        let perStop = data.contrastPerStop ?? familyContrast ?? 0.05
        if short {
            // High-intensity failure lowers contrast and density; no colour shift, no grain change.
            return ReciprocityEffect(lossStops: loss, cast: .zero, contrastGain: max(0.5, 1 - perStop * loss),
                                     shadowGrainGain: 1, beyondDatasheet: false)
        }
        var cast = ChannelStops.zero
        let pts = data.type == .table ? points(data) : []
        if pts.contains(where: { $0.hasCC }) {
            // Rows with filters: interpolate each channel in log-time (rows without a filter count as 0),
            // and past the last row keep its cast per stop of loss.
            func c(_ p: Point) -> ChannelStops { p.cast ?? .zero }
            if let last = pts.last, t <= last.t {
                for i in 1..<pts.count where t <= pts[i].t {
                    let a = pts[i - 1], b = pts[i]
                    let f = (log2(t) - log2(a.t)) / (log2(b.t) - log2(a.t))
                    cast = ChannelStops(r: c(a).r + f * (c(b).r - c(a).r), g: c(a).g + f * (c(b).g - c(a).g),
                                        b: c(a).b + f * (c(b).b - c(a).b))
                    break
                }
            } else if let last = pts.last, last.loss > 0 {
                let k = loss / last.loss
                cast = ChannelStops(r: c(last).r * k, g: c(last).g * k, b: c(last).b * k)
            }
        } else {
            // No filter data: the family's extra loss per channel, per stop of loss (positive = loses more).
            let per = data.castPerStop ?? familyCast ?? .zero
            cast = ChannelStops(r: -per.r * loss, g: -per.g * loss, b: -per.b * loss)
        }
        return ReciprocityEffect(lossStops: loss, cast: cast, contrastGain: 1 + perStop * loss,
                                 shadowGrainGain: min(2, exp2(loss / 2)), beyondDatasheet: beyond)
    }
}
