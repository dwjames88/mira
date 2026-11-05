import ImageIO
import MiraCamera
import MiraCameraKit
import MiraCore
import Photos
import UniformTypeIdentifiers
import XCTest
@testable import Mira

/// A real save into the simulator's OWN Photos library: HEIC + DNG pair through `PhotoKitLibraryWriter`, the recipe
/// attached by `EditorPrintWriter`, then reopened with `AssetEditSession`. Needs Photos access:
/// xcrun simctl privacy 9AAF38B4-A5CD-47D3-AB67-706E96089A68 grant photos com.fieldframes.mira.ios
/// The created asset stays in the simulator library (deleting one raises a system confirmation).
@MainActor
final class CameraSaveRoundTripTests: XCTestCase {
    func heic(from jpeg: URL, to url: URL) throws -> Bool {
        guard let source = CGImageSourceCreateWithURL(jpeg as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    func testPairSavesAndRecipeRoundTrips() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        try XCTSkipUnless(status == .authorized, "Grant Photos: xcrun simctl privacy <udid> grant photos com.fieldframes.mira.ios")
        let library = try XCTUnwrap(PhotoEngine.library)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cam-rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let heicURL = dir.appendingPathComponent("frame.heic")
        try XCTSkipUnless(try heic(from: CameraFixtures.sampleURL, to: heicURL), "no HEIC encoder in this simulator")
        let dngURL = dir.appendingPathComponent("frame.dng")
        try FileManager.default.copyItem(at: Snapshot.root.appendingPathComponent("Fixtures/raw/iphone-xs.dng"), to: dngURL)

        let id = try await PhotoKitLibraryWriter().createAsset(photo: heicURL, alternateRaw: dngURL)
        var recipe = Recipe(filmID: PhotoEngine.filmList.first?.id, exposure: 0.3)
        recipe.grainAmount = 0.35
        // Photos may take a moment to offer the RAW resource: retry like the print queue does.
        let writer = EditorPrintWriter(renderer: Renderer(library: library))
        var lastError: Error?
        var attached = false
        for _ in 0..<5 where !attached {
            do { try await writer.attach(recipe: recipe, toAsset: id, rawBase: true); attached = true } catch {
                lastError = error
                try? await Task.sleep(for: .seconds(1))
            }
        }
        XCTAssertTrue(attached, "attach failed: \(String(describing: lastError))")

        let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
        XCTAssertTrue(asset.hasAdjustments, "Photos shows the frame as edited")
        let session = AssetEditSession(asset: asset)
        let loaded = try await session.load()
        XCTAssertTrue(loaded.hadOurAdjustments)
        XCTAssertEqual(loaded.recipe.filmID, recipe.filmID)
        XCTAssertEqual(loaded.recipe.exposure, recipe.exposure, accuracy: 1e-9)
        XCTAssertEqual(loaded.recipe.grainAmount, recipe.grainAmount, accuracy: 1e-9)
        XCTAssertTrue(loaded.isRaw, "the frame reopens on its RAW")

        let input = try await EditingInputFetch.fetch(PhotoKitEditingInputRequester(asset: asset))
        let data = try XCTUnwrap(input.adjustmentData)
        XCTAssertEqual(data.formatIdentifier, MiraAdjustment.formatIdentifier)
        XCTAssertEqual(data.formatVersion, "4", "pipeline 2 recipes write format 4")
        if case .mira(let rawBase) = MiraAdjustment.state(of: data) { XCTAssertTrue(rawBase) } else { XCTFail("not a Mira adjustment") }
    }
}
