import CoreImage
import Foundation
import MiraCore
import Testing
@testable import MiraUI

@MainActor
@Suite("Exposure time control", .serialized)
struct ReciprocityControlTests {
    static func library() throws -> FilmLibrary {
        try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
    }

    /// A small image tagged as if it came from a file shot at `seconds`.
    static func source(exposure seconds: Double?) -> CIImage {
        let url = SnapshotTests.root.appendingPathComponent("Fixtures/sample.jpg")
        let image = ImageSource.load(url: url)!
        return image.withMiraExposureTime(seconds)
    }

    @Test func controlIsShownOnlyWithAFilm() throws {
        let model = EditorModel(library: try Self.library(), recipe: .neutral)
        #expect(!model.showsReciprocityControls)
        model.selectFilm("kodak-tri-x-400")
        #expect(model.showsReciprocityControls)
        model.selectFilm("cinema-print")
        #expect(model.showsReciprocityControls)  // a film is selected; its data is empty, the control still shows the time
    }

    @Test func timesAreFormatted() {
        #expect(ExposureTimeFormat.label(1.0 / 250) == "1/250 s")
        #expect(ExposureTimeFormat.label(1.0 / 8000) == "1/8000 s")
        #expect(ExposureTimeFormat.label(0.5) == "0.5 s")
        #expect(ExposureTimeFormat.label(2) == "2 s")
        #expect(ExposureTimeFormat.label(1.3) == "1.3 s")
        #expect(ExposureTimeFormat.label(30) == "30 s")
        #expect(ExposureTimeFormat.label(60) == "60 s")
        #expect(ExposureTimeFormat.label(sliderValue: log2(8.0)) == "8 s")
    }

    @Test func sliderSnapsToStandardSpeeds() {
        #expect(ExposureTimeFormat.standard(nearestTo: 1.0 / 130) == 1.0 / 125)
        #expect(ExposureTimeFormat.standard(nearestTo: 1.0 / 450) == 1.0 / 500)
        #expect(ExposureTimeFormat.standard(nearestTo: 2.1) == 2)
        #expect(ExposureTimeFormat.standard(nearestTo: 100) == 60)
        #expect(ExposureTimeFormat.standard(nearestTo: 1e-6) == 1.0 / 8000)
        #expect(ExposureTimeFormat.range.lowerBound == log2(1.0 / 8000) && ExposureTimeFormat.range.upperBound == log2(60))
    }

    @Test func readoutShowsExifOrNoExifOrTheChosenTime() throws {
        let model = EditorModel(library: try Self.library(), recipe: Recipe(filmID: "kodak-tri-x-400"))
        model.setSource(Self.source(exposure: nil))
        #expect(model.sourceExposureTime == nil && model.exposureTimeReadout == "No EXIF")
        #expect(model.reciprocityReadout == nil)
        model.setSource(Self.source(exposure: 1.0 / 250))
        #expect(model.exposureTimeReadout == "1/250 s \u{00B7} EXIF")
        #expect(model.reciprocityReadout == nil)   // no effect at 1/250 s
        model.setExposureTime(sliderValue: log2(2.0))
        #expect(model.recipe.exposureTime == 2 && model.exposureTimeReadout == "2 s")
        model.setExposureTime(sliderValue: log2(30.0))
        #expect(model.exposureTimeReadout == "30 s")
        #expect(model.reciprocityReadout?.hasPrefix("Reciprocity \u{2212}") == true)
    }

    @Test func resetReturnsToExif() throws {
        let model = EditorModel(library: try Self.library(), recipe: Recipe(filmID: "kodak-tri-x-400"))
        model.setSource(Self.source(exposure: 1.0 / 250))
        model.setExposureTime(sliderValue: log2(8.0))
        #expect(model.recipe.exposureTime == 8)
        model.resetExposureTime()
        #expect(model.recipe.exposureTime == nil && model.effectiveExposureTime == 1.0 / 250)
        // Dragging the slider back to the EXIF speed also clears the override.
        model.setExposureTime(sliderValue: log2(8.0))
        model.setExposureTime(sliderValue: log2(1.0 / 250))
        #expect(model.recipe.exposureTime == nil)
        // Without EXIF the neutral 1/125 s position is "no time".
        model.setSource(Self.source(exposure: nil))
        model.setExposureTime(sliderValue: log2(10.0))
        #expect(model.recipe.exposureTime == 10)
        model.setExposureTime(sliderValue: log2(1.0 / 125))
        #expect(model.recipe.exposureTime == nil)
    }

    @Test func readoutDescribesTheEffect() throws {
        let model = EditorModel(library: try Self.library(), recipe: Recipe(filmID: "fuji-velvia-50", exposureTime: 30))
        let line = try #require(model.reciprocityReadout)
        #expect(line.contains("Reciprocity \u{2212}1 stop") || line.contains("Reciprocity \u{2212}\u{2154} stops") || line.contains("stops"))
        #expect(line.contains("cast +G"), "\(line)")
        #expect(line.contains("contrast +"), "\(line)")
        #expect(!model.reciprocityExtrapolated)
        model.recipe.exposureTime = 60
        #expect(model.reciprocityExtrapolated)   // Velvia 50 is rated to 32 s
        model.recipe.reciprocity = .off
        #expect(model.reciprocityReadout == nil)
    }

    @Test func effectFormatting() {
        #expect(ReciprocityFormat.stops(1.0 + 1.0 / 3) == "\u{2212}1\u{2153}")
        #expect(ReciprocityFormat.stops(2.0 / 3) == "\u{2212}\u{2154}")
        #expect(ReciprocityFormat.stops(2) == "\u{2212}2")
        #expect(ReciprocityFormat.stops(-0.5) .hasPrefix("+"))
        #expect(ReciprocityFormat.castName(ChannelStops(r: -0.3, g: 0.12, b: -0.3)) == "G")
        #expect(ReciprocityFormat.castName(ChannelStops(r: -0.26, g: 0.07, b: 0.07)) == "C")
        #expect(ReciprocityFormat.castName(ChannelStops(r: 0.2, g: -0.05, b: -0.15)) == "R")
        #expect(ReciprocityFormat.castName(ChannelStops(r: 0.01, g: 0, b: -0.01)) == nil)
        let e = ReciprocityEffect(lossStops: 4.0 / 3, cast: ChannelStops(r: -0.3, g: 0.12, b: -0.3), contrastGain: 1.07,
                                  shadowGrainGain: 1.5, beyondDatasheet: false)
        #expect(ReciprocityFormat.readout(e) == "Reciprocity \u{2212}1\u{2153} stops \u{00B7} cast +G \u{00B7} contrast +7%")
    }
}
