#if os(macOS)
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
    /// Tooltip shown over the slider.
    let help: String?

    init(_ id: String, _ label: String, _ keyPath: WritableKeyPath<Recipe, Double>,
         _ range: ClosedRange<Double>, default defaultValue: Double, help: String? = nil) {
        self.help = help
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
            .help(spec.help ?? "")
        }
    }
}

// MARK: Films

/// FILMS: the selected film's header (name, brand, ISO, family, description), the ISO and VARIATIONS chip rows of
/// its stock, and its STRENGTH.
struct FilmsPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, T.cells(2))
                .padding(.top, T.rows(2))
                .padding(.bottom, T.rows(1))
            FFHairline()
            FFScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    stockChips
                    SpecSliders(model: model, specs: [SliderSpec("strength", "Strength", \.strength, 0...1, default: 1,
                                                                      help: "Choosing a film sets grain, halation and bloom to its own level")])
                        .padding(.top, T.rows(1))
                    filmControls
                    presetSection
                }
                .padding(.horizontal, T.cells(2))
                .padding(.bottom, T.rows(1))
            }
            .scrollIndicators(.hidden)
        }
        .ffPanel()
    }

    /// ISO and VARIATIONS: chip rows for the selected film's stock, wrapping onto several lines. Each row is
    /// absent when the stock offers only one choice there.
    @ViewBuilder private var stockChips: some View {
        let isos = model.isoChoices
        if !isos.isEmpty {
            let current = model.selectedFilm?.iso
            VStack(alignment: .leading, spacing: T.rows(0.5)) {
                FFSectionLabel("ISO").padding(.top, T.rows(1))
                FFWrapLayout(spacing: T.cells(2), lineSpacing: 0) {
                    ForEach(isos) { choice in
                        let target = model.filmID(forISO: choice.iso)
                        VariantChip(title: choice.label, selected: choice.iso == current, kind: "ISO",
                                    onHover: { hoverChip($0, target) }) { model.selectISO(choice.iso) }
                    }
                }
            }
        }
        let variations = model.variationChoices
        if !variations.isEmpty {
            VStack(alignment: .leading, spacing: T.rows(0.5)) {
                FFSectionLabel("Variations").padding(.top, T.rows(1))
                FFWrapLayout(spacing: T.cells(2), lineSpacing: 0) {
                    ForEach(variations) { choice in
                        VariantChip(title: choice.label, selected: choice.filmID == model.selectedFilmID, kind: "Variation",
                                    onHover: { hoverChip($0, choice.filmID) }) { model.selectFilm(choice.filmID) }
                    }
                }
            }
        }
    }

    /// Hovering a chip previews the film it would apply, like a strip card.
    private func hoverChip(_ inside: Bool, _ id: String?) {
        guard let id else { return }
        if inside {
            model.hoverFilm(id)
        } else if model.hoveredTarget == .film(id) {
            model.endHover()
        }
    }

    /// PUSH / PULL, SCAN, PAPER (not on print cards) and (monochrome films) TONING.
    @ViewBuilder private var filmControls: some View {
        if model.showsFilmControls {
            if model.isLegacyPipeline {
                Text("Made with an earlier Mira; changing film settings updates it to the current film model")
                    .ffLabel(color: T.paperDim)
                    .lineLimit(3)
                    .padding(.top, T.rows(1))
                    .help("This edit uses the original film model, which ignores Push / Pull, Scan, Paper, Toning and Exposure time")
            }
            FFSlider("Push / Pull", value: Binding(get: { model.recipe.push },
                                                   set: { model.recipe.push = PushFormat.snapped($0) }),
                     in: PushFormat.range, default: 0, snap: PushFormat.step, format: PushFormat.label)
                .padding(.top, T.rows(1))
                .help("Shoot the film at a different speed and develop to compensate, in stops")
            LatitudeCompact(model: model)
            if model.showsReciprocityControls { reciprocityControls }
            chipSection("Scan", ScanProfile.allCases.map { ($0.displayName, $0 == model.recipe.scanProfile, $0) }) {
                model.selectScan($0)
            }
            if model.showsPaperChips {
                chipSection("Paper", PaperProfile.allCases.map { ($0.displayName, $0 == model.recipe.paper, $0) }) {
                    model.selectPaper($0)
                }
                Text("Mira originals, inspired by published print behavior. Replaces Scan. No affiliation with Kodak or Fujifilm.")
                    .ffLabel(color: T.paperDim)
                    .lineLimit(3)
                    .help("Cinema Print and Color Paper are Mira original looks; choosing one sets Scan to Neutral")
            }
            if model.showsToning {
                chipSection("Toning", Toning.allCases.map { ($0.displayName, $0 == model.recipe.toning, $0) }) {
                    model.recipe.toning = $0
                }
                if model.recipe.toning != .none {
                    FFSlider("Toning", value: $model.recipe.toningStrength, in: 0...1, default: 0.5)
                        .padding(.top, T.rows(0.5))
                }
            }
        }
    }

    /// EXPOSURE TIME: the EXIF time or the chosen one on a log slider (double-click the label for the EXIF time),
    /// the reciprocity mode, and what the time does to this film.
    @ViewBuilder private var reciprocityControls: some View {
        FFSlider("Exposure time",
                 value: Binding(get: { model.exposureTimeSliderValue },
                                set: { model.setExposureTime(sliderValue: $0) }),
                 in: ExposureTimeFormat.range, default: log2(model.sourceExposureTime.map { ExposureTimeFormat.standard(nearestTo: $0) } ?? ExposureTimeFormat.neutral),
                 snap: ExposureTimeFormat.step,
                 format: { _ in model.exposureTimeReadout })
            .padding(.top, T.rows(1))
            .help("Shutter speed the film is exposed for; long times make film lose speed (reciprocity failure). Double-click to use the photo's EXIF time")
        chipSection("Reciprocity", ReciprocityMode.allCases.map { ($0.displayName, $0 == model.recipe.reciprocity, $0) }) {
            model.recipe.reciprocity = $0
        }
        .help("Off ignores the exposure time. Compensated keeps the brightness and shows the colour cast, contrast and shadow grain. Uncompensated also darkens")
        if model.recipe.reciprocity != .off {
            FFSlider("Reciprocity strength", value: $model.recipe.reciprocityStrength, in: 0...2, default: 1,
                     format: { "\(Int(($0 * 100).rounded())) %" })
                .padding(.top, T.rows(0.5))
                .help("How strongly the colour cast, contrast and shadow grain of reciprocity failure show; 100 % is the datasheet model")
        }
        if let readout = model.reciprocityReadout {
            (Text("\(Text(readout).foregroundStyle(T.paperMid))\(Text(model.reciprocityExtrapolated ? " \u{00B7} beyond datasheet" : "").foregroundStyle(T.paperDim))"))
                .ffLabel(color: T.paperMid)
                .lineLimit(2)
                .padding(.top, T.rows(0.5))
                .accessibilityLabel(readout + (model.reciprocityExtrapolated ? ", beyond datasheet" : ""))
        }
    }

    private func chipSection<V>(_ title: String, _ items: [(String, Bool, V)],
                                choose: @escaping (V) -> Void) -> some View {
        VStack(alignment: .leading, spacing: T.rows(0.5)) {
            FFSectionLabel(title).padding(.top, T.rows(1))
            FFWrapLayout(spacing: T.cells(2), lineSpacing: 0) {
                ForEach(items.indices, id: \.self) { i in
                    VariantChip(title: items[i].0, selected: items[i].1, onHover: { _ in }) { choose(items[i].2) }
                }
            }
        }
    }

    /// The preset the look equals, if any, and SAVE PRESET.
    private var presetSection: some View {
        VStack(alignment: .leading, spacing: T.rows(0.5)) {
            FFSectionLabel("Preset").padding(.top, T.rows(1))
            Text(appliedPreset.map { "Matches \($0.displayName)" } ?? "Not saved as a preset")
                .ffLabel(color: T.paperDim)
                .lineLimit(2)
            Button("Save Preset\u{2026}") { model.beginSavePreset() }
                .buttonStyle(.ffProminent)
                .disabled(model.source == nil)
                .padding(.top, T.rows(1) / 2)
                .help("Save the film and develop settings as a preset \u{21E7}\u{2318}S")
            if let notice = model.presetNotice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(T.lichen)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, T.rows(1) / 2)
            }
        }
    }

    private var appliedPreset: Preset? {
        model.appliedPresetID.flatMap { id in model.presets.first { $0.id == id } }
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
            // The preset the look matches, named as on its card; reserved so the header never changes height.
            Group {
                if let preset = appliedPreset {
                    PresetText.name(film: preset.filmName, nickname: preset.nickname, size: 15)
                        .font(T.display(15, weight: .medium))
                        .foregroundStyle(T.paperSoft)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityLabel("Preset \(preset.displayName)")
                } else {
                    Text(" ")
                        .accessibilityHidden(true)
                }
            }
            .frame(height: T.rows(1.5), alignment: .leading)
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

/// A tab-bar-style choice: mono label, paper and medium with a lichen underline when selected.
private struct VariantChip: View {
    let title: String
    let selected: Bool
    var kind = "Variant"
    let onHover: (Bool) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .ffLabel(color: selected ? T.paper : T.paperDim, weight: selected ? .medium : .regular)
                .lineLimit(1)
                .frame(height: T.rows(1.5))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? T.lichen : Color.clear).frame(height: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .accessibilityLabel("\(kind) \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Lays children out left to right and wraps onto a new line when the row is full.
struct FFWrapLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private func rows(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return (frames, CGSize(width: maxX, height: y + lineHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = rows(subviews, width: bounds.width)
        for (sub, frame) in zip(subviews, laid.frames) {
            sub.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                      proposal: ProposedViewSize(frame.size))
        }
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

/// One Develop section's data-driven sliders: the recipe sliders, then the camera-raw-decode ones for a RAW photo.
struct DevelopSectionSpec: Identifiable {
    let section: DevelopSection
    let specs: [SliderSpec]
    let rawSpecs: [RawSliderSpec]
    var id: String { section.rawValue }

    init(_ section: DevelopSection, specs: [SliderSpec] = [], rawSpecs: [RawSliderSpec] = []) {
        self.section = section
        self.specs = specs
        self.rawSpecs = rawSpecs
    }

    /// Every slider id the section can show, in order.
    var sliderIDs: [String] { specs.map(\.id) + rawSpecs.map(\.id) }
}

/// DEVELOP: histogram, then Light, White balance, Color (with curves and the mixer), Detail, Lens, Film and
/// Frame, with RESET at the foot. Camera-raw-decode controls sit inside the section of their function.
struct DevelopPanel: View {
    @Bindable var model: EditorModel

    /// The panel's sections in order. White balance, the lens-correction toggle, the rem-jet toggle and the
    /// border controls are laid out by hand around these.
    static let sections: [DevelopSectionSpec] = [
        DevelopSectionSpec(.light, specs: [
            SliderSpec("exposure", "Exposure", \.exposure, -2...2, default: 0),
            SliderSpec("contrast", "Contrast", \.contrast, -1...1, default: 0),
            SliderSpec("highlights", "Highlights", \.highlights, -1...1, default: 0),
            SliderSpec("shadows", "Shadows", \.shadows, -1...1, default: 0),
            SliderSpec("whites", "Whites", \.whites, -1...1, default: 0),
            SliderSpec("blacks", "Blacks", \.blacks, -1...1, default: 0),
        ], rawSpecs: [.boost, .highlightRecovery, .localToneMap]),
        DevelopSectionSpec(.whiteBalance),
        DevelopSectionSpec(.color, specs: [
            SliderSpec("vibrance", "Vibrance", \.vibrance, -1...1, default: 0),
            SliderSpec("saturation", "Saturation", \.saturation, -1...1, default: 0),
        ]),
        DevelopSectionSpec(.detail, specs: [
            SliderSpec("texture", "Texture", \.texture, -1...1, default: 0),
            SliderSpec("clarity", "Clarity", \.clarity, -1...1, default: 0),
        ], rawSpecs: [.sharpness, .luminanceNoise, .colorNoise]),
        DevelopSectionSpec(.lens, specs: [
            SliderSpec("vignette", "Vignette", \.vignetteAmount, 0...1, default: 0),
        ]),
        DevelopSectionSpec(.film, specs: [
            SliderSpec("grain", "Grain", \.grainAmount, 0...1, default: 0,
                       help: "50% is the film's own grain"),
            SliderSpec("grainSize", "Grain size", \.grainSize, 0...1, default: 0.5,
                       help: "50% is the film's own grain size"),
            SliderSpec("halation", "Halation", \.halationAmount, 0...1, default: 0,
                       help: "50% is the film's own halation"),
            SliderSpec("halationRadius", "Halation radius", \.halationRadius, 0...1, default: 0.5,
                       help: "50% is the film's own spread"),
            SliderSpec("bloom", "Bloom", \.bloomAmount, 0...1, default: 0,
                       help: "50% is the film's own bloom"),
        ]),
        DevelopSectionSpec(.frame, specs: [
            SliderSpec("borderWidth", "Border width", \.borderWidth, 0...0.3, default: 0.04),
        ]),
    ]

    private static func spec(_ section: DevelopSection) -> DevelopSectionSpec {
        sections.first { $0.section == section }!
    }

    private func label(_ section: DevelopSection) -> some View {
        FFSectionLabel(section.title).padding(.top, T.rows(1)).padding(.bottom, 4)
    }

    private func sliders(_ section: DevelopSection) -> some View {
        let spec = Self.spec(section)
        return Group {
            SpecSliders(model: model, specs: spec.specs)
            RawSliders(model: model, specs: spec.rawSpecs)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FFScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HistogramView(model: model)
                    LatitudeReadout(model: model)
                    label(.light)
                    sliders(.light)
                    label(.whiteBalance)
                    WhiteBalanceSliders(model: model)
                    label(.color)
                    sliders(.color)
                    CurvesPanel(model: model)
                    ColorMixerPanel(model: model)
                    label(.detail)
                    sliders(.detail)
                    label(.lens)
                    if model.rawControlVisibility.lensCorrection {
                        FFToggle("Lens correction", isOn: Binding(
                            get: { model.recipe.raw.lensCorrection ?? false },
                            set: { model.recipe.raw.lensCorrection = $0 }))
                            .padding(.bottom, 8)
                            .help("Corrects the lens distortion in the camera raw decode")
                    }
                    sliders(.lens)
                    label(.film)
                    sliders(.film)
                    if model.showsRemJetToggle {
                        FFToggle("Remove rem-jet", isOn: $model.recipe.remJetRemoved)
                            .padding(.bottom, 8)
                            .help("Removing the anti-halation backing lets highlights bleed red")
                    }
                    label(.frame)
                    FFToggle("Border", isOn: $model.recipe.borderEnabled)
                        .padding(.bottom, 8)
                    if model.recipe.borderEnabled {
                        sliders(.frame)
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
                    .help("Reset all sliders, curves, the mixer and white balance; keeps the selected film, crop and dodge and burn")
            }
            .padding(.horizontal, T.cells(2))
            .padding(.vertical, T.rows(1))
        }
        .ffPanel()
    }
}

/// WHITE BALANCE: one temperature (kelvin) and tint pair for every photo, and "As shot" to clear both.
private struct WhiteBalanceSliders: View {
    @Bindable var model: EditorModel

    var body: some View {
        let wb = WhiteBalanceControl(isRaw: model.isRawSource, asShot: model.rawAsShot)
        FFSlider("Temperature (K)",
                 value: Binding(get: { wb.temperature(of: model.recipe) },
                                set: { wb.setTemperature($0, in: &model.recipe) }),
                 in: wb.kelvinRange, default: wb.kelvinDefault, decimals: 0, snap: WhiteBalanceControl.kelvinSnap)
            .help(wb.isRaw ? "White balance in kelvin; the camera's value until you change it"
                           : "Warmer or cooler, in kelvin from a 6500 K neutral")
        FFSlider("Tint",
                 value: Binding(get: { wb.tint(of: model.recipe) },
                                set: { wb.setTint($0, in: &model.recipe) }),
                 in: wb.tintRange, default: wb.tintDefault, decimals: 0, snap: WhiteBalanceControl.tintSnap)
        HStack {
            Spacer()
            Button("As shot") { WhiteBalanceControl.resetToAsShot(&model.recipe) }
                .buttonStyle(.ff)
                .disabled(wb.isAsShot(model.recipe))
                .help("Back to the camera's white balance")
        }
        .padding(.bottom, 8)
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

#endif
