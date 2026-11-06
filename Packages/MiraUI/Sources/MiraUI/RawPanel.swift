#if os(macOS)
import MiraCore
import SwiftUI

private typealias T = FieldFramesTheme

extension EditorModel {
    var rawControlVisibility: RawControlVisibility {
        RawControlVisibility(isRaw: isRawSource, supported: rawSupportedControls)
    }
}

/// One camera-raw-decode slider, shown inside the Develop section its function belongs to. A nil setting reads
/// "Auto" and the slider rests on `fallback`.
struct RawSliderSpec: Identifiable, @unchecked Sendable {
    let id: String
    let label: String
    let keyPath: WritableKeyPath<RawSettings, Double?>
    let range: ClosedRange<Double>
    let fallback: @Sendable (Recipe) -> Double
    let help: String?
    let isShown: @Sendable (RawControlVisibility) -> Bool

    init(_ id: String, _ label: String, _ keyPath: WritableKeyPath<RawSettings, Double?>,
         _ range: ClosedRange<Double>, fallback: @escaping @Sendable (Recipe) -> Double = { _ in 0 },
         help: String? = nil, isShown: @escaping @Sendable (RawControlVisibility) -> Bool) {
        self.id = id
        self.label = label
        self.keyPath = keyPath
        self.range = range
        self.fallback = fallback
        self.help = help
        self.isShown = isShown
    }

    static let boost = RawSliderSpec(
        "boost", "Boost", \.boostAmount, RawSupportedControls.boostRange,
        fallback: { $0.filmID == nil ? 0.5 : 0 },
        help: "Tone-curve boost from the camera raw decode; Auto leaves it to the film", isShown: \.boost)
    static let highlightRecovery = RawSliderSpec(
        "highlightRecovery", "Highlight recovery", \.extendedDynamicRangeAmount,
        RawSupportedControls.extendedDynamicRange, isShown: \.highlightRecovery)
    static let localToneMap = RawSliderSpec(
        "localToneMap", "Local tone map", \.localToneMapAmount, RawSupportedControls.unitRange,
        isShown: \.localToneMap)
    static let sharpness = RawSliderSpec(
        "sharpness", "Sharpness", \.sharpnessAmount, RawSupportedControls.unitRange, isShown: \.sharpness)
    static let luminanceNoise = RawSliderSpec(
        "luminanceNoise", "Luminance noise", \.luminanceNoiseReductionAmount, RawSupportedControls.unitRange,
        isShown: \.luminanceNoiseReduction)
    static let colorNoise = RawSliderSpec(
        "colorNoise", "Color noise", \.colorNoiseReductionAmount, RawSupportedControls.unitRange,
        isShown: \.colorNoiseReduction)
}

/// The camera-raw-decode sliders of one Develop section that the open photo supports.
struct RawSliders: View {
    @Bindable var model: EditorModel
    let specs: [RawSliderSpec]

    var body: some View {
        let show = model.rawControlVisibility
        let recipe = model.recipe
        ForEach(specs.filter { $0.isShown(show) }) { spec in
            let fallback = spec.fallback(recipe)
            let setting = recipe.raw[keyPath: spec.keyPath]
            RecipeSlider(label: spec.label, shown: setting ?? fallback, range: spec.range, defaultValue: fallback,
                         isAuto: setting == nil, context: spec.id.hashValue,
                         get: { model.recipe.raw[keyPath: spec.keyPath] ?? fallback },
                         set: { new in
                             model.recipe.raw[keyPath: spec.keyPath] = abs(new - fallback) <= 0.005 ? nil : new
                         })
                .equatable()
                .help(spec.help ?? "")
        }
    }
}

/// LATITUDE under the histogram: the stops the film records either side of a normal exposure, and how much
/// of this frame falls outside them (lichen when over 1%).
struct LatitudeReadout: View {
    @Bindable var model: EditorModel

    var body: some View {
        if let film = model.selectedFilm {
            let c = film.resolvedCharacter
            let r = model.latitudeReading
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: T.cells(1)) {
                    Text("Latitude").ffLabel(color: T.paperDim)
                    Text(LatitudeFormat.range(under: c.latitudeUnder, over: c.latitudeOver) + " stops")
                        .ffLabel(color: T.paper)
                }
                .frame(height: T.rows(1))
                if let r {
                    HStack(spacing: T.cells(1)) {
                        Text("Under \(LatitudeFormat.percent(r.under))")
                            .ffLabel(color: LatitudeFormat.isFlagged(r.under) ? T.lichen : T.paperDim)
                        Text("\u{00B7}").ffLabel(color: T.paperDim)
                        Text("Over \(LatitudeFormat.percent(r.over))")
                            .ffLabel(color: LatitudeFormat.isFlagged(r.over) ? T.lichen : T.paperDim)
                    }
                    .frame(height: T.rows(1))
                }
            }
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The one-line version for the FILMS panel: "-2 / +3 . 12% OVER".
struct LatitudeCompact: View {
    @Bindable var model: EditorModel

    var body: some View {
        if let film = model.selectedFilm {
            let c = film.resolvedCharacter
            let flag = model.latitudeReading.flatMap(LatitudeFormat.compact)
            HStack(spacing: T.cells(1)) {
                Text("Latitude").ffLabel(color: T.paperDim)
                Text(LatitudeFormat.range(under: c.latitudeUnder, over: c.latitudeOver)).ffLabel(color: T.paper)
                if let flag {
                    Text("\u{00B7}").ffLabel(color: T.paperDim)
                    Text(flag).ffLabel(color: T.lichen)
                }
            }
            .frame(height: T.rows(1))
            .accessibilityElement(children: .combine)
        }
    }
}
#endif
