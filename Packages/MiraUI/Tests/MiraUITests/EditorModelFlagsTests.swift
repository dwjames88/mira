import Foundation
import MiraCore
import Testing
@testable import MiraUI

/// The editor keeps stored answers (`hasEdits`, `canReset`, `differsFromReference`, `selectedFilm`, `curves`,
/// `colorMixer`) so the app's menus and panels do not read `recipe` and re-evaluate on every slider tick. They
/// must always equal what the recipe says.
@MainActor
@Suite("Editor model stored answers", .serialized)
struct EditorModelFlagsTests {
    private static func makeModel() throws -> EditorModel {
        let library = try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
        return EditorModel(library: library, presetStore: PresetModelTests.tempStore())
    }

    /// Everything the stored answers promise, recomputed from the recipe.
    private static func check(_ model: EditorModel, _ note: String = "",
                              sourceLocation: SourceLocation = #_sourceLocation) {
        let r = model.recipe
        var neutral = Recipe.neutral
        neutral.pipeline = r.pipeline
        #expect(model.hasEdits == (r != neutral), "hasEdits \(note)", sourceLocation: sourceLocation)
        let resetTarget = Recipe(filmID: r.filmID, pipeline: r.pipeline, crop: r.crop, dodgeBurn: r.dodgeBurn)
        #expect(model.canReset == (r != resetTarget), "canReset \(note)", sourceLocation: sourceLocation)
        #expect(model.canResetAll == model.hasEdits, sourceLocation: sourceLocation)
        #expect(model.selectedFilm?.id == r.filmID.flatMap { model.library.film(id: $0)?.id },
                "selectedFilm \(note)", sourceLocation: sourceLocation)
        #expect(model.curves == r.curves, "curves \(note)", sourceLocation: sourceLocation)
        #expect(model.colorMixer == r.colorMixer, "colorMixer \(note)", sourceLocation: sourceLocation)
        #expect(model.differsFromReference == (model.reference.map { r != $0 } ?? false),
                "differsFromReference \(note)", sourceLocation: sourceLocation)
    }

    @Test func storedAnswersFollowEveryKindOfRecipeChange() throws {
        let model = try Self.makeModel()
        Self.check(model, "at start")
        #expect(!model.hasEdits && !model.canReset)

        model.recipe.exposure = 0.4
        Self.check(model, "after exposure")
        #expect(model.hasEdits && model.canReset)

        model.selectFilm("fuji-velvia-50")
        Self.check(model, "after selectFilm")

        model.recipe.curves.rgb = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.62), CurvePoint(x: 1, y: 1)]
        Self.check(model, "after a curve")
        #expect(model.curves.rgb.count == 3)

        model.recipe.colorMixer[.red].hue = 0.2
        Self.check(model, "after the mixer")
        #expect(!model.colorMixer[.red].isZero)

        // A crop or strokes are edits, but Reset keeps them: canReset must not count them.
        model.reset()
        Self.check(model, "after reset")
        #expect(model.curves == Recipe.neutral.curves && model.colorMixer == Recipe.neutral.colorMixer)
        model.recipe.crop.straighten = 3
        Self.check(model, "after a crop")
        #expect(model.hasEdits && !model.canReset)
        model.recipe.dodgeBurn.strokes = [DodgeBurnStroke(mode: .burn, points: [StrokePoint(x: 0.3, y: 0.3)])]
        Self.check(model, "after a stroke")
        #expect(!model.canReset)

        model.resetAll()
        Self.check(model, "after resetAll")
        #expect(!model.hasEdits)
        #expect(model.selectedFilm == nil)

        // Whole-recipe replacement (a restored sidecar, a preset).
        var other = Recipe(filmID: "fuji-velvia-50", grainAmount: 0.4)
        other.warmth = 0.2
        model.recipe = other
        Self.check(model, "after replacing the recipe")
    }

    @Test func aLegacyRecipeWithNothingSetIsNotAnEdit() throws {
        let model = try Self.makeModel()
        var legacy = Recipe.neutral
        legacy.pipeline = 1
        model.recipe = legacy
        Self.check(model, "legacy")
        #expect(!model.hasEdits)
    }

    @Test func differsFromReferenceTracksTheSavedRecipe() throws {
        let model = try Self.makeModel()
        #expect(!model.differsFromReference, "no reference: never differs")
        model.reference = .neutral
        Self.check(model, "reference neutral")
        #expect(!model.differsFromReference)

        model.recipe.contrast = 0.3
        #expect(model.differsFromReference)
        let saved = model.recipe
        model.reference = saved
        #expect(!model.differsFromReference, "saving moves the reference")
        model.recipe.contrast = 0.31
        #expect(model.differsFromReference)
        model.recipe.contrast = 0.3
        #expect(!model.differsFromReference, "back to the saved look")
        model.reference = nil
        #expect(!model.differsFromReference)
        Self.check(model, "reference cleared")
    }

    @Test func canZoomIgnoresTheRecipeButFollowsTheSource() async throws {
        let model = try Self.makeModel()
        #expect(!model.canZoom)
        #expect(model.loadSource(url: SnapshotTests.root.appendingPathComponent("Fixtures/sample.jpg")))
        model.setViewport(pane: CGSize(width: 1200, height: 800), fitArea: CGSize(width: 1100, height: 700))
        #expect(model.canZoom)
        model.recipe.crop.rect = CropRect(x: 0.1, y: 0.1, w: 0.6, h: 0.6)
        #expect(model.canZoom)
        model.beginCrop()
        #expect(!model.canZoom, "not while the crop tool is open")
        model.cancelCrop()
        #expect(model.canZoom)
        model.cancelWork()
    }
}
