import MiraCore
import SwiftUI

private typealias T = FieldFramesTheme

/// The shared editor: preview, film strip and inspector.
public struct EditorView: View {
    @Bindable private var model: EditorModel

    public init(model: EditorModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PreviewPane(model: model)
                if model.isCropping {
                    FFHairline()
                    CropControls(model: model)
                }
                FFHairline()
                FilmStrip(model: model)
            }
            FFHairline(.vertical)
            InspectorView(model: model)
                .frame(width: T.cells(36))
        }
        .frame(minWidth: 760, minHeight: 520)
        .fieldFramesWindow()
    }
}

// MARK: Preview

private struct PreviewPane: View {
    @Bindable var model: EditorModel
    @Environment(\.ffImageCanvas) private var imageCanvas
    @Environment(\.displayScale) private var displayScale

    @ViewBuilder
    private func canvas(_ frame: PreviewFrame) -> some View {
        if imageCanvas, let image = model.displayedImage {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            FrameCanvas(frame: frame)
        }
    }

    var body: some View {
        ZStack {
            // The photograph sits on plain ink: no grain, no veil over it.
            T.ink
            if let frame = model.displayedFrame {
                canvas(frame)
                    .aspectRatio(frame.pixelSize, contentMode: .fit)
                    .padding(T.cells(3))
                    .accessibilityLabel(model.showOriginal ? "Original photo" : "Edited photo")
                if model.isCropping {
                    CropOverlay(model: model)
                        .padding(T.cells(3))
                }
            } else {
                Text("Developing").ffLabel()
            }
        }
        .overlay(alignment: .topLeading) {
            if let name = model.hoverPreviewName {
                Text("Preview \u{00B7} \(name)")
                    .ffLabel(color: T.onPhoto)
                    .lineLimit(1)
                    .padding(.horizontal, T.cells(1))
                    .padding(.vertical, 4)
                    .background(T.onPhotoVeil)
                    .padding(T.cells(2))
                    .allowsHitTesting(false)
                    .accessibilityLabel("Previewing \(name)")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !model.isCropping {
                CompareButton(model: model)
                    .padding(T.cells(2))
            }
        }
        .overlay(alignment: .topTrailing) {
            if !model.isCropping {
                Button("Crop") { model.beginCrop() }
                    .buttonStyle(.ff)
                    .background(T.backdrop)
                    .padding(T.cells(2))
                    .disabled(model.displayedFrame == nil)
                    .help("Crop, rotate and straighten (C)")
            }
        }
        .background {
            // C toggles the crop tool in both hosts (Done when it is already open).
            Button("Toggle crop") { model.toggleCrop() }
                .keyboardShortcut("c", modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            // The picture area is the pane minus its padding; previews are rendered at that size in pixels.
            let inset = T.cells(3) * 2
            model.setCanvas(pixels: CGSize(width: max(1, size.width - inset) * displayScale,
                                           height: max(1, size.height - inset) * displayScale))
        }
        .contentShape(Rectangle())
        .gesture(holdToCompare(model), isEnabled: !model.isCropping)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(model.isCropping ? "" : "Press and hold to see the original")
    }
}

@MainActor
private func holdToCompare(_ model: EditorModel) -> some Gesture {
    DragGesture(minimumDistance: 0)
        .onChanged { _ in if !model.showOriginal { model.showOriginal = true } }
        .onEnded { _ in model.showOriginal = false }
}

private struct CompareButton: View {
    @Bindable var model: EditorModel

    var body: some View {
        FFButtonChrome(pressed: model.showOriginal) {
            Text("Hold to compare")
        }
        .background(T.backdrop)
        .gesture(holdToCompare(model))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Compare")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Press and hold to show the original")
    }
}

// MARK: Film strip

private struct FilmStrip: View {
    @Bindable var model: EditorModel

    private var tabs: [(value: FilmFamily?, title: String)] {
        [(nil, "All")] + FilmFamily.allCases.map { (Optional($0), $0.displayName) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FFTabBar(tabs, selection: $model.familyFilter)
                .padding(.horizontal, T.cells(2))
            FFHairline()
            FFScrollView(.horizontal) {
                HStack(alignment: .top, spacing: T.cells(1)) {
                    FilmCard(
                        title: "Original", caption: "No film",
                        image: model.thumbnails[EditorModel.originalTileID],
                        isSelected: model.recipe.filmID == nil,
                        onHoverChange: { hover($0, nil) }
                    ) { model.selectFilm(nil) }

                    ForEach(model.visibleFilms) { film in
                        FilmCard(
                            title: film.displayName,
                            caption: caption(for: film),
                            image: model.thumbnails[film.id],
                            isSelected: model.recipe.filmID == film.id,
                            onHoverChange: { hover($0, film.id) }
                        ) { model.selectFilm(film.id) }
                    }
                }
                .padding(.horizontal, T.cells(2) - 4)
                .padding(.vertical, T.rows(1) / 2)
            }
            .frame(height: T.rows(9))
        }
        .ffPanel()
    }

    /// Enter previews the card; exit only ends the hover if no other card has taken over, so the
    /// exit/enter order between neighbours does not matter.
    private func hover(_ inside: Bool, _ id: String?) {
        let target: EditorModel.HoverTarget = id.map(EditorModel.HoverTarget.film) ?? .original
        if inside {
            model.hoverFilm(id)
        } else if model.hoveredTarget == target {
            model.endHover()
        }
    }

    private func caption(for film: Film) -> String {
        film.iso > 0 ? "\(film.brand) \u{00B7} \(film.iso)" : film.brand
    }
}

// MARK: Inspector

private struct SliderSpec: Identifiable {
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

private struct SliderGroup: Identifiable {
    let title: String
    let specs: [SliderSpec]
    var id: String { title }
}

private struct InspectorView: View {
    @Bindable var model: EditorModel

    private static let groups: [SliderGroup] = [
        SliderGroup(title: "Film", specs: [
            SliderSpec("strength", "Strength", \.strength, 0...1, default: 1),
        ]),
        SliderGroup(title: "Tone", specs: [
            SliderSpec("exposure", "Exposure", \.exposure, -2...2, default: 0),
            SliderSpec("contrast", "Contrast", \.contrast, -1...1, default: 0),
        ]),
        SliderGroup(title: "Colour", specs: [
            SliderSpec("saturation", "Saturation", \.saturation, -1...1, default: 0),
            SliderSpec("warmth", "Warmth", \.warmth, -1...1, default: 0),
            SliderSpec("tint", "Tint", \.tint, -1...1, default: 0),
        ]),
        SliderGroup(title: "Texture", specs: [
            SliderSpec("grain", "Grain", \.grainAmount, 0...1, default: 0),
            SliderSpec("grainSize", "Grain size", \.grainSize, 0...1, default: 0.5),
            SliderSpec("halation", "Halation", \.halationAmount, 0...1, default: 0),
            SliderSpec("halationRadius", "Halation radius", \.halationRadius, 0...1, default: 0.5),
            SliderSpec("bloom", "Bloom", \.bloomAmount, 0...1, default: 0),
        ]),
    ]

    private func binding(_ keyPath: WritableKeyPath<Recipe, Double>) -> Binding<Double> {
        Binding(
            get: { model.recipe[keyPath: keyPath] },
            set: { model.recipe[keyPath: keyPath] = $0 })
    }

    private func sliders(_ specs: [SliderSpec]) -> some View {
        ForEach(specs) { spec in
            FFSlider(spec.label, value: binding(spec.keyPath), in: spec.range, default: spec.defaultValue)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, T.cells(2))
                .padding(.top, T.rows(2))
                .padding(.bottom, T.rows(1))
            FFHairline()
            FFScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.groups) { group in
                        FFSectionLabel(group.title)
                            .padding(.top, T.rows(1))
                            .padding(.bottom, 4)
                        sliders(group.specs)
                    }
                    FFSectionLabel("Frame")
                        .padding(.top, T.rows(1))
                        .padding(.bottom, 4)
                    sliders([SliderSpec("vignette", "Vignette", \.vignetteAmount, 0...1, default: 0)])
                    FFToggle("Border", isOn: $model.recipe.borderEnabled)
                        .padding(.bottom, 8)
                    if model.recipe.borderEnabled {
                        sliders([SliderSpec("borderWidth", "Border width", \.borderWidth, 0...0.3, default: 0.04)])
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
                    .disabled(model.recipe == Recipe(filmID: model.recipe.filmID, crop: model.recipe.crop))
                    .help("Reset all sliders and keep the selected film")
            }
            .padding(.horizontal, T.cells(2))
            .padding(.vertical, T.rows(1))
        }
        .ffPanel()
    }

    /// Fixed-height header: name (one line), meta label (one line), description (three lines). The
    /// height is the same for Original and every film, so the sliders below never shift.
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
    private var cropLine: String? {
        let c = model.recipe.crop
        guard !c.isIdentity else { return nil }
        var parts = ["Crop"]
        if !c.rect.isFull { parts.append(c.aspect == CropAspect.free ? "Free" : CropAspect.label(c.aspect)) }
        if abs(c.straighten) > 1e-9 {
            parts.append(c.straighten.formatted(.number.precision(.fractionLength(1))) + "\u{00B0}")
        }
        if c.normalizedQuarterTurns != 0 { parts.append("\(c.normalizedQuarterTurns * 90)\u{00B0} turn") }
        if c.flipH || c.flipV { parts.append("Flip " + (c.flipH ? "H" : "") + (c.flipV ? "V" : "")) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var descriptionText: String {
        model.selectedFilm?.description ?? "The photograph as it was taken. Choose a film from the strip to grade it."
    }
}
