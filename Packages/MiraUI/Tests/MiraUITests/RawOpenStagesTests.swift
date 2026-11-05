import CoreImage
import Foundation
import MiraCore
import Testing
@testable import MiraUI

/// Opening a RAW file: embedded preview, draft frame, full-quality frame, cached reopen.
@MainActor
@Suite("RAW open stages", .serialized)
struct RawOpenStagesTests {
    static var dng: URL { SnapshotTests.root.appendingPathComponent("Fixtures/raw/iphone-xs.dng") }

    @Test func opensInStagesThenReopensFromTheCache() async throws {
        RawAssetCache.shared.removeAll()
        let model = EditorModel(library: try FilmVariantTests.makeLibrary())
        let t0 = Date()
        #expect(model.loadSource(url: Self.dng))
        // Stage 1 is on screen when loadSource returns: the embedded preview, not yet a full source.
        let returnMs = Date().timeIntervalSince(t0) * 1000
        print("RAWSTAGE loadSource returned in \(Int(returnMs)) ms, isSourceFull=\(model.isSourceFull)")
        try await HoverTests.waitFor { model.isRawSource }
        #expect(model.isRawSource)                       // stage 2: draft frame, RAW session open
        #expect(model.isSourceFull)
        #expect(model.rawAsShot != nil)
        try await HoverTests.waitFor { model.rawSession.refinedKey != nil }
        #expect(model.rawSession.refinedKey == RawDevelopKey(model.recipe))   // stage 3: full quality in

        // Reopen: the proxy is cached, so the RAW session is open as soon as loadSource returns.
        let again = EditorModel(library: try FilmVariantTests.makeLibrary())
        let t1 = Date()
        #expect(again.loadSource(url: Self.dng))
        let reopenMs = Date().timeIntervalSince(t1) * 1000
        print("RAWSTAGE reopen loadSource returned in \(Int(reopenMs)) ms")
        #expect(again.isRawSource && again.isSourceFull)
    }

    @Test func aRecipeChangeDuringTheOpenIsDevelopedAfterIt() async throws {
        RawAssetCache.shared.removeAll()
        let model = EditorModel(library: try FilmVariantTests.makeLibrary())
        #expect(model.loadSource(url: Self.dng))
        model.recipe.raw.temperature = 7000     // like a restored sidecar, set right after loadSource
        try await HoverTests.waitFor { model.rawSession.refinedKey == RawDevelopKey(model.recipe) }
        #expect(model.rawSession.shownKey == RawDevelopKey(model.recipe))
        #expect(model.rawSession.refinedKey == RawDevelopKey(model.recipe))
    }
}
