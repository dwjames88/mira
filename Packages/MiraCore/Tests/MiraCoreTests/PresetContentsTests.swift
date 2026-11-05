import Foundation
import Testing
@testable import MiraCore

/// What a preset holds. Everything about the look is in (film and variant id, push/pull, scan, paper,
/// toning, exposure time override, reciprocity, grain, halation, bloom, every Develop control). Only the
/// photo's own things are out: crop, dodge and burn strokes, and the per-shot RAW settings
/// (white balance, noise reduction, sharpening, lens correction, moire), the one existing exception.
@Suite("Preset contents") struct PresetContentsTests {
    static func fullLook() -> Recipe {
        var r = PresetFileTests.fullRecipe()
        r.filmID = "kodak-portra-400-plus-1"   // a variant id
        r.push = 1.0 / 3
        r.remJetRemoved = true
        r.scanProfile = .noritsu
        r.paper = .colorPaper
        r.toning = .sepia
        r.toningStrength = 0.6
        r.exposureTime = 2.5
        r.reciprocity = .uncompensated
        r.reciprocityStrength = 1.4
        r.curves.red = [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 1, y: 1)]
        r.colorMixer.orange = ColorAdjust(hue: 0.2, saturation: -0.1, luminance: 0.15)
        r.raw = RawSettings(temperature: 4300, tint: 8, boostAmount: 0.4, localToneMapAmount: 0.3,
                            extendedDynamicRangeAmount: 0.5, shadowBias: 0.1, luminanceNoiseReductionAmount: 0.7,
                            colorNoiseReductionAmount: 0.6, sharpnessAmount: 0.5, detailAmount: 0.4,
                            moireReductionAmount: 0.3, lensCorrection: true)
        r.crop.straighten = 7
        r.dodgeBurn.strokes = [DodgeBurnStroke(mode: .burn, points: [StrokePoint(x: 0.4, y: 0.4)])]
        return r
    }

    /// The look with the photo's things taken out.
    static func expectedStored(_ r: Recipe) -> Recipe {
        var e = r
        e.crop = .identity
        e.dodgeBurn = .identity
        e.raw = r.raw.presetPortion
        return e
    }

    @Test func presetStoresTheWholeLookAndNothingOfThePhoto() {
        let full = Self.fullLook()
        let p = Preset(nickname: "Look", recipe: full, filmName: "Portra 400 +1")
        #expect(p.recipe == Self.expectedStored(full))
        #expect(p.filmID == "kodak-portra-400-plus-1")
        #expect(p.recipe.push == 1.0 / 3)
        #expect(p.recipe.scanProfile == .noritsu)
        #expect(p.recipe.paper == .colorPaper)
        #expect(p.recipe.toning == .sepia)
        #expect(p.recipe.toningStrength == 0.6)
        #expect(p.recipe.exposureTime == 2.5)          // per-look, unlike the crop
        #expect(p.recipe.reciprocity == .uncompensated)
        #expect(p.recipe.reciprocityStrength == 1.4)
        #expect(p.recipe.grainAmount == full.grainAmount && p.recipe.halationAmount == full.halationAmount
                && p.recipe.bloomAmount == full.bloomAmount)
        #expect(p.recipe.crop == .identity)
        #expect(p.recipe.dodgeBurn == .identity)
        // RAW: the look portion only.
        #expect(p.recipe.raw.boostAmount == 0.4 && p.recipe.raw.localToneMapAmount == 0.3
                && p.recipe.raw.extendedDynamicRangeAmount == 0.5)
        #expect(p.recipe.raw.temperature == nil && p.recipe.raw.tint == nil
                && p.recipe.raw.luminanceNoiseReductionAmount == nil && p.recipe.raw.lensCorrection == nil)
    }

    @Test func presetFileKeepsTheSameContents() throws {
        let p = Preset(nickname: "Look", recipe: Self.fullLook(), filmName: "Portra 400 +1")
        let back = try PresetFile.decode(PresetFile.encode(p, appVersion: "1.0.0"))
        #expect(back.recipe == p.recipe)
        #expect(back.recipe.exposureTime == 2.5)
        #expect(back.filmID == "kodak-portra-400-plus-1")
    }

    @Test func applyingKeepsThePhotosCropStrokesAndShotSettings() {
        let p = Preset(nickname: "Look", recipe: Self.fullLook(), filmName: "Portra 400 +1")
        var photo = Recipe(filmID: "fuji-velvia-50", exposure: -1)
        photo.crop.straighten = -9
        photo.dodgeBurn.strokes = [DodgeBurnStroke(mode: .dodge, points: [StrokePoint(x: 0.1, y: 0.2)])]
        photo.raw = RawSettings(temperature: 5200, lensCorrection: false)

        let applied = p.recipe(keeping: photo.crop, dodgeBurn: photo.dodgeBurn, raw: photo.raw)
        #expect(applied.crop == photo.crop)
        #expect(applied.dodgeBurn == photo.dodgeBurn)
        #expect(applied.raw.temperature == 5200 && applied.raw.lensCorrection == false)
        #expect(applied.raw.boostAmount == 0.4)
        #expect(applied.filmID == "kodak-portra-400-plus-1")
        #expect(applied.exposureTime == 2.5)
        #expect(applied.reciprocity == .uncompensated)
        #expect(applied.toning == .sepia)
    }
}
