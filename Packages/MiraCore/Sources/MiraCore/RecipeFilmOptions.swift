import Foundation

/// Post-film "scan" rendering: how the lab scanner interprets the developed film. Our own small
/// tone and colour transforms (pipeline 2 only), not copies of any scanner's output.
public enum ScanProfile: String, Codable, CaseIterable, Sendable {
    case neutral
    /// Cooler, punchier, slightly lifted blacks.
    case frontier
    /// Warmer, flatter, softer highlights.
    case noritsu

    public var displayName: String {
        switch self {
        case .neutral: "Neutral"
        case .frontier: "Frontier-like"
        case .noritsu: "Noritsu-like"
        }
    }
}

/// Black-and-white print toning (split-toned tint after the film; pipeline 2, monochrome films).
public enum Toning: String, Codable, CaseIterable, Sendable {
    case none, selenium, sepia, cyanotype, copper

    public var displayName: String {
        switch self {
        case .none: "None"
        case .selenium: "Selenium"
        case .sepia: "Sepia"
        case .cyanotype: "Cyanotype"
        case .copper: "Copper"
        }
    }
}

/// Camera RAW decode settings (`CIRAWFilter`). nil means "the decoder's default / as shot", so an
/// empty value changes nothing. Only used when the source is a RAW file.
///
/// Presets carry the look-related values (boost, tone mapping, extended dynamic range) but not the
/// per-shot or per-camera ones (white balance in kelvin, noise reduction, sharpening, lens
/// correction, moiré): see `presetPortion`.
public struct RawSettings: Codable, Hashable, Sendable {
    /// White balance in kelvin and tint; nil = as shot.
    public var temperature: Double?
    public var tint: Double?
    /// Tone-curve boost, 0 (linear, scene-referred) ... 1 (camera look). nil = automatic: 0 when a
    /// film is applied (the film supplies the curve), the decoder default otherwise.
    public var boostAmount: Double?
    public var localToneMapAmount: Double?
    public var extendedDynamicRangeAmount: Double?
    public var shadowBias: Double?
    public var luminanceNoiseReductionAmount: Double?
    public var colorNoiseReductionAmount: Double?
    public var sharpnessAmount: Double?
    public var detailAmount: Double?
    public var moireReductionAmount: Double?
    public var lensCorrection: Bool?

    public static let identity = RawSettings()

    public init(temperature: Double? = nil, tint: Double? = nil, boostAmount: Double? = nil,
                localToneMapAmount: Double? = nil, extendedDynamicRangeAmount: Double? = nil,
                shadowBias: Double? = nil, luminanceNoiseReductionAmount: Double? = nil,
                colorNoiseReductionAmount: Double? = nil, sharpnessAmount: Double? = nil,
                detailAmount: Double? = nil, moireReductionAmount: Double? = nil, lensCorrection: Bool? = nil) {
        self.temperature = temperature
        self.tint = tint
        self.boostAmount = boostAmount
        self.localToneMapAmount = localToneMapAmount
        self.extendedDynamicRangeAmount = extendedDynamicRangeAmount
        self.shadowBias = shadowBias
        self.luminanceNoiseReductionAmount = luminanceNoiseReductionAmount
        self.colorNoiseReductionAmount = colorNoiseReductionAmount
        self.sharpnessAmount = sharpnessAmount
        self.detailAmount = detailAmount
        self.moireReductionAmount = moireReductionAmount
        self.lensCorrection = lensCorrection
    }

    public var isIdentity: Bool { self == .identity }

    /// The part of the settings a preset keeps.
    public var presetPortion: RawSettings {
        RawSettings(boostAmount: boostAmount, localToneMapAmount: localToneMapAmount,
                    extendedDynamicRangeAmount: extendedDynamicRangeAmount)
    }
}
