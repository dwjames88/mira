import MiraCore
import Testing
@testable import MiraUI

@MainActor
@Suite("Paper and scan chips", .serialized)
struct PaperChipsTests {
    static func library() throws -> FilmLibrary {
        try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
    }

    @Test func selectingPaperClearsScanAndViceVersa() throws {
        let model = EditorModel(library: try Self.library(), recipe: Recipe(filmID: "fuji-velvia-50"))
        model.selectScan(.frontier)
        #expect(model.recipe.scanProfile == .frontier && model.recipe.paper == .none)
        model.selectPaper(.cinemaPrint)
        #expect(model.recipe.paper == .cinemaPrint && model.recipe.scanProfile == .neutral)
        model.selectScan(.noritsu)
        #expect(model.recipe.scanProfile == .noritsu && model.recipe.paper == .none)
        model.selectPaper(.colorPaper)
        model.selectScan(.neutral)   // Neutral does not clear a paper
        #expect(model.recipe.paper == .colorPaper && model.recipe.scanProfile == .neutral)
        model.selectPaper(.none)
        #expect(model.recipe.paper == .none)
    }

    @Test func paperChipsAreHiddenOnPrintCards() throws {
        let model = EditorModel(library: try Self.library(), recipe: Recipe(filmID: "fuji-velvia-50"))
        #expect(model.showsPaperChips)
        model.selectFilm("cinema-print")
        #expect(!model.showsPaperChips)
        model.recipe = .neutral
        #expect(!model.showsPaperChips)
    }

    @Test func paperChipsAreHiddenOnMonochromeFilms() throws {
        let lib = try Self.library()
        let mono = try #require(lib.films.first { $0.isMonochrome && $0.family != .print })
        let model = EditorModel(library: lib, recipe: Recipe(filmID: mono.id))
        #expect(model.showsToning)
        #expect(!model.showsPaperChips)
    }

    @Test func familyTabsIncludeMotionPictureAndPrint() throws {
        let model = EditorModel(library: try Self.library())
        #expect(model.availableFamilies.contains(.motionPicture))
        #expect(model.availableFamilies.contains(.print))
    }
}
