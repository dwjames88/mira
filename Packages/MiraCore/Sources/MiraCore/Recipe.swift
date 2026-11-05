import Foundation

/// A complete, re-editable description of a look. Missing keys decode to defaults so
/// recipes written by other versions stay editable.
public struct Recipe: Codable, Hashable, Sendable {
    public var filmID: String?
    public var strength: Double
    public var exposure: Double
    public var contrast: Double
    public var saturation: Double
    public var warmth: Double
    public var tint: Double
    /// Tonal-range adjustments, all -1...1 and 0 by default. Written to disk only when non-zero.
    public var highlights: Double
    public var shadows: Double
    public var whites: Double
    public var blacks: Double
    public var vibrance: Double
    public var clarity: Double
    public var texture: Double
    public var grainAmount: Double
    public var grainSize: Double
    public var halationAmount: Double
    public var halationRadius: Double
    public var bloomAmount: Double
    public var vignetteAmount: Double
    public var borderEnabled: Bool
    public var borderWidth: Double
    public var version: Int
    /// Which rendering pipeline the recipe was made with. 1 (also every recipe written before 0.5, which
    /// has no `pipeline` key) is the original graph: white balance after the film, generic grain and
    /// halation. 2 is the film-science graph: exposure with the film's latitude and white balance before
    /// the film, halation in the exposure, per-film grain. A saved edit keeps its pipeline so it reopens
    /// looking the same; new recipes use `currentPipeline`.
    public var pipeline: Int
    public static let legacyPipeline = 1
    public static let currentPipeline = 2
    /// Push (+) or pull (−) processing in stops, −2...2 in thirds (pipeline 2).
    public var push: Double
    /// Removes the rem-jet backing of motion-picture stocks, unlocking their strong red halation.
    public var remJetRemoved: Bool
    /// Lab-scan rendering after the film (pipeline 2).
    public var scanProfile: ScanProfile
    /// Print stock after the film (pipeline 2); excludes `scanProfile` when not `.none`.
    public var paper: PaperProfile
    /// Black-and-white toning and its strength 0...1 (pipeline 2, monochrome films).
    public var toning: Toning
    public var toningStrength: Double
    /// Camera RAW decode settings; identity for non-RAW sources.
    public var raw: RawSettings
    /// Exposure time in seconds the film is exposed for (reciprocity, pipeline 2); nil reads the source's EXIF
    /// value. The EXIF value itself is a property of the source and is never stored here.
    public var exposureTime: Double?
    /// How the film's reciprocity failure is simulated (pipeline 2); `.compensated` by default.
    public var reciprocity: ReciprocityMode
    /// How strongly the reciprocity residue shows, 0...2 (1 = the datasheet model, 0 = none). Scales the cast,
    /// contrast and shadow-grain residue, and in Uncompensated mode the loss.
    public var reciprocityStrength: Double

    /// True when any film-science control is set (adjustment-data format version 4).
    public var usesFilmScienceControls: Bool {
        push != 0 || remJetRemoved || scanProfile != .neutral || paper != .none || toning != .none || !raw.isIdentity
            || exposureTime != nil || reciprocity != .compensated || reciprocityStrength != 1
    }

    /// The controls only pipeline 2 renders (push, rem-jet, scan, paper, toning, exposure time, reciprocity).
    struct FilmScienceControls: Equatable {
        var push: Double, remJet: Bool, scan: ScanProfile, paper: PaperProfile, toning: Toning, toningStrength: Double
        var exposureTime: Double?, reciprocity: ReciprocityMode, reciprocityStrength: Double
    }
    var filmScienceControls: FilmScienceControls {
        FilmScienceControls(push: push, remJet: remJetRemoved, scan: scanProfile, paper: paper, toning: toning,
                            toningStrength: toningStrength, exposureTime: exposureTime, reciprocity: reciprocity,
                            reciprocityStrength: reciprocityStrength)
    }

    /// True for a recipe on the legacy pipeline: it ignores the film-science controls.
    public var isLegacyPipeline: Bool { pipeline < Recipe.currentPipeline }

    /// Moves the recipe to the current pipeline when `self` differs from `old` in a pipeline-2-only control while
    /// both are on the legacy pipeline (same film). The one rule behind every film-science control, Mac and iOS:
    /// the control would otherwise do nothing. Returns true when it upgraded.
    @discardableResult
    public mutating func upgradePipelineIfFilmScienceChanged(from old: Recipe) -> Bool {
        guard isLegacyPipeline, old.isLegacyPipeline, filmID == old.filmID,
              filmScienceControls != old.filmScienceControls else { return false }
        pipeline = Recipe.currentPipeline
        return true
    }

    /// Applies `edit` (a change to film-science controls) and upgrades a legacy recipe to the current pipeline
    /// in the same edit; reopening without touching a control keeps the pipeline.
    public mutating func settingFilmScienceControl(_ edit: (inout Recipe) -> Void) {
        let old = self
        edit(&self)
        upgradePipelineIfFilmScienceChanged(from: old)
    }


    /// Crop, rotation, flips and straighten; identity by default.
    public var crop: CropSettings
    /// Tone curves (RGB, red, green, blue, luminance); identity by default.
    public var curves: CurvesSettings
    /// Per-hue-range hue, saturation and luminance; identity by default.
    public var colorMixer: ColorMixerSettings
    /// Dodge and burn strokes; identity (none) by default. Belongs to the photo, not to a look.
    public var dodgeBurn: DodgeBurnSettings

    public static let neutral = Recipe()

    public init(
        filmID: String? = nil,
        strength: Double = 1,
        exposure: Double = 0,
        contrast: Double = 0,
        saturation: Double = 0,
        warmth: Double = 0,
        tint: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0,
        whites: Double = 0,
        blacks: Double = 0,
        vibrance: Double = 0,
        clarity: Double = 0,
        texture: Double = 0,
        grainAmount: Double = 0,
        grainSize: Double = 0.5,
        halationAmount: Double = 0,
        halationRadius: Double = 0.5,
        bloomAmount: Double = 0,
        vignetteAmount: Double = 0,
        borderEnabled: Bool = false,
        borderWidth: Double = 0.04,
        version: Int = 1,
        pipeline: Int = Recipe.currentPipeline,
        push: Double = 0,
        remJetRemoved: Bool = false,
        scanProfile: ScanProfile = .neutral,
        paper: PaperProfile = .none,
        toning: Toning = .none,
        toningStrength: Double = 0.5,
        raw: RawSettings = .identity,
        exposureTime: Double? = nil,
        reciprocity: ReciprocityMode = .compensated,
        reciprocityStrength: Double = 1,
        crop: CropSettings = .identity,
        curves: CurvesSettings = .identity,
        colorMixer: ColorMixerSettings = .identity,
        dodgeBurn: DodgeBurnSettings = .identity
    ) {
        self.filmID = filmID
        self.strength = strength
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
        self.tint = tint
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.vibrance = vibrance
        self.clarity = clarity
        self.texture = texture
        self.grainAmount = grainAmount
        self.grainSize = grainSize
        self.halationAmount = halationAmount
        self.halationRadius = halationRadius
        self.bloomAmount = bloomAmount
        self.vignetteAmount = vignetteAmount
        self.borderEnabled = borderEnabled
        self.borderWidth = borderWidth
        self.version = version
        self.pipeline = pipeline
        self.push = push
        self.remJetRemoved = remJetRemoved
        self.scanProfile = scanProfile
        self.paper = paper
        self.toning = toning
        self.toningStrength = toningStrength
        self.raw = raw
        self.exposureTime = exposureTime
        self.reciprocity = reciprocity
        self.reciprocityStrength = reciprocityStrength
        self.crop = crop
        self.curves = curves
        self.colorMixer = colorMixer
        self.dodgeBurn = dodgeBurn
    }

    private enum CodingKeys: String, CodingKey {
        case filmID, strength, exposure, contrast, saturation, warmth, tint
        case grainAmount, grainSize, halationAmount, halationRadius, bloomAmount
        case vignetteAmount, borderEnabled, borderWidth, version, pipeline, crop
        case push, remJetRemoved, scanProfile, paper, toning, toningStrength, raw, curves, colorMixer, dodgeBurn
        case exposureTime, reciprocity, reciprocityStrength
        case highlights, shadows, whites, blacks, vibrance, clarity, texture
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Recipe()
        filmID = try c.decodeIfPresent(String.self, forKey: .filmID)
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? d.strength
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? d.exposure
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? d.contrast
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? d.saturation
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? d.warmth
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? d.tint
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? d.highlights
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? d.shadows
        whites = try c.decodeIfPresent(Double.self, forKey: .whites) ?? d.whites
        blacks = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? d.blacks
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? d.vibrance
        clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? d.clarity
        texture = try c.decodeIfPresent(Double.self, forKey: .texture) ?? d.texture
        grainAmount = try c.decodeIfPresent(Double.self, forKey: .grainAmount) ?? d.grainAmount
        grainSize = try c.decodeIfPresent(Double.self, forKey: .grainSize) ?? d.grainSize
        halationAmount = try c.decodeIfPresent(Double.self, forKey: .halationAmount) ?? d.halationAmount
        halationRadius = try c.decodeIfPresent(Double.self, forKey: .halationRadius) ?? d.halationRadius
        bloomAmount = try c.decodeIfPresent(Double.self, forKey: .bloomAmount) ?? d.bloomAmount
        vignetteAmount = try c.decodeIfPresent(Double.self, forKey: .vignetteAmount) ?? d.vignetteAmount
        borderEnabled = try c.decodeIfPresent(Bool.self, forKey: .borderEnabled) ?? d.borderEnabled
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? d.borderWidth
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        pipeline = try c.decodeIfPresent(Int.self, forKey: .pipeline) ?? Recipe.legacyPipeline
        push = try c.decodeIfPresent(Double.self, forKey: .push) ?? d.push
        remJetRemoved = try c.decodeIfPresent(Bool.self, forKey: .remJetRemoved) ?? d.remJetRemoved
        // Unknown enum values (from a newer build) fall back to the default rather than failing.
        scanProfile = (try? c.decodeIfPresent(ScanProfile.self, forKey: .scanProfile)) ?? d.scanProfile
        paper = (try? c.decodeIfPresent(PaperProfile.self, forKey: .paper)) ?? d.paper
        toning = (try? c.decodeIfPresent(Toning.self, forKey: .toning)) ?? d.toning
        toningStrength = try c.decodeIfPresent(Double.self, forKey: .toningStrength) ?? d.toningStrength
        raw = try c.decodeIfPresent(RawSettings.self, forKey: .raw) ?? .identity
        exposureTime = try c.decodeIfPresent(Double.self, forKey: .exposureTime)
        reciprocity = (try? c.decodeIfPresent(ReciprocityMode.self, forKey: .reciprocity)) ?? d.reciprocity
        reciprocityStrength = try c.decodeIfPresent(Double.self, forKey: .reciprocityStrength) ?? d.reciprocityStrength
        crop = try c.decodeIfPresent(CropSettings.self, forKey: .crop) ?? .identity
        curves = try c.decodeIfPresent(CurvesSettings.self, forKey: .curves) ?? .identity
        colorMixer = try c.decodeIfPresent(ColorMixerSettings.self, forKey: .colorMixer) ?? .identity
        dodgeBurn = try c.decodeIfPresent(DodgeBurnSettings.self, forKey: .dodgeBurn) ?? .identity
    }

    /// Curves, the colour mixer and the tone controls are written only when they change something, so recipes
    /// that do not use them keep exactly the bytes older versions wrote.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(filmID, forKey: .filmID)
        try c.encode(strength, forKey: .strength)
        try c.encode(exposure, forKey: .exposure)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(saturation, forKey: .saturation)
        try c.encode(warmth, forKey: .warmth)
        try c.encode(tint, forKey: .tint)
        try c.encode(grainAmount, forKey: .grainAmount)
        try c.encode(grainSize, forKey: .grainSize)
        try c.encode(halationAmount, forKey: .halationAmount)
        try c.encode(halationRadius, forKey: .halationRadius)
        try c.encode(bloomAmount, forKey: .bloomAmount)
        try c.encode(vignetteAmount, forKey: .vignetteAmount)
        try c.encode(borderEnabled, forKey: .borderEnabled)
        try c.encode(borderWidth, forKey: .borderWidth)
        try c.encode(version, forKey: .version)
        // Absent means the legacy pipeline, so legacy recipes keep exactly the bytes older versions wrote.
        if pipeline != Recipe.legacyPipeline { try c.encode(pipeline, forKey: .pipeline) }
        if push != 0 { try c.encode(push, forKey: .push) }
        if remJetRemoved { try c.encode(remJetRemoved, forKey: .remJetRemoved) }
        if scanProfile != .neutral { try c.encode(scanProfile, forKey: .scanProfile) }
        if paper != .none { try c.encode(paper, forKey: .paper) }
        if toning != .none {
            try c.encode(toning, forKey: .toning)
            try c.encode(toningStrength, forKey: .toningStrength)
        }
        if !raw.isIdentity { try c.encode(raw, forKey: .raw) }
        if let exposureTime { try c.encode(exposureTime, forKey: .exposureTime) }
        if reciprocity != .compensated { try c.encode(reciprocity, forKey: .reciprocity) }
        if reciprocityStrength != 1 { try c.encode(reciprocityStrength, forKey: .reciprocityStrength) }
        try c.encode(crop, forKey: .crop)
        if !curves.isIdentity { try c.encode(curves, forKey: .curves) }
        if !colorMixer.isIdentity { try c.encode(colorMixer, forKey: .colorMixer) }
        if !dodgeBurn.isIdentity { try c.encode(dodgeBurn, forKey: .dodgeBurn) }
        if highlights != 0 { try c.encode(highlights, forKey: .highlights) }
        if shadows != 0 { try c.encode(shadows, forKey: .shadows) }
        if whites != 0 { try c.encode(whites, forKey: .whites) }
        if blacks != 0 { try c.encode(blacks, forKey: .blacks) }
        if vibrance != 0 { try c.encode(vibrance, forKey: .vibrance) }
        if clarity != 0 { try c.encode(clarity, forKey: .clarity) }
        if texture != 0 { try c.encode(texture, forKey: .texture) }
    }

    /// True when any value that needs adjustment-data format version 2 is set.
    public var usesToneControls: Bool {
        highlights != 0 || shadows != 0 || whites != 0 || blacks != 0
            || vibrance != 0 || clarity != 0 || texture != 0
    }

    /// True when the recipe has dodge and burn strokes (adjustment-data format version 3).
    public var usesDodgeBurn: Bool { !dodgeBurn.isIdentity }

    /// JSON with sorted keys, so equal recipes produce equal bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Recipe {
        try JSONDecoder().decode(Recipe.self, from: data)
    }
}
