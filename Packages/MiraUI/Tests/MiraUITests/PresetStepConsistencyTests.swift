import AppKit
import MiraCore
import SwiftUI
import Testing
@testable import MiraUI

/// Mac twin of the iOS step-consistency tests: apply preset A, then preset B, move between the editor's tabs, and
/// the published preview frame must be pixel-identical to a fresh render of B's recipe on a fresh model.
@MainActor
@Suite("Preset and tab consistency", .serialized)
struct PresetStepConsistencyTests {
    static func pixels(_ model: EditorModel) throws -> Data {
        let frame = try #require(model.previewFrame)
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        return Data(bytes: base, count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }

    static func settle(_ model: EditorModel) async throws {
        try await Task.sleep(for: .milliseconds(100))
        try await HoverTests.waitFor { model.previewFrame != nil && model.isPreviewIdle }
    }

    static func presets(_ model: EditorModel) throws -> (Preset, Preset) {
        let colour = model.films.filter { !$0.isMonochrome && $0.family != .print }
        let a = try #require(colour.first), b = try #require(colour.dropFirst().first)
        var ra = Recipe(filmID: a.id); ra.pipeline = Recipe.currentPipeline
        ra.exposure = 0.4; ra.highlights = -0.35; ra.shadows = 0.3; ra.contrast = 0.2
        ra.grainAmount = 0.9; ra.halationAmount = 0.9; ra.bloomAmount = 1; ra.push = 1; ra.toning = .none
        var rb = Recipe(filmID: b.id); rb.pipeline = Recipe.currentPipeline
        rb.contrast = -0.1; rb.grainAmount = 0.3; rb.push = -0.5
        return (Preset(nickname: "A", recipe: ra, filmName: a.displayName), Preset(nickname: "B", recipe: rb, filmName: b.displayName))
    }

    @Test func presetBAfterAIsAFreshRenderOfBOnEveryTab() async throws {
        let store = PresetModelTests.tempStore()
        let (pa, pb) = try await { let m = try await PresetModelTests.makeModel(store: store); return try Self.presets(m) }()
        _ = try store.add(pa); _ = try store.add(pb)

        let model = try await PresetModelTests.makeModel(store: store)
        var crop = CropSettings.identity; crop.straighten = 4
        model.recipe.crop = crop
        model.applyPreset(pa.id)
        try await Self.settle(model)
        model.applyPreset(pb.id)
        try await Self.settle(model)

        // B replaced A completely; the photo's crop survived.
        var expected = pb.recipe; expected.crop = crop
        #expect(model.recipe == expected)
        #expect(model.recipe.exposure == 0)
        #expect(model.recipe.bloomAmount == pb.recipe.bloomAmount)

        let fresh = try await PresetModelTests.makeModel(store: PresetModelTests.tempStore())
        fresh.recipe = expected
        try await Self.settle(fresh)
        let reference = try Self.pixels(fresh)

        // The frame published after the apply, then after every tab switch and back.
        #expect(try Self.pixels(model) == reference, "A -> B on the films tab differs from a fresh render of B")
        for tab in [EditorTab.develop, .films, .develop, .dodgeBurn, .films, .crop, .develop] {
            model.selectTab(tab)
            try await Self.settle(model)
            if tab == .crop { continue }   // the crop tool shows the whole uncropped frame
            #expect(try Self.pixels(model) == reference, "tab \(tab): preview differs from a fresh render of B")
        }
        model.cancelWork(); fresh.cancelWork()
    }

    @Test func applyingFromOriginalMatchesAcrossTabs() async throws {
        let store = PresetModelTests.tempStore()
        let model = try await PresetModelTests.makeModel(store: store)
        let (pa, _) = try Self.presets(model)
        _ = try store.add(pa)
        model.selectTab(.develop)
        model.applyPreset(pa.id)
        try await Self.settle(model)
        let develop = try Self.pixels(model)
        model.selectTab(.films)
        try await Self.settle(model)
        #expect(try Self.pixels(model) == develop)
        model.cancelWork()
    }
}
