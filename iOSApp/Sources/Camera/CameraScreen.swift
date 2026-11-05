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
    @State private var doors: CameraFilmDoorModel?

    var body: some View {
        ZStack {
            FieldFramesTheme.ink.ignoresSafeArea()
            if let model, let doors {
                CameraView(model: model, filmName: filmName(model), onClose: onClose) { context in
                    FilmDoorHost(camera: model, doors: doors, context: context)
                } wbDoor: { context in
                    WBDoorHost(camera: model, context: context)
                }
                // IMPORT / SAVE PRESET from the door: the camera's presentations, bound to the door model
                // (RootView turns the editor's off while the camera is open).
                .presetPresentations(hub: PresetHub.shared, model: doors)
            }
        }
        .onAppear {
            guard model == nil else { return }
            let made = makeModel()
            let door = CameraFilmDoorModel(recipe: made.recipe)
            door.onRecipeChange = { [weak made] in made?.recipe = $0 }
            model = made
            doors = door
        }
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
            printQueue: CameraPrints.queue,
            onOpenFrame: { [editor, onClose] id in
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
                onClose()
                Task { await editor.openAsset(asset) }
            })
    }
}

/// The film door as the camera presents it: `CameraFilmDoor` over the door model, which is bound to the camera model.
/// Cards are requested from the finder only while the door is on screen.
private struct FilmDoorHost: View {
    let camera: CameraModel
    let doors: CameraFilmDoorModel
    let context: CameraDoorContext

    var body: some View {
        CameraFilmDoor(
            model: doors,
            grain: Binding(get: { camera.settings.finderGrainLive }, set: { camera.settings.finderGrainLive = $0 }),
            onClose: context.close,
            maxHeight: context.maxHeight)
            .onAppear {
                doors.resetWantedThumbnails()
                doors.setThumbnails(camera.cardThumbnails)
            }
            .onDisappear {
                camera.setWantedCardIDs([])
                doors.resetWantedThumbnails()
            }
            // The cards ask for their thumbnails as they appear; forward the set to the finder when it changes.
            .task {
                var sent: Set<String> = []
                while !Task.isCancelled {
                    let wanted = doors.wantedThumbnailIDs
                    if wanted != sent {
                        sent = wanted
                        camera.setWantedCardIDs(wanted.sorted())
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            // The finder renders new card images about twice a second (CGImages are classes: compare identities).
            .onChange(of: camera.cardThumbnails.mapValues { ObjectIdentifier($0) }) {
                doors.setThumbnails(camera.cardThumbnails)
            }
    }
}

private struct WBDoorHost: View {
    @Bindable var camera: CameraModel
    let context: CameraDoorContext

    var body: some View {
        CameraWBDoor(state: $camera.wb, onClose: context.close)
    }
}
