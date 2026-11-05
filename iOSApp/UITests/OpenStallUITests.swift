import Photos
import UIKit
import XCTest

/// Cross-process repro: the runner creates assets, Mira (another process) opens the newest one.
/// Prints `STALLUI <test> iter=<n> ms=<ms> ok=<bool> id=<localIdentifier>`. Opt-in (adds assets, never deletes):
/// run with TEST_RUNNER_MIRA_STALL_PROBE=1; MIRA_STALL_DIR (TEST_RUNNER_ prefixed) receives hierarchies of failures.
@MainActor final class OpenStallUITests: XCTestCase {
    nonisolated private static let albumName = "Mira Stall UI"
    nonisolated private static var stallDir: String {
        ProcessInfo.processInfo.environment["MIRA_STALL_DIR"] ?? FileManager.default.temporaryDirectory.path
    }
    private var app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MIRA_STALL_PROBE"] == "1",
                          "Opt-in stress probe: set TEST_RUNNER_MIRA_STALL_PROBE=1")
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        try XCTSkipUnless(s == .authorized || s == .limited, Preconditions.hint)
    }

    // MARK: asset creation (runner process)

    private func makeFile(raw: Bool) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
        if raw {
            let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/raw/iphone-xs.dng")
            let url = tmp.appendingPathComponent("stallui-\(UUID().uuidString).dng")
            try FileManager.default.copyItem(at: src, to: url)
            return url
        }
        let size = CGSize(width: 1200, height: 800)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            for _ in 0..<12 {
                UIColor(red: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1), alpha: 1).setFill()
                ctx.fill(CGRect(x: .random(in: 0...1000), y: .random(in: 0...600), width: .random(in: 100...600), height: .random(in: 100...400)))
            }
        }
        let url = tmp.appendingPathComponent("stallui-\(UUID().uuidString).jpg")
        try img.jpegData(compressionQuality: 0.9)!.write(to: url)
        return url
    }

    private func album() -> PHAssetCollection? {
        var found: PHAssetCollection?
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            .enumerateObjects { c, _, stop in if c.localizedTitle == Self.albumName { found = c; stop.pointee = true } }
        return found
    }

    /// Creates an asset (creationDate = now) in the test album; returns its localIdentifier.
    private func createAsset(raw: Bool) throws -> String {
        let url = try makeFile(raw: raw)
        nonisolated(unsafe) let existing = album()
        nonisolated(unsafe) var assetID = ""
        let done = expectation(description: "create")
        PHPhotoLibrary.shared().performChanges({ @Sendable in
            let create = PHAssetCreationRequest.forAsset()
            create.addResource(with: .photo, fileURL: url, options: nil)
            create.creationDate = Date()
            guard let placeholder = create.placeholderForCreatedAsset else { return }
            assetID = placeholder.localIdentifier
            if let existing {
                PHAssetCollectionChangeRequest(for: existing)?.addAssets([placeholder] as NSArray)
            } else {
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: Self.albumName)
                    .addAssets([placeholder] as NSArray)
            }
        }, completionHandler: { _, _ in done.fulfill() })
        wait(for: [done], timeout: 30)
        XCTAssertFalse(assetID.isEmpty, "asset creation failed")
        return assetID
    }

    // MARK: app navigation

    private func launchAndEnterAlbum() throws {
        app = XCUIApplication()
        try Preconditions.launchOrSkip(app)
        let albumText = app.staticTexts[Self.albumName]
        for _ in 0..<8 where !albumText.exists { app.scrollViews.firstMatch.swipeUp(); sleep(1) }
        XCTAssertTrue(albumText.waitForExistence(timeout: 10), "album not listed")
        albumText.tap()
        sleep(2)
        let all = app.buttons["ALL"]
        if all.waitForExistence(timeout: 3) { all.tap(); sleep(1) }
    }

    private func tapFirstCell() {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2)).tap()
    }

    private func ts() -> String { ISO8601DateFormatter().string(from: Date()) }

    /// Waits for the editor in two phases so a host watcher can sample the stuck app after 12 s.
    private func waitForEditor() -> Bool {
        let back = app.buttons["Back to library"]
        if back.waitForExistence(timeout: 12) { return true }
        print("STALLUI-SUSPECT t=\(ts())")
        return back.waitForExistence(timeout: 8)
    }

    private func finish(_ test: String, _ iter: Int, _ start: Date, _ ok: Bool, _ id: String) {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("STALLUI \(test) iter=\(iter) ms=\(ms) ok=\(ok) id=\(id) t=\(ts())")
        if !ok {
            try? app.debugDescription.write(toFile: "\(Self.stallDir)/ui-hier-\(test)-\(iter).txt", atomically: true, encoding: .utf8)
            XCTFail("\(test) iter \(iter) editor never opened id=\(id)")
        }
    }

    // MARK: tests

    func testColdLaunchOpenFreshAsset() throws {
        _ = try createAsset(raw: false) // make sure the album exists before first launch
        for i in 1...15 {
            let raw = i % 2 == 0
            app.terminate()
            let id = try createAsset(raw: raw)
            sleep(1)
            let start = Date()
            try launchAndEnterAlbum()
            tapFirstCell()
            let ok = waitForEditor()
            finish("cold-\(raw ? "dng" : "jpeg")", i, start, ok, id)
            if !ok { app.terminate() }
        }
    }

    private func warmLoop(test: String, settle: UInt32?) throws {
        _ = try createAsset(raw: false)
        try launchAndEnterAlbum()
        for i in 1...15 {
            let raw = i % 2 == 0
            let id = try createAsset(raw: raw)
            if let settle { sleep(settle) } else { usleep(300_000) }
            let start = Date()
            tapFirstCell()
            let ok = waitForEditor()
            finish("\(test)-\(raw ? "dng" : "jpeg")", i, start, ok, id)
            if ok {
                app.buttons["Back to library"].tap()
                sleep(2)
            } else {
                app.terminate()
                try launchAndEnterAlbum()
            }
        }
    }

    func testWarmOpenFreshAssetAfterInsert() throws { try warmLoop(test: "warm", settle: 2) }
    func testWarmOpenImmediatelyAfterInsert() throws { try warmLoop(test: "warmfast", settle: nil) }
}
