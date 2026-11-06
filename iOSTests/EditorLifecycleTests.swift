import CoreImage
import ImageIO
import MiraCore
import UIKit
import XCTest
@testable import Mira

/// What the editor holds while a photo is open and lets go of when it closes, and the redraw a new source asks for.
@MainActor
final class EditorLifecycleTests: XCTestCase {
    private func loaded(width: Int = 600, height: Int = 800) -> LoadedSource {
        let picture = CIImage(cgImage: DrawableCanvas.markedPicture(width: width, height: height))
        return LoadedSource(image: picture, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, size: picture.extent.size)
    }

    private func jpeg(width: Int = 600, height: Int = 800) throws -> Data {
        let image = UIImage(cgImage: DrawableCanvas.markedPicture(width: width, height: height))
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    private func sourceFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("mira-source-") })
    }

    // MARK: LivePreview

    /// A RAW develop swaps the source in later without touching the recipe; the Metal view only redraws when asked.
    func testNewSourceAsksTheViewToRedraw() {
        let live = LivePreview()
        var calls = 0
        live.onSourceChange = { calls += 1 }
        let l = loaded()
        live.setSource(l.image, colorSpace: l.colorSpace, size: l.size)
        XCTAssertEqual(calls, 1)
        live.setSource(l.image, colorSpace: l.colorSpace, size: l.size)
        XCTAssertEqual(calls, 2)
    }

    func testClearDropsThePictureAndWhatWasBuiltFromIt() {
        let live = LivePreview()
        live.proxyBox = CGSize(width: 300, height: 400)
        let l = loaded()
        live.setSource(l.image, colorSpace: l.colorSpace, size: l.size)
        live.updateProxyTarget(zoom: 1)
        XCTAssertNotNil(live.proxy)
        XCTAssertGreaterThan(live.proxyLongSide(zoom: 1), 0)
        live.clear()
        XCTAssertNil(live.source)
        XCTAssertNil(live.proxy)
        XCTAssertEqual(live.sourceSize, .zero)
        XCTAssertEqual(live.proxyLongSide(zoom: 1), 0)
        // A new photo after a clear builds its own proxy again.
        live.setSource(l.image, colorSpace: l.colorSpace, size: l.size)
        live.updateProxyTarget(zoom: 1)
        XCTAssertNotNil(live.proxy)
    }

    func testClosingThePhotoReleasesThePreviewPicture() {
        let m = EditorViewModel()
        m.present(loaded())
        XCTAssertNotNil(m.live.source)
        m.closePhoto()
        XCTAssertNil(m.live.source)
        XCTAssertNil(m.live.proxy)
        XCTAssertFalse(m.hasPhoto)
    }

    /// Closing while the crop step is open used to commit the crop into a recipe that is reset a line later.
    func testClosingWhileCroppingEndsCropping() {
        let m = EditorViewModel()
        m.present(loaded())
        m.beginCrop()
        XCTAssertTrue(m.isCropping)
        m.workingCrop.straighten = 3
        m.closePhoto()
        XCTAssertFalse(m.isCropping)
        XCTAssertEqual(m.recipe, Recipe())
        XCTAssertEqual(m.saveState, .saved)
    }

    // MARK: PhotoEngine

    func testDiscardKeepsASourceHandedOverAfterTheDecision() async throws {
        let engine = PhotoEngine()
        _ = try await engine.load(data: try jpeg(), epoch: 5)
        await engine.discard(upTo: 4)
        _ = try await engine.histogram(for: Recipe())   // still there
        await engine.discard(upTo: 5)
        do {
            _ = try await engine.histogram(for: Recipe())
            XCTFail("the source was discarded")
        } catch let error as PhotoEngineError {
            XCTAssertEqual(error.errorDescription, PhotoEngineError.cannotLoad.errorDescription)
        }
    }

    func testDiscardRemovesTheTempCopyOfAnImport() async throws {
        let before = sourceFiles()
        let engine = PhotoEngine()
        _ = try await engine.load(data: try jpeg(), epoch: 1)
        XCTAssertEqual(sourceFiles().subtracting(before).count, 1)
        await engine.discard(upTo: 1)
        XCTAssertTrue(sourceFiles().subtracting(before).isEmpty)
    }

    /// A file that cannot be read must not take the open photo's source (or its temp copy) with it.
    func testFailedLoadLeavesTheOpenSourceAndLeaksNothing() async throws {
        let before = sourceFiles()
        let engine = PhotoEngine()
        _ = try await engine.load(data: try jpeg(), epoch: 1)
        let held = sourceFiles().subtracting(before)
        do {
            _ = try await engine.load(data: Data([0, 1, 2, 3]), epoch: 2)
            XCTFail("not an image")
        } catch {}
        _ = try await engine.histogram(for: Recipe())
        XCTAssertEqual(sourceFiles().subtracting(before), held, "the first copy stays, the failed one is removed")
        await engine.discard(upTo: 1)
    }

    /// A thumbnail request cancelled while it waited its turn on the engine is dropped, not rendered.
    func testCancelledThumbnailRequestIsSkipped() async throws {
        let engine = PhotoEngine()
        _ = try await engine.load(data: try jpeg(), epoch: 1)
        let task = Task { () -> Data? in
            // Hold this task until it has been cancelled, so the request reaches the engine already cancelled.
            while !Task.isCancelled { await Task.yield() }
            return try? await engine.renderThumbnail(filmID: nil)
        }
        task.cancel()
        let data = await task.value
        XCTAssertNil(data)
        let live = try await engine.renderThumbnail(filmID: nil)   // an uncancelled request still renders
        XCTAssertFalse(live.isEmpty)
        await engine.discard(upTo: 1)
    }

    /// The film cards' small copy is made once and kept; it must look like the scale-down it replaces (a lazy Lanczos
    /// of the source, graded and encoded the same way).
    func testMaterialisedThumbnailMatchesTheLazyScale() async throws {
        let data = try jpeg(width: 1600, height: 1200)
        let engine = PhotoEngine()
        let loadedSource = try await engine.load(data: data, epoch: 1)
        let film = StepConsistencyTests.film(mono: false)
        let kept = try await engine.renderThumbnail(filmID: film.id)
        let again = try await engine.renderThumbnail(filmID: film.id)
        XCTAssertEqual(kept, again, "the same copy is reused")

        let library = try XCTUnwrap(PhotoEngine.library)
        let renderer = Renderer(library: library)
        var lazy = renderer.previewImage(from: loadedSource.image, maxPixelSize: 220)
        lazy = lazy.withMiraExposureTime(loadedSource.image.miraExposureTime).withMiraHeadroom(loadedSource.image.miraHeadroom)
        let recipe = Recipe(filmID: film.id, reciprocity: .off).applyingNativeTexture(filmID: film.id)
        let reference = try XCTUnwrap(Renderer.sharedContext.jpegRepresentation(
            of: renderer.apply(recipe, to: lazy), colorSpace: loadedSource.colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85]))
        let a = DrawableCanvas.frame(of: try XCTUnwrap(UIImage(data: kept)?.cgImage))
        let b = DrawableCanvas.frame(of: try XCTUnwrap(UIImage(data: reference)?.cgImage))
        XCTAssertEqual(a.w, b.w); XCTAssertEqual(a.h, b.h)
        var worst = 0, total = 0
        for i in 0..<a.px.count { let d = abs(Int(a.px[i]) - Int(b.px[i])); worst = max(worst, d); total += d }
        XCTAssertLessThanOrEqual(worst, 2, "max level difference")
        XCTAssertLessThan(Double(total) / Double(a.px.count), 0.05, "mean level difference")
        await engine.discard(upTo: 1)
    }
}
