import MiraCore
import Testing
@testable import MiraUI

@Suite("White balance control")
struct WhiteBalanceControlTests {
    private let raw = WhiteBalanceControl(isRaw: true, asShot: (5200, 8))
    private let plain = WhiteBalanceControl(isRaw: false, asShot: nil)

    @Test func rawRestsOnTheAsShotValues() {
        let r = Recipe()
        #expect(raw.temperature(of: r) == 5200 && raw.tint(of: r) == 8)
        #expect(raw.kelvinDefault == 5200 && raw.tintDefault == 8)
        #expect(raw.isAsShot(r))
    }

    @Test func rawWritesTheDecoderSettingsAndLeavesWarmthAlone() {
        var r = Recipe()
        raw.setTemperature(6100, in: &r)
        raw.setTint(-12, in: &r)
        #expect(r.raw.temperature == 6100 && r.raw.tint == -12)
        #expect(r.warmth == 0 && r.tint == 0)
        #expect(!raw.isAsShot(r))
        raw.setTemperature(5210, in: &r)   // within snap of as shot
        raw.setTint(8, in: &r)
        #expect(r.raw.temperature == nil && r.raw.tint == nil)
        #expect(raw.isAsShot(r))
    }

    @Test func plainMapsKelvinAndTintToWarmthAndTint() {
        var r = Recipe()
        #expect(plain.temperature(of: r) == 6500 && plain.tint(of: r) == 0)
        plain.setTemperature(7250, in: &r)
        plain.setTint(20, in: &r)
        #expect(r.warmth == 0.5 && r.tint == 0.5)
        #expect(r.raw.temperature == nil && r.raw.tint == nil)
        #expect(plain.temperature(of: r) == 7250 && plain.tint(of: r) == 20)
        plain.setTemperature(6500, in: &r)
        plain.setTint(0, in: &r)
        #expect(r.warmth == 0 && r.tint == 0 && plain.isAsShot(r))
        #expect(plain.kelvinRange == 5000...8000 && plain.tintRange == -40...40)
    }

    @Test func resetToAsShotClearsAllFour() {
        var r = Recipe()
        r.raw.temperature = 4000; r.raw.tint = 30; r.warmth = 0.4; r.tint = -0.4
        #expect(!raw.isAsShot(r) && !plain.isAsShot(r))
        WhiteBalanceControl.resetToAsShot(&r)
        #expect(r.raw.temperature == nil && r.raw.tint == nil && r.warmth == 0 && r.tint == 0)
        #expect(raw.isAsShot(r) && plain.isAsShot(r))
    }
}
