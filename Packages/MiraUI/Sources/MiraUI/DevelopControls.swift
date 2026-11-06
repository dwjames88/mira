import MiraCore
import SwiftUI

/// The DEVELOP panel's sections, named for what they do. Mac section labels and iOS chip groups both use these.
public enum DevelopSection: String, CaseIterable, Sendable {
    case light = "Light"
    case whiteBalance = "White balance"
    case color = "Color"
    case detail = "Detail"
    case lens = "Lens"
    case film = "Film"
    case frame = "Frame"

    public var title: String { rawValue }
}

/// A `Double?` setting shown as a slider: while the setting is nil ("as shot" / "Auto") the slider sits
/// at `fallback`, and moving it back onto `fallback` (which double-clicking the label does) clears it.
enum OptionalValue {
    static func binding(get: @escaping () -> Double?, set: @escaping (Double?) -> Void,
                        fallback: Double, tolerance: Double = 0.005) -> Binding<Double> {
        // Binding's closures are @Sendable in the macOS 26 SDK, but SwiftUI only calls them on the main
        // actor, which is where the caller's closures (which touch the editor model) live.
        nonisolated(unsafe) let get = get
        nonisolated(unsafe) let set = set
        return Binding(get: { get() ?? fallback },
                       set: { new in set(abs(new - fallback) <= tolerance ? nil : new) })
    }
}

/// Which camera-raw-decode controls to show for the open photo, each in its functional section. All false for
/// a photo that is not developed from a camera RAW; each optional one only when the decoder supports it.
public struct RawControlVisibility: Equatable, Sendable {
    public var isRaw: Bool
    /// LIGHT: tone-curve boost and highlight recovery (every RAW decoder has them).
    public var boost: Bool { isRaw }
    public var highlightRecovery: Bool { isRaw }
    public var localToneMap: Bool
    public var luminanceNoiseReduction: Bool
    public var colorNoiseReduction: Bool
    public var sharpness: Bool
    public var lensCorrection: Bool

    public init(isRaw: Bool, supported s: RawSupportedControls) {
        self.isRaw = isRaw
        localToneMap = isRaw && s.localToneMap
        luminanceNoiseReduction = isRaw && s.luminanceNoiseReduction
        colorNoiseReduction = isRaw && s.colorNoiseReduction
        sharpness = isRaw && s.sharpness
        lensCorrection = isRaw && s.lensCorrection
    }

    public static let none = RawControlVisibility(isRaw: false, supported: RawSupportedControls())
}

/// WHITE BALANCE: one temperature (kelvin) and tint pair for every photo.
///
/// - Camera RAW: drives the decoder (`recipe.raw.temperature` / `.tint`, nil = as shot); the slider rests on the
///   as-shot value and moving it back there clears the setting.
/// - Anything else: drives the pipeline balance (`recipe.warmth` / `.tint`) through `PipelineWhiteBalance`,
///   resting on 6500 K and tint 0.
///
/// "As shot" clears both, so pipeline warmth / tint left on a RAW recipe by an older edit or a preset goes too.
public struct WhiteBalanceControl: Equatable, Sendable {
    public let isRaw: Bool
    public let kelvinRange: ClosedRange<Double>
    public let kelvinDefault: Double
    public let tintRange: ClosedRange<Double>
    public let tintDefault: Double
    public static let kelvinSnap: Double = 50
    public static let tintSnap: Double = 1

    public init(isRaw: Bool, asShot: (temperature: Double, tint: Double)?) {
        self.isRaw = isRaw
        if isRaw {
            let k = (asShot?.temperature ?? 5500).rounded()
            kelvinRange = 2000...max(12000, (asShot?.temperature ?? 0).rounded(.up))
            kelvinDefault = k
            tintRange = RawSupportedControls.tintRange
            tintDefault = (asShot?.tint ?? 0).rounded()
        } else {
            kelvinRange = PipelineWhiteBalance.kelvinRange
            kelvinDefault = PipelineWhiteBalance.neutralKelvin
            tintRange = PipelineWhiteBalance.tintRange
            tintDefault = 0
        }
    }

    public func temperature(of r: Recipe) -> Double {
        isRaw ? (r.raw.temperature ?? kelvinDefault) : PipelineWhiteBalance.kelvin(warmth: r.warmth)
    }

    public func tint(of r: Recipe) -> Double {
        isRaw ? (r.raw.tint ?? tintDefault) : PipelineWhiteBalance.displayTint(r.tint)
    }

    public func setTemperature(_ k: Double, in r: inout Recipe) {
        if isRaw {
            r.raw.temperature = abs(k - kelvinDefault) <= Self.kelvinSnap / 2 ? nil : k
        } else {
            r.warmth = abs(k - kelvinDefault) <= Self.kelvinSnap / 2 ? 0 : PipelineWhiteBalance.warmth(kelvin: k)
        }
    }

    public func setTint(_ t: Double, in r: inout Recipe) {
        if isRaw {
            r.raw.tint = abs(t - tintDefault) <= Self.tintSnap / 2 ? nil : t
        } else {
            r.tint = abs(t - tintDefault) <= Self.tintSnap / 2 ? 0 : PipelineWhiteBalance.tint(display: t)
        }
    }

    /// True when "As shot" would change nothing.
    public func isAsShot(_ r: Recipe) -> Bool {
        r.raw.temperature == nil && r.raw.tint == nil && r.warmth == 0 && r.tint == 0
    }

    public func temperatureIsAsShot(_ r: Recipe) -> Bool { isRaw ? r.raw.temperature == nil : r.warmth == 0 }
    public func tintIsAsShot(_ r: Recipe) -> Bool { isRaw ? r.raw.tint == nil : r.tint == 0 }

    public static func resetToAsShot(_ r: inout Recipe) {
        r.raw.temperature = nil
        r.raw.tint = nil
        r.warmth = 0
        r.tint = 0
    }
}
