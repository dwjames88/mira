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
    /// The version written for a recipe that has no tone controls (kept for source compatibility).
    public static let formatVersion = baseFormatVersion

    public static func formatVersion(for recipe: Recipe) -> String {
        recipe.usesToneControls ? toneFormatVersion : baseFormatVersion
    }
    /// Identifiers written by the app's earlier name (Emulsion). Still readable so photos edited
    /// before the rename reopen with their recipe; never written.
    public static let legacyFormatIdentifiers: [String] = ["com.dwjames.emulsion"]
    /// Versions this build can read. Add to this set when the payload format changes compatibly.
    public static let supportedVersions: Set<String> = ["1", "2"]

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

    public static func adjustmentData(for recipe: Recipe) throws -> PHAdjustmentData {
        PHAdjustmentData(
            formatIdentifier: formatIdentifier,
            formatVersion: formatVersion(for: recipe),
            data: try encode(recipe)
        )
    }

    public static func recipe(from data: PHAdjustmentData) -> Recipe? {
        decode(formatIdentifier: data.formatIdentifier, formatVersion: data.formatVersion, data: data.data)
    }
}
