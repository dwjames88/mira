import Foundation

/// How a film stock behaves beyond its colour LUT: grain, halation and exposure latitude. Values are
/// derived from the family and ISO (`defaults`) and can be overridden per film in `films.json`
/// (`"character": { "grainStrength": 1.2, ... }`). Used by the film-science pipeline (`Recipe.pipeline` 2).
///
/// Physical basis:
/// - Grain: faster emulsions use larger silver-halide crystals, so grain strength and size grow with
///   ISO (roughly with its square root and fourth root). Negative film shows grain most in the
///   midtones and shadows of the print (thin areas of the negative); slide film in the light
///   midtones and highlights (thin areas of the positive). Colour films have dye clouds in three
///   layers, so some grain is chromatic; black-and-white grain is monochrome.
/// - Halation: light passes through the emulsion, reflects off the film base and re-exposes the
///   red-sensitive (deepest) layer around bright highlights, giving a red-orange glow. Black-and-white
///   and most slide stocks carry an anti-halation layer, so theirs is faint and, for B&W, untinted.
/// - Latitude: negative film records several stops above a normal exposure on its long shoulder, so
///   overexposure rolls highlights off; slide film clips like a digital sensor.
public struct FilmCharacter: Codable, Hashable, Sendable {
    /// Grain visibility relative to an ISO 400 colour negative (1.0).
    public var grainStrength: Double
    /// Grain feature size as a fraction of the frame diagonal (resolution independent).
    public var grainSize: Double
    /// 0 monochrome grain, 1 fully independent per-channel grain.
    public var grainChroma: Double
    /// sRGB-encoded luminance where grain is most visible.
    public var grainTonalCenter: Double
    /// Halation strength relative to an unprotected colour negative (1.0).
    public var halationStrength: Double
    /// Halation colour in linear RGB (normalised to unit luminance by the renderer).
    public var halationTint: [Double]
    /// Halation spread (Gaussian sigma) as a fraction of the frame diagonal.
    public var halationRadius: Double
    /// 0 hard clip on overexposure (slide, digital), 1 full negative-film shoulder.
    public var latitude: Double
    /// Stops below and above a normal exposure the stock still records with detail (for the latitude
    /// indicator): e.g. colour negative 2 and 3, slide 2 and 1.5.
    public var latitudeUnder: Double
    public var latitudeOver: Double
    /// True for stocks with a rem-jet anti-halation backing (ECN-2 motion-picture film): halation is
    /// suppressed unless the recipe removes the rem-jet (`Recipe.remJetRemoved`), which gives the strong
    /// red bleed of rem-jet-free stocks.
    public var remJet: Bool
    /// Per stop of push (negative stops = pull): added print contrast (0...1 scale of the contrast
    /// slider) and relative grain growth.
    public var pushContrastPerStop: Double
    public var pushGrainPerStop: Double

    public init(grainStrength: Double, grainSize: Double, grainChroma: Double, grainTonalCenter: Double,
                halationStrength: Double, halationTint: [Double], halationRadius: Double, latitude: Double,
                latitudeUnder: Double = 2, latitudeOver: Double = 3, remJet: Bool = false,
                pushContrastPerStop: Double = 0.08, pushGrainPerStop: Double = 0.25) {
        self.grainStrength = grainStrength
        self.grainSize = grainSize
        self.grainChroma = grainChroma
        self.grainTonalCenter = grainTonalCenter
        self.halationStrength = halationStrength
        self.halationTint = halationTint
        self.halationRadius = halationRadius
        self.latitude = latitude
        self.latitudeUnder = latitudeUnder
        self.latitudeOver = latitudeOver
        self.remJet = remJet
        self.pushContrastPerStop = pushContrastPerStop
        self.pushGrainPerStop = pushGrainPerStop
    }

    /// Used when no film is selected: an ISO 400 colour negative.
    public static let generic = defaults(family: .colorNegative, iso: 400, monochrome: false)

    public static func defaults(family: FilmFamily, iso: Int, monochrome: Bool) -> FilmCharacter {
        let speed = Double(iso > 0 ? iso : 100)
        let rel = speed / 400
        var strength = pow(rel, 0.5)
        var size = 0.00045 * pow(rel, 0.25)
        var chroma: Double
        var center: Double
        var halation: Double
        var tint: [Double] = [1.0, 0.28, 0.06]
        var latitude: Double
        var under = 2.0, over = 3.0
        var remJet = false
        var pushContrast = 0.08, pushGrain = 0.25
        switch family {
        case .colorNegative:
            chroma = 0.3; center = 0.4; halation = 1.0; latitude = 1.0
        case .slide:
            strength *= 0.8; chroma = 0.2; center = 0.65; halation = 0.15; latitude = 0.15
            over = 1.5; pushContrast = 0.12
        case .kodachrome:
            // K-14: dyes added in development, no dye couplers in the emulsion, so very fine grain.
            strength *= 0.55; chroma = 0.15; center = 0.65; halation = 0.1; latitude = 0.15
            under = 1.5; over = 1; pushContrast = 0.12
        case .motionPicture:
            // ECN-2: rem-jet backing suppresses halation until it is removed.
            chroma = 0.3; center = 0.4; halation = 1.2; latitude = 1.0; over = 4; under = 3; remJet = true
        case .blackAndWhite:
            strength *= 1.1; chroma = 0; center = 0.4; halation = 0.25; latitude = 0.9
            pushContrast = 0.12; pushGrain = 0.35
        case .instant:
            strength *= 0.6; size *= 1.3; chroma = 0.15; center = 0.5; halation = 0.3; latitude = 0.5
            tint = [1.0, 0.5, 0.25]; under = 1; over = 1
        case .print:
            // A print stock on its own: fine-grained positive, moderate shoulder.
            strength *= 0.4; chroma = 0.2; center = 0.5; halation = 0.5; latitude = 0.6; over = 2
        }
        if monochrome {
            chroma = 0
            tint = [1, 1, 1]
            if family != .blackAndWhite { halation = min(halation, 0.25) }
        }
        strength = min(max(strength, 0.3), 2.5)
        size = min(max(size, 0.0002), 0.0012)
        return FilmCharacter(grainStrength: strength, grainSize: size, grainChroma: chroma,
                             grainTonalCenter: center, halationStrength: halation, halationTint: tint,
                             halationRadius: 0.006, latitude: latitude, latitudeUnder: under,
                             latitudeOver: over, remJet: remJet, pushContrastPerStop: pushContrast,
                             pushGrainPerStop: pushGrain)
    }

    /// Any subset of the fields, as written in `films.json`.
    public struct Override: Codable, Hashable, Sendable {
        public var grainStrength: Double?
        public var grainSize: Double?
        public var grainChroma: Double?
        public var grainTonalCenter: Double?
        public var halationStrength: Double?
        public var halationTint: [Double]?
        public var halationRadius: Double?
        public var latitude: Double?
        public var latitudeUnder: Double?
        public var latitudeOver: Double?
        public var remJet: Bool?

        public init(grainStrength: Double? = nil, grainSize: Double? = nil, grainChroma: Double? = nil,
                    grainTonalCenter: Double? = nil, halationStrength: Double? = nil,
                    halationTint: [Double]? = nil, halationRadius: Double? = nil, latitude: Double? = nil,
                    latitudeUnder: Double? = nil, latitudeOver: Double? = nil, remJet: Bool? = nil) {
            self.grainStrength = grainStrength
            self.grainSize = grainSize
            self.grainChroma = grainChroma
            self.grainTonalCenter = grainTonalCenter
            self.halationStrength = halationStrength
            self.halationTint = halationTint
            self.halationRadius = halationRadius
            self.latitude = latitude
            self.latitudeUnder = latitudeUnder
            self.latitudeOver = latitudeOver
            self.remJet = remJet
        }
    }

    public func applying(_ o: Override?) -> FilmCharacter {
        guard let o else { return self }
        var c = self
        if let v = o.grainStrength { c.grainStrength = v }
        if let v = o.grainSize { c.grainSize = v }
        if let v = o.grainChroma { c.grainChroma = v }
        if let v = o.grainTonalCenter { c.grainTonalCenter = v }
        if let v = o.halationStrength { c.halationStrength = v }
        if let v = o.halationTint, v.count == 3 { c.halationTint = v }
        if let v = o.halationRadius { c.halationRadius = v }
        if let v = o.latitude { c.latitude = v }
        if let v = o.latitudeUnder { c.latitudeUnder = v }
        if let v = o.latitudeOver { c.latitudeOver = v }
        if let v = o.remJet { c.remJet = v }
        return c
    }
}
