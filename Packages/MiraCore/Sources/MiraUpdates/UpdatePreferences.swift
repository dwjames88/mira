import Foundation

/// The updater's persisted state: the automatic-check switch, when it last ran, and the skipped version.
public struct UpdatePreferences: @unchecked Sendable {
    /// Also used by `@AppStorage` in Settings (MiraUI keeps a copy of this string in `MiraSettings`).
    public static let autoCheckKey = "mira.updates.autoCheck"
    public static let lastCheckKey = "mira.updates.lastCheck"
    public static let skippedVersionKey = "mira.updates.skippedVersion"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// On unless the user turned it off.
    public var automaticChecksEnabled: Bool {
        get { defaults.object(forKey: Self.autoCheckKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.autoCheckKey) }
    }

    public var lastCheck: Date? {
        get { defaults.object(forKey: Self.lastCheckKey) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Self.lastCheckKey) }
    }

    public var skippedVersion: SemanticVersion? {
        get { defaults.string(forKey: Self.skippedVersionKey).flatMap(SemanticVersion.init) }
        nonmutating set {
            if let newValue { defaults.set(newValue.description, forKey: Self.skippedVersionKey) }
            else { defaults.removeObject(forKey: Self.skippedVersionKey) }
        }
    }
}
