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

    public static let neutral = Recipe()

    public init(
        filmID: String? = nil,
        strength: Double = 1,
        exposure: Double = 0,
        contrast: Double = 0,
        saturation: Double = 0,
        warmth: Double = 0,
        tint: Double = 0,
        grainAmount: Double = 0,
        grainSize: Double = 0.5,
        halationAmount: Double = 0,
        halationRadius: Double = 0.5,
        bloomAmount: Double = 0,
        vignetteAmount: Double = 0,
        borderEnabled: Bool = false,
        borderWidth: Double = 0.04,
        version: Int = 1,
        crop: CropSettings = .identity
    ) {
        self.filmID = filmID
        self.strength = strength
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
        self.tint = tint
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
    }

    private enum CodingKeys: String, CodingKey {
        case filmID, strength, exposure, contrast, saturation, warmth, tint
        case grainAmount, grainSize, halationAmount, halationRadius, bloomAmount
        case vignetteAmount, borderEnabled, borderWidth, version, crop
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
