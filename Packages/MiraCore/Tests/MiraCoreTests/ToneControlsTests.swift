import CoreImage
import Foundation
import Photos
import Testing
@testable import MiraCore

@Suite struct ToneControlsPersistenceTests {
    static let toned = Recipe(filmID: "kodak-portra-400", exposure: 0.2, highlights: -0.4, shadows: 0.5,
                              whites: 0.1, blacks: -0.2, vibrance: 0.3, clarity: 0.25, texture: -0.15)

    @Test func roundTripKeepsNewFields() throws {
        let back = try Recipe.decode(Self.toned.encoded())
        #expect(back == Self.toned)
        #expect(back.highlights == -0.4 && back.shadows == 0.5 && back.whites == 0.1 && back.blacks == -0.2)
        #expect(back.vibrance == 0.3 && back.clarity == 0.25 && back.texture == -0.15)
    }

    @Test func oldJSONDecodesWithZeroes() throws {
        let v1 = Data(#"{"filmID":"x","strength":0.5,"exposure":0.3,"contrast":0.1,"saturation":0,"warmth":0,"tint":0}"#.utf8)
        let r = try Recipe.decode(v1)
        #expect(r.exposure == 0.3)
        #expect(!r.usesToneControls)
        #expect(r.highlights == 0 && r.shadows == 0 && r.whites == 0 && r.blacks == 0)
        #expect(r.vibrance == 0 && r.clarity == 0 && r.texture == 0)
    }

    @Test func neutralBytesUnchanged() throws {
        let text = String(decoding: try Recipe.neutral.encoded(), as: UTF8.self)
        for key in ["highlights", "shadows", "whites", "blacks", "vibrance", "clarity", "texture"] {
            #expect(!text.contains(key), "\(key) must not be written when 0")
        }
        // Exactly the keys older builds wrote.
        let expected = #"{"borderEnabled":false,"borderWidth":0.04,"bloomAmount":0,"contrast":0,"crop":"#
        _ = expected
        let obj = try #require(JSONSerialization.jsonObject(with: Recipe.neutral.encoded()) as? [String: Any])
        #expect(Set(obj.keys) == ["strength", "exposure", "contrast", "saturation", "warmth", "tint", "grainAmount",
                                  "grainSize", "halationAmount", "halationRadius", "bloomAmount", "vignetteAmount",
                                  "borderEnabled", "borderWidth", "version", "crop"])
    }

    @Test func nonZeroValuesAreWrittenOnlyWhenSet() throws {
        let text = String(decoding: try Recipe(blacks: 0.5).encoded(), as: UTF8.self)
        #expect(text.contains("\"blacks\""))
        #expect(!text.contains("\"whites\""))
    }

    @Test func formatVersionSelection() throws {
        #expect(try MiraAdjustment.adjustmentData(for: .neutral).formatVersion == "1")
        #expect(try MiraAdjustment.adjustmentData(for: Recipe(exposure: 0.3)).formatVersion == "1")
        for r in [Recipe(highlights: 0.1), Recipe(shadows: 0.1), Recipe(whites: 0.1), Recipe(blacks: 0.1),
                  Recipe(vibrance: 0.1), Recipe(clarity: 0.1), Recipe(texture: 0.1)] {
            #expect(try MiraAdjustment.adjustmentData(for: r).formatVersion == "2")
        }
    }

    @Test func versionTwoAndLegacyAreReadable() throws {
        #expect(MiraAdjustment.supportedVersions == ["1", "2"])
        let adj = try MiraAdjustment.adjustmentData(for: Self.toned)
        #expect(MiraAdjustment.canHandle(adj))
        #expect(MiraAdjustment.recipe(from: adj) == Self.toned)
        let legacyV1 = PHAdjustmentData(formatIdentifier: "com.dwjames.emulsion", formatVersion: "1", data: try Recipe(exposure: 0.4).encoded())
        #expect(MiraAdjustment.recipe(from: legacyV1) == Recipe(exposure: 0.4))
    }

    @Test func sidecarWritesVersionTwoWhenNeeded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mira-tone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = dir.appendingPathComponent("a.jpg")
        try Data([0]).write(to: image)
        let store = SidecarStore(fallbackDirectory: dir.appendingPathComponent("fb"))
        try store.save(Self.toned, for: image)
        #expect(store.load(for: image) == Self.toned)
        let text = try String(contentsOf: SidecarStore.sidecarURL(for: image), encoding: .utf8)
        #expect(text.contains("\"formatVersion\" : \"2\""))
    }
}

@Suite struct ToneControlsRenderTests {
    let context = Renderer.sharedContext
    let size = 256

    func render(_ r: Recipe) throws -> Pixels {
        let renderer = Renderer(library: try emptyLibrary())
        return Pixels(renderer.apply(r, to: Fixture.gradientAndPatches(size: size)), context: context)
    }

    /// Luma of the ramp (top half of the fixture) at column fraction `f`.
    func ramp(_ p: Pixels, _ f: Double) -> Double {
        let x = Int(f * Double(size - 1)), y = size / 4
        return p.luma[y * p.width + x]
    }

    @Test func zeroIsIdentity() throws {
        let a = try render(.neutral), b = try render(Recipe(highlights: 0, shadows: 0, whites: 0, blacks: 0))
        #expect(a.rgba == b.rgba)
        // The kernel itself, at zero, changes nothing either.
        let src = Fixture.gradientAndPatches(size: size)
        let out = GradeKernels.applyTone(highlights: 0, shadows: 0, whites: 0, blacks: 0, to: src, base: src)
        let p = Pixels(src, context: context), q = Pixels(out, context: context)
        let worst = zip(p.rgba, q.rgba).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 1)
    }

    @Test func blacksMinusCrushesDarkest() throws {
        let base = try render(.neutral), crushed = try render(Recipe(blacks: -1)), lifted = try render(Recipe(blacks: 1))
        #expect(ramp(crushed, 0.1) < ramp(base, 0.1) - 0.05)
        #expect(ramp(crushed, 0.02) < 0.01)
        #expect(ramp(lifted, 0.02) > ramp(base, 0.02) + 0.05)
        #expect(abs(ramp(crushed, 0.95) - ramp(base, 0.95)) < 0.03)
    }

    @Test func whitesPlusBrightensNearWhite() throws {
        let base = try render(.neutral), up = try render(Recipe(whites: 1)), down = try render(Recipe(whites: -1))
        #expect(ramp(up, 0.85) > ramp(base, 0.85) + 0.05)
        #expect(ramp(down, 0.95) < ramp(base, 0.95) - 0.1)
        #expect(abs(ramp(up, 0.05) - ramp(base, 0.05)) < 0.02)
    }

    @Test func highlightsMinusLowersBrightLeavesShadows() throws {
        let base = try render(.neutral), r = try render(Recipe(highlights: -1)), up = try render(Recipe(highlights: 1))
        #expect(ramp(r, 0.85) < ramp(base, 0.85) - 0.1)
        #expect(abs(ramp(r, 0.08) - ramp(base, 0.08)) < 0.02)
        #expect(ramp(up, 0.75) > ramp(base, 0.75) + 0.02)
    }

    @Test func shadowsPlusLiftsDarkLeavesHighlights() throws {
        let base = try render(.neutral), r = try render(Recipe(shadows: 1)), down = try render(Recipe(shadows: -1))
        #expect(ramp(r, 0.15) > ramp(base, 0.15) + 0.08)
        #expect(abs(ramp(r, 0.92) - ramp(base, 0.92)) < 0.02)
        #expect(ramp(down, 0.2) < ramp(base, 0.2) - 0.03)
    }

    @Test func eachControlIsMonotonicAcrossTheRamp() throws {
        for r in [Recipe(highlights: -1), Recipe(highlights: 1), Recipe(shadows: 1), Recipe(shadows: -1),
                  Recipe(whites: 1), Recipe(whites: -1), Recipe(blacks: 1), Recipe(blacks: -1)] {
            let p = try render(r)
            var prev = -1.0
            for i in 0..<size {
                let v = p.luma[(size / 4) * p.width + i]
                #expect(v >= prev - 0.012, "\(r) not monotonic at column \(i)")
                prev = v
            }
        }
    }

    @Test func vibranceClarityTextureRunAndChangePixels() throws {
        let base = try render(.neutral)
        for r in [Recipe(vibrance: 0.8), Recipe(clarity: 0.8), Recipe(texture: 0.8), Recipe(vibrance: -0.8)] {
            #expect(try render(r).rgba != base.rgba)
        }
    }

    @Test func previewAndFullSizeAgree() throws {
        let renderer = Renderer(library: try emptyLibrary())
        let r = Recipe(highlights: -0.8, shadows: 0.8, clarity: 0.5, texture: 0.5)
        let big = Fixture.gradientAndPatches(size: 512)
        let small = Fixture.gradientAndPatches(size: 256)
        let a = Pixels(renderer.apply(r, to: big), context: context)
        let b = Pixels(renderer.apply(r, to: small), context: context)
        #expect(abs(mean(a.luma) - mean(b.luma)) < 0.02)
    }
}
