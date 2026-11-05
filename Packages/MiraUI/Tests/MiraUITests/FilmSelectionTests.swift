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

@MainActor
@Suite("Native texture on film selection", .serialized)
struct NativeTextureSelectionTests {
    func model() throws -> (EditorModel, FilmLibrary) {
        let library = try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
        return (EditorModel(library: library), library)
    }

    @Test func selectingFilmResetsTextureToNative() throws {
        let (model, library) = try model()
        let ids = library.films.prefix(2).map(\.id)
        model.selectFilm(ids[0])
        #expect(model.recipe.grainAmount == 0.5 && model.recipe.halationAmount == 0.5 && model.recipe.bloomAmount == 0.5)
        model.recipe.grainAmount = 0.9; model.recipe.halationAmount = 0.1; model.recipe.bloomAmount = 0.8
        model.selectFilm(ids[1])
        #expect(model.recipe.grainAmount == 0.5 && model.recipe.halationAmount == 0.5 && model.recipe.bloomAmount == 0.5)
        model.selectFilm(nil)
        #expect(model.recipe.grainAmount == 0 && model.recipe.halationAmount == 0 && model.recipe.bloomAmount == 0)
    }

    @Test func hoverRecipeMatchesSelection() throws {
        let (model, library) = try model()
        let id = try #require(library.films.first?.id)
        model.recipe.grainAmount = 0.9
        #expect(model.hoverRecipe(for: .film(id)).grainAmount == 0.5)
        #expect(model.hoverRecipe(for: .film(id)).bloomAmount == 0.5)
    }

    @Test func presetsKeepTheirOwnValues() throws {
        let (model, library) = try model()
        let id = try #require(library.films.first?.id)
        var r = Recipe(filmID: id, grainAmount: 0.8, halationAmount: 0.1, bloomAmount: 0.3)
        r.pipeline = Recipe.currentPipeline
        let preset = Preset(nickname: "Mine", recipe: r, library: library)
        let applied = model.recipe(applying: preset)
        #expect(applied.grainAmount == 0.8 && applied.halationAmount == 0.1 && applied.bloomAmount == 0.3)
    }
}
