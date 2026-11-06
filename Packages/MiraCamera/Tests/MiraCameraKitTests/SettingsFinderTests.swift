import Foundation
import Testing
import MiraCore
@testable import MiraCameraKit

@Suite struct CameraSettingsTests {
    private func suite() -> (UserDefaults, String) {
        let name = "mira.camera.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func defaults() {
        let s = CameraSettings()
        #expect(!s.silentShutter && !s.addLocation && s.finderGrainLive)
        #expect(s.finderQuality == .auto && s.lastFilmID == nil && s.lastRecipe == nil)
        #expect(s.whiteBalanceKelvin == nil)
    }

    @Test func roundTripThroughUserDefaults() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CameraSettingsStore(defaults: defaults)
        #expect(store.load() == CameraSettings())
        let recipe = Recipe(filmID: "kodak-portra-400", exposure: 0.5)
        let s = CameraSettings(silentShutter: true, addLocation: true, finderGrainLive: false, finderQuality: .reduced,
                               lastFilmID: "kodak-portra-400", lastRecipe: recipe, whiteBalanceKelvin: 4300)
        store.save(s)
        #expect(CameraSettingsStore(defaults: defaults).load() == s)
    }

    @Test func missingKeysDecodeToDefaultsAndGarbageIsIgnored() throws {
        let partial = try JSONDecoder().decode(CameraSettings.self, from: Data(#"{"silentShutter":true}"#.utf8))
        #expect(partial.silentShutter && partial.finderGrainLive && partial.finderQuality == .auto)
        #expect(partial.whiteBalanceKelvin == nil)
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("nope".utf8), forKey: CameraSettingsStore.defaultKey)
        #expect(CameraSettingsStore(defaults: defaults).load() == CameraSettings())
    }
}

@Suite struct FallbackLadderTests {
    /// Feeds `ms` frames at 30 Hz from `start` for `seconds`; returns the end time.
    @discardableResult
    private func feed(_ l: inout FallbackLadder, ms: Double, from start: Double, seconds: Double) -> Double {
        var t = start
        while t < start + seconds {
            l.record(frameMilliseconds: ms, at: t)
            t += 1.0 / 30
        }
        return t
    }

    @Test func startsFull() {
        let l = FallbackLadder()
        #expect(l.level == .full && l.quality == .full)
    }

    @Test func stepsDownAfterAboveOneSecondOfSlowFrames() {
        var l = FallbackLadder()
        feed(&l, ms: 35, from: 0, seconds: 0.9)
        #expect(l.level == .full)
        feed(&l, ms: 35, from: 0.9, seconds: 0.5)
        #expect(l.level == .grainOff)
        #expect(l.quality.textureScale == 1 && !l.quality.grainLive && l.quality.renderScale == 1)
    }

    @Test func walksAllTheWayDown() {
        var l = FallbackLadder()
        var t = 0.0
        var seen: [FinderLevel] = [l.level]
        while t < 20 {
            t = feed(&l, ms: 40, from: t, seconds: 0.1)
            if seen.last != l.level { seen.append(l.level) }
        }
        #expect(seen == [.full, .grainOff, .reduced, .lowFrameRate])
        #expect(!seen.contains(.halfTexture))
        let q = l.quality
        #expect(q.renderScale == 0.75 && q.textureScale == 1 && !q.grainLive && q.frameRate == 24)
    }

    @Test func aSingleSpikeDoesNothing() {
        var l = FallbackLadder()
        var t = feed(&l, ms: 15, from: 0, seconds: 2)
        l.record(frameMilliseconds: 200, at: t)
        t = feed(&l, ms: 15, from: t, seconds: 3)
        #expect(l.level == .full)
    }

    @Test func hysteresisBeforeStepUp() {
        var l = FallbackLadder()
        var t = feed(&l, ms: 40, from: 0, seconds: 1.5)
        #expect(l.level == .grainOff)
        // 25 ms is between the thresholds: stays put however long it lasts.
        t = feed(&l, ms: 25, from: t, seconds: 10)
        #expect(l.level == .grainOff)
        // Fast frames: not before 5 s, then one level.
        t = feed(&l, ms: 12, from: t, seconds: 4.5)
        #expect(l.level == .grainOff)
        t = feed(&l, ms: 12, from: t, seconds: 1)
        #expect(l.level == .full)
    }

    @Test func thermalFloors() {
        var l = FallbackLadder()
        l.thermal = .fair
        #expect(l.level == .full)
        l.thermal = .serious
        #expect(l.level == .grainOff && !l.quality.grainLive)
        l.thermal = .critical
        #expect(l.level == .lowFrameRate && l.quality.frameRate == 24)
        l.thermal = .nominal
        #expect(l.level == .full)
        // The measured level wins when it is worse than the floor.
        l.thermal = .serious
        var t = 0.0
        while t < 20 { t = feed(&l, ms: 40, from: t, seconds: 0.1) }
        #expect(l.level == .lowFrameRate)
    }

    @Test func overridePinsALevel() {
        for (mode, level) in [(FinderQualityMode.full, FinderLevel.full), (.halfTexture, .halfTexture), (.grainOff, .grainOff), (.reduced, .reduced)] {
            var l = FallbackLadder(mode: mode)
            feed(&l, ms: 60, from: 0, seconds: 5)
            #expect(l.level == level)
        }
        var l = FallbackLadder(mode: .full, thermal: .critical)
        #expect(l.level == .full)
        l.mode = .auto
        #expect(l.level == .lowFrameRate)
    }

    @Test func autoNeverUsesHalfTexture() {
        #expect(!FinderLevel.automatic.contains(.halfTexture))
        for level in [FinderLevel.grainOff, .reduced, .lowFrameRate] { #expect(level.quality().textureScale == 1) }
        #expect(FinderLevel.halfTexture.quality().textureScale == 0.5 && FinderLevel.halfTexture.quality().grainLive)
    }

    @Test func grainSettingOffAppliesToEveryLevel() {
        var l = FallbackLadder(mode: .full, grainLiveSetting: false)
        #expect(!l.quality.grainLive)
        l.mode = .halfTexture
        #expect(!l.quality.grainLive && l.quality.textureScale == 0.5)
        #expect(FallbackLadder(mode: .halfTexture, grainLiveSetting: true).quality.grainLive)
    }
}

@Suite struct FinderRecipeTests {
    let user = Recipe(filmID: "kodak-portra-400", exposure: 0.3).applyingNativeTexture(filmID: "kodak-portra-400")

    @Test func grainOffWhenNotLive() {
        #expect(user.grainAmount > 0)
        let live = FinderRecipe.recipe(from: user, quality: .full)
        #expect(live == user)
        let off = FinderRecipe.recipe(from: user, quality: FinderQuality(grainLive: false))
        #expect(off.grainAmount == 0)
        var expected = user
        expected.grainAmount = 0
        #expect(off == expected)
        // The user's recipe is untouched.
        #expect(user.grainAmount > 0)
    }

    @Test func previewScale() {
        #expect(FinderRecipe.previewScale(finderLongSide: 1809, captureLongSide: 4032) == 1809.0 / 4032)
        #expect(FinderRecipe.previewScale(finderLongSide: 5000, captureLongSide: 4032) == 1)
        #expect(FinderRecipe.previewScale(finderLongSide: 0, captureLongSide: 4032) == 1)
        #expect(FinderRecipe.previewScale(finderLongSide: 1000, captureLongSide: 0) == 1)
    }

    @Test func grainSeedFitsIn24BitsAndVaries() {
        var seen = Set<Double>()
        for i in 0..<2000 {
            let s = FinderRecipe.grainSeed(frameIndex: i)
            #expect(s >= 1 && s < 16_777_216 && s == s.rounded())
            #expect(Double(Float(s)) == s)
            seen.insert(s)
        }
        #expect(seen.count > 1990)
        #expect(FinderRecipe.grainSeed(frameIndex: 7) == FinderRecipe.grainSeed(frameIndex: 7))
        #expect(FinderRecipe.grainSeed(frameIndex: 1) != FinderRecipe.grainSeed(frameIndex: 2))
        _ = FinderRecipe.grainSeed(frameIndex: Int.max)
        _ = FinderRecipe.grainSeed(frameIndex: -5)
    }
}
