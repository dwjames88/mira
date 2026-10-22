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
    /// Crop, rotation, flips and straighten; identity by default.
    public var crop: CropSettings
    /// Tone curves (RGB, red, green, blue, luminance); identity by default.
    public var curves: CurvesSettings
    /// Per-hue-range hue, saturation and luminance; identity by default.
    public var colorMixer: ColorMixerSettings

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
        crop: CropSettings = .identity,
        curves: CurvesSettings = .identity,
        colorMixer: ColorMixerSettings = .identity
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
        self.crop = crop
        self.curves = curves
        self.colorMixer = colorMixer
    }

    private enum CodingKeys: String, CodingKey {
        case filmID, strength, exposure, contrast, saturation, warmth, tint
        case grainAmount, grainSize, halationAmount, halationRadius, bloomAmount
        case vignetteAmount, borderEnabled, borderWidth, version, crop, curves, colorMixer
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
        crop = try c.decodeIfPresent(CropSettings.self, forKey: .crop) ?? .identity
        curves = try c.decodeIfPresent(CurvesSettings.self, forKey: .curves) ?? .identity
        colorMixer = try c.decodeIfPresent(ColorMixerSettings.self, forKey: .colorMixer) ?? .identity
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
        try c.encode(crop, forKey: .crop)
        if !curves.isIdentity { try c.encode(curves, forKey: .curves) }
        if !colorMixer.isIdentity { try c.encode(colorMixer, forKey: .colorMixer) }
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
