import Foundation
import MiraCore

/// User settings for the camera. Missing keys decode to defaults so older stores stay readable.
public struct CameraSettings: Sendable, Equatable, Codable {
    /// Suppress the shutter sound where the device allows it.
    public var silentShutter: Bool
    public var addLocation: Bool
    /// FINDER: LIVE (grain shimmers in the finder) or OFF.
    public var finderGrainLive: Bool
    public var finderQuality: FinderQualityMode
    public var lastFilmID: String?
    public var lastRecipe: Recipe?

    public init(
        silentShutter: Bool = false, addLocation: Bool = false, finderGrainLive: Bool = true,
        finderQuality: FinderQualityMode = .auto, lastFilmID: String? = nil, lastRecipe: Recipe? = nil
    ) {
        self.silentShutter = silentShutter
        self.addLocation = addLocation
        self.finderGrainLive = finderGrainLive
        self.finderQuality = finderQuality
        self.lastFilmID = lastFilmID
        self.lastRecipe = lastRecipe
    }

    private enum CodingKeys: String, CodingKey {
        case silentShutter, addLocation, finderGrainLive, finderQuality, lastFilmID, lastRecipe
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        silentShutter = try c.decodeIfPresent(Bool.self, forKey: .silentShutter) ?? false
        addLocation = try c.decodeIfPresent(Bool.self, forKey: .addLocation) ?? false
        finderGrainLive = try c.decodeIfPresent(Bool.self, forKey: .finderGrainLive) ?? true
        finderQuality = try c.decodeIfPresent(FinderQualityMode.self, forKey: .finderQuality) ?? .auto
        lastFilmID = try c.decodeIfPresent(String.self, forKey: .lastFilmID)
        lastRecipe = try c.decodeIfPresent(Recipe.self, forKey: .lastRecipe)
    }
}

/// Persists `CameraSettings` as one JSON blob in `UserDefaults`.
// `UserDefaults` is documented thread-safe, so sharing it is safe.
public struct CameraSettingsStore: @unchecked Sendable {
    public static let defaultKey = "mira.camera.settings"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = CameraSettingsStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    /// The stored settings, or defaults when nothing (or something unreadable) is stored.
    public func load() -> CameraSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(CameraSettings.self, from: data) else { return CameraSettings() }
        return settings
    }

    public func save(_ settings: CameraSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
