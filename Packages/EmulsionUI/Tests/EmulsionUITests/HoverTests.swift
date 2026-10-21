import AppKit
import EmulsionCore
import Testing
@testable import EmulsionUI

@MainActor
@Suite("Hover preview", .serialized)
struct HoverTests {
    static func makeModel() async throws -> (EditorModel, [Film]) {
        let root = SnapshotTests.root
        let library = try FilmLibrary(directory: root.appendingPathComponent("Films"))
        let model = EditorModel(library: library)
        #expect(model.loadSource(url: root.appendingPathComponent("Fixtures/sample.jpg")))
        model.recipe.filmID = "fuji-velvia-50"
        model.recipe.contrast = 0.2
        try await waitFor { model.previewImage != nil }
        #expect(model.previewImage != nil)
        let others = library.films.filter { $0.id != "fuji-velvia-50" }
        return (model, others)
    }

    static func waitFor(_ timeout: TimeInterval = 60, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    static func data(_ image: NSImage?) -> Data? { image?.tiffRepresentation }

    @Test func hoverShowsPreviewAfterDebounceAndEndReturns() async throws {
        let (model, others) = try await Self.makeModel()
        let applied = model.previewImage
        let film = try #require(others.first(where: { $0.family == .blackAndWhite }))

        model.hoverFilm(film.id)
        #expect(model.hoverPreviewFilm == nil)           // debounce: still the applied look
        #expect(model.displayedImage === applied)
        try await Self.waitFor { model.hoverPreviewFilm != nil }
        #expect(model.hoverPreviewFilm?.id == film.id)
        #expect(model.hoverPreviewName == film.displayName)
        #expect(Self.data(model.displayedImage) != Self.data(applied))

        model.endHover()
        #expect(model.hoverPreviewFilm == nil)
        #expect(model.displayedImage === applied)
        model.cancelWork()
    }

    @Test func hoverNeverMutatesRecipe() async throws {
        let (model, others) = try await Self.makeModel()
        let before = model.recipe
        model.hoverFilm(others[0].id)
        try await Self.waitFor { model.hoverPreviewFilm != nil }
        #expect(model.recipe == before)
        model.hoverFilm(nil)
        try await Self.waitFor { model.hoverPreviewName == "Original" }
        #expect(model.recipe == before)
        model.endHover()
        #expect(model.recipe == before)
        model.cancelWork()
    }

    @Test func rapidSweepEndsOnLast() async throws {
        let (model, others) = try await Self.makeModel()
        model.hoverFilm(others[0].id)
        model.hoverFilm(others[1].id)
        model.hoverFilm(others[2].id)
        try await Self.waitFor { model.hoverPreviewFilm != nil }
        #expect(model.hoverPreviewFilm?.id == others[2].id)
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.hoverPreviewFilm?.id == others[2].id)
        model.cancelWork()
    }

    @Test func appliedFilmAndCompareBehaviour() async throws {
        let (model, others) = try await Self.makeModel()
        model.hoverFilm("fuji-velvia-50")
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.hoverPreviewFilm == nil)

        model.hoverFilm(others[0].id)
        try await Self.waitFor { model.hoverPreviewFilm != nil }
        model.showOriginal = true
        #expect(model.hoverPreviewFilm == nil)
        model.showOriginal = false
        #expect(model.hoverPreviewFilm != nil)

        model.selectFilm(others[0].id)                    // click applies and clears hover
        #expect(model.hoveredTarget == nil)
        #expect(model.hoverPreviewFilm == nil)
        model.cancelWork()
    }

    /// Regression: the canvas only redraws if the hover image change is observable.
    @Test func hoverImageChangeIsObserved() async throws {
        let (model, others) = try await Self.makeModel()
        let film = try #require(others.first(where: { $0.family == .blackAndWhite }))
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking { _ = model.displayedImage } onChange: { flag.fired = true }
        model.hoverFilm(film.id)
        flag.fired = false
        withObservationTracking { _ = model.displayedImage } onChange: { flag.fired = true }
        try await Self.waitFor { model.hoverPreviewFilm != nil }
        #expect(model.hoverPreviewFilm != nil)
        #expect(flag.fired, "displayedImage must notify observers when the hover render lands")
    }
}
