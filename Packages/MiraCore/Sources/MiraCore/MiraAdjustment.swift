import Foundation
import Photos

/// The one place that knows how a `Recipe` is stored as Photos adjustment data. Both the app
/// and the Photos extension use it.
public enum MiraAdjustment {
    public static let formatIdentifier = "com.fieldframes.mira"
    /// Version of the original payload (no highlights, shadows, whites, blacks, vibrance, clarity, texture).
    public static let baseFormatVersion = "1"
    /// Written when the recipe uses the tone controls. Older builds refuse it, so they never
    /// open an edit they would render without those controls.
    public static let toneFormatVersion = "2"
    /// Written when the recipe has dodge and burn strokes. Builds that do not know them refuse it.
    public static let dodgeBurnFormatVersion = "3"
    /// Written when the recipe uses the film-science pipeline (`Recipe.pipeline` 2 or later), which
    /// renders differently from every earlier build. Older builds refuse it, so they never open an
    /// edit they would render with the wrong pipeline.
    public static let filmScienceFormatVersion = "4"
    /// The version written for a recipe that has no tone controls (kept for source compatibility).
    public static let formatVersion = baseFormatVersion

    public static func formatVersion(for recipe: Recipe) -> String {
        if recipe.pipeline >= 2 || recipe.usesFilmScienceControls { return filmScienceFormatVersion }
        if recipe.usesDodgeBurn { return dodgeBurnFormatVersion }
        return recipe.usesToneControls ? toneFormatVersion : baseFormatVersion
    }
    /// Identifiers written by the app's earlier name (Emulsion). Still readable so photos edited
    /// before the rename reopen with their recipe; never written.
    public static let legacyFormatIdentifiers: [String] = ["com.dwjames.emulsion"]
    /// Versions this build can read. Add to this set when the payload format changes compatibly.
    public static let supportedVersions: Set<String> = ["1", "2", "3", "4"]

    public static func canHandle(formatIdentifier: String, formatVersion: String) -> Bool {
        (formatIdentifier == Self.formatIdentifier || legacyFormatIdentifiers.contains(formatIdentifier))
            && supportedVersions.contains(formatVersion)
    }

    public static func canHandle(_ data: PHAdjustmentData) -> Bool {
        canHandle(formatIdentifier: data.formatIdentifier, formatVersion: data.formatVersion)
    }

    /// Deterministic JSON for the recipe.
    public static func encode(_ recipe: Recipe) throws -> Data {
        try recipe.encoded()
    }

    /// nil when the identifier/version is not ours or the payload cannot be decoded.
    public static func decode(formatIdentifier: String, formatVersion: String, data: Data) -> Recipe? {
        guard canHandle(formatIdentifier: formatIdentifier, formatVersion: formatVersion) else { return nil }
        return try? Recipe.decode(data)
    }

    public static func adjustmentData(for recipe: Recipe, rawBase: Bool = false) throws -> PHAdjustmentData {
        PHAdjustmentData(
            formatIdentifier: formatIdentifier,
            formatVersion: formatVersion(for: recipe),
            data: rawBase ? try encodeMarkingRawBase(recipe) : try encode(recipe)
        )
    }

    // MARK: RAW base

    /// Top-level key added to the payload of an edit made on the RAW original (not on the rendered
    /// JPEG of a RAW+JPEG pair). `Recipe` decoding ignores it, so every build still reads the recipe;
    /// only builds that know the key rebuild the edit on the RAW.
    static let rawBaseKey = "miraBase"
    static let rawBaseValue = "raw"

    static func encodeMarkingRawBase(_ recipe: Recipe) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: encode(recipe)) as? [String: Any] ?? [:]
        object[rawBaseKey] = rawBaseValue
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// True when `payload` (the adjustment data bytes) was written for a RAW base.
    public static func isRawBase(payload: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return false }
        return object[rawBaseKey] as? String == rawBaseValue
    }

    public static func isRawBase(_ data: PHAdjustmentData) -> Bool { isRawBase(payload: data.data) }

    /// What the asset's adjustment data means for opening it.
    public static func state(of data: PHAdjustmentData?) -> AssetAdjustmentState {
        guard let data else { return .none }
        return recipe(from: data) != nil ? .mira(rawBase: isRawBase(data)) : .foreign
    }

    /// For the Photos extension: it is only given the rendered JPEG of a RAW+JPEG pair, so it cannot
    /// continue an edit that was made on the RAW. Declining makes Photos hand it the rendered result.
    public static func canHandleInExtension(_ data: PHAdjustmentData) -> Bool {
        canHandle(data) && !isRawBase(data)
    }

    public static func recipe(from data: PHAdjustmentData) -> Recipe? {
        decode(formatIdentifier: data.formatIdentifier, formatVersion: data.formatVersion, data: data.data)
    }
}
