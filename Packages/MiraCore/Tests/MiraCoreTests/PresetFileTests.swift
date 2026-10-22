import Foundation
import Testing
@testable import MiraCore

@Suite("Preset files", .serialized)
struct PresetFileTests {
    static func fullRecipe() -> Recipe {
        var r = Recipe(filmID: "kodak-portra-400")
        r.strength = 0.8; r.exposure = 0.4; r.contrast = -0.2; r.saturation = 0.1; r.warmth = 0.15; r.tint = -0.05
        r.highlights = -0.3; r.shadows = 0.25; r.whites = 0.1; r.blacks = -0.1
        r.vibrance = 0.2; r.clarity = 0.35; r.texture = -0.15
        r.grainAmount = 0.3; r.grainSize = 0.7; r.halationAmount = 0.2; r.halationRadius = 0.6
        r.bloomAmount = 0.1; r.vignetteAmount = 0.25; r.borderEnabled = true; r.borderWidth = 0.06
        r.curves.rgb = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.62), CurvePoint(x: 1, y: 1)]
        r.crop.straighten = 7
        return r
    }

    static func preset(_ nick: String = "Last Summer", film: String = "Portra 400") -> Preset {
        Preset(nickname: nick, recipe: fullRecipe(), filmName: film, created: Date(timeIntervalSince1970: 1_700_000_000.123))
    }

    @Test func roundTripKeepsEveryDevelopField() throws {
        let original = Self.preset()
        let data = try PresetFile.encode(original, appVersion: "0.3.1")
        let back = try PresetFile.decode(data)
        #expect(back.nickname == "Last Summer")
        #expect(back.filmID == "kodak-portra-400")
        #expect(back.filmName == "Portra 400")
        #expect(back.created == original.created)
        #expect(back.id != original.id)   // a new identity on the receiving side
        #expect(back.recipe == original.recipe)
        #expect(back.recipe.crop == .identity)
        #expect(back.recipe.texture == -0.15 && back.recipe.clarity == 0.35 && back.recipe.blacks == -0.1)
        #expect(!back.recipe.curves.isIdentity)
    }

    @Test func fileLayoutAndSortedKeys() throws {
        let data = try PresetFile.encode(Self.preset(), appVersion: "0.3.1", exported: Date(timeIntervalSince1970: 1_700_000_000))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["format"] as? String == "com.fieldframes.mira.preset")
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["appVersion"] as? String == "0.3.1")
        #expect(object["exported"] as? String == "2023-11-14T22:13:20.000Z")
        let preset = try #require(object["preset"] as? [String: Any])
        #expect(Set(preset.keys) == ["nickname", "filmID", "filmName", "created", "recipe"])
        let recipe = try #require(preset["recipe"] as? [String: Any])
        let crop = try #require(recipe["crop"] as? [String: Any])
        #expect(crop["straighten"] as? Double == 0)
        let text = String(decoding: data, as: UTF8.self)
        let top = ["appVersion", "exported", "format", "preset", "schemaVersion"].compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(top == top.sorted())
        #expect(try PresetFile.encode(Self.preset(), appVersion: "0.3.1", exported: Date(timeIntervalSince1970: 5))
                == PresetFile.encode(Self.preset(), appVersion: "0.3.1", exported: Date(timeIntervalSince1970: 5)))
    }

    @Test func fileNamesAreSanitized() {
        #expect(PresetFile.fileName(for: Self.preset()) == "Portra 400 - Last Summer.mirapreset")
        #expect(PresetFile.fileName(for: Self.preset("A/B: C")) == "Portra 400 - A-B- C.mirapreset")
        #expect(PresetFile.sanitized("..hidden. ") == "hidden")
        #expect(PresetFile.sanitized("a\\b\nc") == "a-bc")
        #expect(PresetFile.sanitized("///") == "---")
        #expect(PresetFile.sanitized("  ") == "Preset")
    }

    @Test func rejectsWrongFormatAndGarbage() throws {
        #expect(throws: PresetFileError.notAPresetFile) { try PresetFile.decode(Data("not json at all".utf8)) }
        #expect(throws: PresetFileError.notAPresetFile) { try PresetFile.decode(Data("[1,2,3]".utf8)) }
        #expect(throws: PresetFileError.notAPresetFile) { try PresetFile.decode(Data()) }
        let wrong = #"{"format":"com.example.other","schemaVersion":1,"preset":{"nickname":"X"}}"#
        #expect(throws: PresetFileError.notAPresetFile) { try PresetFile.decode(Data(wrong.utf8)) }
        let noFormat = #"{"schemaVersion":1,"preset":{"nickname":"X"}}"#
        #expect(throws: PresetFileError.notAPresetFile) { try PresetFile.decode(Data(noFormat.utf8)) }
        // Mira's own Presets.json is not a share file either.
        let store = try PresetStore.encode([Self.preset()])
        #expect(throws: PresetFileError.notAPresetFile) { try PresetFile.decode(store) }
    }

    @Test func rejectsNewerSchema() throws {
        let future = #"{"format":"com.fieldframes.mira.preset","schemaVersion":2,"preset":{"nickname":"X"}}"#
        #expect(throws: PresetFileError.newerVersion(2)) { try PresetFile.decode(Data(future.utf8)) }
        #expect(PresetFileError.newerVersion(2).description.contains("newer version"))
    }

    @Test func rejectsMissingNickname() throws {
        for body in [#"{"filmName":"Portra 400"}"#, #"{"nickname":"   "}"#, #"{"nickname":null}"#, "{}"] {
            let text = #"{"format":"com.fieldframes.mira.preset","schemaVersion":1,"preset":"# + body + "}"
            #expect(throws: PresetFileError.missingNickname, "\(body)") { try PresetFile.decode(Data(text.utf8)) }
        }
        let noPreset = #"{"format":"com.fieldframes.mira.preset","schemaVersion":1}"#
        #expect(throws: PresetFileError.notAPresetFile) { try PresetFile.decode(Data(noPreset.utf8)) }
    }

    @Test func acceptsUnknownKeysAndMissingFields() throws {
        let text = """
        {"format":"com.fieldframes.mira.preset","schemaVersion":1,"extra":{"a":1},"shared_by":"someone",
         "preset":{"nickname":" Mono ","filmID":"ilford-hp5","wow":true,
                   "recipe":{"exposure":0.5,"futureSlider":0.9,"crop":{"straighten":12}}}}
        """
        let p = try PresetFile.decode(Data(text.utf8))
        #expect(p.nickname == "Mono")
        #expect(p.filmID == "ilford-hp5")
        #expect(p.filmName == "ilford-hp5")   // no filmName in the file: the id stands in
        #expect(p.recipe.exposure == 0.5)
        #expect(p.recipe.strength == 1)       // missing keys fall back to defaults
        #expect(p.recipe.crop == .identity)   // crop is stripped
    }

    @Test func keepBothNumbersTheNickname() {
        let a = Self.preset("Last Summer")
        #expect(PresetFile.uniqueNickname("Other", filmName: "Portra 400", among: [a]) == "Other")
        #expect(PresetFile.uniqueNickname("Last Summer", filmName: "Portra 400", among: [a]) == "Last Summer 2")
        #expect(PresetFile.uniqueNickname("last summer", filmName: "portra 400", among: [a]) == "last summer 2")
        let b = Self.preset("Last Summer 2")
        #expect(PresetFile.uniqueNickname("Last Summer", filmName: "Portra 400", among: [a, b]) == "Last Summer 3")
        #expect(PresetFile.uniqueNickname("Last Summer", filmName: "Velvia 50", among: [a, b]) == "Last Summer")
    }

    @Test func writesUniquelyNamedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mira-pf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let one = try PresetFile.write(Self.preset(), into: dir, appVersion: "0.3.1")
        let two = try PresetFile.write(Self.preset(), into: dir, appVersion: "0.3.1")
        #expect(one.lastPathComponent == "Portra 400 - Last Summer.mirapreset")
        #expect(two.lastPathComponent == "Portra 400 - Last Summer 2.mirapreset")
        #expect(try PresetFile.read(one).recipe == Self.preset().recipe)
        #expect(PresetFile.isPresetFile(one))
        #expect(!PresetFile.isPresetFile(dir.appendingPathComponent("a.json")))
    }
}

@MainActor
@Suite("Preset import", .serialized)
struct PresetImportTests {
    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mira-pi-\(UUID().uuidString)")
    }

    @Test func importsReplacesKeepsBothAndReportsFailures() async throws {
        let store = PresetStore(directory: Self.tempDir())
        let files = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: files); try? FileManager.default.removeItem(at: store.directory) }
        let existing = try store.add(PresetFileTests.preset("Last Summer"))
        var changed = PresetFileTests.fullRecipe(); changed.exposure = -0.9
        let dup = Preset(nickname: "Last Summer", recipe: changed, filmName: "Portra 400")
        let fresh = PresetFileTests.preset("Harbour", film: "Velvia 50")
        let dupURL = try PresetFile.write(dup, into: files, appVersion: "0.3.1")
        let freshURL = try PresetFile.write(fresh, into: files, appVersion: "0.3.1")
        let bad = files.appendingPathComponent("broken.mirapreset")
        try Data("nope".utf8).write(to: bad)

        var asked: [(String, Int)] = []
        var outcome = await store.importPresets(from: [dupURL, freshURL, bad]) { incoming, old, remaining in
            asked.append((incoming.displayName, remaining))
            #expect(old.id == existing.id)
            return .keepBoth
        }
        #expect(asked.count == 1 && asked[0].0 == "Portra 400 - Last Summer")
        #expect(outcome.added.map(\.displayName) == ["Portra 400 - Last Summer 2", "Velvia 50 - Harbour"])
        #expect(outcome.failures == [PresetImportFailure(fileName: "broken.mirapreset", reason: "not a Mira preset file")])
        #expect(store.all.count == 3)
        #expect(outcome.summary == "Imported 2 presets. Could not import: broken.mirapreset (not a Mira preset file).")

        // Replace keeps the id and the place in the list.
        outcome = await store.importPresets(from: [dupURL]) { _, _, _ in .replace }
        #expect(outcome.replaced.count == 1 && outcome.added.isEmpty)
        let replaced = try #require(store.preset(id: existing.id))
        #expect(replaced.recipe.exposure == -0.9)
        #expect(store.all.first?.id == existing.id)
        #expect(store.all.count == 3)
        #expect(outcome.summary == "Imported 1 preset (1 replaced).")

        // Skip leaves the store alone.
        outcome = await store.importPresets(from: [dupURL]) { _, _, _ in .skip }
        #expect(outcome.importedCount == 0 && outcome.skipped == ["Portra 400 - Last Summer"])
        #expect(store.all.count == 3)
        #expect(outcome.summary == "Skipped 1.")
    }

    @Test func importedPresetsReachTheSharedFile() async throws {
        let dir = Self.tempDir()
        let files = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: files); try? FileManager.default.removeItem(at: dir) }
        let url = try PresetFile.write(PresetFileTests.preset(), into: files, appVersion: "0.3.1")
        let app = PresetStore(directory: dir)
        _ = await app.importPresets(from: [url]) { _, _, _ in .skip }
        let extensionSide = PresetStore(directory: dir)
        #expect(extensionSide.all.map(\.displayName) == ["Portra 400 - Last Summer"])
    }
}
