import Foundation
import MiraCore
import Observation
import Testing
@testable import MiraUI

/// A closed photo must be freed: the app drops its `EditorModel` when you go back to the library, and the
/// model holds the decoded source, the preview frames and the thumbnails.
@MainActor
@Suite("Editor model lifetime", .serialized)
struct EditorModelLifetimeTests {
    /// Loads a photo, renders, then lets go of the model the way the app does (`cancelWork`, drop the reference).
    private static func openAndClose(observing: (EditorModel) -> Void = { _ in }) async throws -> WeakBox {
        let root = SnapshotTests.root
        let library = try FilmLibrary(directory: root.appendingPathComponent("Films"))
        var model: EditorModel? = EditorModel(library: library, presetStore: PresetModelTests.tempStore())
        let box = WeakBox(model!)
        #expect(model!.loadSource(url: root.appendingPathComponent("Fixtures/sample.jpg")))
        model!.recipe.filmID = "fuji-velvia-50"
        observing(model!)
        model!.recipe.exposure = 0.3   // fires a watcher armed above
        let live = model!
        try await HoverTests.waitFor { live.previewImage != nil && live.isPreviewIdle && live.thumbnailsSettled }
        model!.hoverFilm("fuji-velvia-50")
        model!.cancelWork()
        model = nil
        return box
    }

    final class WeakBox {
        weak var model: EditorModel?
        init(_ model: EditorModel) { self.model = model }
    }

    @Test func editorModelIsFreedAfterCancelWork() async throws {
        let box = try await Self.openAndClose()
        // Cancelled tasks release the model when they finish; give them a moment.
        try await HoverTests.waitFor(10) { box.model == nil }
        #expect(box.model == nil, "EditorModel is still alive after cancelWork and dropping the last reference")
    }

    /// Re-arms a one-shot `withObservationTracking` on `recipe` from its own change callback, like `AppState.observe`.
    @MainActor
    final class RecipeWatcher {
        var fired = 0

        func arm(_ model: EditorModel) {
            withObservationTracking {
                _ = model.recipe
            } onChange: { [weak self, weak model] in
                Task { @MainActor in
                    guard let self, let model else { return }
                    self.fired += 1
                    self.arm(model)
                }
            }
        }
    }

    /// The registration sits in the model's own observation registrar until the next change, so a watcher whose
    /// callback holds the model strongly keeps a closed photo alive for good (AppState.observe holds it weakly).
    @Test func recipeWatcherWithWeakModelDoesNotKeepTheModelAlive() async throws {
        let watcher = RecipeWatcher()
        let box = try await Self.openAndClose(observing: { watcher.arm($0) })
        try await HoverTests.waitFor(10) { box.model == nil }
        #expect(box.model == nil, "a weak watcher must not keep the closed model alive")
        #expect(watcher.fired >= 1, "the watcher saw the recipe changes while the photo was open")
    }
}
