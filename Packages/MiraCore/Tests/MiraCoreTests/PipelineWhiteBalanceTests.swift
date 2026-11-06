import Testing
@testable import MiraCore

@Suite("Pipeline white balance")
struct PipelineWhiteBalanceTests {
    @Test func neutralIsSixtyFiveHundredKelvin() {
        #expect(PipelineWhiteBalance.neutralKelvin == 6500)
        #expect(PipelineWhiteBalance.kelvin(warmth: 0) == 6500)
        #expect(PipelineWhiteBalance.warmth(kelvin: 6500) == 0)
        #expect(PipelineWhiteBalance.displayTint(0) == 0)
        #expect(PipelineWhiteBalance.tint(display: 0) == 0)
    }

    @Test func kelvinRoundTripsWithWarmth() {
        for w in stride(from: -1.0, through: 1.0, by: 0.125) {
            #expect(abs(PipelineWhiteBalance.warmth(kelvin: PipelineWhiteBalance.kelvin(warmth: w)) - w) < 1e-12)
        }
        #expect(PipelineWhiteBalance.kelvin(warmth: 0.5) == 7250)
        #expect(PipelineWhiteBalance.warmth(kelvin: 7250) == 0.5)
        #expect(PipelineWhiteBalance.kelvinRange == 5000...8000)
    }

    @Test func tintRoundTripsAndScales() {
        for t in stride(from: -1.0, through: 1.0, by: 0.125) {
            #expect(abs(PipelineWhiteBalance.tint(display: PipelineWhiteBalance.displayTint(t)) - t) < 1e-12)
        }
        #expect(PipelineWhiteBalance.displayTint(0.5) == 20)
        #expect(PipelineWhiteBalance.tint(display: 20) == 0.5)
        #expect(PipelineWhiteBalance.tintRange == -40...40)
    }

    @Test func valuesClampToTheRange() {
        #expect(PipelineWhiteBalance.kelvin(warmth: 3) == 8000)
        #expect(PipelineWhiteBalance.kelvin(warmth: -3) == 5000)
        #expect(PipelineWhiteBalance.warmth(kelvin: 12000) == 1)
        #expect(PipelineWhiteBalance.warmth(kelvin: 2000) == -1)
        #expect(PipelineWhiteBalance.displayTint(9) == 40)
        #expect(PipelineWhiteBalance.tint(display: -500) == -1)
    }

    @Test func nonFiniteValuesAreZero() {
        #expect(PipelineWhiteBalance.kelvin(warmth: .nan) == 6500)
        #expect(PipelineWhiteBalance.warmth(kelvin: .nan) == 0)
        #expect(PipelineWhiteBalance.warmth(kelvin: .infinity) == 0)
        #expect(PipelineWhiteBalance.displayTint(.nan) == 0)
        #expect(PipelineWhiteBalance.tint(display: .infinity) == 0)
    }

    @Test func targetNeutralMatchesTheOriginalFormula() {
        for w in stride(from: -1.5, through: 1.5, by: 0.25) {
            for t in stride(from: -1.5, through: 1.5, by: 0.25) {
                let n = PipelineWhiteBalance.targetNeutral(warmth: w, tint: t)
                #expect(n.temperature == 6500 - 1500 * min(max(w, -1), 1))
                #expect(n.tint == -40 * min(max(t, -1), 1))
            }
        }
        let nan = PipelineWhiteBalance.targetNeutral(warmth: .nan, tint: .nan)
        #expect(nan.temperature == 6500 && nan.tint == 0)
    }
}
