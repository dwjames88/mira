import AppKit
import MiraCore
import SwiftUI
import Testing
@testable import MiraUI

@MainActor
@Suite("Presets", .serialized)
struct PresetModelTests {
    static func tempStore() -> PresetStore {
        PresetStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mira-ui-presets-\(UUID().uuidString)"))
    }

    static func makeModel(store: PresetStore) async throws -> EditorModel {
        let root = SnapshotTests.root
        let library = try FilmLibrary(directory: root.appendingPathComponent("Films"))
        let model = EditorModel(library: library, presetStore: store)
        #expect(model.loadSource(url: root.appendingPathComponent("Fixtures/sample.jpg")))
        try await HoverTests.waitFor { model.previewImage != nil && model.isPreviewIdle }
        return model
    }

    @Test func saveThenApplyRestoresFilmAndDevelopValuesButNotCrop() async throws {
        let store = Self.tempStore()
        let model = try await Self.makeModel(store: store)
        let film = try #require(model.films.first(where: { $0.id == "fuji-velvia-50" }) ?? model.films.first)
        model.selectFilm(film.id)
        model.recipe.strength = 0.8
        model.recipe.exposure = 0.5
        model.recipe.contrast = 0.2
        model.recipe.grainAmount = 0.4
        model.recipe.vignetteAmount = 0.3
        model.recipe.curves.rgb = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)]
        model.recipe.crop.straighten = 3
        let saved = model.recipe

        let preset = try model.saveCurrentAsPreset(nickname: "  Last Summer ")
        #expect(preset.displayName == "\(film.displayName) - Last Summer")
        #expect(preset.recipe.crop == .identity)
        #expect(model.presets == [preset])

        // Change everything, including the crop.
        model.recipe = Recipe(filmID: nil, exposure: -1, saturation: 0.5)
        model.recipe.crop.straighten = -8
        let cropBefore = model.recipe.crop

        model.applyPreset(preset.id)
        var expected = saved
        expected.crop = cropBefore
        #expect(model.recipe == expected)
        #expect(model.recipe.filmID == film.id)
        #expect(model.recipe.exposure == 0.5)
        #expect(model.presetNotice == nil)
        #expect(model.isApplied(preset))
        #expect(model.appliedPresetID == preset.id)

        // Then it is ordinary recipe state: tweak freely.
        model.recipe.exposure = 0.1
        #expect(!model.isApplied(preset))
        #expect(model.appliedPresetID == nil)
        model.cancelWork()
    }

    @Test func missingFilmAppliesDevelopSettingsAndSaysSo() async throws {
        let store = Self.tempStore()
        let model = try await Self.makeModel(store: store)
        var r = Recipe(filmID: "removed-film-9000")
        r.exposure = 0.7
        r.warmth = 0.2
        let preset = try store.add(Preset(nickname: "Gone", recipe: r, filmName: "Portra 400"))
        model.refreshPresets()
        #expect(model.isFilmMissing(preset))
        model.recipe.crop.straighten = 2

        model.applyPreset(preset.id)
        #expect(model.recipe.filmID == nil)
        #expect(model.recipe.exposure == 0.7 && model.recipe.warmth == 0.2)
        #expect(model.recipe.crop.straighten == 2)
        #expect(model.presetNotice == "Portra 400 is not installed; applied develop settings only.")
        model.cancelWork()
    }

    @Test func noFilmPresetIsNamedOriginal() async throws {
        let model = try await Self.makeModel(store: Self.tempStore())
        model.recipe.contrast = 0.3
        let preset = try model.saveCurrentAsPreset(nickname: "Flat")
        #expect(preset.displayName == "Original - Flat")
        #expect(throws: PresetError.emptyNickname) { try model.saveCurrentAsPreset(nickname: "  ") }
        model.cancelWork()
    }

    @Test func hoverPreviewsThePresetWithoutTouchingTheRecipe() async throws {
        let store = Self.tempStore()
        let model = try await Self.makeModel(store: store)
        let film = try #require(model.films.first(where: { $0.family == .blackAndWhite }))
        var r = Recipe(filmID: film.id)
        r.contrast = 0.4
        let preset = try store.add(Preset(nickname: "Mono", recipe: r, filmName: film.displayName))
        model.refreshPresets()
        let before = model.recipe
        let applied = model.previewImage

        model.hoverPreset(preset.id)
        try await HoverTests.waitFor { model.hoverPreviewName != nil }
        #expect(model.hoverPreviewName == "\(film.displayName) - Mono")
        #expect(model.recipe == before)
        #expect(HoverTests.data(model.displayedImage) != HoverTests.data(applied))
        model.endHover()
        #expect(model.recipe == before)
        #expect(model.displayedImage === applied)
        model.cancelWork()
    }

    @Test func thumbnailsRenderOnTheFilmsTabAndFollowTheCrop() async throws {
        let store = Self.tempStore()
        let model = try await Self.makeModel(store: store)
        let preset = try model.saveCurrentAsPreset(nickname: "A")
        #expect(model.tab == .films)
        try await HoverTests.waitFor { model.presetThumbnails[preset.id] != nil }
        let first = try #require(model.presetThumbnails[preset.id])

        model.recipe.crop.rect = CropRect(x: 0.1, y: 0.1, w: 0.5, h: 0.5)
        try await HoverTests.waitFor { model.presetThumbnails[preset.id].map { $0 !== first } ?? false }
        #expect(model.presetThumbnails[preset.id] !== first)
        model.cancelWork()
    }

    @Test func presetsSavedElsewhereAppearAfterRefresh() async throws {
        let store = Self.tempStore()
        let model = try await Self.makeModel(store: store)
        let other = PresetStore(directory: store.directory)   // the other process
        let p = try other.add(nickname: "Over there", recipe: .neutral, filmName: nil)
        model.refreshPresets()
        #expect(model.presets == [p])
        model.duplicatePreset(p.id)
        #expect(model.presets.count == 2)
        model.deletePreset(p.id)
        #expect(model.presets.count == 1)
        model.cancelWork()
    }

    @Test func presetsHaveNoTabOfTheirOwn() {
        #expect(EditorTab.allCases == [.films, .develop, .crop])
        #expect(EditorTab.allCases.map(\.key) == ["1", "2", "3"])
        #expect(EditorTab.forKey("4") == nil)
    }

    @Test func thumbnailsWaitWhileAnotherTabIsOpenAndResumeOnFilms() async throws {
        let store = Self.tempStore()
        let model = try await Self.makeModel(store: store)
        model.selectTab(.develop)
        let preset = try model.saveCurrentAsPreset(nickname: "Later")
        model.refreshPresets()
        #expect(model.presetThumbnails[preset.id] == nil)
        model.selectTab(.films)
        try await HoverTests.waitFor { model.presetThumbnails[preset.id] != nil }
        model.cancelWork()
    }

    @Test func filmsStripListsPresetsAndAppliedPresetFollowsTheLook() async throws {
        let store = Self.tempStore()
        let model = try await Self.makeModel(store: store)
        model.recipe.contrast = 0.3
        let preset = try model.saveCurrentAsPreset(nickname: "Strip")
        #expect(model.presets.map(\.id) == [preset.id])
        #expect(model.appliedPresetID == preset.id)
        // Changing the family filter does not hide presets.
        model.familyFilter = .blackAndWhite
        #expect(model.presets.count == 1)
        model.recipe.contrast = 0.31
        #expect(model.appliedPresetID == nil)
        model.cancelWork()
    }
}
