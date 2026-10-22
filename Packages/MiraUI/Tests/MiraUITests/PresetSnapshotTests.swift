import AppKit
import MiraCore
import SwiftUI
import Testing
@testable import MiraUI

/// Renders the FILMS tab (presets + films), the Save Preset sheet and the duplicate dialog to `<repo>/build/snapshots/`.
@MainActor
@Suite("Preset snapshots", .serialized)
struct PresetSnapshotTests {
    @Test func renderFilmsTabWithPresetsAndSheets() async throws {
        FieldFramesTheme.registerFonts()
        let store = PresetModelTests.tempStore()
        let model = try await PresetModelTests.makeModel(store: store)
        let films = model.films
        let velvia = try #require(films.first(where: { $0.id == "fuji-velvia-50" }) ?? films.first)
        let mono = try #require(films.first(where: { $0.family == .blackAndWhite }))

        var a = Recipe(filmID: velvia.id); a.grainAmount = 0.4; a.halationAmount = 0.3
        var b = Recipe(filmID: mono.id); b.contrast = 0.35
        var c = Recipe(filmID: "removed-film-9000"); c.warmth = 0.3; c.exposure = 0.3
        for (nick, r, name) in [("Last Summer", a, velvia.displayName), ("Harbour Mono", b, mono.displayName),
                                ("Gone Fishing", c, "Portra 400")] {
            try store.add(Preset(nickname: nick, recipe: r, filmName: name))
        }
        model.recipe = a
        #expect(model.tab == .films)
        model.refreshPresets()
        try await HoverTests.waitFor(90) { model.presets.count == 3 && model.presetThumbnails.count == 3 }
        #expect(model.presetThumbnails.count == 3)
        try await HoverTests.waitFor { model.isPreviewIdle }

        for (scheme, tag) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            try SnapshotTests.writePNG(EditorView(model: model), size: CGSize(width: 1280, height: 800),
                                       scheme: scheme, name: "films-tab-presets-\(tag)")
        }
        let first = try #require(model.presets.first)
        model.hoverPreset(first.id)
        try SnapshotTests.writePNG(SavePresetSheet(model: model, mode: .save, initialNickname: "Last Summer"),
                                   size: CGSize(width: 352, height: 360), scheme: .dark, name: "save-preset-sheet-dark")
        try SnapshotTests.writePNG(SavePresetSheet(model: model, mode: .save, initialNickname: "Last Summer"),
                                   size: CGSize(width: 352, height: 360), scheme: .light, name: "save-preset-sheet-light")
        try SnapshotTests.writePNG(SavePresetSheet(model: model, mode: .save),
                                   size: CGSize(width: 352, height: 360), scheme: .dark, name: "save-preset-sheet-empty-dark")

        // The duplicate dialog, for a multi-file import (APPLY TO ALL shown).
        let existing = first
        var incomingRecipe = a; incomingRecipe.exposure = 0.5
        let incoming = Preset(nickname: first.nickname, recipe: incomingRecipe, filmName: first.filmName)
        let transfer = PresetTransfer(store: store, sharingEnabled: true)
        let conflict = PresetConflict(incoming: incoming, existing: existing, keepBothNickname: "\(first.nickname) 2",
                                      fileCount: 3, remaining: 1)
        for (scheme, tag) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            try SnapshotTests.writePNG(PresetConflictSheet(transfer: transfer, conflict: conflict, applyToAllOn: true),
                                       size: CGSize(width: 352, height: 360), scheme: scheme, name: "preset-duplicate-dialog-\(tag)")
        }

        // No presets yet: the single SAVE A PRESET slot ahead of the films.
        let empty = try await PresetModelTests.makeModel(store: PresetModelTests.tempStore())
        try await HoverTests.waitFor { empty.isPreviewIdle && empty.thumbnails.count > 4 }
        try SnapshotTests.writePNG(EditorView(model: empty), size: CGSize(width: 1280, height: 800),
                                   scheme: .dark, name: "films-tab-no-presets-dark")
        empty.cancelWork()
        model.cancelWork()
    }
}
