import CoreImage
import Foundation
import MiraCore
import Testing
@testable import MiraUI

@MainActor
@Suite("Film stocks and variants", .serialized)
struct FilmVariantTests {
    /// Two stocks (portra: three variants, one B&W) in a temp directory with identity-ish `.cube` LUTs.
    static func makeLibrary() throws -> FilmLibrary {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mira-variants-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Cube"), withIntermediateDirectories: true)
        var cube = "LUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { cube += "\(r) \(g) \(b)\n" } } }
        try cube.write(to: dir.appendingPathComponent("Cube/id.cube"), atomically: true, encoding: .utf8)
        func entry(_ id: String, _ name: String, _ family: String, parent: String? = nil, variant: String? = nil) -> String {
            var s = #"{"id":"\#(id)","displayName":"\#(name)","brand":"B","family":"\#(family)","iso":400,"description":"d","file":"Cube/id.cube""#
            if let parent { s += #","parent":"\#(parent)""# }
            if let variant { s += #","variant":"\#(variant)""# }
            return s + "}"
        }
        let json = "[" + [
            entry("portra", "Portra 400", "colorNegative"),
            entry("portra-m1", "Portra 400 \u{2212}1", "colorNegative", parent: "portra", variant: "\u{2212}1"),
            entry("portra-p1", "Portra 400 +1", "colorNegative", parent: "portra", variant: "+1"),
            entry("portra-p2", "Portra 400 +2", "colorNegative", parent: "portra", variant: "+2"),
            entry("trix", "Tri-X 400", "blackAndWhite"),
        ].joined(separator: ",") + "]"
        try json.write(to: dir.appendingPathComponent("films.json"), atomically: true, encoding: .utf8)
        return try FilmLibrary(directory: dir)
    }

    @Test func stripShowsStocksOnlyAndRespectsFamilyFilter() throws {
        let model = EditorModel(library: try Self.makeLibrary())
        #expect(model.visibleFilms.map(\.id) == ["portra", "trix"])
        model.familyFilter = .colorNegative
        #expect(model.visibleFilms.map(\.id) == ["portra"])
        model.familyFilter = .slide
        #expect(model.visibleFilms.isEmpty)
        #expect(model.visibleFilms.allSatisfy { !$0.isVariant })
    }

    @Test func selectingAVariantKeepsTheStockCardSelected() throws {
        let model = EditorModel(library: try Self.makeLibrary())
        model.selectFilm("portra-p1")
        #expect(model.selectedFilmID == "portra-p1")
        #expect(model.selectedStockID == "portra")
        #expect(model.selectedFilm?.displayName == "Portra 400 +1")
        model.selectFilm("trix")
        #expect(model.selectedStockID == "trix")
        model.selectFilm(nil)
        #expect(model.selectedStockID == nil)
    }

    @Test func variantChoicesListBaseThenVariants() throws {
        let library = try Self.makeLibrary()
        let fromBase = FilmVariantChoice.choices(for: "portra", in: library)
        #expect(fromBase.map(\.label) == ["Base", "\u{2212}1", "+1", "+2"])
        #expect(fromBase.map(\.id) == ["portra", "portra-m1", "portra-p1", "portra-p2"])
        #expect(fromBase.map(\.isBase) == [true, false, false, false])
        // Same list when a variant is the selected film.
        #expect(FilmVariantChoice.choices(for: "portra-p2", in: library) == fromBase)
        // No picker for a lone stock, Original or an unknown id.
        #expect(FilmVariantChoice.choices(for: "trix", in: library).isEmpty)
        #expect(FilmVariantChoice.choices(for: nil, in: library).isEmpty)
        #expect(FilmVariantChoice.choices(for: "nope", in: library).isEmpty)
        let model = EditorModel(library: library)
        model.selectFilm("portra-m1")
        #expect(model.variantChoices == fromBase)
    }

    @Test func selectFilmOptsIntoCurrentPipelineOnly() throws {
        var legacy = Recipe(filmID: "portra")
        legacy.pipeline = Recipe.legacyPipeline
        let model = EditorModel(library: try Self.makeLibrary(), recipe: legacy)
        model.recipe.exposure = 0.3
        #expect(model.recipe.pipeline == Recipe.legacyPipeline, "sliders keep the pipeline")
        model.selectFilm("portra-p1")
        #expect(model.recipe.pipeline == Recipe.currentPipeline)
        #expect(model.recipe.exposure == 0.3)
    }

    @Test func legacyRecipeOpenedUnchangedHasNoEdits() throws {
        var legacy = Recipe.neutral
        legacy.pipeline = Recipe.legacyPipeline
        let model = EditorModel(library: try Self.makeLibrary(), recipe: legacy)
        #expect(!model.hasEdits)
        #expect(!model.canResetAll)
        #expect(!model.canReset)
        model.recipe.exposure = 0.2
        #expect(model.hasEdits)
        #expect(model.canReset)
        model.reset()
        #expect(model.recipe.pipeline == Recipe.legacyPipeline, "Reset keeps the pipeline")
        #expect(!model.canReset)
    }

    @Test func legacyRecipeWithFilmIsNotDirtyAgainstItself() throws {
        var legacy = Recipe(filmID: "portra")
        legacy.pipeline = Recipe.legacyPipeline
        let model = EditorModel(library: try Self.makeLibrary(), recipe: legacy)
        #expect(!EditDirtyCheck.isDirty(current: model.recipe, loaded: legacy))
        model.selectFilm("portra")
        #expect(EditDirtyCheck.isDirty(current: model.recipe, loaded: legacy), "choosing a film is an edit")
    }

    @Test func applyingPresetKeepsItsOwnPipeline() throws {
        let library = try Self.makeLibrary()
        let model = EditorModel(library: library)
        var r = Recipe(filmID: "portra")
        r.pipeline = Recipe.legacyPipeline
        let preset = Preset(nickname: "Old", recipe: r, library: library)
        #expect(model.recipe(applying: preset).pipeline == Recipe.legacyPipeline)
    }

    @Test func thumbnailsAreRenderedForVisibleStocksOnly() async throws {
        let model = EditorModel(library: try Self.makeLibrary())
        model.familyFilter = .colorNegative
        model.setSource(CIImage(color: CIColor(red: 0.4, green: 0.3, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200)))
        try await HoverTests.waitFor(30) { model.thumbnails.count == 2 }
        #expect(Set(model.thumbnails.keys) == [EditorModel.originalTileID, "portra"])
        model.familyFilter = nil
        try await HoverTests.waitFor(30) { model.thumbnails.count == 3 }
        #expect(Set(model.thumbnails.keys) == [EditorModel.originalTileID, "portra", "trix"])
        model.cancelWork()
    }
}
