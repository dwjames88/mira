import CoreImage
import Foundation
import MiraCore
import SwiftUI
import Testing
@testable import MiraUI

@MainActor
@Suite("RAW controls and latitude", .serialized)
struct RawLatitudeTests {
    @Test func latitudeFormatting() {
        #expect(LatitudeFormat.range(under: 2, over: 3) == "\u{2212}2 / +3")
        #expect(LatitudeFormat.range(under: 1.5, over: 4) == "\u{2212}1.5 / +4")
        #expect(LatitudeFormat.percent(0.124) == "12%")
        #expect(!LatitudeFormat.isFlagged(0.01) && LatitudeFormat.isFlagged(0.02))
        let none = LatitudeReading(under: 0, over: 0.005, underStops: 0, overStops: 0)
        #expect(LatitudeFormat.compact(none) == nil)
        let over = LatitudeReading(under: 0.02, over: 0.12, underStops: 0, overStops: 1)
        #expect(LatitudeFormat.compact(over) == "12% over")
        let under = LatitudeReading(under: 0.04, over: 0, underStops: 1, overStops: 0)
        #expect(LatitudeFormat.compact(under) == "4% under")
    }

    @Test func optionalBindingFallsBackAndClearsToNil() {
        var value: Double? = nil
        let b = OptionalValue.binding(get: { value }, set: { value = $0 }, fallback: 5500, tolerance: 25)
        #expect(b.wrappedValue == 5500)
        b.wrappedValue = 6500
        #expect(value == 6500 && b.wrappedValue == 6500)
        b.wrappedValue = 5510   // back onto the fallback (double-click reset)
        #expect(value == nil)
    }

    @Test func rawControlsOnlyForRawSourcesAndSupportedControls() throws {
        let model = EditorModel(library: try FilmVariantTests.makeLibrary())
        #expect(!model.rawControlVisibility.isRaw)
        #expect(!model.rawControlVisibility.sharpness)
        model.rawSession.isRaw = true
        var supported = RawSupportedControls()
        supported.sharpness = true
        supported.lensCorrection = true
        model.rawSession.supported = supported
        let v = model.rawControlVisibility
        #expect(v.isRaw && v.sharpness && v.lensCorrection)
        #expect(!v.localToneMap && !v.luminanceNoiseReduction && !v.colorNoiseReduction)
        // Unsupported controls stay hidden for a non-RAW photo even if flags are left over.
        model.rawSession.isRaw = false
        #expect(!model.rawControlVisibility.sharpness)
    }

    @Test func latitudeReadingFollowsTheFilmAndClears() async throws {
        let model = EditorModel(library: try FilmVariantTests.makeLibrary())
        model.setSource(CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200)))
        #expect(model.latitudeReading == nil)
        model.selectFilm("portra")
        try await HoverTests.waitFor(20) { model.latitudeReading != nil }
        #expect(model.latitudeReading != nil)
        model.selectFilm(nil)
        #expect(model.latitudeReading == nil)
        model.cancelWork()
    }

    @Test func redevelopedSourceRegeneratesThumbnails() async throws {
        let model = EditorModel(library: try FilmVariantTests.makeLibrary())
        model.setSource(CIImage(color: CIColor(red: 0.4, green: 0.3, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200)))
        try await HoverTests.waitFor(30) { model.thumbnails.count == 3 }
        let before = model.thumbnails
        model.replaceSource(CIImage(color: CIColor(red: 0.1, green: 0.6, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200)), keepZoom: true)
        model.invalidateThumbnailsForNewSource()
        #expect(model.thumbnails.count == 3, "old tiles stay until new ones arrive")
        try await HoverTests.waitFor(30) {
            model.thumbnails.count == 3 && model.thumbnails.allSatisfy { before[$0.key] !== $0.value }
        }
        #expect(model.thumbnails.allSatisfy { before[$0.key] !== $0.value })
        model.cancelWork()
    }
}
