import CoreImage
import Foundation
import MiraCore
import Testing
@testable import MiraUI

/// The film strip renders thumbnails for the cards on screen and a few on each side, and reuses
/// thumbnails from the disk cache across sessions.
@MainActor
@Suite("Lazy film-strip thumbnails", .serialized)
struct LazyThumbnailTests {
    static func tempCache() -> ThumbnailDiskCache {
        ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mira-lazy-\(UUID().uuidString)", isDirectory: true))
    }

    static func makeModel(cache: ThumbnailDiskCache?) throws -> EditorModel {
        let library = try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
        let model = EditorModel(library: library)
        model.thumbnailDiskCache = cache
        model.setCanvas(pixels: CGSize(width: 1200, height: 800))
        #expect(model.loadSource(url: SnapshotTests.root.appendingPathComponent("Fixtures/sample.jpg")))
        return model
    }

    static var initialCount: Int { 1 + EditorModel.initialVisibleCards + EditorModel.thumbnailPrefetch }

    @Test func onlyVisibleAndPrefetchCardsRenderInitially() async throws {
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let model = try Self.makeModel(cache: cache)
        #expect(model.visibleFilms.count > Self.initialCount * 2, "needs a library bigger than the window")
        try await HoverTests.waitFor(120) { model.thumbnailsSettled }
        #expect(model.thumbnailsSettled)
        // Give any stray extra render time to show up.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.thumbnails.count == Self.initialCount)
        #expect(model.engine.thumbnailRenderCount == Self.initialCount)
        let cards = model.visibleFilms.map(\.id)
        #expect(model.thumbnails[cards[0]] != nil)
        #expect(model.thumbnails[cards[cards.count - 1]] == nil)
        model.cancelWork()
    }

    @Test func scrollingMovesTheWindow() async throws {
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let model = try Self.makeModel(cache: cache)
        try await HoverTests.waitFor(120) { model.thumbnailsSettled }
        let cards = model.visibleFilms.map(\.id)
        let renders = model.engine.thumbnailRenderCount
        // Cards 40...43 scroll into view.
        for id in cards[40...43] { model.cardAppeared(id) }
        let want = model.wantedThumbnailIDs()
        #expect(want.count == 1 + 4 + 2 * EditorModel.thumbnailPrefetch)
        #expect(want[1] == cards[40], "visible cards lead, nearest first")
        try await HoverTests.waitFor(120) { model.thumbnailsSettled }
        #expect(model.thumbnails[cards[40 - EditorModel.thumbnailPrefetch]] != nil)
        #expect(model.thumbnails[cards[43 + EditorModel.thumbnailPrefetch]] != nil)
        #expect(model.thumbnails[cards[43 + EditorModel.thumbnailPrefetch + 1]] == nil)
        #expect(model.engine.thumbnailRenderCount == renders + 4 + 2 * EditorModel.thumbnailPrefetch)
        // Scroll back to the start: the window follows.
        for id in cards[40...43] { model.cardDisappeared(id) }
        for id in cards[0...3] { model.cardAppeared(id) }
        try await HoverTests.waitFor(120) { model.thumbnailsSettled }
        #expect(model.wantedThumbnailIDs().count == 1 + 4 + EditorModel.thumbnailPrefetch)
        // Cards 0...9 were rendered at the start: coming back to them costs nothing.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.engine.thumbnailRenderCount == renders + 4 + 2 * EditorModel.thumbnailPrefetch)
        model.cancelWork()
    }

    @Test func aNewSessionReusesTheDiskCache() async throws {
        let cache = Self.tempCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let first = try Self.makeModel(cache: cache)
        try await HoverTests.waitFor(120) { first.thumbnailsSettled }
        #expect(first.engine.thumbnailRenderCount == Self.initialCount)
        first.cancelWork()

        let second = try Self.makeModel(cache: cache)
        try await HoverTests.waitFor(120) { second.thumbnailsSettled }
        #expect(second.thumbnails.count == Self.initialCount)
        #expect(second.engine.thumbnailRenderCount == 0, "every tile came from disk")
        second.cancelWork()
    }
}
