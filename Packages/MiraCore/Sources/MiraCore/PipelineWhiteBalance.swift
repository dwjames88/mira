import Foundation

/// The pipeline white balance (`Recipe.warmth` / `Recipe.tint`, applied before the film by `CITemperatureAndTint`)
/// in the units the WHITE BALANCE controls show: kelvin and tint, as for a camera RAW.
///
/// The renderer balances from a 6500 K neutral to `6500 - 1500 * warmth` K and tint `-40 * tint`, warmth and
/// tint each clamped to -1 ... 1. The control shows the light the photo is balanced for, so higher reads warmer
/// like the RAW temperature: `kelvin = 6500 + 1500 * warmth` (5000 ... 8000 K) and `tint = 40 * recipe.tint`
/// (-40 ... 40, positive = magenta, the same units as `RawSupportedControls.tintRange`).
public enum PipelineWhiteBalance {
    public static let neutralKelvin: Double = 6500
    /// Kelvin per unit of warmth.
    public static let kelvinPerWarmth: Double = 1500
    /// Tint units per unit of `Recipe.tint`.
    public static let tintPerUnit: Double = 40

    public static let kelvinRange: ClosedRange<Double> = (neutralKelvin - kelvinPerWarmth)...(neutralKelvin + kelvinPerWarmth)
    public static let tintRange: ClosedRange<Double> = -tintPerUnit...tintPerUnit

    public static func kelvin(warmth: Double) -> Double { neutralKelvin + kelvinPerWarmth * unit(warmth) }
    public static func warmth(kelvin: Double) -> Double { unit((kelvin - neutralKelvin) / kelvinPerWarmth) }
    public static func displayTint(_ tint: Double) -> Double { tintPerUnit * unit(tint) }
    public static func tint(display: Double) -> Double { unit(display / tintPerUnit) }

    /// The `CITemperatureAndTint` target neutral for a recipe (the neutral is `neutralKelvin`, tint 0).
    public static func targetNeutral(warmth: Double, tint: Double) -> (temperature: Double, tint: Double) {
        (neutralKelvin - kelvinPerWarmth * unit(warmth), -tintPerUnit * unit(tint))
    }

    private static func unit(_ v: Double) -> Double { v.isFinite ? min(max(v, -1), 1) : 0 }
}
