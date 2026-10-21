import EmulsionCore
import SwiftUI

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
                FilmStrip(model: model)
            }
            Divider()
            InspectorView(model: model)
                .frame(width: 280)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

// MARK: Preview

private struct PreviewPane: View {
    @Bindable var model: EditorModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(white: 0.09)
            if let image = model.displayedImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
                    .accessibilityLabel(model.showOriginal ? "Original photo" : "Edited photo")
            } else {
                ProgressView()
            }
            CompareButton(model: model)
                .padding(16)
        }
        .contentShape(Rectangle())
        .gesture(holdToCompare(model))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help("Press and hold to see the original")
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
        Label("Compare", systemImage: "square.split.2x1")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(Capsule())
            .gesture(holdToCompare(model))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Press and hold to show the original")
    }
}

// MARK: Film strip

private struct FilmStrip: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 8) {
            Picker("Family", selection: $model.familyFilter) {
                Text("All").tag(FilmFamily?.none)
                ForEach(FilmFamily.allCases, id: \.self) { family in
                    Text(family.displayName).tag(FilmFamily?.some(family))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)
            .padding(.top, 10)

            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        FilmTile(
                            title: "Original", caption: "No film",
                            image: model.thumbnails[EditorModel.originalTileID],
                            isSelected: model.recipe.filmID == nil
                        ) { model.selectFilm(nil) }

                        ForEach(model.visibleFilms) { film in
                            FilmTile(
                                title: film.displayName,
                                caption: caption(for: film),
                                image: model.thumbnails[film.id],
                                isSelected: model.recipe.filmID == film.id
                            ) { model.selectFilm(film.id) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }
            }
            .scrollIndicators(.automatic)
        }
        .padding(.bottom, 10)
        .background(.bar)
    }

    private func caption(for film: Film) -> String {
        film.iso > 0 ? "\(film.brand) \(film.iso)" : film.brand
    }
}

private struct FilmTile: View {
    let title: String
    let caption: String
    let image: NSImage?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Rectangle().fill(.quaternary)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: 104, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
                }
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 112)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(caption)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: Inspector

private struct SliderSpec: Identifiable {
    let id: String
    let label: String
    let keyPath: WritableKeyPath<Recipe, Double>
    let range: ClosedRange<Double>
    let defaultValue: Double
}

private struct InspectorView: View {
    @Bindable var model: EditorModel

    private var specs: [SliderSpec] {
        [
            SliderSpec(id: "strength", label: "Strength", keyPath: \.strength, range: 0...1, defaultValue: 1),
            SliderSpec(id: "exposure", label: "Exposure", keyPath: \.exposure, range: -2...2, defaultValue: 0),
            SliderSpec(id: "contrast", label: "Contrast", keyPath: \.contrast, range: -1...1, defaultValue: 0),
            SliderSpec(id: "saturation", label: "Saturation", keyPath: \.saturation, range: -1...1, defaultValue: 0),
            SliderSpec(id: "warmth", label: "Warmth", keyPath: \.warmth, range: -1...1, defaultValue: 0),
            SliderSpec(id: "tint", label: "Tint", keyPath: \.tint, range: -1...1, defaultValue: 0),
            SliderSpec(id: "grain", label: "Grain", keyPath: \.grainAmount, range: 0...1, defaultValue: 0),
            SliderSpec(id: "grainSize", label: "Grain Size", keyPath: \.grainSize, range: 0...1, defaultValue: 0.5),
            SliderSpec(id: "halation", label: "Halation", keyPath: \.halationAmount, range: 0...1, defaultValue: 0),
            SliderSpec(id: "halationRadius", label: "Halation Radius", keyPath: \.halationRadius, range: 0...1, defaultValue: 0.5),
            SliderSpec(id: "bloom", label: "Bloom", keyPath: \.bloomAmount, range: 0...1, defaultValue: 0),
            SliderSpec(id: "vignette", label: "Vignette", keyPath: \.vignetteAmount, range: 0...1, defaultValue: 0),
        ]
    }

    private func binding(_ keyPath: WritableKeyPath<Recipe, Double>) -> Binding<Double> {
        Binding(
            get: { model.recipe[keyPath: keyPath] },
            set: { model.recipe[keyPath: keyPath] = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    ForEach(specs) { spec in
                        SliderRow(spec: spec, value: binding(spec.keyPath))
                    }
                    Divider()
                    Toggle("Border", isOn: $model.recipe.borderEnabled)
                    if model.recipe.borderEnabled {
                        SliderRow(
                            spec: SliderSpec(id: "borderWidth", label: "Border Width", keyPath: \.borderWidth,
                                             range: 0...0.3, defaultValue: 0.04),
                            value: binding(\.borderWidth))
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button("Reset") { model.reset() }
                    .buttonStyle(.glass)
                    .disabled(model.recipe == Recipe(filmID: model.recipe.filmID))
                    .help("Reset all sliders and keep the selected film")
            }
            .padding(12)
        }
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.selectedFilm?.displayName ?? "Original")
                .font(.headline)
            if let film = model.selectedFilm {
                Text(film.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SliderRow: View {
    let spec: SliderSpec
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(spec.label)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { value = spec.defaultValue }
                    .help("Double-click to reset")
                Spacer()
                Text(value, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: $value, in: spec.range)
                .labelsHidden()
                .accessibilityLabel(spec.label)
        }
    }
}
