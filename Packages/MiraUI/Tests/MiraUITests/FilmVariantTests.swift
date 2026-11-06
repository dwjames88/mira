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

    @Test func variationChoicesListStandardThenVariations() throws {
        let model = EditorModel(library: try Self.makeLibrary())
        #expect(model.variationChoices.isEmpty && model.isoChoices.isEmpty, "Original has no chips")
        model.selectFilm("portra-m1")
        #expect(model.variationChoices.map(\.label) == ["Standard", "\u{2212}1", "+1", "+2"])
        #expect(model.variationChoices.map(\.filmID) == ["portra", "portra-m1", "portra-p1", "portra-p2"])
        #expect(model.isoChoices.isEmpty, "a single ISO hides the ISO row")
        model.selectFilm("trix")
        #expect(model.variationChoices.isEmpty && model.isoChoices.isEmpty)
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

    @Test func familyTabsListOnlyPresentFamiliesInDisplayOrder() throws {
        let model = EditorModel(library: try Self.makeLibrary())
        #expect(model.availableFamilies == [.colorNegative, .blackAndWhite])
    }
}

@MainActor
@Suite("Film controls", .serialized)
struct FilmControlTests {
    private func library(remJet: Bool) throws -> FilmLibrary {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mira-ctl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Cube"), withIntermediateDirectories: true)
        var cube = "LUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { cube += "\(r) \(g) \(b)\n" } } }
        try cube.write(to: dir.appendingPathComponent("Cube/id.cube"), atomically: true, encoding: .utf8)
        let json = """
        [{"id":"cine","displayName":"Cine","brand":"B","family":"colorNegative","iso":500,"description":"d","file":"Cube/id.cube","character":{"remJet":\(remJet)}},
         {"id":"bw","displayName":"BW","brand":"B","family":"blackAndWhite","iso":400,"description":"d","file":"Cube/id.cube"}]
        """
        try json.write(to: dir.appendingPathComponent("films.json"), atomically: true, encoding: .utf8)
        return try FilmLibrary(directory: dir)
    }

    @Test func remJetToggleOnlyForRemJetFilms() throws {
        let yes = EditorModel(library: try library(remJet: true))
        let no = EditorModel(library: try library(remJet: false))
        #expect(!yes.showsRemJetToggle)   // Original
        yes.selectFilm("cine"); no.selectFilm("cine")
        #expect(yes.showsRemJetToggle)
        #expect(!no.showsRemJetToggle)
        yes.selectFilm("bw")
        #expect(!yes.showsRemJetToggle)
    }

    @Test func toningOnlyForMonochromeFilms() throws {
        let model = EditorModel(library: try library(remJet: false))
        #expect(!model.showsToning && !model.showsFilmControls)
        model.selectFilm("cine")
        #expect(model.showsFilmControls && !model.showsToning)
        model.selectFilm("bw")
        #expect(model.showsToning)
    }

    @Test func pushSnapsToThirdsAndFormats() {
        #expect(PushFormat.snapped(0.1) == 0)
        #expect(abs(PushFormat.snapped(0.4) - 1.0 / 3) < 1e-9)
        #expect(PushFormat.snapped(5) == 2 && PushFormat.snapped(-5) == -2)
        #expect(PushFormat.label(0) == "0")
        #expect(PushFormat.label(1) == "+1")
        #expect(PushFormat.label(4.0 / 3) == "+1\u{2153}")
        #expect(PushFormat.label(-2.0 / 3) == "\u{2212}\u{2154}")
        #expect(PushFormat.label(-2) == "\u{2212}2")
        #expect(PushFormat.label(1.0 / 3) == "+\u{2153}")
    }

    @Test func resetClearsFilmAndRawSettingsButKeepsFilmAndPipeline() throws {
        let model = EditorModel(library: try library(remJet: true))
        model.selectFilm("bw")
        model.recipe.push = 1; model.recipe.remJetRemoved = true
        model.recipe.scanProfile = .noritsu; model.recipe.toning = .sepia; model.recipe.toningStrength = 0.9
        model.recipe.raw.boostAmount = 0.3
        #expect(model.canReset)
        model.reset()
        let r = model.recipe
        #expect(r.push == 0 && !r.remJetRemoved && r.scanProfile == .neutral && r.toning == .none && r.toningStrength == 0.5)
        #expect(r.raw.isIdentity)
        #expect(r.filmID == "bw" && r.pipeline == Recipe.currentPipeline)
        #expect(!model.canReset)
        model.resetAll()
        #expect(model.recipe == .neutral)
    }

    @Test func legacyControlsKeepThePipelineAndFilmScienceControlsUpgradeIt() throws {
        var legacy = Recipe(filmID: "bw"); legacy.pipeline = Recipe.legacyPipeline
        let model = EditorModel(library: try library(remJet: false), recipe: legacy)
        model.recipe.grainAmount = 0.4; model.recipe.strength = 0.7
        #expect(model.recipe.pipeline == Recipe.legacyPipeline)
        // Push, toning and scan do nothing on pipeline 1, so changing one moves the recipe up in the same edit.
        model.recipe.push = 1
        #expect(model.recipe.pipeline == Recipe.currentPipeline)
    }
}

/// ISO and Variations chips against the bundled catalog.
@MainActor
@Suite("Stock ISO and variation chips", .serialized)
struct StockChipTests {
    static func makeModel(_ film: String?) throws -> EditorModel {
        let library = try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
        return EditorModel(library: library, recipe: Recipe(filmID: film))
    }

    @Test func stripHasOneCardPerStockTitledByStockName() throws {
        let model = try Self.makeModel(nil)
        let cards = model.visibleFilms
        #expect(cards.count == model.library.filmStocks.count)
        #expect(cards.allSatisfy { $0.isStockBase && $0.stockName != nil })
        #expect(cards.contains { $0.stockName == "Portra" && $0.id == "kodak-portra-400" })
        model.familyFilter = .instant
        #expect(model.visibleFilms.allSatisfy { $0.family == .instant } && !model.visibleFilms.isEmpty)
    }

    @Test func clickingACardAppliesTheBaseFilm() throws {
        let model = try Self.makeModel("fuji-superia-100")
        let portra = try #require(model.library.stock(id: "kodak-portra"))
        model.selectStock(portra)
        #expect(model.selectedFilmID == "kodak-portra-400" && model.recipe.filmID == "kodak-portra-400")
        #expect(model.selectedStockID == "kodak-portra" && model.selectedCardID == "kodak-portra-400")
    }

    @Test func oldPresetFilmShowsStockIsoAndVariation() throws {
        let model = try Self.makeModel("kodak-portra-400-plus-1")
        #expect(model.selectedStockID == "kodak-portra")
        #expect(model.selectedCardID == "kodak-portra-400")
        #expect(model.selectedFilm?.iso == 400 && model.selectedFilm?.variationLabel == "+1")
        #expect(model.isoChoices.map(\.label) == ["160", "400", "800"])
        let selected = model.variationChoices.first { $0.filmID == model.selectedFilmID }
        #expect(selected?.variation == "+1")
        #expect(model.selectedFilm?.displayName == "Portra 400 +1")
    }

    @Test func isoThenVariationAppliesTheRightFilm() throws {
        let model = try Self.makeModel("kodak-portra-400")
        model.selectISO(800)
        #expect(model.recipe.filmID == "kodak-portra-800")
        let plusOne = try #require(model.variationChoices.first { $0.variation == "+1" })
        model.selectFilm(plusOne.filmID)
        #expect(model.recipe.filmID == "kodak-portra-800-plus-1")
        model.selectISO(160)   // keeps +1
        #expect(model.recipe.filmID == "kodak-portra-160-plus-1")
        model.selectFilm("kodak-portra-400-nc")
        model.selectISO(800)   // 800 has no NC: back to Standard
        #expect(model.recipe.filmID == "kodak-portra-800")
        #expect(model.selectedStockID == "kodak-portra")
    }

    @Test func proviaFourHundredHasNoStandardChip() throws {
        let model = try Self.makeModel("fuji-provia-100f")
        #expect(model.isoChoices.map(\.label) == ["100F", "400"])
        #expect(model.variationChoices.map(\.label) == ["Standard", "Generic"])
        model.selectISO(400)
        #expect(model.recipe.filmID == "fuji-provia-400f")
        #expect(model.variationChoices.map(\.label) == ["F", "X"])
        model.selectFilm(model.variationChoices[1].filmID)
        #expect(model.recipe.filmID == "fuji-provia-400x")
    }

    @Test func singletonStocksShowNoChipRows() throws {
        let model = try Self.makeModel("kodak-ektar-100")
        #expect(model.isoChoices.isEmpty && model.variationChoices.isEmpty)
        #expect(model.selectedStockID == "kodak-ektar-100")
    }
}
