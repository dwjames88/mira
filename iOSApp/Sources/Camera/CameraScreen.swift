import MiraCamera
import MiraCore
import MiraUI
import Photos
import SwiftUI

/// The camera as the app presents it: `CameraView` with the app's pieces (film renderer, the editor-backed print
/// writer, opening a frame in the editor the gallery already uses).
struct CameraScreen: View {
    let editor: EditorViewModel
    let onClose: () -> Void
    // Made once on appear: building it in `init` would make a model (Metal device, queues) per parent redraw.
    @State private var model: CameraModel?

    var body: some View {
        ZStack {
            FieldFramesTheme.ink.ignoresSafeArea()
            if let model {
                CameraView(model: model, filmName: filmName(model), onClose: onClose) {
                    // LEAD: wire CameraFilmDoor here
                    CameraFilmDoorPlaceholder(model: model)
                } wbDoor: {
                    // LEAD: wire CameraWBDoor here
                    CameraWBRowPlaceholder(model: model)
                }
            }
        }
        .onAppear { if model == nil { model = makeModel() } }
    }

    private func filmName(_ model: CameraModel) -> String? {
        guard let id = model.recipe.filmID else { return "No film" }
        return PhotoEngine.library?.film(id: id)?.displayName
    }

    private func makeModel() -> CameraModel {
        let renderer = PhotoEngine.library.map { Renderer(library: $0) }
        var initial: Recipe?
        if CameraSettingsStore().load().lastRecipe == nil, let id = PhotoEngine.filmList.first?.id {
            initial = Recipe(filmID: id).applyingNativeTexture(filmID: id)
        }
        return CameraModel(
            printWriter: EditorPrintWriter(renderer: renderer),
            renderer: renderer,
            initialRecipe: initial,
            fixtureURL: Bundle.main.url(forResource: "sample", withExtension: "jpg"),
            onOpenFrame: { [editor, onClose] id in
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
                onClose()
                Task { await editor.openAsset(asset) }
            })
    }
}

/// Until `CameraFilmDoor` lands: pick a film from a plain list.
struct CameraFilmDoorPlaceholder: View {
    let model: CameraModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("FILM").ffLabel(size: 11).padding(FieldFramesTheme.cells(2))
                ForEach(PhotoEngine.filmList) { film in
                    Button {
                        model.recipe = Recipe(filmID: film.id).applyingNativeTexture(filmID: film.id)
                    } label: {
                        Text(film.displayName.uppercased())
                            .ffLabel(size: 11, color: model.recipe.filmID == film.id ? FieldFramesTheme.paper : FieldFramesTheme.paperDim)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, FieldFramesTheme.cells(2))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .foregroundStyle(FieldFramesTheme.paper)
    }
}

/// Until `CameraWBDoor` lands: one row of chips, AUTO · DAYLIGHT · CLOUDY · TUNGSTEN · FLUOR. · LOCK.
struct CameraWBRowPlaceholder: View {
    @Bindable var model: CameraModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WHITE BALANCE").ffLabel(size: 11)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(WhiteBalancePreset.allCases, id: \.self) { preset in
                        chip(preset.label, on: model.wb.preset == preset, label: preset.accessibilityLabel) {
                            model.wb.preset = preset
                        }
                    }
                    chip("LOCK", on: model.wb.locked, label: "Lock white balance to the current value") {
                        model.wb.locked.toggle()
                    }
                }
            }
        }
        .padding(FieldFramesTheme.cells(2))
        .frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(FieldFramesTheme.paper)
    }

    private func chip(_ title: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).ffLabel(size: 10, color: on ? FieldFramesTheme.paper : FieldFramesTheme.paperDim)
                .padding(.horizontal, 8).frame(minHeight: 44)
                .overlay(Rectangle().stroke(on ? FieldFramesTheme.lichen : FieldFramesTheme.hair, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
