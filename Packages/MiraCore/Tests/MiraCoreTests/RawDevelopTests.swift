import CoreGraphics
import Foundation
import Testing
@testable import MiraCore

/// A stand-in for `CIRAWFilter` whose supported flags can be switched.
final class MockRawFilter: RawFilterControls {
    var isDraftModeEnabled = false
    var scaleFactor: Float = 1
    var neutralChromaticity = CGPoint(x: 0.31, y: 0.33)
    var neutralTemperature: Float = 5200
    var neutralTint: Float = 8
    var boostAmount: Float = 1
    var shadowBias: Float = 0.1
    var localToneMapAmount: Float = 0.3
    var extendedDynamicRangeAmount: Float = 0
    var luminanceNoiseReductionAmount: Float = 0.4
    var colorNoiseReductionAmount: Float = 0.5
    var sharpnessAmount: Float = 0.6
    var detailAmount: Float = 0.7
    var moireReductionAmount: Float = 0.2
    var isLensCorrectionEnabled = true
    var supportsAll = true
    var isLocalToneMapSupported: Bool { supportsAll }
    var isLuminanceNoiseReductionSupported: Bool { supportsAll }
    var isColorNoiseReductionSupported: Bool { supportsAll }
    var isSharpnessSupported: Bool { supportsAll }
    var isDetailSupported: Bool { supportsAll }
    var isMoireReductionSupported: Bool { supportsAll }
    var isLensCorrectionSupported: Bool { supportsAll }
}

@Suite struct RawDevelopTests {
    @Test func presetPortionDropsWhiteBalanceAndNoise() {
        let s = RawSettings(temperature: 4000, tint: 10, boostAmount: 0.5, localToneMapAmount: 0.2,
                            extendedDynamicRangeAmount: 1.5, shadowBias: 0.2, luminanceNoiseReductionAmount: 0.9,
                            colorNoiseReductionAmount: 0.8, sharpnessAmount: 0.5, detailAmount: 1,
                            moireReductionAmount: 0.5, lensCorrection: false)
        let p = s.presetPortion
        #expect(p == RawSettings(boostAmount: 0.5, localToneMapAmount: 0.2, extendedDynamicRangeAmount: 1.5))
        #expect(p.temperature == nil && p.tint == nil && p.luminanceNoiseReductionAmount == nil)
    }

    @Test func recipeRoundTripKeepsRawSettings() throws {
        var r = Recipe.neutral
        r.raw = RawSettings(temperature: 5600, tint: -5, boostAmount: 0.25, lensCorrection: true)
        let back = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(r))
        #expect(back == r)
        #expect(back.raw.temperature == 5600)
    }

    @Test func automaticBoostIsZeroWithFilm() {
        let initial = RawInitialValues(of: MockRawFilter())
        #expect(RawSettingsMapper.resolvedBoost(.identity, filmApplied: true, initial: initial) == 0)
        #expect(RawSettingsMapper.resolvedBoost(.identity, filmApplied: false, initial: initial) == 1)
        #expect(RawSettingsMapper.resolvedBoost(RawSettings(boostAmount: 0.6), filmApplied: true, initial: initial) == 0.6)
        #expect(RawSettingsMapper.resolvedExtendedDynamicRange(.identity, filmApplied: true, initial: initial) == 2)
        #expect(RawSettingsMapper.resolvedExtendedDynamicRange(.identity, filmApplied: false, initial: initial) == 0)
        #expect(RawSettingsMapper.resolvedExtendedDynamicRange(RawSettings(extendedDynamicRangeAmount: 1), filmApplied: true, initial: initial) == 1)
    }

    @Test func draftAndScaleFollowTheCaller() {
        let f = MockRawFilter()
        let initial = RawInitialValues(of: f)
        RawSettingsMapper.apply(.identity, filmApplied: false, draft: true, scale: 0.5, initial: initial, to: f)
        #expect(f.isDraftModeEnabled && f.scaleFactor == 0.5)
        RawSettingsMapper.apply(.identity, filmApplied: false, draft: false, scale: 1, initial: initial, to: f)
        #expect(!f.isDraftModeEnabled && f.scaleFactor == 1)
    }

    @Test func nilRestoresDecoderValuesAndSettingsOverride() {
        let f = MockRawFilter()
        let initial = RawInitialValues(of: f)
        let s = RawSettings(temperature: 3200, tint: -20, localToneMapAmount: 0.9, shadowBias: 0.5,
                            luminanceNoiseReductionAmount: 1, sharpnessAmount: 0, detailAmount: 5, lensCorrection: false)
        RawSettingsMapper.apply(s, filmApplied: false, draft: false, scale: 1, initial: initial, to: f)
        #expect(f.neutralTemperature == 3200 && f.neutralTint == -20)
        #expect(f.localToneMapAmount == 0.9 && f.shadowBias == 0.5 && f.luminanceNoiseReductionAmount == 1)
        #expect(f.sharpnessAmount == 0 && f.detailAmount == 3)   // clamped to 0...3
        #expect(!f.isLensCorrectionEnabled)
        RawSettingsMapper.apply(.identity, filmApplied: false, draft: false, scale: 1, initial: initial, to: f)
        #expect(f.neutralChromaticity == initial.chromaticity)
        #expect(f.localToneMapAmount == 0.3 && f.shadowBias == 0.1 && f.sharpnessAmount == 0.6 && f.detailAmount == 0.7)
        #expect(f.isLensCorrectionEnabled)
    }

    @Test func unsupportedControlsAreNotTouched() {
        let f = MockRawFilter()
        f.supportsAll = false
        let initial = RawInitialValues(of: f)
        let s = RawSettings(localToneMapAmount: 1, luminanceNoiseReductionAmount: 1, sharpnessAmount: 1,
                            detailAmount: 1, moireReductionAmount: 1, lensCorrection: false)
        RawSettingsMapper.apply(s, filmApplied: false, draft: false, scale: 1, initial: initial, to: f)
        #expect(f.localToneMapAmount == 0.3 && f.luminanceNoiseReductionAmount == 0.4 && f.sharpnessAmount == 0.6)
        #expect(f.detailAmount == 0.7 && f.moireReductionAmount == 0.2 && f.isLensCorrectionEnabled)
    }

    @Test func presetsStoreOnlyThePortionAndKeepThePhotosWhiteBalance() {
        var recipe = Recipe.neutral
        recipe.raw = RawSettings(temperature: 4000, tint: 3, boostAmount: 0.4, luminanceNoiseReductionAmount: 0.7, sharpnessAmount: 0.5)
        let preset = Preset(nickname: "x", recipe: recipe)
        #expect(preset.recipe.raw == RawSettings(boostAmount: 0.4))
        let photoRaw = RawSettings(temperature: 6500, tint: -9, boostAmount: 1, luminanceNoiseReductionAmount: 0.2, sharpnessAmount: 0.1)
        let applied = preset.recipe(keeping: .identity, raw: photoRaw)
        #expect(applied.raw.temperature == 6500 && applied.raw.tint == -9)
        #expect(applied.raw.luminanceNoiseReductionAmount == 0.2 && applied.raw.sharpnessAmount == 0.1)
        #expect(applied.raw.boostAmount == 0.4)
    }

    @Test func nonRawFilesFallBackToTheNormalLoad() throws {
        let url = ImageSourceLoadingTests.sample
        var recipe = Recipe.neutral
        recipe.filmID = "x"
        let a = try #require(ImageSource.developedSource(url: url, recipe: recipe, draft: true))
        let b = try #require(ImageSource.load(url: url))
        #expect(a.extent == b.extent)
    }
}
