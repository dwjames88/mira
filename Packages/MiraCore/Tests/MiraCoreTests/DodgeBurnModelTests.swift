import Foundation
import Testing
@testable import MiraCore

@Suite struct DodgeBurnModelTests {
    static func stroke(_ mode: DodgeBurnMode = .dodge, at points: [(Double, Double)] = [(0.5, 0.5)],
                       size: Double = 0.1, strength: Double = 1, flow: Double = 1, feather: Double = 0.5) -> DodgeBurnStroke {
        DodgeBurnStroke(mode: mode, points: points.map { StrokePoint(x: $0.0, y: $0.1) }, size: size,
                        feather: feather, flow: flow, strength: strength)
    }

    static let painted: Recipe = {
        var r = Recipe(filmID: "kodak-portra-400", exposure: 0.1)
        var a = stroke(.dodge, at: [(0.1, 0.2), (0.2, 0.25), (0.31234567, 0.4)], size: 0.07, strength: 0.6)
        a.points[1].pressure = 0.4
        a.range = .shadows; a.protectTones = false; a.lumaRange = LumaRange(low: 0.1, high: 0.7, softness: 0.2)
        var b = stroke(.burn, at: [(0.7, 0.7)])
        b.hidden = true
        r.dodgeBurn = DodgeBurnSettings(strokes: [a, b, stroke(.erase)])
        return r
    }()

    @Test func roundTrip() throws {
        let back = try Recipe.decode(Self.painted.encoded())
        #expect(back.dodgeBurn.strokes.count == 3)
        #expect(back.dodgeBurn.strokes[0].range == .shadows)
        #expect(back.dodgeBurn.strokes[0].protectTones == false)
        #expect(back.dodgeBurn.strokes[0].lumaRange == LumaRange(low: 0.1, high: 0.7, softness: 0.2))
        #expect(back.dodgeBurn.strokes[0].points[1].pressure == 0.4)
        #expect(back.dodgeBurn.strokes[1].hidden && !back.dodgeBurn.strokes[0].hidden)
        #expect(back.dodgeBurn.strokes[2].mode == .erase)
        // Points are rounded to four decimals on disk; a second round trip is exact.
        #expect(abs(back.dodgeBurn.strokes[0].points[2].x - 0.3123) < 1e-9)
        #expect(try Recipe.decode(back.encoded()) == back)
    }

    @Test func identityIsNotWritten() throws {
        let text = String(decoding: try Recipe.neutral.encoded(), as: UTF8.self)
        #expect(!text.contains("dodgeBurn"))
        #expect(try Recipe.decode(Recipe.neutral.encoded()).dodgeBurn.isIdentity)
        #expect(try String(decoding: Self.painted.encoded(), as: UTF8.self).contains("dodgeBurn"))
    }

    @Test func olderDataDecodesAsIdentity() throws {
        let v1 = Data(#"{"filmID":"x","strength":0.5,"exposure":0.3}"#.utf8)
        let v2 = Data(#"{"filmID":"x","highlights":0.3,"crop":{"straighten":3}}"#.utf8)
        for data in [v1, v2] {
            let r = try Recipe.decode(data)
            #expect(r.dodgeBurn.isIdentity && !r.usesDodgeBurn)
        }
        // Damaged values are clamped, not fatal.
        let odd = Data(#"{"dodgeBurn":{"strokes":[{"mode":"bogus","points":[0.1,0.2,2,0.3],"size":9,"strength":-3}]}}"#.utf8)
        let s = try #require(try Recipe.decode(odd).dodgeBurn.strokes.first)
        #expect(s.mode == .dodge && s.points.count == 1 && s.points[0].pressure == 1)
        #expect(s.size == DodgeBurnStroke.sizeRange.upperBound && s.strength == 0)
    }

    @Test func formatVersionThreeOnlyWithStrokes() throws {
        #expect(try MiraAdjustment.adjustmentData(for: .neutral).formatVersion == "1")
        #expect(try MiraAdjustment.adjustmentData(for: Recipe(highlights: 0.2)).formatVersion == "2")
        let withStrokes = Self.painted
        let adj = try MiraAdjustment.adjustmentData(for: withStrokes)
        #expect(adj.formatVersion == "3")
        #expect(MiraAdjustment.canHandle(adj))
        #expect(MiraAdjustment.recipe(from: adj) == (try Recipe.decode(withStrokes.encoded())))
        // Strokes win over the tone controls' version 2.
        var both = withStrokes; both.highlights = 0.3
        #expect(try MiraAdjustment.adjustmentData(for: both).formatVersion == "3")
        // Removing every stroke goes back to the old versions.
        var cleared = withStrokes; cleared.dodgeBurn = .identity
        #expect(try MiraAdjustment.adjustmentData(for: cleared).formatVersion == "1")
    }

    @Test func sidecarsCarryStrokes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mira-db-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = dir.appendingPathComponent("a.jpg")
        try Data([0]).write(to: image)
        let store = SidecarStore(fallbackDirectory: dir.appendingPathComponent("fb"))
        try store.save(Self.painted, for: image)
        let json = try String(contentsOf: SidecarStore.sidecarURL(for: image), encoding: .utf8)
        #expect(json.contains("\"formatVersion\" : \"3\""))
        #expect(store.load(for: image)?.dodgeBurn.strokes.count == 3)
    }

    @Test func presetsDropStrokes() throws {
        let preset = Preset(nickname: "Painted", recipe: Self.painted, filmName: "Portra 400")
        #expect(preset.recipe.dodgeBurn.isIdentity)
        #expect(preset.recipe.exposure == 0.1)
        let data = try PresetFile.encode(Preset(nickname: "P", recipe: Self.painted), appVersion: "0.4.0")
        #expect(!String(decoding: data, as: UTF8.self).contains("dodgeBurn"))
        // A file that smuggles strokes in has them removed on import.
        let doctored = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var body = try #require(doctored["preset"] as? [String: Any])
        var recipe = try #require(body["recipe"] as? [String: Any])
        recipe["dodgeBurn"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.painted.dodgeBurn))
        body["recipe"] = recipe
        var file = doctored; file["preset"] = body
        let back = try PresetFile.decode(JSONSerialization.data(withJSONObject: file))
        #expect(back.recipe.dodgeBurn.isIdentity)
        // Decoding a stored preset (Presets.json) also strips them.
        var stored = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(preset)) as? [String: Any])
        var storedRecipe = try #require(stored["recipe"] as? [String: Any])
        storedRecipe["dodgeBurn"] = recipe["dodgeBurn"]
        stored["recipe"] = storedRecipe
        let decoded = try JSONDecoder().decode(Preset.self, from: JSONSerialization.data(withJSONObject: stored))
        #expect(decoded.recipe.dodgeBurn.isIdentity)
    }

    @Test func applyingKeepsThePhotosStrokes() {
        var preset = Preset(nickname: "Flat", recipe: Recipe(filmID: "x", contrast: 0.3))
        let mine = Self.painted.dodgeBurn
        let r = preset.recipe(keeping: CropSettings(straighten: 4), dodgeBurn: mine)
        #expect(r.dodgeBurn == mine && r.crop.straighten == 4 && r.contrast == 0.3)
        preset.setRecipe(Self.painted)
        #expect(preset.recipe.dodgeBurn.isIdentity)
    }

    @Test func modeAndRangeHelpers() {
        #expect(DodgeBurnMode.dodge.flipped == .burn && DodgeBurnMode.burn.flipped == .dodge)
        #expect(DodgeBurnMode.erase.flipped == .erase)
        #expect(!Self.stroke(strength: 0).isActive)
        #expect(Self.stroke(.erase, strength: 0).isActive)
        var hidden = Self.stroke(); hidden.hidden = true
        #expect(!hidden.isActive)
        #expect(!DodgeBurnSettings(strokes: [hidden]).hasVisibleEffect)
        #expect(DodgeBurnSettings(strokes: [Self.stroke()]).hasVisibleEffect)
    }
}
