#if os(macOS)
import Foundation
import MiraCore

extension EditorModel {
    /// The exposure-time control is offered whenever a film is selected.
    public var showsReciprocityControls: Bool { selectedFilm != nil }

    /// The photo's EXIF exposure time in seconds; nil for a file without one.
    public var sourceExposureTime: Double? { source?.miraExposureTime }

    /// The time the film is exposed for: the recipe's own, else the photo's EXIF value.
    public var effectiveExposureTime: Double? { recipe.exposureTime ?? sourceExposureTime }

    /// What the exposure time does to the selected film; nil when reciprocity is off, the recipe is on the legacy
    /// pipeline, there is no time, or the effect is nil at that time.
    public var reciprocityEffect: ReciprocityEffect? {
        Reciprocity.effect(for: recipe, film: selectedFilm, sourceExposureTime: sourceExposureTime)
    }

    /// "\u{2212}1\u{2153} stops (compensated) \u{00B7} cast G +0.12 st \u{00B7} contrast +7 % \u{00B7} shadow grain +38 %",
    /// or "No change at this speed" (plus "beyond datasheet" in `reciprocityExtrapolated`).
    public var reciprocityReadout: String? {
        ReciprocityFormat.summary(recipe: recipe, film: selectedFilm, sourceExposureTime: sourceExposureTime)?.text
    }
    public var reciprocityExtrapolated: Bool {
        ReciprocityFormat.summary(recipe: recipe, film: selectedFilm, sourceExposureTime: sourceExposureTime)?.beyondDatasheet ?? false
    }

    /// Slider position (log2 of seconds) of the effective time; 1/125 s with no time at all.
    public var exposureTimeSliderValue: Double { log2(effectiveExposureTime ?? ExposureTimeFormat.neutral) }

    /// Sets the time from a slider position: snapped to the nearest standard shutter speed. The standard speed
    /// nearest the EXIF value (1/125 s without EXIF) counts as "no override" (nil), so the reset position and the
    /// slider agree.
    public func setExposureTime(sliderValue v: Double) {
        let t = ExposureTimeFormat.standard(nearestTo: exp2(v))
        let unchanged: Double = sourceExposureTime.map { ExposureTimeFormat.standard(nearestTo: $0) } ?? ExposureTimeFormat.neutral
        let newValue: Double? = t == unchanged ? nil : t
        if recipe.exposureTime != newValue { recipe.exposureTime = newValue }
    }

    /// Back to the photo's EXIF time (double-click on the control).
    public func resetExposureTime() { recipe.exposureTime = nil }

    /// The readout beside the slider: "1/250 s \u{00B7} EXIF", "No EXIF", or the chosen time.
    public var exposureTimeReadout: String {
        if let t = recipe.exposureTime { return ExposureTimeFormat.label(t) }
        if let t = sourceExposureTime { return ExposureTimeFormat.label(t) + " \u{00B7} EXIF" }
        return "No EXIF"
    }
}
#endif
