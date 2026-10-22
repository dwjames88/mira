import MiraCore
import SwiftUI

private typealias T = FieldFramesTheme

// MARK: Sliders

struct SliderSpec: Identifiable {
    let id: String
    let label: String
    let keyPath: WritableKeyPath<Recipe, Double>
    let range: ClosedRange<Double>
    let defaultValue: Double

    init(_ id: String, _ label: String, _ keyPath: WritableKeyPath<Recipe, Double>,
         _ range: ClosedRange<Double>, default defaultValue: Double) {
        self.id = id
        self.label = label
        self.keyPath = keyPath
        self.range = range
        self.defaultValue = defaultValue
    }
}

struct SliderGroup: Identifiable {
    let title: String
    let specs: [SliderSpec]
    var id: String { title }
}

private struct SpecSliders: View {
    @Bindable var model: EditorModel
    let specs: [SliderSpec]

    var body: some View {
        ForEach(specs) { spec in
            FFSlider(spec.label,
                     value: Binding(get: { model.recipe[keyPath: spec.keyPath] },
                                    set: { model.recipe[keyPath: spec.keyPath] = $0 }),
                     in: spec.range, default: spec.defaultValue)
        }
    }
}

// MARK: Films

/// FILMS: the selected film's header (name, brand, ISO, family, description) and its STRENGTH.
struct FilmsPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, T.cells(2))
                .padding(.top, T.rows(2))
                .padding(.bottom, T.rows(1))
            FFHairline()
            VStack(alignment: .leading, spacing: 0) {
                SpecSliders(model: model, specs: [SliderSpec("strength", "Strength", \.strength, 0...1, default: 1)])
                    .padding(.top, T.rows(1))
            }
            .padding(.horizontal, T.cells(2))
            Spacer(minLength: 0)
        }
        .ffPanel()
    }

    /// Fixed-height header: name (one line), meta label (one line), description (three lines). The
    /// height is the same for Original and every film, so the slider below never shifts.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.selectedFilm?.displayName ?? "Original")
                .font(T.display(26, weight: .medium))
                .foregroundStyle(T.paper)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: T.rows(2), alignment: .leading)
            Text(metaLine)
                .ffLabel(color: T.lichen)
                .lineLimit(1)
                .frame(height: T.rows(1), alignment: .leading)
            // Reserved even when the picture is not cropped, so the header never changes height.
            Text(cropLine ?? " ")
                .ffLabel(color: T.paperDim)
                .lineLimit(1)
                .frame(height: T.rows(1), alignment: .leading)
                .accessibilityHidden(cropLine == nil)
            Text(descriptionText)
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(T.paperMid)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: Self.descriptionHeight, maxHeight: Self.descriptionHeight,
                       alignment: .topLeading)
                .padding(.top, 6)
        }
    }

    /// Three lines of 12 pt text with 2 pt line spacing.
    private static let descriptionHeight: CGFloat = T.rows(3) + 4

    private var metaLine: String {
        guard let film = model.selectedFilm else { return "No film \u{00B7} source image" }
        let iso = film.iso > 0 ? "ISO \(film.iso)" : nil
        return [film.brand, iso, film.family.displayName].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// `CROP · 3:2 · 4.2°`, nil when the committed crop is the identity.
    private var cropLine: String? { CropSummary.line(for: model.recipe.crop) }

    private var descriptionText: String {
        model.selectedFilm?.description ?? "The photograph as it was taken. Choose a film from the strip to grade it."
    }
}

enum CropSummary {
    static func line(for c: CropSettings, label: Bool = true) -> String? {
        guard !c.isIdentity else { return nil }
        var parts = label ? ["Crop"] : []
        if !c.rect.isFull { parts.append(c.aspect == CropAspect.free ? "Free" : CropAspect.label(c.aspect)) }
        if abs(c.straighten) > 1e-9 {
            parts.append(c.straighten.formatted(.number.precision(.fractionLength(1))) + "\u{00B0}")
        }
        if c.normalizedQuarterTurns != 0 { parts.append("\(c.normalizedQuarterTurns * 90)\u{00B0} turn") }
        if c.flipH || c.flipV { parts.append("Flip " + (c.flipH ? "H" : "") + (c.flipV ? "V" : "")) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: Develop

/// DEVELOP: histogram, light, presence and colour sliders, curves, colour mixer, then effects and frame, with
/// RESET at the foot.
struct DevelopPanel: View {
    @Bindable var model: EditorModel

    static let toneColor: [SliderGroup] = [
        SliderGroup(title: "Light", specs: [
            SliderSpec("exposure", "Exposure", \.exposure, -2...2, default: 0),
            SliderSpec("contrast", "Contrast", \.contrast, -1...1, default: 0),
            SliderSpec("highlights", "Highlights", \.highlights, -1...1, default: 0),
            SliderSpec("shadows", "Shadows", \.shadows, -1...1, default: 0),
            SliderSpec("whites", "Whites", \.whites, -1...1, default: 0),
            SliderSpec("blacks", "Blacks", \.blacks, -1...1, default: 0),
        ]),
        SliderGroup(title: "Presence", specs: [
            SliderSpec("texture", "Texture", \.texture, -1...1, default: 0),
            SliderSpec("clarity", "Clarity", \.clarity, -1...1, default: 0),
            SliderSpec("vibrance", "Vibrance", \.vibrance, -1...1, default: 0),
            SliderSpec("saturation", "Saturation", \.saturation, -1...1, default: 0),
        ]),
        SliderGroup(title: "Color", specs: [
            SliderSpec("warmth", "Temperature", \.warmth, -1...1, default: 0),
            SliderSpec("tint", "Tint", \.tint, -1...1, default: 0),
        ]),
    ]

    static let texture = [
        SliderSpec("grain", "Grain", \.grainAmount, 0...1, default: 0),
        SliderSpec("grainSize", "Grain size", \.grainSize, 0...1, default: 0.5),
        SliderSpec("halation", "Halation", \.halationAmount, 0...1, default: 0),
        SliderSpec("halationRadius", "Halation radius", \.halationRadius, 0...1, default: 0.5),
        SliderSpec("bloom", "Bloom", \.bloomAmount, 0...1, default: 0),
    ]

    var body: some View {
        VStack(spacing: 0) {
            FFScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HistogramView(model: model)
                    ForEach(Self.toneColor) { group in
                        FFSectionLabel(group.title).padding(.top, T.rows(1)).padding(.bottom, 4)
                        SpecSliders(model: model, specs: group.specs)
                    }
                    CurvesPanel(model: model)
                    ColorMixerPanel(model: model)
                    FFSectionLabel("Effects").padding(.top, T.rows(1)).padding(.bottom, 4)
                    SpecSliders(model: model, specs: Self.texture)
                    FFSectionLabel("Frame").padding(.top, T.rows(1)).padding(.bottom, 4)
                    SpecSliders(model: model, specs: [SliderSpec("vignette", "Vignette", \.vignetteAmount, 0...1, default: 0)])
                    FFToggle("Border", isOn: $model.recipe.borderEnabled)
                        .padding(.bottom, 8)
                    if model.recipe.borderEnabled {
                        SpecSliders(model: model, specs: [SliderSpec("borderWidth", "Border width", \.borderWidth, 0...0.3, default: 0.04)])
                    }
                }
                .padding(.horizontal, T.cells(2))
                .padding(.bottom, T.rows(1))
            }
            FFHairline()
            HStack {
                Spacer()
                Button("Reset") { model.reset() }
                    .buttonStyle(FFButtonStyle())
                    .disabled(!model.canReset)
                    .help("Reset all sliders, curves and the mixer; keeps the selected film and crop")
            }
            .padding(.horizontal, T.cells(2))
            .padding(.vertical, T.rows(1))
        }
        .ffPanel()
    }
}

// MARK: Crop

/// CROP: a readout of the working crop and how to use the tool. The controls themselves sit in the
/// bar under the canvas.
struct CropPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Crop")
                .font(T.display(26, weight: .medium))
                .foregroundStyle(T.paper)
                .frame(height: T.rows(2), alignment: .leading)
                .padding(.top, T.rows(2))
            Text(summary)
                .ffLabel(color: T.lichen)
                .lineLimit(1)
                .frame(height: T.rows(1), alignment: .leading)
            Text("Drag the box or its corners to frame the picture. Pick a ratio, straighten the horizon, rotate or flip. Done keeps the crop; Cancel puts back the one you had. Leaving this tab keeps it too.")
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(T.paperMid)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            FFSectionLabel("Readout").padding(.top, T.rows(2)).padding(.bottom, 4)
            readout("Ratio", ratioText)
            readout("Straighten", model.crop.straighten.formatted(.number.precision(.fractionLength(1))) + "\u{00B0}")
            readout("Rotation", "\(model.crop.normalizedQuarterTurns * 90)\u{00B0}")
            readout("Flip", flipText)
            readout("Size", sizeText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, T.cells(2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffPanel()
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).ffLabel()
            Spacer()
            Text(value).ffLabel(color: T.paperMid)
        }
        .frame(height: T.rows(1.5))
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        CropSummary.line(for: model.crop, label: false) ?? "Whole picture"
    }

    private var ratioText: String {
        model.crop.aspect == CropAspect.free ? "Free" : CropAspect.label(model.crop.aspect)
    }

    private var flipText: String {
        let c = model.crop
        if c.flipH && c.flipV { return "H + V" }
        return c.flipH ? "H" : (c.flipV ? "V" : "None")
    }

    private var sizeText: String {
        guard let canvas = model.cropCanvasSize else { return "\u{2014}" }
        let r = model.crop.rect
        return "\(Int((r.w * canvas.width).rounded())) \u{00D7} \(Int((r.h * canvas.height).rounded())) px"
    }
}
