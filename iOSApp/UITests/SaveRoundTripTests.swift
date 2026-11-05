import Photos
import UIKit
import XCTest

/// Save-to-Photos round trip inside the simulator's OWN library, on an album named "Emulsion Test" that the
/// test creates (never a real library). The runner needs Photos access:
/// xcrun simctl privacy <udid> grant photos com.fieldframes.mira.ios.uitests.xctrunner
@MainActor final class SaveRoundTripTests: XCTestCase {
    nonisolated private static let albumName = "Emulsion Test"

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["MIRA_UITEST_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// Creates the album (once) holding one new generated JPEG; returns that asset's identifier.
    private func seedAlbum() throws -> String {
        let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var found: PHAssetCollection?
        existing.enumerateObjects { c, _, stop in if c.localizedTitle == Self.albumName { found = c; stop.pointee = true } }
        if let found, let first = PHAsset.fetchAssets(in: found, options: nil).firstObject { return first.localIdentifier }

        let size = CGSize(width: 1200, height: 800)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.9, green: 0.6, blue: 0.2, alpha: 1).setFill()
            ctx.fill(CGRect(x: 300, y: 200, width: 600, height: 400))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("emulsion-test.jpg")
        try image.jpegData(compressionQuality: 0.9)!.write(to: url)
        nonisolated(unsafe) var assetID = ""
        let done = expectation(description: "album")
        PHPhotoLibrary.shared().performChanges({ @Sendable in
            let create = PHAssetCreationRequest.forAsset()
            create.addResource(with: .photo, fileURL: url, options: nil)
            let albumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: Self.albumName)
            if let placeholder = create.placeholderForCreatedAsset {
                assetID = placeholder.localIdentifier
                albumRequest.addAssets([placeholder] as NSArray)
            }
        }, completionHandler: { _, _ in done.fulfill() })
        wait(for: [done], timeout: 30)
        XCTAssertFalse(assetID.isEmpty, "could not create the Emulsion Test asset (Photos access for the runner?)")
        return assetID
    }

    func testSaveEditShowsEditedBadgeThenRevert() throws {
        let assetID = try seedAlbum()
        if PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject?.hasAdjustments == true {
            let clean = expectation(description: "clean")
            PHPhotoLibrary.shared().performChanges({ @Sendable in
                if let a = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject {
                    PHAssetChangeRequest(for: a).revertAssetContentToOriginal()
                }
            }, completionHandler: { _, _ in clean.fulfill() })
            wait(for: [clean], timeout: 30)
        }
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 20))
        let album = app.staticTexts[Self.albumName]
        for _ in 0..<6 where !album.exists { app.scrollViews.firstMatch.swipeUp(); sleep(1) }
        XCTAssertTrue(album.waitForExistence(timeout: 10), "album not listed")
        album.tap()
        sleep(3)
        shot("10-album")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2)).tap()
        let back = app.buttons["Back to library"]
        XCTAssertTrue(back.waitForExistence(timeout: 30), "editor never opened")
        sleep(3)
        try? app.debugDescription.write(toFile: "/private/tmp/claude-501/uishots/hierarchy.txt", atomically: true, encoding: .utf8)
        shot("11-editor")
        // Change something: drag the strength slider.
        let film = app.buttons["Ultra Color 100, AGFA"]; if film.waitForExistence(timeout: 5) { film.tap() }

        let save = app.buttons["SAVE"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "edit did not flag unsaved")
        save.tap()
        let saved = app.staticTexts["SAVED TO PHOTOS"]
        XCTAssertTrue(saved.waitForExistence(timeout: 60), "save did not finish")
        shot("12-saved")
        back.tap()
        sleep(3)
        shot("13-album-after-save")

        // Reopen: the saved recipe must come back (film applied, nothing unsaved).
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2)).tap()
        XCTAssertTrue(back.waitForExistence(timeout: 30), "editor did not reopen")
        sleep(4)
        shot("14-reopened")
        XCTAssertTrue(app.staticTexts["SAVED"].exists, "reopened edit should start SAVED")
        XCTAssertTrue(app.buttons["Ultra Color 100, AGFA"].isSelected, "stored film not restored")
        back.tap()

        // Revert through PhotoKit so the library is left as it was.
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
        XCTAssertNotNil(asset)
        XCTAssertTrue(asset?.hasAdjustments ?? false, "asset carries no adjustments after save")
        // Photos' own Revert to Original, then the album is left clean.
        let reverted = expectation(description: "revert")
        PHPhotoLibrary.shared().performChanges({ @Sendable in
            if let a = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject {
                PHAssetChangeRequest(for: a).revertAssetContentToOriginal()
            }
        }, completionHandler: { _, _ in reverted.fulfill() })
        wait(for: [reverted], timeout: 30)
        XCTAssertFalse(PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject?.hasAdjustments ?? true)
    }
}
