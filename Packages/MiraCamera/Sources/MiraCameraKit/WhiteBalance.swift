import Foundation

/// White balance chips: the light the film "sees".
public enum WhiteBalancePreset: String, Sendable, Codable, CaseIterable, Equatable {
    case auto, daylight, cloudy, tungsten, fluorescent

    /// Color temperature in Kelvin; nil for auto.
    public var kelvin: Int? {
        switch self {
        case .auto: nil
        case .daylight: 5500
        case .cloudy: 6500
        case .tungsten: 3200
        case .fluorescent: 4000
        }
    }

    /// Chip text, mono caps.
    public var label: String {
        switch self {
        case .auto: "AUTO"
        case .daylight: "DAYLIGHT 5500"
        case .cloudy: "CLOUDY 6500"
        case .tungsten: "TUNGSTEN 3200"
        case .fluorescent: "FLUOR. 4000"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .auto: "Auto white balance"
        case .daylight: "Daylight, 5500 Kelvin"
        case .cloudy: "Cloudy, 6500 Kelvin"
        case .tungsten: "Tungsten, 3200 Kelvin"
        case .fluorescent: "Fluorescent, 4000 Kelvin"
        }
    }
}

/// A preset plus the lock-to-current-value toggle.
public struct WhiteBalanceState: Sendable, Equatable {
    public var preset: WhiteBalancePreset
    /// Holds the current value (for auto: the value at the moment of locking).
    public var locked: Bool

    public init(preset: WhiteBalancePreset = .auto, locked: Bool = false) {
        self.preset = preset
        self.locked = locked
    }

    /// True when the device should be in locked white balance (a fixed preset, or auto with the lock on).
    public var isFixed: Bool { preset != .auto || locked }
}
