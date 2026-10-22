import Foundation
import Testing
@testable import MiraCore

@Suite struct PresetTests {
    static func recipe() -> Recipe {
        var r = Recipe(filmID: "kodak-portra-400")
        r.exposure = 0.4; r.contrast = -0.2; r.grainAmount = 0.3; r.vignetteAmount = 0.25
        r.crop.straighten = 7
        return r
    }

    @Test func displayNameJoinsFilmAndNickname() {
        let p = Preset(nickname: "Last Summer", recipe: Self.recipe(), filmName: "Portra 400")
        #expect(p.displayName == "Portra 400 - Last Summer")
    }

    @Test func noFilmIsNamedOriginal() {
        let p = Preset(nickname: "Flat", recipe: Recipe(contrast: 0.1))
        #expect(p.filmName == "Original")
        #expect(p.filmID == nil)
        #expect(p.displayName == "Original - Flat")
    }

    @Test func filmNameComesFromLibrary() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Films")
        let library = try FilmLibrary(directory: dir)
        let film = try #require(library.films.first)
        let p = Preset(nickname: "Test", recipe: Recipe(filmID: film.id), library: library)
        #expect(p.filmName == film.displayName)
        #expect(p.displayName == "\(film.displayName) - Test")
    }

    @Test func cropIsNeverStored() {
        let p = Preset(nickname: "A", recipe: Self.recipe(), filmName: "Portra 400")
        #expect(p.recipe.crop == .identity)
        #expect(p.recipe.exposure == 0.4)
        var crop = CropSettings.identity
        crop.straighten = -3
        let applied = p.recipe(keeping: crop)
        #expect(applied.crop == crop)
        #expect(applied.filmID == "kodak-portra-400")
        #expect(applied.contrast == -0.2)
    }

    @Test func codableRoundTrip() throws {
        let p = Preset(nickname: "Last Summer", recipe: Self.recipe(), filmName: "Portra 400",
                       created: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try PresetStore.encode([p])
        let back = try PresetStore.decode(data)
        #expect(back == [p])
        #expect(try PresetStore.encode(back) == data)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"version\" : 1"))
    }

    @Test func minimalJSONDecodesWithDefaults() throws {
        let p = try JSONDecoder().decode(Preset.self, from: Data(#"{"nickname":"Bare"}"#.utf8))
        #expect(p.nickname == "Bare")
        #expect(p.recipe == .neutral)
        #expect(p.filmID == nil)
        #expect(p.filmName == "Original")
        #expect(p.version == 1)

        let q = try JSONDecoder().decode(Preset.self, from: Data(#"{"nickname":"X","recipe":{"filmID":"f","exposure":1},"future":1}"#.utf8))
        #expect(q.filmID == "f")
        #expect(q.filmName == "f")
        #expect(q.recipe.exposure == 1)
    }

    @Test func decodedCropIsDropped() throws {
        let json = #"{"nickname":"C","recipe":{"crop":{"straighten":9}}}"#
        let p = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        #expect(p.recipe.crop == .identity)
    }
}

@MainActor
@Suite("Preset store", .serialized) struct PresetStoreTests {
    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mira-presets-\(UUID().uuidString)")
    }

    static func recipe() -> Recipe { PresetTests.recipe() }

    @Test func addPersistsAcrossInstances() throws {
        let dir = Self.tempDir()
        let a = PresetStore(directory: dir)
        #expect(a.all.isEmpty)
        let p = try a.add(nickname: "  Last Summer ", recipe: Self.recipe(), filmName: "Portra 400")
        #expect(p.nickname == "Last Summer")
        let b = PresetStore(directory: dir)
        #expect(b.all == [p])
        #expect(b.preset(id: p.id)?.displayName == "Portra 400 - Last Summer")
        let json = try String(contentsOf: dir.appendingPathComponent("Presets.json"), encoding: .utf8)
        #expect(json.contains("\"presets\""))
    }

    @Test func emptyNicknameIsRejected() throws {
        let store = PresetStore(directory: Self.tempDir())
        #expect(throws: PresetError.emptyNickname) {
            try store.add(nickname: "   ", recipe: .neutral, filmName: nil)
        }
        let p = try store.add(nickname: "Ok", recipe: .neutral, filmName: nil)
        #expect(throws: PresetError.emptyNickname) { try store.rename(id: p.id, nickname: "\n") }
        #expect(throws: PresetError.notFound) { try store.rename(id: UUID(), nickname: "Z") }
        #expect(store.all.count == 1)
    }

    @Test func renameChangesOnlyTheNickname() throws {
        let dir = Self.tempDir()
        let store = PresetStore(directory: dir)
        let p = try store.add(nickname: "Old", recipe: Self.recipe(), filmName: "Portra 400")
        let r = try store.rename(id: p.id, nickname: " New ")
        #expect(r.nickname == "New")
        #expect(r.recipe == p.recipe && r.filmName == p.filmName && r.id == p.id)
        #expect(PresetStore(directory: dir).all.first?.nickname == "New")
    }

    @Test func duplicateMakesACopyWithANewID() throws {
        let dir = Self.tempDir()
        let store = PresetStore(directory: dir)
        let p = try store.add(nickname: "Last Summer", recipe: Self.recipe(), filmName: "Portra 400")
        let other = try store.add(nickname: "Winter", recipe: .neutral, filmName: nil)
        let copy = try store.duplicate(id: p.id)
        #expect(copy.id != p.id)
        #expect(copy.nickname == "Last Summer copy")
        #expect(copy.recipe == p.recipe)
        #expect(PresetStore(directory: dir).all.map(\.id) == [p.id, copy.id, other.id])
    }

    @Test func deletePersists() throws {
        let dir = Self.tempDir()
        let store = PresetStore(directory: dir)
        let p = try store.add(nickname: "A", recipe: .neutral, filmName: nil)
        let q = try store.add(nickname: "B", recipe: .neutral, filmName: nil)
        try store.delete(id: p.id)
        #expect(PresetStore(directory: dir).all.map(\.id) == [q.id])
        #expect(throws: PresetError.notFound) { try store.delete(id: p.id) }
    }

    @Test func corruptFileIsBackedUpAndStoreStartsEmpty() throws {
        let dir = Self.tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Presets.json")
        try Data("{ not json".utf8).write(to: file)
        let store = PresetStore(directory: dir)
        #expect(store.all.isEmpty)
        let bak = try Data(contentsOf: dir.appendingPathComponent("Presets.json.bak"))
        #expect(String(decoding: bak, as: UTF8.self) == "{ not json")
        // Still usable: saving replaces the damaged file.
        let p = try store.add(nickname: "Fresh", recipe: .neutral, filmName: nil)
        #expect(PresetStore(directory: dir).all == [p])
    }

    @Test func oneBadEntryDoesNotHideTheRest() throws {
        let dir = Self.tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"version":1,"presets":[{"nickname":"Good"},{"nickname":5},{"nickname":"Also"}]}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("Presets.json"))
        #expect(PresetStore(directory: dir).all.map(\.nickname) == ["Good", "Also"])
    }

    /// The app and the Photos extension each hold their own store on the same file.
    @Test func twoStoresOnTheSameDirectorySeeEachOther() throws {
        let dir = Self.tempDir()
        let app = PresetStore(directory: dir)
        let ext = PresetStore(directory: dir)
        #expect(app.all.isEmpty && ext.all.isEmpty)

        let p = try app.add(nickname: "From the app", recipe: Self.recipe(), filmName: "Portra 400")
        #expect(ext.reloadIfChanged())
        #expect(ext.all == [p])
        #expect(!ext.reloadIfChanged())

        let q = try ext.add(nickname: "From the extension", recipe: .neutral, filmName: nil)
        #expect(app.all.map(\.id) == [p.id, q.id])

        try ext.rename(id: p.id, nickname: "Renamed")
        #expect(app.preset(id: p.id)?.nickname == "Renamed")
        try app.delete(id: q.id)
        #expect(ext.all.map(\.id) == [p.id])
    }

    @Test func fallbackDirectoryWithoutAGroup() {
        let fallback = PresetStore.directory(groupContainer: nil)
        #expect(fallback.lastPathComponent == "Mira")
        #expect(fallback.deletingLastPathComponent().lastPathComponent == "Application Support")

        let group = URL(fileURLWithPath: "/tmp/group")
        #expect(PresetStore.directory(groupContainer: group).path == "/tmp/group/Library/Application Support/Mira")
        #expect(PresetStore.groupIdentifier == "VF945J28YU.com.fieldframes.mira")
    }
}
