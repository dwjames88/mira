import MiraCamera
import MiraCore
import MiraUI
import Photos
import SwiftUI

/// The camera as the app presents it: `CameraView` with the app's pieces (film renderer, the editor-backed print
/// writer, bringing up the library the camera sits over).
struct CameraScreen: View {
    let editor: EditorViewModel
    /// Brings up the library: the header's LIBRARY link and the last-frame thumbnail.
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
            onOpenLibrary: { [onClose] in onClose() },
            onFrameSaved: { DevelopStore.shared.add($0) })
    }
}

/// The film door as the camera presents it: `CameraFilmDoor` over the door model, which is bound to the camera model.
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
    }
}
