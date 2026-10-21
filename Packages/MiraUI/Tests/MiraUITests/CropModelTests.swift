import AppKit
import MiraCore
import Testing
@testable import MiraUI

@MainActor
@Suite("Crop mode", .serialized)
struct CropModelTests {
    static func makeModel() async throws -> EditorModel {
        let root = SnapshotTests.root
        let library = try FilmLibrary(directory: root.appendingPathComponent("Films"))
        let model = EditorModel(library: library)
        #expect(model.loadSource(url: root.appendingPathComponent("Fixtures/sample.jpg")))
        try await HoverTests.waitFor { model.previewImage != nil }
        #expect(model.previewImage != nil)
        return model
    }

    @Test func cancelRestoresAndCommitWrites() async throws {
        let model = try await Self.makeModel()
        #expect(!model.isCropping)
        model.beginCrop()
        #expect(model.isCropping)

        model.straighten = 6
        model.setAspect("3:2")
        model.rotate90()
        #expect(model.recipe.crop == .identity) // nothing is written until Done

        model.cancelCrop()
        #expect(!model.isCropping)
        #expect(model.recipe.crop == .identity)
        #expect(model.crop == .identity)

        model.beginCrop()
        model.straighten = 6
        model.setAspect("3:2")
        let box = model.crop.rect
        model.commitCrop()
        #expect(!model.isCropping)
        #expect(model.recipe.crop.straighten == 6)
        #expect(model.recipe.crop.aspect == "3:2")
        #expect(model.recipe.crop.rect == box.clamped())
        #expect(model.hasEdits)

        // Re-opening starts from the committed crop; cancelling keeps it.
        model.beginCrop()
        #expect(model.crop == model.recipe.crop)
        model.resetCrop()
        #expect(model.crop.isIdentity)
        model.cancelCrop()
        #expect(model.recipe.crop.straighten == 6)
        model.cancelWork()
    }

    @Test func committingAnIdentityCropClearsIt() async throws {
        let model = try await Self.makeModel()
        model.beginCrop()
        model.setAspect("free")
        model.commitCrop()
        #expect(model.recipe.crop == .identity)
        #expect(!model.hasEdits)
        model.cancelWork()
    }

    @Test func aspectLockShapesTheBox() async throws {
        let model = try await Self.makeModel()
        model.beginCrop()
        model.setAspect("square")
        let canvas = try #require(model.cropCanvasSize)
        let r = model.crop.rect
        #expect(abs(r.w * canvas.width - r.h * canvas.height) < 1e-6)
        model.setAspect("3:2")
        let r2 = model.crop.rect
        #expect(abs((r2.w * canvas.width) / (r2.h * canvas.height) - 1.5) < 1e-6)
        model.toggleAspectOrientation()
        #expect(model.crop.aspect == "2:3")
        let r3 = model.crop.rect
        #expect(abs((r3.w * canvas.width) / (r3.h * canvas.height) - 2.0 / 3) < 1e-6)
        model.cancelCrop()
        model.cancelWork()
    }

    @Test func rotateSwapsCanvasAndCompareAndHoverAreOff() async throws {
        let model = try await Self.makeModel()
        model.beginCrop()
        let before = try #require(model.cropCanvasSize)
        model.rotate90()
        let after = try #require(model.cropCanvasSize)
        #expect(after.width == before.height && after.height == before.width)

        model.showOriginal = true
        model.hoverFilm(model.films[0].id)
        #expect(model.hoveredTarget == nil)
        #expect(model.displayedImage === model.previewImage)
        model.cancelCrop()
        model.cancelWork()
    }

    @Test func toolIsInertWithoutBeginning() async throws {
        let model = try await Self.makeModel()
        model.rotate90(); model.flipH(); model.flipV()
        model.commitCrop()
        #expect(model.recipe.crop == .identity)
        model.cancelWork()
    }
}
