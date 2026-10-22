import AppKit
import MiraCore
import SwiftUI
import Testing
@testable import MiraUI

/// The menu path (Preset > Import Presets...) ends in `PresetTransfer.importPresets(from:)`; these drive that
/// function with `.mirapreset` fixtures, answering the duplicate dialog the way its buttons do.
@MainActor
@Suite("Preset import UI", .serialized)
struct PresetTransferTests {
    struct Fixtures {
        let dir: URL
        let fresh: URL
        let duplicate: URL
        let missingFilm: URL
        let duplicate2: URL
    }

    static func fixtures(film: Film) throws -> Fixtures {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mira-ui-import-\(UUID().uuidString)")
        func make(_ nick: String, filmID: String?, filmName: String, exposure: Double) throws -> URL {
            var r = Recipe(filmID: filmID); r.exposure = exposure; r.grainAmount = 0.3
            return try PresetFile.write(Preset(nickname: nick, recipe: r, filmName: filmName), into: dir, appVersion: "0.3.1")
        }
        return Fixtures(
            dir: dir,
            fresh: try make("Fresh", filmID: film.id, filmName: film.displayName, exposure: 0.2),
            duplicate: try make("Last Summer", filmID: film.id, filmName: film.displayName, exposure: 0.9),
            missingFilm: try make("Gone Fishing", filmID: "removed-film-9000", filmName: "Portra 400", exposure: 0.1),
            duplicate2: try make("Harbour", filmID: film.id, filmName: film.displayName, exposure: 0.8))
    }

    static func waitForConflict(_ transfer: PresetTransfer) async throws {
        try await HoverTests.waitFor { transfer.conflict != nil }
    }

    @Test func importWithDuplicateAndMissingFilm() async throws {
        let store = PresetModelTests.tempStore()
        let transfer = PresetTransfer(store: store, sharingEnabled: true)
        let model = EditorModel(library: try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films")),
                                presetStore: store, transfer: transfer)
        #expect(model.loadSource(url: SnapshotTests.root.appendingPathComponent("Fixtures/sample.jpg")))
        let film = try #require(model.films.first)
        let files = try Self.fixtures(film: film)
        defer { try? FileManager.default.removeItem(at: files.dir) }
        let saved = try store.add(Preset(nickname: "Last Summer", recipe: Recipe(filmID: film.id), filmName: film.displayName))
        model.refreshPresets()

        let task = Task { await transfer.importPresets(from: [files.fresh, files.duplicate, files.missingFilm]) }
        try await Self.waitForConflict(transfer)
        let conflict = try #require(transfer.conflict)
        #expect(conflict.existing.id == saved.id)
        #expect(conflict.incoming.displayName == "\(film.displayName) - Last Summer")
        #expect(conflict.keepBothNickname == "Last Summer 2")
        transfer.resolveConflict(.keepBoth)
        let outcome = await task.value

        #expect(transfer.conflict == nil)
        #expect(outcome.added.count == 3 && outcome.failures.isEmpty)
        #expect(transfer.notice == "Imported 3 presets.")
        #expect(model.presets.map(\.nickname) == ["Last Summer", "Fresh", "Last Summer 2", "Gone Fishing"])
        let gone = try #require(model.presets.first { $0.nickname == "Gone Fishing" })
        #expect(model.isFilmMissing(gone))
        #expect(gone.recipe.crop == .identity)
        model.cancelWork()
    }

    @Test func skipReplaceAndApplyToAll() async throws {
        let store = PresetModelTests.tempStore()
        let transfer = PresetTransfer(store: store, sharingEnabled: true)
        let library = try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
        let film = try #require(library.films.first)
        let files = try Self.fixtures(film: film)
        defer { try? FileManager.default.removeItem(at: files.dir) }
        let a = try store.add(Preset(nickname: "Last Summer", recipe: Recipe(filmID: film.id), filmName: film.displayName))
        let b = try store.add(Preset(nickname: "Harbour", recipe: Recipe(filmID: film.id), filmName: film.displayName))

        // Replace for both with APPLY TO ALL: one question only.
        var task = Task { await transfer.importPresets(from: [files.duplicate, files.duplicate2]) }
        try await Self.waitForConflict(transfer)
        #expect(transfer.conflict?.fileCount == 2)
        transfer.resolveConflict(.replace, toAll: true)
        var outcome = await task.value
        #expect(outcome.replaced.count == 2)
        #expect(store.all.map(\.id) == [a.id, b.id])
        #expect(store.preset(id: a.id)?.recipe.exposure == 0.9)
        #expect(store.preset(id: b.id)?.recipe.exposure == 0.8)

        // Skip.
        task = Task { await transfer.importPresets(from: [files.duplicate]) }
        try await Self.waitForConflict(transfer)
        transfer.resolveConflict(.skip)
        outcome = await task.value
        #expect(outcome.skipped.count == 1 && store.all.count == 2)
        #expect(transfer.notice == "Skipped 1.")
    }

    @Test func badFilesAreListedByName() async throws {
        let store = PresetModelTests.tempStore()
        let transfer = PresetTransfer(store: store, sharingEnabled: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mira-ui-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("not-a-preset.mirapreset")
        try Data("{}".utf8).write(to: bad)
        let future = dir.appendingPathComponent("future.mirapreset")
        try Data(#"{"format":"com.fieldframes.mira.preset","schemaVersion":9,"preset":{"nickname":"X"}}"#.utf8).write(to: future)
        let outcome = await transfer.importPresets(from: [bad, future])
        #expect(outcome.importedCount == 0)
        #expect(transfer.notice?.contains("not-a-preset.mirapreset (not a Mira preset file)") == true)
        #expect(transfer.notice?.contains("future.mirapreset (made by a newer version of Mira)") == true)
        #expect(store.all.isEmpty)
    }

    @Test func nonPresetFilesAreIgnoredByStartImport() async throws {
        let transfer = PresetTransfer(store: PresetModelTests.tempStore(), sharingEnabled: true)
        transfer.startImport([URL(fileURLWithPath: "/tmp/photo.jpg")])
        #expect(!transfer.isImporting)
        #expect(transfer.notice == nil)
    }

    @Test func exportAllWritesOneFilePerPreset() throws {
        let store = PresetModelTests.tempStore()
        try store.add(Preset(nickname: "A/B", recipe: Recipe(filmID: "x"), filmName: "Film: One"))
        try store.add(Preset(nickname: "C", recipe: Recipe(), filmName: nil))
        let transfer = PresetTransfer(store: store, sharingEnabled: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mira-ui-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = transfer.exportAll(to: folder)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["Film- One - A-B.mirapreset", "Original - C.mirapreset"])
        #expect(text == "Exported 2 presets to \(folder.lastPathComponent).")
    }

    @Test func extensionSideTransferHasSharingOff() throws {
        let library = try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
        let model = EditorModel(library: library, presetStore: PresetModelTests.tempStore())
        #expect(!model.transfer.sharingEnabled)
    }
}
