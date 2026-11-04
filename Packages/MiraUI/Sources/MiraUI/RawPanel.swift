import MiraCore
import SwiftUI

private typealias T = FieldFramesTheme

/// A `Double?` setting shown as a slider: while the setting is nil ("as shot" / "Auto") the slider sits
/// at `fallback`, and moving it back onto `fallback` (which double-clicking the label does) clears it.
enum OptionalValue {
    static func binding(get: @escaping () -> Double?, set: @escaping (Double?) -> Void,
                        fallback: Double, tolerance: Double = 0.005) -> Binding<Double> {
        Binding(get: { get() ?? fallback },
                set: { new in set(abs(new - fallback) <= tolerance ? nil : new) })
    }
}

/// Which RAW controls to show for the open photo.
struct RawControlVisibility: Equatable {
    var isRaw: Bool
    var localToneMap: Bool
    var luminanceNoiseReduction: Bool
    var colorNoiseReduction: Bool
    var sharpness: Bool
    var lensCorrection: Bool

    init(isRaw: Bool, supported s: RawSupportedControls) {
        self.isRaw = isRaw
        localToneMap = isRaw && s.localToneMap
        luminanceNoiseReduction = isRaw && s.luminanceNoiseReduction
        colorNoiseReduction = isRaw && s.colorNoiseReduction
        sharpness = isRaw && s.sharpness
        lensCorrection = isRaw && s.lensCorrection
    }
}

extension EditorModel {
    var rawControlVisibility: RawControlVisibility {
        RawControlVisibility(isRaw: isRawSource, supported: rawSupportedControls)
    }
}

/// DEVELOP > RAW: white balance, boost, highlight recovery, local tone map, noise reduction, sharpness
/// and lens correction. Only for camera RAW files; each control only when the decoder supports it.
struct RawGroup: View {
    @Bindable var model: EditorModel

    private func slider(_ label: String, _ kp: WritableKeyPath<RawSettings, Double?>, range: ClosedRange<Double>,
                        fallback: Double, decimals: Int = 2, snap: Double? = nil, autoText: String? = nil,
                        help: String? = nil) -> some View {
        let binding = OptionalValue.binding(
            get: { model.recipe.raw[keyPath: kp] }, set: { model.recipe.raw[keyPath: kp] = $0 },
            fallback: fallback, tolerance: snap.map { $0 / 2 } ?? 0.005)
        let isNil = model.recipe.raw[keyPath: kp] == nil
        return FFSlider(label, value: binding, in: range, default: fallback, decimals: decimals, snap: snap,
                        format: autoText.flatMap { text in isNil ? { _ in text } : nil })
            .help(help ?? "")
    }

    var body: some View {
        let show = model.rawControlVisibility
        if show.isRaw {
            let asShot = model.rawAsShot
            let kelvinTop = max(12000, (asShot?.temperature ?? 0).rounded(.up))
            VStack(alignment: .leading, spacing: 0) {
                FFSectionLabel("RAW", trailing: nil).padding(.top, T.rows(1)).padding(.bottom, 4)
                slider("Temperature (K)", \.temperature, range: 2000...kelvinTop,
                       fallback: (asShot?.temperature ?? 5500).rounded(), decimals: 0, snap: 50,
                       help: "White balance in kelvin; the as-shot value until you change it")
                slider("Tint", \.tint, range: RawSupportedControls.tintRange,
                       fallback: (asShot?.tint ?? 0).rounded(), decimals: 0, snap: 1)
                HStack {
                    Spacer()
                    Button("As Shot") {
                        model.recipe.raw.temperature = nil
                        model.recipe.raw.tint = nil
                    }
                    .buttonStyle(.ff)
                    .disabled(model.recipe.raw.temperature == nil && model.recipe.raw.tint == nil)
                    .help("Back to the camera's white balance")
                }
                .padding(.bottom, 8)
                slider("Boost", \.boostAmount, range: RawSupportedControls.boostRange,
                       fallback: model.recipe.filmID == nil ? 0.5 : 0, autoText: "Auto",
                       help: "Tone-curve boost; Auto leaves it to the film")
                slider("Highlight recovery", \.extendedDynamicRangeAmount,
                       range: RawSupportedControls.extendedDynamicRange, fallback: 0, autoText: "Auto")
                if show.localToneMap {
                    slider("Local tone map", \.localToneMapAmount, range: RawSupportedControls.unitRange,
                           fallback: 0, autoText: "Auto")
                }
                if show.luminanceNoiseReduction {
                    slider("Luminance noise", \.luminanceNoiseReductionAmount, range: RawSupportedControls.unitRange,
                           fallback: 0, autoText: "Auto")
                }
                if show.colorNoiseReduction {
                    slider("Color noise", \.colorNoiseReductionAmount, range: RawSupportedControls.unitRange,
                           fallback: 0, autoText: "Auto")
                }
                if show.sharpness {
                    slider("Sharpness", \.sharpnessAmount, range: RawSupportedControls.unitRange,
                           fallback: 0, autoText: "Auto")
                }
                if show.lensCorrection {
                    FFToggle("Lens correction", isOn: Binding(
                        get: { model.recipe.raw.lensCorrection ?? false },
                        set: { model.recipe.raw.lensCorrection = $0 }))
                        .padding(.bottom, 8)
                }
            }
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
