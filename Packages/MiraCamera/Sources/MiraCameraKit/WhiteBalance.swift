import Foundation

/// Named colour temperatures the Kelvin dial snaps to and names in its readout.
public enum WhiteBalancePreset: String, Sendable, Codable, CaseIterable, Equatable {
    case tungsten, fluorescent, daylight, cloudy

    public var kelvin: Int {
        switch self {
        case .tungsten: 3200
        case .fluorescent: 4000
        case .daylight: 5500
        case .cloudy: 6500
        }
    }

    /// Mono caps name shown beside the value.
    public var name: String {
        switch self {
        case .tungsten: "TUNGSTEN"
        case .fluorescent: "FLUORESCENT"
        case .daylight: "DAYLIGHT"
        case .cloudy: "CLOUDY"
        }
    }
}

/// The white balance request: nil is AUTO (continuous auto white balance); a value locks the device at that
/// temperature (tint 0).
public struct WhiteBalanceState: Sendable, Equatable {
    public var kelvin: Int? {
        didSet { if let k = kelvin, k != WhiteBalanceModel.clamp(k) { kelvin = WhiteBalanceModel.clamp(k) } }
    }

    public init(kelvin: Int? = nil) {
        self.kelvin = kelvin.map(WhiteBalanceModel.clamp)
    }

    public var isAuto: Bool { kelvin == nil }
}

/// Pure rules for the Kelvin dial.
public enum WhiteBalanceModel {
    public static let range = 2500...9000
    /// One dial step.
    public static let step = 100
    /// Where a drag or a tap on AUTO starts from.
    public static let startKelvin = 5500
    /// A drag that ends this close to a preset snaps to it.
    public static let snapRadius = 150

    public static func clamp(_ kelvin: Int) -> Int { min(max(kelvin, range.lowerBound), range.upperBound) }

    /// Rounds to a dial step and clamps.
    public static func quantised(_ kelvin: Int) -> Int {
        clamp(Int((Double(kelvin) / Double(step)).rounded()) * step)
    }

    /// The preset within `snapRadius` of `kelvin` (the nearest), if any.
    public static func detent(near kelvin: Int) -> WhiteBalancePreset? {
        WhiteBalancePreset.allCases
            .filter { abs($0.kelvin - kelvin) <= snapRadius }
            .min { abs($0.kelvin - kelvin) < abs($1.kelvin - kelvin) }
    }

    /// The value a drag ends on: the nearby preset's temperature, else the clamped value.
    public static func snapped(_ kelvin: Int) -> Int { detent(near: kelvin)?.kelvin ?? clamp(kelvin) }

    /// The preset a value is exactly on, for the readout.
    public static func preset(at kelvin: Int) -> WhiteBalancePreset? { WhiteBalancePreset.allCases.first { $0.kelvin == kelvin } }

    /// "5500 K · DAYLIGHT", or "5600 K" away from a preset.
    public static func readout(_ kelvin: Int) -> String {
        preset(at: kelvin).map { "\(kelvin) K \u{00B7} \($0.name)" } ?? "\(kelvin) K"
    }
}
