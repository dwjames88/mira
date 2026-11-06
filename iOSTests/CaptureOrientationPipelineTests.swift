import CoreImage
import ImageIO
import MiraCamera
import MiraCameraKit
import MiraCore
import Photos
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Mira

/// The whole capture pipeline on the simulator, into its OWN Photos library (album "Emulsion Test" only): a frame the way
/// the camera writes it (sensor-orientation HEIC with an orientation tag + the capture's rotation angle + the aspect
/// crop in the recipe) goes through `CaptureSaver` (`PhotoKitLibraryWriter` + the print queue + `EditorPrintWriter`),
/// is reopened by `EditorViewModel.openAsset`, and the preview (a real CAMetalLayer drawable) and the saved edit's
/// rendered JPEG must both have the marked corner top-left. Needs Photos access:
/// xcrun simctl privacy 9AAF38B4-A5CD-47D3-AB67-706E96089A68 grant photos com.fieldframes.mira.ios
/// The created assets stay in the simulator library (deleting one raises a system confirmation).
@MainActor
final class CaptureOrientationPipelineTests: XCTestCase {
    static let ink = CIColor(red: 0.082, green: 0.078, blue: 0.059)
    static let drawable = CGSize(width: 1000, height: 1000)
    static let albumTitle = "Emulsion Test"

    // MARK: Fixtures

    /// The orientation tag the camera's HEIC carries for a capture rotation angle (pixels stay in sensor orientation).
    static func exifOrientation(angle: Double) -> CGImagePropertyOrientation {
        switch Int(angle) {
        case 90: .right      // 6: turn 90 degrees clockwise to display
        case 180: .down      // 3
        case 270: .left      // 8
        default: .up
        }
    }

    /// The marked picture as the sensor holds it for `angle`: the upright picture turned back by the tag, written as a HEIC.
    static func writeSensorFrame(angle: Double, to url: URL, uprightSize: CGSize) throws -> CapturedFrame {
        let upright = CIImage(cgImage: DrawableCanvas.markedPicture(width: Int(uprightSize.width), height: Int(uprightSize.height)))
        let tag = exifOrientation(angle: angle)
        // CIImage.oriented(tag) displays a sensor image; the inverse tag turns the upright picture into the sensor image.
        let inverse: CGImagePropertyOrientation = switch tag { case .right: .left; case .left: .right; default: tag }
        let sensor = upright.oriented(inverse)
        let context = CIContext()
        let cg = try XCTUnwrap(context.createCGImage(sensor, from: sensor.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.95,
                                                     kCGImagePropertyOrientation: tag.rawValue] as CFDictionary)
        try XCTSkipUnless(CGImageDestinationFinalize(destination), "no HEIC encoder in this simulator")
        return CapturedFrame(heicURL: url, pixelSize: PixelSize(width: cg.width, height: cg.height), exposureTime: 0.01, rotationAngle: angle)
    }

    func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cam-orient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func requirePhotos() throws {
        try XCTSkipUnless(PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
                          "Grant Photos: xcrun simctl privacy 9AAF38B4-A5CD-47D3-AB67-706E96089A68 grant photos com.fieldframes.mira.ios")
    }

    // MARK: Photos helpers (changes built off the main actor)

    final class IDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        var id: String? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ id: String) { lock.lock(); value = id; lock.unlock() }
    }

    nonisolated static func albumChanges(title: String, assetID: String, existing: String?, box: IDBox) -> @Sendable () -> Void {
        { @Sendable in
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
            let request: PHAssetCollectionChangeRequest?
            if let existing, let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [existing], options: nil).firstObject {
                request = PHAssetCollectionChangeRequest(for: album)
            } else {
                request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                if let id = request?.placeholderForCreatedAssetCollection.localIdentifier { box.set(id) }
            }
            request?.addAssets(assets)
        }
    }

    /// Puts the asset in the album named "Emulsion Test", creating it if missing. Never any other album.
    func addToTestAlbum(_ assetID: String) async throws {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", Self.albumTitle)
        let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject?.localIdentifier
        try await PHPhotoLibrary.shared().performChanges(Self.albumChanges(title: Self.albumTitle, assetID: assetID, existing: existing, box: IDBox()))
        let album = try XCTUnwrap(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject)
        let inAlbum = PHAsset.fetchAssets(in: album, options: nil)
        var found = false
        inAlbum.enumerateObjects { asset, _, stop in if asset.localIdentifier == assetID { found = true; stop.pointee = true } }
        XCTAssertTrue(found, "the asset is in the \"\(Self.albumTitle)\" album")
    }

    /// The saver the camera uses, with the real PhotoKit writer and the editor's print writer.
    func makeSaver() throws -> CaptureSaver {
        let library = try XCTUnwrap(PhotoEngine.library)
        let queue = PrintQueue(store: PendingPrintStore(directory: try tempDirectory()),
                               writer: EditorPrintWriter(renderer: Renderer(library: library)))
        return CaptureSaver(library: PhotoKitLibraryWriter(), baker: PhotoKitBaker(library: library), queue: queue)
    }

    /// `save`, then drains the queue again (Photos may take a moment to offer the original) until the recipe is attached.
    func save(_ frame: CapturedFrame, recipe: Recipe, saver: CaptureSaver) async throws -> String {
        var outcome = try await saver.save(frame, recipe: recipe)
        XCTAssertNotNil(outcome.assetID)
        for _ in 0..<5 {
            if case .developed = outcome { break }
            try? await Task.sleep(for: .seconds(1))
            outcome = try await saver.save(frame, recipe: recipe)   // never reached for a developed frame
        }
        guard case .developed(let id) = outcome else {
            XCTFail("the recipe was not attached: \(outcome)")
            return outcome.assetID
        }
        return id
    }

    // MARK: Rendered output

    nonisolated static func currentImage(of asset: PHAsset) async throws -> (data: Data, orientation: CGImagePropertyOrientation) {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { @Sendable data, _, orientation, _ in
                if let data { continuation.resume(returning: (data, orientation)) }
                else { continuation.resume(throwing: PhotoLibraryError.renderFailed) }
            }
        }
    }

    func openedModel(_ id: String) async throws -> (EditorViewModel, PHAsset) {
        let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
        let m = EditorViewModel()
        guard case .opened = await m.openAsset(asset) else { XCTFail("the asset did not open"); throw CancellationError() }
        m.live.proxyBox = Self.drawable
        return (m, asset)
    }

    // MARK: Cases

    struct Case: CustomStringConvertible {
        var angle: Double
        var aspect: CaptureAspect
        var film: Bool
        var description: String { "angle \(Int(angle)) \(aspect.rawValue)\(film ? " film" : "")" }
    }

    func runCase(_ c: Case, saver: CaptureSaver, frameFor: (URL) throws -> CapturedFrame) async throws {
        let dir = try tempDirectory()
        let frame = try frameFor(dir.appendingPathComponent("frame.heic"))
        // What `CameraModel.capture` does with the aspect.
        var recipe = Recipe(filmID: c.film ? StepConsistencyTests.film(mono: false).id : nil)
        recipe.grainAmount = 0
        if let crop = CaptureCrop.recipeCrop(sensorSize: frame.pixelSize, rotationAngle: frame.rotationAngle, aspect: c.aspect) {
            recipe.crop.rect = crop.rect
            recipe.crop.aspect = crop.aspectID
        }
        let id = try await save(frame, recipe: recipe, saver: saver)
        try await addToTestAlbum(id)

        // The editor's real open path, then the preview on a drawable.
        let (m, asset) = try await openedModel(id)
        XCTAssertEqual(m.recipe.crop.aspect, recipe.crop.aspect, "\(c): the crop is restored")
        let frameOnScreen = try XCTUnwrap(DrawableCanvas.render(m.live, size: Self.drawable, recipe: m.liveRecipe, zoom: 1,
                                                                contentScale: 3, ink: Self.ink))
        DrawableCanvas.assertMarksUpright(frameOnScreen, "\(c) preview")

        // The saved edit's rendered JPEG is orientation 1 and upright.
        let rendered = try await Self.currentImage(of: asset)
        XCTAssertEqual(rendered.orientation, .up, "\(c): the rendered edit is orientation 1")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(rendered.data as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual((properties?[kCGImagePropertyOrientation] as? Int) ?? 1, 1, "\(c): no orientation tag in the rendered file")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        if c.aspect == .square { XCTAssertEqual(image.width, image.height, "\(c): square") }
        else if frame.rotationAngle == 90 { XCTAssertGreaterThan(image.height, image.width, "\(c): portrait") }
        else { XCTAssertGreaterThan(image.width, image.height, "\(c): landscape") }
        DrawableCanvas.assertMarksUpright(DrawableCanvas.frame(of: image), "\(c) rendered JPEG")
    }

    func testPortraitCaptureIsUprightInPreviewAndRenderedEdit() async throws {
        try requirePhotos()
        let saver = try makeSaver()
        for c in [Case(angle: 90, aspect: .fourThree, film: false), Case(angle: 90, aspect: .sixteenNine, film: true),
                  Case(angle: 90, aspect: .square, film: false)] {
            try await runCase(c, saver: saver) { url in try Self.writeSensorFrame(angle: c.angle, to: url, uprightSize: CGSize(width: 900, height: 1200)) }
        }
    }

    func testLandscapeCapturesAreUprightInPreviewAndRenderedEdit() async throws {
        try requirePhotos()
        let saver = try makeSaver()
        for c in [Case(angle: 180, aspect: .fourThree, film: false), Case(angle: 180, aspect: .xpan, film: true),
                  Case(angle: 0, aspect: .threeTwo, film: false)] {
            try await runCase(c, saver: saver) { url in try Self.writeSensorFrame(angle: c.angle, to: url, uprightSize: CGSize(width: 1200, height: 900)) }
        }
    }

    /// The simulator's fake camera: its capture writes the fixture (here a marked picture) as the HEIC.
    func testFakeCameraCaptureIsUpright() async throws {
        try requirePhotos()
        let dir = try tempDirectory()
        let fixture = dir.appendingPathComponent("marked.jpg")
        let marked = DrawableCanvas.markedPicture(width: 1200, height: 900)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(fixture as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, marked, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let device = FakeCaptureDevice(fixtureURL: fixture)
        let format = await device.configure(settings: CameraSettings())
        let captured = try await device.capture(format: format, location: nil)
        try await runCase(Case(angle: captured.rotationAngle, aspect: .square, film: true), saver: try makeSaver()) { url in
            let moved = url.deletingLastPathComponent().appendingPathComponent("fake.\(captured.heicURL.pathExtension)")
            try FileManager.default.moveItem(at: captured.heicURL, to: moved)
            var frame = captured
            frame.heicURL = moved
            return frame
        }
    }

    // MARK: ProRAW pair

    /// 16 x 16 luma grid of `frame`'s `rect`.
    static func grid(_ frame: DrawableCanvas.Frame, rect: CGRect) -> [Double] {
        var out = [Double](repeating: 0, count: 256)
        for gy in 0..<16 {
            for gx in 0..<16 {
                var sum = 0.0, n = 0.0
                let x0 = Int(rect.minX + rect.width * Double(gx) / 16), x1 = Int(rect.minX + rect.width * Double(gx + 1) / 16)
                let y0 = Int(rect.minY + rect.height * Double(gy) / 16), y1 = Int(rect.minY + rect.height * Double(gy + 1) / 16)
                for y in y0..<max(y1, y0 + 1) { for x in x0..<max(x1, x0 + 1) {
                    let c = frame.rgb(min(x, frame.w - 1), min(y, frame.h - 1)); sum += 0.3 * Double(c.r) + 0.59 * Double(c.g) + 0.11 * Double(c.b); n += 1 } }
                out[gy * 16 + gx] = sum / n
            }
        }
        return out
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in a.indices { sab += (a[i] - ma) * (b[i] - mb); saa += (a[i] - ma) * (a[i] - ma); sbb += (b[i] - mb) * (b[i] - mb) }
        return sab / max((saa * sbb).squareRoot(), 1e-9)
    }

    func testProRAWPairReopensWithTheDNGsOrientation() async throws {
        try requirePhotos()
        let dngSource = Snapshot.root.appendingPathComponent("Fixtures/raw/iphone-xs.dng")
        let reference = try XCTUnwrap(RawDevelop(url: dngSource), "iphone-xs.dng does not open")
        let dir = try tempDirectory()
        let heicURL = dir.appendingPathComponent("frame.heic")
        let frame = try Self.writeSensorFrame(angle: 90, to: heicURL, uprightSize: CGSize(width: 900, height: 1200))
        let dngURL = dir.appendingPathComponent("frame.dng")
        try FileManager.default.copyItem(at: dngSource, to: dngURL)
        var captured = frame
        captured.dngURL = dngURL
        var recipe = Recipe(filmID: nil)
        recipe.grainAmount = 0
        let id = try await save(captured, recipe: recipe, saver: try makeSaver())
        try await addToTestAlbum(id)

        let (m, _) = try await openedModel(id)
        // Let the full-quality RAW develop land (it replaces the source at the reference's pixel size).
        let developed = try XCTUnwrap(reference.apply(recipe.raw, filmApplied: false, draft: false), "reference develop")
        let end = Date().addingTimeInterval(90)
        while Date() < end, m.live.sourceSize != developed.extent.size { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertEqual(m.live.sourceSize, developed.extent.size, "the RAW develop finished")

        let preview = try XCTUnwrap(DrawableCanvas.render(m.live, size: Self.drawable, recipe: m.liveRecipe, zoom: 1,
                                                          contentScale: 3, ink: Self.ink))
        // Reference: the same develop, rendered to a bitmap, top row first.
        let e = developed.extent
        let fit = min(Self.drawable.width / e.width, Self.drawable.height / e.height)
        let fw: CGFloat = e.width * fit, fh: CGFloat = e.height * fit
        let rect = CGRect(x: (Self.drawable.width - fw) / 2, y: (Self.drawable.height - fh) / 2, width: fw, height: fh)
            .insetBy(dx: 4, dy: 4)
        let small = developed.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: 64 / e.width, y: 64 / e.height))
        var px = [UInt8](repeating: 0, count: 64 * 64 * 4)
        px.withUnsafeMutableBytes {
            CIContext().render(small, toBitmap: $0.baseAddress!, rowBytes: 64 * 4, bounds: CGRect(x: 0, y: 0, width: 64, height: 64),
                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        let ref = DrawableCanvas.Frame(w: 64, h: 64, px: px)
        let a = Self.grid(preview, rect: rect)
        let upright = Self.grid(ref, rect: CGRect(x: 0, y: 0, width: 64, height: 64))
        var flipped = [Double](repeating: 0, count: 256)
        for i in 0..<256 { flipped[i] = upright[(15 - i / 16) * 16 + i % 16] }
        let up = Self.correlation(a, upright), down = Self.correlation(a, flipped)
        print("RAW preview vs reference: upright \(up), flipped \(down)")
        XCTAssertGreaterThan(up, 0.8, "the reopened RAW preview matches the reference develop")
        XCTAssertGreaterThan(up, down + 0.05, "upright correlates better than vertically flipped")
    }
}
