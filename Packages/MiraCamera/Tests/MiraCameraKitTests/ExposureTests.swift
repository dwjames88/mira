import Testing
import MiraCore
@testable import MiraCameraKit

@Suite struct ExposureModelTests {
    @Test func snapsToThirdsAndClamps() {
        #expect(ExposureModel.snapToThird(0.1) == 0)
        #expect(abs(ExposureModel.snapToThird(0.2) - 1.0 / 3) < 1e-12)
        #expect(abs(ExposureModel.snapToThird(-0.9) - -1.0) < 1e-12)
        #expect(ExposureModel.snapToThird(7) == 3)
        #expect(ExposureModel.snapToThird(-7) == -3)
        #expect(ExposureModel.snapToThird(.nan) == 0)
    }

    @Test func clampsToDeviceRange() {
        #expect(ExposureModel.clamp(5, min: -8, max: 8) == 3)
        #expect(ExposureModel.clamp(-5, min: -2, max: 2) == -2)
        #expect(ExposureModel.clamp(1, min: -2, max: 2) == 1)
        #expect(ExposureModel.clamp(.infinity, min: -2, max: 2) == 0)
    }

    @Test func labels() {
        #expect(ExposureModel.label(0) == "0")
        #expect(ExposureModel.label(1.0 / 3) == "+⅓")
        #expect(ExposureModel.label(-2.0 / 3) == "\u{2212}⅔")
        #expect(ExposureModel.label(1 + 1.0 / 3) == "+1⅓")
        #expect(ExposureModel.label(-1) == "\u{2212}1")
        #expect(ExposureModel.label(2 + 2.0 / 3) == "+2⅔")
        #expect(ExposureModel.label(3) == "+3")
        #expect(ExposureModel.label(-3) == "\u{2212}3")
        #expect(ExposureModel.label(10) == "+3")
    }

    @Test func needleMapping() {
        #expect(ExposureModel.needle(offsetEV: 0) == 0)
        #expect(ExposureModel.needle(offsetEV: 1.5) == 0.5)
        #expect(ExposureModel.needle(offsetEV: -3) == -1)
        #expect(ExposureModel.needle(offsetEV: -9) == -1)
        #expect(ExposureModel.needle(offsetEV: 9) == 1)
        #expect(ExposureModel.needle(offsetEV: .nan) == 0)
    }

    @Test func detentsCrossed() {
        #expect(ExposureModel.detentsCrossed(from: 0, to: 0) == 0)
        #expect(ExposureModel.detentsCrossed(from: 0, to: 1) == 3)
        #expect(ExposureModel.detentsCrossed(from: 1, to: -1) == 6)
        #expect(ExposureModel.detentsCrossed(from: -3, to: 3) == 18)
        #expect(ExposureModel.detentsCrossed(from: 0.05, to: 0.1) == 0)
        #expect(ExposureModel.detentsCrossed(from: 0.1, to: 0.4) == 1)
    }
}

@Suite struct ExposureReadoutTests {
    @Test func fullLine() {
        #expect(ExposureReadout.text(duration: 1.0 / 125, iso: 64, aperture: 1.8) == "1/125 \u{00B7} ISO 64 \u{00B7} \u{0192}1.8")
        #expect(ExposureReadout.text(duration: 1.0 / 60, iso: 63.6, aperture: 2.2) == "1/60 \u{00B7} ISO 64 \u{00B7} \u{0192}2.2")
    }

    @Test func missingApertureIsOmitted() {
        #expect(ExposureReadout.text(duration: 1.0 / 250, iso: 100, aperture: nil) == "1/250 \u{00B7} ISO 100")
    }

    @Test func shutterRoundsToStandardValues() {
        #expect(ExposureReadout.shutterText(1.0 / 118) == "1/125")
        #expect(ExposureReadout.shutterText(1.0 / 8000) == "1/8000")
        #expect(ExposureReadout.shutterText(1.0 / 20000) == "1/8000")
        #expect(ExposureReadout.shutterText(1.0 / 3) == "1/3")
        #expect(ExposureReadout.shutterText(0.39) == "1/3")
        #expect(ExposureReadout.shutterText(1.0 / 14) == "1/15")
        #expect(ExposureReadout.shutterText(1.0 / 29) == "1/30")
    }

    @Test func longExposures() {
        #expect(ExposureReadout.shutterText(0.5) == "0.5 s")
        #expect(ExposureReadout.shutterText(0.4) == "0.4 s")
        #expect(ExposureReadout.shutterText(1) == "1 s")
        #expect(ExposureReadout.shutterText(2) == "2 s")
        #expect(ExposureReadout.shutterText(1.52) == "1.5 s")
    }
}

@Suite struct LatitudeReadoutTests {
    @Test func text() {
        let r = LatitudeReadout(reading: LatitudeReading(under: 0.04, over: 0.01, underStops: 1, overStops: 0.5))
        #expect(r.text == "UNDER 4% \u{00B7} OVER 1%")
        #expect(LatitudeReadout(reading: LatitudeReading(under: 0.004, over: 0.996, underStops: 0, overStops: 0)).text == "UNDER 0% \u{00B7} OVER 100%")
        #expect(LatitudeReadout(reading: nil).text == "UNDER \u{2014} \u{00B7} OVER \u{2014}")
    }

    @Test func hotThresholdsAreAboveTwoPercent() {
        func r(_ u: Double, _ o: Double) -> LatitudeReadout {
            LatitudeReadout(reading: LatitudeReading(under: u, over: o, underStops: 0, overStops: 0))
        }
        #expect(!r(0.02, 0.02).overIsHot && !r(0.02, 0.02).underIsHot)
        #expect(r(0.0201, 0.0201).overIsHot && r(0.0201, 0.0201).underIsHot)
        #expect(r(0, 0.5).overIsHot && !r(0, 0.5).underIsHot)
        #expect(!LatitudeReadout(reading: nil).overIsHot && !LatitudeReadout(reading: nil).underIsHot)
    }
}
