import AppKit

/// The user's appearance choice, stored under `mira.appearance` (`"system"` by default). Shared by the
/// app (Settings, View menu, toolbar toggle) and the Photos extension, which reads it from its own
/// defaults container and otherwise inherits Photos' appearance.
public enum AppearancePreference: String, CaseIterable, Sendable {
    case system, light, dark

    public static let key = "mira.appearance"

    /// The `NSAppearance` to force, or nil to follow the system.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Unknown or missing values mean System.
    public init(storedValue: String?) {
        self = storedValue.flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }

    /// What the toolbar toggle switches to: Light when the effective appearance is dark, else Dark.
    public static func next(toggleFrom effectiveIsDark: Bool) -> AppearancePreference {
        effectiveIsDark ? .light : .dark
    }

    /// The preference stored in `defaults`, or nil if none was ever set (the extension case).
    public static func stored(in defaults: UserDefaults = .standard) -> AppearancePreference? {
        defaults.string(forKey: key).flatMap(AppearancePreference.init(rawValue:))
    }
}

extension NSAppearance {
    /// True when this appearance resolves to dark aqua.
    public var isDarkAqua: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
