import MiraCore
import Observation
import Testing
@testable import MiraUI

@MainActor
@Suite("Film selection observation", .serialized)
struct FilmSelectionTests {
    @Test func selectedFilmIDFollowsRecipeButIgnoresSliders() throws {
        let library = try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
        let model = EditorModel(library: library, recipe: Recipe(filmID: "fuji-velvia-50"))
        #expect(model.selectedFilmID == "fuji-velvia-50")

        let fired = Counter()
        withObservationTracking { _ = model.selectedFilmID } onChange: { fired.bump() }
        model.recipe.exposure = 0.5
        model.recipe.contrast = 0.2
        #expect(fired.n == 0, "a slider change must not invalidate views that read selectedFilmID")

        let other = try #require(library.films.first { $0.id != "fuji-velvia-50" })
        model.selectFilm(other.id)
        #expect(model.selectedFilmID == other.id)
        #expect(fired.n == 1)
        model.recipe = .neutral
        #expect(model.selectedFilmID == nil)
    }
}

private final class Counter: @unchecked Sendable {
    var n = 0
    func bump() { n += 1 }
}
